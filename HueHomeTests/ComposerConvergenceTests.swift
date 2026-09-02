// ComposerConvergenceTests.swift
// HueHome Pro — Unit Tests
//
// Slice 3 (Composer convergence) — PRODUCTION-WIRING proof, not helper math.
//
// The Composer used to render its supporting controls on a second StageCard
// captioned "Advanced", outside the `.id(tab)` subtree that held the
// essentials. Slice 3 folds that tier into each layer's card. These tests
// build the REAL `CompositionEditorPanel` over a running composition with a
// live `CompositionParamBox`, evaluate its body — and every Composer-owned
// body inside it — and walk the resulting view tree by reflection, collecting
// every string it carries (control titles, chip labels, section captions,
// accessibility labels) and every view type it instantiates. That is the
// same tree SwiftUI renders; a control the fold-in dropped is absent from it
// and fails here by name.
//
// Why reflection and not the accessibility tree: SwiftUI materialises its
// accessibility elements only while an assistive technology is running —
// hosted in-process, even in a key window, `accessibilityElements` is empty.
// The reflective walk needs the panel's body to be evaluable outside a
// SwiftUI graph, which is why the panel takes its orchestrator as an
// explicit parameter rather than `@Environment`.

import XCTest
import SwiftUI
@testable import HueHome

// MARK: - Reflective view-tree walk

/// `ForEach` keeps its data and content closure public; expanding it is what
/// turns "a row of chips" into the chips' labels.
private protocol ForEachExpanding {
    func expandedChildren() -> [Any]
}
extension ForEach: ForEachExpanding {
    fileprivate func expandedChildren() -> [Any] {
        data.map { content($0) as Any }
    }
}

private enum ComposerViewTree {
    struct Inventory {
        var strings: [String] = []
        var types: [String] = []
    }

    /// Composer-owned bodies are evaluated; everything else is read as stored
    /// state. Evaluating a foreign body (a `BeatPanelView`, a
    /// `HueSaturationPad`) would read environment objects it has no graph
    /// for; their stored properties already carry the titles we assert on.
    private static func evaluatesBody(_ typeName: String) -> Bool {
        typeName.hasPrefix("CompositionEditorPanel")
            || typeName.hasPrefix("ComposerSupportingControls")
            || typeName.hasPrefix("ComposerControlGate<")
            || typeName.hasPrefix("StageCard<")
    }

    private static func body(of view: any View) -> Any {
        func open<V: View>(_ v: V) -> Any { v.body }
        return open(view)
    }

    @MainActor
    static func inventory(of root: Any) -> Inventory {
        var out = Inventory()
        var budget = 400_000
        walk(root, depth: 0, budget: &budget, into: &out)
        return out
    }

    @MainActor
    private static func walk(_ node: Any, depth: Int, budget: inout Int, into out: inout Inventory) {
        guard budget > 0, depth < 80 else { return }
        budget -= 1

        if let s = node as? String { out.strings.append(s); return }
        if let key = node as? LocalizedStringKey {
            // The literal behind `Text("Mode")` lives in the key's storage.
            for child in Mirror(reflecting: key).children {
                if let s = child.value as? String { out.strings.append(s) }
            }
            return
        }

        let typeName = String(describing: type(of: node))
        out.types.append(typeName)

        if let view = node as? any View, evaluatesBody(typeName) {
            walk(body(of: view), depth: depth + 1, budget: &budget, into: &out)
            return
        }
        if let forEach = node as? ForEachExpanding {
            for child in forEach.expandedChildren() {
                walk(child, depth: depth + 1, budget: &budget, into: &out)
            }
            return
        }

        let mirror = Mirror(reflecting: node)
        // Class instances are model objects (the view model, the box, the
        // orchestrator) — never part of the rendered tree. SwiftUI's own text
        // storage is the one class we descend, for the localized key inside.
        if mirror.displayStyle == .class, !typeName.contains("TextStorage") { return }
        for child in mirror.children {
            walk(child.value, depth: depth + 1, budget: &budget, into: &out)
        }
    }
}

// MARK: - Tests

@MainActor
final class ComposerConvergenceTests: XCTestCase {

    // MARK: Fixtures

    private func makeDemoOrchestrator() async -> UnifiedOrchestrator {
        let orchestrator = UnifiedOrchestrator()
        orchestrator.enterDemoMode()
        await orchestrator.loadAll()
        return orchestrator
    }

    private func room(_ id: String, bridge: String? = "bridge-a",
                      kind: RoomDisplayItem.Kind = .room) -> RoomDisplayItem {
        RoomDisplayItem(
            kind: kind,
            id: id, name: id, archetype: nil, isOn: true, brightness: 60,
            groupedLightID: "gl-\(id)", lightCount: 3, bridgeID: bridge,
            childResourceRefs: [])
    }

    private func preset(
        palette: PaletteConfig = PaletteConfig(),
        motion: MotionConfig = MotionConfig(),
        envelope: EnvelopeConfig = EnvelopeConfig(),
        reaction: ReactionConfig = ReactionConfig()
    ) -> CompositionPreset {
        CompositionPreset(
            id: UUID(), name: "Aurora Drift", icon: "sparkles", accentColorHex: "#FFB84D",
            isBuiltIn: false, category: .ambient, seasonMonths: nil,
            palette: palette, motion: motion, envelope: envelope, reaction: reaction,
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_000_000))
    }

    /// A composition RUNNING on `target` through the production identity
    /// install, with its live editor box in place — what `applyCore`'s
    /// composition arm leaves behind, minus the network.
    @discardableResult
    private func stageRunningComposition(
        _ preset: CompositionPreset, on target: RoomDisplayItem, in vm: StudioViewModel
    ) -> (card: StudioCard, box: CompositionParamBox, identity: RunningLookIdentity) {
        let card = vm.studioCard(for: preset)
        let identity = vm.installRunningIdentity(
            room: target, card: card, execution: .composition(presetID: preset.id))
        vm.runningEffects[StudioSelectionKey(room: target)] = RunningEffect(
            cardID: card.id, card: card, room: target, lightIDs: ["L1", "L2", "L3"],
            isEntertainment: false, requestedTransport: nil,
            transportFallback: false, identity: identity)
        let box = CompositionParamBox(preset: preset)
        vm.testInstallCompositionBox(box, at: StudioSelectionKey(room: target))
        return (card, box, identity)
    }

    /// The panel exactly as the host constructs it (`MixerTrayView.hostContent`),
    /// with the layer tab pinned to `tab`.
    private func panel(vm: StudioViewModel, orchestrator: UnifiedOrchestrator,
                       tab: CompositionLayerTab) -> CompositionEditorPanel {
        CompositionEditorPanel(
            vm: vm,
            orchestrator: orchestrator,
            activeCompositionTab: .constant(tab),
            activeHarmonyRule: .constant(HarmonyRule.none),
            editingSwatch: .constant(nil))
    }

    private func inventory(of preset: CompositionPreset, tab: CompositionLayerTab,
                           orchestrator: UnifiedOrchestrator) -> ComposerViewTree.Inventory {
        let vm = StudioViewModel()
        let target = room("room-a")
        vm.selectedRoom = target
        stageRunningComposition(preset, on: target, in: vm)
        return ComposerViewTree.inventory(of: panel(vm: vm, orchestrator: orchestrator, tab: tab))
    }

    /// What each catalog control id is called on the page. Several ids have
    /// more than one honest spelling (offset is "Heads" for chase and
    /// "Density" for twinkle; direction is the dial when an Entertainment
    /// area exists and the inline "Create Entertainment Area" row when not).
    private static let spokenNames: [String: [String]] = [
        "mode": ["Mode"], "temperature": ["Warmth"], "colorPad": ["Hue", "Fine Tune", "Color"],
        "harmony": ["HARMONY", "No harmony"],
        "hueShift": ["Hue Shift"], "saturation": ["Saturation"], "randomize": ["Randomize"],
        "dynamicSceneExport": ["Save as Hue dynamic scene"],
        "pattern": ["Pattern"], "speed": ["Speed"], "forward": ["Forward"],
        "direction": ["DIRECTION", "Create Entertainment Area"],
        "spread": ["Spread"], "offset": ["Offset", "Heads", "Density"], "mirror": ["Mirror"],
        "shape": ["Shape"], "bpm": ["BPM"], "depth": ["Depth"],
        "attack": ["Attack"], "decay": ["Decay"], "dutyCycle": ["Duty Cycle"],
        "minBrightness": ["Min Brightness"], "maxBrightness": ["Max Brightness"],
        "source": ["Source"], "targets": ["TARGETS", "Targets"],
        "beatPanel": ["BeatPanelView"],
        "sensitivity": ["Sensitivity"], "smoothing": ["Smoothing"],
        "threshold": ["Threshold"], "intensity": ["Intensity"],
    ]

    private struct Scenario {
        let name: String
        let tab: CompositionLayerTab
        let preset: CompositionPreset
    }

    private func scenarios() -> [Scenario] {
        var spectrum = PaletteConfig(); spectrum.mode = .spectrum
        var gradient = PaletteConfig(); gradient.mode = .gradient
        var temperature = PaletteConfig(); temperature.mode = .temperature
        var cascade = MotionConfig(); cascade.pattern = .cascade
        var twinkle = MotionConfig(); twinkle.pattern = .twinkle
        var chase = MotionConfig(); chase.pattern = .chase
        var still = MotionConfig(); still.pattern = .static
        var swell = EnvelopeConfig(); swell.shape = .swell
        var pulse = EnvelopeConfig(); pulse.shape = .pulse
        var steady = EnvelopeConfig(); steady.shape = .steady
        var mic = ReactionConfig(); mic.source = .micBass
        var beat = ReactionConfig(); beat.source = .beat
        var off = ReactionConfig(); off.source = .none
        return [
            Scenario(name: "palette/spectrum", tab: .palette, preset: preset(palette: spectrum)),
            Scenario(name: "palette/gradient", tab: .palette, preset: preset(palette: gradient)),
            Scenario(name: "palette/temperature", tab: .palette, preset: preset(palette: temperature)),
            Scenario(name: "motion/cascade", tab: .motion, preset: preset(motion: cascade)),
            Scenario(name: "motion/twinkle", tab: .motion, preset: preset(motion: twinkle)),
            Scenario(name: "motion/chase", tab: .motion, preset: preset(motion: chase)),
            Scenario(name: "motion/static", tab: .motion, preset: preset(motion: still)),
            Scenario(name: "envelope/swell", tab: .envelope, preset: preset(envelope: swell)),
            Scenario(name: "envelope/pulse", tab: .envelope, preset: preset(envelope: pulse)),
            Scenario(name: "envelope/steady", tab: .envelope, preset: preset(envelope: steady)),
            Scenario(name: "reaction/micBass", tab: .reaction, preset: preset(reaction: mic)),
            Scenario(name: "reaction/beat", tab: .reaction, preset: preset(reaction: beat)),
            Scenario(name: "reaction/none", tab: .reaction, preset: preset(reaction: off)),
        ]
    }

    // MARK: - Every former "Advanced" control is still on the page

    /// For every layer and every gating state the catalog distinguishes, each
    /// control id the catalog renders — essential AND supporting — is in the
    /// evaluated view tree. This is the migration proof for retiring the
    /// Advanced card: a control the fold-in dropped fails here by name.
    func testEveryFormerAdvancedControlIsStillRendered() async {
        let orchestrator = await makeDemoOrchestrator()
        for scenario in scenarios() {
            let tree = inventory(of: scenario.preset, tab: scenario.tab, orchestrator: orchestrator)
            XCTAssertFalse(tree.strings.isEmpty,
                "\(scenario.name): the evaluated panel carries no strings — the walk, not the page, is broken")

            let expected = ComposerControlCatalog.renderedControlIDs(
                tab: scenario.tab,
                paletteMode: scenario.preset.palette.mode,
                motionPattern: scenario.preset.motion.pattern,
                envelopeShape: scenario.preset.envelope.shape,
                reactionSource: scenario.preset.reaction.source)
            XCTAssertFalse(expected.isEmpty, "\(scenario.name): the catalog renders nothing?")

            let haystack = tree.strings + tree.types
            for id in expected {
                let names = Self.spokenNames[id] ?? [id]
                let found = haystack.contains { text in names.contains { text.contains($0) } }
                XCTAssertTrue(found,
                    "\(scenario.name): control `\(id)` (\(names)) is not on the page — "
                    + "it was reachable through Advanced before the fold-in. "
                    + "Strings: \(Set(tree.strings).sorted())")
            }
            let advanced = tree.strings.filter { $0.contains("Advanced") }
            XCTAssertTrue(advanced.isEmpty,
                "\(scenario.name): the page still says \"Advanced\" — \(advanced)")
        }
    }

    /// The gating is the reveal: a control the engine ignores for the current
    /// state is NOT on the page (spec §17 — no dead controls), so the fold-in
    /// did not simply dump every control onto every layer.
    func testGatedControlsStayOffThePage() async {
        let orchestrator = await makeDemoOrchestrator()
        var still = MotionConfig(); still.pattern = .static
        var steady = EnvelopeConfig(); steady.shape = .steady
        var breathe = EnvelopeConfig(); breathe.shape = .breathe
        var off = ReactionConfig(); off.source = .none
        var beat = ReactionConfig(); beat.source = .beat

        let staticMotion = inventory(of: preset(motion: still), tab: .motion, orchestrator: orchestrator)
        for absent in ["Speed", "Spread", "Mirror", "Forward", "DIRECTION"] {
            XCTAssertFalse(staticMotion.strings.contains(absent),
                "motion/static renders `\(absent)` — the engine returns a fixed phase; the control is dead")
        }
        let steadyEnvelope = inventory(of: preset(envelope: steady), tab: .envelope, orchestrator: orchestrator)
        for absent in ["BPM", "Depth", "Min Brightness", "Attack", "Duty Cycle"] {
            XCTAssertFalse(steadyEnvelope.strings.contains(absent),
                "envelope/steady renders `\(absent)` — steady returns max brightness only")
        }
        let breatheEnvelope = inventory(of: preset(envelope: breathe), tab: .envelope, orchestrator: orchestrator)
        for absent in ["Attack", "Decay", "Duty Cycle"] {
            XCTAssertFalse(breatheEnvelope.strings.contains(absent),
                "envelope/breathe renders `\(absent)` — that is a swell/pulse-only control")
        }
        let noReaction = inventory(of: preset(reaction: off), tab: .reaction, orchestrator: orchestrator)
        for absent in ["Intensity", "Smoothing", "Threshold", "Sensitivity", "Targets"] {
            XCTAssertFalse(noReaction.strings.contains(absent),
                "reaction/none renders `\(absent)` — there is no reaction to shape")
        }
        let beatReaction = inventory(of: preset(reaction: beat), tab: .reaction, orchestrator: orchestrator)
        for absent in ["Smoothing", "Threshold", "Sensitivity"] {
            XCTAssertFalse(beatReaction.strings.contains(absent),
                "reaction/beat renders `\(absent)` — that shapes the MIC drive only")
        }
    }

    /// The supporting tier must not resurrect the two previews it used to
    /// duplicate: the envelope curve and the mic meter each appear ONCE.
    func testSupportingTierDoesNotDuplicateThePreviews() async {
        let orchestrator = await makeDemoOrchestrator()
        var mic = ReactionConfig(); mic.source = .micBass
        var swell = EnvelopeConfig(); swell.shape = .swell

        let envelope = inventory(of: preset(envelope: swell), tab: .envelope, orchestrator: orchestrator)
        XCTAssertEqual(envelope.types.filter { $0.hasPrefix("EnvelopeStripView") }.count, 1,
            "the envelope curve preview renders more than once on the Brightness layer")

        let reaction = inventory(of: preset(reaction: mic), tab: .reaction, orchestrator: orchestrator)
        XCTAssertEqual(reaction.types.filter { $0.hasPrefix("MicLevelMeterView") }.count, 1,
            "the mic level meter renders more than once on the React layer")

        // …and no control title is carried twice on any layer.
        for scenario in scenarios() {
            let tree = inventory(of: scenario.preset, tab: scenario.tab, orchestrator: orchestrator)
            let titles = tree.strings.filter {
                ["Spread", "Max Brightness", "Intensity", "Hue Shift", "Randomize"].contains($0)
            }
            XCTAssertEqual(titles.count, Set(titles).count,
                "\(scenario.name): a control is on the page twice — a tier is rendering twice: \(titles)")
        }
    }

    /// One identity lifetime per layer: the tab subtree is no longer keyed by
    /// `.id(activeCompositionTab)` (which tore down a knob's in-flight exact
    /// entry on every programmatic tab change) — and the supporting tier lives
    /// INSIDE the layer's card, not on a card of its own.
    func testSupportingTierRendersInsideTheLayerCard() async {
        let orchestrator = await makeDemoOrchestrator()
        var swell = EnvelopeConfig(); swell.shape = .swell
        let tree = inventory(of: preset(envelope: swell), tab: .envelope, orchestrator: orchestrator)
        XCTAssertEqual(tree.types.filter { $0.hasPrefix("StageCard<") }.count, 1,
            "the Brightness layer renders \(tree.types.filter { $0.hasPrefix("StageCard<") }.count) cards — "
            + "the supporting tier must be inside the layer's ONE card, not a second one")
        XCTAssertEqual(tree.types.filter { $0.hasPrefix("ComposerSupportingControls") }.count, 1)
    }

    // MARK: - No colour popover, no detached customization sheet

    /// Composer customization presents nothing on its own: no colour popover,
    /// no "Advanced" sheet, no `StageSheetScaffold`. The ONE presentation the
    /// Composer path is allowed — the Entertainment-area BUILDER, a creation
    /// workflow that writes a bridge resource — is user-initiated from its
    /// inline row and is pinned (and narrowly carved out) by Guard 13(a).
    /// Here: the hosted page, rendered in a key window, presents nothing
    /// spontaneously, and no `StageSheetScaffold` is in the evaluated tree.
    func testComposerCustomizationHasNoColorPopoverAndNoDetachedCustomizationSheet() async {
        let orchestrator = await makeDemoOrchestrator()
        var cascade = MotionConfig(); cascade.pattern = .cascade
        var gradient = PaletteConfig(); gradient.mode = .gradient
        for (tab, p) in [(CompositionLayerTab.palette, preset(palette: gradient)),
                         (CompositionLayerTab.motion, preset(motion: cascade))] {
            let tree = inventory(of: p, tab: tab, orchestrator: orchestrator)
            XCTAssertFalse(tree.types.contains { $0.hasPrefix("StageSheetScaffold") },
                "\(tab): a StageSheetScaffold is in the Composer tree — that is a detached customization sheet")
            XCTAssertFalse(tree.types.contains { $0.hasPrefix("ComposerLayerSheet") },
                "\(tab): the retired ComposerLayerSheet is back")

            let vm = StudioViewModel()
            let target = room("room-a")
            vm.selectedRoom = target
            let staged = stageRunningComposition(p, on: target, in: vm)
            vm.sessionMemory.update(staged.identity.targetKey) { $0.activeCompositionTab = tab }
            let host = hostComposer(vm: vm, orchestrator: orchestrator)
            pump(0.3)
            XCTAssertNil(host.presentedViewController,
                "\(tab): the Composer host presented a surface of its own")
            pump(0.5)
            XCTAssertNil(host.presentedViewController,
                "\(tab): a presentation landed after the host settled")
        }
    }

    // MARK: - The layer tab is per-target session memory

    /// Plan §24: the current Composer domain is remembered PER ACTIVE TARGET.
    /// Two rooms running compositions keep their own layer; a room and a zone
    /// sharing an id keep their own; and a stopped target's selection is
    /// cleared with the rest of its working memory.
    func testActiveLayerIsRememberedPerTargetAndDiesWithIt() {
        let vm = StudioViewModel()
        let a = room("room-a")
        let b = room("room-b")
        let zoneA = room("room-a", kind: .zone)     // same id, other kind
        let sa = stageRunningComposition(preset(), on: a, in: vm)
        let sb = stageRunningComposition(preset(), on: b, in: vm)
        let sz = stageRunningComposition(preset(), on: zoneA, in: vm)

        let tabA = vm.sessionMemory.binding(for: sa.identity.targetKey, \.activeCompositionTab)
        let tabB = vm.sessionMemory.binding(for: sb.identity.targetKey, \.activeCompositionTab)
        let tabZ = vm.sessionMemory.binding(for: sz.identity.targetKey, \.activeCompositionTab)
        XCTAssertEqual(tabA.wrappedValue, .palette, "a fresh target opens on Palette")

        tabA.wrappedValue = .reaction
        XCTAssertEqual(tabA.wrappedValue, .reaction)
        XCTAssertEqual(tabB.wrappedValue, .palette, "room B did not follow room A's layer")
        XCTAssertEqual(tabZ.wrappedValue, .palette, "the zone sharing room A's id did not follow it")

        tabZ.wrappedValue = .motion
        XCTAssertEqual(tabA.wrappedValue, .reaction, "…and room A did not follow the zone")

        vm.sessionMemory.clear(for: sa.identity.targetKey)   // what stopEffect does
        XCTAssertEqual(tabA.wrappedValue, .palette, "a stopped target's layer selection died with it")
        XCTAssertEqual(tabZ.wrappedValue, .motion, "…without touching the zone's")
    }

    // MARK: - Capability truth on the page (S3-4)

    private func light(_ id: String, color: Bool, ct: (Int, Int)? = nil) -> HueLight {
        HueLight(
            id: id,
            metadata: LightMetadata(name: id, archetype: nil),
            on: OnState(on: true),
            dimming: DimmingState(brightness: 100),
            color: color ? LightColor(xy: CIExy(x: 0.3, y: 0.3), gamut_type: "C") : nil,
            color_temperature: ct.map {
                LightColorTemp(mirek: nil,
                               mirek_schema: MirekSchema(mirek_minimum: $0.0, mirek_maximum: $0.1),
                               mirek_valid: nil)
            },
            owner: nil, effects: nil, effects_v2: nil, timed_effects: nil, gradient: nil)
    }

    /// A real (non-demo) orchestrator whose light cache is seeded — the same
    /// seam the inventory fill uses — so `targetSnapshot(for:)` reads KNOWN
    /// capability for the composition's lights.
    private func seededInventory(_ lights: [HueLight]) -> (StudioViewModel, UnifiedOrchestrator) {
        let orchestrator = UnifiedOrchestrator()
        XCTAssertTrue(orchestrator.seedRawLightCache(bridgeID: "bridge-a", lights: lights, replace: true))
        let vm = StudioViewModel()
        vm.configure(orchestrator: orchestrator)
        return (vm, orchestrator)
    }

    private func pageStrings(vm: StudioViewModel, orchestrator: UnifiedOrchestrator,
                             preset p: CompositionPreset, tab: CompositionLayerTab) -> [String] {
        let target = room("room-a")
        vm.selectedRoom = target
        stageRunningComposition(p, on: target, in: vm)
        return ComposerViewTree.inventory(of: panel(vm: vm, orchestrator: orchestrator, tab: tab)).strings
    }

    /// PRODUCTION WIRING: the panel's colour controls answer against the
    /// running composition's real light inventory through the one funnel.
    /// Colour lights → the pad and harmony row are live and say nothing;
    /// white-only lights → they are on the page, refused in words; an unread
    /// inventory → CHECKING, never a refusal. Motion stays live throughout.
    func testColourControlsResolveAgainstTheTargetsRealInventory() async {
        var gradient = PaletteConfig(); gradient.mode = .gradient

        // Colour lights: nothing to caveat.
        let (vmC, orchC) = seededInventory([light("L1", color: true), light("L2", color: true), light("L3", color: true)])
        let colourPage = pageStrings(vm: vmC, orchestrator: orchC, preset: preset(palette: gradient), tab: .palette)
        XCTAssertTrue(colourPage.contains("HARMONY"))
        XCTAssertFalse(colourPage.contains(StudioBoardAvailability.checkingCopy),
            "a fully colour-capable room reads CHECKING: \(colourPage)")
        XCTAssertFalse(colourPage.contains("NO COLOR LIGHTS HERE"))

        // White-only lights: rendered, refused in words, not hidden.
        let (vmW, orchW) = seededInventory([light("L1", color: false), light("L2", color: false), light("L3", color: false)])
        let whitePage = pageStrings(vm: vmW, orchestrator: orchW, preset: preset(palette: gradient), tab: .palette)
        XCTAssertTrue(whitePage.contains("HARMONY"), "the harmony row is DISABLED on a white room, not removed")
        // ONE note per colour-gated control on the gradient page — the pad,
        // the harmony row, Randomize, and the dynamic-scene export — so one
        // gated neighbour cannot vouch for an ungated one.
        let colourGatedOnGradientPage = 4
        XCTAssertEqual(whitePage.filter { $0 == "NO COLOR LIGHTS HERE" }.count, colourGatedOnGradientPage,
            "a white-only room does not refuse EVERY colour control in words: \(whitePage)")
        XCTAssertFalse(whitePage.contains(StudioBoardAvailability.checkingCopy),
            "a READ inventory with no colour lights is a known no, not still-checking")

        // Unread inventory (demo orchestrator vends no raw lights): CHECKING.
        let demo = await makeDemoOrchestrator()
        let unreadPage = inventory(of: preset(palette: gradient), tab: .palette, orchestrator: demo).strings
        XCTAssertEqual(unreadPage.filter { $0 == StudioBoardAvailability.checkingCopy }.count,
                       colourGatedOnGradientPage,
            "an unread inventory must read CHECKING on every colour control: \(unreadPage)")
        XCTAssertFalse(unreadPage.contains("NO COLOR LIGHTS HERE"),
            "unknown is NOT unsupported — an unread room must never be refused")

        // Motion has no hardware precondition: live on the white room.
        var cascade = MotionConfig(); cascade.pattern = .cascade
        let (vmM, orchM) = seededInventory([light("L1", color: false), light("L2", color: false)])
        let motionPage = pageStrings(vm: vmM, orchestrator: orchM, preset: preset(motion: cascade), tab: .motion)
        XCTAssertTrue(motionPage.contains("Speed"))
        XCTAssertFalse(motionPage.contains("NO COLOR LIGHTS HERE"))
        XCTAssertFalse(motionPage.contains(StudioBoardAvailability.checkingCopy),
            "motion controls carry no capability caveat on a read white room: \(motionPage)")
    }

    /// Warmth authors the target's INTERSECTED mirek range (row 58): two CT
    /// lights of 153…454 and 200…500 give a 200…454 control; a CT light with
    /// no readable schema leaves the control CHECKING and disabled.
    func testWarmthRangeIsTheTargetsIntersectionAndNeverAFakeSpan() {
        var temperature = PaletteConfig(); temperature.mode = .temperature

        let (vmR, orchR) = seededInventory([light("L1", color: true, ct: (153, 454)),
                                            light("L2", color: true, ct: (200, 500))])
        let target = room("room-a")
        vmR.selectedRoom = target
        stageRunningComposition(preset(palette: temperature), on: target, in: vmR)
        let context = ComposerAvailabilityContext(vm: vmR)
        XCTAssertEqual(context.warmthRange, 200...454)
        XCTAssertTrue(context.isInteractive("temperature"))

        // The same page, reflected: the Warmth control carries no caveat.
        let page = ComposerViewTree.inventory(of: panel(vm: vmR, orchestrator: orchR, tab: .palette)).strings
        XCTAssertTrue(page.contains("Warmth"))
        XCTAssertFalse(page.contains(StudioBoardAvailability.checkingCopy), "\(page)")

        // Schemaless CT: unknown, disabled, no authoring range.
        let (vmS, _) = seededInventory([light("L1", color: false, ct: nil)])
        vmS.selectedRoom = target
        stageRunningComposition(preset(palette: temperature), on: target, in: vmS)
        let schemaless = ComposerAvailabilityContext(vm: vmS)
        XCTAssertNil(schemaless.warmthRange)
        XCTAssertFalse(schemaless.isInteractive("temperature"))
    }

    // MARK: - Hosting (for the presentation probe)

    private var windows: [UIWindow] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            windows.forEach { $0.isHidden = true; $0.rootViewController = nil }
            windows.removeAll()
        }
        super.tearDown()
    }

    private func hostComposer(vm: StudioViewModel,
                              orchestrator: UnifiedOrchestrator) -> UIHostingController<AnyView> {
        let root = AnyView(
            StudioCustomizationHost(
                vm: vm,
                performVM: .constant(nil),
                activeHarmonyRule: .constant(HarmonyRule.none),
                editingSwatch: .constant(nil),
                onBackToDecks: {},
                onSaveComposition: { _ in },
                onTransportSwitch: { _, _ in }
            )
            .background(StagePalette.stage)
            .environment(orchestrator)
        )
        let host = UIHostingController(rootView: root)
        host.overrideUserInterfaceStyle = .dark
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        windows.append(window)
        host.view.layoutIfNeeded()
        return host
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

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
        /// The `value` binding of every StageKnob / StageFader found, by title.
        var bindings: [(title: String, value: Binding<Double>)] = []
        /// Which instrument each continuous control IS, by title.
        var instruments: [String: String] = [:]
    }

    /// Composer-owned bodies are evaluated; everything else is read as stored
    /// state. Evaluating a foreign body (a `BeatPanelView`, a
    /// `HueSaturationPad`) would read environment objects it has no graph
    /// for; their stored properties already carry the titles we assert on.
    private static func evaluatesBody(_ typeName: String) -> Bool {
        typeName.hasPrefix("CompositionEditorPanel")
            || typeName.hasPrefix("ComposerSupportingControls")
            || typeName.hasPrefix("ComposerControlGate<")
            || typeName.hasPrefix("ComposerContinuousControl")
            || typeName.hasPrefix("ComposerChoiceControl<")
            || typeName.hasPrefix("ComposerToggleControl")
            || typeName.hasPrefix("ComposerTargetPads")
            || typeName.hasPrefix("ComposerHarmonySwatches")
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
        if let knob = node as? StageKnob {
            out.bindings.append((knob.title, knob.$value)); out.instruments[knob.title] = "StageKnob"
        }
        if let fader = node as? StageFader {
            out.bindings.append((fader.title, fader.$value)); out.instruments[fader.title] = "StageFader"
        }

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
            activeHarmonyRule: .constant(HarmonyRule.none))
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
        "harmony": ["Harmony"],
        "hueShift": ["Hue Shift"], "saturation": ["Saturation"], "randomize": ["Randomize"],
        "dynamicSceneExport": ["Save as Hue dynamic scene"],
        "pattern": ["Pattern"], "speed": ["Speed"], "forward": ["Forward"],
        "direction": ["Direction", "Create Entertainment Area"],
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
        for absent in ["Speed", "Spread", "Mirror", "Forward", "Direction"] {
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
            XCTAssertFalse(tree.types.contains { $0.localizedCaseInsensitiveContains("popover") },
                "\(tab): a popover modifier is in the Composer tree — colour editing is inline")
            XCTAssertFalse(tree.types.contains { $0.hasPrefix("ColorWheelView") },
                "\(tab): the detached colour wheel is back")

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

    // MARK: - Inline colour (S3-3)

    /// With a harmony rule active the swatch row renders and tapping a slot
    /// expands the SHARED StageColorEditor inline — in the evaluated tree,
    /// under the swatches, with no popover and no wheel.
    func testHarmonySwatchExpandsTheSharedEditorInline() async {
        let orchestrator = await makeDemoOrchestrator()
        let (vm, orch) = seededInventory([light("L1", color: true), light("L2", color: true)])
        _ = orchestrator
        var gradient = PaletteConfig(); gradient.mode = .gradient
        let target = room("room-a")
        vm.selectedRoom = target
        let staged = stageRunningComposition(preset(palette: gradient), on: target, in: vm)
        let harmonyPanel = CompositionEditorPanel(
            vm: vm, orchestrator: orch,
            activeCompositionTab: .constant(.palette),
            activeHarmonyRule: .constant(.triadic))

        let collapsed = ComposerViewTree.inventory(of: harmonyPanel)
        XCTAssertTrue(collapsed.types.contains { $0.hasPrefix("ComposerHarmonySwatches") })
        XCTAssertFalse(collapsed.types.contains { $0.hasPrefix("StageColorEditor") },
            "nothing is expanded yet")

        // Tap slot 2: expansion lands in THIS target's session memory.
        vm.sessionMemory.update(staged.identity.targetKey) {
            $0.expandedColorControlID = ComposerHarmonySwatches.controlID(cardID: staged.card.id, slot: 1)
        }
        let expanded = ComposerViewTree.inventory(of: harmonyPanel)
        XCTAssertTrue(expanded.types.contains { $0.hasPrefix("StageColorEditor") },
            "the shared inline editor is on the page for the open slot")
        XCTAssertTrue(expanded.strings.contains("Color 2"))
        XCTAssertFalse(expanded.types.contains { $0.localizedCaseInsensitiveContains("popover") })
        XCTAssertFalse(expanded.types.contains { $0.hasPrefix("ColorWheelView") })
    }

    /// A per-swatch edit writes ONE slot of the palette — the popover's write,
    /// unchanged — through the edit session, gamut-clamped, leaving the other
    /// slots and every other target alone.
    func testSwatchEditWritesOnlyItsSlotThroughTheSession() {
        let vm = StudioViewModel()
        let a = room("room-a"), b = room("room-b")
        let boxA = stageRunningComposition(preset(), on: a, in: vm).box
        let boxB = stageRunningComposition(preset(), on: b, in: vm).box
        let before = (boxA.palette.color1, boxA.palette.color3)
        let beforeB = boxB.palette.color2
        let s = session(vm, on: a)
        XCTAssertEqual(ComposerHarmonySwatches.commit(slot: 1, hue: 0.5, saturation: 1.0,
                                                      gamut: .c, session: s, vm: vm), .commit)
        let expected = ComposerHarmonySwatches.slotColor(hue: 0.5, saturation: 1.0, gamut: .c)
        XCTAssertEqual(boxA.palette.color2.x, expected.x, accuracy: 1e-9)
        XCTAssertEqual(boxA.palette.color2.y, expected.y, accuracy: 1e-9)
        XCTAssertEqual(boxA.palette.color1.x, before.0.x, "slot 1 untouched")
        XCTAssertEqual(boxA.palette.color3?.x, before.1?.x, "slot 3 untouched")
        XCTAssertEqual(boxB.palette.color2.x, beforeB.x, "room B's palette did not move")
        XCTAssertEqual(boxB.palette.color2.y, beforeB.y)
        // Fenced like every other write.
        vm.stopRunningScopes(forRowAt: StudioSelectionKey(room: a))
        XCTAssertEqual(ComposerHarmonySwatches.commit(slot: 0, hue: 0.1, saturation: 1.0,
                                                      gamut: .c, session: s, vm: vm), .drop(.nothingRunning))
    }

    /// The editor hands back a SwiftUI `Color`; the slot receives an xy. The
    /// round trip hue → Color → HSB → xy lands within a hair of the direct
    /// hue → xy conversion the popover made.
    func testInlineColourRoundTripIsLossless() {
        for hue in stride(from: 0.0, through: 0.95, by: 0.05) {
            for sat in [0.35, 0.7, 1.0] {
                let direct = ComposerHarmonySwatches.slotColor(hue: hue, saturation: sat, gamut: .c)
                let ui = UIColor(Color(hue: hue, saturation: sat, brightness: 1.0))
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
                ui.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
                let viaEditor = ComposerHarmonySwatches.slotColor(hue: Double(h), saturation: Double(s), gamut: .c)
                XCTAssertEqual(viaEditor.x, direct.x, accuracy: 1e-3, "hue \(hue) sat \(sat)")
                XCTAssertEqual(viaEditor.y, direct.y, accuracy: 1e-3, "hue \(hue) sat \(sat)")
            }
        }
    }

    /// Expansion is per target: opening slot 1 on room A leaves room B (and
    /// the zone sharing A's id) collapsed, and a stopped target's expansion
    /// dies with its memory.
    func testColorExpansionIsPerTarget() {
        let vm = StudioViewModel()
        let p = preset()
        let a = room("room-a"), b = room("room-b"), zoneA = room("room-a", kind: .zone)
        let sa = stageRunningComposition(p, on: a, in: vm)
        let sb = stageRunningComposition(p, on: b, in: vm)
        let sz = stageRunningComposition(p, on: zoneA, in: vm)
        let slot1 = ComposerHarmonySwatches.controlID(cardID: sa.card.id, slot: 0)
        vm.sessionMemory.update(sa.identity.targetKey) { $0.expandedColorControlID = slot1 }
        XCTAssertEqual(vm.sessionMemory.state(for: sa.identity.targetKey).expandedColorControlID, slot1)
        XCTAssertNil(vm.sessionMemory.state(for: sb.identity.targetKey).expandedColorControlID, "room B stays collapsed")
        XCTAssertNil(vm.sessionMemory.state(for: sz.identity.targetKey).expandedColorControlID, "the zone stays collapsed")
        // One slot at a time.
        let slot3 = ComposerHarmonySwatches.controlID(cardID: sa.card.id, slot: 2)
        vm.sessionMemory.update(sa.identity.targetKey) { $0.expandedColorControlID = slot3 }
        XCTAssertEqual(vm.sessionMemory.state(for: sa.identity.targetKey).expandedColorControlID, slot3)
        vm.sessionMemory.clear(for: sa.identity.targetKey)
        XCTAssertNil(vm.sessionMemory.state(for: sa.identity.targetKey).expandedColorControlID)
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
        XCTAssertTrue(colourPage.contains("Harmony"), "the harmony row is on a colour room: \(colourPage)")
        XCTAssertFalse(colourPage.contains(StudioBoardAvailability.checkingCopy),
            "a fully colour-capable room reads CHECKING: \(colourPage)")
        XCTAssertFalse(colourPage.contains("NO COLOR LIGHTS HERE"))

        // White-only lights: rendered, refused in words, not hidden.
        let (vmW, orchW) = seededInventory([light("L1", color: false), light("L2", color: false), light("L3", color: false)])
        let whitePage = pageStrings(vm: vmW, orchestrator: orchW, preset: preset(palette: gradient), tab: .palette)
        XCTAssertTrue(whitePage.contains("Harmony"), "the harmony row is DISABLED on a white room, not removed")
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

    // MARK: - Semantic vocabulary (S3-2)

    /// Every continuous Composer control is a knob or a fader — no gen-1
    /// slider, no raw Toggle — and the instrument matches the meaning: rates
    /// and character on knobs, levels and amounts on faders.
    func testComposerSpeaksTheInstrumentVocabulary() async {
        let orchestrator = await makeDemoOrchestrator()
        var swell = EnvelopeConfig(); swell.shape = .swell
        var spectrum = PaletteConfig(); spectrum.mode = .spectrum
        var mic = ReactionConfig(); mic.source = .micBass
        var cascade = MotionConfig(); cascade.pattern = .cascade
        let expectations: [(String, CompositionLayerTab, CompositionPreset, [String: String])] = [
            ("motion", .motion, preset(motion: cascade), ["Speed": "StageKnob", "Spread": "StageKnob", "Offset": "StageKnob"]),
            ("envelope", .envelope, preset(envelope: swell), ["BPM": "StageKnob", "Depth": "StageFader", "Attack": "StageKnob",
                                                            "Min Brightness": "StageFader", "Max Brightness": "StageFader"]),
            ("palette", .palette, preset(palette: spectrum), ["Hue Shift": "StageKnob", "Saturation": "StageFader"]),
            ("reaction", .reaction, preset(reaction: mic), ["Sensitivity": "StageKnob", "Smoothing": "StageKnob",
                                                           "Threshold": "StageKnob", "Intensity": "StageFader"]),
        ]
        for (name, tab, p, instruments) in expectations {
            let tree = inventory(of: p, tab: tab, orchestrator: orchestrator)
            XCTAssertFalse(tree.types.contains { $0.hasPrefix("StageSlider") }, "\(name): a gen-1 StageSlider is on the page")
            XCTAssertFalse(tree.types.contains { $0.hasPrefix("Toggle<") }, "\(name): a raw Toggle is on the page")
            for (title, instrument) in instruments {
                XCTAssertEqual(tree.instruments[title], instrument,
                    "\(name): `\(title)` is a \(tree.instruments[title] ?? "missing control"), not a \(instrument)")
            }
            XCTAssertTrue(tree.types.contains { $0.hasPrefix("StageSteppedEncoder<") }, "\(name): the discrete choice is not a stepped encoder")
        }
    }

    /// PRODUCTION WIRING through the instrument: the knob's own `value`
    /// binding — the one its drag, its typed draft and its accessibility
    /// adjust action all write — reaches the running composition's box
    /// through the edit session, and only that target's box.
    func testAKnobsBindingWritesTheCapturedTargetThroughTheSession() async {
        let orchestrator = await makeDemoOrchestrator()
        let vm = StudioViewModel()
        var cascade = MotionConfig(); cascade.pattern = .cascade
        let p = preset(motion: cascade)
        let a = room("room-a"), b = room("room-b")
        let boxA = stageRunningComposition(p, on: a, in: vm).box
        let boxB = stageRunningComposition(p, on: b, in: vm).box
        vm.selectedRoom = a
        let tree = ComposerViewTree.inventory(of: panel(vm: vm, orchestrator: orchestrator, tab: .motion))
        let speedKnobs = tree.bindings.filter { $0.title == "Speed" }
        XCTAssertEqual(speedKnobs.count, 1, "exactly one Speed knob on the Motion layer")
        guard let speed = speedKnobs.first else { return }

        // The selection moves to B before the write lands — the write was
        // authored against A and must land on A.
        vm.selectedRoom = b
        speed.value.wrappedValue = 77
        XCTAssertEqual(boxA.motion.speed, 77, "the knob wrote the box it was rendered for")
        XCTAssertEqual(boxB.motion.speed, MotionConfig().speed, "room B's box did not move")
    }

    // MARK: - Exact-state fencing (S3-5): the Composer edit session

    private func session(_ vm: StudioViewModel, on target: RoomDisplayItem) -> ComposerEditSession {
        vm.selectedRoom = target
        let s = vm.composerEditSession()
        XCTAssertNotNil(s, "a composition is running on \(target.id) with a live box")
        return s!
    }

    /// Room A vs room B, room vs zone, bridge 1 vs bridge 2: the SAME preset
    /// running on each holds its own box, and a commit through one target's
    /// session leaves every other target's box byte-identical.
    func testAnEditOnOneTargetLeavesEveryOtherTargetsBoxUntouched() {
        let vm = StudioViewModel()
        let p = preset()
        let a = room("room-a", bridge: "bridge-a")
        let b = room("room-b", bridge: "bridge-a")
        let zoneA = room("room-a", bridge: "bridge-a", kind: .zone)     // same id, other kind
        let aOnB = room("room-a", bridge: "bridge-b")                   // same id, other bridge
        let others = [b, zoneA, aOnB]
        let boxA = stageRunningComposition(p, on: a, in: vm).box
        let otherBoxes = others.map { stageRunningComposition(p, on: $0, in: vm).box }
        XCTAssertTrue(otherBoxes.allSatisfy { $0 !== boxA }, "four targets, four boxes")

        let sA = session(vm, on: a)
        XCTAssertTrue(sA.box === boxA)
        // Move the selection elsewhere BEFORE the write lands — the shape of
        // every "wrote to the wrong room" defect.
        vm.selectedRoom = b
        let verdict = vm.commitComposerEdit(sA) { box in
            box.motion.speed = 99
            box.envelope.bpm = 200
            box.palette.mode = .spectrum
        }
        XCTAssertEqual(verdict, .commit)
        XCTAssertEqual(boxA.motion.speed, 99, "the write landed on the box the gesture began on")
        for (other, box) in zip(others, otherBoxes) {
            XCTAssertEqual(box.motion.speed, p.motion.speed, "\(other.kind) \(other.id)@\(other.bridgeID ?? "-") moved")
            XCTAssertEqual(box.envelope.bpm, p.envelope.bpm)
            XCTAssertEqual(box.palette.mode, p.palette.mode)
        }
    }

    /// Stop is authoritative: a session captured before the stop drops as
    /// `.nothingRunning` and the (evicted) box is not mutated.
    func testAStopFencesTheSessionCapturedBeforeIt() {
        let vm = StudioViewModel()
        let a = room("room-a")
        let staged = stageRunningComposition(preset(), on: a, in: vm)
        let s = session(vm, on: a)
        // What `stopEffect` does first, before any suspension (Slice 2 fence-first).
        vm.stopRunningScopes(forRowAt: StudioSelectionKey(room: a))
        let verdict = vm.commitComposerEdit(s) { $0.motion.speed = 99 }
        XCTAssertEqual(verdict, .drop(.nothingRunning))
        XCTAssertEqual(staged.box.motion.speed, MotionConfig().speed, "a stopped run's box did not move")
    }

    /// A REPLACEMENT on the same place (a different composition applied to
    /// the room) retires the predecessor's scope: its session drops, and the
    /// successor's fresh box never receives the predecessor's edit.
    func testAReplacementOnTheSamePlaceFencesThePredecessor() {
        let vm = StudioViewModel()
        let a = room("room-a")
        let first = stageRunningComposition(preset(), on: a, in: vm)
        let sOld = session(vm, on: a)
        let second = stageRunningComposition(preset(), on: a, in: vm)   // new preset, same place
        XCTAssertTrue(second.box !== first.box)
        let verdict = vm.commitComposerEdit(sOld) { $0.motion.speed = 99 }
        XCTAssertFalse(verdict.isCommit, "the predecessor's edit landed: \(verdict)")
        XCTAssertEqual(second.box.motion.speed, MotionConfig().speed, "the successor's box is untouched")
        XCTAssertEqual(first.box.motion.speed, MotionConfig().speed, "…and so is the evicted one")
        // A fresh session addresses the successor and commits.
        let sNew = session(vm, on: a)
        XCTAssertTrue(sNew.box === second.box)
        XCTAssertEqual(vm.commitComposerEdit(sNew) { $0.motion.speed = 42 }, .commit)
        XCTAssertEqual(second.box.motion.speed, 42)
    }

    /// A RESTART of the same look on the same place is a new generation: the
    /// old session is stale, the new one commits, and the box is the new run's.
    func testARestartOfTheSameLookFencesTheOldGeneration() {
        let vm = StudioViewModel()
        let a = room("room-a")
        let p = preset()
        let first = stageRunningComposition(p, on: a, in: vm)
        let sOld = session(vm, on: a)
        let second = stageRunningComposition(p, on: a, in: vm)         // same preset, same place
        XCTAssertNotEqual(first.identity.generation, second.identity.generation)
        XCTAssertEqual(first.identity.targetKey, second.identity.targetKey, "same look, same place")
        XCTAssertEqual(vm.commitComposerEdit(sOld) { $0.motion.speed = 99 }, .drop(.staleGeneration))
        XCTAssertEqual(second.box.motion.speed, MotionConfig().speed)
        XCTAssertEqual(vm.commitComposerEdit(session(vm, on: a)) { $0.motion.speed = 42 }, .commit)
        XCTAssertEqual(second.box.motion.speed, 42)
    }

    /// A transport failover (DTLS → REST) rekeys the running instance: writes
    /// authored against the streaming run drop; the look never stopped and
    /// the NEXT gesture captures the new identity and commits.
    func testATransportFailoverFencesInFlightEditsWithoutStoppingTheLook() {
        let vm = StudioViewModel()
        let a = room("room-a")
        let staged = stageRunningComposition(preset(), on: a, in: vm)
        let sOld = session(vm, on: a)
        vm.rekeyRunningInstance(at: StudioSelectionKey(room: a), reason: .transportChanged)
        XCTAssertEqual(vm.commitComposerEdit(sOld) { $0.motion.speed = 99 }, .drop(.staleGeneration))
        XCTAssertEqual(staged.box.motion.speed, MotionConfig().speed)
        let sNew = session(vm, on: a)
        XCTAssertTrue(sNew.box === staged.box, "the same box — the look never stopped")
        XCTAssertEqual(vm.commitComposerEdit(sNew) { $0.motion.speed = 42 }, .commit)
    }

    // MARK: - Revert to Saved / Save

    private func storeWith(_ presets: [CompositionPreset]) -> CompositionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-convergence-\(UUID().uuidString).json")
        let store = CompositionStore(fileURL: url, loadsSynchronously: true)
        presets.forEach { store.save($0) }
        return store
    }

    /// Revert restores the SAVED document — all four layers — into the live
    /// box, fences the edit that was in flight against the pre-revert run,
    /// hands the next gesture a fresh identity, and leaves other targets alone.
    func testRevertRestoresTheSavedDocumentAndFencesInFlightEdits() {
        let vm = StudioViewModel()
        var motion = MotionConfig(); motion.speed = 33; motion.pattern = .wave
        var envelope = EnvelopeConfig(); envelope.bpm = 90
        let saved = preset(motion: motion, envelope: envelope)
        vm.injectForTesting(compositionStore: storeWith([saved]))
        let a = room("room-a")
        let b = room("room-b")
        let boxA = stageRunningComposition(saved, on: a, in: vm).box
        let boxB = stageRunningComposition(saved, on: b, in: vm).box

        // Unsaved edits on A and on B.
        let sA = session(vm, on: a)
        XCTAssertEqual(vm.commitComposerEdit(sA) { $0.motion.speed = 77; $0.palette.mode = .spectrum }, .commit)
        XCTAssertEqual(vm.commitComposerEdit(session(vm, on: b)) { $0.motion.speed = 55 }, .commit)
        let before = vm.runningEffect(for: a)?.identity

        vm.selectedRoom = a
        vm.revertActiveComposition()

        XCTAssertEqual(boxA.motion.speed, 33, "speed came back from the saved document")
        XCTAssertEqual(boxA.motion.pattern, .wave)
        XCTAssertEqual(boxA.palette.mode, saved.palette.mode, "the palette layer reverted too")
        XCTAssertEqual(boxA.envelope.bpm, 90)
        XCTAssertEqual(boxB.motion.speed, 55, "room B's unsaved edit is untouched by room A's revert")
        XCTAssertTrue(vm.statusMessage.contains("Reverted to saved"))

        // The pre-revert session is stale; a fresh one commits.
        XCTAssertEqual(vm.commitComposerEdit(sA) { $0.motion.speed = 99 }, .drop(.staleGeneration))
        XCTAssertEqual(boxA.motion.speed, 33, "the in-flight edit did not land on top of the revert")
        let after = vm.runningEffect(for: a)?.identity
        XCTAssertNotEqual(before?.generation, after?.generation, "revert minted a new generation")
        XCTAssertEqual(before?.targetKey, after?.targetKey, "…on the same look and place")
        XCTAssertTrue(vm.valueScopes.isCurrent(after!), "the row's identity is the live one")
        XCTAssertEqual(vm.commitComposerEdit(session(vm, on: a)) { $0.motion.speed = 12 }, .commit)
    }

    /// Revert refuses the "+ Create" draft (nothing saved to revert to) and
    /// never touches the box.
    func testRevertRefusesTheStarterDraft() {
        let vm = StudioViewModel()
        let a = room("room-a")
        let card = vm.starterCompositionCard()
        let identity = vm.installRunningIdentity(
            room: a, card: card, execution: .composition(presetID: StudioViewModel.composerStarterDraftPresetID))
        vm.runningEffects[StudioSelectionKey(room: a)] = RunningEffect(
            cardID: card.id, card: card, room: a, lightIDs: ["L1"],
            isEntertainment: false, requestedTransport: nil, transportFallback: false, identity: identity)
        let box = CompositionParamBox(preset: preset())
        vm.testInstallCompositionBox(box, at: StudioSelectionKey(room: a))
        XCTAssertEqual(vm.commitComposerEdit(session(vm, on: a)) { $0.motion.speed = 77 }, .commit)
        vm.revertActiveComposition()
        XCTAssertEqual(box.motion.speed, 77, "the draft kept its edits")
        XCTAssertEqual(vm.runningEffect(for: a)?.identity.generation, identity.generation,
                       "a refused revert bumps nothing")
    }

    /// Save persists EXACTLY the live edits as a NEW preset (save-as), leaves
    /// the running box and other targets untouched, and sanitises the name
    /// and icon the way the sheet relies on.
    func testSavePersistsExactEditsAsANewPresetAndTouchesNothingElse() throws {
        let vm = StudioViewModel()
        let store = storeWith([])
        vm.injectForTesting(compositionStore: store)
        let a = room("room-a")
        let b = room("room-b")
        let boxA = stageRunningComposition(preset(), on: a, in: vm).box
        let boxB = stageRunningComposition(preset(), on: b, in: vm).box
        XCTAssertEqual(vm.commitComposerEdit(session(vm, on: a)) {
            $0.motion.speed = 88; $0.envelope.shape = .pulse; $0.reaction.source = .beat
        }, .commit)

        vm.selectedRoom = a
        let saved = try XCTUnwrap(vm.saveActiveComposition(
            name: "   ", icon: "definitely.not.a.symbol", preferredTransport: nil, category: .all))
        XCTAssertEqual(saved.name, "My Composition", "an empty name gets the default")
        XCTAssertEqual(saved.icon, "sparkles", "an unknown symbol falls back")
        XCTAssertEqual(saved.category, .myCreations, "`.all` is a filter, never a preset's category")
        XCTAssertEqual(saved.motion.speed, 88)
        XCTAssertEqual(saved.envelope.shape, .pulse)
        XCTAssertEqual(saved.reaction.source, .beat)
        XCTAssertTrue(store.presets.contains { $0.id == saved.id }, "persisted")
        XCTAssertEqual(boxA.motion.speed, 88, "saving does not disturb the running box")
        XCTAssertEqual(boxB.motion.speed, MotionConfig().speed, "…or another target's")
        XCTAssertTrue(vm.valueScopes.isCurrent(vm.runningEffect(for: a)!.identity),
                      "save does not restart or rekey the running look")
    }

    // MARK: - Perform

    /// Entering Perform threads the LIVE box (deck A is the same instance the
    /// editor writes), records the backing preset — nil for the starter draft
    /// — and leaving it hands the same box back untouched: no duplicate
    /// runtime, no copy.
    func testPerformThreadsTheLiveBoxAndLeavesItIntactOnExit() async {
        let orchestrator = await makeDemoOrchestrator()
        let vm = StudioViewModel()
        let a = room("room-a")
        let p = preset()
        let staged = stageRunningComposition(p, on: a, in: vm)
        XCTAssertEqual(vm.commitComposerEdit(session(vm, on: a)) { $0.motion.speed = 64 }, .commit)

        // Exactly what MixerTrayView's Perform button builds.
        var presetID: UUID? = nil
        if case .composition(let pid) = staged.card.strategy,
           pid != StudioViewModel.composerStarterDraftPresetID { presetID = pid }
        var performVM: PerformanceViewModel? = PerformanceViewModel(
            orchestrator: orchestrator, room: a, liveBox: staged.box,
            liveName: staged.card.name, presetID: presetID, compositionStore: vm.compositionStore)
        XCTAssertTrue(performVM!.mix.deckA === staged.box, "Perform performs THE live box, not a copy")
        XCTAssertEqual(performVM!.presetID, p.id)
        XCTAssertEqual(performVM!.room.id, a.id)

        performVM = nil   // exit: the cover's item goes nil
        XCTAssertEqual(staged.box.motion.speed, 64, "the edit survived Perform")
        XCTAssertTrue(vm.composerEditSession()!.box === staged.box, "the editor still addresses the same box")
        XCTAssertTrue(vm.valueScopes.isCurrent(staged.identity), "Perform neither stopped nor rekeyed the look")

        // The starter draft performs as unsaved.
        let starter = vm.starterCompositionCard()
        var draftID: UUID? = nil
        if case .composition(let pid) = starter.strategy,
           pid != StudioViewModel.composerStarterDraftPresetID { draftID = pid }
        XCTAssertNil(draftID)
    }

    // MARK: - Host identity

    /// The customization host keys its subtree on the exact target and look,
    /// without the generation: two targets running the same preset never
    /// share view identity; a same-look restart or Revert keeps it.
    func testHostIdentityIsPerTargetAndSurvivesAGenerationBump() {
        let vm = StudioViewModel()
        let p = preset()
        let a = room("room-a", bridge: "bridge-a")
        let aOnB = room("room-a", bridge: "bridge-b")
        let zoneA = room("room-a", bridge: "bridge-a", kind: .zone)
        let idA = stageRunningComposition(p, on: a, in: vm).identity
        let idB = stageRunningComposition(p, on: aOnB, in: vm).identity
        let idZ = stageRunningComposition(p, on: zoneA, in: vm).identity
        XCTAssertEqual(idA.cardID, idB.cardID, "the bare cardID — the old host key — cannot tell these apart")
        let ids = Set([idA.targetKey.stableID, idB.targetKey.stableID, idZ.targetKey.stableID])
        XCTAssertEqual(ids.count, 3, "same preset, three targets, three view identities")

        let restarted = stageRunningComposition(p, on: a, in: vm).identity
        XCTAssertNotEqual(restarted.generation, idA.generation)
        XCTAssertEqual(restarted.targetKey.stableID, idA.targetKey.stableID,
                       "a generation bump does not tear the surface down")
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

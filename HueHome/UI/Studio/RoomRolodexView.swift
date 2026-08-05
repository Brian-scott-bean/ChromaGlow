// RoomRolodexView.swift
// CastChroma — v0.18.0 Studio Room Rolodex
//
// A compact, floating two-axis wheel picker for choosing a room or a zone —
// sized to hover inline near the top of the Studio section. The whole control
// is ~126pt (a 26pt legend row over a 96pt three-detent wheel); it sits above
// Studio's deck grid, which claims every point the wheel does not take.
//   • Vertical wheel   = ROOMS  (spin up / down)     → Apple-time-picker cylinder
//   • Horizontal wheel = ZONES  (spin left / right)  → same cylinder, rotated 90°
//   • Both cross at a glowing amber "lens" that always frames the live selection.
//
// A SINGLE axis-locked drag gesture drives whichever wheel the finger commits to
// (horizontal → zones, vertical → rooms), so both directions always work — no two
// overlapping ScrollViews fighting over the pan. Wheels are hand-rendered with a
// 3D cylinder curve + flick momentum + snap detents, so it still reads as the
// system picker. A search affordance reveals the searchable `RoomPickerSheetView`.

import SwiftUI

struct RoomRolodexView: View {

    let rooms: [RoomDisplayItem]
    let zones: [RoomDisplayItem]
    let selectedRoom: RoomDisplayItem?
    let runningEffects: [RoomEffectKey: RunningEffect]   // exact bridge+room key (round 4c)

    /// The user chose this item. Fires ONCE, after the wheel has stopped —
    /// never mid-drag, and never when the finger merely lifts.
    let onCommit: (RoomDisplayItem) -> Void
    /// Open customization for THIS exact item. Never writes the selection and
    /// never touches a playback API, so tapping an already-selected room still
    /// opens the surface.
    let onActivate: (RoomDisplayItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // ── Compact geometry ──────────────────────────────────────────────
    //
    // The stage shows exactly three room detents (96 = 3 × 32): the selection
    // in the lens plus one neighbour above and below, which is the least a
    // wheel can show and still read as a wheel. Studio's deck grid takes every
    // point this gives back, so the stage does not get to be generous.
    private let stageHeight:   CGFloat = 96        // the wheel viewport
    private static let rowHeightConst: CGFloat = 32     // vertical detent height
    private static let colWidthConst:  CGFloat = 150    // horizontal detent width
    private var rowHeight: CGFloat { Self.rowHeightConst }
    private var colWidth:  CGFloat { Self.colWidthConst }
    private let lensWidth:      CGFloat = 214
    private let lensHeight:     CGFloat = 36

    // ── Selection + drag state ────────────────────────────────────────
    //
    // One machine. The scalars that used to live here (selRoom, selZone,
    // liveRoom, liveZone, lockAxis, activeAxis, drag) and the old `isSyncing`
    // flag are all inside it, and the transient/committed separation the wheel
    // always had is now honoured all the way up.
    @State private var machine: RolodexSelectionMachine
    @State private var didInit = false
    @State private var showListFallback = false
    /// Cancels the previous settle's watchdog when a new settle begins.
    @State private var settleWatchdog: Task<Void, Never>?

    /// How long to wait for a spring completion before committing anyway.
    /// Comfortably longer than the 0.34s spring — this is a stuck-state
    /// backstop, not a second timing path.
    private static let settleWatchdogSeconds: Double = 1.2

    init(
        rooms: [RoomDisplayItem],
        zones: [RoomDisplayItem],
        selectedRoom: RoomDisplayItem?,
        runningEffects: [RoomEffectKey: RunningEffect],
        onCommit: @escaping (RoomDisplayItem) -> Void,
        onActivate: @escaping (RoomDisplayItem) -> Void
    ) {
        self.rooms = rooms
        self.zones = zones
        self.selectedRoom = selectedRoom
        self.runningEffects = runningEffects
        self.onCommit = onCommit
        self.onActivate = onActivate

        let startAsZone = selectedRoom?.kind == .zone
        let r = rooms.firstIndex { $0.id == selectedRoom?.id } ?? 0
        let z = zones.firstIndex { $0.id == selectedRoom?.id } ?? 0
        _machine = State(initialValue: RolodexSelectionMachine(
            rowHeight: Self.rowHeightConst,
            colWidth: Self.colWidthConst,
            activeAxis: startAsZone ? .horizontal : .vertical,
            committedRoom: r,
            committedZone: z,
            roomTokens: rooms.map(RolodexItemToken.init(item:)),
            zoneTokens: zones.map(RolodexItemToken.init(item:))))
    }

    // ── Derived ───────────────────────────────────────────────────────
    /// The POSITIONAL base each wheel is drawn from — the settle target while a settle
    /// is in flight, the committed index otherwise. Never `committedRoom` directly:
    /// see `renderBase(for:)` for why that produced the snap-back.
    private var baseRoom: Int { machine.renderBase(for: .vertical) }
    private var baseZone: Int { machine.renderBase(for: .horizontal) }
    private var liveRoom: Int { machine.liveRoom }
    private var liveZone: Int { machine.liveZone }
    private var activeAxis: Axis { machine.activeAxis }

    private var roomDrag: CGFloat { activeAxis == .vertical ? machine.translation : 0 }
    private var zoneDrag: CGFloat { activeAxis == .horizontal ? machine.translation : 0 }

    private var activeItem: RoomDisplayItem? {
        item(axis: activeAxis, index: machine.activeIndex)
    }
    private var activeID: String? { activeItem?.id }

    private func item(axis: Axis, index: Int) -> RoomDisplayItem? {
        axis == .vertical ? rooms[safe: index] : zones[safe: index]
    }

    /// Identity-only view of both rosters, so a brightness or on/off change
    /// (which `RoomDisplayItem`'s memberwise `==` treats as a difference) does
    /// not look like a roster change and trigger a needless rebase.
    private var rosterFingerprint: [RolodexItemToken] {
        rooms.map(RolodexItemToken.init(item:)) + zones.map(RolodexItemToken.init(item:))
    }

    /// Run the machine's effects. This is the ONLY place the rolodex talks to
    /// its parent — and note what is NOT here: `.preview` is consumed entirely
    /// by the wheel's own rendering (the machine's `liveRoom`/`liveZone` and
    /// `isPreviewing` already drive the cells and the lens), so there is no
    /// closure a future edit could attach a refresh or a selection write to.
    /// That is what makes "Studio gains no preview state" structural.
    ///
    /// None of these branches calls a playback API. `.commit`,
    /// `.reconcileSelection` and `.applyExternalSelection` each produce exactly
    /// one selection write; `.activate` produces none.
    private func perform(_ effects: [RolodexSelectionMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .haptic:
                HapticManager.shared.selection()
            case .preview:
                break   // wheel-local; never crosses this boundary
            case let .commit(axis, index):
                if let item = item(axis: axis, index: index) { onCommit(item) }
            case let .reconcileSelection(axis, index):
                if let item = item(axis: axis, index: index) { onCommit(item) }
            case let .applyExternalSelection(axis, index):
                if let item = item(axis: axis, index: index) { onCommit(item) }
            case let .activate(axis, index):
                if let item = item(axis: axis, index: index) { onActivate(item) }
            }
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            header
            wheelStage
                .frame(height: stageHeight)
        }
        .onAppear {
            DispatchQueue.main.async { didInit = true }
        }
        .onDisappear { settleWatchdog?.cancel() }
        // Roster changes rebase by TOKEN. A reorder keeps the selection with no
        // effect at all; only a vanished item produces `.reconcileSelection`,
        // which is a repair and never counted as the user choosing.
        .onChange(of: rosterFingerprint) { _, _ in
            perform(machine.apply(.rosterChanged(
                rooms: rooms.map(RolodexItemToken.init(item:)),
                zones: zones.map(RolodexItemToken.init(item:)))))
        }
        // A selection made elsewhere (Siri, a deep link, the parent). While idle
        // this only snaps the wheels — the parent already holds it, so writing
        // back would be circular. Mid-drag or mid-spring it is DEFERRED.
        .onChange(of: selectedRoom?.id) { _, id in
            guard didInit, let id, id != activeID else { return }
            if let z = zones.firstIndex(where: { $0.id == id }) {
                withAnimation(HueAnimation.card) {
                    machine.apply(.externalSelect(axis: .horizontal, index: z))
                }
            } else if let r = rooms.firstIndex(where: { $0.id == id }) {
                withAnimation(HueAnimation.card) {
                    machine.apply(.externalSelect(axis: .vertical, index: r))
                }
            }
        }
        .sheet(isPresented: $showListFallback) {
            RoomPickerSheetView(
                rooms: rooms,
                zones: zones,
                selectedRoom: activeItem ?? selectedRoom,
                runningEffects: runningEffects,
                onSelect: { item in
                    select(item)
                    showListFallback = false
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.ultraThinMaterial)
        }
    }

    // ──────────────────────────────────────────────────────────────────
    // MARK: - Header (legend + search)
    // ──────────────────────────────────────────────────────────────────

    private var header: some View {
        HStack(spacing: 10) {
            axisTag(system: "chevron.up.chevron.down", title: "ROOMS", active: activeAxis == .vertical)
            Circle().fill(.white.opacity(0.16)).frame(width: 3, height: 3)
            axisTag(system: "chevron.left.chevron.right", title: "ZONES", active: activeAxis == .horizontal)

            Spacer()

            Button {
                showListFallback = true
                HapticManager.shared.light()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 26, height: 26)
            }
            .accessibilityLabel("Search rooms and zones")
        }
        .padding(.horizontal, 6)
    }

    private func axisTag(system: String, title: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: system).font(.system(size: 9, weight: .bold))
            Text(title).font(.system(size: 10, weight: .bold)).tracking(0.6)
        }
        .foregroundStyle(active ? HuePalette.amber : .white.opacity(0.38))
        .animation(HueAnimation.normal, value: active)
    }

    // ──────────────────────────────────────────────────────────────────
    // MARK: - Wheel stage (the crossing rolodex)
    // ──────────────────────────────────────────────────────────────────

    private var wheelStage: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                crossRails

                // Vertical ROOM wheel
                ForEach(Array(rooms.enumerated()), id: \.element.id) { idx, room in
                    let pos = CGFloat(idx - baseRoom) * rowHeight + roomDrag
                    if abs(pos) < h / 2 + rowHeight {
                        wheelCell(
                            item: room, isZone: false,
                            isCenter: idx == liveRoom && activeAxis == .vertical,
                            isCommitted: machine.committedMarker(for: .vertical) == idx
                                && activeAxis == .vertical)
                            .frame(width: min(w, 300))
                            .offset(y: pos)
                            .modifier(Cylinder(n: pos / (h / 2), axis: .vertical, reduceMotion: reduceMotion))
                            .opacity(axisOpacity(active: activeAxis == .vertical, pos: pos, axis: .vertical))
                    }
                }

                // Horizontal ZONE wheel
                ForEach(Array(zones.enumerated()), id: \.element.id) { idx, zone in
                    let pos = CGFloat(idx - baseZone) * colWidth + zoneDrag
                    if abs(pos) < w / 2 + colWidth {
                        wheelCell(
                            item: zone, isZone: true,
                            isCenter: idx == liveZone && activeAxis == .horizontal,
                            isCommitted: machine.committedMarker(for: .horizontal) == idx
                                && activeAxis == .horizontal)
                            .frame(width: colWidth)
                            .offset(x: pos)
                            .modifier(Cylinder(n: pos / (w / 2), axis: .horizontal, reduceMotion: reduceMotion))
                            .opacity(axisOpacity(active: activeAxis == .horizontal, pos: pos, axis: .horizontal))
                    }
                }

                selectionLens
                    .allowsHitTesting(false)
            }
            .frame(width: w, height: h)
            .animation(HueAnimation.normal, value: activeAxis)
            .contentShape(Rectangle())
            .gesture(wheelDrag(width: w, height: h))
            // Deliberate activation of the centred item. A tap opens
            // customization WITHOUT committing, which is what makes tapping an
            // already-selected room work — a commit-only design silently no-ops
            // there. The machine ignores taps while dragging or settling.
            .onTapGesture { perform(machine.apply(.tapCenter)) }
        }
    }

    // ── Single axis-locked drag driving both wheels ────────────────────

    private func wheelDrag(width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                // Detent crossings PREVIEW ONLY. Nothing here reaches the
                // parent: `.preview` is consumed inside `perform`.
                perform(machine.apply(
                    .dragChanged(dx: value.translation.width, dy: value.translation.height)))
            }
            .onEnded { value in
                beginSettle(
                    predictedDX: value.predictedEndTranslation.width,
                    predictedDY: value.predictedEndTranslation.height)
            }
    }

    /// Release → `.settling`. NO commit here: the spring's completion is what
    /// commits, which is what keeps the content below the wheel still while the
    /// wheel is visibly moving.
    private func beginSettle(predictedDX: CGFloat, predictedDY: CGFloat) {
        settleWatchdog?.cancel()
        settleWatchdog = nil

        let event = RolodexSelectionMachine.Event.dragEnded(
            predictedDX: predictedDX, predictedDY: predictedDY, reduceMotion: reduceMotion)

        if reduceMotion {
            // No spring to wait on. The machine runs the SAME settle rule
            // immediately, so there is no second timing path to drift.
            perform(machine.apply(event))
            return
        }

        var effects: [RolodexSelectionMachine.Effect] = []
        // `token` is assigned synchronously inside the animation body, so the
        // completion closure — which runs later — sees the settle it belongs to
        // and NOT whatever settle happens to be active by then. That is exactly
        // the stale-callback case the token exists for.
        var token: RolodexSettleToken?
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            effects = machine.apply(event)
            token = machine.activeSettleToken
        } completion: {
            if let token { perform(machine.apply(.settleFinished(token))) }
        }
        perform(effects)

        // Backstop: SwiftUI does not guarantee the completion runs if the
        // animation is interrupted, and a wheel stranded in `.settling` would
        // never commit again. The watchdog carries the same token, so once the
        // real completion has landed this is a no-op.
        if let token {
            settleWatchdog = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.settleWatchdogSeconds))
                guard !Task.isCancelled else { return }
                perform(machine.apply(.settleWatchdogFired(token)))
            }
        }
    }

    /// The active axis is fully opaque. The inactive axis keeps a clear "hole" over
    /// the center focus so its text never ghosts under the selected word — only
    /// distant peeks stay faintly visible.
    private func axisOpacity(active: Bool, pos: CGFloat, axis: Axis) -> Double {
        if active { return 1 }
        let clear: CGFloat = axis == .vertical ? lensHeight / 2 + 12 : lensWidth / 2 + 28
        let ramp: CGFloat = 40
        let t = min(1, max(0, (abs(pos) - clear) / ramp))
        return Double(t) * 0.18
    }

    /// The picker sheet. Deliberate in both senses — it commits AND opens
    /// customization, the opposite direction from a centre tap, so the two can
    /// never be silently swapped. Zones are searched before rooms, as before.
    private func select(_ item: RoomDisplayItem) {
        settleWatchdog?.cancel()
        settleWatchdog = nil
        var effects: [RolodexSelectionMachine.Effect] = []
        if let z = zones.firstIndex(where: { $0.id == item.id }) {
            withAnimation(HueAnimation.card) {
                effects = machine.apply(.pickerSelect(axis: .horizontal, index: z))
            }
        } else if let r = rooms.firstIndex(where: { $0.id == item.id }) {
            withAnimation(HueAnimation.card) {
                effects = machine.apply(.pickerSelect(axis: .vertical, index: r))
            }
        } else {
            // Not on either wheel — notify the parent as the legacy path did.
            onCommit(item)
            HapticManager.shared.selection()
            return
        }
        perform(effects)
    }

    // ── Shared cell ────────────────────────────────────────────────────

    /// `isCenter` = under the lens right now (may be a mid-drag preview).
    /// `isCommitted` = the selection that is actually in force. During a drag
    /// they differ, and the amber ring on the committed-but-off-centre item is
    /// what shows where releasing without moving would return you.
    private func wheelCell(
        item: RoomDisplayItem, isZone: Bool, isCenter: Bool, isCommitted: Bool
    ) -> some View {
        let running = runningEffects[RoomEffectKey(room: item)]
        return HStack(spacing: 7) {
            Image(systemName: isZone ? "square.3.layers.3d" : archetypeIcon(for: item.archetype))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isCenter ? HuePalette.amber : .white.opacity(0.82))
                .frame(width: 18)

            Text(item.name)
                .font(.system(size: 16, weight: isCenter ? .semibold : .medium))
                .foregroundStyle(isCenter ? .white : .white.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if running != nil {
                Circle().fill(running!.card.accentColor).frame(width: 5, height: 5)
            }
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .overlay(
            // Only while previewing: at rest the committed item IS the centred
            // one and the lens already frames it, so a ring would be noise.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(HuePalette.amber.opacity(0.55), lineWidth: 1)
                .opacity(isCommitted && !isCenter && machine.isPreviewing ? 1 : 0)
                .animation(HueAnimation.normal, value: machine.isPreviewing)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(isZone ? "zone" : "room"), \(item.lightCount) lights")
        .accessibilityAddTraits(isCenter ? [.isSelected, .isButton] : .isButton)
        // VoiceOver: activating the centred row opens customization. Before
        // this the row announced as a button and doing so did nothing at all.
        .accessibilityAction {
            if isCenter { perform(machine.apply(.tapCenter)) }
        }
    }

    // ──────────────────────────────────────────────────────────────────
    // MARK: - Chrome
    // ──────────────────────────────────────────────────────────────────

    /// The glowing center well — transparent so the wheel floats through it.
    private var selectionLens: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(HuePalette.amber.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [HuePalette.amber.opacity(0.85), HuePalette.amberDeep.opacity(0.45)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        // Dashed and thinner while the wheel is moving, solid
                        // when it has settled — the visual half of "this is a
                        // preview, nothing below has changed yet".
                        style: StrokeStyle(
                            lineWidth: machine.isPreviewing ? 1.0 : 1.25,
                            dash: machine.isPreviewing ? [4, 3] : [])
                    )
                    .animation(HueAnimation.normal, value: machine.isPreviewing)
            )
            .shadow(color: HuePalette.amber.opacity(0.28), radius: 12)
            .frame(width: lensWidth, height: lensHeight)
    }

    /// Faint amber hairline rails down + across the center — draws the "+" so the
    /// two-axis intent is unmistakable even before the user touches anything.
    private var crossRails: some View {
        ZStack {
            Rectangle()
                .fill(LinearGradient(colors: [.clear, HuePalette.amber.opacity(0.12), .clear],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 1)
            Rectangle()
                .fill(LinearGradient(colors: [.clear, HuePalette.amber.opacity(0.12), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Cylinder curvature modifier

private struct Cylinder: ViewModifier {
    let n: CGFloat          // -1 (edge) … 0 (center) … 1 (edge)
    let axis: Axis
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let c = min(max(n, -1), 1)
        let angle = reduceMotion ? 0 : Double(c) * 46
        return content
            .opacity(max(0.05, 1 - abs(c) * 0.92))
            .scaleEffect(1 - abs(c) * 0.12)
            .rotation3DEffect(
                .degrees(axis == .vertical ? -angle : angle),
                axis: axis == .vertical ? (x: 1, y: 0, z: 0) : (x: 0, y: 1, z: 0),
                perspective: 0.5
            )
    }
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - Rolodex selection machine (Track A / C3)
//
// C2 extracted today's behaviour verbatim. C3 corrects it, and does so in ONE
// commit because the settling phase, the generation token, the watchdog, the
// Reduce Motion path, the delayed commit and deliberate activation are a single
// correctness boundary — landing a subset would put incomplete selection
// semantics on `main`.
//
// The rule: PREVIEW DURING MOVEMENT, COMMIT AFTER THE WHEEL LOCKS.
//
// Three effects write `vm.selectedRoom`, and exactly one of them means the user
// chose. `.commit` is user intent. `.reconcileSelection` repairs a selection
// whose item vanished. `.applyExternalSelection` carries intent that originated
// elsewhere (Siri, a deep link). All three produce one selection write and one
// refresh cycle; only `.commit` may be counted as a user commit.
//
// `.preview` is INTERNAL. It is consumed by the rolodex's own view state and
// there is no closure that carries it to the parent — that is what makes
// "Studio gains no preview state" structural rather than a promise.
// ──────────────────────────────────────────────────────────────────────────

/// Pure detent arithmetic, lifted verbatim from the pre-C2 gesture handlers.
///
/// There is no momentum simulation and never was: `predictedEndTranslation` IS
/// the flick, and the spring is the settle. Preserving these two expressions
/// unchanged is what preserves the wheel's feel.
enum RolodexKinematics {

    /// The legacy `clampIndex` bound. A zero-count axis yields `-1`, exactly as
    /// before — every caller guards on a non-empty axis first.
    static func clamp(_ i: Int, count: Int) -> Int {
        min(max(i, 0), count - 1)
    }

    /// The detent under the lens for a live translation.
    /// Reproduces `clampIndex(CGFloat(base) - drag / step, count)`.
    static func liveIndex(base: Int, translation: CGFloat, step: CGFloat, count: Int) -> Int {
        clamp(Int((CGFloat(base) - translation / step).rounded()), count: count)
    }

    /// The flick-predicted settle detent. Reproduces the legacy `.onEnded`
    /// expression `min(max(Int((CGFloat(base) - predicted / step).rounded()), 0), count - 1)`.
    static func settleTarget(base: Int, predicted: CGFloat, step: CGFloat, count: Int) -> Int {
        clamp(Int((CGFloat(base) - predicted / step).rounded()), count: count)
    }
}

/// Opaque, wheel-local identity for one rolodex item.
///
/// TYPED FIELDS, not a delimiter-composed string — a "|" inside a bridge or
/// group id must not be able to alias two items. Indexes alone cannot survive a
/// roster reorder (3 → 8) and cannot disambiguate a duplicate Hue room id across
/// two bridges, which is why rebasing keys on this and uses indexes only for
/// geometry.
struct RolodexItemToken: Hashable {
    let bridgeID: String?
    let groupID: String
    let kind: RoomDisplayItem.Kind

    init(item: RoomDisplayItem) {
        self.bridgeID = item.bridgeID
        self.groupID = item.id
        self.kind = item.kind
    }
}

/// Identifies ONE settle operation.
///
/// The spring's completion callback and the watchdog both carry it, and a
/// callback whose token is not the active settle is dropped. Without this, a
/// stale animation completing after a new drag began, a roster change, or an
/// applied external selection would commit the WRONG selection.
struct RolodexSettleToken: Hashable {
    let generation: UInt64
}

/// The rolodex's interaction state.
///
/// The machine traffics in `Int`, `Axis` and opaque `RolodexItemToken`s only.
/// Tokens are minted by the PARENT from the full item identity, so the machine
/// can rebase across reorders and disambiguate duplicate room ids without
/// understanding bridges or playback identity — it cannot construct or degrade
/// an identity, and it has no route to a playback API.
struct RolodexSelectionMachine: Equatable {

    /// `committed` is deliberately DATA, not a phase. A phase carrying the same
    /// value would be a second source of truth — the bug this commit fixes.
    enum Phase: Equatable {
        case idle
        case dragging
        /// Previewing `target`; NO commit has happened yet.
        case settling(token: RolodexSettleToken, axis: Axis, target: Int)
    }

    enum Event {
        case dragChanged(dx: CGFloat, dy: CGFloat)
        /// Enters `.settling`. Emits a preview of the target and NEVER a commit —
        /// the commit waits for the wheel to actually stop.
        case dragEnded(predictedDX: CGFloat, predictedDY: CGFloat, reduceMotion: Bool)
        case settleFinished(RolodexSettleToken)
        case settleWatchdogFired(RolodexSettleToken)
        /// Deliberate activation of the centred item.
        case tapCenter
        /// The picker sheet — deliberate, so it commits AND activates.
        case pickerSelect(axis: Axis, index: Int)
        /// Siri, a deep link, or any selection made outside the wheel.
        case externalSelect(axis: Axis, index: Int)
        case rosterChanged(rooms: [RolodexItemToken], zones: [RolodexItemToken])
    }

    enum Effect: Equatable {
        case haptic
        /// WHEEL-LOCAL. Never leaves the view — there is no `onPreview`.
        case preview(axis: Axis, index: Int)
        /// → `vm.selectedRoom`. USER INTENT.
        case commit(axis: Axis, index: Int)
        /// → `vm.selectedRoom`. Repair after the selected item vanished.
        case reconcileSelection(axis: Axis, index: Int)
        /// → `vm.selectedRoom`. Intent that originated elsewhere.
        case applyExternalSelection(axis: Axis, index: Int)
        /// → opens customization for THIS exact item. Never a selection write.
        case activate(axis: Axis, index: Int)
    }

    let rowHeight: CGFloat
    let colWidth: CGFloat

    private(set) var phase: Phase = .idle
    private(set) var committedRoom: Int
    private(set) var committedZone: Int
    private(set) var liveRoom: Int
    private(set) var liveZone: Int
    private(set) var activeAxis: Axis
    private(set) var lockAxis: Axis?
    private(set) var translation: CGFloat = 0

    private(set) var roomTokens: [RolodexItemToken]
    private(set) var zoneTokens: [RolodexItemToken]

    /// An external selection that arrived while the finger was down or the
    /// wheel was still springing. Held by TOKEN so a roster change in the
    /// meantime cannot silently repoint it at a different item.
    private(set) var deferredExternal: (axis: Axis, token: RolodexItemToken)?

    private var settleGeneration: UInt64 = 0

    init(
        rowHeight: CGFloat,
        colWidth: CGFloat,
        activeAxis: Axis,
        committedRoom: Int,
        committedZone: Int,
        roomTokens: [RolodexItemToken] = [],
        zoneTokens: [RolodexItemToken] = []
    ) {
        self.rowHeight = rowHeight
        self.colWidth = colWidth
        self.activeAxis = activeAxis
        self.committedRoom = committedRoom
        self.committedZone = committedZone
        self.liveRoom = committedRoom
        self.liveZone = committedZone
        self.roomTokens = roomTokens
        self.zoneTokens = zoneTokens
    }

    static func == (lhs: RolodexSelectionMachine, rhs: RolodexSelectionMachine) -> Bool {
        lhs.phase == rhs.phase
            && lhs.committedRoom == rhs.committedRoom && lhs.committedZone == rhs.committedZone
            && lhs.liveRoom == rhs.liveRoom && lhs.liveZone == rhs.liveZone
            && lhs.activeAxis == rhs.activeAxis && lhs.lockAxis == rhs.lockAxis
            && lhs.translation == rhs.translation
            && lhs.roomTokens == rhs.roomTokens && lhs.zoneTokens == rhs.zoneTokens
            && lhs.deferredExternal?.axis == rhs.deferredExternal?.axis
            && lhs.deferredExternal?.token == rhs.deferredExternal?.token
            && lhs.settleGeneration == rhs.settleGeneration
    }

    // ── Reads ─────────────────────────────────────────────────────────

    /// The index the lens is over on the active axis.
    var activeIndex: Int { activeAxis == .vertical ? liveRoom : liveZone }

    /// The committed index on the active axis — the amber ring's home, so the
    /// user can see where releasing without moving would return them.
    var committedIndex: Int { activeAxis == .vertical ? committedRoom : committedZone }

    /// The index each wheel is DRAWN from on `axis`.
    ///
    /// `translation` is measured from this base, and `applyDragEnded` zeroes it the
    /// instant a settle begins — so during `.settling` the base must already BE the
    /// settle target. Drawing from `committedRoom` there (which does not move until
    /// the spring's completion commits) makes the spring carry the wheel back to the
    /// previously committed row, and the deferred commit then jumps it forward. That
    /// two-legged move is the build-47 snap-back.
    func renderBase(for axis: Axis) -> Int {
        if case let .settling(_, settleAxis, target) = phase, settleAxis == axis {
            return target
        }
        return axis == .vertical ? committedRoom : committedZone
    }

    /// The index wearing the committed marker on `axis`, or nil when there is no live
    /// "return here" answer.
    ///
    /// PRESERVED while dragging — that is exactly when the user needs to see where
    /// letting go unchanged would land them. SUPPRESSED while settling: the choice is
    /// made, and continuing to mark the old room presents a destination the wheel is
    /// no longer travelling to.
    func committedMarker(for axis: Axis) -> Int? {
        if case let .settling(_, settleAxis, _) = phase, settleAxis == axis {
            return nil
        }
        return axis == .vertical ? committedRoom : committedZone
    }

    /// True while the wheel is moving under a finger or still springing. The
    /// lens draws a dashed stroke here and a solid one at rest.
    var isPreviewing: Bool {
        if case .idle = phase { return false }
        return true
    }

    /// The settle currently awaiting its completion callback, if any. The view
    /// hands this back through the spring's completion and the watchdog.
    var activeSettleToken: RolodexSettleToken? {
        if case let .settling(token, _, _) = phase { return token }
        return nil
    }

    private func tokens(for axis: Axis) -> [RolodexItemToken] {
        axis == .vertical ? roomTokens : zoneTokens
    }

    private func count(for axis: Axis) -> Int { tokens(for: axis).count }

    // ── Events ────────────────────────────────────────────────────────

    @discardableResult
    mutating func apply(_ event: Event) -> [Effect] {
        switch event {
        case let .dragChanged(dx, dy):
            return applyDragChanged(dx: dx, dy: dy)

        case let .dragEnded(predictedDX, predictedDY, reduceMotion):
            return applyDragEnded(
                predictedDX: predictedDX, predictedDY: predictedDY, reduceMotion: reduceMotion)

        case let .settleFinished(token):
            return completeSettle(token)

        case let .settleWatchdogFired(token):
            // Identical rule to a real completion. The watchdog exists because
            // an interrupted or never-delivered SwiftUI completion would
            // otherwise strand the wheel in `.settling` forever, and a wheel
            // that never commits is worse than one that commits early.
            return completeSettle(token)

        case .tapCenter:
            // Deliberate activation. NOT a commit — folding activation into
            // `.commit` would make tapping an already-selected room a no-op,
            // and the customization surface would simply never open.
            guard case .idle = phase, count(for: activeAxis) > 0 else { return [] }
            return [.activate(axis: activeAxis, index: activeIndex)]

        case let .pickerSelect(axis, index):
            guard index >= 0, index < count(for: axis) else { return [] }
            phase = .idle
            deferredExternal = nil
            lockAxis = nil
            translation = 0
            activeAxis = axis
            setIndices(axis: axis, index: index)
            // The sheet IS deliberate: it commits and opens customization. This
            // is the opposite direction from `.tapCenter`, and the two must not
            // be silently swappable.
            return [.commit(axis: axis, index: index), .activate(axis: axis, index: index), .haptic]

        case let .externalSelect(axis, index):
            return applyExternalSelect(axis: axis, index: index)

        case let .rosterChanged(rooms, zones):
            return applyRosterChanged(rooms: rooms, zones: zones)
        }
    }

    // ── Drag ──────────────────────────────────────────────────────────

    private mutating func applyDragChanged(dx: CGFloat, dy: CGFloat) -> [Effect] {
        if lockAxis == nil {
            // Axis capture: >6pt on either axis, and it NEVER re-locks for the
            // life of the gesture.
            guard abs(dx) > 6 || abs(dy) > 6 else { return [] }
            lockAxis = abs(dx) > abs(dy) ? .horizontal : .vertical
            activeAxis = lockAxis!
            // A new drag abandons any settle in flight. The old token is no
            // longer active, so its completion and watchdog are both dropped —
            // this is what stops a stale settle committing over a new gesture.
            phase = .dragging
        }
        translation = lockAxis == .horizontal ? dx : dy
        return updateLive()
    }

    /// The detent tick. Haptic and a WHEEL-LOCAL preview — no commit, no
    /// parent-facing effect of any kind.
    private mutating func updateLive() -> [Effect] {
        var newRoom = liveRoom
        var newZone = liveZone
        if lockAxis == .vertical, count(for: .vertical) > 0 {
            newRoom = RolodexKinematics.liveIndex(
                base: committedRoom, translation: translation,
                step: rowHeight, count: count(for: .vertical))
        } else if lockAxis == .horizontal, count(for: .horizontal) > 0 {
            newZone = RolodexKinematics.liveIndex(
                base: committedZone, translation: translation,
                step: colWidth, count: count(for: .horizontal))
        }
        guard newRoom != liveRoom || newZone != liveZone else { return [] }
        liveRoom = newRoom
        liveZone = newZone
        return [.haptic, .preview(axis: activeAxis, index: activeIndex)]
    }

    private mutating func applyDragEnded(
        predictedDX: CGFloat, predictedDY: CGFloat, reduceMotion: Bool
    ) -> [Effect] {
        let axis = lockAxis ?? activeAxis
        let step = axis == .horizontal ? colWidth : rowHeight
        let predicted = axis == .horizontal ? predictedDX : predictedDY
        let base = axis == .horizontal ? committedZone : committedRoom
        let n = count(for: axis)
        lockAxis = nil
        translation = 0
        guard n > 0 else {
            phase = .idle
            return []
        }

        let target = RolodexKinematics.settleTarget(
            base: base, predicted: predicted, step: step, count: n)
        activeAxis = axis
        setLive(axis: axis, index: target)

        settleGeneration &+= 1
        let token = RolodexSettleToken(generation: settleGeneration)
        phase = .settling(token: token, axis: axis, target: target)

        // The finger lifting is NOT the commit. Everything below the wheel must
        // stay still while the wheel is visibly moving.
        var effects: [Effect] = [.preview(axis: axis, index: target)]

        if reduceMotion {
            // No spring to wait on, so the same settle rule runs immediately —
            // one code path, not a parallel "reduced" branch that could drift.
            effects += completeSettle(token)
        }
        return effects
    }

    // ── Settle completion — the ONLY drag-driven commit ───────────────

    private mutating func completeSettle(_ token: RolodexSettleToken) -> [Effect] {
        guard case let .settling(active, axis, target) = phase, active == token else {
            // Stale: a settle that was superseded by a new drag, a roster
            // change, or an applied external selection. Dropping it is the
            // whole point of the token.
            return []
        }
        phase = .idle

        if let deferred = deferredExternal {
            deferredExternal = nil
            // A deferred external selection SUPERSEDES the stale settle target.
            // Committing the target and then applying the external one would
            // switch the content twice and fire two refresh cycles. Exactly one
            // write, and it is NOT a user commit — the user did not choose this
            // by dragging.
            if let index = tokens(for: deferred.axis).firstIndex(of: deferred.token) {
                activeAxis = deferred.axis
                setIndices(axis: deferred.axis, index: index)
                return [.applyExternalSelection(axis: deferred.axis, index: index)]
            }
            // The deferred item vanished before we could apply it — fall
            // through and honour the settle rather than strand the wheel.
        }

        setCommitted(axis: axis, index: target)
        return [.commit(axis: axis, index: target)]
    }

    // ── External selection ────────────────────────────────────────────

    private mutating func applyExternalSelect(axis: Axis, index: Int) -> [Effect] {
        guard index >= 0, index < count(for: axis) else { return [] }
        switch phase {
        case .idle:
            // The parent already holds this selection — writing it back would
            // be circular. Snap the wheels and emit nothing. This replaces the
            // old `isSyncing` flag with a structural rule.
            activeAxis = axis
            setIndices(axis: axis, index: index)
            return []

        case .dragging, .settling:
            // Never yank the wheel out from under a finger or mid-spring. Held
            // by token and applied when the settle resolves.
            deferredExternal = (axis: axis, token: tokens(for: axis)[index])
            return []
        }
    }

    // ── Roster changes — rebased by TOKEN, never by index ─────────────

    private mutating func applyRosterChanged(
        rooms: [RolodexItemToken], zones: [RolodexItemToken]
    ) -> [Effect] {
        let previousRooms = roomTokens
        let previousZones = zoneTokens
        roomTokens = rooms
        zoneTokens = zones

        var effects: [Effect] = []

        // Rebase each axis independently. A committed item that merely MOVED
        // keeps its selection with no effect at all; only one that VANISHED
        // produces a repair — and a repair is never a user commit.
        let roomOutcome = rebase(
            axis: .vertical, previous: previousRooms, current: rooms,
            committed: committedRoom, live: liveRoom)
        committedRoom = roomOutcome.committed
        liveRoom = roomOutcome.live

        let zoneOutcome = rebase(
            axis: .horizontal, previous: previousZones, current: zones,
            committed: committedZone, live: liveZone)
        committedZone = zoneOutcome.committed
        liveZone = zoneOutcome.live

        let activeVanished = activeAxis == .vertical ? roomOutcome.vanished : zoneOutcome.vanished
        if activeVanished, count(for: activeAxis) > 0 {
            effects.append(.reconcileSelection(axis: activeAxis, index: committedIndex))
        }

        // A settle whose target moved must follow the token, and one whose
        // target vanished must not commit a stale index.
        if case let .settling(token, axis, target) = phase {
            let previous = axis == .vertical ? previousRooms : previousZones
            if target >= 0, target < previous.count,
               let moved = tokens(for: axis).firstIndex(of: previous[target]) {
                phase = .settling(token: token, axis: axis, target: moved)
                setLive(axis: axis, index: moved)
            } else {
                phase = .idle
            }
        }

        // A deferred external whose item vanished can never be applied.
        if let deferred = deferredExternal,
           !tokens(for: deferred.axis).contains(deferred.token) {
            deferredExternal = nil
        }

        return effects
    }

    private func rebase(
        axis: Axis, previous: [RolodexItemToken], current: [RolodexItemToken],
        committed: Int, live: Int
    ) -> (committed: Int, live: Int, vanished: Bool) {
        guard !current.isEmpty else { return (0, 0, !previous.isEmpty) }
        guard committed >= 0, committed < previous.count else {
            return (RolodexKinematics.clamp(committed, count: current.count),
                    RolodexKinematics.clamp(live, count: current.count),
                    false)
        }
        let committedToken = previous[committed]
        if let moved = current.firstIndex(of: committedToken) {
            // Identity survived a reorder — index 3 → 8 has no effect at all.
            let newLive: Int
            if live >= 0, live < previous.count,
               let movedLive = current.firstIndex(of: previous[live]) {
                newLive = movedLive
            } else {
                newLive = moved
            }
            return (moved, newLive, false)
        }
        // The committed item is gone. Re-centre on a survivor near where it was.
        let repaired = RolodexKinematics.clamp(committed, count: current.count)
        return (repaired, repaired, true)
    }

    // ── Index helpers ─────────────────────────────────────────────────

    private mutating func setIndices(axis: Axis, index: Int) {
        setCommitted(axis: axis, index: index)
        setLive(axis: axis, index: index)
    }

    private mutating func setCommitted(axis: Axis, index: Int) {
        if axis == .horizontal { committedZone = index } else { committedRoom = index }
    }

    private mutating func setLive(axis: Axis, index: Int) {
        if axis == .horizontal { liveZone = index } else { liveRoom = index }
    }
}

// MARK: - Preview

#if DEBUG
private extension RoomDisplayItem {
    static func mock(_ name: String, _ archetype: String, kind: Kind = .room, lights: Int = 3) -> RoomDisplayItem {
        RoomDisplayItem(
            kind: kind,
            id: "\(kind.rawValue)-\(name)",
            name: name,
            archetype: archetype,
            isOn: true,
            brightness: 80,
            groupedLightID: nil,
            lightCount: lights,
            bridgeID: nil,
            childResourceRefs: []
        )
    }
}

#Preview("Room Rolodex — floating inline") {
    let rooms: [RoomDisplayItem] = [
        .mock("Living Room", "living_room", lights: 6),
        .mock("Kitchen", "kitchen", lights: 4),
        .mock("Bedroom", "bedroom", lights: 3),
        .mock("Office", "office", lights: 2),
        .mock("Bathroom", "bathroom", lights: 2),
        .mock("Hallway", "hallway", lights: 1),
        .mock("Garage", "garage", lights: 2)
    ]
    let zones: [RoomDisplayItem] = [
        .mock("Downstairs", "downstairs", kind: .zone, lights: 12),
        .mock("Upstairs", "upstairs", kind: .zone, lights: 8),
        .mock("Movie Night", "tv", kind: .zone, lights: 5),
        .mock("Whole Home", "home", kind: .zone, lights: 20)
    ]
    return ZStack {
        HuePalette.Noir.background.ignoresSafeArea()
        VStack {
            RoomRolodexView(
                rooms: rooms, zones: zones,
                selectedRoom: rooms[1], runningEffects: [:],
                onCommit: { _ in }, onActivate: { _ in }
            )
            .padding(.horizontal, 16)
            Spacer()
        }
    }
    .preferredColorScheme(.dark)
}
#endif

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
    let onSelect: (RoomDisplayItem) -> Void

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
    // C2: the six `@State` scalars that used to live here (selRoom, selZone,
    // liveRoom, liveZone, lockAxis, activeAxis, drag) are now one machine. The
    // old `isSyncing` flag is gone with them: its only job was the `!isSyncing`
    // guard in `updateLive()`, and it could never be true during a drag —
    // `select(_:)` and the external-sync handler both set and cleared it
    // synchronously, with no gesture callback in between. The machine encodes
    // the same rule structurally: `.externalSync` emits nothing.
    @State private var machine: RolodexSelectionMachine
    @State private var didInit = false
    @State private var showListFallback = false

    init(
        rooms: [RoomDisplayItem],
        zones: [RoomDisplayItem],
        selectedRoom: RoomDisplayItem?,
        runningEffects: [RoomEffectKey: RunningEffect],
        onSelect: @escaping (RoomDisplayItem) -> Void
    ) {
        self.rooms = rooms
        self.zones = zones
        self.selectedRoom = selectedRoom
        self.runningEffects = runningEffects
        self.onSelect = onSelect

        let startAsZone = selectedRoom?.kind == .zone
        let r = rooms.firstIndex { $0.id == selectedRoom?.id } ?? 0
        let z = zones.firstIndex { $0.id == selectedRoom?.id } ?? 0
        _machine = State(initialValue: RolodexSelectionMachine(
            rowHeight: Self.rowHeightConst,
            colWidth: Self.colWidthConst,
            activeAxis: startAsZone ? .horizontal : .vertical,
            committedRoom: r,
            committedZone: z))
    }

    // ── Derived ───────────────────────────────────────────────────────
    private var selRoom: Int { machine.committedRoom }
    private var selZone: Int { machine.committedZone }
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

    /// Run the machine's effects against the outside world. This is the ONLY
    /// place the rolodex talks to its parent.
    private func perform(_ effects: [RolodexSelectionMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .haptic:
                HapticManager.shared.selection()
            case let .commit(axis, index):
                if let item = item(axis: axis, index: index) { onSelect(item) }
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
        // Keep the wheels aligned if the selection is changed from elsewhere.
        .onChange(of: selectedRoom?.id) { _, id in
            guard didInit, let id, id != activeID else { return }
            if let z = zones.firstIndex(where: { $0.id == id }) {
                withAnimation(HueAnimation.card) {
                    machine.apply(.externalSync(axis: .horizontal, index: z),
                                  roomCount: rooms.count, zoneCount: zones.count)
                }
            } else if let r = rooms.firstIndex(where: { $0.id == id }) {
                withAnimation(HueAnimation.card) {
                    machine.apply(.externalSync(axis: .vertical, index: r),
                                  roomCount: rooms.count, zoneCount: zones.count)
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
                    let pos = CGFloat(idx - selRoom) * rowHeight + roomDrag
                    if abs(pos) < h / 2 + rowHeight {
                        wheelCell(item: room, isZone: false, isCenter: idx == liveRoom && activeAxis == .vertical)
                            .frame(width: min(w, 300))
                            .offset(y: pos)
                            .modifier(Cylinder(n: pos / (h / 2), axis: .vertical, reduceMotion: reduceMotion))
                            .opacity(axisOpacity(active: activeAxis == .vertical, pos: pos, axis: .vertical))
                    }
                }

                // Horizontal ZONE wheel
                ForEach(Array(zones.enumerated()), id: \.element.id) { idx, zone in
                    let pos = CGFloat(idx - selZone) * colWidth + zoneDrag
                    if abs(pos) < w / 2 + colWidth {
                        wheelCell(item: zone, isZone: true, isCenter: idx == liveZone && activeAxis == .horizontal)
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
        }
    }

    // ── Single axis-locked drag driving both wheels ────────────────────

    private func wheelDrag(width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                perform(machine.apply(
                    .dragChanged(dx: value.translation.width, dy: value.translation.height),
                    roomCount: rooms.count, zoneCount: zones.count))
            }
            .onEnded { value in
                // Two transactions, preserved from the legacy shape: the spring
                // settles onto the predicted detent, and then `select(_:)` ran
                // its own `HueAnimation.card` transaction over the same indices.
                // The second one writes identical values, but it is what fires
                // the selection and the haptic, and it can retarget the
                // still-running spring — so C2 keeps both. C3 collapses them.
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    machine.apply(
                        .dragEnded(predictedDX: value.predictedEndTranslation.width,
                                   predictedDY: value.predictedEndTranslation.height),
                        roomCount: rooms.count, zoneCount: zones.count)
                }
                guard activeItem != nil else { return }   // zero-count axis: inert, as before
                var effects: [RolodexSelectionMachine.Effect] = []
                withAnimation(HueAnimation.card) {
                    effects = machine.apply(
                        .pickerSelect(axis: machine.activeAxis, index: machine.activeIndex),
                        roomCount: rooms.count, zoneCount: zones.count)
                }
                perform(effects)
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

    /// Commit a concrete item (from the list fallback) and sync the wheels.
    /// Zones are searched before rooms, exactly as before.
    private func select(_ item: RoomDisplayItem) {
        var effects: [RolodexSelectionMachine.Effect] = []
        if let z = zones.firstIndex(where: { $0.id == item.id }) {
            withAnimation(HueAnimation.card) {
                effects = machine.apply(.pickerSelect(axis: .horizontal, index: z),
                                        roomCount: rooms.count, zoneCount: zones.count)
            }
        } else if let r = rooms.firstIndex(where: { $0.id == item.id }) {
            withAnimation(HueAnimation.card) {
                effects = machine.apply(.pickerSelect(axis: .vertical, index: r),
                                        roomCount: rooms.count, zoneCount: zones.count)
            }
        } else {
            // Not on either wheel — the legacy code still notified the parent
            // and fired the haptic, so that is preserved verbatim.
            onSelect(item)
            HapticManager.shared.selection()
            return
        }
        perform(effects)
    }

    // ── Shared cell ────────────────────────────────────────────────────

    private func wheelCell(item: RoomDisplayItem, isZone: Bool, isCenter: Bool) -> some View {
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(isZone ? "zone" : "room"), \(item.lightCount) lights")
        .accessibilityAddTraits(isCenter ? [.isSelected, .isButton] : .isButton)
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
                        lineWidth: 1.25
                    )
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
// MARK: - Rolodex selection machine (Track A / C2)
//
// A MECHANICAL extraction of the gesture handlers above. This commit changes
// no behaviour: the machine still emits a selection event at every detent
// crossing, exactly as `updateLive()` did. There is no settling phase, no
// deliberate activation, no delayed commit, no settle token, no watchdog and no
// token-based rebasing — those are C3's, and putting any of them here would
// destroy this commit's value as a bisect anchor.
//
// `RolodexItemToken` is minted here but never consulted: C2 introduces it as
// DATA so C3 can key rebasing on it without also having to prove the minting.
// ──────────────────────────────────────────────────────────────────────────

/// Pure detent arithmetic, lifted verbatim from the gesture handlers.
///
/// There is no momentum simulation and never was: `predictedEndTranslation` IS
/// the flick, and the spring is the settle. Preserving these two expressions
/// unchanged is what preserves the wheel's feel.
enum RolodexKinematics {

    /// The legacy `clampIndex` bound. A zero-count axis yields `-1`, exactly as
    /// before — every caller guards on a non-empty axis first, and
    /// `RolodexSelectionMachine` keeps that guard.
    static func clamp(_ i: Int, count: Int) -> Int {
        min(max(i, 0), count - 1)
    }

    /// The detent under the lens for a live translation.
    /// Reproduces `clampIndex(CGFloat(base) - drag / step, count)`.
    static func liveIndex(base: Int, translation: CGFloat, step: CGFloat, count: Int) -> Int {
        clamp(Int((CGFloat(base) - translation / step).rounded()), count: count)
    }

    /// The flick-predicted settle detent. Reproduces the `.onEnded` expression
    /// `min(max(Int((CGFloat(base) - predicted / step).rounded()), 0), count - 1)`.
    static func settleTarget(base: Int, predicted: CGFloat, step: CGFloat, count: Int) -> Int {
        clamp(Int((CGFloat(base) - predicted / step).rounded()), count: count)
    }
}

/// Opaque, wheel-local identity for one rolodex item.
///
/// TYPED FIELDS, not a delimiter-composed string — a "|" inside a bridge or
/// group id must not be able to alias two items. Indexes alone cannot survive a
/// roster reorder and cannot disambiguate a duplicate Hue room id across two
/// bridges, which is why C3 will key rebasing on this rather than on position.
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

/// The rolodex's interaction state, extracted from `RoomRolodexView`'s `@State`.
///
/// Counts are passed per-event rather than stored: the view reads `rooms.count`
/// and `zones.count` live at gesture time, and a stored copy could go stale
/// against a roster change mid-drag.
struct RolodexSelectionMachine: Equatable {

    enum Event {
        case dragChanged(dx: CGFloat, dy: CGFloat)
        /// Settles onto the flick-predicted detent. Emits NOTHING — the legacy
        /// `.onEnded` ran its spring first and only then called `select(_:)`,
        /// and that second step is modelled by `.pickerSelect` below.
        case dragEnded(predictedDX: CGFloat, predictedDY: CGFloat)
        /// The legacy `select(_:)`: the picker sheet, and the end-of-drag
        /// re-application. Deliberate, so it commits.
        case pickerSelect(axis: Axis, index: Int)
        /// The legacy `.onChange(of: selectedRoom?.id)` sync. Aligns the wheels
        /// to a selection made elsewhere and emits nothing — this is what the
        /// old `isSyncing` flag existed to suppress.
        case externalSync(axis: Axis, index: Int)
    }

    enum Effect: Equatable {
        case haptic
        /// Writes `vm.selectedRoom`. In C2 this still fires per detent crossing,
        /// which IS the defect — C3 moves it behind settling.
        case commit(axis: Axis, index: Int)
    }

    let rowHeight: CGFloat
    let colWidth: CGFloat

    private(set) var committedRoom: Int
    private(set) var committedZone: Int
    private(set) var liveRoom: Int
    private(set) var liveZone: Int
    private(set) var activeAxis: Axis
    private(set) var lockAxis: Axis?
    private(set) var translation: CGFloat

    init(
        rowHeight: CGFloat,
        colWidth: CGFloat,
        activeAxis: Axis,
        committedRoom: Int,
        committedZone: Int
    ) {
        self.rowHeight = rowHeight
        self.colWidth = colWidth
        self.activeAxis = activeAxis
        self.committedRoom = committedRoom
        self.committedZone = committedZone
        self.liveRoom = committedRoom
        self.liveZone = committedZone
        self.lockAxis = nil
        self.translation = 0
    }

    /// The index the lens is over on the active axis.
    var activeIndex: Int { activeAxis == .vertical ? liveRoom : liveZone }

    @discardableResult
    mutating func apply(_ event: Event, roomCount: Int, zoneCount: Int) -> [Effect] {
        switch event {
        case let .dragChanged(dx, dy):
            // Axis capture: >6pt on either axis, and it NEVER re-locks for the
            // life of the gesture.
            if lockAxis == nil {
                guard abs(dx) > 6 || abs(dy) > 6 else { return [] }
                lockAxis = abs(dx) > abs(dy) ? .horizontal : .vertical
                activeAxis = lockAxis!
            }
            translation = lockAxis == .horizontal ? dx : dy
            return updateLive(roomCount: roomCount, zoneCount: zoneCount)

        case let .dragEnded(predictedDX, predictedDY):
            let axis = lockAxis ?? activeAxis
            let step = axis == .horizontal ? colWidth : rowHeight
            let predicted = axis == .horizontal ? predictedDX : predictedDY
            let base = axis == .horizontal ? committedZone : committedRoom
            let count = axis == .horizontal ? zoneCount : roomCount
            guard count > 0 else {
                lockAxis = nil
                translation = 0
                return []
            }
            let target = RolodexKinematics.settleTarget(
                base: base, predicted: predicted, step: step, count: count)
            if axis == .horizontal {
                committedZone = target; liveZone = target
            } else {
                committedRoom = target; liveRoom = target
            }
            activeAxis = axis
            translation = 0
            lockAxis = nil
            return []

        case let .pickerSelect(axis, index):
            activeAxis = axis
            if axis == .horizontal {
                committedZone = index; liveZone = index
            } else {
                committedRoom = index; liveRoom = index
            }
            return [.commit(axis: axis, index: index), .haptic]

        case let .externalSync(axis, index):
            activeAxis = axis
            if axis == .horizontal {
                committedZone = index; liveZone = index
            } else {
                committedRoom = index; liveRoom = index
            }
            return []
        }
    }

    /// The detent tick — `updateLive()`, unchanged. Haptic first, then the
    /// selection write, which is the order the legacy code fired them in.
    private mutating func updateLive(roomCount: Int, zoneCount: Int) -> [Effect] {
        var newRoom = liveRoom
        var newZone = liveZone
        if lockAxis == .vertical, roomCount > 0 {
            newRoom = RolodexKinematics.liveIndex(
                base: committedRoom, translation: translation, step: rowHeight, count: roomCount)
        } else if lockAxis == .horizontal, zoneCount > 0 {
            newZone = RolodexKinematics.liveIndex(
                base: committedZone, translation: translation, step: colWidth, count: zoneCount)
        }
        guard newRoom != liveRoom || newZone != liveZone else { return [] }
        liveRoom = newRoom
        liveZone = newZone
        return [.haptic, .commit(axis: activeAxis, index: activeIndex)]
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
                onSelect: { _ in }
            )
            .padding(.horizontal, 16)
            Spacer()
        }
    }
    .preferredColorScheme(.dark)
}
#endif

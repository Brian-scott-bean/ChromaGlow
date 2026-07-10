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
    let runningEffects: [String: RunningEffect]   // keyed by room/zone ID
    let onSelect: (RoomDisplayItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // ── Compact geometry ──────────────────────────────────────────────
    //
    // The stage shows exactly three room detents (96 = 3 × 32): the selection
    // in the lens plus one neighbour above and below, which is the least a
    // wheel can show and still read as a wheel. Studio's deck grid takes every
    // point this gives back, so the stage does not get to be generous.
    private let stageHeight:   CGFloat = 96        // the wheel viewport
    private let rowHeight:      CGFloat = 32        // vertical detent height
    private let colWidth:       CGFloat = 150       // horizontal detent width
    private let lensWidth:      CGFloat = 214
    private let lensHeight:     CGFloat = 36

    // ── Selection + drag state ────────────────────────────────────────
    @State private var selRoom = 0                  // committed room index
    @State private var selZone = 0                  // committed zone index
    @State private var liveRoom = 0                 // currently-centered room while dragging
    @State private var liveZone = 0                 // currently-centered zone while dragging
    @State private var lockAxis: Axis? = nil        // axis captured for the active drag
    @State private var activeAxis: Axis = .vertical // .vertical = a room, .horizontal = a zone
    @State private var drag: CGFloat = 0            // live translation along the active axis
    @State private var didInit = false
    @State private var isSyncing = false
    @State private var showListFallback = false

    init(
        rooms: [RoomDisplayItem],
        zones: [RoomDisplayItem],
        selectedRoom: RoomDisplayItem?,
        runningEffects: [String: RunningEffect],
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
        _activeAxis = State(initialValue: startAsZone ? .horizontal : .vertical)
        _selRoom = State(initialValue: r); _liveRoom = State(initialValue: r)
        _selZone = State(initialValue: z); _liveZone = State(initialValue: z)
    }

    // ── Derived ───────────────────────────────────────────────────────
    private var roomDrag: CGFloat { activeAxis == .vertical ? drag : 0 }
    private var zoneDrag: CGFloat { activeAxis == .horizontal ? drag : 0 }

    private var activeItem: RoomDisplayItem? {
        activeAxis == .vertical
            ? rooms[safe: liveRoom]
            : zones[safe: liveZone]
    }
    private var activeID: String? { activeItem?.id }

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
            isSyncing = true
            if let z = zones.firstIndex(where: { $0.id == id }) {
                activeAxis = .horizontal
                withAnimation(HueAnimation.card) { selZone = z; liveZone = z }
            } else if let r = rooms.firstIndex(where: { $0.id == id }) {
                activeAxis = .vertical
                withAnimation(HueAnimation.card) { selRoom = r; liveRoom = r }
            }
            isSyncing = false
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
                let dx = value.translation.width
                let dy = value.translation.height

                if lockAxis == nil {
                    guard abs(dx) > 6 || abs(dy) > 6 else { return }
                    lockAxis = abs(dx) > abs(dy) ? .horizontal : .vertical
                    activeAxis = lockAxis!
                }

                drag = lockAxis == .horizontal ? dx : dy
                updateLive()
            }
            .onEnded { value in
                let axis = lockAxis ?? activeAxis
                let step = axis == .horizontal ? colWidth : rowHeight
                let predicted = axis == .horizontal ? value.predictedEndTranslation.width : value.predictedEndTranslation.height
                let base = axis == .horizontal ? selZone : selRoom
                let count = axis == .horizontal ? zones.count : rooms.count
                guard count > 0 else { lockAxis = nil; drag = 0; return }

                let target = min(max(Int((CGFloat(base) - predicted / step).rounded()), 0), count - 1)

                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    if axis == .horizontal { selZone = target; liveZone = target }
                    else { selRoom = target; liveRoom = target }
                    drag = 0
                }

                let item = axis == .horizontal ? zones[safe: target] : rooms[safe: target]
                if let item { select(item) }
                lockAxis = nil
            }
    }

    /// Fires as each new item crosses the center during a drag — the detent tick.
    private func updateLive() {
        var newRoom = liveRoom, newZone = liveZone
        if lockAxis == .vertical, !rooms.isEmpty {
            newRoom = clampIndex(CGFloat(selRoom) - drag / rowHeight, rooms.count)
        } else if lockAxis == .horizontal, !zones.isEmpty {
            newZone = clampIndex(CGFloat(selZone) - drag / colWidth, zones.count)
        }
        guard newRoom != liveRoom || newZone != liveZone else { return }
        liveRoom = newRoom; liveZone = newZone
        HapticManager.shared.selection()
        if let item = activeItem, !isSyncing { onSelect(item) }
    }

    private func clampIndex(_ v: CGFloat, _ count: Int) -> Int {
        min(max(Int(v.rounded()), 0), count - 1)
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

    /// Commit a concrete item (from the list fallback or a snap) and sync the wheels.
    private func select(_ item: RoomDisplayItem) {
        isSyncing = true
        if let z = zones.firstIndex(where: { $0.id == item.id }) {
            activeAxis = .horizontal
            withAnimation(HueAnimation.card) { selZone = z; liveZone = z }
        } else if let r = rooms.firstIndex(where: { $0.id == item.id }) {
            activeAxis = .vertical
            withAnimation(HueAnimation.card) { selRoom = r; liveRoom = r }
        }
        onSelect(item)
        HapticManager.shared.selection()
        isSyncing = false
    }

    // ── Shared cell ────────────────────────────────────────────────────

    private func wheelCell(item: RoomDisplayItem, isZone: Bool, isCenter: Bool) -> some View {
        let running = runningEffects[item.id]
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

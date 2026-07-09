// HueHomeWidget.swift
// HueHome Pro — Epic 5 / Widget
//
// Home screen widget showing live room states.
// Sizes: Small (summary), Medium (room grid), Large (full list).
//
// Data flow:
//   getTimeline() → reads WidgetDataStore (UserDefaults / App Group)
//               → fires ONE grouped_light API call to refresh on/off states
//               → returns 15-minute timeline
//
// Design: dark ambient background, amber glow for ON rooms,
// matching the main app's glassmorphic language.

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline Entry

struct HueWidgetEntry: TimelineEntry {
    let date:         Date
    let rooms:        [WidgetRoomSnapshot]
    var zones:        [WidgetRoomSnapshot] = []
    var scenes:       [WidgetSceneSnapshot] = []
    let isPaired:     Bool
    var isStale:      Bool    = false
    var selectedRoomID: String? = nil
    var showPresets:  Bool    = true
    var showScenes:   Bool    = true
    /// Current page of the paginated Large widget (already clamped by the provider).
    var largePage:    Int     = 0

    /// Every controllable group (rooms first, then zones).
    var groups: [WidgetRoomSnapshot] { rooms + zones }

    /// Rooms + zones bucketed per bridge (for multi-bridge sections), sorted by
    /// bridge name so every bridge is represented and ordering is stable.
    struct BridgeSection: Identifiable {
        let id: String
        let name: String
        let rooms: [WidgetRoomSnapshot]
        let zones: [WidgetRoomSnapshot]
        var onCount: Int { rooms.filter(\.isOn).count }
        var total:   Int { rooms.count }
    }
    var bridgeSections: [BridgeSection] {
        var order: [String] = []
        var names: [String: String] = [:]
        var roomsBy: [String: [WidgetRoomSnapshot]] = [:]
        var zonesBy: [String: [WidgetRoomSnapshot]] = [:]
        func note(_ item: WidgetRoomSnapshot) -> String {
            let bid = item.bridgeID ?? "—"
            if names[bid] == nil { names[bid] = item.bridgeName ?? "Bridge"; order.append(bid) }
            return bid
        }
        for r in rooms { roomsBy[note(r), default: []].append(r) }
        for z in zones { zonesBy[note(z), default: []].append(z) }
        return order
            .map { BridgeSection(id: $0, name: names[$0] ?? "Bridge",
                                 rooms: roomsBy[$0] ?? [], zones: zonesBy[$0] ?? []) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
    /// True when rooms span more than one bridge.
    var isMultiBridge: Bool { Set(rooms.compactMap(\.bridgeID)).count > 1 }

    /// Up to `n` rooms picked round-robin across bridges, so a small/medium
    /// widget still surfaces every bridge instead of just the alphabetical first.
    func balancedRooms(max n: Int) -> [WidgetRoomSnapshot] {
        guard isMultiBridge else { return Array(rooms.prefix(n)) }
        let sections = bridgeSections
        var result: [WidgetRoomSnapshot] = []
        var idx = 0
        while result.count < n {
            var addedThisRound = false
            for s in sections where idx < s.rooms.count {
                result.append(s.rooms[idx]); addedThisRound = true
                if result.count >= n { break }
            }
            if !addedThisRound { break }
            idx += 1
        }
        return result
    }

    // ── Pagination (Large widget) ─────────────────────────────
    // WidgetKit can't scroll, so the Large widget pages through EVERY room and
    // zone across ALL bridges. Groups are clustered by bridge (sorted by name)
    // so a page reads as coherent, and a page can still span a bridge boundary.
    static let largePageSize = 6

    /// All groups in a stable, bridge-clustered order (rooms then zones per
    /// bridge). Single-bridge setups keep the plain rooms-then-zones order.
    var orderedGroups: [WidgetRoomSnapshot] {
        guard isMultiBridge else { return rooms + zones }
        return bridgeSections.flatMap { $0.rooms + $0.zones }
    }

    var largePageCount: Int {
        max(1, (orderedGroups.count + Self.largePageSize - 1) / Self.largePageSize)
    }

    /// The page index, defensively clamped for display.
    var clampedLargePage: Int { min(max(0, largePage), largePageCount - 1) }

    /// The slice of groups shown on the current Large page.
    var largePageGroups: [WidgetRoomSnapshot] {
        let start = clampedLargePage * Self.largePageSize
        guard start < orderedGroups.count else { return [] }
        let end = min(start + Self.largePageSize, orderedGroups.count)
        return Array(orderedGroups[start ..< end])
    }

    /// Name + on/total for a bridge (rooms *and* zones) — for inline page headers.
    func bridgeLabel(_ bridgeID: String?) -> (name: String, on: Int, total: Int) {
        let all = groups.filter { $0.bridgeID == bridgeID }
        return (all.first?.bridgeName ?? "Bridge", all.filter(\.isOn).count, all.count)
    }

    /// Summary counts stay room-based so overlapping zones don't double-count.
    var onCount:    Int { rooms.filter(\.isOn).count }
    var totalCount: Int { rooms.count }

    /// The pinned room or zone, if the widget is configured to focus on one.
    var selectedRoom: WidgetRoomSnapshot? {
        guard let id = selectedRoomID else { return nil }
        return groups.first { $0.id == id }
    }

    var displayRooms: [WidgetRoomSnapshot] {
        selectedRoom.map { [$0] } ?? rooms
    }

    /// Scenes for the pinned group (for the focused medium widget).
    var selectedScenes: [WidgetSceneSnapshot] {
        guard let g = selectedRoom else { return [] }
        return scenes.filter { $0.ownerGroupID == g.id && (g.bridgeID == nil || $0.bridgeID == g.bridgeID) }
    }

    /// Where a tap on the widget body (non-button) should deep-link.
    var deepLinkURL: URL? {
        if let g = selectedRoom {
            return URL(string: "lightshade://\(g.isZone ? "zone" : "room")/\(g.id)")
        }
        return URL(string: "lightshade://dashboard")
    }
}

// MARK: - Timeline Provider

struct HueWidgetProvider: AppIntentTimelineProvider {

    // ── Placeholder (shown while widget loads for the first time) ──
    func placeholder(in context: Context) -> HueWidgetEntry {
        HueWidgetEntry(date: .now, rooms: previewRooms, isPaired: true)
    }

    func snapshot(for configuration: SelectRoomIntent,
                  in context: Context) async -> HueWidgetEntry {
        if context.isPreview {
            return HueWidgetEntry(date: .now, rooms: previewRooms, isPaired: true,
                                  selectedRoomID: configuration.room?.id,
                                  showPresets: configuration.showPresets,
                                  showScenes: configuration.showScenes)
        }
        let store = WidgetDataStore.shared
        return HueWidgetEntry(date: .now, rooms: store.rooms, zones: store.zones,
                              scenes: store.scenes, isPaired: store.isPaired,
                              selectedRoomID: configuration.room?.id,
                              showPresets: configuration.showPresets,
                              showScenes: configuration.showScenes,
                              largePage: store.largePage)
    }

    // ── Timeline (called on schedule + after WidgetCenter.reloadAll) ──
    // Round-2 Item 3 (blurry/redacted widget): this must ALWAYS return fast
    // and must NEVER return a `.never` policy — a slow/crashing/frozen
    // timeline is exactly what WidgetKit renders as the blurred placeholder.
    func timeline(for configuration: SelectRoomIntent,
                  in context: Context) async -> Timeline<HueWidgetEntry> {
        let store = WidgetDataStore.shared
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now)
            ?? .now.addingTimeInterval(15 * 60)
        let selectedID  = configuration.room?.id

        guard store.isPaired else {
            // Genuinely unpaired. `.never` used to freeze this entry forever;
            // the blob-change reload usually revives it, but keep a slow timed
            // backstop so a missed/throttled reload cannot strand the widget.
            let entry = HueWidgetEntry(date: .now, rooms: [], isPaired: false,
                                       selectedRoomID: selectedID)
            return Timeline(entries: [entry],
                            policy: .after(.now.addingTimeInterval(60 * 60)))
        }

        // Every bridge we can reach — the refresh fans out across ALL of them so
        // rooms/zones on non-primary bridges stay live too, not just the first.
        let targets: [WidgetBridgeCredentials] = {
            let all = Array(store.bridges.values)
            if !all.isEmpty { return all }
            if let p = store.primaryCredentials() { return [p] }
            return []
        }()

        guard !targets.isEmpty else {
            // Paired per the routing metadata, but the shared-Keychain
            // credentials are unreadable right now (device before first
            // unlock, transient Keychain hiccup). This is NOT "unpaired" —
            // serve the cached snapshot and retry soon.
            let entry = HueWidgetEntry(date: .now, rooms: store.rooms, zones: store.zones,
                                       scenes: store.scenes, isPaired: true,
                                       isStale: true, selectedRoomID: selectedID,
                                       showPresets: configuration.showPresets,
                                       showScenes: configuration.showScenes,
                                       largePage: Self.clampedPage(store, count: store.groups.count))
            return Timeline(entries: [entry],
                            policy: .after(.now.addingTimeInterval(15 * 60)))
        }

        // Refresh grouped_light states with ONE bounded call PER bridge, run
        // CONCURRENTLY so wall-clock ≈ the slowest single bridge (not the sum) —
        // an unreachable bridge still costs at most `budget`, never stalling the
        // build into WidgetKit throttling.
        var freshGL: [WidgetAPIClient.GLData] = []
        await withTaskGroup(of: [WidgetAPIClient.GLData]?.self) { group in
            for creds in targets {
                group.addTask {
                    await WidgetAPIClient.fetchGroupedLightsBounded(
                        ip: creds.ip, token: creds.token, budget: 4
                    )
                }
            }
            for await result in group {
                if let result { freshGL.append(contentsOf: result) }
            }
        }

        var rooms = store.rooms
        var zones = store.zones
        if !freshGL.isEmpty {
            // Never trap on duplicate ids — a crash here leaves the redacted snapshot.
            let glMap = Dictionary(freshGL.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            func merge(_ list: [WidgetRoomSnapshot]) -> [WidgetRoomSnapshot] {
                list.map { item in
                    var r = item
                    if let gl = item.groupedLightId.flatMap({ glMap[$0] }) {
                        r.isOn       = gl.on.on
                        r.brightness = gl.dimming?.brightness ?? r.brightness
                    }
                    return r
                }
            }
            rooms = merge(rooms)
            zones = merge(zones)
            store.write(rooms: rooms, zones: zones, scenes: store.scenes)
        }

        let entry = HueWidgetEntry(
            date: .now, rooms: rooms, zones: zones, scenes: store.scenes, isPaired: true,
            isStale: rooms.isEmpty && zones.isEmpty, selectedRoomID: selectedID,
            showPresets: configuration.showPresets, showScenes: configuration.showScenes,
            largePage: Self.clampedPage(store, count: rooms.count + zones.count)
        )
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }

    /// Keep the shared Large-widget page index in range as the device count
    /// changes (rooms added/removed), and hand the clamped value to the entry.
    static func clampedPage(_ store: WidgetDataStore, count: Int) -> Int {
        let pages   = max(1, (count + HueWidgetEntry.largePageSize - 1) / HueWidgetEntry.largePageSize)
        let clamped = min(max(0, store.largePage), pages - 1)
        if clamped != store.largePage { store.largePage = clamped }
        return clamped
    }

    // ── Preview data ──
    private var previewRooms: [WidgetRoomSnapshot] {[
        WidgetRoomSnapshot(id:"1", name:"Living Room", archetype:"living_room",  isOn:true,  brightness:85, lightCount:3, groupedLightId:nil),
        WidgetRoomSnapshot(id:"2", name:"Kitchen",     archetype:"kitchen",      isOn:false, brightness:100,lightCount:2, groupedLightId:nil),
        WidgetRoomSnapshot(id:"3", name:"Bedroom",     archetype:"bedroom",      isOn:false, brightness:60, lightCount:1, groupedLightId:nil),
        WidgetRoomSnapshot(id:"4", name:"Office",      archetype:"office",       isOn:true,  brightness:70, lightCount:2, groupedLightId:nil),
    ]}
}

// MARK: - Entry View (dispatcher)

struct HueHomeWidgetEntryView: View {
    var entry: HueWidgetEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        // ── Lock screen ──────────────────────────
        case .accessoryCircular:    AccessoryCircularView(entry: entry)
        case .accessoryRectangular: AccessoryRectangularView(entry: entry)
        case .accessoryInline:      AccessoryInlineView(entry: entry)
        // ── Home screen ──────────────────────────
        default:
            if let room = entry.selectedRoom {
                switch family {
                case .systemSmall:  FocusedSmallWidgetView(room: room, entry: entry)
                case .systemMedium: FocusedMediumWidgetView(room: room, entry: entry)
                default:            LargeWidgetView(entry: entry)
                }
            } else {
                switch family {
                case .systemSmall:  SmallWidgetView(entry: entry)
                case .systemMedium: MediumWidgetView(entry: entry)
                default:            LargeWidgetView(entry: entry)
                }
            }
        }
    }
}

// MARK: - Small Widget  (2 × 2)

struct SmallWidgetView: View {
    let entry: HueWidgetEntry
    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 5) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(amber)
                Text("CastChroma")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            if !entry.isPaired {
                // Not paired state
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.4))
                Text("Open app to pair")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
            } else {
                // Big count
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text("\(entry.onCount)")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(entry.onCount > 0 ? amber : .white.opacity(0.3))
                    Text("on")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.bottom, 2)
                }

                Text(entry.onCount == 0
                     ? "All lights off"
                     : "of \(entry.totalCount) rooms")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.40))
                    .padding(.bottom, 6)

                // All Off button (interactive — iOS 17)
                Button(intent: AllOffIntent()) {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                            .font(.system(size: 9, weight: .semibold))
                        Text("All Off")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(amber))
                    .tapTargetHeight(34)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)

                // Top ON room names
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entry.rooms.filter(\.isOn).prefix(2)) { room in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(amber)
                                .frame(width: 5, height: 5)
                                .shadow(color: amber.opacity(0.9), radius: 3)
                            Text(room.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetBackground(amber: amber)
    }
}

// MARK: - Medium Widget  (4 × 2)

struct MediumWidgetView: View {
    let entry: HueWidgetEntry
    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header bar
            HStack {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(amber)
                Text("CastChroma")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                // On count badge
                if entry.isPaired {
                    HStack(spacing: 4) {
                        Text("\(entry.onCount) on")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(entry.onCount > 0 ? amber : .white.opacity(0.35))
                        Circle()
                            .fill(entry.onCount > 0 ? amber : Color.white.opacity(0.2))
                            .frame(width: 7, height: 7)
                            .shadow(color: entry.onCount > 0 ? amber.opacity(0.9) : .clear, radius: 5)
                    }
                }
            }

            if !entry.isPaired {
                Spacer()
                Label("Open app to connect", systemImage: "link.badge.plus")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
            } else {
                // Room grid — up to 4 rooms in 2 × 2 (balanced across bridges)
                let displayed = entry.balancedRooms(max: 4)
                let chunked   = stride(from: 0, to: displayed.count, by: 2).map {
                    Array(displayed[$0 ..< min($0 + 2, displayed.count)])
                }
                VStack(spacing: 6) {
                    ForEach(chunked.indices, id: \.self) { rowIdx in
                        HStack(spacing: 8) {
                            ForEach(chunked[rowIdx]) { room in
                                MediumRoomCell(room: room, amber: amber)
                            }
                        }
                    }
                    // Preset chips strip
                    if entry.showPresets {
                        WidgetPresetStrip(amber: amber)
                    }
                }
            }
        }
        .widgetBackground(amber: amber)
    }
}

struct MediumRoomCell: View {
    let room: WidgetRoomSnapshot
    let amber: Color

    var body: some View {
        Button(intent: ToggleRoomIntent(roomID: room.id, currentlyOn: room.isOn)) {
            cellBody
        }
        .buttonStyle(.plain)
    }

    private var cellBody: some View {
        HStack(spacing: 8) {
            // Archetype icon
            Image(systemName: widgetArchetypeIcon(room.archetype))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(room.isOn ? amber : .white.opacity(0.3))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(room.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(room.isOn ? .white : .white.opacity(0.45))
                    .lineLimit(1)

                if room.isOn {
                    // Brightness bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.1))
                                .frame(height: 3)
                            Capsule()
                                .fill(amber.opacity(0.8))
                                .frame(width: geo.size.width * CGFloat(room.brightness / 100), height: 3)
                        }
                    }
                    .frame(height: 3)
                } else {
                    Text("Off")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(room.isOn
                      ? amber.opacity(0.12)
                      : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(room.isOn ? amber.opacity(0.3) : Color.white.opacity(0.08), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Large Widget  (4 × 4)

struct LargeWidgetView: View {
    let entry: HueWidgetEntry
    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(amber)
                Text("CastChroma")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                if entry.isPaired {
                    Text("\(entry.onCount) / \(entry.totalCount) on")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(entry.onCount > 0 ? amber : .white.opacity(0.35))
                }
            }

            Divider()
                .background(Color.white.opacity(0.1))

            if !entry.isPaired {
                Spacer()
                Label("Open app to connect your Hue Bridge", systemImage: "link.badge.plus")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
            } else {
                // ── Paginated list: every room + zone across every bridge is
                //    reachable via ◀ / ▶ (WidgetKit can't scroll). Groups are
                //    bridge-clustered; a slim bridge header marks each boundary.
                let page  = entry.largePageGroups
                let multi = entry.isMultiBridge
                VStack(spacing: 4) {
                    ForEach(Array(page.enumerated()), id: \.element.id) { idx, g in
                        if multi, idx == 0 || page[idx - 1].bridgeID != g.bridgeID {
                            let label = entry.bridgeLabel(g.bridgeID)
                            HStack(spacing: 5) {
                                Image(systemName: "wifi.router")
                                    .font(.system(size: 8, weight: .semibold))
                                Text(label.name.uppercased())
                                    .font(.system(size: 8, weight: .bold))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(label.on)/\(label.total)")
                                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            }
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.top, 1)
                        }
                        LargeRoomRow(room: g, amber: amber)
                    }
                }

                Spacer(minLength: 2)

                // Page controls (only when there's more than one page).
                if entry.largePageCount > 1 {
                    LargePageBar(entry: entry, amber: amber)
                        .padding(.top, 1)
                }

                // Preset "effects" strip.
                if entry.showPresets {
                    WidgetPresetStrip(amber: amber)
                        .padding(.top, 2)
                }
            }
        }
        .widgetBackground(amber: amber)
    }
}

struct LargeRoomRow: View {
    let room: WidgetRoomSnapshot
    let amber: Color

    /// Tapping the icon/name deep-links into that room/zone for editing.
    private var roomURL: URL {
        URL(string: "lightshade://\(room.isZone ? "zone" : "room")/\(room.id)")
            ?? URL(string: "lightshade://dashboard")!
    }

    var body: some View {
        HStack(spacing: 6) {
            Link(destination: roomURL) {
                HStack(spacing: 6) {
                    Image(systemName: widgetArchetypeIcon(room.archetype))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(room.isOn ? amber : .white.opacity(0.25))
                        .frame(width: 18)

                    Text(room.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(room.isOn ? .white : .white.opacity(0.4))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 2)

            // Brightness −/+ (each turns the group on; clamped 1–100)
            Button(intent: AdjustBrightnessIntent(roomID: room.id, delta: -20)) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .tapTarget(30)
            }
            .buttonStyle(.plain)

            Text(room.isOn ? "\(Int(room.brightness))%" : "Off")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(room.isOn ? amber.opacity(0.75) : .white.opacity(0.25))
                .frame(width: 30)

            Button(intent: AdjustBrightnessIntent(roomID: room.id, delta: 20)) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .tapTarget(30)
            }
            .buttonStyle(.plain)

            // Interactive toggle button
            Button(intent: ToggleRoomIntent(roomID: room.id, currentlyOn: room.isOn)) {
                Image(systemName: room.isOn ? "power.circle.fill" : "power.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(room.isOn ? amber : .white.opacity(0.3))
                    .tapTarget(30)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Large Page Bar (◀ / page x of y / ▶)

struct LargePageBar: View {
    let entry: HueWidgetEntry
    let amber: Color

    private var page: Int  { entry.clampedLargePage }
    private var count: Int { entry.largePageCount }

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: WidgetPageIntent(direction: -1, pageSize: HueWidgetEntry.largePageSize)) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(page > 0 ? amber : .white.opacity(0.2))
                    .frame(width: 30, height: 22)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                    .tapTarget(width: 44, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(page == 0)

            Spacer()

            Text("Page \(page + 1) of \(count) · \(entry.groups.count) lights")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)

            Spacer()

            Button(intent: WidgetPageIntent(direction: 1, pageSize: HueWidgetEntry.largePageSize)) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(page < count - 1 ? amber : .white.opacity(0.2))
                    .frame(width: 30, height: 22)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                    .tapTarget(width: 44, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(page >= count - 1)
        }
    }
}

// MARK: - Preset Strip (shared by Medium + Large)

struct WidgetPresetStrip: View {
    let amber: Color

    private struct Preset {
        let id: String; let icon: String; let label: String; let color: Color
    }
    private let presets: [Preset] = [
        Preset(id: "energize", icon: "bolt.fill",       label: "Energize", color: Color(hue:0.58,saturation:0.7,brightness:1.0)),
        Preset(id: "read",     icon: "book.fill",       label: "Read",     color: Color(hue:0.12,saturation:0.6,brightness:1.0)),
        Preset(id: "relax",    icon: "moon.stars.fill", label: "Relax",    color: Color(hue:0.09,saturation:0.8,brightness:0.9)),
        Preset(id: "sleep",    icon: "zzz",             label: "Sleep",    color: Color(hue:0.07,saturation:0.7,brightness:0.7)),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(presets, id: \.id) { p in
                Button(intent: ApplyPresetIntent(presetID: p.id)) {
                    HStack(spacing: 3) {
                        Image(systemName: p.icon)
                            .font(.system(size: 8, weight: .semibold))
                        Text(p.label)
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(p.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(p.color.opacity(0.15)))
                    // Medium and Large are both near-full vertically; 26 is what
                    // the tighter of the two (Medium) can spare.
                    .overlay(Capsule().strokeBorder(p.color.opacity(0.3), lineWidth: 0.5))
                    .tapTargetHeight(26)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Scene Strip (pinned group's scenes)

struct WidgetSceneStrip: View {
    let scenes: [WidgetSceneSnapshot]
    let groupID: String
    let amber: Color

    var body: some View {
        HStack(spacing: 6) {
            ForEach(scenes.prefix(3)) { scene in
                let color = sceneChipColor(scene.name)
                Button(intent: ActivateSceneIntent(sceneID: scene.id, bridgeID: scene.bridgeID, groupID: groupID)) {
                    HStack(spacing: 3) {
                        Image(systemName: sceneChipIcon(scene.name))
                            .font(.system(size: 8, weight: .semibold))
                        Text(scene.name)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(color.opacity(0.15)))
                    .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 0.5))
                    .tapTargetHeight(32)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Focused Small Widget (single pinned room)

struct FocusedSmallWidgetView: View {
    let room:  WidgetRoomSnapshot
    let entry: HueWidgetEntry
    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: widgetArchetypeIcon(room.archetype))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(room.isOn ? amber : .white.opacity(0.4))
                Text(room.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer()
                Button(intent: ToggleRoomIntent(roomID: room.id, currentlyOn: room.isOn)) {
                    Image(systemName: room.isOn ? "power.circle.fill" : "power.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(room.isOn ? amber : .white.opacity(0.3))
                        .tapTarget(30)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // systemSmall is 130pt wide inside its padding: a 34pt readout plus
            // two buttons caps each button near 30pt.
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(room.isOn ? "\(Int(room.brightness))%" : "Off")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(room.isOn ? amber : .white.opacity(0.3))
                Spacer()
                Button(intent: AdjustBrightnessIntent(roomID: room.id, delta: -20)) {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .tapTarget(30)
                }
                .buttonStyle(.plain)
                Button(intent: AdjustBrightnessIntent(roomID: room.id, delta: 20)) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .tapTarget(30)
                }
                .buttonStyle(.plain)
            }

            Text("\(room.lightCount) bulb\(room.lightCount == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.top, 2)

            if room.isOn {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08)).frame(height: 3)
                        Capsule()
                            .fill(LinearGradient(colors: [amber.opacity(0.6), amber],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * CGFloat(room.brightness / 100), height: 3)
                    }
                }
                .frame(height: 3)
                .padding(.top, 6)
            }
        }
        .widgetBackground(amber: room.isOn ? amber : .white)
    }
}

// MARK: - Focused Medium Widget (single pinned room, expanded)

struct FocusedMediumWidgetView: View {
    let room:  WidgetRoomSnapshot
    let entry: HueWidgetEntry
    private let amber = Color(red: 1.0, green: 0.76, blue: 0.20)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: icon + name (+ zone tag) + power toggle
            HStack(spacing: 8) {
                Image(systemName: widgetArchetypeIcon(room.archetype))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(room.isOn ? amber : .white.opacity(0.3))
                VStack(alignment: .leading, spacing: 1) {
                    Text(room.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(room.isZone ? "Zone" : "\(room.lightCount) bulb\(room.lightCount == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                Button(intent: ToggleRoomIntent(roomID: room.id, currentlyOn: room.isOn)) {
                    Image(systemName: room.isOn ? "power.circle.fill" : "power.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(room.isOn ? amber : .white.opacity(0.3))
                        .tapTarget(44)
                }
                .buttonStyle(.plain)
            }

            // Brightness row: − [bar/%] +
            HStack(spacing: 8) {
                Button(intent: AdjustBrightnessIntent(roomID: room.id, delta: -20)) {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                        .tapTarget(40)
                }
                .buttonStyle(.plain)

                ZStack(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule().fill(Color.white.opacity(0.1)).frame(height: 5)
                        Capsule()
                            .fill(LinearGradient(colors: [amber.opacity(0.6), amber],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * CGFloat((room.isOn ? room.brightness : 0) / 100), height: 5)
                    }
                    .frame(height: 5)
                }
                .frame(maxWidth: .infinity)

                Text(room.isOn ? "\(Int(room.brightness))%" : "Off")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(room.isOn ? amber.opacity(0.85) : .white.opacity(0.3))
                    .frame(width: 34, alignment: .trailing)

                Button(intent: AdjustBrightnessIntent(roomID: room.id, delta: 20)) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                        .tapTarget(40)
                }
                .buttonStyle(.plain)
            }

            // Scene chips for this group
            if entry.showScenes, !entry.selectedScenes.isEmpty {
                WidgetSceneStrip(scenes: entry.selectedScenes, groupID: room.id, amber: amber)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetBackground(amber: room.isOn ? amber : .white)
    }
}

// MARK: - Widget Declaration

struct HueHomeWidget: Widget {
    let kind = "com.lightshade.app.HueHomeWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectRoomIntent.self,
            provider: HueWidgetProvider()
        ) { entry in
            HueHomeWidgetEntryView(entry: entry)
                .widgetURL(entry.deepLinkURL)
        }
        .configurationDisplayName("CastChroma")
        .description("Control lights, apply presets, and monitor rooms right from your home screen.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline
        ])
    }
}

// MARK: - Tap targets
//
// Apple's minimum is 44×44pt. A widget's canvas is fixed, so that isn't always
// reachable: the Large family stacks 6 rows + a page bar + a preset strip into
// ~326pt, and Focused-Small must fit a 34pt percentage readout plus two buttons
// across 130pt. These helpers grow the HIT area around unchanged artwork; each
// call site passes the largest size its family can afford. Raise LargeRoomRow
// past ~30pt only after lowering `HueWidgetEntry.largePageSize`.

extension View {
    /// Square hit area of `side`×`side`, centered on the existing glyph.
    func tapTarget(_ side: CGFloat) -> some View {
        frame(width: side, height: side).contentShape(Rectangle())
    }

    /// Rectangular hit area — for chevrons and other non-square controls.
    func tapTarget(width: CGFloat, height: CGFloat) -> some View {
        frame(width: width, height: height).contentShape(Rectangle())
    }

    /// Pill/chip buttons: grow the vertical hit area, let width stay intrinsic.
    func tapTargetHeight(_ height: CGFloat) -> some View {
        frame(minHeight: height).contentShape(Rectangle())
    }
}

// MARK: - Background helper (iOS 17 containerBackground vs padding/background)

extension View {
    func widgetBackground(amber: Color) -> some View {
        if #available(iOS 17.0, *) {
            return self
                .padding(14)
                .containerBackground(for: .widget) {
                    ZStack {
                        Color(red: 0.055, green: 0.055, blue: 0.08)
                        // Ambient amber orb (top left)
                        Circle()
                            .fill(RadialGradient(
                                colors: [amber.opacity(0.22), .clear],
                                center: .center, startRadius: 0, endRadius: 100
                            ))
                            .frame(width: 160)
                            .offset(x: -60, y: -60)
                            .blur(radius: 14)
                    }
                }
                .eraseToAnyView()
        } else {
            return self
                .padding(14)
                .background(
                    ZStack {
                        Color(red: 0.055, green: 0.055, blue: 0.08)
                        Circle()
                            .fill(amber.opacity(0.15))
                            .frame(width: 140)
                            .offset(x: -50, y: -50)
                            .blur(radius: 14)
                    }
                )
                .eraseToAnyView()
        }
    }

    func eraseToAnyView() -> AnyView { AnyView(self) }
}

// MARK: - Archetype Icon (widget-local copy — no UIKit dependency)

func widgetArchetypeIcon(_ archetype: String?) -> String {
    switch archetype?.lowercased() {
    case "living_room":          return "sofa.fill"
    case "kitchen":              return "fork.knife"
    case "dining":               return "fork.knife.circle.fill"
    case "bedroom", "kids_bedroom": return "bed.double.fill"
    case "bathroom":             return "shower.fill"
    case "office", "computer":   return "desktopcomputer"
    case "gym":                  return "dumbbell.fill"
    case "hallway":              return "door.left.hand.open"
    case "garage":               return "car.fill"
    case "terrace", "garden":    return "leaf.fill"
    case "recreation":           return "gamecontroller.fill"
    case "lounge":               return "chair.fill"
    case "tv":                   return "tv.fill"
    case "studio", "music":      return "music.note"
    case "laundry_room":         return "washer.fill"
    case "balcony", "porch":     return "sun.horizon.fill"
    default:                     return "lightbulb.fill"
    }
}

// Compact scene name → color / icon (widget-local; mirrors the app's palette).
func sceneChipColor(_ name: String) -> Color {
    let n = name.lowercased()
    if n.contains("relax")   { return Color(red: 1.0, green: 0.60, blue: 0.20) }
    if n.contains("energize"){ return Color(red: 0.25, green: 0.70, blue: 1.0) }
    if n.contains("read")    { return Color(red: 1.0, green: 0.88, blue: 0.50) }
    if n.contains("bright")  { return Color(red: 1.0, green: 0.95, blue: 0.70) }
    if n.contains("night") || n.contains("sleep") { return Color(red: 0.45, green: 0.30, blue: 0.80) }
    if n.contains("party") || n.contains("disco") { return Color(red: 0.90, green: 0.20, blue: 0.85) }
    if n.contains("fire") || n.contains("warm")   { return Color(red: 1.0, green: 0.45, blue: 0.15) }
    if n.contains("ocean") || n.contains("cool")  { return Color(red: 0.0, green: 0.75, blue: 0.85) }
    return Color(red: 0.60, green: 0.40, blue: 0.90)
}

func sceneChipIcon(_ name: String) -> String {
    let n = name.lowercased()
    if n.contains("relax")   { return "moon.stars.fill" }
    if n.contains("energize"){ return "bolt.fill" }
    if n.contains("read")    { return "book.fill" }
    if n.contains("bright")  { return "sun.max.fill" }
    if n.contains("sleep")   { return "zzz" }
    if n.contains("night")   { return "moon.fill" }
    if n.contains("party") || n.contains("disco") { return "music.note" }
    if n.contains("fire") || n.contains("warm")   { return "flame.fill" }
    if n.contains("ocean")   { return "water.waves" }
    return "wand.and.stars"
}
// MARK: - Lock Screen: Accessory Circular

/// Shown as a circular complication on the iOS lock screen.
/// Displays a Gauge arc filled by the fraction of rooms that are on,
/// with the lightbulb icon in the center. When a room is pinned it
/// shows that room's brightness gauge instead.
struct AccessoryCircularView: View {
    let entry: HueWidgetEntry

    var body: some View {
        if let room = entry.selectedRoom {
            // Pinned room — TAP TOGGLES it (lock-screen control); the gauge
            // still shows its brightness. iOS 17+ interactive accessory widget.
            Button(intent: ToggleRoomIntent(roomID: room.id, currentlyOn: room.isOn)) {
                Gauge(value: room.isOn ? room.brightness / 100 : 0) {
                    Image(systemName: room.isOn ? widgetArchetypeIcon(room.archetype) : "power")
                        .widgetAccentable()
                } currentValueLabel: {
                    Text(room.isOn ? "\(Int(room.brightness))" : "off")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .widgetAccentable()
            }
            .buttonStyle(.plain)
        } else {
            // All rooms — on/off fraction
            let fraction = entry.totalCount > 0
                ? Double(entry.onCount) / Double(entry.totalCount)
                : 0
            Gauge(value: fraction) {
                Image(systemName: "lightbulb.fill")
                    .widgetAccentable()
            } currentValueLabel: {
                Text("\(entry.onCount)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        }
    }
}

// MARK: - Lock Screen: Accessory Rectangular

/// Wide rectangle on the lock screen — fits 3 compact room rows.
/// When a room is pinned it shows that room's name, status, and brightness bar.
struct AccessoryRectangularView: View {
    let entry: HueWidgetEntry

    var body: some View {
        if let room = entry.selectedRoom {
            // Pinned room/zone — with an interactive power toggle (iOS 17+).
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Label(room.name, systemImage: widgetArchetypeIcon(room.archetype))
                        .font(.system(size: 13, weight: .semibold))
                        .widgetAccentable()
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Button(intent: ToggleRoomIntent(roomID: room.id, currentlyOn: room.isOn)) {
                        Image(systemName: room.isOn ? "power.circle.fill" : "power.circle")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .widgetAccentable(room.isOn)
                }

                // Interactive −/+ brightness (iOS 17+) + readout.
                HStack(spacing: 8) {
                    Button(intent: AdjustBrightnessIntent(roomID: room.id, delta: -20)) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.plain)

                    Text(room.isOn ? "\(Int(room.brightness))%" : "Off")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Button(intent: AdjustBrightnessIntent(roomID: room.id, delta: 20)) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                .widgetAccentable(room.isOn)

                if room.isOn {
                    // Compact brightness bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.secondary.opacity(0.3)).frame(height: 3)
                            Capsule()
                                .fill(.primary)
                                .frame(width: geo.size.width * CGFloat(room.brightness / 100), height: 3)
                                .widgetAccentable()
                        }
                    }
                    .frame(height: 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // All rooms — top 3 by on-state
            let display = entry.rooms.sorted { $0.isOn && !$1.isOn }.prefix(3)
            VStack(alignment: .leading, spacing: 2) {
                Label("HueHome • \(entry.onCount) on", systemImage: "lightbulb.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .widgetAccentable()
                ForEach(display) { room in
                    HStack {
                        Image(systemName: widgetArchetypeIcon(room.archetype))
                            .font(.system(size: 9))
                            .foregroundStyle(room.isOn ? .primary : .secondary)
                            .widgetAccentable(room.isOn)
                        Text(room.name)
                            .font(.system(size: 11))
                            .foregroundStyle(room.isOn ? .primary : .secondary)
                            .lineLimit(1)
                        Spacer()
                        Text(room.isOn ? "\(Int(room.brightness))%" : "—")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Lock Screen: Accessory Inline

/// Single line of text at the very top of the lock screen.
struct AccessoryInlineView: View {
    let entry: HueWidgetEntry

    var body: some View {
        if let room = entry.selectedRoom {
            Label(
                room.isOn ? "\(room.name) \(Int(room.brightness))%" : "\(room.name) off",
                systemImage: widgetArchetypeIcon(room.archetype)
            )
            .widgetAccentable(room.isOn)
        } else {
            Label(
                entry.onCount == 0
                    ? "All lights off"
                    : "\(entry.onCount) room\(entry.onCount == 1 ? "" : "s") on",
                systemImage: entry.onCount > 0 ? "lightbulb.fill" : "lightbulb.slash.fill"
            )
            .widgetAccentable(entry.onCount > 0)
        }
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    HueHomeWidget()
} timeline: {
    HueWidgetEntry(date: .now,
                   rooms: [
                    WidgetRoomSnapshot(id:"1", name:"Living Room", archetype:"living_room", isOn:true,  brightness:85, lightCount:3, groupedLightId:nil),
                    WidgetRoomSnapshot(id:"2", name:"Office",      archetype:"office",      isOn:true,  brightness:70, lightCount:2, groupedLightId:nil),
                    WidgetRoomSnapshot(id:"3", name:"Bedroom",     archetype:"bedroom",     isOn:false, brightness:60, lightCount:1, groupedLightId:nil),
                   ], isPaired: true)
}

#Preview("Medium", as: .systemMedium) {
    HueHomeWidget()
} timeline: {
    HueWidgetEntry(date: .now,
                   rooms: [
                    WidgetRoomSnapshot(id:"1", name:"Living Room", archetype:"living_room", isOn:true,  brightness:85, lightCount:3, groupedLightId:nil),
                    WidgetRoomSnapshot(id:"2", name:"Kitchen",     archetype:"kitchen",     isOn:false, brightness:100,lightCount:2, groupedLightId:nil),
                    WidgetRoomSnapshot(id:"3", name:"Bedroom",     archetype:"bedroom",     isOn:false, brightness:60, lightCount:1, groupedLightId:nil),
                    WidgetRoomSnapshot(id:"4", name:"Office",      archetype:"office",      isOn:true,  brightness:70, lightCount:2, groupedLightId:nil),
                   ], isPaired: true)
}

private let previewSnapshot = HueWidgetEntry(
    date: .now,
    rooms: [
        WidgetRoomSnapshot(id:"1", name:"Living Room", archetype:"living_room", isOn:true,  brightness:85, lightCount:3, groupedLightId:nil),
        WidgetRoomSnapshot(id:"2", name:"Kitchen",     archetype:"kitchen",     isOn:false, brightness:100,lightCount:2, groupedLightId:nil),
        WidgetRoomSnapshot(id:"3", name:"Bedroom",     archetype:"bedroom",     isOn:false, brightness:60, lightCount:1, groupedLightId:nil),
        WidgetRoomSnapshot(id:"4", name:"Office",      archetype:"office",      isOn:true,  brightness:70, lightCount:2, groupedLightId:nil),
    ],
    isPaired: true
)

#Preview("Lock Screen: Circular", as: .accessoryCircular) {
    HueHomeWidget()
} timeline: { previewSnapshot }

#Preview("Lock Screen: Rectangular", as: .accessoryRectangular) {
    HueHomeWidget()
} timeline: { previewSnapshot }

#Preview("Lock Screen: Inline", as: .accessoryInline) {
    HueHomeWidget()
} timeline: { previewSnapshot }

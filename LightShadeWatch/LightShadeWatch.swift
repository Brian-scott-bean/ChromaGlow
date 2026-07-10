// LightShadeWatch.swift
// LightShade — watchOS Widget Extension
//
// Provides four watch face complication styles + Smart Stack entry:
//   • accessoryCircular    — Gauge arc: fraction of rooms on, lightbulb center
//   • accessoryRectangular — Pinned room status OR top-3 rooms list
//   • accessoryCorner      — Mini icon + on-count text (watch-only)
//   • accessoryInline      — Single line: "4 on · Relax" or "Living Room 85%"
//
// Data: reads from App Group (group.com.huehome.pro) written by the iOS app.
// Refreshes every 15 minutes via timeline, or instantly when iOS app updates.

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline Entry

struct WatchEntry: TimelineEntry {
    let date:           Date
    let rooms:          [WatchRoomSnapshot]
    var zones:          [WatchRoomSnapshot] = []
    let isPaired:       Bool
    let selectedRoomID: String?

    // Summary counts stay room-based so overlapping zones don't double-count.
    var onCount:  Int { rooms.filter(\.isOn).count }
    var total:    Int { rooms.count }

    var selectedRoom: WatchRoomSnapshot? {
        guard let id = selectedRoomID else { return nil }
        return (rooms + zones).first { $0.id == id }
    }
}

// MARK: - Provider

struct WatchProvider: AppIntentTimelineProvider {

    func placeholder(in context: Context) -> WatchEntry {
        WatchEntry(date: .now, rooms: previewRooms, isPaired: true, selectedRoomID: nil)
    }

    func snapshot(for config: WatchConfigIntent, in context: Context) async -> WatchEntry {
        let store = WatchWidgetStore.shared
        return WatchEntry(
            date:           .now,
            rooms:          context.isPreview ? previewRooms : store.rooms,
            zones:          context.isPreview ? [] : store.zones,
            isPaired:       context.isPreview ? true : store.isPaired,
            selectedRoomID: config.room?.id
        )
    }

    func timeline(for config: WatchConfigIntent, in context: Context) async -> Timeline<WatchEntry> {
        let store  = WatchWidgetStore.shared
        let next   = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        let entry  = WatchEntry(
            date:           .now,
            rooms:          store.rooms,
            zones:          store.zones,
            isPaired:       store.isPaired,
            selectedRoomID: config.room?.id
        )
        return Timeline(entries: [entry], policy: .after(next))
    }

    func recommendations() -> [AppIntentRecommendation<WatchConfigIntent>] {
        [AppIntentRecommendation(intent: WatchConfigIntent(), description: "All Lights")]
    }

    private var previewRooms: [WatchRoomSnapshot] {[
        WatchRoomSnapshot(id:"1", name:"Living Room", archetype:"living_room", isOn:true,  brightness:85, lightCount:3, groupedLightId:nil),
        WatchRoomSnapshot(id:"2", name:"Kitchen",     archetype:"kitchen",     isOn:false, brightness:100,lightCount:2, groupedLightId:nil),
        WatchRoomSnapshot(id:"3", name:"Bedroom",     archetype:"bedroom",     isOn:false, brightness:60, lightCount:1, groupedLightId:nil),
        WatchRoomSnapshot(id:"4", name:"Office",      archetype:"office",      isOn:true,  brightness:70, lightCount:2, groupedLightId:nil),
    ]}
}

// MARK: - Entry View (dispatcher)

struct LightShadeWatchEntryView: View {
    var entry: WatchEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:    CircularView(entry: entry)
        case .accessoryRectangular: RectangularView(entry: entry)
        #if os(watchOS)
        case .accessoryCorner:      CornerView(entry: entry)
        #endif
        default:                    InlineView(entry: entry)
        }
    }
}

// MARK: - Circular (gauge arc — most common watch face slot)

struct CircularView: View {
    let entry: WatchEntry

    // `.accessoryCircularCapacity` renders the ring and the currentValueLabel
    // ONLY; a Gauge's `label` is never drawn in this style, so the icon that
    // used to live there never appeared. Icon + value share currentValueLabel
    // now, and `label` remains for VoiceOver.
    var body: some View {
        if let room = entry.selectedRoom {
            // Pinned room: brightness gauge
            Gauge(value: room.brightness / 100) {
                Text(room.name)
            } currentValueLabel: {
                VStack(spacing: -1) {
                    Image(systemName: watchArchetypeIcon(room.archetype))
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(Int(room.brightness))")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        } else {
            // All rooms: fraction on
            let fraction = entry.total > 0
                ? Double(entry.onCount) / Double(entry.total) : 0
            Gauge(value: fraction) {
                Text("Lights on")
            } currentValueLabel: {
                VStack(spacing: -1) {
                    Image(systemName: entry.onCount > 0 ? "lightbulb.fill" : "lightbulb.slash")
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(entry.onCount)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        }
    }
}

// MARK: - Rectangular (wide bar — shows most detail)

struct RectangularView: View {
    let entry: WatchEntry

    var body: some View {
        if let room = entry.selectedRoom {
            // Single pinned room
            VStack(alignment: .leading, spacing: 3) {
                Label(room.name, systemImage: watchArchetypeIcon(room.archetype))
                    .font(.system(size: 13, weight: .semibold))
                    .widgetAccentable()
                    .lineLimit(1)

                Text(room.isOn
                     ? "\(Int(room.brightness))% · \(room.lightCount) bulb\(room.lightCount == 1 ? "" : "s")"
                     : "Lights off")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if room.isOn {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.secondary.opacity(0.25)).frame(height: 3)
                            Capsule()
                                .fill(.primary)
                                .frame(width: geo.size.width * room.brightness / 100, height: 3)
                                .widgetAccentable()
                        }
                    }
                    .frame(height: 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // All rooms — show top 3
            let display = entry.rooms.sorted { $0.isOn && !$1.isOn }.prefix(3)
            VStack(alignment: .leading, spacing: 3) {
                Label("ChromaGlow · \(entry.onCount) on", systemImage: "lightbulb.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .widgetAccentable()
                    .lineLimit(1)
                ForEach(display) { room in
                    HStack(spacing: 4) {
                        Image(systemName: watchArchetypeIcon(room.archetype))
                            .font(.system(size: 9))
                            .widgetAccentable(room.isOn)
                        Text(room.name)
                            .font(.system(size: 10))
                            .foregroundStyle(room.isOn ? .primary : .secondary)
                            .lineLimit(1)
                        Spacer()
                        Text(room.isOn ? "\(Int(room.brightness))%" : "—")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Corner (watch-only slot — bottom corners of watch face)

#if os(watchOS)
struct CornerView: View {
    let entry: WatchEntry

    var body: some View {
        if let room = entry.selectedRoom {
            Image(systemName: watchArchetypeIcon(room.archetype))
                .widgetAccentable(room.isOn)
                .widgetLabel {
                    Text(room.isOn ? "\(Int(room.brightness))%" : "Off")
                }
        } else {
            Image(systemName: entry.onCount > 0 ? "lightbulb.fill" : "lightbulb.slash")
                .widgetAccentable(entry.onCount > 0)
                .widgetLabel {
                    Text("\(entry.onCount) on")
                }
        }
    }
}
#endif

// MARK: - Inline (single line at top of watch face)

struct InlineView: View {
    let entry: WatchEntry

    var body: some View {
        if let room = entry.selectedRoom {
            Label(
                room.isOn ? "\(room.name) \(Int(room.brightness))%" : "\(room.name) off",
                systemImage: watchArchetypeIcon(room.archetype)
            )
            .widgetAccentable(room.isOn)
        } else {
            Label(
                entry.onCount == 0 ? "All off" : "\(entry.onCount) of \(entry.total) on",
                systemImage: entry.onCount > 0 ? "lightbulb.fill" : "lightbulb.slash"
            )
            .widgetAccentable(entry.onCount > 0)
        }
    }
}

// MARK: - Widget Declaration

struct LightShadeWatch: Widget {
    let kind = "com.lightshade.app.WatchWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: WatchConfigIntent.self,
            provider: WatchProvider()
        ) { entry in
            LightShadeWatchEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("ChromaGlow")
        .description("Monitor and control your lights from your wrist.")
        #if os(watchOS)
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner,
        ])
        #else
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
        #endif
    }
}

// MARK: - Scenes Widget (second kind — no migration of existing face configs)

struct WatchSceneEntry: TimelineEntry {
    let date:     Date
    let isPaired: Bool
    /// The room whose scenes are shown: the pinned room, else the first
    /// group that has scenes at all.
    let room:     WatchRoomSnapshot?
    let scenes:   [WatchSceneSnapshot]
}

struct WatchSceneProvider: AppIntentTimelineProvider {

    func placeholder(in context: Context) -> WatchSceneEntry {
        WatchSceneEntry(date: .now, isPaired: true,
                        room: previewSceneRoom, scenes: previewScenes)
    }

    func snapshot(for config: WatchConfigIntent, in context: Context) async -> WatchSceneEntry {
        context.isPreview
            ? WatchSceneEntry(date: .now, isPaired: true,
                              room: previewSceneRoom, scenes: previewScenes)
            : makeEntry(config: config)
    }

    func timeline(for config: WatchConfigIntent, in context: Context) async -> Timeline<WatchSceneEntry> {
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        return Timeline(entries: [makeEntry(config: config)], policy: .after(next))
    }

    func recommendations() -> [AppIntentRecommendation<WatchConfigIntent>] {
        [AppIntentRecommendation(intent: WatchConfigIntent(), description: "Scenes")]
    }

    private func makeEntry(config: WatchConfigIntent) -> WatchSceneEntry {
        let store = WatchWidgetStore.shared
        let room: WatchRoomSnapshot?
        if let pinnedID = config.room?.id {
            room = store.groups.first { $0.id == pinnedID }
        } else {
            // First group that actually has scenes — an empty face helps nobody.
            room = store.groups.first { !store.scenes(forGroup: $0.id).isEmpty }
                ?? store.rooms.first
        }
        return WatchSceneEntry(
            date:     .now,
            isPaired: store.isPaired,
            room:     room,
            scenes:   room.map { store.scenes(forGroup: $0.id) } ?? []
        )
    }

    private var previewSceneRoom: WatchRoomSnapshot {
        WatchRoomSnapshot(id: "1", name: "Living Room", archetype: "living_room",
                          isOn: true, brightness: 85, lightCount: 3, groupedLightId: nil)
    }
    private var previewScenes: [WatchSceneSnapshot] {[
        WatchSceneSnapshot(id: "s1", name: "Relax",    ownerGroupID: "1", bridgeID: "b"),
        WatchSceneSnapshot(id: "s2", name: "Energize", ownerGroupID: "1", bridgeID: "b"),
        WatchSceneSnapshot(id: "s3", name: "Nightlight", ownerGroupID: "1", bridgeID: "b"),
    ]}
}

/// Display-only (watchOS accessory complications are non-interactive):
/// a tap opens the watch app straight into the room, which lists and
/// recalls these scenes.
struct WatchSceneEntryView: View {
    var entry: WatchSceneEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            if family == .accessoryInline {
                inline
            } else {
                rectangular
            }
        }
        .widgetURL(deepLink)
    }

    private var deepLink: URL? {
        guard let room = entry.room else { return nil }
        return URL(string: "lightshade://group/\(room.id)")
    }

    private var inline: some View {
        Label(
            entry.room.map { "\($0.name) · \(entry.scenes.count) scene\(entry.scenes.count == 1 ? "" : "s")" }
                ?? "No scenes yet",
            systemImage: "theatermasks.fill"
        )
    }

    @ViewBuilder
    private var rectangular: some View {
        if let room = entry.room, !entry.scenes.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Label(room.name, systemImage: "theatermasks.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .widgetAccentable()
                    .lineLimit(1)
                ForEach(entry.scenes.prefix(2)) { scene in
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Text(scene.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                }
                if entry.scenes.count > 2 {
                    Text("+\(entry.scenes.count - 2) more · tap to open")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Label("Scenes", systemImage: "theatermasks.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .widgetAccentable()
                Text(entry.isPaired
                     ? "No scenes synced yet — open ChromaGlow on your iPhone."
                     : "Open ChromaGlow on your iPhone to sync.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct LightShadeWatchScenes: Widget {
    let kind = "com.lightshade.app.WatchSceneWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: WatchConfigIntent.self,
            provider: WatchSceneProvider()
        ) { entry in
            WatchSceneEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("ChromaGlow Scenes")
        .description("A room's scenes at a glance — tap to open and recall.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Archetype Icons

private func watchArchetypeIcon(_ archetype: String?) -> String {
    switch archetype?.lowercased() {
    case "living_room":              return "sofa.fill"
    case "kitchen":                  return "fork.knife"
    case "bedroom", "kids_bedroom":  return "bed.double.fill"
    case "bathroom":                 return "shower.fill"
    case "office", "computer":       return "desktopcomputer"
    case "gym":                      return "dumbbell.fill"
    case "hallway":                  return "door.left.hand.open"
    case "garage":                   return "car.fill"
    case "terrace", "garden":        return "leaf.fill"
    case "tv":                       return "tv.fill"
    case "studio", "music":          return "music.note"
    default:                         return "lightbulb.fill"
    }
}

// MARK: - Previews

private let previewEntry = WatchEntry(
    date: .now,
    rooms: [
        WatchRoomSnapshot(id:"1", name:"Living Room", archetype:"living_room", isOn:true,  brightness:85, lightCount:3, groupedLightId:nil),
        WatchRoomSnapshot(id:"2", name:"Kitchen",     archetype:"kitchen",     isOn:false, brightness:100,lightCount:2, groupedLightId:nil),
        WatchRoomSnapshot(id:"3", name:"Office",      archetype:"office",      isOn:true,  brightness:70, lightCount:2, groupedLightId:nil),
    ],
    isPaired: true,
    selectedRoomID: nil
)

#Preview("Circular", as: .accessoryCircular)       { LightShadeWatch() } timeline: { previewEntry }
#Preview("Rectangular", as: .accessoryRectangular)  { LightShadeWatch() } timeline: { previewEntry }
#Preview("Inline", as: .accessoryInline)            { LightShadeWatch() } timeline: { previewEntry }
#if os(watchOS)
#Preview("Corner", as: .accessoryCorner)            { LightShadeWatch() } timeline: { previewEntry }
#endif

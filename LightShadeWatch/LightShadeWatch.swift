// LightShadeWatch.swift
// LightShade — watchOS Widget Extension
//
// Provides four watch face complication styles + Smart Stack entry:
//   • accessoryCircular    — Gauge arc: fraction of rooms on, lightbulb center
//   • accessoryRectangular — Pinned room status OR top-3 rooms list
//   • accessoryCorner      — Mini icon + on-count text (watch-only)
//   • accessoryInline      — Single line: "4 on · Relax" or "Living Room 85%"
//
// Data: reads from App Group (group.com.lightshade.app) written by the iOS app.
// Refreshes every 15 minutes via timeline, or instantly when iOS app updates.

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline Entry

struct WatchEntry: TimelineEntry {
    let date:           Date
    let rooms:          [WatchRoomSnapshot]
    let isPaired:       Bool
    let selectedRoomID: String?

    var onCount:  Int { rooms.filter(\.isOn).count }
    var total:    Int { rooms.count }

    var selectedRoom: WatchRoomSnapshot? {
        guard let id = selectedRoomID else { return nil }
        return rooms.first { $0.id == id }
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

    var body: some View {
        if let room = entry.selectedRoom {
            // Pinned room: brightness gauge
            Gauge(value: room.brightness / 100) {
                Image(systemName: watchArchetypeIcon(room.archetype))
                    .widgetAccentable()
            } currentValueLabel: {
                Text("\(Int(room.brightness))")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        } else {
            // All rooms: fraction on
            let fraction = entry.total > 0
                ? Double(entry.onCount) / Double(entry.total) : 0
            Gauge(value: fraction) {
                Image(systemName: entry.onCount > 0 ? "lightbulb.fill" : "lightbulb.slash")
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
                Label("CastChroma · \(entry.onCount) on", systemImage: "lightbulb.fill")
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
        .configurationDisplayName("CastChroma")
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

// Composer2LightHeightsView.swift
// ChromaGlow — UI/Composer2 ("the room is the band", step 3: build 917)
//
// Play Along → Light heights: which of the room's lights are low (floor
// lamps), middle (eye height) and high (ceiling). ChromaGlow starts from the
// Hue Bridge's heights when the area has them, else from each light's
// product type; a choice here wins and is kept on this phone.

import SwiftUI

struct Composer2LightHeightsView: View {
    struct Entry: Identifiable, Equatable {
        let id: String          // light id
        let name: String
        let resolved: Composer2LightRole
        let source: Composer2LightRoles.Source
    }

    @State private var entries: [Entry] = []
    @State private var version: UInt64 = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Light heights")
                        .font(.system(.title2, design: .rounded).weight(.heavy))
                        .foregroundStyle(LuminousPalette.ink)
                    Text("Low lights carry the kick and the bass, high lights the snare and the cymbals.")
                        .font(.subheadline)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                }

                if entries.isEmpty {
                    Text("Start a look in a room to set its lights' heights.")
                        .font(.subheadline)
                        .foregroundStyle(LuminousPalette.inkSecondary)
                } else {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.name).font(.headline).foregroundStyle(LuminousPalette.ink)
                                Spacer(minLength: 8)
                                Text(caption(entry.source))
                                    .font(.footnote)
                                    .foregroundStyle(LuminousPalette.inkSecondary)
                            }
                            LuminousSegmented(options: Composer2LightRole.allCases,
                                              selection: binding(entry),
                                              title: { $0.title },
                                              accessibilityLabel: "\(entry.name) height")
                        }
                    }
                    if !Composer2LightRoles.canSplit(entries.map(\.resolved)) {
                        Label("Set at least one light low and one high for the drums to split across the room.",
                              systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(LuminousPalette.inkSecondary)
                    }
                }

                Label("Kept on this phone. Your Hue Bridge's own light positions aren't changed.",
                      systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(LuminousPalette.inkSecondary)
            }
            .padding(20)
        }
        .background(LuminousPalette.night.ignoresSafeArea())
        .onAppear(perform: reload)
    }

    private func binding(_ entry: Entry) -> Binding<Composer2LightRole> {
        Binding(get: { entries.first { $0.id == entry.id }?.resolved ?? entry.resolved },
                set: { role in
                    HapticManager.shared.selection()
                    Composer2LightRoles.setAnswer(role, lightID: entry.id)
                    reload()
                })
    }

    private func caption(_ source: Composer2LightRoles.Source) -> String {
        switch source {
        case .answer: return "Set by you"
        case .bridge: return "From your Hue Bridge"
        case .product: return "From the light's type"
        case .unknown: return "Guessed"
        }
    }

    /// The room's lights, one row per light (a strip's segments share one).
    private func reload() {
        entries = Self.entries(layout: Composer2PlaybackCenter.shared.document?.roomContext.layout ?? .empty,
                               live: Composer2PlaybackCenter.shared.output?.liveSlots ?? [])
    }

    /// Lights from the look's layout, heights from the live Entertainment
    /// slots when they're running (the bridge's z), else from the layout.
    static func entries(layout: Composer2SlotLayout, live: [CompositionRenderSlot]) -> [Entry] {
        let answers = Composer2LightRoles.answers()
        var liveRoles: [String: (Composer2LightRole, Composer2LightRoles.Source)] = [:]
        for (slot, r) in zip(live, Composer2LightRoles.resolve(live, answers: answers)) {
            if let id = slot.lightID, liveRoles[id] == nil { liveRoles[id] = (r.role, r.source) }
        }
        var seen = Set<String>()
        var out: [Entry] = []
        for (slot, r) in zip(layout.slots, layout.roles) {
            guard let id = slot.lightID, seen.insert(id).inserted else { continue }
            let resolved = liveRoles[id] ?? (r.role, r.source)
            out.append(Entry(id: id, name: slot.name, resolved: resolved.0, source: resolved.1))
        }
        return out
    }
}

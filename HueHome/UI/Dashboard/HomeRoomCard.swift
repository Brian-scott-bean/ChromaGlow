// HomeRoomCard.swift
// ChromaGlow — Home (Luminous): one room, drawn as light.
//
// A small stage whose orbs are the room's lamps in their real colours and
// brightness (dark glass when off), the room's name and state, a power
// button that glows in the room's colour, and — while the room is on — a
// glow slider painted with its colours. Tap to step into the room; hold to
// wash it in a colour.
//
// Contracts: takes a VALUE-TYPE room (never a binding) and is Equatable on
// what it draws, so SSE churn elsewhere never re-renders it. Power flips
// locally at once and resyncs to bridge truth; the slider keeps its own drag
// state and commits ONCE on release.

import SwiftUI

struct HomeRoomCard: View {
    let room: RoomDisplayItem
    /// The room's lamps as they are right now (may be empty on a cold cache).
    let lights: [LightDisplayItem]
    var features: GuestFeatureSet = .unrestricted
    /// A look or effect is playing in this room.
    var isLive: Bool = false
    let onToggle: (Bool) -> Void
    /// Called ONCE when a brightness drag ends.
    let onBrightness: (Double) -> Void
    var onNavigate: (() -> Void)? = nil
    var onLongPress: (() -> Void)? = nil

    @State private var localIsOn: Bool
    @State private var localBrightness: Double
    @State private var dragging = false

    init(room: RoomDisplayItem, lights: [LightDisplayItem], features: GuestFeatureSet = .unrestricted,
         isLive: Bool = false, onToggle: @escaping (Bool) -> Void, onBrightness: @escaping (Double) -> Void,
         onNavigate: (() -> Void)? = nil, onLongPress: (() -> Void)? = nil) {
        self.room = room
        self.lights = lights
        self.features = features
        self.isLive = isLive
        self.onToggle = onToggle
        self.onBrightness = onBrightness
        self.onNavigate = onNavigate
        self.onLongPress = onLongPress
        _localIsOn = State(initialValue: room.isOn)
        _localBrightness = State(initialValue: max(1, room.brightness))
    }

    private var color: Color { room.luminousColor }

    /// What the stage draws: the lamps, dark while the room is (locally) off.
    private var stageLights: [LightDisplayItem] {
        guard localIsOn else { return lights.map { var l = $0; l.isOn = false; return l } }
        // Just switched on here: the cached lamps still say off until the
        // bridge confirms (~3 s on the phone) — light them at the room's level.
        if !lights.isEmpty, !lights.contains(where: \.isOn) {
            return lights.map { var l = $0; l.isOn = true; l.brightness = localBrightness; return l }
        }
        return lights
    }

    private var statusLine: String {
        let count = "\(room.lightCount) light\(room.lightCount == 1 ? "" : "s")"
        guard localIsOn else { return "\(count) · Off" }
        return "\(count) · \(BrightnessDisplay.percent(localBrightness))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The stage and the name open the room; the slider below is a
            // sibling of the link, so a drag or tap on it never navigates.
            NavigationLink(value: room) {
                VStack(alignment: .leading, spacing: 0) {
                    LuminousMiniRoomStage(lights: stageLights,
                                          fallbackColor: color,
                                          fallbackLevel: localIsOn ? localBrightness / 100 : 0,
                                          height: 70)
                        .padding(.top, 6)
                        // Keep the arc out of the power button's corner — the
                        // last lamp (and a "+N" count) used to hide under it.
                        .padding(.trailing, features.canPower ? 40 : 0)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: archetypeIcon(for: room.archetype))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(localIsOn ? color : LuminousPalette.inkTertiary)
                            Text(room.name)
                                .font(LuminousType.cardTitleSmall)
                                .foregroundStyle(LuminousPalette.ink)
                                .lineLimit(room.name.contains(" ") ? 2 : 1)
                                .minimumScaleFactor(0.75)
                        }
                        HStack(spacing: 6) {
                            if isLive {
                                Circle().fill(LuminousPalette.live).frame(width: 6, height: 6)
                                    .shadow(color: LuminousPalette.live, radius: 3)
                            }
                            Text(isLive ? "Playing · \(statusLine)" : statusLine)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(isLive ? LuminousPalette.live : LuminousPalette.inkSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .contentTransition(.numericText())
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, localIsOn && features.canAdjust ? 2 : 14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(LuminousPressStyle(scale: 1))
            // Fire onNavigate with the push so the orchestrator can suppress
            // SSE rebuilds for the animation window.
            .simultaneousGesture(TapGesture().onEnded { _ in onNavigate?() })
            // Hold → colour wash. Simultaneous so the tap keeps navigating; a
            // completed hold wins because the finger never lifts into a tap.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    guard let onLongPress else { return }
                    HapticManager.shared.medium()
                    onLongPress()
                }
            )
            .accessibilityLabel("\(room.name), \(statusLine)")
            .accessibilityHint("Opens the room")

            if localIsOn && features.canAdjust {
                LuminousGlowSlider(value: $localBrightness,
                                   range: 1...100,
                                   colors: [color.opacity(0.55), color],
                                   format: { "\(BrightnessDisplay.percent($0))%" },
                                   showsHeader: false,
                                   accessibilityName: "\(room.name) brightness",
                                   onEditingChanged: { editing in
                                       dragging = editing
                                       if !editing { onBrightness(localBrightness) }
                                   })
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .luminousPanel(radius: LuminousPalette.cardRadius,
                       glow: localIsOn ? color : nil,
                       glowStrength: localIsOn ? 0.35 + 0.65 * (localBrightness / 100) : 0)
        .overlay {
            if isLive {
                RoundedRectangle(cornerRadius: LuminousPalette.cardRadius, style: .continuous)
                    .strokeBorder(LuminousPalette.live.opacity(0.55), lineWidth: 1.2)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            // The power button sits above the card's tap so it stays a plain
            // tap. Hidden when the guest grant lacks power.
            if features.canPower {
                LuminousPowerButton(isOn: localIsOn, tint: color, size: 34,
                                    label: "Turn \(room.name) \(localIsOn ? "off" : "on")") {
                    HapticManager.shared.light()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { localIsOn.toggle() }
                    onToggle(localIsOn)
                }
                .padding(4)
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(localIsOn ? 1 : 0.82)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: localIsOn)
        .accessibilityElement(children: .contain)
        // Bridge truth (SSE, loadAll, rollback) wins whenever it changes.
        .onChange(of: room.isOn) { _, confirmed in
            if localIsOn != confirmed {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { localIsOn = confirmed }
            }
        }
        .onChange(of: room.brightness) { _, new in
            if !dragging { localBrightness = max(1, new) }
        }
    }
}

extension HomeRoomCard: Equatable {
    // Closures are stable captures; only what the card draws decides a
    // re-render. nonisolated: every compared field is a value type.
    nonisolated static func == (lhs: HomeRoomCard, rhs: HomeRoomCard) -> Bool {
        lhs.room == rhs.room && lhs.lights == rhs.lights && lhs.features == rhs.features && lhs.isLive == rhs.isLive
    }
}

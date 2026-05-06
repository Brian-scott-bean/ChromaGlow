// StudioViewModel.swift
// CastChroma — v0.15.0 Studio Tab
//
// Unified ViewModel replacing EffectsViewModel + SyncModeEngine.
// Owns: card catalog, room selection, param state, apply/stop logic.

import SwiftUI
import Observation

// MARK: - Data Models

struct StudioCard: Identifiable, Hashable {
    let id: String
    let name: String
    let tagline: String
    let icon: String
    let accentColor: Color
    let requiresForeground: Bool
    let params: [StudioParam]
    let strategy: StudioStrategy

    /// True for cards that use the Entertainment API (Strobe, Party, Thunderstorm).
    /// These affect the entire entertainment area, not just the selected room.
    var isEntertainmentScoped: Bool {
        guard case .appDriven(let key) = strategy else { return false }
        return ["strobe", "party", "thunderstorm"].contains(key)
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: StudioCard, rhs: StudioCard) -> Bool { lhs.id == rhs.id }
}

struct StudioParam: Identifiable {
    let id: String
    let label: String
    let kind: StudioParamKind
    let defaultValue: Double
    let tier: ParamTier
    var displayValue: String { "\(Int(defaultValue))" }

    enum ParamTier: String {
        case essential  // Always visible in compact mixer tray
        case color      // Color section of param sheet
        case advanced   // Advanced section of param sheet
    }
}

enum StudioParamKind {
    case slider(min: Double, max: Double)
    case colorPicker
    case toggle
}

enum StudioStrategy: Equatable {
    case bridgeNative(effect: String)
    case appDriven(engineKey: String)
    case composition(presetID: UUID)

    /// Effects that the bridge handles natively on the grouped_light resource.
    /// Only "no_effect" is valid on grouped_light — all actual effects
    /// (candle, fire, sparkle, etc.) must be sent per-light.
    /// The grouped_light schema does NOT include an effects field.
    static let groupedLightOnlyEffects: Set<String> = ["no_effect"]
}

// MARK: - StudioViewModel

/// Tracks a running effect on a specific room.
struct RunningEffect {
    let cardID: String
    let card: StudioCard
    let room: RoomDisplayItem
    let lightIDs: [String]     // for per-light cleanup (bridgeNative)
    let isEntertainment: Bool  // true = DTLS session active
}

@Observable
final class StudioViewModel {

    // ── Selection state ───────────────────────────────────────
    var selectedRoom: RoomDisplayItem? = nil
    var selectedCard: StudioCard?      = nil

    /// All currently running effects, keyed by room ID.
    /// Multiple rooms can have independent effects running simultaneously.
    var runningEffects: [String: RunningEffect] = [:]

    /// The running effect on the CURRENTLY SELECTED room.
    /// Drives card grid running indicators and mixer tray content.
    var currentRoomEffect: RunningEffect? {
        guard let room = selectedRoom else { return nil }
        return runningEffects[room.id]
    }

    /// Whether ANY effect is running across any room.
    var hasAnyRunningEffect: Bool {
        !runningEffects.isEmpty
    }

    /// Convenience: the running card ID for the currently selected room.
    /// Used by the card grid to determine which card shows as "running".
    var runningCardID: String? {
        currentRoomEffect?.cardID
    }

    // ── Param values (namespaced: cardID → paramID → value) ──
    // Composition-ready: each card gets its own param namespace.
    var paramValues:  [String: [String: Double]] = [:]
    var paramColors:  [String: [String: Color]]  = [:]

    // ── Engine reference (set in configure()) ─────────────────
    private weak var orchestrator: UnifiedOrchestrator?

    // ── Safety: Strobe compliance ─────────────────────────────
    /// Whether the user has acknowledged the strobe warning (persisted).
    var strobeWarningAcknowledged: Bool {
        get { UserDefaults.standard.bool(forKey: "strobeWarningAcknowledged") }
        set { UserDefaults.standard.set(newValue, forKey: "strobeWarningAcknowledged") }
    }

    /// True if iOS "Reduce Motion" is enabled — strobe should be blocked.
    var isReduceMotionEnabled: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    /// True if iOS "Dim Flashing Lights" is enabled — strobe brightness capped at 30%.
    /// Note: This API requires iOS 17+. Falls back to false on older SDKs.
    var isDimFlashingLightsEnabled: Bool {
        // UIAccessibility.isDimFlashingLightsEnabled requires iOS 17+ SDK.
        // When building against older SDKs, this safely returns false.
        false
    }

    /// Whether to show the strobe warning dialog before activating strobe.
    var needsStrobeWarning: Bool {
        !strobeWarningAcknowledged && !isReduceMotionEnabled
    }

    // ── Preset colors for the color picker param ──────────────
    static let presetColors: [Color] = [
        HuePalette.Noir.destructive,   // red
        HuePalette.amberDeep,          // orange
        HuePalette.amber,              // amber
        HuePalette.Noir.success,       // green
        Color(hex: "#0A84FF"),          // blue — system blue, no token yet
        Color(hex: "#BF5AF2"),          // purple — no token yet
        Color.white
    ]

    // ── Card catalogs ─────────────────────────────────────────
    let effectCards: [StudioCard] = StudioViewModel.buildEffectCards()
    let liveModeCards: [StudioCard] = StudioViewModel.buildLiveModeCards()

    // ── Composition store ─────────────────────────────────────
    let compositionStore = CompositionStore()

    /// Live composition param box — the render loop reads this each frame.
    /// UI writes to it on slider drag for instant light response.
    nonisolated(unsafe) var activeCompositionBox: CompositionParamBox?

    // ── Status ────────────────────────────────────────────────
    var statusMessage: String = ""

    @MainActor
    func configure(orchestrator: UnifiedOrchestrator) {
        self.orchestrator = orchestrator
        if selectedRoom == nil, let first = orchestrator.allRooms.first {
            selectedRoom = first
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Param Access (composition-ready)
    // ──────────────────────────────────────────────

    /// Read a param value for a specific card, falling back to the param's default.
    func paramValue(for cardID: String, paramID: String, default defaultVal: Double) -> Double {
        paramValues[cardID]?[paramID] ?? defaultVal
    }

    /// Write a param value for a specific card.
    func setParamValue(for cardID: String, paramID: String, value: Double) {
        if paramValues[cardID] == nil { paramValues[cardID] = [:] }
        paramValues[cardID]?[paramID] = value
        // Push live update to running engine loop (if this card is running)
        if cardID == runningCardID {
            orchestrator?.updateStudioParams(
                values: paramValues[cardID] ?? [:],
                colors: paramColors[cardID] ?? [:]
            )
        }
    }

    /// Read a param color for a specific card.
    func paramColor(for cardID: String, paramID: String) -> Color? {
        paramColors[cardID]?[paramID]
    }

    /// Write a param color for a specific card.
    func setParamColor(for cardID: String, paramID: String, color: Color) {
        if paramColors[cardID] == nil { paramColors[cardID] = [:] }
        paramColors[cardID]?[paramID] = color
        // Push live update to running engine loop
        if cardID == runningCardID {
            orchestrator?.updateStudioParams(
                values: paramValues[cardID] ?? [:],
                colors: paramColors[cardID] ?? [:]
            )
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Apply / Stop
    // ──────────────────────────────────────────────
    //
    // RATE LIMIT DISCIPLINE:
    //   grouped_light: ~1 PUT/sec (bridge silently drops excess)
    //   individual light: ~10 PUT/sec
    //
    // Every operation must minimize grouped_light PUTs.
    // Combine on + effect + brightness into ONE atomic PUT.
    // Never send on:false between card switches (wastes a slot).

    /// Whether the current stop is an explicit user action (turn off) vs internal switch.
    private var isExplicitStop = false

    /// Send per-light commands in throttled batches to avoid 429 rate limiting.
    /// The bridge accepts ~7 simultaneous per-light PUTs before throttling.
    /// Batches of 5 with 150ms gaps guarantee no 429s.
    private func sendPerLightBatched(
        lightIDs: [String],
        api: HueAPIClient,
        action: @escaping (String) async -> Void
    ) async {
        let batchSize = 5
        for batchStart in stride(from: 0, to: lightIDs.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, lightIDs.count)
            let batch = Array(lightIDs[batchStart..<batchEnd])
            await withTaskGroup(of: Void.self) { group in
                for id in batch {
                    group.addTask { await action(id) }
                }
            }
            // Wait between batches to stay under bridge rate limit
            if batchEnd < lightIDs.count {
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// Resolve individual light IDs for a room/zone using its in-memory child refs.
    /// - Zone children have rtype "light" → rid IS the light ID (zero API calls)
    /// - Room children have rtype "device" → need one fetchLights() to match owner.rid
    private func resolveLightIDs(for room: RoomDisplayItem, api: HueAPIClient) async -> [String] {
        let refs = room.childResourceRefs
        guard !refs.isEmpty else { return [] }

        // Zones reference lights directly — no API call needed
        let hasDirectLightRefs = refs.contains { $0.rtype == "light" }
        if hasDirectLightRefs {
            let ids = refs.filter { $0.rtype == "light" }.map { $0.rid }
            print("[Studio] 🔍 Resolved \(ids.count) lights from zone refs (no API call)")
            return ids
        }

        // Rooms reference devices — resolve via light.owner.rid
        let deviceIDs = Set(refs.map { $0.rid })
        guard let allLights = try? await api.fetchLights() else { return [] }
        let roomLightIDs = allLights
            .filter { light in
                guard let ownerRID = light.owner?.rid else { return false }
                return deviceIDs.contains(ownerRID)
            }
            .map { $0.id }
        print("[Studio] 🔍 Resolved \(roomLightIDs.count) lights from \(deviceIDs.count) device refs")
        return roomLightIDs
    }

    @MainActor
    func apply(_ card: StudioCard) async {
        print("[Studio] apply '\(card.name)' — selectedRoom: \(selectedRoom?.name ?? "nil")")
        guard let room = selectedRoom else {
            statusMessage = "⚠ Select a room first"
            print("[Studio] ❌ No room selected")
            return
        }
        guard let groupedLightID = room.groupedLightID else {
            statusMessage = "⚠ Room '\(room.name)' has no grouped light"
            print("[Studio] ❌ Room '\(room.name)' has no groupedLightID")
            return
        }
        guard let orchestrator else {
            print("[Studio] ❌ orchestrator is nil")
            return
        }
        guard let api = orchestrator.hueClient(for: room.bridgeID) else {
            print("[Studio] ❌ hueClient(for: \(room.bridgeID ?? "nil")) returned nil")
            return
        }
        print("[Studio] ✅ All guards passed — groupedLightID: \(groupedLightID), bridgeID: \(room.bridgeID ?? "nil"), strategy: \(card.strategy)")

        // ── Stop any effect already running on THIS room ─────────────
        if let existing = runningEffects[room.id] {
            let existingCard = existing.card
            print("[Studio] Replacing '\(existingCard.name)' on \(room.name)")
            isExplicitStop = false
            await stopEffect(on: room.id)

            // Delay if both old and new use REST on the same grouped_light
            let oldIsBridgeNative: Bool
            if case .bridgeNative = existingCard.strategy { oldIsBridgeNative = true } else { oldIsBridgeNative = false }
            let newIsBridgeNative: Bool
            if case .bridgeNative = card.strategy { newIsBridgeNative = true } else { newIsBridgeNative = false }
            if oldIsBridgeNative && newIsBridgeNative {
                try? await Task.sleep(for: .milliseconds(400))
            }
        }

        // ── If new card is entertainment-scoped, stop any existing entertainment effect ──
        if card.isEntertainmentScoped {
            for (roomID, effect) in runningEffects where effect.isEntertainment {
                print("[Studio] Stopping entertainment '\(effect.card.name)' on \(effect.room.name) (only one DTLS session allowed)")
                isExplicitStop = false
                await stopEffect(on: roomID)
            }
        }

        // ── Check for light overlap with other running rooms ─────────
        // (e.g. Home zone overlaps individual rooms)
        let newLightIDs: [String]
        switch card.strategy {
        case .bridgeNative:
            newLightIDs = await resolveLightIDs(for: room, api: api)
        default:
            newLightIDs = []  // appDriven doesn't use per-light IDs
        }

        if !newLightIDs.isEmpty {
            let newLightSet = Set(newLightIDs)
            for (roomID, effect) in runningEffects {
                let overlap = Set(effect.lightIDs).intersection(newLightSet)
                if !overlap.isEmpty {
                    print("[Studio] Light overlap: \(overlap.count) lights shared with \(effect.room.name) — stopping")
                    isExplicitStop = false
                    await stopEffect(on: roomID)
                }
            }
        }

        let brightness = paramValue(for: card.id, paramID: "brightness", default: 70)

        switch card.strategy {
        case .bridgeNative(let effectName):
            // Step 1: Turn on group with brightness (1 grouped_light PUT).
            print("[Studio] 📡 Group ON + bri=\(brightness) → \(room.name)")
            try? await api.setGroupedLightState(
                id: groupedLightID, on: true, brightness: brightness
            )

            // Step 2: Apply effect per-light.
            let lightIDs = newLightIDs.isEmpty ? await resolveLightIDs(for: room, api: api) : newLightIDs
            if lightIDs.isEmpty {
                statusMessage = "⚠ No lights found in \(room.name)"
                return
            }
            print("[Studio] 📡 Per-light effect=\(effectName) to \(lightIDs.count) lights in \(room.name)")
            await sendPerLightBatched(lightIDs: lightIDs, api: api) { id in
                try? await api.setLightNativeEffect(id: id, effect: effectName)
            }

            runningEffects[room.id] = RunningEffect(
                cardID: card.id, card: card, room: room,
                lightIDs: lightIDs, isEntertainment: false
            )
            statusMessage = "🟢 \(card.name) → \(room.name)"

        case .appDriven(let engineKey):
            if engineKey == "strobe" && isReduceMotionEnabled {
                statusMessage = "⚠ Strobe disabled — 'Reduce Motion' is enabled in iOS Settings"
                return
            }

            var flatValues = paramValues[card.id] ?? [:]
            let flatColors = paramColors[card.id] ?? [:]

            if engineKey == "strobe" && isDimFlashingLightsEnabled {
                flatValues["brightness"] = min(flatValues["brightness"] ?? 100, 30)
            }

            await orchestrator.startStudioMode(
                key: engineKey, room: room,
                params: flatValues, colors: flatColors
            )
            let isEnt = orchestrator.studioEntClient != nil
            runningEffects[room.id] = RunningEffect(
                cardID: card.id, card: card, room: room,
                lightIDs: [], isEntertainment: isEnt
            )
            let transport = isEnt ? "ENTERTAINMENT" : "REST"
            statusMessage = "🟢 \(card.name) → \(room.name) [\(transport)]"

        case .composition(let presetID):
            guard let preset = compositionStore.presets.first(where: { $0.id == presetID }) else {
                statusMessage = "⚠ Composition not found"
                return
            }
            let box = CompositionParamBox(preset: preset)
            activeCompositionBox = box

            await orchestrator.startCompositionMode(
                room: room, paramBox: box
            )
            let isEnt = orchestrator.studioEntClient != nil
            runningEffects[room.id] = RunningEffect(
                cardID: card.id, card: card, room: room,
                lightIDs: [], isEntertainment: isEnt
            )
            let transport = isEnt ? "ENTERTAINMENT" : "REST"
            statusMessage = "🟢 \(card.name) → \(room.name) [\(transport)]"
        }

        print("[Studio] Active effects: \(runningEffects.count) rooms")
    }

    /// Stop the effect running on a specific room.
    @MainActor
    private func stopEffect(on roomID: String) async {
        guard let effect = runningEffects[roomID],
              let orchestrator,
              let api = orchestrator.hueClient(for: effect.room.bridgeID),
              let groupedLightID = effect.room.groupedLightID else { return }

        print("[Studio] Stopping '\(effect.card.name)' on \(effect.room.name) (glID: \(groupedLightID)) explicit=\(isExplicitStop)")

        switch effect.card.strategy {
        case .bridgeNative:
            // Clean up per-light effects (the ONLY way to clear them)
            if !effect.lightIDs.isEmpty {
                print("[Studio] 📡 Clearing per-light effects on \(effect.lightIDs.count) lights")
                await sendPerLightBatched(lightIDs: effect.lightIDs, api: api) { id in
                    try? await api.setLightNativeEffect(id: id, effect: "no_effect")
                }
            }

            if isExplicitStop {
                // User tapped Stop — turn off the room (1 PUT)
                try? await api.setGroupedLight(id: groupedLightID, on: false)
            }

        case .appDriven:
            await orchestrator.stopStudioMode()
            try? await Task.sleep(for: .milliseconds(200))

        case .composition:
            await orchestrator.stopStudioMode()
            activeCompositionBox = nil
            try? await Task.sleep(for: .milliseconds(200))
        }

        runningEffects.removeValue(forKey: roomID)
    }

    /// Public stop — called from the card grid (tap running card to toggle off)
    /// or from the mixer stop button.
    @MainActor
    func stop(_ card: StudioCard) async {
        guard let room = selectedRoom else { return }
        isExplicitStop = false
        await stopEffect(on: room.id)
        statusMessage = ""
    }

    /// Explicit stop — called when user taps the stop button directly.
    /// Turns off the room's lights.
    @MainActor
    func explicitStop(_ card: StudioCard) async {
        guard let room = selectedRoom else { return }
        isExplicitStop = true
        await stopEffect(on: room.id)
        statusMessage = ""
    }

    /// Stop all running effects across all rooms.
    @MainActor
    func stopAll() async {
        isExplicitStop = true
        let roomIDs = Array(runningEffects.keys)
        for roomID in roomIDs {
            await stopEffect(on: roomID)
        }
        statusMessage = ""
    }

    // ──────────────────────────────────────────────
    // MARK: - Live Param Updates
    // ──────────────────────────────────────────────

    private var paramTask: Task<Void, Never>?

    /// Debounced param update — dispatches to the correct API call based on param ID.
    /// Waits 150ms after last change, then sends one PUT.
    @MainActor
    func sendParam(cardID: String, paramID: String, value: Double) {
        paramTask?.cancel()
        paramTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }

            guard let room = selectedRoom,
                  let groupedLightID = room.groupedLightID,
                  let orchestrator,
                  let api = orchestrator.hueClient(for: room.bridgeID) else { return }

            // Read current transition setting for this card (used as duration)
            let card = (effectCards + liveModeCards + composerStudioCards).first(where: { $0.id == cardID })
            let transitionMs = Int(paramValue(for: cardID, paramID: "transition", default: card?.params.first(where: { $0.id == "transition" })?.defaultValue ?? 400))

            switch paramID {
            case "brightness":
                try? await api.setGroupedLightEffect(
                    id: groupedLightID, on: nil,
                    brightness: value, xy: nil, mirek: nil,
                    duration: transitionMs
                )
            case "warmth":
                let mirek = Int(value.rounded())
                try? await api.setGroupedLightEffect(
                    id: groupedLightID, on: nil,
                    brightness: nil, xy: nil, mirek: mirek,
                    duration: transitionMs
                )
            case "transition":
                // Stored locally — affects subsequent brightness/warmth/color sends.
                // No immediate bridge command needed.
                break
            case "speed", "saturation":
                // Bridge-native effects don't expose runtime speed/saturation.
                // Values stored for app-driven engines and future composition emulation.
                break
            default:
                // App-driven params (speed, sensitivity, min_brightness, duty_cycle, etc.)
                // are read by the engine loop directly from paramValues — no bridge call needed.
                break
            }
        }
    }

    /// Send a color param change to the bridge (for base_color, flash_color, etc.).
    /// Converts SwiftUI Color to CIE xy using HueColorUtils.
    @MainActor
    func sendColorParam(cardID: String, paramID: String, color: Color) {
        setParamColor(for: cardID, paramID: paramID, color: color)

        // Only send to bridge for base_color on bridge-native effects
        guard paramID == "base_color" else { return }
        let card = (effectCards + liveModeCards).first(where: { $0.id == cardID })
        guard case .bridgeNative = card?.strategy else { return }

        paramTask?.cancel()
        paramTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }

            guard let room = selectedRoom,
                  let groupedLightID = room.groupedLightID,
                  let orchestrator,
                  let api = orchestrator.hueClient(for: room.bridgeID) else { return }

            // Extract HSB from Color
            let uiColor = UIColor(color)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
            uiColor.getHue(&h, saturation: &s, brightness: &b, alpha: nil)

            let xy = HueColorUtils.xyFrom(hue: Double(h), saturation: Double(s), brightness: Double(b))
            let transitionMs = Int(paramValue(for: cardID, paramID: "transition", default: 500))

            try? await api.setGroupedLightEffect(
                id: groupedLightID, on: nil,
                brightness: nil, xy: (xy.x, xy.y), mirek: nil,
                duration: transitionMs
            )
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Composer Cards (from store)
    // ──────────────────────────────────────────────

    /// Build StudioCards from saved CompositionPresets.
    /// These appear on Deck 3 alongside the "+ Create" button.
    var composerStudioCards: [StudioCard] {
        compositionStore.presets.map { preset in
            StudioCard(
                id: "comp_\(preset.id.uuidString)",
                name: preset.name,
                tagline: "\(preset.palette.mode.rawValue.capitalized) • \(preset.motion.pattern.rawValue.capitalized) • \(preset.envelope.shape.rawValue.capitalized)",
                icon: preset.icon,
                accentColor: Color(hex: preset.accentColorHex),
                requiresForeground: true,  // compositions need render loop
                params: [],  // controlled via layer tabs, not flat params
                strategy: .composition(presetID: preset.id)
            )
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Card Catalog
    // ──────────────────────────────────────────────

    private static func buildEffectCards() -> [StudioCard] {
        return [
            StudioCard(
                id: "candle",
                name: "Candle",
                tagline: "Warm flickering flame, perfect for dinner or relaxation",
                icon: "flame.fill",
                accentColor: Color(hex: "#FF9500"),
                requiresForeground: false,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "warmth", label: "Warmth", kind: .slider(min: 153, max: 500), defaultValue: 366, tier: .color),
                    StudioParam(id: "base_color", label: "Base Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .slider(min: 0, max: 6000), defaultValue: 500, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "candle")
            ),
            StudioCard(
                id: "fire",
                name: "Fire",
                tagline: "Intense fire effect with deep amber and red tones",
                icon: "flame",
                accentColor: Color(hex: "#FF3B30"),
                requiresForeground: false,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "warmth", label: "Warmth", kind: .slider(min: 153, max: 500), defaultValue: 400, tier: .color),
                    StudioParam(id: "base_color", label: "Base Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .slider(min: 0, max: 6000), defaultValue: 300, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "fire")
            ),
            StudioCard(
                id: "sparkle",
                name: "Sparkle",
                tagline: "Gentle random twinkle across all lights",
                icon: "sparkles",
                accentColor: Color(hex: "#FFC107"),
                requiresForeground: false,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "base_color", label: "Base Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .slider(min: 0, max: 6000), defaultValue: 400, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "sparkle")
            ),
            StudioCard(
                id: "prism",
                name: "Prism",
                tagline: "Slow color cycling through the full spectrum",
                icon: "camera.filters",
                accentColor: Color(hex: "#BF5AF2"),
                requiresForeground: false,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                    StudioParam(id: "transition", label: "Smoothness", kind: .slider(min: 0, max: 6000), defaultValue: 1000, tier: .advanced),
                    StudioParam(id: "saturation", label: "Saturation", kind: .slider(min: 0, max: 100), defaultValue: 100, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "prism")
            ),
            StudioCard(
                id: "opal",
                name: "Opal",
                tagline: "Iridescent pastel color shifts",
                icon: "circle.hexagongrid.fill",
                accentColor: Color(hex: "#40D9BF"),
                requiresForeground: false,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "warmth", label: "Warmth", kind: .slider(min: 153, max: 500), defaultValue: 300, tier: .color),
                    StudioParam(id: "base_color", label: "Base Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .slider(min: 0, max: 6000), defaultValue: 800, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "opal")
            ),
            StudioCard(
                id: "glisten",
                name: "Glisten",
                tagline: "Quick bright flashes like sunlight on water",
                icon: "rays",
                accentColor: Color(hex: "#0A84FF"),
                requiresForeground: false,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "base_color", label: "Base Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .slider(min: 0, max: 6000), defaultValue: 300, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "glisten")
            ),
            StudioCard(
                id: "colorloop",
                name: "Color Loop",
                tagline: "Continuous slow hue rotation — classic Hue effect",
                icon: "arrow.triangle.2.circlepath",
                accentColor: Color(hex: "#30D158"),
                requiresForeground: false,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                    StudioParam(id: "transition", label: "Smoothness", kind: .slider(min: 0, max: 6000), defaultValue: 1000, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "colorloop")
            ),
        ]
    }

    private static func buildLiveModeCards() -> [StudioCard] {
        return [
            StudioCard(
                id: "music_sync",
                name: "Music Sync",
                tagline: "Lights pulse and flash to your music in real time via microphone",
                icon: "waveform.and.mic",
                accentColor: Color(hex: "#FF4D8C"),
                requiresForeground: true,
                params: [
                    StudioParam(id: "sensitivity", label: "Sensitivity", kind: .slider(min: 0, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 80, tier: .essential),
                    StudioParam(id: "color", label: "Color Palette", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "min_brightness", label: "Min Brightness", kind: .slider(min: 1, max: 50), defaultValue: 10, tier: .advanced),
                    StudioParam(id: "smoothness", label: "Smoothness", kind: .slider(min: 0, max: 100), defaultValue: 30, tier: .advanced),
                    StudioParam(id: "saturation", label: "Saturation", kind: .slider(min: 0, max: 100), defaultValue: 100, tier: .advanced),
                ],
                strategy: .appDriven(engineKey: "mic")
            ),
            StudioCard(
                id: "gaming",
                name: "Gaming",
                tagline: "Dynamic hue shifts during intense gaming sessions",
                icon: "gamecontroller.fill",
                accentColor: Color(hex: "#0A84FF"),
                requiresForeground: true,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 80, tier: .essential),
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                    StudioParam(id: "warmth", label: "Warmth", kind: .slider(min: 153, max: 500), defaultValue: 300, tier: .color),
                    StudioParam(id: "saturation", label: "Saturation", kind: .slider(min: 0, max: 100), defaultValue: 80, tier: .advanced),
                    StudioParam(id: "min_brightness", label: "Min Brightness", kind: .slider(min: 1, max: 50), defaultValue: 15, tier: .advanced),
                ],
                strategy: .appDriven(engineKey: "gaming")
            ),
            StudioCard(
                id: "party",
                name: "Party",
                tagline: "Fast multi-color flashes synchronized across the room",
                icon: "party.popper.fill",
                accentColor: Color(hex: "#BF5AF2"),
                requiresForeground: true,
                params: [
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 60, tier: .essential),
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 90, tier: .essential),
                    StudioParam(id: "color", label: "Flash Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "min_brightness", label: "Min Brightness", kind: .slider(min: 0, max: 50), defaultValue: 5, tier: .advanced),
                    StudioParam(id: "smoothness", label: "Smoothness", kind: .slider(min: 0, max: 100), defaultValue: 20, tier: .advanced),
                    StudioParam(id: "saturation", label: "Saturation", kind: .slider(min: 0, max: 100), defaultValue: 100, tier: .advanced),
                ],
                strategy: .appDriven(engineKey: "party")
            ),
            StudioCard(
                id: "strobe",
                name: "Strobe",
                tagline: "High-frequency white flash — use responsibly",
                icon: "bolt.fill",
                accentColor: Color(hex: "#FFC107"),
                requiresForeground: true,
                params: [
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 100, tier: .essential),
                    StudioParam(id: "flash_color", label: "Flash Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "min_brightness", label: "Min Brightness", kind: .slider(min: 0, max: 50), defaultValue: 0, tier: .advanced),
                    StudioParam(id: "duty_cycle", label: "Duty Cycle", kind: .slider(min: 10, max: 90), defaultValue: 50, tier: .advanced),
                ],
                strategy: .appDriven(engineKey: "strobe")
            ),
            StudioCard(
                id: "thunderstorm",
                name: "Thunderstorm",
                tagline: "Random lightning strikes with dim ambient fill",
                icon: "cloud.bolt.fill",
                accentColor: Color(hex: "#668AFF"),
                requiresForeground: true,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 80, tier: .essential),
                    StudioParam(id: "frequency", label: "Storm Intensity", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                    StudioParam(id: "ambient_color", label: "Ambient Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "flash_intensity", label: "Flash Intensity", kind: .slider(min: 20, max: 100), defaultValue: 90, tier: .advanced),
                    StudioParam(id: "min_brightness", label: "Min Brightness", kind: .slider(min: 1, max: 30), defaultValue: 5, tier: .advanced),
                ],
                strategy: .appDriven(engineKey: "thunderstorm")
            ),
            StudioCard(
                id: "ambient",
                name: "Ambient",
                tagline: "Slow breathing color shifts that blend with your room",
                icon: "aqi.low",
                accentColor: Color(hex: "#40D9BF"),
                requiresForeground: true,
                params: [
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 30, tier: .essential),
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "color", label: "Color Palette", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "warmth", label: "Warmth", kind: .slider(min: 153, max: 500), defaultValue: 350, tier: .color),
                    StudioParam(id: "smoothness", label: "Smoothness", kind: .slider(min: 0, max: 100), defaultValue: 70, tier: .advanced),
                    StudioParam(id: "min_brightness", label: "Min Brightness", kind: .slider(min: 1, max: 50), defaultValue: 15, tier: .advanced),
                ],
                strategy: .appDriven(engineKey: "ambient")
            ),
        ]
    }
}


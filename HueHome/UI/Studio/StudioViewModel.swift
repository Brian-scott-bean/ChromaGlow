// StudioViewModel.swift
// CastChroma — v0.15.0 Studio Tab
//
// Unified ViewModel replacing EffectsViewModel + SyncModeEngine.
// Owns: card catalog, room selection, param state, apply/stop logic.

import SwiftUI
import Observation
import MediaAccessibility
#if canImport(FoundationModels)
import FoundationModels
#endif

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
    let compositionLayerActivity: CompositionLayerActivity?
    let compositionTier: CompositionTier?
    let isAIGenerated: Bool

    init(
        id: String,
        name: String,
        tagline: String,
        icon: String,
        accentColor: Color,
        requiresForeground: Bool,
        params: [StudioParam],
        strategy: StudioStrategy,
        compositionLayerActivity: CompositionLayerActivity?,
        compositionTier: CompositionTier? = nil,
        isAIGenerated: Bool = false
    ) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.icon = icon
        self.accentColor = accentColor
        self.requiresForeground = requiresForeground
        self.params = params
        self.strategy = strategy
        self.compositionLayerActivity = compositionLayerActivity
        self.compositionTier = compositionTier
        self.isAIGenerated = isAIGenerated
    }

    /// True for cards that use the Entertainment API (Strobe, Party, Thunderstorm).
    /// These affect the entire entertainment area, not just the selected room.
    var isEntertainmentScoped: Bool {
        guard case .appDriven(let key) = strategy else { return false }
        return ["strobe", "party", "thunderstorm"].contains(key)
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: StudioCard, rhs: StudioCard) -> Bool { lhs.id == rhs.id }
}

struct CompositionLayerActivity: Hashable {
    let palette: Bool
    let motion: Bool
    let envelope: Bool
    let reaction: Bool
}

struct StudioParam: Identifiable {
    let id: String
    let label: String
    let kind: StudioParamKind
    let defaultValue: Double
    let tier: ParamTier
    /// Optional human-readable value formatter (Hz, Kelvin, %). Nil → plain Int.
    /// @Sendable: pure value formatters only — this is what makes StudioParam
    /// (and therefore StudioCard) Sendable, which StudioCardView's
    /// nonisolated == relies on.
    var format: (@Sendable (Double) -> String)? = nil
    /// Param only reaches the lights over the Entertainment (DTLS) transport —
    /// the REST fallback loop ignores it. Rows render a hint while on REST.
    var entOnly: Bool = false
    var displayValue: String { "\(Int(defaultValue))" }

    enum ParamTier: String {
        case essential  // Always visible in compact mixer tray
        case color      // Color section of param sheet
        case advanced   // Advanced section of param sheet
    }
}

/// Shared value formatters and chip option sets for the param catalogs.
enum StudioParamFormat {
    /// Mirek (153–500) shown as Kelvin, rounded to 100K.
    static let kelvin: @Sendable (Double) -> String = { mirek in
        let k = 1_000_000 / max(mirek, 1)
        return "\(Int((k / 100).rounded()) * 100)K"
    }
    /// Engine speed 0–100 shown as flash rate. Mirrors the strobe/party
    /// loops' mapping (0.5–3.0 Hz, WCAG ≤3 flashes/sec).
    static let flashHz: @Sendable (Double) -> String = { value in
        String(format: "%.1f Hz", 0.5 + (min(max(value, 0), 100) / 100.0) * 2.5)
    }
    /// Transition smoothness as three meaningful presets (ms). The old
    /// 0–6000 ms slider implied runtime control it never had — this value
    /// only sets the glide duration of later brightness/warmth/color PUTs.
    static let transitionOptions: [(label: String, value: Double)] = [
        ("INSTANT", 0), ("SMOOTH", 400), ("SLOW", 1500),
    ]
}

enum StudioParamKind {
    case slider(min: Double, max: Double)
    case colorPicker
    case toggle
    /// One-tap chip choices (label + stored value) for params whose value
    /// space is really a few meaningful presets (e.g. transition smoothness).
    case segmented(options: [(label: String, value: Double)])
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

private struct AICompositionDraft {
    let name: String
    let icon: String
    let accentColorHex: String
    let palette: PaletteConfig
    let motion: MotionConfig
    let envelope: EnvelopeConfig
    let reaction: ReactionConfig
    let providerModel: String
}

private enum AICompositionGeneratorError: LocalizedError {
    case promptTooShort
    case providerUnavailable
    case invalidModelResponse
    case decodeFailure(raw: String, details: String)

    var errorDescription: String? {
        switch self {
        case .promptTooShort:
            return "Give me at least a few words to build from."
        case .providerUnavailable:
            return "Apple Foundation Models is unavailable on this device."
        case .invalidModelResponse:
            return "AI response was invalid. Try a different prompt."
        case .decodeFailure:
            return "Couldn’t decode AI composition. Try a different prompt."
        }
    }
}

private struct AICompositionGenerator {
    private struct ModelDraft: Decodable {
        var name: String
        var icon: String
        var accentColorHex: String
        var palette: PaletteConfig
        var motion: MotionConfig
        var envelope: EnvelopeConfig
        var reaction: ReactionConfig

        init(
            name: String,
            icon: String,
            accentColorHex: String,
            palette: PaletteConfig,
            motion: MotionConfig,
            envelope: EnvelopeConfig,
            reaction: ReactionConfig
        ) {
            self.name = name
            self.icon = icon
            self.accentColorHex = accentColorHex
            self.palette = palette
            self.motion = motion
            self.envelope = envelope
            self.reaction = reaction
        }

        private enum CodingKeys: String, CodingKey {
            case name, icon, accentColorHex, palette, motion, envelope, reaction
        }

        private struct ModelPaletteDraft: Decodable {
            var mode: String?
            var colors: [String]?
            var color1: String?
            var color2: String?
            var color3: String?
            var saturation: Double?
            var hueShift: Double?
            var temperature: Int?
            var randomize: Bool?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? "AI Composition"
            icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "wand.and.stars"
            accentColorHex = try container.decodeIfPresent(String.self, forKey: .accentColorHex) ?? "#FFB340"

            if let strictPalette = try? container.decode(PaletteConfig.self, forKey: .palette) {
                palette = strictPalette
            } else if let loosePalette = try? container.decode(ModelPaletteDraft.self, forKey: .palette) {
                palette = Self.normalizedPalette(from: loosePalette)
            } else {
                palette = PaletteConfig()
            }

            motion = (try? container.decode(MotionConfig.self, forKey: .motion)) ?? MotionConfig()
            envelope = (try? container.decode(EnvelopeConfig.self, forKey: .envelope)) ?? EnvelopeConfig()
            reaction = (try? container.decode(ReactionConfig.self, forKey: .reaction)) ?? ReactionConfig()
        }

        private static func normalizedPalette(from loose: ModelPaletteDraft) -> PaletteConfig {
            var normalized = PaletteConfig()

            if let rawMode = loose.mode?.lowercased(),
               let mode = PaletteConfig.Mode(rawValue: rawMode) {
                normalized.mode = mode
            }

            let paletteColors = (loose.colors ?? []).compactMap { hexToCodableColor($0) }
            if let first = paletteColors.first { normalized.color1 = first }
            if paletteColors.count > 1 {
                normalized.color2 = paletteColors[1]
            } else if let c2 = hexToCodableColor(loose.color2) {
                normalized.color2 = c2
            } else {
                normalized.color2 = normalized.color1
            }

            if paletteColors.count > 2 {
                normalized.color3 = paletteColors[2]
            } else {
                normalized.color3 = hexToCodableColor(loose.color3)
            }

            if paletteColors.isEmpty, let c1 = hexToCodableColor(loose.color1) {
                normalized.color1 = c1
            }

            normalized.saturation = loose.saturation ?? normalized.saturation
            normalized.hueShift = loose.hueShift ?? normalized.hueShift
            normalized.temperature = loose.temperature ?? normalized.temperature
            normalized.randomize = loose.randomize ?? normalized.randomize
            return normalized
        }

        private static func hexToCodableColor(_ hex: String?) -> CodableColor? {
            guard let raw = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return CodableColor.from(color: Color(hex: raw))
        }
    }

    func generateDraft(from rawPrompt: String) async throws -> AICompositionDraft {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.count >= 4 else { throw AICompositionGeneratorError.promptTooShort }

#if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                debugLog("[AI] FoundationModels unavailable; using local fallback draft.")
                return fallbackDraft(from: prompt, providerModel: "fallback/local_unavailable")
            }
            let session = LanguageModelSession(instructions: """
            You generate Philips Hue composition presets. Return ONLY JSON. No markdown.
            Keep values within valid ranges:
            - Motion speed 0...100, spread 0...100, offset 0...100
            - Envelope bpm 20...240, depth 0...100, attack 0...100, decay 0...100, dutyCycle 10...90, minBrightness 0...50, maxBrightness 50...100
            - Reaction sensitivity/smoothing/intensity/threshold 0...100
            - Palette saturation 0...100, hueShift -180...180, temperature 153...500
            Use valid enums exactly matching app model raw values.
            Palette must include mode, color1, and color2 keys (no "colors" array).
            """)

            let promptPayload = """
            Create a composition preset from this user prompt:
            \(prompt)

            Return JSON object with keys:
            {
              "name": String,
              "icon": String,
              "accentColorHex": String,
              "palette": PaletteConfig,
              "motion": MotionConfig,
              "envelope": EnvelopeConfig,
              "reaction": ReactionConfig
            }
            """
            do {
                let response = try await session.respond(to: promptPayload)
                let sanitized = sanitizeModelResponse(response.content)
                let raw = extractJSONObject(from: sanitized)
                guard let data = raw.data(using: .utf8) else {
                    throw AICompositionGeneratorError.invalidModelResponse
                }
                let decoded: ModelDraft
                do {
                    decoded = try JSONDecoder().decode(ModelDraft.self, from: data)
                } catch {
                    throw AICompositionGeneratorError.decodeFailure(raw: raw, details: String(describing: error))
                }
                return clamped(decoded, prompt: prompt, providerModel: "FoundationModels/SystemLanguageModel.default")
            } catch {
                debugLog("[AI] FoundationModels generation failed; using local fallback draft. Error: \(error)")
                return fallbackDraft(from: prompt, providerModel: "fallback/local_generation_error")
            }
        }
#endif
        debugLog("[AI] FoundationModels unsupported in this build; using local fallback draft.")
        return fallbackDraft(from: prompt, providerModel: "fallback/local_unsupported")
    }

    private func sanitizeModelResponse(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
        cleaned = cleaned.replacingOccurrences(of: "```", with: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractJSONObject(from text: String) -> String {
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return text
    }

    private func clamped(_ draft: ModelDraft, prompt: String, providerModel: String) -> AICompositionDraft {
        let fallbackName = prompt
            .split(separator: " ")
            .prefix(4)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let sanitizedName = (draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackName : draft.name)
        let finalName = sanitizedName.isEmpty ? "AI Composition" : sanitizedName
        let fallbackIcon = "wand.and.stars"
        let icon = draft.icon.isEmpty ? fallbackIcon : draft.icon
        let accent = draft.accentColorHex.hasPrefix("#") ? draft.accentColorHex : "#FFB340"

        var palette = draft.palette
        palette.saturation = min(100, max(0, palette.saturation))
        palette.hueShift = min(180, max(-180, palette.hueShift))
        palette.temperature = min(500, max(153, palette.temperature))

        var motion = draft.motion
        motion.speed = min(100, max(0, motion.speed))
        motion.spread = min(100, max(0, motion.spread))
        motion.offset = min(100, max(0, motion.offset))

        var envelope = draft.envelope
        envelope.bpm = min(240, max(20, envelope.bpm))
        envelope.depth = min(100, max(0, envelope.depth))
        envelope.attack = min(100, max(0, envelope.attack))
        envelope.decay = min(100, max(0, envelope.decay))
        envelope.dutyCycle = min(90, max(10, envelope.dutyCycle))
        envelope.minBrightness = min(50, max(0, envelope.minBrightness))
        envelope.maxBrightness = min(100, max(50, envelope.maxBrightness))

        var reaction = draft.reaction
        reaction.sensitivity = min(100, max(0, reaction.sensitivity))
        reaction.smoothing = min(100, max(0, reaction.smoothing))
        reaction.intensity = min(100, max(0, reaction.intensity))
        reaction.threshold = min(100, max(0, reaction.threshold))

        return AICompositionDraft(
            name: finalName,
            icon: icon,
            accentColorHex: accent,
            palette: palette,
            motion: motion,
            envelope: envelope,
            reaction: reaction,
            providerModel: providerModel
        )
    }

    private func fallbackDraft(from prompt: String, providerModel: String) -> AICompositionDraft {
        let lower = prompt.lowercased()
        let isForest = lower.contains("forest") || lower.contains("woods") || lower.contains("nature")
        let isSmooth = lower.contains("smooth") || lower.contains("calm") || lower.contains("soft")
        let isNight = lower.contains("night") || lower.contains("moon") || lower.contains("dark")

        let primaryHue: Double = isForest ? 0.33 : (isNight ? 0.60 : 0.11)
        let secondaryHue: Double = isForest ? 0.28 : (isNight ? 0.68 : 0.06)
        let sat: Double = isSmooth ? 0.45 : 0.70

        let c1 = HueColorUtils.xyFrom(hue: primaryHue, saturation: sat, brightness: 1.0)
        let c2 = HueColorUtils.xyFrom(hue: secondaryHue, saturation: sat * 0.9, brightness: 1.0)

        let palette = PaletteConfig(
            mode: .gradient,
            color1: CodableColor(x: c1.x, y: c1.y),
            color2: CodableColor(x: c2.x, y: c2.y),
            color3: nil,
            hueShift: 0,
            saturation: sat * 100,
            temperature: isNight ? 420 : 340,
            randomize: false
        )

        let motion = MotionConfig(
            pattern: isSmooth ? .wave : .cascade,
            speed: isSmooth ? 28 : 44,
            forward: true,
            spread: 68,
            offset: 42,
            mirror: false
        )

        let envelope = EnvelopeConfig(
            shape: isSmooth ? .breathe : .swell,
            bpm: isSmooth ? 36 : 52,
            depth: isSmooth ? 28 : 45,
            attack: 55,
            decay: 48,
            dutyCycle: 50,
            minBrightness: isNight ? 8 : 14,
            maxBrightness: isNight ? 70 : 88
        )

        let reaction = ReactionConfig()

        let draft = ModelDraft(
            name: prompt.split(separator: " ").prefix(3).map(String.init).joined(separator: " ").capitalized,
            icon: isForest ? "leaf.fill" : "wand.and.stars",
            accentColorHex: isForest ? "#4EA26D" : (isNight ? "#6A7DFF" : "#FFB340"),
            palette: palette,
            motion: motion,
            envelope: envelope,
            reaction: reaction
        )
        return clamped(draft, prompt: prompt, providerModel: providerModel)
    }
}

// MARK: - StudioViewModel

/// Tracks a running effect on a specific room.
struct RunningEffect {
    let cardID: String
    let card: StudioCard
    let room: RoomDisplayItem
    let lightIDs: [String]     // for per-light cleanup (bridgeNative)
    let isEntertainment: Bool  // true = DTLS session active
    let requestedTransport: CompositionPreferredTransport?
    let transportFallback: Bool
    /// Lights whose firmware accepted the effects_v2 upgrade — live
    /// speed/color slider writes target exactly these (bridgeNative only).
    var v2CapableLightIDs: [String] = []
}

enum CompositionTransportPreference: String {
    case auto
    case roomOnly
    case entertainmentArea
}

@MainActor
@Observable
final class StudioViewModel {

    // ── Selection state ───────────────────────────────────────
    var selectedRoom: RoomDisplayItem? = nil

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

    /// True if iOS "Dim Flashing Lights" is enabled — strobe brightness capped
    /// at 30%. The accommodation lives in MediaAccessibility (iOS 16.4+), not
    /// UIAccessibility; the old hardcoded `false` silently disabled it.
    var isDimFlashingLightsEnabled: Bool {
        MADimFlashingLightsEnabled()
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
    // loadsSynchronously: false — StudioView constructs this VM eagerly (and again on
    // every tab switch), so the composition-library file read + JSON decode must not run
    // on the main thread. Presets publish shortly after; mutations force a sync load first.
    let compositionStore = CompositionStore(loadsSynchronously: false)
    private let aiGenerator = AICompositionGenerator()
    var isGeneratingAIComposition = false
    var aiGenerationErrorMessage: String?
    var activeCompositionGamut: HueColorUtils.Gamut = .c
    var roomHasColorLights: Bool = true
    var restoredHarmonyRule: HarmonyRule? = nil
    let suggestedAIPrompts: [String] = [
        "Static Warm Sunset",
        "Cozy Reading Corner",
        "Energetic Club Pulse",
        "Blinking Christmas Lights"
    ]

    /// Template preset for "+ Create" — kept in the store for `apply()` lookup, hidden from Deck 3 grid.
    // nonisolated: a Sendable constant read from nonisolated contexts too
    // (CompositionEntityQuery.eligible, ScenesTabView's detached refresh).
    nonisolated static let composerStarterDraftPresetID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DA")!

    /// Stable card id for `+ Create` (not `comp_{uuid}`).
    static let composerStarterCardID = "composer_starter"

    /// Live composition param boxes, keyed by room id — the render loops
    /// read these each frame. UI writes on slider drag for instant response.
    private var activeCompositionBoxes: [String: CompositionParamBox] = [:]

    /// The editable box for the CURRENTLY SELECTED room. A single slot here
    /// meant the tray edited whatever room applied LAST, not the room on
    /// screen, whenever two rooms ran compositions at once. Get-only is
    /// enough: every editor binding mutates fields through the class
    /// reference; the two ownership writes go straight to the dict.
    var activeCompositionBox: CompositionParamBox? {
        guard let room = selectedRoom else { return nil }
        return activeCompositionBoxes[room.id]
    }

    // ── Status ────────────────────────────────────────────────
    var statusMessage: String = ""

    func configure(orchestrator: UnifiedOrchestrator) {
        self.orchestrator = orchestrator
        orchestrator.studioStopHandler = { [weak self] roomID, turnOffLights in
            await self?.stopFromNowPlaying(roomID: roomID, turnOffLights: turnOffLights)
        }
        if selectedRoom == nil, let first = orchestrator.allRooms.first {
            selectedRoom = first
        }
        restoreLastUsedParams()
    }

    /// Mirror a running effect into the orchestrator's shared now-playing
    /// registry (Dashboard bar, Tap-Dial punch target).
    private func publishNowPlaying(room: RoomDisplayItem, card: StudioCard) {
        orchestrator?.addActiveEffect(ActiveEffectEntry(
            id: room.id,
            roomName: room.name,
            groupedLightID: room.groupedLightID,
            effectID: card.id,
            effectName: card.name,
            effectIcon: card.icon,
            isAppDriven: card.requiresForeground && card.compositionTier != .bridgeOptimized
        ))
    }

    /// Stop routed from a non-Studio surface (Dashboard Now-Playing bar, Siri).
    /// `turnOffLights: true` = the tray Stop button's semantics, room goes off.
    /// `false` = tear the effect down but leave lights at their current state.
    func stopFromNowPlaying(roomID: String, turnOffLights: Bool = true) async {
        isExplicitStop = turnOffLights
        await stopEffect(on: roomID)
        // stopEffect's guard can bail (stale entry, missing grouped light) —
        // the bar entry must still clear or Stop appears to do nothing.
        orchestrator?.removeActiveEffect(roomID: roomID)
        statusMessage = ""
    }

    /// Restore per-card last-used params (clamped by the store). Values set
    /// earlier this session win over the persisted snapshot.
    private var didRestoreParams = false
    private func restoreLastUsedParams() {
        guard !didRestoreParams else { return }
        didRestoreParams = true
        let restored = StudioParamStore.shared.load(cards: effectCards + liveModeCards)
        paramValues.merge(restored.values) { session, _ in session }
        paramColors.merge(restored.colors) { session, _ in session }
    }

    /// Wipe a card back to factory defaults — dicts, persistence, and the
    /// running effect if it's live (app-driven loops fall back to their own
    /// defaults on an empty box; bridge-native re-applies v1+v2 defaults).
    func resetParams(for card: StudioCard) async {
        paramValues[card.id] = nil
        paramColors[card.id] = nil
        StudioParamStore.shared.saveNow(values: paramValues, colors: paramColors)
        guard card.id == runningCardID else { return }
        switch card.strategy {
        case .appDriven:
            orchestrator?.updateStudioParams(values: [:], colors: [:])
        case .bridgeNative:
            await apply(card)
        case .composition:
            break   // compositions revert via revertActiveComposition()
        }
    }

    /// Copy the backing preset's four layer configs back into the live box —
    /// the composer's "revert to saved".
    func revertActiveComposition() {
        guard let box = activeCompositionBox,
              let effect = currentRoomEffect,
              case .composition(let pid) = effect.card.strategy,
              pid != Self.composerStarterDraftPresetID,
              let preset = compositionStore.presets.first(where: { $0.id == pid }) else { return }
        box.palette = preset.palette
        box.motion = preset.motion
        box.envelope = preset.envelope
        box.reaction = preset.reaction
        box.triggerRESTBurst()
        statusMessage = "Reverted to saved '\(preset.name)'"
    }

    private enum PrefKeys {
        static let compositionTransportPreference = "compositionTransportPreference"
        static let compositionTransportPromptEnabled = "compositionTransportPromptEnabled"
    }

    var compositionTransportPreference: CompositionTransportPreference {
        get {
            let raw = UserDefaults.standard.string(forKey: PrefKeys.compositionTransportPreference) ?? CompositionTransportPreference.auto.rawValue
            return CompositionTransportPreference(rawValue: raw) ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: PrefKeys.compositionTransportPreference)
        }
    }

    var isCompositionTransportPromptEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: PrefKeys.compositionTransportPromptEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: PrefKeys.compositionTransportPromptEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: PrefKeys.compositionTransportPromptEnabled)
        }
    }

    func preferredEntertainmentForCompositionTier(_ tier: CompositionTier) -> Bool {
        switch compositionTransportPreference {
        case .auto:
            return tier != .bridgeOptimized
        case .roomOnly:
            return false
        case .entertainmentArea:
            return true
        }
    }

    var activeRESTCadenceForSelectedRoom: Double? {
        guard let orchestrator else { return nil }
        if let roomID = selectedRoom?.id,
           let roomCadence = orchestrator.activeRESTCadenceByRoom[roomID] {
            return roomCadence
        }
        return orchestrator.activeRESTCadence
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
        StudioParamStore.shared.scheduleSave(values: paramValues, colors: paramColors)
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
        StudioParamStore.shared.scheduleSave(values: paramValues, colors: paramColors)
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
        action: @escaping @Sendable (String) async -> Void
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
    private func resolveLightIDs(
        for room: RoomDisplayItem,
        api: HueAPIClient,
        cachedLights: [HueLight]? = nil
    ) async -> [String] {
        let refs = room.childResourceRefs
        guard !refs.isEmpty else { return [] }

        // Zones reference lights directly — no API call needed
        let hasDirectLightRefs = refs.contains { $0.rtype == "light" }
        if hasDirectLightRefs {
            let ids = refs.filter { $0.rtype == "light" }.map { $0.rid }
            debugLog("[Studio] 🔍 Resolved \(ids.count) lights from zone refs (no API call)")
            return ids
        }

        // Rooms reference devices — resolve via light.owner.rid
        let deviceIDs = Set(refs.map { $0.rid })
        let allLights: [HueLight]
        if let cachedLights {
            allLights = cachedLights
        } else {
            guard let fetchedLights = try? await api.fetchLights() else { return [] }
            allLights = fetchedLights
        }
        let roomLightIDs = allLights
            .filter { light in
                guard let ownerRID = light.owner?.rid else { return false }
                return deviceIDs.contains(ownerRID)
            }
            .map { $0.id }
        debugLog("[Studio] 🔍 Resolved \(roomLightIDs.count) lights from \(deviceIDs.count) device refs")
        return roomLightIDs
    }

    /// [HueLight] models for a set of light ids (effects_v2 capability
    /// checks need the decoded capability blocks, not just ids). Reuses the
    /// bridge inventory apply() already fetched for rooms; zones cost one GET.
    private func roomHueLights(
        lightIDs: [String],
        api: HueAPIClient,
        cachedLights: [HueLight]?
    ) async -> [HueLight] {
        let idSet = Set(lightIDs)
        if let cachedLights { return cachedLights.filter { idSet.contains($0.id) } }
        guard let all = try? await api.fetchLights() else { return [] }
        return all.filter { idSet.contains($0.id) }
    }

    /// Per-light effects_v2 upgrade (ported from the retired Effects surface
    /// in the R4 Effects-port commit). Speed maps the card's 0–100 slider to
    /// the API's 0…1; color is sent only when the user picked a base_color.
    /// retry: false — a light that 400s must not stall the gate; it keeps
    /// the v1 blanket. Returns the v2-capable light ids for live sliders.
    private func applyStudioEffectV2Parameters(
        card: StudioCard,
        effectName: String,
        roomLights: [HueLight],
        api: HueAPIClient,
        gate: BridgeCommandGate
    ) async -> [String] {
        let v2Capable = roomLights.filter {
            ($0.effects_v2?.action?.effect_values ?? []).contains(effectName)
        }
        guard !v2Capable.isEmpty else { return [] }

        var speed: Double? = nil
        if let speedParam = card.params.first(where: { $0.id == "speed" }) {
            let raw = paramValue(for: card.id, paramID: "speed",
                                 default: speedParam.defaultValue)
            speed = min(1.0, max(0.0, raw / 100.0))
        }
        var colorXY: CGPoint? = nil
        if let color = paramColor(for: card.id, paramID: "base_color") {
            let uiColor = UIColor(color)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
            uiColor.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
            let xy = HueColorUtils.xyFrom(hue: Double(h), saturation: Double(s), brightness: Double(b))
            colorXY = CGPoint(x: xy.x, y: xy.y)
        }
        // Warmth rides the same v2 apply — but only when the user actually
        // set it, so untouched cards keep the firmware's default look.
        var mirek: Int? = nil
        if card.params.contains(where: { $0.id == "warmth" }),
           let raw = paramValues[card.id]?["warmth"] {
            mirek = Int(raw.rounded())
        }
        guard speed != nil || colorXY != nil || mirek != nil else { return v2Capable.map(\.id) }

        let body = EffectsV2Body(effect: effectName, speed: speed, colorXY: colorXY, mirek: mirek)
        for light in v2Capable {
            _ = await gate.send(retry: false) {
                try await api.setLightEffectV2(id: light.id, body: body)
            }
        }
        return v2Capable.map(\.id)
    }

    // ── Coverage (R4 Effects port) ────────────────────────────

    /// Per-card firmware-effect coverage for the selected room — drives the
    /// "N OF M LIGHTS" badges on Deck 0 and the mixer-header badge.
    var effectCoverage: [String: EffectCapabilityResolver.Coverage] = [:]
    /// Room the current `effectCoverage` was computed for.
    @ObservationIgnored private var coverageRoomID: String?

    /// Rebuild coverage for the selected room. Keyed by card id; resolved by
    /// the strategy's effect-name string. Triggered by .task(id: room) in
    /// StudioView so rapid rolodex scrubs auto-cancel stale fetches.
    func refreshCoverage() async {
        guard let orchestrator, !orchestrator.isDemoMode,
              let room = selectedRoom,
              let api = orchestrator.hueClient(for: room.bridgeID) else {
            effectCoverage = [:]
            return
        }
        // Room switch: the visible badges are still the PREVIOUS room's
        // coverage until this finishes — clear rather than mislabel.
        if coverageRoomID != room.id {
            effectCoverage = [:]
            coverageRoomID = room.id
        }
        // Reuse the lights loadAll just cached instead of a fresh GET — this .task
        // fires at tab prewarm, right in the post-pairing REST storm, and Hue bridges
        // serialize CLIP v2 requests. Capability data is topology-stable, so a <60s
        // snapshot is authoritative; fall back to the network when stale or missing.
        let all: [HueLight]
        if Date().timeIntervalSince(orchestrator.lastLoadedAt) < 60,
           let cached = orchestrator.cachedRawLights(for: room.bridgeID) {
            all = cached
        } else {
            guard let fetched = try? await api.fetchLights() else { return }
            all = fetched
        }
        let ids = Set(await resolveLightIDs(for: room, api: api, cachedLights: all))
        guard !Task.isCancelled else { return }
        let lights = all.filter { ids.contains($0.id) }
        guard !lights.isEmpty else {
            effectCoverage = [:]
            return
        }
        var result: [String: EffectCapabilityResolver.Coverage] = [:]
        for card in effectCards {
            if case .bridgeNative(let name) = card.strategy {
                result[card.id] = EffectCapabilityResolver.coverage(for: name, lights: lights)
            }
        }
        effectCoverage = result
    }

    /// Resolve a room-dominant Hue gamut for color-clamping in Composer.
    private func resolveDominantGamut(
        for room: RoomDisplayItem,
        api: HueAPIClient,
        cachedLights: [HueLight]? = nil
    ) async -> HueColorUtils.Gamut {
        let allLights: [HueLight]
        if let cachedLights {
            allLights = cachedLights
        } else {
            guard let fetchedLights = try? await api.fetchLights() else { return .c }
            allLights = fetchedLights
        }

        let refs = room.childResourceRefs
        let roomLights: [HueLight]
        if refs.contains(where: { $0.rtype == "light" }) {
            let lightIDs = Set(refs.filter { $0.rtype == "light" }.map(\.rid))
            roomLights = allLights.filter { lightIDs.contains($0.id) }
        } else {
            let deviceIDs = Set(refs.map(\.rid))
            roomLights = allLights.filter { light in
                guard let ownerRID = light.owner?.rid else { return false }
                return deviceIDs.contains(ownerRID)
            }
        }

        guard !roomLights.isEmpty else {
            await MainActor.run { roomHasColorLights = false }
            return .c
        }
        var counts: [HueColorUtils.Gamut: Int] = [.a: 0, .b: 0, .c: 0]
        for light in roomLights {
            guard let raw = light.color?.gamut_type?.uppercased(),
                  let gamut = HueColorUtils.Gamut(rawValue: raw) else { continue }
            counts[gamut, default: 0] += 1
        }
        let totalColorLights = counts.values.reduce(0, +)
        await MainActor.run { roomHasColorLights = totalColorLights > 0 }
        return counts.max(by: { $0.value < $1.value })?.key ?? .c
    }

    func apply(_ card: StudioCard) async {
        await apply(card, roomOverride: nil, preferEntertainmentOverride: nil)
    }

    /// Apply using a captured room snapshot to avoid room-selection races
    /// when taps and room-swipes happen close together.
    func apply(_ card: StudioCard, roomOverride: RoomDisplayItem?, preferEntertainmentOverride: Bool?) async {
        debugLog("[Studio] apply '\(card.name)' — selectedRoom: \(selectedRoom?.name ?? "nil")")
        guard let room = roomOverride ?? selectedRoom else {
            statusMessage = "⚠ Select a room first"
            debugLog("[Studio] ❌ No room selected")
            return
        }
        guard let groupedLightID = room.groupedLightID else {
            statusMessage = "⚠ Room '\(room.name)' has no room control"
            debugLog("[Studio] ❌ Room '\(room.name)' has no groupedLightID")
            return
        }
        guard let orchestrator else {
            debugLog("[Studio] ❌ orchestrator is nil")
            return
        }
        guard let api = orchestrator.hueClient(for: room.bridgeID) else {
            debugLog("[Studio] ❌ hueClient(for: \(room.bridgeID ?? "nil")) returned nil")
            return
        }
        debugLog("[Studio] ✅ All guards passed — groupedLightID: \(groupedLightID), bridgeID: \(room.bridgeID ?? "nil"), strategy: \(card.strategy)")

        // ── Stop any effect already running on THIS room ─────────────
        if let existing = runningEffects[room.id] {
            let existingCard = existing.card
            debugLog("[Studio] Replacing '\(existingCard.name)' on \(room.name)")
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

        // ── Studio engine is singleton in orchestrator for app-driven cards. ────────
        // Composition now runs per-room and can coexist across rooms.
        let newUsesStudioEngine: Bool = {
            switch card.strategy {
            case .appDriven: return true
            case .composition, .bridgeNative: return false
            }
        }()
        if newUsesStudioEngine {
            for (roomID, effect) in runningEffects where roomID != room.id {
                let effectUsesStudioEngine: Bool = {
                    switch effect.card.strategy {
                    case .appDriven: return true
                    case .composition, .bridgeNative: return false
                    }
                }()
                guard effectUsesStudioEngine else { continue }
                debugLog("[Studio] Stopping '\(effect.card.name)' on \(effect.room.name) (single Studio engine loop)")
                isExplicitStop = false
                await stopEffect(on: roomID)
            }
        }

        // ── If new card is entertainment-scoped, stop any existing entertainment effect ──
        if card.isEntertainmentScoped {
            for (roomID, effect) in runningEffects where effect.isEntertainment {
                debugLog("[Studio] Stopping entertainment '\(effect.card.name)' on \(effect.room.name) (only one DTLS session allowed)")
                isExplicitStop = false
                await stopEffect(on: roomID)
            }
        }

        // ── Check for light overlap with other running rooms ─────────
        // (e.g. Home zone overlaps individual rooms)
        let needsBridgeLightInventory = room.childResourceRefs.contains { $0.rtype != "light" }
        let bridgeLights: [HueLight]? =
            needsBridgeLightInventory ? (try? await api.fetchLights()) : nil
        let newLightIDs = await resolveLightIDs(for: room, api: api, cachedLights: bridgeLights)

        if !newLightIDs.isEmpty {
            let newLightSet = Set(newLightIDs)
            for (roomID, effect) in runningEffects {
                let overlap = Set(effect.lightIDs).intersection(newLightSet)
                if !overlap.isEmpty {
                    debugLog("[Handoff] Light overlap detected: \(overlap.count) lights shared with \(effect.room.name) — awaiting teardown barrier")
                    isExplicitStop = false
                    await stopEffect(on: roomID)
                    debugLog("[Handoff] Overlap teardown barrier complete for \(effect.room.name)")
                }
            }
        }

        debugLog("[Handoff] Startup barrier clear for '\(card.name)' on \(room.name); beginning startup sequence")

        let brightness = paramValue(for: card.id, paramID: "brightness", default: 70)

        switch card.strategy {
        case .bridgeNative(let effectName):
            // If the routing verdict below comes back "no light can run this",
            // the group-on we are about to send is the only thing that changed —
            // remember whether we did it to a dark room so we can undo it.
            let roomWasOff = !room.isOn

            // Step 1: Turn on group with brightness (1 grouped_light PUT).
            debugLog("[Studio] 📡 Group ON + bri=\(brightness) → \(room.name)")
            try? await api.setGroupedLightState(
                id: groupedLightID, on: true, brightness: brightness
            )

            // Step 2: Apply effect per-light.
            let lightIDs = newLightIDs.isEmpty
                ? await resolveLightIDs(for: room, api: api, cachedLights: bridgeLights)
                : newLightIDs
            if lightIDs.isEmpty {
                statusMessage = "⚠ No lights found in \(room.name)"
                return
            }
            // Fire the blanket first: this is a live performance surface, and
            // `bridgeLights` is usually nil, so resolving capability up front
            // would put a fetchLights() between the tap and the first bulb.
            // Incapable lights answer the PUT with a 400 and change nothing.
            debugLog("[Studio] 📡 Per-light effect=\(effectName) to \(lightIDs.count) lights in \(room.name)")
            await sendPerLightBatched(lightIDs: lightIDs, api: api) { id in
                try? await api.setLightNativeEffect(id: id, effect: effectName)
            }

            // Step 3 (R4 Effects port): gate-paced per-light effects_v2
            // parameter upgrade — real speed/color on capable lights; lights
            // that reject v2 keep the parameterless v1 blanket above.
            let roomLights = await roomHueLights(
                lightIDs: lightIDs, api: api, cachedLights: bridgeLights
            )
            let v2Capable = await applyStudioEffectV2Parameters(
                card: card, effectName: effectName, roomLights: roomLights,
                api: api, gate: orchestrator.commandGate(for: room.bridgeID)
            )

            // Now say what actually happened. Those 400s were discarded, so a
            // room of white-only bulbs used to report a cheerful green success
            // over a room that had not changed at all.
            let routing = EffectCapabilityResolver.routing(
                for: effectName, lights: roomLights, fallbackIDs: lightIDs
            )
            let drivenIDs: [String]
            var coverage: EffectCapabilityResolver.Coverage? = nil

            switch routing {
            case .unsupported:
                effectCoverage[card.id] = EffectCapabilityResolver.coverage(
                    for: effectName, lights: roomLights)
                // Nothing is running, so leave nothing behind: Step 1 switched
                // the group on, and abandoning that leaves a dark room lit with
                // "⚠ no lights can run…" and no stop affordance. Only undo what
                // we did — a room that was already on stays on.
                if roomWasOff {
                    try? await api.setGroupedLight(id: groupedLightID, on: false)
                }
                statusMessage = "⚠ No lights in \(room.name) can run \(card.name)"
                HapticManager.shared.light()
                return   // nothing is running; do not register an effect
            case .run(let ids, let cov):
                drivenIDs = ids      // teardown targets only the lights we moved
                coverage = cov
            case .runUnverified(let ids):
                drivenIDs = ids      // capability unknown; assume the bridge obliged
            }

            if let coverage { effectCoverage[card.id] = coverage }

            runningEffects[room.id] = RunningEffect(
                cardID: card.id, card: card, room: room,
                lightIDs: drivenIDs, isEntertainment: false,
                requestedTransport: nil, transportFallback: false,
                v2CapableLightIDs: v2Capable
            )
            publishNowPlaying(room: room, card: card)
            // Partial coverage is not a failure, but the user should hear it
            // from the status line rather than infer it from a badge.
            if let coverage, !coverage.isFull {
                statusMessage = "🟢 \(card.name) → \(room.name) — \(coverage.label) lights"
            } else {
                statusMessage = "🟢 \(card.name) → \(room.name)"
            }

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
            let isEnt = orchestrator.studioEntClients[room.bridgeID ?? ""] != nil
            runningEffects[room.id] = RunningEffect(
                cardID: card.id, card: card, room: room,
                lightIDs: newLightIDs, isEntertainment: isEnt,
                requestedTransport: nil, transportFallback: false
            )
            publishNowPlaying(room: room, card: card)
            let transport = isEnt ? TransportVocabulary.toastStreaming
                                  : TransportVocabulary.toastRoomMode
            statusMessage = "🟢 \(card.name) → \(room.name) · \(transport)"

        case .composition(let presetID):
            guard let preset = compositionStore.presets.first(where: { $0.id == presetID }) else {
                statusMessage = "⚠ Composition not found"
                return
            }
            let tier = preset.capabilityTier
            if tier == .bridgeOptimized {
                let phase = preset.motion.sample(
                    position: 0, radial: nil, angular: nil, lightIndex: 0, time: 0
                ).phase
                let color = preset.palette.color(at: phase)
                // tier == .bridgeOptimized guarantees reaction.source == .none,
                // so there is no reaction term in this one-shot snapshot.
                let brightnessNorm = preset.envelope.value(at: 0)
                let brightnessPct = min(100.0, max(1.0, brightnessNorm * 100.0))

                if preset.palette.mode == .temperature {
                    try? await api.setGroupedLightEffect(
                        id: groupedLightID,
                        on: true,
                        brightness: brightnessPct,
                        xy: nil,
                        mirek: preset.palette.temperature,
                        duration: 500
                    )
                } else {
                    try? await api.setGroupedLightEffect(
                        id: groupedLightID,
                        on: true,
                        brightness: brightnessPct,
                        xy: (color.x, color.y),
                        mirek: nil,
                        duration: 500
                    )
                }
                debugLog("[Composer] ⚡ bridgeOptimized one-shot applied for '\(preset.name)' on \(room.name)")
            } else {
                // Overlap mic startup with gamut fetch so voice-derived levels exist sooner (Sync-style responsiveness).
                async let gamutTask = resolveDominantGamut(for: room, api: api, cachedLights: bridgeLights)
                async let micHeadStart: Void = {
                    guard preset.reaction.requiresMic else { return }
                    await AudioAnalysisEngine.shared.setDemand(.composerReaction, active: true)
                }()
                // Prefer completing mic handoff before blocking on gamut result — bridge fetch still runs in parallel.
                await micHeadStart
                activeCompositionGamut = await gamutTask
                let box = CompositionParamBox(preset: preset)
                activeCompositionBoxes[room.id] = box
                // Restore persisted harmony rule for re-edit
                if let savedRule = preset.palette.harmonyRule,
                   let rule = HarmonyRule(rawValue: savedRule) {
                    restoredHarmonyRule = rule
                } else {
                    restoredHarmonyRule = nil
                }
                let presetPreferEntertainment: Bool?
                switch preset.preferredTransport {
                case .roomOnly:
                    presetPreferEntertainment = false
                case .entertainmentArea:
                    presetPreferEntertainment = true
                case nil:
                    presetPreferEntertainment = nil
                }
                let requestedEntertainment = preferEntertainmentOverride
                    ?? presetPreferEntertainment
                    ?? preferredEntertainmentForCompositionTier(tier)
                let requestedTransport: CompositionPreferredTransport = requestedEntertainment ? .entertainmentArea : .roomOnly

                await orchestrator.startCompositionMode(
                    room: room,
                    paramBox: box,
                    gamutOverride: activeCompositionGamut,
                    preferEntertainment: requestedEntertainment,
                    tier: tier,
                    preset: preset
                )
                let isEnt = orchestrator.studioEntClients[room.bridgeID ?? ""] != nil
                runningEffects[room.id] = RunningEffect(
                    cardID: card.id, card: card, room: room,
                    lightIDs: newLightIDs, isEntertainment: isEnt,
                    requestedTransport: requestedTransport,
                    transportFallback: requestedTransport == .entertainmentArea && !isEnt
                )
                publishNowPlaying(room: room, card: card)
                let transport = isEnt ? TransportVocabulary.toastStreaming
                                      : TransportVocabulary.toastRoomMode
                statusMessage = "🟢 \(card.name) → \(room.name) · \(transport)"
                if requestedTransport == .entertainmentArea && !isEnt {
                    statusMessage = "⚠ Streaming isn't available — playing \(room.name) in Room mode"
                }
                debugLog("[Studio] Active effects: \(runningEffects.count) rooms")
                return
            }
            runningEffects[room.id] = RunningEffect(
                cardID: card.id, card: card, room: room,
                lightIDs: newLightIDs, isEntertainment: false,
                requestedTransport: nil, transportFallback: false
            )
            publishNowPlaying(room: room, card: card)
            statusMessage = "🟢 \(card.name) → \(room.name) · \(TransportVocabulary.toastOneShot)"
        }

        debugLog("[Studio] Active effects: \(runningEffects.count) rooms")
    }

    /// Stop the effect running on a specific room.
    private func stopEffect(on roomID: String) async {
        guard let effect = runningEffects[roomID],
              let orchestrator,
              let api = orchestrator.hueClient(for: effect.room.bridgeID),
              let groupedLightID = effect.room.groupedLightID else { return }

        debugLog("[Studio] Stopping '\(effect.card.name)' on \(effect.room.name) (glID: \(groupedLightID)) explicit=\(isExplicitStop)")

        switch effect.card.strategy {
        case .bridgeNative:
            // Clean up per-light effects (the ONLY way to clear them)
            if !effect.lightIDs.isEmpty {
                debugLog("[Handoff] Clearing per-light no_effect on \(effect.lightIDs.count) lights for \(effect.room.name)")
                await sendPerLightBatched(lightIDs: effect.lightIDs, api: api) { id in
                    try? await api.setLightNativeEffect(id: id, effect: "no_effect")
                }
                // Allow bridge-side effect transition buffers to settle before a new owner starts.
                try? await Task.sleep(for: .milliseconds(150))
                debugLog("[Handoff] Per-light no_effect cleanup + settle delay complete for \(effect.room.name)")
            }

            if isExplicitStop {
                // User tapped Stop — turn off the room (1 PUT)
                try? await api.setGroupedLight(id: groupedLightID, on: false)
            }

        case .appDriven:
            // Room-scoped: the global stopStudioMode() tore down every other
            // room's composition stream and the whole Now-Playing registry.
            await orchestrator.stopAppDrivenStudioEffect(roomID: roomID,
                                                         bridgeID: effect.room.bridgeID)
            try? await Task.sleep(for: .milliseconds(200))

        case .composition:
            await orchestrator.stopCompositionMode(roomID: roomID)
            // Keyed by the STOPPING room — the old single-slot nil-out
            // clobbered the selected room's editor when another room stopped.
            activeCompositionBoxes.removeValue(forKey: roomID)
            if isExplicitStop {
                // Ensure composition cards (including bridge one-shot tier)
                // fully release control and don't appear "stuck on".
                try? await api.setGroupedLight(id: groupedLightID, on: false)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        runningEffects.removeValue(forKey: roomID)
        orchestrator.removeActiveEffect(roomID: roomID)
    }

    /// Explicit stop — called when user taps the stop button directly.
    /// Turns off the room's lights.
    func explicitStop(_ card: StudioCard) async {
        guard let room = selectedRoom else { return }
        isExplicitStop = true
        await stopEffect(on: room.id)
        statusMessage = ""
    }

    /// Stop all running effects across all rooms.
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
            let card = (effectCards + liveModeCards + composerStudioCards + [starterCompositionCard()]).first(where: { $0.id == cardID })
            let transitionMs = Int(paramValue(for: cardID, paramID: "transition", default: card?.params.first(where: { $0.id == "transition" })?.defaultValue ?? 400))

            // Live param PUTs go through the studio latest-wins mailbox —
            // a direct api call here (with only the 150 ms debounce) could
            // stack behind in-flight frames and replay stale slider values.
            switch paramID {
            case "brightness":
                await orchestrator.enqueueStudioRestWrite {
                    try? await api.setGroupedLightEffect(
                        id: groupedLightID, on: nil,
                        brightness: value, xy: nil, mirek: nil,
                        duration: transitionMs
                    )
                }
            case "warmth":
                let mirek = Int(value.rounded())
                // R5: while a bridge-native effect runs on v2-capable lights,
                // re-parameterize the EFFECT's color_temperature per-light —
                // a grouped mirek PUT fights the running firmware effect.
                // Mirrors the speed case below; grouped stays the v1 fallback.
                if let effect = runningEffects[room.id],
                   effect.cardID == cardID,
                   case .bridgeNative(let effectName) = effect.card.strategy,
                   !effect.v2CapableLightIDs.isEmpty {
                    let gate = orchestrator.commandGate(for: room.bridgeID)
                    let capable = effect.v2CapableLightIDs
                    await orchestrator.enqueueStudioRestWrite {
                        for id in capable {
                            _ = await gate.send(retry: false) {
                                try await api.setLightEffectV2(
                                    id: id,
                                    body: EffectsV2Body(effect: effectName, mirek: mirek)
                                )
                            }
                        }
                    }
                } else {
                    await orchestrator.enqueueStudioRestWrite {
                        try? await api.setGroupedLightEffect(
                            id: groupedLightID, on: nil,
                            brightness: nil, xy: nil, mirek: mirek,
                            duration: transitionMs
                        )
                    }
                }
            case "transition":
                // Stored locally — affects subsequent brightness/warmth/color sends.
                // No immediate bridge command needed.
                break
            case "speed":
                // R4 Effects port: while a bridge-native effect runs on
                // v2-capable lights, the speed slider re-parameterizes the
                // effect itself per-light (latest-wins mailbox + gate pacing).
                if let effect = runningEffects[room.id],
                   effect.cardID == cardID,
                   case .bridgeNative(let effectName) = effect.card.strategy,
                   !effect.v2CapableLightIDs.isEmpty {
                    let clamped = min(1.0, max(0.0, value / 100.0))
                    let gate = orchestrator.commandGate(for: room.bridgeID)
                    let capable = effect.v2CapableLightIDs
                    await orchestrator.enqueueStudioRestWrite {
                        for id in capable {
                            _ = await gate.send(retry: false) {
                                try await api.setLightEffectV2(
                                    id: id,
                                    body: EffectsV2Body(effect: effectName, speed: clamped)
                                )
                            }
                        }
                    }
                }
            case "saturation":
                // Bridge-native effects don't expose runtime saturation.
                // Value stored for app-driven engines.
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

            // R4 Effects port: while this bridge-native effect runs on
            // v2-capable lights, tint the EFFECT itself per-light; the
            // grouped xy write below stays the v1-only path.
            if let effect = runningEffects[room.id],
               effect.cardID == cardID,
               case .bridgeNative(let effectName) = effect.card.strategy,
               !effect.v2CapableLightIDs.isEmpty {
                let gate = orchestrator.commandGate(for: room.bridgeID)
                let capable = effect.v2CapableLightIDs
                let point = CGPoint(x: xy.x, y: xy.y)
                await orchestrator.enqueueStudioRestWrite {
                    for id in capable {
                        _ = await gate.send(retry: false) {
                            try await api.setLightEffectV2(
                                id: id,
                                body: EffectsV2Body(effect: effectName, colorXY: point)
                            )
                        }
                    }
                }
                return
            }

            // Same latest-wins routing as sendParam — see comment there.
            await orchestrator.enqueueStudioRestWrite {
                try? await api.setGroupedLightEffect(
                    id: groupedLightID, on: nil,
                    brightness: nil, xy: (xy.x, xy.y), mirek: nil,
                    duration: transitionMs
                )
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Composer Cards (from store)
    // ──────────────────────────────────────────────

    /// Sorted for Deck 3: in-season presets first, then alphabetical.
    var composerDeckPresetsSorted: [CompositionPreset] {
        compositionStore.presets
            .filter { $0.id != Self.composerStarterDraftPresetID }
            .sorted { a, b in
                if a.isInSeason != b.isInSeason { return a.isInSeason && !b.isInSeason }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    /// Deck 3 filter chip — `preset.category` never equals `.all` (virtual category).
    func composerPresets(for category: PresetCategory) -> [CompositionPreset] {
        switch category {
        case .all: return composerDeckPresetsSorted
        default: return composerDeckPresetsSorted.filter { $0.category == category }
        }
    }

    /// The "All" view, grouped into collapsible sections. Order: the user's own
    /// creations first (their work beats our catalog), then Holiday when it is
    /// actually in season, then the remaining categories in chip order. Empty
    /// categories don't render a header.
    func composerSections() -> [(category: PresetCategory, presets: [CompositionPreset])] {
        Self.sectionOrder(holidayInSeason: hasSeasonalCompositionPreset).compactMap { category in
            let presets = composerPresets(for: category)
            return presets.isEmpty ? nil : (category, presets)
        }
    }

    /// Composer creations that behave like firmware effects — surfaced on
    /// Deck 0 under the built-in cards, because that is where a user looks
    /// for "the things that move".
    var composerEffectPresets: [CompositionPreset] {
        composerDeckPresetsSorted.filter { PresetSurfaceClassifier.surface(for: $0) == .effect }
    }

    /// Composer creations that listen (mic/beat) — surfaced on Deck 1 next to
    /// party/strobe/thunderstorm.
    var composerLivePresets: [CompositionPreset] {
        composerDeckPresetsSorted.filter { PresetSurfaceClassifier.surface(for: $0) == .live }
    }

    /// Pure section ordering for the All view (unit-tested).
    static func sectionOrder(holidayInSeason: Bool) -> [PresetCategory] {
        var order: [PresetCategory] = [.myCreations]
        if holidayInSeason { order.append(.holiday) }
        order += PresetCategory.allCases.filter {
            $0 != .all && $0 != .myCreations && ($0 != .holiday || !holidayInSeason)
        }
        return order
    }

    /// Any non-starter preset is in-season (for Holiday chip emphasis).
    var hasSeasonalCompositionPreset: Bool {
        composerDeckPresetsSorted.contains(where: \.isInSeason)
    }

    func studioCard(for preset: CompositionPreset) -> StudioCard {
        let activity = compositionLayerActivity(for: preset)
        return StudioCard(
            id: "comp_\(preset.id.uuidString)",
            name: preset.name,
            tagline: "\(preset.palette.mode.rawValue.capitalized) • \(preset.motion.pattern.rawValue.capitalized) • \(preset.envelope.shape.rawValue.capitalized)",
            icon: preset.icon,
            accentColor: Color(hex: preset.accentColorHex),
            requiresForeground: true,
            params: [],
            strategy: .composition(presetID: preset.id),
            compositionLayerActivity: activity,
            compositionTier: preset.capabilityTier,
            isAIGenerated: preset.aiPrompt != nil || preset.providerModel != nil
        )
    }

    /// Card used exclusively by the `+ Create` control.
    func starterCompositionCard() -> StudioCard {
        return StudioCard(
            id: Self.composerStarterCardID,
            name: "New Composition",
            tagline: "Warm gradient • Breathe • Shape it in the mixer",
            icon: "sparkles",
            accentColor: HuePalette.amber,
            requiresForeground: true,
            params: [],
            strategy: .composition(presetID: Self.composerStarterDraftPresetID),
            compositionLayerActivity: CompositionLayerActivity(
                palette: false,
                motion: false,
                envelope: false,
                reaction: false
            ),
            isAIGenerated: false
        )
    }

    private func compositionLayerActivity(for preset: CompositionPreset) -> CompositionLayerActivity {
        let paletteActive =
            preset.palette.mode != .gradient ||
            preset.palette.hueShift != 0 ||
            preset.palette.saturation != 100 ||
            preset.palette.temperature != 366 ||
            preset.palette.randomize ||
            preset.palette.color3 != nil

        let motionActive =
            preset.motion.pattern != .cascade ||
            preset.motion.speed != 40 ||
            preset.motion.forward != true ||
            preset.motion.spread != 70 ||
            preset.motion.offset != 50 ||
            preset.motion.mirror

        let envelopeActive =
            preset.envelope.shape != .breathe ||
            preset.envelope.bpm != 60 ||
            preset.envelope.depth != 50 ||
            preset.envelope.attack != 50 ||
            preset.envelope.decay != 50 ||
            preset.envelope.dutyCycle != 50 ||
            preset.envelope.minBrightness != 10 ||
            preset.envelope.maxBrightness != 100

        let reactionActive =
            preset.reaction.source != .none ||
            preset.reaction.sensitivity != 70 ||
            preset.reaction.smoothing != 30 ||
            preset.reaction.intensity != 70 ||
            preset.reaction.threshold != 10 ||
            Set(preset.reaction.targets) != Set([.brightness])

        return CompositionLayerActivity(
            palette: paletteActive,
            motion: motionActive,
            envelope: envelopeActive,
            reaction: reactionActive
        )
    }

    /// Ensures the hidden starter template exists so `.composition(starterID)` resolves in `apply()`.
    func ensureComposerStarterDraft() {
        guard !compositionStore.presets.contains(where: { $0.id == Self.composerStarterDraftPresetID }) else { return }
        let now = Date()
        let draft = CompositionPreset(
            id: Self.composerStarterDraftPresetID,
            name: "New Composition",
            icon: "sparkles",
            accentColorHex: "#FFB340",
            isBuiltIn: false,
            category: .myCreations,
            seasonMonths: nil,
            palette: PaletteConfig(
                mode: .gradient,
                color1: CodableColor.warmWhite,
                color2: CodableColor(x: 0.5500, y: 0.3900)
            ),
            motion: MotionConfig(pattern: .static, speed: 35, forward: true),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 28, depth: 22, minBrightness: 12, maxBrightness: 95),
            reaction: ReactionConfig(),
            createdAt: now,
            updatedAt: now,
            aiPrompt: nil,
            providerModel: nil
        )
        compositionStore.save(draft)
    }

    func applyStarterComposition() async {
        ensureComposerStarterDraft()
        // +Create should stay scoped to the selected room by default.
        await apply(starterCompositionCard(), roomOverride: nil, preferEntertainmentOverride: false)
    }

    func generateCompositionFromPrompt(_ rawPrompt: String) async -> CompositionPreset? {
        let prompt = String(rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
        guard !isGeneratingAIComposition else { return nil }
        guard !prompt.isEmpty else {
            aiGenerationErrorMessage = "Type a prompt first."
            return nil
        }

        isGeneratingAIComposition = true
        aiGenerationErrorMessage = nil
        defer { isGeneratingAIComposition = false }

        do {
            let draft = try await aiGenerator.generateDraft(from: prompt)
            let now = Date()
            let safeIcon = sanitizedSymbolName(draft.icon)
            if safeIcon != draft.icon {
                debugLog("[AI] Invalid SF Symbol '\(draft.icon)' from model. Falling back to '\(safeIcon)'.")
            }
            let preset = CompositionPreset(
                id: UUID(),
                name: draft.name,
                icon: safeIcon,
                accentColorHex: draft.accentColorHex,
                isBuiltIn: false,
                category: .myCreations,
                seasonMonths: nil,
                palette: draft.palette,
                motion: draft.motion,
                envelope: draft.envelope,
                reaction: draft.reaction,
                createdAt: now,
                updatedAt: now,
                aiPrompt: prompt,
                providerModel: draft.providerModel
            )
            compositionStore.save(preset)
            statusMessage = "✨ Generated '\(preset.name)'"
            return preset
        } catch {
            if case let AICompositionGeneratorError.decodeFailure(raw: raw, details: details) = error {
                debugLog("[AI] Decode failure details: \(details)")
                debugLog("[AI] Raw model response JSON candidate: \(raw)")
            } else {
                debugLog("[AI] Generation failure: \(error)")
            }
            let message = (error as? LocalizedError)?.errorDescription ?? "Couldn’t generate composition. Try a different prompt."
            aiGenerationErrorMessage = message
            statusMessage = "⚠ \(message)"
            return nil
        }
    }

    /// Persist the currently running composition params as a new user preset.
    func saveActiveComposition(
        name rawName: String,
        icon: String,
        accentColorHex: String = "#FFB340",
        preferredTransport: CompositionPreferredTransport?,
        category: PresetCategory = .myCreations
    ) -> CompositionPreset? {
        guard let box = activeCompositionBox else { return nil }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeIcon = sanitizedSymbolName(icon)
        let now = Date()
        let preset = CompositionPreset(
            id: UUID(),
            name: trimmed.isEmpty ? "My Composition" : trimmed,
            icon: safeIcon,
            accentColorHex: accentColorHex,
            isBuiltIn: false,
            // `.all` is a virtual filter, never a real category on a preset.
            category: category == .all ? .myCreations : category,
            seasonMonths: nil,
            palette: box.palette,
            motion: box.motion,
            envelope: box.envelope,
            reaction: box.reaction,
            createdAt: now,
            updatedAt: now,
            preferredTransport: preferredTransport
        )
        compositionStore.save(preset)
        return preset
    }

    private func sanitizedSymbolName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "sparkles" }
        return UIImage(systemName: trimmed) != nil ? trimmed : "sparkles"
    }

    func renameCompositionPreset(id: UUID, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let idx = compositionStore.presets.firstIndex(where: { $0.id == id }) else { return }
        var preset = compositionStore.presets[idx]
        preset.name = name
        preset.updatedAt = Date()
        compositionStore.save(preset)
        guard let fresh = compositionStore.presets.first(where: { $0.id == id }) else { return }

        let roomIDs = Array(runningEffects.keys).filter { roomID in
            guard let effect = runningEffects[roomID] else { return false }
            guard case .composition(let pid) = effect.card.strategy else { return false }
            return pid == id
        }
        for roomID in roomIDs {
            guard let effect = runningEffects[roomID] else { continue }
            let freshCard = studioCard(for: fresh)
            runningEffects[roomID] = RunningEffect(
                cardID: effect.cardID,
                card: freshCard,
                room: effect.room,
                lightIDs: effect.lightIDs,
                isEntertainment: effect.isEntertainment,
                requestedTransport: effect.requestedTransport,
                transportFallback: effect.transportFallback
            )
            publishNowPlaying(room: effect.room, card: freshCard)
        }
    }

    func duplicateCompositionPreset(_ preset: CompositionPreset) {
        _ = compositionStore.duplicate(preset)
    }

    /// Upload a saved preset to its room's bridge as a native dynamic scene.
    /// The bridge then cycles the palette on its own — app closed, phone away.
    /// This is the third engine, and the only one that outlives the app.
    ///
    /// Works straight from the stored preset, so it does not require the
    /// composition to be running first (the Composer's own export operates on
    /// the live, possibly-unsaved param box instead).
    func exportPresetAsDynamicScene(_ preset: CompositionPreset, named name: String) async {
        if let reason = BridgeDynamicSceneExporter.ineligibilityReason(for: preset) {
            statusMessage = "⚠ \(reason)"
            return
        }
        guard let orchestrator,
              let room = selectedRoom,
              let groupedLightID = room.groupedLightID,
              let api = orchestrator.hueClient(for: room.bridgeID) else {
            statusMessage = "⚠ Select a room first"
            return
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sceneName = trimmed.isEmpty ? preset.name : trimmed

        do {
            let ids = Set(try await api.fetchLightIDsForGroup(groupedLightID: groupedLightID))
            let lights = try await api.fetchLights().filter { ids.contains($0.id) }
            guard !lights.isEmpty else {
                statusMessage = "⚠ No lights found in '\(room.name)'"
                return
            }

            let gamut = await resolveDominantGamut(for: room, api: api, cachedLights: nil)
            let recipe = BridgeDynamicSceneExporter.recipe(for: preset, gamut: gamut)

            let request = CreateSceneRequest.dynamicScene(
                name: sceneName,
                groupID: room.id,
                groupRtype: room.kind == .zone ? "zone" : "room",
                lights: lights,
                paletteXY: recipe.palette.map { (x: $0.x, y: $0.y) },
                brightness: recipe.brightness,
                speed: recipe.speed
            )
            let sceneID = try await api.createSceneReturningID(request)
            if let bridgeID = room.bridgeID {
                SceneProvenanceStore.shared.markStudioExported(bridgeID: bridgeID, sceneID: sceneID)
            }
            statusMessage = BridgeDynamicSceneExporter.successMessage(
                name: sceneName, willAnimate: recipe.willAnimate)
            HapticManager.shared.medium()
            await orchestrator.loadAllScenes()
        } catch HueAPIError.decodingFailed {
            // The POST landed — only the id parse failed. The scene exists.
            statusMessage = "'\(sceneName)' saved to your bridge ✓ — find it in Scenes"
            HapticManager.shared.medium()
            await orchestrator.loadAllScenes()
        } catch {
            statusMessage = "⚠ Couldn't save the scene — \(error.localizedDescription)"
        }
    }

    /// Re-file a saved preset under a different category chip. Works on any
    /// preset, including built-ins — a reset (delete) still restores a
    /// built-in's shipped category, since the catalog copy wins.
    func setCategory(_ category: PresetCategory, for preset: CompositionPreset) {
        guard category != .all,   // virtual filter, never a stored value
              let idx = compositionStore.presets.firstIndex(where: { $0.id == preset.id }) else { return }
        var updated = compositionStore.presets[idx]
        guard updated.category != category else { return }
        updated.category = category
        updated.updatedAt = Date()
        compositionStore.save(updated)
    }

    /// Persist which engine a preset asks for. `nil` means Auto: let
    /// `preferredEntertainmentForCompositionTier` decide at apply time.
    /// Takes effect on the next apply — a running effect is switched from the
    /// mixer tray's transport badge instead.
    func setPreferredTransport(_ transport: CompositionPreferredTransport?, for preset: CompositionPreset) {
        guard let idx = compositionStore.presets.firstIndex(where: { $0.id == preset.id }) else { return }
        var updated = compositionStore.presets[idx]
        guard updated.preferredTransport != transport else { return }
        updated.preferredTransport = transport
        updated.updatedAt = Date()
        compositionStore.save(updated)
    }

    func deleteCompositionPreset(_ preset: CompositionPreset) async {
        let card = studioCard(for: preset)
        if runningCardID == card.id {
            await explicitStop(card)
        }
        compositionStore.delete(preset)
    }

    /// Build StudioCards from saved CompositionPresets (Deck 3 grid only — starter template excluded).
    var composerStudioCards: [StudioCard] {
        composerDeckPresetsSorted.map { studioCard(for: $0) }
    }

    // ──────────────────────────────────────────────
    // MARK: - Card Catalog
    // ──────────────────────────────────────────────

    // internal (not private): StudioIntentTests pins StudioEffectChoice's
    // case list to these catalogs so a new deck card can't silently be
    // missing from Siri.
    static func buildEffectCards() -> [StudioCard] {
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
                    StudioParam(id: "speed", label: "Flicker Rate", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                    StudioParam(id: "warmth", label: "Warmth", kind: .slider(min: 153, max: 500), defaultValue: 366, tier: .color, format: StudioParamFormat.kelvin),
                    StudioParam(id: "base_color", label: "Base Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 400, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "candle"),
                compositionLayerActivity: nil
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
                    StudioParam(id: "speed", label: "Flicker Rate", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                    StudioParam(id: "warmth", label: "Warmth", kind: .slider(min: 153, max: 500), defaultValue: 400, tier: .color, format: StudioParamFormat.kelvin),
                    StudioParam(id: "base_color", label: "Base Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 400, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "fire"),
                compositionLayerActivity: nil
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
                    StudioParam(id: "speed", label: "Twinkle Rate", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                    StudioParam(id: "base_color", label: "Base Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 400, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "sparkle"),
                compositionLayerActivity: nil
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
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 1500, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "prism"),
                compositionLayerActivity: nil
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
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 40, tier: .essential),
                    StudioParam(id: "warmth", label: "Warmth", kind: .slider(min: 153, max: 500), defaultValue: 300, tier: .color, format: StudioParamFormat.kelvin),
                    StudioParam(id: "base_color", label: "Base Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 400, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "opal"),
                compositionLayerActivity: nil
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
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                    StudioParam(id: "base_color", label: "Base Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 400, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "glisten"),
                compositionLayerActivity: nil
            ),
            StudioCard(
                id: "cosmos",
                name: "Cosmos",
                tagline: "Drifting starfield shimmer",
                icon: "moon.stars.fill",
                accentColor: Color(hex: "#5E5CE6"),
                requiresForeground: false,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                    StudioParam(id: "base_color", label: "Tint", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 400, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "cosmos"),
                compositionLayerActivity: nil
            ),
            StudioCard(
                id: "enchant",
                name: "Enchant",
                tagline: "Slow magical color weave",
                icon: "wand.and.stars",
                accentColor: Color(hex: "#BF5AF2"),
                requiresForeground: false,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                    StudioParam(id: "base_color", label: "Tint", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 400, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "enchant"),
                compositionLayerActivity: nil
            ),
            StudioCard(
                id: "sunbeam",
                name: "Sunbeam",
                tagline: "Warm rays drifting through",
                icon: "sun.max.fill",
                accentColor: Color(hex: "#FF9F0A"),
                requiresForeground: false,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 75, tier: .essential),
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 40, tier: .essential),
                    StudioParam(id: "base_color", label: "Tint", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 400, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "sunbeam"),
                compositionLayerActivity: nil
            ),
            StudioCard(
                id: "underwater",
                name: "Underwater",
                tagline: "Caustic light through water",
                icon: "water.waves",
                accentColor: Color(hex: "#32ADE6"),
                requiresForeground: false,
                params: [
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 70, tier: .essential),
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                    StudioParam(id: "base_color", label: "Tint", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 400, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "underwater"),
                compositionLayerActivity: nil
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
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 1500, tier: .advanced),
                ],
                strategy: .bridgeNative(effect: "colorloop"),
                compositionLayerActivity: nil
            ),
        ]
    }

    static func buildLiveModeCards() -> [StudioCard] {
        return [
            StudioCard(
                id: "party",
                name: "Party",
                tagline: "Fast multi-color flashes synchronized across the room",
                icon: "party.popper.fill",
                accentColor: Color(hex: "#BF5AF2"),
                requiresForeground: true,
                params: [
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 60, tier: .essential, format: StudioParamFormat.flashHz),
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 90, tier: .essential),
                    StudioParam(id: "color", label: "Flash Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "min_brightness", label: "Fade Floor", kind: .slider(min: 0, max: 50), defaultValue: 5, tier: .advanced),
                    StudioParam(id: "smoothness", label: "Smoothness", kind: .slider(min: 0, max: 100), defaultValue: 20, tier: .essential),
                ],
                strategy: .appDriven(engineKey: "party"),
                compositionLayerActivity: nil
            ),
            StudioCard(
                id: "strobe",
                name: "Strobe",
                tagline: "High-frequency white flash — use responsibly",
                icon: "bolt.fill",
                accentColor: Color(hex: "#FFC107"),
                requiresForeground: true,
                params: [
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential, format: StudioParamFormat.flashHz, entOnly: true),
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 100, tier: .essential),
                    StudioParam(id: "flash_color", label: "Flash Color", kind: .colorPicker, defaultValue: 0, tier: .color, entOnly: true),
                    StudioParam(id: "min_brightness", label: "Min Brightness", kind: .slider(min: 0, max: 50), defaultValue: 0, tier: .advanced),
                    StudioParam(id: "duty_cycle", label: "Duty Cycle", kind: .slider(min: 10, max: 90), defaultValue: 50, tier: .advanced, entOnly: true),
                ],
                strategy: .appDriven(engineKey: "strobe"),
                compositionLayerActivity: nil
            ),
            StudioCard(
                id: "thunderstorm",
                name: "Thunderstorm",
                tagline: "Random lightning strikes with dim ambient fill",
                icon: "cloud.bolt.fill",
                accentColor: Color(hex: "#668AFF"),
                requiresForeground: true,
                params: [
                    StudioParam(id: "frequency", label: "Storm Intensity", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .essential),
                    StudioParam(id: "flash_intensity", label: "Flash Brightness", kind: .slider(min: 20, max: 100), defaultValue: 90, tier: .essential),
                    StudioParam(id: "ambient_color", label: "Ambient Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "flash_color", label: "Flash Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "min_brightness", label: "Ambient Level", kind: .slider(min: 1, max: 30), defaultValue: 5, tier: .advanced),
                    // Every knob the engine has, exposed. Defaults reproduce the
                    // storm exactly as it behaved when these were literals.
                    StudioParam(id: "strike_rate", label: "Strike Chance", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .advanced),
                    StudioParam(id: "flash_length", label: "Flash Length", kind: .slider(min: 1, max: 8), defaultValue: 3, tier: .advanced),
                    StudioParam(id: "afterglow", label: "Afterglow", kind: .slider(min: 0, max: 5), defaultValue: 1, tier: .advanced),
                ],
                strategy: .appDriven(engineKey: "thunderstorm"),
                compositionLayerActivity: nil
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
                    StudioParam(id: "warmth", label: "Warmth", kind: .slider(min: 153, max: 500), defaultValue: 350, tier: .color, format: StudioParamFormat.kelvin),
                    StudioParam(id: "smoothness", label: "Smoothness", kind: .slider(min: 0, max: 100), defaultValue: 70, tier: .advanced),
                    StudioParam(id: "min_brightness", label: "Min Brightness", kind: .slider(min: 1, max: 50), defaultValue: 15, tier: .advanced),
                ],
                strategy: .appDriven(engineKey: "ambient"),
                compositionLayerActivity: nil
            ),
        ]
    }
}


/// DEBUG-only console diagnostics (house convention — see UnifiedOrchestrator).
/// Release builds compile the call away, keeping room and composition names
/// out of the release console.
fileprivate func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

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

    /// Prominence metadata for the board descriptor (Slice 2). The old
    /// `.advanced` bucket — a user-facing "Advanced section" — is retired
    /// per spec §2.3: there is no Advanced product concept. `.support`
    /// marks quieter refinements that render smaller and later in the ONE
    /// board, never hidden behind a disclosure.
    enum ParamTier: String {
        case essential  // the look's everyday controls
        case color      // color-semantic controls (inline B+ editor)
        case support    // quieter refinements — visible, just not loud
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

/// Exact identity of a running-effect row (round 4c). The same room id can
/// exist on two bridges, and a room-id-only key silently overwrites one
/// bridge's row with the other's — which is how one bridge's failed save or
/// stop used to erase the other's record. Destructive row removal always uses
/// this key; room-only callers go through the fail-closed
/// `runningEffect(forRoomID:)` read instead.
struct RoomEffectKey: Hashable {
    let bridgeID: String?
    let roomID: String

    init(bridgeID: String?, roomID: String) {
        self.bridgeID = bridgeID
        self.roomID = roomID
    }

    init(room: RoomDisplayItem) {
        self.init(bridgeID: room.bridgeID, roomID: room.id)
    }
}

/// Exact identity of the Studio SELECTION, for the side effects that refire
/// when the selected room changes (coverage badges, the customization surface's
/// view identity).
///
/// `RoomEffectKey` keys running effects; this keys the selection that drives
/// per-room *reads*. They are deliberately separate: a selection exists with no
/// effect running, and the selection is what `.task(id:)` observes.
///
/// Why this is not a bare room id — the defect it fixes: two bridges can expose
/// the same Hue room id, so `.task(id: selectedRoom?.id)` did not refire when
/// the user switched between them, and `refreshCoverage`'s `coverageRoomID`
/// comparison did not clear. Deck 0's "N OF M LIGHTS" badges then showed bridge
/// A's capabilities against bridge B's room. This is the same collision class
/// `RoomEffectKey` exists to prevent, reached through the read path.
///
/// `kind` is defense in depth for VIEW identity and the legacy nil-bridge path.
/// The Rolodex's two axes address rooms and zones from different bridge
/// collections, and nothing in the type system guarantees their id spaces are
/// disjoint — see the invariant documented at `CompositionPlaybackKey`, which
/// carries no kind because within one bridge a room id and a zone id can never
/// be equal (proved by `testRoomAndZoneIDsNeverCollideWithinABridge`).
struct StudioSelectionKey: Hashable {
    let bridgeID: String?
    let groupID: String
    let kind: RoomDisplayItem.Kind

    /// For SwiftUI `.id(…)` view identity only. Equality and hashing use the
    /// typed fields above — never this composed string, so a "|" inside a
    /// bridge or group id cannot alias two distinct selections.
    ///
    /// The `"legacy"` sentinel matches `CompositionPlaybackKey.bridgeKey` and
    /// `BridgeNativeOwnershipKey`, so a nil-bridge selection reads the same
    /// across every exact key in the app.
    var stableID: String { "\(bridgeID ?? "legacy")|\(kind.rawValue)|\(groupID)" }

    init(bridgeID: String?, groupID: String, kind: RoomDisplayItem.Kind) {
        self.bridgeID = bridgeID
        self.groupID = groupID
        self.kind = kind
    }

    init(room: RoomDisplayItem) {
        self.init(bridgeID: room.bridgeID, groupID: room.id, kind: room.kind)
    }
}

/// Tracks a running effect on a specific room.
struct RunningEffect {
    let cardID: String
    let card: StudioCard
    let room: RoomDisplayItem
    let lightIDs: [String]     // for per-light cleanup (bridgeNative)
    let isEntertainment: Bool  // true = DTLS session active
    let requestedTransport: CompositionPreferredTransport?
    let transportFallback: Bool
    /// The exact running identity (Slice 2 production wiring): bridge + group +
    /// kind + look + execution + generation. Every mutation captured against
    /// this row is fenced on THIS value at commit/send time — the weaker
    /// place-level keys never decide at a mutation boundary. `var` because
    /// reset/rekey advance the generation in place.
    var identity: RunningLookIdentity
    /// Lights whose firmware accepted the effects_v2 upgrade — live
    /// speed/color slider writes target exactly these (bridgeNative only).
    var v2CapableLightIDs: [String] = []
    /// The orchestrator-side claim that stops All-Day overwriting this room
    /// (packet 6). Set for `.bridgeNative` only: those are long-running firmware
    /// effects. One-shot `.bridgeOptimized` writes finish immediately and must
    /// never register persistent ownership.
    var bridgeNativeOwnership: UnifiedOrchestrator.BridgeNativeOwnershipToken? = nil
    /// Non-nil = this row MIRRORS a bridge-stored animation that was already
    /// running on the bridge when the app launched (packet 8).
    ///
    /// There is no app task, no Entertainment client, no REST scheduler and no
    /// mic demand behind it — only the bridge's own rule chain. Note that
    /// `activeCompositionBoxes` is deliberately NOT populated for these, which
    /// is what makes every live-edit control inert rather than fake.
    var recovered: UnifiedOrchestrator.RecoveredBridgeAnimationKey? = nil
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

    /// All currently running effects, keyed by EXACT bridge + group + KIND
    /// identity (Slice 2 production wiring). Round 4c fixed the same-room-id-
    /// on-two-bridges overwrite with `RoomEffectKey`; this migration adds the
    /// room-vs-zone axis the Slice 1 identity contract requires — a room and a
    /// zone sharing an identifier are two rows here, never one. Multiple
    /// targets can have independent effects running simultaneously.
    var runningEffects: [StudioSelectionKey: RunningEffect] = [:]

    /// The exact row for a room the caller can fully identify.
    func runningEffect(for room: RoomDisplayItem) -> RunningEffect? {
        runningEffects[StudioSelectionKey(room: room)]
    }

    /// Room-only compatibility read: the row when EXACTLY ONE target holds
    /// this group id, nil otherwise. Fail closed on a collision — a caller
    /// that cannot say which bridge (or which kind) must not be handed an
    /// arbitrary row.
    func runningEffect(forRoomID id: String) -> RunningEffect? {
        guard let key = runningEffectKey(forRoomID: id) else { return nil }
        return runningEffects[key]
    }

    /// Same exactly-one rule, resolving the key itself (for stops that enter
    /// with a bare room id from the Dashboard bar, Siri, or a handoff record).
    private func runningEffectKey(forRoomID id: String) -> StudioSelectionKey? {
        let keys = runningEffects.keys.filter { $0.groupID == id }
        guard keys.count == 1 else { return nil }
        return keys.first
    }

    /// Bridge-attributed compatibility resolution for records that carry
    /// bridge + group id but no kind (saved-look outcomes, handoff prompts,
    /// stop targets minted before the kind-aware key existed). Resolves the
    /// unique matching row and fails closed when a room and a zone share the
    /// id on that bridge — such a caller cannot say which one it means.
    func runningKey(bridgeID: String?, groupID: String) -> StudioSelectionKey? {
        let keys = runningEffects.keys.filter {
            $0.bridgeID == bridgeID && $0.groupID == groupID
        }
        guard keys.count == 1 else { return nil }
        return keys.first
    }

    /// A pending cross-surface handoff awaiting the user's answer.
    ///
    /// Non-nil means: a Studio card was tapped, a composition owns that bridge's
    /// Entertainment session, and NOTHING has been torn down yet. The whole point
    /// is that this state exists *before* any mutation — see `apply`.
    var entertainmentHandoffPrompt: EntertainmentHandoffPrompt? = nil

    /// Everything needed to either forget the request (cancel) or replay it
    /// unchanged (confirm). Carrying the original call's arguments is what makes
    /// cancel genuinely mutation-free: nothing had to be staged in advance.
    struct EntertainmentHandoffPrompt: Identifiable {
        let id = UUID()
        /// The composition currently streaming, named as the user knows it.
        let runningLookName: String
        /// The Studio look they just asked for.
        let requestedLookName: String
        /// The room whose composition owns the session — not necessarily the
        /// room being applied to; ownership is per bridge.
        let owningRoomID: String
        /// The bridge that owns the session, retained at creation (packet 4):
        /// the direct-teardown path passes it to
        /// `stopCompositionMode(roomID:bridgeID:)`, whose exact-key teardown
        /// must not guess an identity after the fact.
        let owningBridgeID: String?
        let card: StudioCard
        let room: RoomDisplayItem
        let preferEntertainmentOverride: Bool?
    }

    /// A pending THIRD-PARTY takeover awaiting the user's answer (packet 7).
    ///
    /// Deliberately separate from `EntertainmentHandoffPrompt` above. That one
    /// is ChromaGlow handing a session between its own surfaces; this one is
    /// asking to replace another app entirely. Collapsing them into one flag
    /// would make "is this ours?" unanswerable at the point it matters most.
    ///
    /// Non-nil means: a start was requested, another controller owns the
    /// bridge, and NOTHING has been mutated.
    var foreignTakeoverRequest: ForeignTakeoverRequest? = nil

    /// Everything needed to replay the original request unchanged, plus the
    /// immutable identity of what was observed when the question was asked.
    struct ForeignTakeoverRequest: Identifiable {
        /// Unique per request, so a double-confirm cannot execute twice.
        let id = UUID()
        /// The frozen, validated way this room streams — bridge, room, target
        /// area, and the channel ids the render loop drives. Carrying the plan
        /// rather than just an id is what lets confirmation notice that the
        /// area was deleted or re-scoped while the prompt was open, instead of
        /// stopping someone else's show and then having nowhere to put ours.
        let plan: EntertainmentTakeoverPlan
        /// The session observed at prompt time. Never displayed.
        let foreignConfigID: String
        let card: StudioCard
        let room: RoomDisplayItem
        let preferEntertainmentOverride: Bool?

        var bridgeID: String { plan.bridgeID }
        var roomID: String { plan.roomID }
        var targetConfigID: String { plan.targetConfigID }
    }

    /// A pending STUDIO→COMPOSITION handoff awaiting the user's answer
    /// (packet 7 hardware follow-up).
    ///
    /// Non-nil means: a streaming composition was requested, one of our own
    /// app-driven looks (Strobe/Party/Thunderstorm) is streaming that bridge,
    /// and NOTHING has been torn down.
    var studioHandoffRequest: StudioHandoffRequest? = nil

    /// Deliberately a THIRD type, not a widened second one.
    ///
    /// `EntertainmentHandoffPrompt` carries neither a plan nor a token because
    /// it moves a session the other way — composition → Studio — where
    /// re-selecting the area is the Studio start's own job and there is nothing
    /// to freeze. This direction is the mirror image and needs both: the
    /// requested composition's area must be frozen before the prompt opens, and
    /// the answer must be spendable exactly once.
    ///
    /// It stays separate from `ForeignTakeoverRequest` for the reason that type
    /// already gives: "is this session ours?" must remain answerable at the
    /// point it matters. One slot for both would make a "Switch" and a "Take
    /// Over" indistinguishable to everything downstream.
    struct StudioHandoffRequest: Identifiable {
        /// Unique per request — and the seed of the confirmation token, so a
        /// double-confirm cannot execute twice.
        let id = UUID()
        /// The requested COMPOSITION's frozen plan, captured before the prompt
        /// opened. A bare configuration id would let the area be deleted or
        /// re-scoped under the prompt and still be replayed.
        let plan: EntertainmentTakeoverPlan
        /// The app-driven owner observed at prompt time. Compared by WHOLE
        /// VALUE at confirmation: a look that restarted elsewhere is a
        /// different look, and this consent did not name it.
        let owner: UnifiedOrchestrator.StudioEntertainmentOwner
        let runningLookName: String
        let requestedLookName: String
        let card: StudioCard
        let room: RoomDisplayItem
        let preferEntertainmentOverride: Bool?

        var bridgeID: String { plan.bridgeID }
    }

    /// A pending "which Entertainment Area did you mean?" awaiting the user
    /// (hardware convergence slice A).
    ///
    /// Non-nil means: a start was requested, several areas could serve the
    /// room, and NOTHING has been mutated — this is raised from the preflight,
    /// above every destructive step, exactly like the two consent prompts.
    var areaChoiceRequest: EntertainmentAreaChoiceRequest? = nil

    /// A FOURTH request type, and the one that is not a consent.
    ///
    /// Choosing a target is not agreeing to replace anybody. This carries no
    /// token, spends no ledger, and authorises no stop — picking "Bedroom TV"
    /// answers *where*, and the takeover prompt still has to ask *whether*, on
    /// its own terms. Folding this into `ForeignTakeoverRequest` would make one
    /// tap silently answer two very different questions.
    struct EntertainmentAreaChoiceRequest: Identifiable {
        let id = UUID()
        let choices: [UnifiedOrchestrator.EntertainmentAreaChoice]
        let card: StudioCard
        let room: RoomDisplayItem
        let preferEntertainmentOverride: Bool?

        /// Each choice carries the exact stream it promises, frozen when the
        /// sheet opened — `confirmAreaChoice` compares that whole value against
        /// a freshly resolved one before anything starts.
        var offeredConfigIDs: [String] { choices.map(\.configID) }
    }

    /// One sentence the user actually sees when we refused, or did something
    /// other than what was asked (packet 7 follow-up).
    ///
    /// `statusMessage` below is WRITE-ONLY — nothing renders it — so every
    /// refusal written there has been silent since it was added: the tap simply
    /// did nothing, with no way to tell a refusal from a bug. This is the one
    /// rendered channel for "we did not do that, and here is why".
    struct StudioNotice: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }

    var studioNotice: StudioNotice? = nil

    func clearStudioNotice() { studioNotice = nil }

    // ── Prompt slots: a question supersedes an explanation ────────────
    //
    // Studio stacks four alert modifiers on one view, and SwiftUI presents
    // exactly one of them. `.noStreamableArea` is the one notice writer that
    // does NOT return, so the same `apply` can go on to raise a takeover
    // prompt — and because the notice is deliberately retained until it is
    // read, the dropped one resurfaced later, attached to nothing the user
    // was doing. Every prompt therefore clears the notice as it is raised.
    private func present(_ prompt: EntertainmentHandoffPrompt) {
        studioNotice = nil
        entertainmentHandoffPrompt = prompt
    }

    private func present(_ request: StudioHandoffRequest) {
        studioNotice = nil
        studioHandoffRequest = request
    }

    private func present(_ request: ForeignTakeoverRequest) {
        studioNotice = nil
        foreignTakeoverRequest = request
    }

    private func present(_ request: EntertainmentAreaChoiceRequest) {
        studioNotice = nil
        areaChoiceRequest = request
    }

    // ── Area choice: target fidelity only, never consent ──────────────

    /// The user named the area. Revalidate that exact area, then replay the
    /// original request against it through the normal production path.
    ///
    /// The revalidation is the point. `exactTargetDecision` re-reads the bridge
    /// and the result is compared to the plan frozen when the sheet opened —
    /// whole value, so a re-scoped area, reordered channels, or moved lights
    /// all fail closed. Resolving by configuration id alone would accept an
    /// area that now drives a different set of lights under the same name.
    ///
    /// A stale choice starts NOTHING. Deliberately not "fall back to the other
    /// candidate": substituting an area the user did not pick is the defect
    /// this whole chooser exists to remove.
    func confirmAreaChoice(_ choice: UnifiedOrchestrator.EntertainmentAreaChoice) async {
        // Cleared before the first await, so a double-tap finds nil.
        guard let request = areaChoiceRequest else { return }
        areaChoiceRequest = nil
        guard let orchestrator else { return }

        guard case .plan(let fresh) = await orchestrator.exactTargetDecision(
                for: request.room, selectedConfigID: choice.configID),
              fresh == choice.plan else {
            studioNotice = StudioNotice(message: EntertainmentAreaChoiceCopy.staleSelection)
            statusMessage = "⚠ \(EntertainmentAreaChoiceCopy.staleSelection)"
            debugLog("[Handoff] '\(choice.areaName)' changed under the chooser — starting nothing")
            return
        }

        await apply(request.card,
                    roomOverride: request.room,
                    preferEntertainmentOverride: request.preferEntertainmentOverride,
                    selectedConfigID: choice.configID)
    }

    // ── Saving a look onto the bridge ─────────────────────────────

    /// Could the look currently being edited actually live on the bridge?
    ///
    /// A bridge chain is pre-rendered steps driven by a schedule; it has no
    /// microphone and no per-frame render loop. Reactive looks therefore
    /// cannot be stored, and saying so up front beats uploading something that
    /// would play back as a still image.
    var canSaveActiveLookToBridge: Bool {
        guard let box = activeCompositionBox else { return false }
        return !box.reaction.requiresMic
    }

    /// Save the running look onto the bridge, on the MANIFEST-BACKED path.
    ///
    /// Deliberately not the "Save as Hue dynamic scene" action buried under
    /// Palette → +N more. That one creates a native Hue scene: genuinely
    /// bridge-run, but with no ownership manifest, so ChromaGlow can never
    /// show it or stop it afterwards. This one goes through
    /// `startCompositionMode(tier: .bridgeOptimized)`, which creates the
    /// resources, persists the manifest BEFORE anything starts, and leaves a
    /// row with an exact Stop that survives a relaunch.
    ///
    /// Every outcome is reported honestly, including the two that are neither
    /// success nor plain failure: saved-but-not-confirmed-running, and
    /// partially-created-and-not-fully-cleaned.
    func saveActiveLookToBridge(_ card: StudioCard) async {
        // One save at a time from this surface. The tray button used to be
        // fire-and-forget and stayed tappable for the whole save — which is
        // exactly how two overlapping saves reached the same room. The
        // orchestrator's per-bridge+room gate is the guarantee; this flag is
        // the honest UI for it.
        guard !isSavingLookToBridge else { return }
        isSavingLookToBridge = true
        defer { isSavingLookToBridge = false }

        guard let room = selectedRoom else {
            studioNotice = StudioNotice(message: "Select a room first.")
            return
        }
        guard let box = activeCompositionBox else { return }
        guard canSaveActiveLookToBridge else {
            studioNotice = StudioNotice(message:
                "Looks that react to sound can't be stored on the bridge — the bridge has no microphone. This one keeps running from ChromaGlow instead.")
            return
        }
        guard let orchestrator else { return }

        // A local preset is what gives the bridge copy a name and a room to be
        // recovered under, so it is created first and reported separately: the
        // user is told whether a copy landed in My Creations or not.
        let preset = compositionStore.presets.first { $0.id == runningPresetID(for: card) }
            ?? saveActiveComposition(name: card.name, icon: card.icon,
                                     preferredTransport: nil)
        guard let preset else {
            studioNotice = StudioNotice(message: BridgeSaveCopy.saveFailedNothingRecorded)
            return
        }

        // The STRICT path: no app-driven fallback, so nothing here can report a
        // save that did not happen.
        let outcome = await orchestrator.saveLookToBridge(
            room: room, paramBox: box,
            gamutOverride: activeCompositionGamut, preset: preset)

        applyBridgeSaveOutcome(
            outcome, room: room, presetName: preset.name,
            bridgeLabel: orchestrator.bridgeLabel(for: room.bridgeID ?? ""))
    }

    /// Apply a strict-save outcome to this VM's state — synchronously, in the
    /// main-actor turn that calls it.
    ///
    /// Factored out of `saveActiveLookToBridge` (round 4f) because the await
    /// above it opens a continuation gap: between the orchestrator's return
    /// and this application, another task can start a new playback on the
    /// same exact bridge+room. Every destructive step here therefore
    /// revalidates the outcome's presentation fence against the orchestrator
    /// immediately before mutating — and the user-facing wording follows the
    /// SAME revalidated truth, because "nothing is playing in the room now"
    /// is only as current as the fence that proves it. A nil or stale fence
    /// proves only that playback CHANGED (the newer look may itself have
    /// stopped by now), so that branch claims neither emptiness nor active
    /// playback.
    func applyBridgeSaveOutcome(
        _ outcome: UnifiedOrchestrator.BridgeSaveOutcome,
        room: RoomDisplayItem, presetName: String, bridgeLabel: String
    ) {
        switch outcome {
        case .savedAndRunning(let manifestID, _):
            bridgeSaveResult = BridgeSaveResult(
                lookName: presetName, roomName: room.name, bridgeLabel: bridgeLabel,
                isRunningOnBridge: true, createdLocalPreset: true,
                stopSurvivesRelaunch: true,
                headline: BridgeSaveCopy.savedAndRunning,
                stoppableManifestID: manifestID)

        case .savedNotConfirmedRunning(
            let manifestID, let savedBridgeID, let previousLookRemoved,
            let presentationFence):
            // Saved, tracked, NOT running. The manifest is retained because it
            // is the only thing that can remove these resources — and the
            // result carries it, so Stop is available right now rather than
            // only after a relaunch surfaces a row. When the required
            // replacement cleanup destroyed a PROVEN bridge-stored predecessor
            // (round 4c), exactly that bridge's row AND its editor box fall
            // with it — they mirrored a look that no longer exists — and the
            // headline says both halves. Another bridge's same-room-id row is
            // a different key and stays untouched. Round 4f: the removal and
            // the "nothing is playing there now" headline both require the
            // fence to hold RIGHT NOW — a newer look that took the key keeps
            // its row, its box, and an honest sentence.
            let fenceValid = previousLookRemoved
                && presentationFence.map { orchestrator?.presentationFenceHolds($0) ?? false } ?? false
            if fenceValid {
                // The outcome names the bridge; the room record supplies the
                // kind, so the removal stays exact under the kind-aware key.
                let key = StudioSelectionKey(bridgeID: savedBridgeID, groupID: room.id, kind: room.kind)
                stopRunningScopes(forRowAt: key)
                runningEffects.removeValue(forKey: key)
                activeCompositionBoxes.removeValue(forKey: key)
            }
            let headline: String
            if !previousLookRemoved {
                headline = BridgeSaveCopy.savedNotConfirmedRunning
            } else if fenceValid {
                headline = BridgeSaveCopy.savedNotConfirmedPreviousLookRemoved
            } else {
                headline = BridgeSaveCopy.savedNotConfirmedPreviousLookRemovedPlaybackChanged
            }
            bridgeSaveResult = BridgeSaveResult(
                lookName: presetName, roomName: room.name, bridgeLabel: bridgeLabel,
                isRunningOnBridge: false, createdLocalPreset: true,
                stopSurvivesRelaunch: true,
                headline: headline,
                stoppableManifestID: manifestID)

        case .partialCleanupFailure(let manifestID, _, let recoverable, let reason):
            // The failure with something left behind gets the RESULT SHEET,
            // not a passing notice: the manifest id it carries is the user's
            // only exact handle on those resources, and the sheet's Remove
            // button is the immediate exact retry. A notice would dismiss
            // itself and take the handle with it.
            bridgeSaveResult = BridgeSaveResult(
                lookName: presetName, roomName: room.name, bridgeLabel: bridgeLabel,
                isRunningOnBridge: false, createdLocalPreset: true,
                stopSurvivesRelaunch: recoverable,
                headline: reason,
                stoppableManifestID: manifestID,
                succeeded: false)

        case .previousLookRemovedSaveFailed(let failedBridgeID, let presentationFence):
            // The room's previous bridge look is provably gone (replacement
            // cleanup removed it) and nothing of ours replaced it. This VM's
            // own running row and editor box were mirroring the destroyed
            // look — they fall too, or the UI keeps asserting a look that no
            // longer exists. The outcome names the destroyed chain's own
            // bridge (round 4c), so exactly that key is removed; another
            // bridge's same-room-id row is a different key and survives.
            // Round 4f: removal and wording both require the fence to hold
            // RIGHT NOW. The outcome deliberately carries no reason string —
            // whether the room is empty is decided here, not before the
            // continuation gap.
            let fenceValid = presentationFence
                .map { orchestrator?.presentationFenceHolds($0) ?? false } ?? false
            if fenceValid {
                let key = StudioSelectionKey(bridgeID: failedBridgeID, groupID: room.id, kind: room.kind)
                stopRunningScopes(forRowAt: key)
                runningEffects.removeValue(forKey: key)
                activeCompositionBoxes.removeValue(forKey: key)
            }
            studioNotice = StudioNotice(message: fenceValid
                ? BridgeSaveCopy.previousLookRemovedSaveFailed
                : BridgeSaveCopy.previousLookRemovedSaveFailedPlaybackChanged)

        case .nothingRecorded(let reason), .saveAlreadyInProgress(let reason):
            // No sheet titled "Saved" for something that was not saved.
            studioNotice = StudioNotice(message: reason)
        }
    }

    /// Remove a saved look from the bridge, by exact manifest identity.
    ///
    /// Offered directly from the save result so a look that was saved but never
    /// confirmed running can be cleaned up immediately — waiting for a relaunch
    /// to surface a Stop is exactly the gap that leaves a user with resources
    /// they cannot find.
    func stopSavedBridgeLook(_ result: BridgeSaveResult) async {
        guard let manifestID = result.stoppableManifestID, let orchestrator else { return }
        guard !isStoppingSavedLook else { return }
        isStoppingSavedLook = true
        defer { isStoppingSavedLook = false }

        let outcome = await orchestrator.stopSavedBridgeLook(manifestID: manifestID)
        applySavedLookStopOutcome(outcome, for: result)
    }

    /// Apply an exact saved-look Stop outcome to this VM's state —
    /// synchronously, in the main-actor turn that calls it.
    ///
    /// Factored out of `stopSavedBridgeLook(_:)` (round 4f) for the same
    /// reason as `applyBridgeSaveOutcome`: the await opens a continuation
    /// gap, so the outcome's presentation fence is revalidated against the
    /// orchestrator immediately before the row and box are removed. The
    /// sheet is dismissed only on SUCCESS — it used to be cleared before the
    /// attempt, so a failed stop dismissed the one control that carried the
    /// exact manifest id, leaving the user a sentence and no way to retry
    /// until a relaunch surfaced a row.
    func applySavedLookStopOutcome(
        _ outcome: UnifiedOrchestrator.SavedLookStopOutcome,
        for result: BridgeSaveResult
    ) {
        switch outcome {
        case .removed(_, let bridgeID, let roomID, _, _, let presentationFence):
            // The fence is the ONLY authorization to touch presentation
            // mirrors, and it must hold RIGHT NOW: nil means the stopped
            // manifest was inert, another owner survives, or a newer
            // playback took the key inside the orchestrator; a token that
            // no longer holds means one took it between the orchestrator's
            // return and this continuation. In every one of those cases the
            // standing row and box belong to a look this stop did not stop
            // — the saved resources are gone either way, so the sheet still
            // dismisses.
            if let fence = presentationFence, let orchestrator,
               orchestrator.presentationFenceHolds(fence) {
                // The outcome carries bridge + room id but no kind — resolve
                // the unique row and fail closed on a room/zone collision.
                if let key = runningKey(bridgeID: bridgeID, groupID: roomID) {
                    stopRunningScopes(forRowAt: key)
                    runningEffects.removeValue(forKey: key)
                    activeCompositionBoxes.removeValue(forKey: key)
                } else if let boxKey = activeCompositionBoxKey(bridgeID: bridgeID, groupID: roomID) {
                    activeCompositionBoxes.removeValue(forKey: boxKey)
                }
            }
            bridgeSaveResult = nil
            studioNotice = StudioNotice(message: "\(result.lookName) was removed from \(result.bridgeLabel).")

        case .alreadyAbsent:
            // Nothing to remove is a success: the resources this sheet
            // offered to remove are not on the bridge.
            bridgeSaveResult = nil
            studioNotice = StudioNotice(message: "\(result.lookName) was removed from \(result.bridgeLabel).")

        case .failed:
            studioNotice = StudioNotice(message: BridgeSaveCopy.saveFailedResourcesRemain)
        }
    }

    /// True while the result sheet's exact Stop is running — the button
    /// disables on it, so a failed stop is a visible retry, not a re-tap race.
    var isStoppingSavedLook = false

    private func runningPresetID(for card: StudioCard) -> UUID? {
        if case .composition(let presetID) = card.strategy { return presetID }
        return nil
    }

    /// What a completed bridge save actually produced, in the user's terms.
    ///
    /// Every field answers a question the device pass proved the user could not
    /// otherwise answer: which bridge, which room, is it running there, is
    /// there a local copy, and will Stop still be there after a relaunch.
    struct BridgeSaveResult: Identifiable, Equatable {
        let id = UUID()
        let lookName: String
        let roomName: String
        let bridgeLabel: String
        let isRunningOnBridge: Bool
        let createdLocalPreset: Bool
        let stopSurvivesRelaunch: Bool
        let headline: String
        /// Present whenever resources exist on the bridge that this result can
        /// remove RIGHT NOW. Non-nil is what makes "saved but not confirmed
        /// running" an actionable state rather than an announcement.
        let stoppableManifestID: UUID?
        /// False for the partial-cleanup failure (round 3): the sheet then
        /// titles itself as the failure it is, and the relaunch row talks
        /// about recovery rather than about a stop.
        var succeeded: Bool = true
    }

    var bridgeSaveResult: BridgeSaveResult? = nil

    /// True while a Save to Bridge is in flight — the tray button disables
    /// and shows progress on it, so the save's serialization is visible
    /// rather than a silently swallowed second tap.
    var isSavingLookToBridge = false

    /// Dismissed without choosing. Nothing was mutated to raise this prompt and
    /// nothing is mutated to drop it.
    func cancelAreaChoice() {
        guard areaChoiceRequest != nil else { return }
        debugLog("[Handoff] Area chooser dismissed without a choice — nothing started")
        areaChoiceRequest = nil
    }

    /// The running effect on the CURRENTLY SELECTED room.
    /// Drives card grid running indicators and mixer tray content.
    var currentRoomEffect: RunningEffect? {
        guard let room = selectedRoom else { return nil }
        return runningEffect(for: room)
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

    // ── Param values — three separated scopes (Slice 2 production wiring) ──
    //
    // The old card-global `paramValues`/`paramColors` dictionaries served
    // persisted defaults, live running-instance values, and mid-drag drafts at
    // once — the exact-state defect audit §2A documents. They are gone. The
    // scopes engine keys live values by exact running target (bridge + group +
    // kind + card + execution) and fences every commit on the full identity.
    @ObservationIgnored let valueScopes = CustomizationValueScopes<Color>()

    /// The app's ONLY generation counter. Bumped for every event that makes
    /// in-flight writes untrustworthy; the fence compares against it.
    @ObservationIgnored let generationCounter = CustomizationGenerationCounter()

    /// Observation bridge: `valueScopes` is a plain class the Observation
    /// runtime cannot see into, so every committed mutation/reset/stop bumps
    /// this. Accessors read it, which is what re-renders the rows.
    private(set) var liveValuesTick: UInt64 = 0
    func bumpLiveValuesTick() { liveValuesTick &+= 1 }

    /// Debounced bridge sends, one slot per exact running target — latest
    /// wins PER TARGET, so two rooms' edits never cancel each other (the old
    /// single global `paramTask` did exactly that, and re-read `selectedRoom`
    /// after its sleep).
    @ObservationIgnored var paramSendTasks: [RunningLookTargetKey: Task<Void, Never>] = [:]

    /// Per-target session working memory (spec §14.4): expansions and board
    /// position per ACTIVE target, cleared on that target's stop and wholly
    /// cleared when the session ends. Never persisted.
    let sessionMemory = StudioSessionWorkingMemory()

    // ── Engine reference (set in configure()) ─────────────────
    // Getter internal so the customization-wiring extension (separate file)
    // can route sends; the setter stays private to `configure`.
    private(set) weak var orchestrator: UnifiedOrchestrator?

    // ── Safety: Strobe compliance ─────────────────────────────
    /// Whether the user has acknowledged the strobe warning (persisted).
    var strobeWarningAcknowledged: Bool {
        get { UserDefaults.standard.bool(forKey: "strobeWarningAcknowledged") }
        set { UserDefaults.standard.set(newValue, forKey: "strobeWarningAcknowledged") }
    }

    /// True if iOS "Reduce Motion" is enabled — strobe should be blocked.
    var isReduceMotionEnabled: Bool {
        #if DEBUG
        if let forced = forcedReduceMotionForTesting { return forced }
        #endif
        return UIAccessibility.isReduceMotionEnabled
    }

    #if DEBUG
    /// TEST SEAM: the system setting cannot be toggled from a unit test, and
    /// the refusal it drives is exactly what must happen before anything is
    /// prepared or torn down.
    var forcedReduceMotionForTesting: Bool?
    #endif

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
    private(set) var compositionStore = CompositionStore(loadsSynchronously: false)

    #if DEBUG
    /// Swap in a store backed by an isolated file, so a test can assert what
    /// Studio displays for a renamed or deleted preset without loading — or
    /// writing — the developer's real `compositions.json`.
    func injectForTesting(compositionStore store: CompositionStore) {
        compositionStore = store
    }

    /// Read-only exact box lookup (round 4e): the live editor box for one
    /// bridge+room, so a collision test can prove two same-room-id rows do
    /// NOT alias one `CompositionParamBox` instance (`===`/`!==`).
    func testActiveCompositionBox(bridgeID: String?, roomID: String) -> CompositionParamBox? {
        guard let key = activeCompositionBoxKey(bridgeID: bridgeID, groupID: roomID) else { return nil }
        return activeCompositionBoxes[key]
    }
    #endif
    private let aiGenerator = AICompositionGenerator()
    var isGeneratingAIComposition = false
    var aiGenerationErrorMessage: String?
    var activeCompositionGamut: HueColorUtils.Gamut = .c
    var roomHasColorLights: Bool = true
    var restoredHarmonyRule: HarmonyRule? = nil
    /// One-shot guard for programmatic harmony-chip clears (album colors,
    /// a rule-less preset restore): StudioView's activeHarmonyRule onChange
    /// has a DESTRUCTIVE `.none` branch (nils color3, resets color2) meant
    /// for the user turning harmony off — a programmatic clear must reset
    /// the chip without that echo. Armed by the restoredHarmonyRule
    /// onChange, consumed by the activeHarmonyRule one. (Audit R9, F6.)
    @ObservationIgnored var harmonyEchoSuppressed = false
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

    /// Live composition param boxes, keyed by EXACT bridge + group + kind
    /// identity (round 4e re-keyed by bridge+room; Slice 2 adds the room-vs-
    /// zone axis) — the render loops read these each frame. UI writes on
    /// slider drag for instant response. A bare room-id key made two
    /// same-room-id composition rows share one editable box: the second apply
    /// overwrote the first bridge's live editor state, and either stop evicted
    /// the other's box while its render loop still read it.
    private var activeCompositionBoxes: [StudioSelectionKey: CompositionParamBox] = [:]

    /// Fail-closed box resolution for callers carrying bridge + group id but
    /// no kind — same rule as `runningKey(bridgeID:groupID:)`.
    private func activeCompositionBoxKey(bridgeID: String?, groupID: String) -> StudioSelectionKey? {
        let keys = activeCompositionBoxes.keys.filter {
            $0.bridgeID == bridgeID && $0.groupID == groupID
        }
        guard keys.count == 1 else { return nil }
        return keys.first
    }

    /// The editable box for the CURRENTLY SELECTED room. A single slot here
    /// meant the tray edited whatever room applied LAST, not the room on
    /// screen, whenever two rooms ran compositions at once. Get-only is
    /// enough: every editor binding mutates fields through the class
    /// reference; the two ownership writes go straight to the dict.
    var activeCompositionBox: CompositionParamBox? {
        guard let room = selectedRoom else { return nil }
        return activeCompositionBoxes[StudioSelectionKey(room: room)]
    }

    // ── Status ────────────────────────────────────────────────
    var statusMessage: String = ""

    func configure(orchestrator: UnifiedOrchestrator) {
        self.orchestrator = orchestrator
        orchestrator.studioStopHandler = { [weak self] target in
            await self?.stopFromNowPlaying(target)
        }
        // Packet 8: this pair is the two-way ordering mechanism for recovered
        // bridge-stored animations. The handler covers configure-BEFORE-load
        // (reconciliation calls it when it publishes); the inline hydrate below
        // covers load-BEFORE-configure (reconciliation already published, and
        // this view model was not alive to hear it). Both paths converge on the
        // same generation-guarded function, so the order the user visits
        // screens in cannot change what they see.
        orchestrator.studioRecoveredHydrationHandler = { [weak self] in
            self?.hydrateRecoveredBridgeStored()
        }
        if selectedRoom == nil, let first = orchestrator.allRooms.first {
            selectedRoom = first
        }
        restoreLastUsedParams()
        hydrateRecoveredBridgeStored()
    }

    /// Which reconcile generation this view model has already mirrored.
    /// `StudioView.onAppear` re-runs `configure` on every appearance, so this
    /// is what makes re-entering the tab free.
    @ObservationIgnored private var hydratedRecoveredGeneration: Int = -1

    /// Mirror the orchestrator's reconciled registry into `runningEffects`.
    ///
    /// Presentation only. This never decides whether a manifest is live — the
    /// orchestrator owns bridge verification, and a second opinion here is how
    /// a phantom row appears.
    func hydrateRecoveredBridgeStored() {
        guard let orchestrator else { return }
        guard orchestrator.bridgeAnimationReconcileGeneration != hydratedRecoveredGeneration else { return }
        hydratedRecoveredGeneration = orchestrator.bridgeAnimationReconcileGeneration

        let live = orchestrator.recoveredBridgeAnimations

        // A room id claimed by more than one bridge is mirrored into Studio
        // for NEITHER — unchanged display policy (round 4c re-keyed the rows
        // exactly, but Studio's rolodex still presents one card per room id,
        // and letting dictionary order pick which bridge's animation that
        // card controls would mean selecting bridge A and pressing Stop could
        // tear down bridge B's).
        //
        // Nothing is lost by that. The orchestrator's registry is exact-keyed,
        // so both animations keep their own Dashboard Now-Playing row and each
        // stays independently stoppable by its exact manifest.
        var recoveredCountByRoomID: [String: Int] = [:]
        for animation in live.values where animation.room != nil {
            recoveredCountByRoomID[animation.manifest.roomID, default: 0] += 1
        }

        // Drop mirrors whose animation is gone, and any whose room id has since
        // become ambiguous — a second bridge appearing must retract the first
        // one's row rather than leave a now-unsafe owner in place.
        for (rowKey, effect) in runningEffects {
            guard let key = effect.recovered else { continue }
            if live[key] == nil || recoveredCountByRoomID[rowKey.groupID, default: 0] > 1 {
                runningEffects.removeValue(forKey: rowKey)
            }
        }

        for (key, animation) in live {
            // No room ⇒ no RunningEffect and no room guessing. The orchestrator
            // still publishes a Now-Playing row carrying the stored room name
            // and a working exact-manifest Stop.
            guard let room = animation.room else { continue }
            guard recoveredCountByRoomID[room.id] == 1 else { continue }
            // Never overwrite a live effect the user started, and never rebuild
            // a mirror that already matches.
            if let existing = runningEffect(for: room), existing.recovered != key { continue }

            // Resolve the display name BEFORE building the card. The
            // orchestrator holds no CompositionStore, so it publishes the
            // manifest's persisted name; Studio has the live preset and is what
            // makes a rename show through. Building the card first and
            // refreshing afterwards left Studio showing the stale name until
            // some later pass, because the refresh deliberately does not bump
            // the hydration generation.
            let currentPresetName = compositionStore.presets
                .first { $0.id == animation.manifest.presetID }?.name
            // A DELETED preset simply keeps the persisted name, and the row
            // stays stoppable either way because Stop routes on the manifest.
            let displayName = currentPresetName ?? animation.displayName

            // Identity minted for fencing uniformity; NOT registered with the
            // value scopes — a recovered mirror has no live box and no editable
            // controls, so there is nothing for a commit to land on.
            let recoveredCardID = Self.recoveredCardID(manifestID: key.manifestID)
            runningEffects[StudioSelectionKey(room: room)] = RunningEffect(
                cardID: recoveredCardID,
                card: recoveredCard(for: animation, displayName: displayName),
                room: room,
                lightIDs: [],
                isEntertainment: false,
                requestedTransport: nil,
                transportFallback: false,
                identity: RunningLookIdentity(
                    bridgeID: room.bridgeID, groupID: room.id, kind: room.kind,
                    cardID: recoveredCardID,
                    execution: .composition(presetID: animation.manifest.presetID),
                    generation: generationCounter.bump(.cardReplaced)),
                recovered: key)
            // NO publishNowPlaying: the orchestrator is the sole publisher of
            // recovered rows. Two publishers is exactly how duplicates appear.
            // NO activeCompositionBoxes entry, no mic demand, no engine task.

            // Mirror the same name onto the Dashboard row. This replaces the
            // row in place and is NOT an ownership change, so it cannot move
            // the generation a parked stop is comparing against.
            if displayName != animation.displayName {
                orchestrator.refreshRecoveredDisplayName(key: key, name: displayName)
            }
        }
    }

    static func recoveredCardID(manifestID: UUID) -> String {
        "recovered_\(manifestID.uuidString)"
    }

    /// A card that describes a bridge-stored animation honestly.
    ///
    /// Deliberately NOT the preset's own card id: the app does not hold this
    /// animation's editable runtime state, so sliders and layer chips would
    /// imply control that no longer exists, and highlighting the original
    /// preset card would suggest the running animation is still linked to that
    /// preset instance. Tapping the real preset stays a deliberate fresh start
    /// with the normal replacement cleanup. A distinct id also keeps two
    /// bridges running the same preset from colliding on one card.
    private func recoveredCard(
        for animation: UnifiedOrchestrator.RecoveredBridgeAnimation,
        displayName: String
    ) -> StudioCard {
        StudioCard(
            id: Self.recoveredCardID(manifestID: animation.manifest.id),
            name: displayName,
            tagline: "Running on the bridge — recovered at launch",
            icon: "externaldrive.connected.to.line.below",
            accentColor: .cyan,
            requiresForeground: false,      // no app task ⇒ no "keep app open"
            params: [],                     // no sliders: nothing to drive
            strategy: .composition(presetID: animation.manifest.presetID),
            compositionLayerActivity: nil,  // no layer chips
            compositionTier: .bridgeOptimized)
    }

    /// Mirror a running effect into the orchestrator's shared now-playing
    /// registry (Dashboard bar, Tap-Dial punch target).
    private func publishNowPlaying(room: RoomDisplayItem, card: StudioCard) {
        // Bridge-attributed (round 4c): the row's presentation key is
        // bridge-qualified, so two bridges' looks in one room id are two rows
        // and each is exactly withdrawable.
        orchestrator?.addActiveEffect(ActiveEffectEntry(
            liveBridgeID: room.bridgeID,
            roomID: room.id,
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
        await stopFromNowPlaying(UnifiedOrchestrator.LiveEffectStopTarget(
            bridgeID: nil, roomID: roomID, turnOffLights: turnOffLights))
    }

    /// The exact live-stop entry point (round 4d). A bridge-attributed
    /// target resolves its exact row directly — two bridges sharing one room
    /// id are two rows, and each Dashboard entry stops precisely its own. A
    /// room-only target (bridgeID nil) resolves only when exactly one bridge
    /// holds the room id and fails closed on a collision — that caller
    /// cannot say WHICH bridge's look it means.
    func stopFromNowPlaying(_ target: UnifiedOrchestrator.LiveEffectStopTarget) async {
        let context = UnifiedOrchestrator.StopAuditContext(route: .nowPlaying)
        orchestrator?.recordStopAudit(context, operation: .stopRequested,
                                      bridgeID: target.bridgeID, roomID: target.roomID,
                                      outcomeReason: "nowPlayingEntry turnOffLights=\(target.turnOffLights)")
        isExplicitStop = target.turnOffLights
        let resolvedKey: StudioSelectionKey?
        if let bridgeID = target.bridgeID {
            // Bridge-attributed target without a kind: resolve the unique row
            // and fail closed when a room and a zone share the id there.
            resolvedKey = runningKey(bridgeID: bridgeID, groupID: target.roomID)
        } else {
            resolvedKey = runningEffectKey(forRoomID: target.roomID)
        }
        guard let key = resolvedKey else {
            // No resolvable row: clear a stale bar entry — exactly when the
            // target names its bridge, through the fail-closed room-scoped
            // removal otherwise.
            if let bridgeID = target.bridgeID {
                orchestrator?.removeActiveEffect(bridgeID: bridgeID, roomID: target.roomID,
                                                context: context)
            } else {
                orchestrator?.removeActiveEffect(roomID: target.roomID, context: context)
            }
            statusMessage = ""
            return
        }
        let stopping = runningEffects[key]
        await stopEffect(on: key, context: context)
        // stopEffect's guard can still bail (stale entry with nothing running),
        // and the bar entry must clear in that case or Stop appears to do
        // nothing. But this stop suspends, so a REPLACEMENT may have taken the
        // room meanwhile — clearing unconditionally would erase the newcomer's
        // Now-Playing row. Clear only when nothing newer holds the room.
        let survivor = runningEffects[key]
        let replacedByNewer = survivor != nil
            && (survivor?.cardID != stopping?.cardID
                || survivor?.bridgeNativeOwnership != stopping?.bridgeNativeOwnership
                || survivor?.recovered != stopping?.recovered)
        if !replacedByNewer {
            if let bridgeID = key.bridgeID {
                orchestrator?.removeActiveEffect(bridgeID: bridgeID, roomID: target.roomID,
                                                context: context)
            } else {
                orchestrator?.removeActiveEffect(roomID: target.roomID, context: context)
            }
        }
        statusMessage = ""
    }

    /// Restore per-card last-used params into SCOPE 1 (persisted defaults),
    /// clamped by the store. Defaults set earlier this session win over the
    /// persisted snapshot.
    private var didRestoreParams = false
    private func restoreLastUsedParams() {
        guard !didRestoreParams else { return }
        didRestoreParams = true
        let restored = StudioParamStore.shared.load(cards: effectCards + liveModeCards)
        for cardID in Set(restored.values.keys).union(restored.colors.keys) {
            var set = CustomizationValueSet<Color>(
                numbers: restored.values[cardID] ?? [:],
                colors: restored.colors[cardID] ?? [:])
            let session = valueScopes.defaults(forCard: cardID)
            // Session-set defaults win over the persisted snapshot.
            set = session.layered(over: set)
            valueScopes.setDefaults(set, forCard: cardID)
        }
        bumpLiveValuesTick()
    }

    /// Reset ONE exact running instance to factory defaults (Slice 2
    /// production wiring). Only the SELECTED target's instance is touched:
    /// the same card running on another room or bridge keeps its values —
    /// the old card-global nil-out reset every bridge at once.
    ///
    /// Persistent policy (spec §22): factory defaults become the card's
    /// next-start state, so the persisted custom defaults are cleared too.
    func resetParams(for card: StudioCard) async {
        valueScopes.clearDefaults(forCard: card.id)
        persistDefaults()
        defer { bumpLiveValuesTick() }
        guard let effect = currentRoomEffect, effect.cardID == card.id else { return }

        // Older in-flight writes for THIS instance lose the fence; the new
        // identity is written back so subsequent gestures capture it.
        paramSendTasks[effect.identity.targetKey]?.cancel()
        paramSendTasks[effect.identity.targetKey] = nil
        let newIdentity = valueScopes.reset(
            effect.identity, newGeneration: generationCounter.bump(.reset))
        runningEffects[StudioSelectionKey(room: effect.room)]?.identity = newIdentity

        switch card.strategy {
        case .appDriven:
            // Empty box = the engine loop falls back to catalog defaults.
            orchestrator?.updateStudioParams(
                values: [:], colors: [:],
                bridgeID: effect.room.bridgeID, roomID: effect.room.id)
        case .bridgeNative:
            await apply(card)   // restart re-applies v1+v2 defaults and re-mints identity
        case .composition:
            break   // compositions revert via revertActiveComposition()
        }
    }

    /// Serialize SCOPE 1 through the existing store (same UserDefaults key,
    /// same shape — no migration).
    func persistDefaults(immediately: Bool = true) {
        var values: [String: [String: Double]] = [:]
        var colors: [String: [String: Color]] = [:]
        for card in effectCards + liveModeCards {
            let set = valueScopes.defaults(forCard: card.id)
            if !set.numbers.isEmpty { values[card.id] = set.numbers }
            if !set.colors.isEmpty { colors[card.id] = set.colors }
        }
        if immediately {
            StudioParamStore.shared.saveNow(values: values, colors: colors)
        } else {
            StudioParamStore.shared.scheduleSave(values: values, colors: colors)
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
        // Packet 4: bridge + room, or nothing. The old roomID-only lookup with
        // a global fallback could show another room's — or another bridge's —
        // number under this room's card. No ledger keys or scopes are built
        // here; the orchestrator owns that vocabulary.
        guard let orchestrator, let selectedRoom else { return nil }
        return orchestrator.activeRESTCadence(
            roomID: selectedRoom.id, bridgeID: selectedRoom.bridgeID)
    }

    // ──────────────────────────────────────────────
    // MARK: - Param Access (composition-ready)
    // ──────────────────────────────────────────────

    /// Read a param value for a specific card, falling back to the param's default.
    ///
    /// Selection-aware (Slice 2 production wiring): when the SELECTED room is
    /// running this card, this returns that exact instance's live value —
    /// switching between two rooms running the same card shows each room's own
    /// numbers. Otherwise it returns the card's persisted default.
    func paramValue(for cardID: String, paramID: String, default defaultVal: Double) -> Double {
        _ = liveValuesTick   // observation dependency on scope mutations
        if let effect = currentRoomEffect, effect.cardID == cardID, effect.recovered == nil {
            return valueScopes.live(for: effect.identity).numbers[paramID] ?? defaultVal
        }
        return valueScopes.defaults(forCard: cardID).numbers[paramID] ?? defaultVal
    }

    /// Read a param color for a specific card — same selection-aware rule as
    /// `paramValue(for:paramID:default:)`.
    func paramColor(for cardID: String, paramID: String) -> Color? {
        _ = liveValuesTick
        if let effect = currentRoomEffect, effect.cardID == cardID, effect.recovered == nil {
            return valueScopes.live(for: effect.identity).colors[paramID]
        }
        return valueScopes.defaults(forCard: cardID).colors[paramID]
    }

    // The old `setParamValue` / `setParamColor` / `sendParam` /
    // `sendColorParam` quartet is GONE. Writes go through the exact-identity
    // session API in `StudioViewModel+CustomizationWiring.swift`
    // (`beginParamEdit` / `updateParamEdit` / `endParamEdit`, and the one-shot
    // `commitParam` / `commitColorParam`). Those capture the running identity
    // when the gesture starts and fence every commit and every debounced
    // bridge send on it — a drag that outlives the selection can no longer
    // land on the newly selected room.

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

        // Zones reference lights directly — no API call needed. When the
        // caller already holds the live lights, prune ghost refs from
        // deleted bulbs while keeping ref order (L-29 parity with
        // CompositionLightResolver; no extra fetch is ever added here).
        let hasDirectLightRefs = refs.contains { $0.rtype == "light" }
        if hasDirectLightRefs {
            var ids = refs.filter { $0.rtype == "light" }.map { $0.rid }
            if let cachedLights {
                let live = Set(cachedLights.map(\.id))
                ids = ids.filter { live.contains($0) }
            }
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
        // set it (a stored default exists), so untouched cards keep the
        // firmware's default look.
        var mirek: Int? = nil
        if card.params.contains(where: { $0.id == "warmth" }),
           let raw = valueScopes.defaults(forCard: card.id).numbers["warmth"] {
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
    /// Selection the current `effectCoverage` was computed for.
    ///
    /// Exact (bridge + group + kind), not a bare room id: two bridges can share
    /// a Hue room id, and comparing bare ids left the PREVIOUS bridge's badges
    /// on screen labelled as this bridge's room.
    @ObservationIgnored private var coverageSelection: StudioSelectionKey?

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
        // Selection switch: the visible badges are still the PREVIOUS
        // selection's coverage until this finishes — clear rather than
        // mislabel. Exact-keyed, so switching between two bridges' rooms that
        // share a Hue id clears too.
        let selection = StudioSelectionKey(room: room)
        if coverageSelection != selection {
            effectCoverage = [:]
            coverageSelection = selection
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

    /// Would this card ask for Entertainment? One rule, asked in two places —
    /// the takeover preflight above the mutations, and the composition branch
    /// that actually starts. Two copies could disagree, and the disagreement
    /// would show up as either a missing prompt or a pointless one.
    func requestsEntertainment(_ card: StudioCard,
                               preferEntertainmentOverride: Bool?) -> Bool {
        switch card.strategy {
        case .appDriven(let engineKey):
            // Only the streaming engines open a session; the rest never can.
            return UnifiedOrchestrator.studioEngineStreams(engineKey)

        case .composition(let presetID):
            guard let preset = compositionStore.presets.first(where: { $0.id == presetID }) else {
                return false
            }
            // A bridgeOptimized preset is a single one-shot PUT — it never
            // streams, so another app's session cannot conflict with it.
            let tier = preset.capabilityTier
            guard tier != .bridgeOptimized else { return false }
            let presetPreferEntertainment: Bool?
            switch preset.preferredTransport {
            case .roomOnly:          presetPreferEntertainment = false
            case .entertainmentArea: presetPreferEntertainment = true
            case nil:                presetPreferEntertainment = nil
            }
            return preferEntertainmentOverride
                ?? presetPreferEntertainment
                ?? preferredEntertainmentForCompositionTier(tier)

        default:
            return false
        }
    }

    /// Apply using a captured room snapshot to avoid room-selection races
    /// when taps and room-swipes happen close together.
    func apply(_ card: StudioCard, roomOverride: RoomDisplayItem?,
               preferEntertainmentOverride: Bool?,
               skipHandoffConfirmation: Bool = false,
               foreignConsent: EntertainmentConsent? = nil,
               consentedPlan: EntertainmentTakeoverPlan? = nil,
               selectedConfigID: String? = nil) async {
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

        // ── Refusals FIRST ───────────────────────────────────────────
        //
        // A card that cannot run must say so before anything is prepared or
        // torn down. Refusing later was a real leak: Strobe under Reduce
        // Motion prepared an Entertainment session — process-owned, persisted,
        // and live on the bridge — then returned without committing it, so
        // nothing in the app pointed at it and the app's own cleanup would
        // skip it forever as "owned". The previous look could already be gone
        // by then too.
        //
        // And the refusal has to be SAID. It only ever wrote `statusMessage`,
        // which nothing renders, so tapping Strobe under Reduce Motion did
        // nothing at all and looked exactly like a broken card. The notice is
        // the rendered channel; `statusMessage` stays because it is still the
        // debug/telemetry trail for the same event.
        if case .appDriven(let engineKey) = card.strategy,
           engineKey == "strobe", isReduceMotionEnabled {
            studioNotice = StudioNotice(message: StudioSafetyCopy.strobeReduceMotion)
            statusMessage = "⚠ \(StudioSafetyCopy.strobeReduceMotion)"
            return
        }

        // Any candidate prepared below but never committed is stopped on the
        // way out. A defer rather than a return-by-return audit: enumerating
        // today's early exits would not protect the next one added.
        //
        // Scoped to THIS apply's candidate. `apply` is reentrant — it suspends
        // on every bridge read — so two taps can be in flight together, and a
        // rollback of "whatever is currently pending" would stop the other
        // one's session. The defer reads the variable at scope exit, naming
        // whatever this call actually prepared.
        var outstandingCandidateID: UUID?
        defer {
            if let outstandingCandidateID {
                orchestrator.rollbackUncommittedEntertainment(candidateID: outstandingCandidateID)
            }
        }

        // ── Cross-surface conflict: Composer owns this bridge's session ──
        //
        // Every Studio app-driven card routes through startStudioMode, which
        // stops whatever Entertainment client sits on the target bridge without
        // asking who owns it. When the owner is a composition, the stop lands but
        // its bookkeeping survives — the 25 fps loop keeps rendering into a
        // disconnected client, `send` no-ops, `isTerminallyFailed` never trips, so
        // the REST failover never fires either. Silent, permanent, unrecoverable
        // without a restart.
        //
        // Ask before touching anything. Everything below this point is
        // destructive, so the check has to sit above ALL of it — including the
        // same-room replacement teardown.
        //
        // Composition → composition stays promptless: that is a replacement
        // inside the surface that already owns the session, not a takeover.
        if !skipHandoffConfirmation,
           case .appDriven = card.strategy,
           let bridgeID = room.bridgeID,
           let owningRoomID = orchestrator.compositionOwningEntertainment(onBridge: bridgeID) {
            present(EntertainmentHandoffPrompt(
                runningLookName: runningEffect(forRoomID: owningRoomID)?.card.name ?? "A composition",
                requestedLookName: card.name,
                owningRoomID: owningRoomID,
                owningBridgeID: bridgeID,
                card: card,
                room: room,
                preferEntertainmentOverride: preferEntertainmentOverride
            ))
            debugLog("[Handoff] '\(card.name)' needs bridge \(bridgeID); room \(owningRoomID)'s composition owns it — asking first")
            return
        }

        // ── The mirror conflict: one of OUR OWN looks owns this bridge ──
        //
        // Sits immediately below the gate above so `.appDriven` requests keep
        // taking that branch first, and well above the first destructive step
        // (the same-room `stopEffect` further down) and above both prepare
        // sites — everything below this point either mutates or opens a
        // session.
        //
        // The defect: a ChromaGlow session is `processOwned`, so the foreign
        // consent flow is a deliberate no-op against it, and the gate above
        // only covers composition-owns → Studio-requested. A composition asked
        // for a bridge Strobe was streaming and simply got nothing useful.
        //
        // Both calls below are reads: `studioOwningEntertainment` inspects
        // registries and `frozenStartPlan` performs GETs. Nothing is stopped,
        // prepared, published, generated, or moved while the prompt is open.
        if !skipHandoffConfirmation,
           case .composition = card.strategy,
           requestsEntertainment(card, preferEntertainmentOverride: preferEntertainmentOverride),
           let bridgeID = room.bridgeID,
           let owner = orchestrator.studioOwningEntertainment(onBridge: bridgeID) {
            // Freeze BEFORE the slot is set. A bare configuration id would let
            // the area be deleted or re-scoped under the open prompt and still
            // be replayed on the way out.
            //
            // The same exact-target decision the preflight uses, so this gate
            // cannot resolve a room differently from the path just below it.
            let plan: EntertainmentTakeoverPlan
            switch await orchestrator.exactTargetDecision(for: room,
                                                          selectedConfigID: selectedConfigID) {
            case .plan(let resolved):
                plan = resolved

            case .choiceRequired(let choices):
                // WHERE has to be settled before WHETHER TO SWITCH — asking to
                // replace a live look without knowing which area replaces it
                // would be asking the user to approve an unknown.
                present(EntertainmentAreaChoiceRequest(
                    choices: choices, card: card, room: room,
                    preferEntertainmentOverride: preferEntertainmentOverride))
                return

            case .staleSelection:
                studioNotice = StudioNotice(message: EntertainmentAreaChoiceCopy.staleSelection)
                return

            case .noCompatiblePlan, .unreadableBridge, .ambiguousOwnership:
                // NOT the Room-mode sentence: this gate returns without
                // starting anything, on purpose. Falling through to a
                // Room-mode start here would put REST writes on a bridge
                // underneath our own live stream — the exact collision the
                // gate exists to prevent — so the copy must not promise it.
                studioNotice = StudioNotice(
                    message: EntertainmentAvailabilityCopy.noCompatibleAreaNothingChanged)
                return
            }
            present(StudioHandoffRequest(
                plan: plan,
                owner: owner,
                // Name the look as the user knows it; the engine key is the
                // honest fallback when Studio has no registry row for it.
                runningLookName: runningEffect(forRoomID: owner.roomID)?.card.name
                    ?? owner.engineKey.capitalized,
                requestedLookName: card.name,
                card: card,
                room: room,
                preferEntertainmentOverride: preferEntertainmentOverride
            ))
            debugLog("[Handoff] '\(card.name)' needs bridge \(bridgeID); '\(owner.engineKey)' in room \(owner.roomID) is streaming it — asking first")
            return
        }

        // ── Third-party conflict: another APP owns this bridge's session ──
        //
        // Same principle as the app-owned check above, one step further out:
        // everything below is destructive, so the question has to be asked
        // before any of it. The difference is who we are interrupting — this
        // is somebody else's show, and the default is to leave it alone.
        //
        // Every outcome is named, because the honest failures (several
        // controllers at once, an unreadable bridge) must stop here too. An
        // optional answer collapsed those into "carry on", which meant failing
        // OPEN into the teardown below and destroying whatever was playing.
        var preparedEntertainment: UnifiedOrchestrator.EntertainmentPreparation?

        // Which requester the choke point should treat this start as. Derived
        // from the card's strategy, never from a caller-supplied flag: only an
        // app-driven engine has the single-slot eviction that makes replacing
        // our own session on this bridge legitimate.
        let entertainmentRequester: EntertainmentRequester = {
            if case .composition = card.strategy { return .composition }
            return .studio
        }()

        if foreignConsent == nil {
            // Did the USER name Streaming, or did the app pick it?
            //
            // Only an explicit ask earns an interrupting sentence. A transport
            // the app chose on the user's behalf keeps its quiet room-mode
            // fallback — telling someone their tap fell back from a decision
            // they never made is noise. That is also why Party/Strobe/
            // Thunderstorm are out of scope here: their transport is the
            // engine's, never a menu choice.
            let explicitStreamingRequest: Bool
            if case .composition(let presetID) = card.strategy {
                if let preferEntertainmentOverride {
                    explicitStreamingRequest = preferEntertainmentOverride
                } else {
                    // Same lookup `requestsEntertainment` uses, so the two can
                    // never disagree about which preset is being asked about.
                    let preset = compositionStore.presets.first(where: { $0.id == presetID })
                    let preferred: CompositionPreferredTransport? = preset?.preferredTransport
                    explicitStreamingRequest = preferred == .entertainmentArea
                }
            } else {
                explicitStreamingRequest = false
            }

            let preflight = await orchestrator.foreignTakeoverPreflight(
                for: room,
                requestsEntertainment: requestsEntertainment(
                    card, preferEntertainmentOverride: preferEntertainmentOverride),
                selectedConfigID: selectedConfigID)

            switch preflight {
            case .notRequested:
                // This card never streams, so no third party can be in the way.
                break

            case .choiceRequired(let choices):
                // Several areas cover this room. Ask — with nothing prepared,
                // nothing torn down, and no consent implied by the answer.
                //
                // This reaches Party and Thunderstorm too: their transport is
                // the engine's, but WHERE they stream is still the user's, and
                // routing them around the chooser would be the second
                // selection path this decision exists to prevent.
                present(EntertainmentAreaChoiceRequest(
                    choices: choices,
                    card: card,
                    room: room,
                    preferEntertainmentOverride: preferEntertainmentOverride
                ))
                debugLog("[Handoff] \(choices.count) areas could serve room \(room.id) — asking which")
                return

            case .staleSelection:
                // The area the user picked no longer serves this room. Falling
                // back to whatever else is available would stream somewhere
                // they did not choose, so start nothing and say so.
                studioNotice = StudioNotice(message: EntertainmentAreaChoiceCopy.staleSelection)
                statusMessage = "⚠ \(EntertainmentAreaChoiceCopy.staleSelection)"
                debugLog("[Handoff] Selected area no longer valid for room \(room.id) — starting nothing")
                return

            case .noStreamableArea:
                // Room mode still starts — that fallback is honest and is what
                // the user wants far more often than nothing at all. What was
                // missing is the sentence: an explicit "stream this" that
                // quietly became room mode looked like the tap misfired.
                if explicitStreamingRequest {
                    studioNotice = StudioNotice(
                        message: EntertainmentAvailabilityCopy.noCompatibleArea)
                }

            case .clear(let plan):
                // ── The frozen plan is the promise, not a hint ──────────
                //
                // On a confirmed handoff replay there is no consent token, so
                // this branch re-derives the plan from scratch — and the
                // caches it selects from have moved since the prompt was
                // shown (the area could be renamed, re-scoped, or replaced by
                // a different one while the old look was being stopped). The
                // user agreed to open ONE named area; if the re-derivation no
                // longer agrees, we refuse rather than stream somewhere the
                // user was never shown.
                if let consentedPlan, plan != consentedPlan {
                    studioNotice = StudioNotice(
                        message: EntertainmentHandoffCopy.handoffFailed)
                    statusMessage = "⚠ \(EntertainmentHandoffCopy.handoffFailed)"
                    debugLog("[Handoff] Frozen plan no longer matches the area we would open on \(plan.bridgeID) — refusing")
                    return
                }
                // Bridge is free — acquire the session NOW, while the current
                // look is still playing and every scope, task, and registry
                // entry is intact. A controller that claims the bridge between
                // this preflight and the acquisition therefore surfaces as a
                // question, with nothing of the user's already destroyed.
                let preparation = await orchestrator.prepareEntertainment(
                    for: room, requestsEntertainment: true, plan: plan, consent: nil,
                    requester: entertainmentRequester)
                switch preparation {
                case .needsForeignConsent(let snapshot, let targetConfigID):
                    guard snapshot.foreign.count == 1,
                          let foreignConfigID = snapshot.foreign.first,
                          targetConfigID == plan.targetConfigID else {
                        studioNotice = StudioNotice(
                            message: EntertainmentConsentCopy.takeoverFailed)
                        statusMessage = "⚠ \(EntertainmentConsentCopy.takeoverFailed)"
                        return
                    }
                    present(ForeignTakeoverRequest(
                        plan: plan,
                        foreignConfigID: foreignConfigID,
                        card: card,
                        room: room,
                        preferEntertainmentOverride: preferEntertainmentOverride
                    ))
                    debugLog("[Handoff] Bridge \(plan.bridgeID) was claimed during the start — asking, nothing torn down")
                    return
                case .failed(let message):
                    studioNotice = StudioNotice(message: message)
                    statusMessage = "⚠ \(message)"
                    return
                case .prepared(let candidate):
                    outstandingCandidateID = candidate.id
                    preparedEntertainment = preparation
                case .unavailable:
                    // The bridge was free and the plan was valid, yet the
                    // session would not open. Carrying on would start REST
                    // under a look the user explicitly asked to STREAM — the
                    // silent demotion this whole packet exists to end. Refuse
                    // instead; nothing has been torn down yet.
                    if explicitStreamingRequest {
                        studioNotice = StudioNotice(
                            message: EntertainmentAvailabilityCopy.couldNotStart)
                        statusMessage = "⚠ \(EntertainmentAvailabilityCopy.couldNotStart)"
                        return
                    }
                    preparedEntertainment = preparation
                case .heldByAnotherLook:
                    // The late-arrival mirror of `.needsForeignConsent` above:
                    // one of our own looks claimed this bridge between the gate
                    // near the top of `apply` and this acquisition. Same
                    // answer — ask, with nothing torn down.
                    guard let bridgeID = room.bridgeID,
                          let owner = orchestrator.studioOwningEntertainment(onBridge: bridgeID) else {
                        // It released again in the meantime, so there is no
                        // owner to name and no honest question to ask. Saying
                        // "another look is already streaming" here would
                        // contradict the very condition that brought us in:
                        // the owner is GONE. All we can honestly report is
                        // that the start did not happen.
                        studioNotice = StudioNotice(
                            message: EntertainmentAvailabilityCopy.couldNotStart)
                        statusMessage = "⚠ \(EntertainmentAvailabilityCopy.couldNotStart)"
                        return
                    }
                    present(StudioHandoffRequest(
                        plan: plan,
                        owner: owner,
                        runningLookName: runningEffect(forRoomID: owner.roomID)?.card.name
                            ?? owner.engineKey.capitalized,
                        requestedLookName: card.name,
                        card: card,
                        room: room,
                        preferEntertainmentOverride: preferEntertainmentOverride
                    ))
                    debugLog("[Handoff] Bridge \(plan.bridgeID) was claimed by '\(owner.engineKey)' during the start — asking, nothing torn down")
                    return
                case .notNeeded:
                    preparedEntertainment = preparation
                }

            case .conflict(let plan, let foreignConfigID):
                present(ForeignTakeoverRequest(
                    plan: plan,
                    foreignConfigID: foreignConfigID,
                    card: card,
                    room: room,
                    preferEntertainmentOverride: preferEntertainmentOverride
                ))
                debugLog("[Handoff] '\(card.name)' needs bridge \(plan.bridgeID), which another app is using — asking first")
                return

            case .ambiguous:
                // Several controllers are streaming. There is no single
                // session to name, so there is no honest question to ask —
                // and certainly no licence to guess which one to evict.
                studioNotice = StudioNotice(message: EntertainmentConsentCopy.takeoverFailed)
                statusMessage = "⚠ \(EntertainmentConsentCopy.takeoverFailed)"
                debugLog("[Handoff] Several third-party sessions on \(room.bridgeID ?? "?") — failing closed")
                return

            case .unreadable:
                // Unknown is not "free". The currently running effect survives
                // untouched — refusing here mutates nothing at all.
                studioNotice = StudioNotice(message: EntertainmentAvailabilityCopy.couldNotCheck)
                statusMessage = "⚠ \(EntertainmentConsentCopy.bridgeUnreadable)"
                debugLog("[Handoff] Could not read \(room.bridgeID ?? "?") — refusing rather than guessing")
                return
            }
        }

        // After consent the frozen plan is authoritative: acquire with it
        // directly rather than re-selecting, so the replay cannot stream a
        // different area than the one that was agreed to.
        if let foreignConsent, preparedEntertainment == nil {
            let preparation = await orchestrator.prepareEntertainment(
                for: room,
                requestsEntertainment: requestsEntertainment(
                    card, preferEntertainmentOverride: preferEntertainmentOverride),
                plan: consentedPlan,
                consent: foreignConsent,
                requester: entertainmentRequester)
            if case .failed(let message) = preparation {
                studioNotice = StudioNotice(message: message)
                statusMessage = "⚠ \(message)"
                return
            }
            if case .needsForeignConsent = preparation {
                studioNotice = StudioNotice(message: EntertainmentConsentCopy.takeoverFailed)
                statusMessage = "⚠ \(EntertainmentConsentCopy.takeoverFailed)"
                return
            }
            if case .prepared(let candidate) = preparation {
                outstandingCandidateID = candidate.id
            }
            preparedEntertainment = preparation
        }

        // ── Stop any effect already running on THIS room ─────────────
        if let existing = runningEffect(for: room) {
            let existingCard = existing.card
            debugLog("[Studio] Replacing '\(existingCard.name)' on \(room.name)")
            isExplicitStop = false
            await stopEffect(on: StudioSelectionKey(room: room),
                             context: UnifiedOrchestrator.StopAuditContext(
                                 route: .applyReplacement, cardOrEffectID: card.id))

            // Delay if both old and new use REST on the same grouped_light
            let oldIsBridgeNative: Bool
            if case .bridgeNative = existingCard.strategy { oldIsBridgeNative = true } else { oldIsBridgeNative = false }
            let newIsBridgeNative: Bool
            if case .bridgeNative = card.strategy { newIsBridgeNative = true } else { newIsBridgeNative = false }
            if oldIsBridgeNative && newIsBridgeNative {
                try? await Task.sleep(for: .milliseconds(400))
            }
        }

        // ── Studio engine is one slot PER BRIDGE for app-driven cards (round 4g). ──
        // Composition runs per-room and can coexist across rooms. Only a
        // SAME-BRIDGE app-driven effect is replaced here: the orchestrator
        // keys the engine runtime by bridge, so another bridge's loop is not
        // this start's to stop — that cross-bridge stop is exactly the
        // hardware-confirmed "bridge 2 kills bridge 1's stream" defect.
        let newUsesStudioEngine: Bool = {
            switch card.strategy {
            case .appDriven: return true
            case .composition, .bridgeNative: return false
            }
        }()
        if newUsesStudioEngine {
            for (rowKey, effect) in runningEffects
            where rowKey != StudioSelectionKey(room: room) && rowKey.bridgeID == room.bridgeID {
                let effectUsesStudioEngine: Bool = {
                    switch effect.card.strategy {
                    case .appDriven: return true
                    case .composition, .bridgeNative: return false
                    }
                }()
                guard effectUsesStudioEngine else { continue }
                debugLog("[Studio] Stopping '\(effect.card.name)' on \(effect.room.name) (one Studio engine loop per bridge)")
                isExplicitStop = false
                await stopEffect(on: rowKey,
                                 context: UnifiedOrchestrator.StopAuditContext(
                                     route: .applyEngineSingleton, cardOrEffectID: card.id))
            }
        }

        // ── If new card is entertainment-scoped, stop any existing SAME-BRIDGE
        // entertainment effect. One DTLS session per BRIDGE is the real Hue
        // constraint — different bridges stream independently and
        // simultaneously, and another bridge's session must survive this
        // start untouched (round 4g).
        if card.isEntertainmentScoped {
            for (rowKey, effect) in runningEffects
            where effect.isEntertainment && rowKey.bridgeID == room.bridgeID {
                debugLog("[Studio] Stopping entertainment '\(effect.card.name)' on \(effect.room.name) (one DTLS session per bridge)")
                isExplicitStop = false
                await stopEffect(on: rowKey,
                                 context: UnifiedOrchestrator.StopAuditContext(
                                     route: .applyEntertainmentScoped, cardOrEffectID: card.id))
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
            // Same-bridge rows only (round 4g): light ids are BRIDGE-LOCAL,
            // so an id match against another bridge's row is a coincidence of
            // numbering, not a shared bulb — and stopping on it is another
            // route to the cross-bridge teardown this round removes.
            for (rowKey, effect) in runningEffects where rowKey.bridgeID == room.bridgeID {
                let overlap = Set(effect.lightIDs).intersection(newLightSet)
                if !overlap.isEmpty {
                    debugLog("[Handoff] Light overlap detected: \(overlap.count) lights shared with \(effect.room.name) — awaiting teardown barrier")
                    isExplicitStop = false
                    await stopEffect(on: rowKey,
                                     context: UnifiedOrchestrator.StopAuditContext(
                                         route: .applyLightOverlap, cardOrEffectID: card.id))
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

            // Packet 6: claim the room BEFORE the first mutating request, not
            // when the RunningEffect is finally stored ~60 lines below. The
            // steps in between turn the group on and write per-light firmware
            // effects, and All-Day dispatching into that window would overwrite
            // a half-started look.
            //
            // `ownershipTransferred` is what stops the defer from releasing a
            // claim that has been handed to the RunningEffect: after transfer,
            // `stopEffect` is the sole owner of release.
            let bridgeNativeOwnership = orchestrator.beginBridgeNativeOwnership(
                roomID: room.id, bridgeID: room.bridgeID)
            var ownershipTransferred = false
            defer {
                if !ownershipTransferred {
                    orchestrator.endBridgeNativeOwnership(bridgeNativeOwnership)
                }
            }

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

            // The startup was accepted, so the provisional claim becomes the
            // effect's own. Marking it transferred is what keeps the defer above
            // from releasing it on the way out of this scope.
            ownershipTransferred = true
            let identity = installRunningIdentity(
                room: room, card: card,
                execution: .bridgeNative(effect: effectName))
            runningEffects[StudioSelectionKey(room: room)] = RunningEffect(
                cardID: card.id, card: card, room: room,
                lightIDs: drivenIDs, isEntertainment: false,
                requestedTransport: nil, transportFallback: false,
                identity: identity,
                v2CapableLightIDs: v2Capable,
                bridgeNativeOwnership: bridgeNativeOwnership
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
            // The Reduce Motion refusal lives at the very top of `apply` now —
            // refusing here would already have prepared a session and torn the
            // previous look down.
            //
            // Slice 2: the engine box is seeded from SCOPE 1 (the card's
            // persisted next-start defaults). The exact running instance's
            // scope-2 values are registered from the same set the moment the
            // identity is installed below, so box and scopes agree at start.
            let startSet = valueScopes.defaults(forCard: card.id)
            var flatValues = startSet.numbers
            let flatColors = startSet.colors

            if engineKey == "strobe" && isDimFlashingLightsEnabled {
                flatValues["brightness"] = min(flatValues["brightness"] ?? 100, 30)
            }

            let outcome = await orchestrator.startStudioMode(
                key: engineKey, room: room,
                params: flatValues, colors: flatColors,
                capturedPlan: consentedPlan,
                consent: foreignConsent,
                preparedEntertainment: preparedEntertainment
            )
            if await handleStartOutcome(outcome, card: card, room: room,
                                  preferEntertainmentOverride: preferEntertainmentOverride,
                                  hadConsent: foreignConsent != nil) {
                return
            }
            // The transport the start ACTUALLY used, from the outcome itself.
            //
            // This used to peek at `studioEntClients` and infer streaming from
            // a client being installed. A client installed is not a session
            // streaming — that inference is precisely what let ChromaGlow show
            // AREA while Hue Sync still owned the lights. The outcome is the
            // only value that knows which branch ran.
            let isEnt = outcome.startedStreaming
            let identity = installRunningIdentity(
                room: room, card: card,
                execution: .appDriven(engineKey: engineKey))
            runningEffects[StudioSelectionKey(room: room)] = RunningEffect(
                cardID: card.id, card: card, room: room,
                lightIDs: newLightIDs, isEntertainment: isEnt,
                requestedTransport: nil, transportFallback: false,
                identity: identity
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
                async let micHeadStart: Void = { [serviceDriven = BeatClock.shared.isServiceDriven] in
                    guard preset.reaction.needsMicNow(serviceDriven: serviceDriven) else { return }
                    await AudioAnalysisEngine.shared.setDemand(.composerReaction, active: true)
                }()
                // Prefer completing mic handoff before blocking on gamut result — bridge fetch still runs in parallel.
                await micHeadStart
                activeCompositionGamut = await gamutTask
                let box = CompositionParamBox(preset: preset)
                activeCompositionBoxes[StudioSelectionKey(room: room)] = box
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
                let requestedEntertainment = requestsEntertainment(
                    card, preferEntertainmentOverride: preferEntertainmentOverride)
                let requestedTransport: CompositionPreferredTransport = requestedEntertainment ? .entertainmentArea : .roomOnly

                let outcome = await orchestrator.startCompositionMode(
                    room: room,
                    paramBox: box,
                    gamutOverride: activeCompositionGamut,
                    preferEntertainment: requestedEntertainment,
                    tier: tier,
                    preset: preset,
                    capturedPlan: consentedPlan,
                    consent: foreignConsent,
                    preparedEntertainment: preparedEntertainment
                )
                if await handleStartOutcome(outcome, card: card, room: room,
                                      preferEntertainmentOverride: preferEntertainmentOverride,
                                      hadConsent: foreignConsent != nil) {
                    return
                }
                // Same rule as the app-driven arm above: the transport comes
                // from what the start returned, never from a registry peek.
                let isEnt = outcome.startedStreaming
                let identity = installRunningIdentity(
                    room: room, card: card,
                    execution: .composition(presetID: presetID))
                runningEffects[StudioSelectionKey(room: room)] = RunningEffect(
                    cardID: card.id, card: card, room: room,
                    lightIDs: newLightIDs, isEntertainment: isEnt,
                    requestedTransport: requestedTransport,
                    transportFallback: requestedTransport == .entertainmentArea && !isEnt,
                    identity: identity
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
            runningEffects[StudioSelectionKey(room: room)] = RunningEffect(
                cardID: card.id, card: card, room: room,
                lightIDs: newLightIDs, isEntertainment: false,
                requestedTransport: nil, transportFallback: false,
                identity: installRunningIdentity(
                    room: room, card: card,
                    execution: .composition(presetID: presetID))
            )
            publishNowPlaying(room: room, card: card)
            statusMessage = "🟢 \(card.name) → \(room.name) · \(TransportVocabulary.toastOneShot)"
        }

        debugLog("[Studio] Active effects: \(runningEffects.count) rooms")
    }

    /// Stop the effect running on a specific room.
    ///
    /// Packet 6 narrowed the opening guard. It used to also require a resolvable
    /// bridge client AND a groupedLightID, and returned if either was missing —
    /// which left `runningEffects` populated, the Now-Playing row stuck, and
    /// (once ownership existed) the room suppressed from All-Day forever. Only
    /// the effect and the orchestrator are actually needed to begin teardown;
    /// every network step below is best-effort.
    private func stopEffect(on rowKey: StudioSelectionKey,
                            context: UnifiedOrchestrator.StopAuditContext = .unattributed) async {
        guard let effect = runningEffects[rowKey], let orchestrator else { return }
        let roomID = rowKey.groupID

        // Slice 2 production wiring: fence FIRST, before any suspension.
        // Pending debounced sends for this exact instance are cancelled, and
        // the scopes forget it so anything already in flight drops as
        // `.nothingRunning` at its commit/enqueue re-check.
        paramSendTasks[effect.identity.targetKey]?.cancel()
        paramSendTasks[effect.identity.targetKey] = nil
        valueScopes.stopRunning(effect.identity)
        sessionMemory.clear(for: effect.identity.targetKey)
        generationCounter.bump(.stopped)
        bumpLiveValuesTick()
        orchestrator.recordStopAudit(context, operation: .stopRequested,
                                     bridgeID: rowKey.bridgeID, roomID: roomID,
                                     cardOrEffectID: effect.cardID,
                                     outcomeReason: "rowStop")

        // Packet 8: a recovered bridge-stored animation has no engine loop, no
        // per-light firmware state and no REST scope to tear down. The ONLY
        // teardown is its own resources on its own bridge, addressed by the
        // exact manifest — so it takes none of the strategy switch below.
        if let key = effect.recovered {
            let stopped = await orchestrator.stopRecoveredBridgeAnimation(
                key, turnOffLights: isExplicitStop)
            guard stopped else {
                // The animation is still running. Say so, and leave the row and
                // the Now-Playing entry exactly where they are.
                statusMessage = "⚠ Couldn't stop \(effect.card.name) — it's still running on the bridge"
                return
            }
            // Identity-matched removal, same discipline as the tail of this
            // function: a replacement that took this room while the stop was in
            // flight must keep its row.
            guard let current = runningEffects[rowKey], current.recovered == key else { return }
            runningEffects.removeValue(forKey: rowKey)
            orchestrator.recordStopAudit(context, operation: .rowRemoved,
                                         bridgeID: rowKey.bridgeID, roomID: roomID,
                                         cardOrEffectID: current.cardID,
                                         outcomeReason: "recovered")
            // NOT removeActiveEffect(roomID:) — a recovered row is keyed by its
            // manifest, and the orchestrator already removed it.
            return
        }

        let api = orchestrator.hueClient(for: effect.room.bridgeID)
        let groupedLightID = effect.room.groupedLightID
        let ownership = effect.bridgeNativeOwnership
        let stoppingCardID = effect.cardID

        // Release on EVERY terminal path — missing client, missing grouped
        // light, a failed cleanup request, or a room that has disappeared. The
        // claim stays live for the duration of the best-effort cleanup below, so
        // All-Day cannot slip in while the firmware effect is still being torn
        // down. `endBridgeNativeOwnership` is synchronous, so `defer` is legal
        // here, and a stale token is a no-op inside it.
        defer {
            if let ownership { orchestrator.endBridgeNativeOwnership(ownership) }
        }

        debugLog("[Studio] Stopping '\(effect.card.name)' on \(effect.room.name) (glID: \(groupedLightID ?? "nil")) explicit=\(isExplicitStop)")

        switch effect.card.strategy {
        case .bridgeNative:
            // Clean up per-light effects (the ONLY way to clear them)
            if let api, !effect.lightIDs.isEmpty {
                debugLog("[Handoff] Clearing per-light no_effect on \(effect.lightIDs.count) lights for \(effect.room.name)")
                await sendPerLightBatched(lightIDs: effect.lightIDs, api: api) { id in
                    try? await api.setLightNativeEffect(id: id, effect: "no_effect")
                }
                // Allow bridge-side effect transition buffers to settle before a new owner starts.
                try? await Task.sleep(for: .milliseconds(150))
                debugLog("[Handoff] Per-light no_effect cleanup + settle delay complete for \(effect.room.name)")
            }

            if isExplicitStop, let api, let groupedLightID {
                // User tapped Stop — turn off the room (1 PUT)
                try? await api.setGroupedLight(id: groupedLightID, on: false)
            }

        case .appDriven:
            // Room-scoped: the global stopStudioMode() tore down every other
            // room's composition stream and the whole Now-Playing registry.
            await orchestrator.stopAppDrivenStudioEffect(roomID: roomID,
                                                         bridgeID: effect.room.bridgeID,
                                                         context: context)
            try? await Task.sleep(for: .milliseconds(200))

        case .composition:
            await orchestrator.stopCompositionMode(roomID: roomID,
                                                   bridgeID: effect.room.bridgeID)
            // Keyed by the STOPPING row's EXACT bridge + room (round 4e) — the
            // room-id removal used to evict another bridge's same-room-id box.
            activeCompositionBoxes.removeValue(forKey: rowKey)
            if isExplicitStop, let api, let groupedLightID {
                // Ensure composition cards (including bridge one-shot tier)
                // fully release control and don't appear "stuck on".
                try? await api.setGroupedLight(id: groupedLightID, on: false)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Identity-matched removal. This function suspends several times, so a
        // stop that started before a replacement can finish after it — and the
        // old unconditional removal would then erase the REPLACEMENT's entry and
        // its Now-Playing row. Only clear what this stop actually owned.
        guard let current = runningEffects[rowKey],
              current.cardID == stoppingCardID,
              current.bridgeNativeOwnership == ownership else { return }
        runningEffects.removeValue(forKey: rowKey)
        if runningEffects.isEmpty { sessionMemory.clearAll() }   // session over
        orchestrator.recordStopAudit(context, operation: .rowRemoved,
                                     bridgeID: rowKey.bridgeID, roomID: roomID,
                                     cardOrEffectID: stoppingCardID)
        // Exact when the row can name its bridge; a legacy nil-bridge row
        // falls back to the fail-closed room-scoped removal.
        if let bridgeID = rowKey.bridgeID {
            orchestrator.removeActiveEffect(bridgeID: bridgeID, roomID: roomID,
                                            context: context)
        } else {
            orchestrator.removeActiveEffect(roomID: roomID, context: context)
        }
    }

    // ── Cross-surface Entertainment handoff ───────────────────────

    /// Keep playing. The prompt was raised before anything was torn down, so
    /// forgetting it IS the whole undo: no session, task, transport entry, or
    /// selected card has been touched.
    func cancelEntertainmentHandoff() {
        guard let prompt = entertainmentHandoffPrompt else { return }
        debugLog("[Handoff] User kept '\(prompt.runningLookName)' — nothing torn down")
        entertainmentHandoffPrompt = nil
    }

    /// Switch. Stop the composition through its official path — the same one the
    /// Studio stop button uses — and only then replay the original request.
    func confirmEntertainmentHandoff() async {
        // Consumed before the first await, so a double-tap while the teardown is
        // in flight finds nil and returns instead of stopping or starting twice.
        guard let prompt = entertainmentHandoffPrompt else { return }
        entertainmentHandoffPrompt = nil
        guard let orchestrator else { return }

        debugLog("[Handoff] Switching from '\(prompt.runningLookName)' to '\(prompt.requestedLookName)'")
        isExplicitStop = false
        // Round 4e: the prompt CARRIES the owning bridge — resolve the row by
        // its exact key first. The room-only lookup fails closed on a
        // same-room-id collision, which used to drop a perfectly attributable
        // stop to the blunt direct-teardown arm below.
        // The prompt carries bridge + room id but no kind — resolve the unique
        // row under the kind-aware key and fail closed on a room/zone collision.
        if let exactOwningKey = runningKey(bridgeID: prompt.owningBridgeID,
                                           groupID: prompt.owningRoomID) {
            // Studio knows this composition: its own stop path already routes to
            // stopCompositionMode and clears the Now-Playing registry.
            await stopEffect(on: exactOwningKey)
        } else if let owningKey = runningEffectKey(forRoomID: prompt.owningRoomID) {
            await stopEffect(on: owningKey)
        } else {
            // Ownership without an unambiguous Studio registry entry — stop the
            // composition directly rather than leaving the session to be
            // silently orphaned.
            await orchestrator.stopCompositionMode(roomID: prompt.owningRoomID,
                                                   bridgeID: prompt.owningBridgeID)
            if let boxKey = activeCompositionBoxKey(bridgeID: prompt.owningBridgeID,
                                                    groupID: prompt.owningRoomID) {
                activeCompositionBoxes.removeValue(forKey: boxKey)
            }
            if let owningBridgeID = prompt.owningBridgeID {
                orchestrator.removeActiveEffect(
                    bridgeID: owningBridgeID, roomID: prompt.owningRoomID)
            } else {
                orchestrator.removeActiveEffect(roomID: prompt.owningRoomID)
            }
        }

        await apply(prompt.card,
                    roomOverride: prompt.room,
                    preferEntertainmentOverride: prompt.preferEntertainmentOverride,
                    skipHandoffConfirmation: true)
    }

    // ── Studio → composition handoff (packet 7 hardware follow-up) ─────

    /// Keep Playing. The request was raised before anything was touched, so
    /// forgetting it IS the whole undo: no session was stopped, no plan acted
    /// on, no bookkeeping moved. The running look keeps streaming.
    func cancelStudioHandoff() {
        guard let request = studioHandoffRequest else { return }
        debugLog("[Handoff] User kept '\(request.runningLookName)' on bridge \(request.bridgeID) — nothing torn down")
        studioHandoffRequest = nil
    }

    /// Switch. Stop exactly the ChromaGlow look the user named, prove it
    /// released, and only then replay the composition request.
    func confirmStudioHandoff() async {
        // Cleared before the first await, so a double-tap while the teardown is
        // in flight finds nil and returns instead of stopping or starting twice.
        guard let request = studioHandoffRequest else { return }
        studioHandoffRequest = nil
        guard let orchestrator else { return }

        debugLog("[Handoff] Switching from '\(request.runningLookName)' to '\(request.requestedLookName)' on \(request.bridgeID)")

        switch await orchestrator.resolveStudioHandoff(requestID: request.id,
                                                       plan: request.plan,
                                                       room: request.room,
                                                       owner: request.owner) {
        case .failed(let message):
            // Never claim a switch that did not happen.
            studioNotice = StudioNotice(message: message)
            statusMessage = "⚠ \(message)"

        case .changedOwner(let owner):
            // A different one of our looks owns the bridge now. The user agreed
            // to stop one specific look, not whatever came next — so ask again,
            // with a FRESH id and therefore a fresh token.
            debugLog("[Handoff] Owner changed before confirmation — asking again")
            present(StudioHandoffRequest(
                plan: request.plan,
                owner: owner,
                runningLookName: runningEffect(forRoomID: owner.roomID)?.card.name
                    ?? owner.engineKey.capitalized,
                requestedLookName: request.requestedLookName,
                card: request.card,
                room: request.room,
                preferEntertainmentOverride: request.preferEntertainmentOverride
            ))

        case .resolved:
            await replayStudioHandoff(request)

        case .ownerGone:
            // The look ended on its own. The bridge is free either way, so the
            // replay is identical — but the two states are kept as two cases,
            // because collapsing them would hide which one actually happened
            // from anyone reading a log or a test.
            await replayStudioHandoff(request)
        }
    }

    /// Clear the Studio mirror of the look that is no longer streaming, then
    /// replay the original composition request through the normal path.
    ///
    /// `skipHandoffConfirmation: true` suppresses ONLY the two ChromaGlow-owned
    /// handoff questions. The replay still runs `foreignTakeoverPreflight` in
    /// full and still passes `foreignConsent: nil`, so a third party that
    /// claimed the area while the old look was being stopped surfaces as the
    /// takeover prompt — it is never stopped, and no REST fallback runs under
    /// it. `consentedPlan` authorizes nothing — it is the plan the user was
    /// SHOWN, and the replay's re-derived plan is checked against it: if the
    /// area the app would open is no longer the one named in the prompt, the
    /// start is refused rather than silently redirected.
    private func replayStudioHandoff(_ request: StudioHandoffRequest) async {
        // The session is gone, so its Now-Playing row and Studio entry are
        // claims about something that is no longer running. Both removals are
        // exact — the owner names its bridge — and a recovered bridge-stored
        // row (keyed by its manifest) structurally cannot be reached from
        // either.
        if let key = runningKey(bridgeID: request.owner.bridgeID,
                                groupID: request.owner.roomID) {
            stopRunningScopes(forRowAt: key)
            runningEffects.removeValue(forKey: key)
        }
        orchestrator?.removeActiveEffect(
            bridgeID: request.owner.bridgeID, roomID: request.owner.roomID)

        await apply(request.card,
                    roomOverride: request.room,
                    preferEntertainmentOverride: request.preferEntertainmentOverride,
                    skipHandoffConfirmation: true,
                    consentedPlan: request.plan)
    }

    // ── Third-party takeover consent (packet 7) ───────────────────

    /// React to a start that did not begin playback. Returns true when `apply`
    /// must stop here — the start never happened.
    ///
    /// A foreign conflict discovered mid-start is a real possibility: another
    /// app can begin streaming between the preflight and the acquisition. It
    /// gets the same answer as the preflight — ask, never fall back quietly.
    @discardableResult
    private func handleStartOutcome(_ outcome: PlaybackStartOutcome,
                                    card: StudioCard,
                                    room: RoomDisplayItem,
                                    preferEntertainmentOverride: Bool?,
                                    hadConsent: Bool) async -> Bool {
        switch outcome {
        case .started:
            return false

        case .failed(let message):
            // A rendered sentence, not just `statusMessage` — nothing renders
            // that. This arm is reached by the confirmed-switch replay, where
            // the old look has ALREADY been stopped: silence here means the
            // lights went out and the app said nothing at all.
            studioNotice = StudioNotice(message: message)
            statusMessage = "⚠ \(message)"
            return true

        case .needsForeignConsent(let snapshot, let targetConfigID):
            guard let bridgeID = room.bridgeID,
                  snapshot.foreign.count == 1,
                  let foreignConfigID = snapshot.foreign.first else {
                // Several controllers, or none we can name: fail closed rather
                // than guess which one the user meant to replace.
                studioNotice = StudioNotice(message: EntertainmentConsentCopy.takeoverFailed)
                statusMessage = "⚠ \(EntertainmentConsentCopy.takeoverFailed)"
                return true
            }
            // A consented start reaching this arm is not a loop (round 3): the
            // commit-boundary verification only returns a contested verdict
            // for a controller PROVEN there — either a different configuration
            // observed directly, or the consented one observed inactive after
            // our own release and then observed active again. Both are new
            // conflicts the old consent never covered, and both HCT-02 and
            // HCT-03 already established that the honest next step is a fresh
            // question about what is actually there. Each prompt costs the
            // user a tap, so nothing here can spin.
            _ = hadConsent
            // Re-derive the frozen plan for the request we are about to raise.
            // Falling back to a bare id here would reintroduce exactly what
            // the plan exists to prevent.
            guard case .conflict(let plan, _) = await orchestrator?.foreignTakeoverPreflight(
                    for: room,
                    requestsEntertainment: requestsEntertainment(
                        card, preferEntertainmentOverride: preferEntertainmentOverride))
            else {
                studioNotice = StudioNotice(message: EntertainmentConsentCopy.takeoverFailed)
                statusMessage = "⚠ \(EntertainmentConsentCopy.takeoverFailed)"
                return true
            }
            guard plan.targetConfigID == targetConfigID else {
                studioNotice = StudioNotice(message: EntertainmentConsentCopy.takeoverFailed)
                statusMessage = "⚠ \(EntertainmentConsentCopy.takeoverFailed)"
                return true
            }
            _ = bridgeID
            present(ForeignTakeoverRequest(
                plan: plan,
                foreignConfigID: foreignConfigID,
                card: card,
                room: room,
                preferEntertainmentOverride: preferEntertainmentOverride
            ))
            return true
        }
    }

    /// Keep Existing. The request was raised before anything was touched, so
    /// forgetting it IS the whole undo: no stop was sent, no session opened,
    /// no playback bookkeeping changed. The other app keeps playing.
    func cancelForeignTakeover() {
        guard let request = foreignTakeoverRequest else { return }
        debugLog("[Handoff] User kept the other app's session on bridge \(request.bridgeID) — nothing touched")
        foreignTakeoverRequest = nil
    }

    /// Take Over. Re-check the bridge, stop exactly the session the user
    /// agreed to replace, and only then replay the original request.
    func confirmForeignTakeover() async {
        // Consumed before the first await, so a double-tap while the takeover
        // is in flight finds nil and returns instead of stopping or starting
        // twice.
        guard let request = foreignTakeoverRequest else { return }
        foreignTakeoverRequest = nil
        guard let orchestrator else { return }

        let resolution = await orchestrator.resolveForeignTakeover(
            requestID: request.id,
            plan: request.plan,
            room: request.room,
            foreignConfigID: request.foreignConfigID
        )

        switch resolution {
        case .failed(let message):
            // Never claim a takeover that did not happen — and never say it
            // only to `statusMessage`, which nothing renders.
            studioNotice = StudioNotice(message: message)
            statusMessage = "⚠ \(message)"

        case .changedOwner(let snapshot):
            // A different controller is streaming now. The user consented to
            // replacing one specific session, not to whatever came next.
            guard snapshot.foreign.count == 1,
                  let foreignConfigID = snapshot.foreign.first else {
                studioNotice = StudioNotice(message: EntertainmentConsentCopy.takeoverFailed)
                statusMessage = "⚠ \(EntertainmentConsentCopy.takeoverFailed)"
                return
            }
            debugLog("[Handoff] Owner changed before confirmation — asking again")
            present(ForeignTakeoverRequest(
                plan: request.plan,
                foreignConfigID: foreignConfigID,
                card: request.card,
                room: request.room,
                preferEntertainmentOverride: request.preferEntertainmentOverride
            ))

        case .resolved(let consent):
            // The bridge is clear. Replay the original request exactly once,
            // through the normal production path, carrying the token — so it
            // cannot prompt again and cannot start twice. The choke point
            // spends the token when it accepts it.
            await apply(request.card,
                        roomOverride: request.room,
                        preferEntertainmentOverride: request.preferEntertainmentOverride,
                        skipHandoffConfirmation: true,
                        foreignConsent: consent,
                        consentedPlan: request.plan)
        }
    }

    /// Explicit stop — called when user taps the stop button directly.
    /// Turns off the room's lights.
    func explicitStop(_ card: StudioCard) async {
        guard let room = selectedRoom else { return }
        let context = UnifiedOrchestrator.StopAuditContext(
            route: .explicitStop, cardOrEffectID: card.id)
        // Audit note: this route targets the SELECTED room's row, not the
        // tapped card's — record both identities so a hardware trace can say
        // whether they disagreed.
        orchestrator?.recordStopAudit(context, operation: .stopRequested,
                                      bridgeID: room.bridgeID, roomID: room.id,
                                      cardOrEffectID: card.id,
                                      outcomeReason: "explicitStopEntry selectedRoom=\(room.id)")
        isExplicitStop = true
        await stopEffect(on: StudioSelectionKey(room: room), context: context)
        statusMessage = ""
    }

    /// Stop all running effects across all rooms.
    func stopAll() async {
        let context = UnifiedOrchestrator.StopAuditContext(route: .stopAll)
        orchestrator?.recordStopAudit(context, operation: .stopAllInvoked,
                                      bridgeID: nil, roomID: nil,
                                      outcomeReason: "rows=\(runningEffects.count)")
        isExplicitStop = true
        let rowKeys = Array(runningEffects.keys)
        for rowKey in rowKeys {
            await stopEffect(on: rowKey, context: context)
        }
        // Belt over the per-row stops: every pending send and every live
        // scope entry dies with the session, whatever the row keys were.
        for task in paramSendTasks.values { task.cancel() }
        paramSendTasks.removeAll()
        valueScopes.stopAll()
        sessionMemory.clearAll()   // session over — a future one starts clean
        generationCounter.bump(.stopped)
        bumpLiveValuesTick()
        statusMessage = ""
    }

    // ──────────────────────────────────────────────
    // MARK: - Live Param Updates
    // ──────────────────────────────────────────────
    //
    // The old `sendParam` / `sendColorParam` pair — one GLOBAL debounce task
    // that re-read `selectedRoom` after its sleep — is gone. Debounced bridge
    // sends now live in `StudioViewModel+CustomizationWiring.swift`, keyed by
    // exact running target and fenced on the identity captured when the
    // gesture began.


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
    ///
    /// Returns whether the draft is present and usable afterwards. This is a READINESS
    /// result, not a novelty claim: the sentinel id is fixed, so the draft is minted once
    /// and reused forever. "Did this tap start something new" is carried separately by
    /// `NewCompositionCreation.wasAlreadyRunning`.
    @discardableResult
    func ensureComposerStarterDraft() -> Bool {
        guard !compositionStore.presets.contains(where: { $0.id == Self.composerStarterDraftPresetID }) else { return true }
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
        return compositionStore.presets.contains(where: { $0.id == Self.composerStarterDraftPresetID })
    }

    /// What ONE "+ Create" tap actually accomplished.
    ///
    /// Every field is measured against the room captured AT THE TAP. Inferring success
    /// from `currentRoomEffect` instead would be wrong twice over: it follows
    /// `selectedRoom`, so a mid-await scrub makes it report on a room the user was not
    /// creating in, and it cannot tell a fresh start from the starter card that was
    /// already running before the tap.
    struct NewCompositionCreation {
        /// The selection captured at the tap, before any await.
        let target: StudioSelectionKey?
        /// The starter draft exists and is usable.
        let draftReady: Bool
        /// The starter card was ALREADY running in `target` before we applied — this
        /// tap started nothing new, so it is a re-entry, not a creation.
        let wasAlreadyRunning: Bool
        /// `apply` left the starter card running in `target` specifically.
        let applied: Bool

        /// A new composition was created BY THIS TAP. Anything less — no room, a
        /// refused or cancelled apply, a re-entry on an already-running card — is not
        /// deliberate creation and must not open the editor.
        var createdNewComposition: Bool { draftReady && applied && !wasAlreadyRunning }
    }

    /// "+ Create": mint the starter draft if needed and start it in `room`.
    ///
    /// `room` is passed explicitly rather than resolved from `selectedRoom` inside
    /// `apply`. `roomOverride: nil` resolves the selection at APPLY time, so a scrub
    /// during the await could start playback in a room the user had already left. Every
    /// other apply site captures a `roomSnapshot` the same way.
    func createStarterComposition(in room: RoomDisplayItem?) async -> NewCompositionCreation {
        guard let room else {
            return NewCompositionCreation(
                target: nil, draftReady: false, wasAlreadyRunning: false, applied: false)
        }
        let draftReady = ensureComposerStarterDraft()
        let card = starterCompositionCard()
        let wasAlreadyRunning = runningEffect(for: room)?.cardID == card.id

        await apply(card, roomOverride: room, preferEntertainmentOverride: false)

        return NewCompositionCreation(
            target: StudioSelectionKey(room: room),
            draftReady: draftReady,
            wasAlreadyRunning: wasAlreadyRunning,
            applied: runningEffect(for: room)?.cardID == card.id)
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

    /// What ONE AI generation's application actually accomplished.
    ///
    /// Same discipline as `NewCompositionCreation`: every field is measured against
    /// the room captured WHEN THE OPERATION STARTED, never against whatever
    /// `selectedRoom` points at after the awaits. The `presetID` names the exact
    /// generated preset, so a caller holding several overlapping operations can
    /// tell whose result this is.
    struct AIGenerationApplication {
        enum Disposition: Equatable {
            /// `apply` left the generated card running in `target`.
            case applied
            /// `apply` returned without starting it (a refusal surface, a missing
            /// room, or any of apply's early returns).
            case refused
            /// The view is holding the generated preset behind the transport
            /// prompt; nothing has been applied yet.
            case transportPromptPending
            /// The selection moved away from `target` before application; nothing
            /// was applied and no editor may open.
            case staleSelection
            /// A newer AI operation was started; this one must do nothing.
            case superseded
            /// Generation itself failed; there is no preset to apply.
            case failed
        }
        /// The exact selection captured at the operation start.
        let target: StudioSelectionKey?
        /// The generated preset's identity.
        let presetID: UUID?
        let disposition: Disposition
    }

    /// Apply an AI-generated preset to the room captured at the operation start.
    ///
    /// `room` is passed explicitly for the same reason `createStarterComposition`
    /// passes it: `roomOverride: nil` resolves the selection at APPLY time, so a
    /// scrub during the await could start playback in a room the user had left.
    func applyGeneratedComposition(
        _ preset: CompositionPreset,
        in room: RoomDisplayItem?,
        preferEntertainmentOverride: Bool?
    ) async -> AIGenerationApplication {
        guard let room else {
            return AIGenerationApplication(target: nil, presetID: preset.id, disposition: .refused)
        }
        let card = studioCard(for: preset)
        await apply(card, roomOverride: room, preferEntertainmentOverride: preferEntertainmentOverride)
        let applied = runningEffect(for: room)?.cardID == card.id
        return AIGenerationApplication(
            target: StudioSelectionKey(room: room),
            presetID: preset.id,
            disposition: applied ? .applied : .refused)
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

        let rowKeys = Array(runningEffects.keys).filter { rowKey in
            guard let effect = runningEffects[rowKey] else { return false }
            guard case .composition(let pid) = effect.card.strategy else { return false }
            return pid == id
        }
        for rowKey in rowKeys {
            guard let effect = runningEffects[rowKey] else { continue }
            let freshCard = studioCard(for: fresh)
            runningEffects[rowKey] = RunningEffect(
                cardID: effect.cardID,
                card: freshCard,
                room: effect.room,
                lightIDs: effect.lightIDs,
                isEntertainment: effect.isEntertainment,
                requestedTransport: effect.requestedTransport,
                transportFallback: effect.transportFallback,
                // A rename replaces the ROW, not the running instance — the
                // identity (and its generation) carries over unchanged.
                identity: effect.identity
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
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 400, tier: .support),
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
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 400, tier: .support),
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
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 400, tier: .support),
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
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 1500, tier: .support),
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
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 400, tier: .support),
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
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 400, tier: .support),
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
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 400, tier: .support),
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
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 400, tier: .support),
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
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 400, tier: .support),
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
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 400, tier: .support),
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
                    StudioParam(id: "transition", label: "Smoothness", kind: .segmented(options: StudioParamFormat.transitionOptions), defaultValue: 1500, tier: .support),
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
                    StudioParam(id: "speed", label: "Speed", kind: .slider(min: 0, max: 100), defaultValue: 60, tier: .essential, format: StudioParamFormat.flashHz, entOnly: true),
                    StudioParam(id: "brightness", label: "Brightness", kind: .slider(min: 1, max: 100), defaultValue: 90, tier: .essential),
                    StudioParam(id: "color", label: "Flash Color", kind: .colorPicker, defaultValue: 0, tier: .color),
                    StudioParam(id: "min_brightness", label: "Fade Floor", kind: .slider(min: 0, max: 50), defaultValue: 5, tier: .support, entOnly: true),
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
                    StudioParam(id: "min_brightness", label: "Min Brightness", kind: .slider(min: 0, max: 50), defaultValue: 0, tier: .support),
                    StudioParam(id: "duty_cycle", label: "Duty Cycle", kind: .slider(min: 10, max: 90), defaultValue: 50, tier: .support, entOnly: true),
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
                    StudioParam(id: "min_brightness", label: "Ambient Level", kind: .slider(min: 1, max: 30), defaultValue: 5, tier: .support),
                    // Every knob the engine has, exposed. Defaults reproduce the
                    // storm exactly as it behaved when these were literals.
                    StudioParam(id: "strike_rate", label: "Strike Chance", kind: .slider(min: 0, max: 100), defaultValue: 50, tier: .support),
                    StudioParam(id: "flash_length", label: "Flash Length", kind: .slider(min: 1, max: 8), defaultValue: 3, tier: .support, entOnly: true),
                    StudioParam(id: "afterglow", label: "Afterglow", kind: .slider(min: 0, max: 5), defaultValue: 1, tier: .support, entOnly: true),
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
                    StudioParam(id: "smoothness", label: "Smoothness", kind: .slider(min: 0, max: 100), defaultValue: 70, tier: .support),
                    StudioParam(id: "min_brightness", label: "Min Brightness", kind: .slider(min: 1, max: 50), defaultValue: 15, tier: .support),
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

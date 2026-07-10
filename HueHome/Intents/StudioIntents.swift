// StudioIntents.swift
// ChromaGlow — Siri Shortcuts
//
// The open-app intents: Composer scenes and Studio effects only run while
// the app is foregrounded (their render loops live in the app process), so
// these use openAppWhenRun = true and hand off through the deep-link
// coordinator's pending-action slot — the same pattern shared scenes and
// widget room taps already use. StudioView drains the action and routes it
// through StudioViewModel.apply so Studio's UI state (runningEffects, the
// shared now-playing registry, mixer tray) stays in sync — starting the
// orchestrator directly from here would desync all of it.

import AppIntents

// MARK: - PendingStudioAction

/// What Siri asked Studio to start. Carried by DeepLinkCoordinator.
enum PendingStudioAction: Equatable {
    case composition(presetID: UUID, groupID: String)
    case effect(effectID: String, groupID: String)
}

// MARK: - CompositionEntity

struct CompositionEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Composer Scene")
    static var defaultQuery = CompositionEntityQuery()

    var id: String        // CompositionPreset.id.uuidString
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: name),
            subtitle: "Composer scene"
        )
    }

    init(preset: CompositionPreset) {
        self.id   = preset.id.uuidString
        self.name = preset.name
    }
}

struct CompositionEntityQuery: EntityStringQuery {

    /// Entity queries run in the app process, so the compositions file is
    /// directly readable — no App Group snapshot needed, never stale. The
    /// pure static read touches no live store (Studio owns the only one)
    /// and the seed result is discarded, never persisted from here.
    static func allPresets() -> [CompositionPreset] {
        eligible(CompositionStore.readPresets(from: CompositionStore.defaultFileURL).presets)
    }

    /// What Siri may offer: everything except the `+ Create` starter draft.
    /// Pure — unit-tested.
    static func eligible(_ presets: [CompositionPreset]) -> [CompositionPreset] {
        presets.filter { $0.id != StudioViewModel.composerStarterDraftPresetID }
    }

    func entities(for identifiers: [String]) async throws -> [CompositionEntity] {
        Self.allPresets()
            .filter { identifiers.contains($0.id.uuidString) }
            .map(CompositionEntity.init(preset:))
    }

    func entities(matching string: String) async throws -> [CompositionEntity] {
        Self.allPresets()
            .filter { HueGroupEntityQuery.matches(name: $0.name, query: string) }
            .map(CompositionEntity.init(preset:))
    }

    func suggestedEntities() async throws -> [CompositionEntity] {
        Self.allPresets().map(CompositionEntity.init(preset:))
    }
}

// MARK: - StudioEffectChoice

/// The Studio deck cards Siri can start, by card id. This is the STUDIO
/// catalog (StudioViewModel.buildEffectCards/buildLiveModeCards — what
/// apply() can actually run), NOT EffectLibrary (the automations surface).
/// A parity test pins the case list to the catalogs.
enum StudioEffectChoice: String, AppEnum, CaseIterable {
    case candle, fire, sparkle, prism, opal, glisten
    case cosmos, enchant, sunbeam, underwater, colorloop
    case party, strobe, thunderstorm, ambient

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Studio Effect")

    static var caseDisplayRepresentations: [StudioEffectChoice: DisplayRepresentation] = [
        .candle: "Candle", .fire: "Fire", .sparkle: "Sparkle",
        .prism: "Prism", .opal: "Opal", .glisten: "Glisten",
        .cosmos: "Cosmos", .enchant: "Enchant", .sunbeam: "Sunbeam",
        .underwater: "Underwater", .colorloop: "Color Loop",
        .party: "Party", .strobe: "Strobe",
        .thunderstorm: "Thunderstorm", .ambient: "Ambient",
    ]

    /// Name as spoken back in the result dialog (matches the card name).
    var displayName: String {
        switch self {
        case .colorloop: return "Color Loop"
        default:         return rawValue.capitalized
        }
    }
}

// MARK: - StartStudioEffectIntent

struct StartStudioEffectIntent: AppIntent {

    static var title: LocalizedStringResource = "Start Studio Effect"
    static var description = IntentDescription(
        "Open ChromaGlow and start a Studio effect in a room.",
        categoryName: "Studio"
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Effect")
    var effect: StudioEffectChoice

    @Parameter(title: "Room or Zone")
    var group: HueGroupEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        DeepLinkCoordinator.shared.requestStudioAction(
            .effect(effectID: effect.rawValue, groupID: group.id)
        )
        return .result(dialog: "Starting \(effect.displayName) in \(group.name).")
    }
}

// MARK: - StartCompositionIntent

struct StartCompositionIntent: AppIntent {

    static var title: LocalizedStringResource = "Start Composer Scene"
    static var description = IntentDescription(
        "Open ChromaGlow and start a Composer scene in a room. Live scenes run while the app is open.",
        categoryName: "Studio"
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Composer Scene")
    var composition: CompositionEntity

    @Parameter(title: "Room or Zone")
    var group: HueGroupEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let presetID = UUID(uuidString: composition.id) else {
            throw IntentError.unknownEntity("Composer scene")
        }
        DeepLinkCoordinator.shared.requestStudioAction(
            .composition(presetID: presetID, groupID: group.id)
        )
        return .result(dialog: "Starting \(composition.name) in \(group.name).")
    }
}

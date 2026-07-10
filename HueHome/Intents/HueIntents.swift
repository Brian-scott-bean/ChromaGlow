// HueIntents.swift
// ChromaGlow — Siri Shortcuts
//
// "Hey Siri, turn on Living Room in ChromaGlow"
// "Hey Siri, dim Kitchen in ChromaGlow"
//
// Background intents: openAppWhenRun = false, so they run in a background
// launch of the app process where the orchestrator is NEVER configured
// (AppRootView.task doesn't fire). They must stay on the lightweight
// direct-client pattern — WidgetDataStore snapshot + HueIntentAPIClient —
// and never touch UnifiedOrchestrator.

import AppIntents

// MARK: - PowerState

/// On/off as an AppEnum. A Bool parameter can neither appear in a Siri
/// phrase nor be reliably prefilled in an AppShortcut, so "Turn on X" and
/// "Turn off X" are two shortcuts prefilled with these cases.
enum PowerState: String, AppEnum {
    case on
    case off

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Power")
    static var caseDisplayRepresentations: [PowerState: DisplayRepresentation] = [
        .on:  "On",
        .off: "Off",
    ]

    var isOn: Bool { self == .on }
}

// MARK: - GroupPowerIntent

struct GroupPowerIntent: AppIntent {

    static var title: LocalizedStringResource = "Turn Lights On or Off"
    static var description = IntentDescription(
        "Turn a room's or zone's lights on or off.",
        categoryName: "Lights"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Room or Zone")
    var group: HueGroupEntity

    @Parameter(title: "Power", default: .on)
    var power: PowerState

    init() {}

    init(power: PowerState) {
        self.power = power
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let creds = WidgetDataStore.shared.credentials(for: group.bridgeID) else {
            throw IntentError.noBridgeConnection
        }
        guard let glId = group.groupedLightId else {
            throw IntentError.noGroupedLight(group.name)
        }
        do {
            try await HueIntentAPIClient.setGroupedLight(
                id: glId, on: power.isOn, ip: creds.ip, token: creds.token
            )
        } catch {
            throw IntentError.bridgeUnreachable(group.name)
        }
        return .result(dialog: "\(group.name) is now \(power.rawValue).")
    }
}

// MARK: - GroupBrightnessIntent

struct GroupBrightnessIntent: AppIntent {

    static var title: LocalizedStringResource = "Set Brightness"
    static var description = IntentDescription(
        "Set the brightness of a room's or zone's lights.",
        categoryName: "Lights"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Room or Zone")
    var group: HueGroupEntity

    @Parameter(title: "Brightness", default: 80,
               inclusiveRange: (lowerBound: 1, upperBound: 100))
    var brightness: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let creds = WidgetDataStore.shared.credentials(for: group.bridgeID) else {
            throw IntentError.noBridgeConnection
        }
        guard let glId = group.groupedLightId else {
            throw IntentError.noGroupedLight(group.name)
        }
        do {
            try await HueIntentAPIClient.setGroupedLight(
                id: glId, brightness: Double(brightness), ip: creds.ip, token: creds.token
            )
        } catch {
            throw IntentError.bridgeUnreachable(group.name)
        }
        return .result(dialog: "\(group.name) brightness set to \(brightness)%.")
    }
}

// MARK: - RecallSceneIntent

struct RecallSceneIntent: AppIntent {

    static var title: LocalizedStringResource = "Activate Scene"
    static var description = IntentDescription(
        "Activate one of your Hue scenes.",
        categoryName: "Lights"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Scene")
    var scene: HueSceneEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let creds = WidgetDataStore.shared.credentials(for: scene.bridgeID) else {
            throw IntentError.noBridgeConnection
        }
        do {
            try await HueIntentAPIClient.recallScene(
                id: scene.id, ip: creds.ip, token: creds.token
            )
        } catch {
            throw IntentError.bridgeUnreachable(scene.name)
        }
        let room = WidgetDataStore.shared.groups
            .first { $0.id == scene.ownerGroupID }?.name
        let location = room.map { " in \($0)" } ?? ""
        return .result(dialog: "\(scene.name) is on\(location).")
    }
}

// MARK: - GroupColorIntent

struct GroupColorIntent: AppIntent {

    static var title: LocalizedStringResource = "Set Light Color"
    static var description = IntentDescription(
        "Set a room's or zone's lights to a named color or white.",
        categoryName: "Lights"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Room or Zone")
    var group: HueGroupEntity

    @Parameter(title: "Color")
    var color: NamedColorChoice

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let creds = WidgetDataStore.shared.credentials(for: group.bridgeID) else {
            throw IntentError.noBridgeConnection
        }
        guard let glId = group.groupedLightId else {
            throw IntentError.noGroupedLight(group.name)
        }
        do {
            switch SiriColorTable.payload(for: color) {
            case .xy(let x, let y):
                try await HueIntentAPIClient.setGroupedLightColor(
                    id: glId, x: x, y: y, ip: creds.ip, token: creds.token
                )
            case .mirek(let mirek):
                try await HueIntentAPIClient.setGroupedLightColorTemp(
                    id: glId, mirek: mirek, ip: creds.ip, token: creds.token
                )
            }
        } catch {
            throw IntentError.bridgeUnreachable(group.name)
        }
        return .result(dialog: "\(group.name) is now \(color.spokenName).")
    }
}

// MARK: - PresetOption

/// Energize/Read/Relax/Sleep as an AppEnum. rawValue == LightingPreset.id
/// (the same contract the widget's PresetChoice keeps) — do not rename cases.
enum PresetOption: String, AppEnum, CaseIterable {
    case energize, read, relax, sleep

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Lighting Preset")
    static var caseDisplayRepresentations: [PresetOption: DisplayRepresentation] = [
        .energize: "Energize", .read: "Read", .relax: "Relax", .sleep: "Sleep",
    ]
}

// MARK: - LightingPresetIntent

struct LightingPresetIntent: AppIntent {

    static var title: LocalizedStringResource = "Apply Lighting Preset"
    static var description = IntentDescription(
        "Apply Energize, Read, Relax, or Sleep to one room or the whole home.",
        categoryName: "Lights"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Preset")
    var preset: PresetOption

    /// Optional scope — nil means every room and zone.
    @Parameter(title: "Room or Zone")
    var group: HueGroupEntity?

    /// Scope selection, pure for tests: nil scope = whole home; an unknown
    /// scope id selects nothing (the entity was deleted since resolution).
    static func presetTargets(
        groups: [WidgetRoomSnapshot], scopeID: String?
    ) -> [WidgetRoomSnapshot] {
        guard let scopeID else { return groups }
        return groups.filter { $0.id == scopeID }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let lighting = LightingPreset.find(preset.rawValue) else {
            throw IntentError.unknownEntity("preset")
        }
        let store = WidgetDataStore.shared
        let scoped = Self.presetTargets(groups: store.groups, scopeID: group?.id)
        // Whole-home only: drop zones that would double-hit room lights.
        let targets = group == nil ? Self.dedupedWholeHomeTargets(scoped) : scoped
        guard !targets.isEmpty else {
            throw group == nil ? IntentError.noBridgeConnection
                               : IntentError.unknownEntity("room")
        }

        let outcomes = await Self.fanOut(to: targets, store: store) { glId, creds in
            try await HueIntentAPIClient.applyPreset(lighting, to: glId, ip: creds.ip, token: creds.token)
        }
        let failed = outcomes.filter { !$0.ok }.map(\.name)
        guard failed.count < outcomes.count else {
            throw IntentError.bridgeUnreachable(group?.name ?? "your lights")
        }
        if !failed.isEmpty {
            throw IntentError.partialFailure(lighting.name, failed)
        }
        if let group {
            return .result(dialog: "\(lighting.name) applied to \(group.name).")
        }
        let count = outcomes.count
        return .result(dialog: "\(lighting.name) applied to \(count) room\(count == 1 ? "" : "s").")
    }
}

// MARK: - AllLightsIntent

struct AllLightsIntent: AppIntent {

    static var title: LocalizedStringResource = "All Lights"
    static var description = IntentDescription(
        "Turn every light on or off. On is a warm welcome-home, not a bare full blast.",
        categoryName: "Lights"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Power", default: .off)
    var power: PowerState

    init() {}

    init(power: PowerState) {
        self.power = power
    }

    /// Single source: LightingPreset.welcomeHome (shared with the widget's
    /// SetAllLightsPowerIntent so the two "all lights on" surfaces can't drift).
    static let welcomeHome = LightingPreset.welcomeHome

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = WidgetDataStore.shared
        guard !store.groups.isEmpty else { throw IntentError.noBridgeConnection }

        let isOn = power.isOn
        let targets = Self.dedupedWholeHomeTargets(store.groups)
        let outcomes = await Self.fanOut(to: targets, store: store) { glId, creds in
            if isOn {
                try await HueIntentAPIClient.applyPreset(Self.welcomeHome, to: glId, ip: creds.ip, token: creds.token)
            } else {
                try await HueIntentAPIClient.setGroupedLight(id: glId, on: false, ip: creds.ip, token: creds.token)
            }
        }
        let failed = outcomes.filter { !$0.ok }.map(\.name)
        guard failed.count < outcomes.count else {
            throw IntentError.bridgeUnreachable("your lights")
        }
        if !failed.isEmpty {
            throw IntentError.partialFailure("All lights \(power.rawValue)", failed)
        }
        return .result(dialog: "All lights are \(power.rawValue).")
    }
}

// MARK: - StopLightEffectsIntent

extension Notification.Name {
    /// Posted by StopLightEffectsIntent. AppRootView answers by stopping
    /// every running app-driven effect through the shared registry
    /// (requestNowPlayingStop) — the sanctioned non-Studio stop path that
    /// tears down the owning engine loop AND keeps Studio's mirror in sync.
    static let siriStopAllEffects = Notification.Name("castchroma.siriStopAllEffects")
}

struct StopLightEffectsIntent: AppIntent {

    static var title: LocalizedStringResource = "Stop Light Effects"
    static var description = IntentDescription(
        "Stop running light effects and scenes. Lights stay on at their current state.",
        categoryName: "Lights"
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // App-driven work (compositions, strobe/party/…): only exists if the
        // app process is alive and foregrounded — a background intent launch
        // has nothing running, so this post is a harmless no-op there.
        await MainActor.run {
            NotificationCenter.default.post(name: .siriStopAllEffects, object: nil)
        }

        // Bridge-native effects (candle/fire/…) persist after app death by
        // design — kill them from here. Per-group failures are tolerated:
        // some firmware 400s no_effect when nothing is running.
        let store = WidgetDataStore.shared
        _ = await Self.fanOut(to: Self.dedupedWholeHomeTargets(store.groups),
                              store: store) { glId, creds in
            try await HueIntentAPIClient.stopNativeEffects(id: glId, ip: creds.ip, token: creds.token)
        }
        return .result(dialog: "Stopped light effects.")
    }
}

// MARK: - Fan-out helper

extension AppIntent {
    /// Whole-home target selection. `store.groups` is rooms PLUS zones, and a
    /// zone's member lights usually belong to rooms too — writing both fires
    /// two concurrent PUTs at the shared lights. Prefer rooms; zones only for
    /// zone-only setups. Trade-off (deliberate): a light that sits in a zone
    /// but is assigned to NO room is skipped by whole-home operations — the
    /// official Hue app pushes every light into a room, so this is rare.
    static func dedupedWholeHomeTargets(_ groups: [WidgetRoomSnapshot]) -> [WidgetRoomSnapshot] {
        let rooms = groups.filter { !$0.isZone }
        return rooms.isEmpty ? groups : rooms
    }

    /// Write to many groups, collecting per-group outcomes for honest
    /// partial-failure dialogs. Groups with no grouped light or no
    /// credentials count as failures (named, never silent).
    ///
    /// Pacing: bridges run concurrently, but each bridge's groups are written
    /// SEQUENTIALLY with a 150ms gap (the sendPerLightBatched constant) — a
    /// whole-home utterance on a many-room home must not burst past the
    /// bridge's ~10 cmd/s grouped-light budget. 10 rooms ≈ 1.5s, comfortably
    /// inside the background-intent window.
    static func fanOut(
        to targets: [WidgetRoomSnapshot],
        store: WidgetDataStore,
        _ write: @escaping @Sendable (String, WidgetBridgeCredentials) async throws -> Void
    ) async -> [(name: String, ok: Bool)] {
        // Resolve credentials up front (same trust rule as before).
        // Tuple, not a nested struct — types can't nest in a generic context.
        typealias Job = (name: String, glId: String?, creds: WidgetBridgeCredentials?, bridgeKey: String)
        let jobs: [Job] = targets.map { t in
            (name: t.name, glId: t.groupedLightId,
             creds: store.credentials(for: t.bridgeID),
             bridgeKey: t.bridgeID ?? "")
        }
        let byBridge = Dictionary(grouping: jobs, by: { $0.bridgeKey })

        return await withTaskGroup(of: [(String, Bool)].self) { tasks in
            for (_, bridgeJobs) in byBridge {
                tasks.addTask {
                    var results: [(String, Bool)] = []
                    var sentAny = false
                    for job in bridgeJobs {
                        guard let glId = job.glId, let creds = job.creds else {
                            results.append((job.name, false))
                            continue
                        }
                        if sentAny { try? await Task.sleep(for: .milliseconds(150)) }
                        sentAny = true
                        do { try await write(glId, creds); results.append((job.name, true)) }
                        catch { results.append((job.name, false)) }
                    }
                    return results
                }
            }
            var results: [(name: String, ok: Bool)] = []
            for await chunk in tasks {
                results.append(contentsOf: chunk.map { (name: $0.0, ok: $0.1) })
            }
            return results
        }
    }
}

// MARK: - IntentError

enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case noBridgeConnection
    case noGroupedLight(String)
    case bridgeUnreachable(String)
    case staleSnapshot
    case unknownEntity(String)
    case partialFailure(String, [String])

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noBridgeConnection:
            return "ChromaGlow couldn't reach your bridge. Open the app and try again."
        case .noGroupedLight(let name):
            return "Couldn't find light controls for \(name). Open ChromaGlow to refresh."
        case .bridgeUnreachable(let name):
            return "ChromaGlow couldn't reach the bridge for \(name). Check that you're on your home Wi-Fi."
        case .staleSnapshot:
            return "ChromaGlow's light list may be out of date — open the app to refresh."
        case .unknownEntity(let kind):
            return "That \(kind) no longer exists. Open ChromaGlow to see what's available."
        case .partialFailure(let operation, let failedNames):
            return "\(operation) mostly worked, but \(failedNames.joined(separator: ", ")) didn't respond."
        }
    }
}

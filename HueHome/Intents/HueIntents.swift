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

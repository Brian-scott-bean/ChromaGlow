// ToggleRoomIntent.swift
// CastChroma — Siri Shortcuts
//
// "Hey Siri, turn on Living Room in CastChroma"
// "Hey Siri, turn off Kitchen in CastChroma"

import AppIntents

struct ToggleRoomIntent: AppIntent {

    static var title: LocalizedStringResource = "Toggle Room Lights"
    static var description = IntentDescription(
        "Turn a room's lights on or off.",
        categoryName: "Lights"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Room")
    var room: HueRoomEntity

    @Parameter(title: "Turn On", default: true)
    var turnOn: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let ip    = WidgetDataStore.shared.bridgeIP,
              let token = WidgetDataStore.shared.token else {
            throw IntentError.noBridgeConnection
        }
        guard let glId = room.groupedLightId else {
            throw IntentError.noGroupedLight(room.name)
        }
        try await HueIntentAPIClient.setGroupedLight(id: glId, on: turnOn, ip: ip, token: token)
        let state = turnOn ? "on" : "off"
        return .result(dialog: "\(room.name) is now \(state).")
    }
}

// MARK: - SetBrightnessIntent

struct SetBrightnessIntent: AppIntent {

    static var title: LocalizedStringResource = "Set Room Brightness"
    static var description = IntentDescription(
        "Set the brightness of a room's lights.",
        categoryName: "Lights"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Room")
    var room: HueRoomEntity

    @Parameter(title: "Brightness", default: 80,
               inclusiveRange: (lowerBound: 1, upperBound: 100))
    var brightness: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let ip    = WidgetDataStore.shared.bridgeIP,
              let token = WidgetDataStore.shared.token else {
            throw IntentError.noBridgeConnection
        }
        guard let glId = room.groupedLightId else {
            throw IntentError.noGroupedLight(room.name)
        }
        try await HueIntentAPIClient.setGroupedLight(
            id: glId, brightness: Double(brightness), ip: ip, token: token
        )
        return .result(dialog: "\(room.name) brightness set to \(brightness)%.")
    }
}

// MARK: - IntentError

enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case noBridgeConnection
    case noGroupedLight(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noBridgeConnection:
            return "CastChroma couldn't reach your bridge. Open the app and try again."
        case .noGroupedLight(let name):
            return "Couldn't find light controls for \(name). Open CastChroma to refresh."
        }
    }
}

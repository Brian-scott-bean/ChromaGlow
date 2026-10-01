// Composer2LiveGateway.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The few orchestrator calls the playback center makes, behind a protocol
// so the lifecycle is testable with a fake. The production adapter reuses
// the existing composition start/stop, the attended start (which owns the
// third-party question), availability, cache accessors and the Now Playing
// registry — it invents no transport of its own.

import Foundation

enum Composer2LiveGate: Equatable {
    case ready
    case demo
    case noRoom
    case noBridge
}

enum Composer2PlayMode: Equatable {
    case streaming
    case roomMode

    var statusText: String {
        switch self {
        case .streaming: return Composer2Copy.liveStreaming
        case .roomMode: return Composer2Copy.liveRoomMode
        }
    }
}

enum Composer2StartOutcome: Equatable {
    case started(Composer2PlayMode)
    /// Another controller owns the lights and the user was not asked (a
    /// controller that appeared mid-start); nothing was mutated.
    case foreignController
    /// The user chose to keep the other app's show; nothing was mutated.
    case declined
    case failed(String)
}

struct Composer2StreamAvailability: Equatable {
    var prefer: Bool
    var severalAreas: Bool
}

/// What a room's lights looked like just before Go Live, so stopping the
/// look puts the room back (device round, build 58: Stop used to leave the
/// lights on the look's last frame — a storm-blue bathroom at 15 %).
struct Composer2RoomSnapshot: Equatable {
    struct Light: Equatable {
        let id: String
        let on: Bool
        let brightness: Double?
        /// Exactly one of xy / mirek, whichever mode the light was in.
        let x: Double?
        let y: Double?
        let mirek: Int?
    }
    let roomID: String
    let bridgeID: String?
    let lights: [Light]
}

extension Composer2RoomSnapshot.Light {
    /// The light as the bridge reported it: white-temperature mode when its
    /// mirek is current (`mirek_valid`), colour mode otherwise.
    init(_ light: HueLight) {
        let ct = light.color_temperature
        let inTemperature = ct?.mirek_valid == true && ct?.mirek != nil
        self.init(id: light.id,
                  on: light.on.on,
                  brightness: light.dimming?.brightness,
                  x: inTemperature ? nil : light.color?.xy.x,
                  y: inTemperature ? nil : light.color?.xy.y,
                  mirek: inTemperature ? ct?.mirek : nil)
    }
}

@MainActor
protocol Composer2LiveGateway: AnyObject {
    func gate(for room: RoomDisplayItem?) -> Composer2LiveGate
    func streamAvailability(for room: RoomDisplayItem) -> Composer2StreamAvailability
    func warm(room: RoomDisplayItem) async
    func streamingLayout(room: RoomDisplayItem, lights: [LightDisplayItem]) -> Composer2SlotLayout?
    func roomLayout(room: RoomDisplayItem, lights: [LightDisplayItem]) -> Composer2SlotLayout
    func lightItems(room: RoomDisplayItem) -> [LightDisplayItem]
    func rooms() -> [RoomDisplayItem]
    func isDemo() -> Bool
    /// Attended start: `askTakeover` is presented as a prompt and answered by a tap.
    func start(room: RoomDisplayItem, box: CompositionParamBox, preferStreaming: Bool,
               askTakeover: @escaping @MainActor () async -> Bool) async -> Composer2StartOutcome
    func stop(roomID: String, bridgeID: String?) async
    /// Exact bridge+room: does any composition claim this room right now?
    func isRoomClaimed(roomID: String, bridgeID: String?) -> Bool
    /// Is the orchestrator still rendering THIS box? A replacement look keeps
    /// the room claimed; only box identity tells the two apart.
    func isDriving(box: CompositionParamBox) -> Bool
    /// The transport the room's composition runs on now (it changes when a
    /// stream fails over to Room mode).
    func transport(roomID: String, bridgeID: String?) -> Composer2PlayMode?
    /// Now Playing registry: the row the Dashboard shows and can stop.
    func publishNowPlaying(roomID: String, bridgeID: String?, roomName: String,
                           groupedLightID: String?, compositionName: String)
    /// Removes the row only while it is still Composer 2's own — a look that
    /// replaced ours publishes under the same key, and its row must survive.
    func retireNowPlaying(roomID: String, bridgeID: String?)
    /// Installs (or clears) the stop route Dashboard taps reach before Studio's.
    func installStopHandler(_ handler: (@MainActor (_ bridgeID: String?, _ roomID: String) async -> Bool)?)
    /// Names of the room's lights the bridge said it could not reach on
    /// their last command (off at the wall, out of range).
    func unresponsiveLightNames(roomID: String, bridgeID: String?) -> [String]
    /// The room's lights as the bridge has them now — read fresh, just
    /// before Go Live changes them. nil when it cannot be read.
    func captureRoomState(room: RoomDisplayItem) async -> Composer2RoomSnapshot?
    /// Put a room's lights back as captured, paced on the bridge's budget.
    func restoreRoomState(_ snapshot: Composer2RoomSnapshot) async
}

extension Composer2LiveGateway {
    func unresponsiveLightNames(roomID: String, bridgeID: String?) -> [String] { [] }
    func captureRoomState(room: RoomDisplayItem) async -> Composer2RoomSnapshot? { nil }
    func restoreRoomState(_ snapshot: Composer2RoomSnapshot) async {}
}

// MARK: - Production adapter

@MainActor
final class Composer2OrchestratorGateway: Composer2LiveGateway {
    private let orchestrator: UnifiedOrchestrator

    init(orchestrator: UnifiedOrchestrator) {
        self.orchestrator = orchestrator
    }

    func gate(for room: RoomDisplayItem?) -> Composer2LiveGate {
        if orchestrator.isDemoMode { return .demo }
        guard let room else { return .noRoom }
        guard room.bridgeID != nil, room.groupedLightID != nil,
              orchestrator.hueClient(for: room.bridgeID) != nil else { return .noBridge }
        return .ready
    }

    func streamAvailability(for room: RoomDisplayItem) -> Composer2StreamAvailability {
        let availability = orchestrator.entertainmentAvailability(for: room)
        var several = false
        if case .choiceRequired = availability { several = true }
        return Composer2StreamAvailability(prefer: availability.canStream, severalAreas: several)
    }

    func warm(room: RoomDisplayItem) async {
        guard !orchestrator.isDemoMode else { return }
        await orchestrator.warmEntertainmentCaches(for: room, force: false)
    }

    func streamingLayout(room: RoomDisplayItem, lights: [LightDisplayItem]) -> Composer2SlotLayout? {
        guard let bridgeID = room.bridgeID,
              let config = orchestrator.selectedEntertainmentConfig(for: room),
              let membership = orchestrator.entertainmentMembershipByBridge[bridgeID] else { return nil }
        let layout = Composer2SlotLayout.streaming(config: config, membership: membership, lights: lights)
        return layout.isEmpty ? nil : layout
    }

    func roomLayout(room: RoomDisplayItem, lights: [LightDisplayItem]) -> Composer2SlotLayout {
        let raw = orchestrator.cachedRawLights(for: room.bridgeID) ?? []
        let layout = Composer2SlotLayout.roomMode(room: room, rawLights: raw, lights: lights)
        return layout.isEmpty ? Composer2SlotLayout.estimated(lights: lights) : layout
    }

    func lightItems(room: RoomDisplayItem) -> [LightDisplayItem] {
        if orchestrator.isDemoMode { return DemoDataProvider.lights(for: room.id) }
        return orchestrator.cachedLightItems(for: room)
    }

    func captureRoomState(room: RoomDisplayItem) async -> Composer2RoomSnapshot? {
        guard !orchestrator.isDemoMode, let api = orchestrator.hueClient(for: room.bridgeID) else { return nil }
        let ids = Set(lightItems(room: room).map(\.id))
        guard !ids.isEmpty, let all = try? await api.fetchLights() else { return nil }
        let lights = all.filter { ids.contains($0.id) }.map(Composer2RoomSnapshot.Light.init)
        return lights.isEmpty ? nil : Composer2RoomSnapshot(roomID: room.id, bridgeID: room.bridgeID, lights: lights)
    }

    func restoreRoomState(_ snapshot: Composer2RoomSnapshot) async {
        guard !orchestrator.isDemoMode, let api = orchestrator.hueClient(for: snapshot.bridgeID) else { return }
        let gate = orchestrator.commandGate(for: snapshot.bridgeID)
        // A batch dispatched just before the stop may still be in flight;
        // let it land so it cannot overwrite the restore.
        try? await Task.sleep(for: .milliseconds(300))
        for light in snapshot.lights {
            let xy: (Double, Double)? = light.x.flatMap { x in light.y.map { (x, $0) } }
            await gate.send {
                if light.on {
                    try await api.setLightEffect(id: light.id, on: true, brightness: light.brightness,
                                                 xy: xy, mirek: light.mirek, duration: 400)
                } else {
                    try await api.setLightEffect(id: light.id, on: false, brightness: nil,
                                                 xy: nil, mirek: nil, duration: 400)
                }
            }
        }
    }

    func unresponsiveLightNames(roomID: String, bridgeID: String?) -> [String] {
        let ids = orchestrator.unresponsiveLightIDs
        guard !ids.isEmpty, !orchestrator.isDemoMode,
              let room = rooms().first(where: { $0.id == roomID && $0.bridgeID == bridgeID })
        else { return [] }
        return lightItems(room: room).filter { ids.contains($0.id) }.map(\.name).sorted()
    }

    func rooms() -> [RoomDisplayItem] {
        orchestrator.allRooms + orchestrator.allZones
    }

    func isDemo() -> Bool { orchestrator.isDemoMode }

    func start(room: RoomDisplayItem, box: CompositionParamBox, preferStreaming: Bool,
               askTakeover: @escaping @MainActor () async -> Bool) async -> Composer2StartOutcome {
        let outcome = await orchestrator.startCompositionModeAttended(
            room: room, paramBox: box, preferEntertainment: preferStreaming, askTakeover: askTakeover)
        switch outcome {
        case .started(.entertainment):
            return .started(.streaming)
        case .started(.rest):
            return .started(.roomMode)
        case .started(.bridgeStored), .started(.oneShot):
            // Cannot happen for a runtime-only start; never leave a claim standing.
            await orchestrator.stopCompositionMode(roomID: room.id, bridgeID: room.bridgeID)
            return .failed(EntertainmentAvailabilityCopy.couldNotStart)
        case .needsForeignConsent:
            return .foreignController
        case .failed(let message):
            return message == EntertainmentConsentCopy.takeoverDeclined ? .declined : .failed(message)
        }
    }

    func stop(roomID: String, bridgeID: String?) async {
        await orchestrator.stopCompositionMode(roomID: roomID, bridgeID: bridgeID)
    }

    func isRoomClaimed(roomID: String, bridgeID: String?) -> Bool {
        orchestrator.compositionTransport(bridgeID: bridgeID, roomID: roomID) != nil
    }

    func isDriving(box: CompositionParamBox) -> Bool {
        orchestrator.isDrivingComposition(box: box)
    }

    func transport(roomID: String, bridgeID: String?) -> Composer2PlayMode? {
        switch orchestrator.compositionTransport(bridgeID: bridgeID, roomID: roomID) {
        case .entertainment: return .streaming
        case .rest: return .roomMode
        case .bridgeStored, .none: return nil
        }
    }

    func publishNowPlaying(roomID: String, bridgeID: String?, roomName: String,
                           groupedLightID: String?, compositionName: String) {
        orchestrator.addActiveEffect(ActiveEffectEntry(
            liveBridgeID: bridgeID, roomID: roomID, roomName: roomName,
            groupedLightID: groupedLightID, effectID: Composer2OrchestratorGateway.nowPlayingEffectID,
            effectName: compositionName, effectIcon: "sparkles", isAppDriven: true))
    }

    func retireNowPlaying(roomID: String, bridgeID: String?) {
        orchestrator.removeActiveEffect(bridgeID: bridgeID, roomID: roomID,
                                        onlyEffectID: Composer2OrchestratorGateway.nowPlayingEffectID)
    }

    static let nowPlayingEffectID = "composer2"

    func installStopHandler(_ handler: (@MainActor (_ bridgeID: String?, _ roomID: String) async -> Bool)?) {
        if let handler {
            orchestrator.composer2StopHandler = { target in
                await handler(target.bridgeID, target.roomID)
            }
        } else {
            orchestrator.composer2StopHandler = nil
        }
    }
}

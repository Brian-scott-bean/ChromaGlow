// BridgeAnimationEngine.swift
// ChromaGlow — Bridge-Stored Animations
//
// Pre-renders CompositionEngine output at N time points, uploads each
// frame as a v1 scene, then chains them with rules + a recurring timer.
// The bridge loops through the scenes autonomously — app can be closed.
//
// Architecture:
//   1. Render N frames from CompositionEngine (up to 8)
//   2. Create a v1 scene per frame (per-light xy + brightness + transitiontime)
//   3. Create a CLIP sensor (step counter: 0 → N-1 → 0)
//   4. Create N rules: "sensor == step → activate scene, bump sensor"
//   5. Create 1 recurring schedule: "Every T seconds → bump sensor"
//   6. Group everything in a resourcelink for cleanup

import Foundation
import OSLog

// MARK: - BridgeAnimationManifest

/// All v1 resource IDs created for a single bridge-stored animation.
/// Persisted to disk so we can find and clean up bridge resources later.
struct BridgeAnimationManifest: Codable, Identifiable {
    let id: UUID
    let presetID: UUID
    let presetName: String
    let roomID: String
    let roomName: String
    let bridgeIP: String

    // v1 resource IDs
    let sensorID: String
    let ruleIDs: [String]
    let scheduleID: String
    let sceneIDs: [String]
    let resourcelinkID: String?  // may fail to create, non-critical

    let stepCount: Int
    let intervalSeconds: Int
    let cycleDurationSeconds: Double
    let createdAt: Date

    /// Composite key for lookup
    var key: String { "\(presetID.uuidString)_\(roomID)" }
}

// MARK: - BridgeAnimationError

enum BridgeAnimationError: LocalizedError {
    case bridgeFull(BridgeResourceCapacity)
    case noLightsResolved
    case noGroupFound
    case presetRequiresMic
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .bridgeFull(let cap):
            return "Bridge is near capacity: \(cap.rulesAvailable) rules, \(cap.scenesAvailable) scenes available."
        case .noLightsResolved:
            return "No lights found for this room."
        case .noGroupFound:
            return "Could not find a v1 group matching this room."
        case .presetRequiresMic:
            return "Mic-reactive presets can't run on the bridge."
        case .uploadFailed(let reason):
            return "Upload failed: \(reason)"
        }
    }
}

// MARK: - BridgeAnimationEngine

actor BridgeAnimationEngine {
    private let log = Logger(subsystem: "com.chromaglow.app", category: "BridgeAnim")

    /// Maximum steps per animation (matches iConnectHue's limit).
    /// Keeps bridge resource usage bounded.
    static let maxSteps = 8

    /// Upload a composition preset as a bridge-stored animation.
    ///
    /// Pre-renders the composition at evenly-spaced time points,
    /// creates a v1 scene for each frame, then chains them with
    /// rules and a recurring timer.
    ///
    /// - Returns: A manifest containing all created resource IDs.
    func upload(
        preset: CompositionPreset,
        room: RoomDisplayItem,
        lightIDs: [String],
        gamut: HueColorUtils.Gamut,
        v1Client: HueV1Client
    ) async throws -> BridgeAnimationManifest {
        guard !lightIDs.isEmpty else {
            throw BridgeAnimationError.noLightsResolved
        }
        guard !preset.reaction.requiresMic else {
            throw BridgeAnimationError.presetRequiresMic
        }

        // ─── 0. Check bridge capacity ───
        let capacity = try await v1Client.fetchResourceCapacity()
        guard capacity.canFitOneAnimation else {
            throw BridgeAnimationError.bridgeFull(capacity)
        }

        // ─── 1. Calculate cycle timing ───
        let stepCount = calculateStepCount(for: preset)
        let cycleDuration = calculateCycleDuration(for: preset)
        let stepInterval = max(3, Int(cycleDuration / Double(stepCount)))  // min 3 seconds between steps
        // Transition time between steps (in deciseconds for v1 API)
        // Use ~80% of step interval for smooth overlap
        let transitionDeciSeconds = max(10, Int(Double(stepInterval) * 8.0))

        log.info("[BridgeAnim] Upload '\(preset.name)' → \(stepCount) steps, \(stepInterval)s/step, cycle=\(cycleDuration)s")

        // ─── 2. Pre-render frames ───
        let paramBox = CompositionParamBox(preset: preset)
        let channelIDs: [UInt8] = (0..<UInt8(min(lightIDs.count, 20))).map { $0 }
        var renderedFrames: [[LightFrame]] = []

        for step in 0..<stepCount {
            let time = Double(step) / Double(stepCount) * cycleDuration
            let frames = CompositionEngine.render(
                time: time,
                channelIDs: channelIDs,
                params: paramBox,
                audioLevel: 0  // no mic on bridge
            )
            renderedFrames.append(frames)
        }

        log.info("[BridgeAnim] Rendered \(renderedFrames.count) frames, \(channelIDs.count) channels each")

        // ─── 3. Find v1 group ID ───
        let groupID = try await v1Client.findGroupID(containingLights: lightIDs)
        log.info("[BridgeAnim] Using v1 group ID: \(groupID)")

        // ─── 4. Create v1 scenes ───
        var sceneIDs: [String] = []
        for (stepIndex, frames) in renderedFrames.enumerated() {
            var lightstates: [String: [String: Any]] = [:]
            for (lightIndex, lightID) in lightIDs.enumerated() {
                guard lightIndex < frames.count else { continue }
                let frame = frames[lightIndex]
                let xy = HueColorUtils.clampXYToGamut(x: frame.x, y: frame.y, gamut: gamut)
                let bri = max(1, min(254, Int(frame.brightness * 254.0)))

                lightstates[lightID] = [
                    "on": true,
                    "bri": bri,
                    "xy": [xy.x, xy.y],
                    "transitiontime": transitionDeciSeconds
                ]
            }
            let sceneName = "CG_\(String(preset.name.prefix(12)))_\(stepIndex)"
            let sceneID = try await v1Client.createScene(
                name: sceneName,
                lightIDs: lightIDs,
                lightstates: lightstates
            )
            sceneIDs.append(sceneID)
            log.info("[BridgeAnim] Created scene \(stepIndex): \(sceneID)")

            // Brief pause between scene creates to avoid overwhelming bridge
            try? await Task.sleep(for: .milliseconds(100))
        }

        // ─── 5. Create CLIP sensor (step counter) ───
        let sensorName = "CG_\(String(preset.name.prefix(16)))_ctr"
        let sensorID = try await v1Client.createCLIPSensor(
            name: sensorName,
            initialStatus: 0
        )
        log.info("[BridgeAnim] Created sensor: \(sensorID)")

        // ─── 6. Create rules (one per step) ───
        var ruleIDs: [String] = []
        for step in 0..<stepCount {
            let nextStep = (step + 1) % stepCount
            let ruleName = "CG_\(String(preset.name.prefix(10)))_s\(step)"

            let conditions: [[String: Any]] = [
                [
                    "address": "/sensors/\(sensorID)/state/status",
                    "operator": "eq",
                    "value": "\(step)"
                ],
                // dx condition ensures rule fires on state change, not just static match
                [
                    "address": "/sensors/\(sensorID)/state/lastupdated",
                    "operator": "dx"
                ]
            ]

            let actions: [[String: Any]] = [
                // Activate the scene for this step
                v1Client.sceneActivationCommand(groupID: groupID, sceneID: sceneIDs[step]),
                // Advance the counter to the next step
                v1Client.sensorIncrementCommand(sensorID: sensorID, nextStatus: nextStep)
            ]

            let ruleID = try await v1Client.createRule(
                name: ruleName,
                conditions: conditions,
                actions: actions
            )
            ruleIDs.append(ruleID)
            log.info("[BridgeAnim] Created rule \(step): \(ruleID)")

            try? await Task.sleep(for: .milliseconds(80))
        }

        // ─── 7. Create recurring schedule ───
        // The schedule bumps the sensor status every T seconds,
        // which triggers the matching rule → activates scene → bumps again.
        let scheduleName = "CG_\(String(preset.name.prefix(14)))_tmr"
        let scheduleCommand = v1Client.sensorIncrementCommand(
            sensorID: sensorID,
            nextStatus: 1  // kick off from step 0 → 1
        )
        let scheduleID = try await v1Client.createRecurringSchedule(
            name: scheduleName,
            intervalSeconds: stepInterval,
            command: scheduleCommand
        )
        log.info("[BridgeAnim] Created schedule: \(scheduleID) (every \(stepInterval)s)")

        // ─── 8. Group in resourcelink ───
        var allLinks: [String] = []
        allLinks.append("/sensors/\(sensorID)")
        allLinks.append("/schedules/\(scheduleID)")
        for ruleID in ruleIDs { allLinks.append("/rules/\(ruleID)") }
        for sceneID in sceneIDs { allLinks.append("/scenes/\(sceneID)") }

        let resourcelinkID: String?
        do {
            let rlName = "CG_\(String(preset.name.prefix(16)))"
            resourcelinkID = try await v1Client.createResourcelink(
                name: rlName,
                description: "ChromaGlow animation: \(preset.name)",
                links: allLinks
            )
            log.info("[BridgeAnim] Created resourcelink: \(resourcelinkID ?? "nil")")
        } catch {
            log.warning("[BridgeAnim] Resourcelink creation failed (non-critical): \(error.localizedDescription)")
            resourcelinkID = nil
        }

        // ─── 9. Kick off: set sensor to 0 to trigger first rule ───
        try await v1Client.setSensorStatus(id: sensorID, status: 0)
        log.info("[BridgeAnim] ⚡ Animation started on bridge!")

        let manifest = BridgeAnimationManifest(
            id: UUID(),
            presetID: preset.id,
            presetName: preset.name,
            roomID: room.id,
            roomName: room.name,
            bridgeIP: v1Client.bridgeIP,
            sensorID: sensorID,
            ruleIDs: ruleIDs,
            scheduleID: scheduleID,
            sceneIDs: sceneIDs,
            resourcelinkID: resourcelinkID,
            stepCount: stepCount,
            intervalSeconds: stepInterval,
            cycleDurationSeconds: cycleDuration,
            createdAt: Date()
        )

        return manifest
    }

    /// Stop a bridge-stored animation and clean up ALL resources.
    func stop(manifest: BridgeAnimationManifest, v1Client: HueV1Client) async {
        log.info("[BridgeAnim] Stopping animation '\(manifest.presetName)' on '\(manifest.roomName)'")

        // Delete in reverse order of dependency:
        // 1. Schedule (stops the timer)
        do { try await v1Client.deleteSchedule(id: manifest.scheduleID) }
        catch { log.warning("[BridgeAnim] Failed to delete schedule \(manifest.scheduleID): \(error.localizedDescription)") }

        // 2. Rules (stops the chain)
        for ruleID in manifest.ruleIDs {
            do { try await v1Client.deleteRule(id: ruleID) }
            catch { log.warning("[BridgeAnim] Failed to delete rule \(ruleID): \(error.localizedDescription)") }
        }

        // 3. Sensor (removes the counter)
        do { try await v1Client.deleteSensor(id: manifest.sensorID) }
        catch { log.warning("[BridgeAnim] Failed to delete sensor \(manifest.sensorID): \(error.localizedDescription)") }

        // 4. Scenes (removes the stored states)
        for sceneID in manifest.sceneIDs {
            do { try await v1Client.deleteScene(id: sceneID) }
            catch { log.warning("[BridgeAnim] Failed to delete scene \(sceneID): \(error.localizedDescription)") }
        }

        // 5. Resourcelink (removes the grouping)
        if let rlID = manifest.resourcelinkID {
            do { try await v1Client.deleteResourcelink(id: rlID) }
            catch { log.warning("[BridgeAnim] Failed to delete resourcelink \(rlID): \(error.localizedDescription)") }
        }

        log.info("[BridgeAnim] ✅ Cleanup complete for '\(manifest.presetName)'")
    }

    // MARK: - Timing Calculation

    /// How many steps to pre-render for this preset.
    /// More dynamic presets get more steps for smoother approximation.
    private func calculateStepCount(for preset: CompositionPreset) -> Int {
        switch preset.motion.pattern {
        case .static:
            // Static preset with envelope modulation — fewer steps needed
            switch preset.envelope.shape {
            case .steady: return 2   // just 2 alternating states
            case .breathe: return 6  // smooth sine needs more points
            case .heartbeat: return 8 // complex shape
            case .pulse: return 4    // on/off
            case .flicker: return 8  // organic noise
            case .swell: return 6    // asymmetric rise/fall
            }
        case .cascade, .wave, .bounce:
            return Self.maxSteps  // motion patterns need full 8 steps
        case .scatter:
            return 6  // pseudo-random, more steps for variety
        }
    }

    /// Full cycle duration in seconds for one complete loop.
    private func calculateCycleDuration(for preset: CompositionPreset) -> Double {
        // Envelope-based cycle time (from BPM)
        let envelopePeriod = 60.0 / max(1, preset.envelope.bpm)

        // Motion-based cycle time (from speed)
        let motionPeriod = 20.0 - (preset.motion.speed / 100.0) * 19.5

        switch preset.motion.pattern {
        case .static:
            // Use envelope period, clamped to bridge-friendly range (8-60 seconds)
            return max(8, min(60, envelopePeriod * 2))  // 2 full cycles
        default:
            // Use motion period, clamped
            return max(16, min(120, motionPeriod * 2))
        }
    }
}



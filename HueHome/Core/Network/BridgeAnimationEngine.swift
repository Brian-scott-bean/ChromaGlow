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
        v2Lights: [HueLight],
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
                params: paramBox   // no mic/beat on bridge — defaults are silent
            )
            renderedFrames.append(frames)
        }

        log.info("[BridgeAnim] Rendered \(renderedFrames.count) frames, \(channelIDs.count) channels each")

        // ─── 3. Resolve v1 light IDs ───
        // v2 API uses UUID light IDs; v1 uses numeric IDs ("1", "2", "3").
        // Mapped by id_v1 IDENTITY (M-04) so v1LightIDs[i] is the same bulb as
        // lightIDs[i] — per-light palette colors are positional downstream.
        let v1LightIDs: [String]
        do {
            v1LightIDs = try v1Client.resolveV1LightIDs(from: lightIDs, v2Lights: v2Lights)
            log.info("[BridgeAnim] Resolved v1 light IDs: \(v1LightIDs)")
        } catch {
            log.error("[BridgeAnim] Failed to resolve v1 light IDs: \(error.localizedDescription)")
            throw BridgeAnimationError.noLightsResolved
        }
        guard !v1LightIDs.isEmpty else {
            throw BridgeAnimationError.noLightsResolved
        }

        // ─── 4. Pre-compute per-step light states ───
        // We'll embed these directly in rule actions (no scene activation).
        // v1 rules support PUT /lights/{id}/state which is more reliable
        // than scene activation via /groups/{id}/action.
        var perStepLightStates: [[[String: Any]]] = []  // [step][lightIndex] -> state dict
        for frames in renderedFrames {
            var stepStates: [[String: Any]] = []
            for (lightIndex, _) in v1LightIDs.enumerated() {
                guard lightIndex < frames.count else { continue }
                let frame = frames[lightIndex]
                let xy = HueColorUtils.clampXYToGamut(x: frame.x, y: frame.y, gamut: gamut)
                let bri = max(1, min(254, Int(frame.brightness * 254.0)))
                stepStates.append([
                    "on": true,
                    "bri": bri,
                    "xy": [xy.x, xy.y],
                    "transitiontime": transitionDeciSeconds
                ])
            }
            perStepLightStates.append(stepStates)
        }
        log.info("[BridgeAnim] Pre-computed \(perStepLightStates.count) step states for \(v1LightIDs.count) lights")

        // ─── 5. Create CLIP sensor (step counter) ───
        let sensorName = "CG_\(String(preset.name.prefix(16)))_ctr"
        let sensorID = try await v1Client.createCLIPSensor(
            name: sensorName,
            initialStatus: 99  // Start at 99 so first set→0 triggers dx
        )
        log.info("[BridgeAnim] Created sensor: \(sensorID)")

        // ─── 6. Create rules (chunked per step, M-05) ───
        // Each rule sets individual light states directly — no scene activation.
        // This avoids the error 608 from scene recall on groups.
        //
        // CHAIN: schedule sets sensor→0 → step-0 rules fire → set lights + advance to 1
        //   → step-1 rules fire → ... → last step's rules WAIT
        //   → schedule fires again → sets sensor→0 → repeat
        //
        // The v1 API hard-caps a rule at 8 actions. A step with N lights needs
        // N light PUTs + 1 sensor advance, so any 8+ light room used to abort
        // the whole upload. Fix: chunk each step into rules of ≤7 light
        // actions sharing the SAME trigger condition — the bridge fires every
        // matching rule on the sensor tick — and put the sensor-advance action
        // only on the last chunk. Action count is validated before POSTing.
        let maxLightActionsPerRule = 7   // 8-action limit minus the sensor advance
        var ruleIDs: [String] = []
        let sceneIDs: [String] = []  // No scenes created — using direct light states

        for step in 0..<stepCount {
            let nextStep = (step + 1) % stepCount

            let conditions: [[String: Any]] = [
                [
                    "address": "/sensors/\(sensorID)/state/status",
                    "operator": "eq",
                    "value": "\(step)"
                ],
                [
                    "address": "/sensors/\(sensorID)/state/lastupdated",
                    "operator": "dx"
                ]
            ]

            // Build actions: one PUT per light
            var lightActions: [[String: Any]] = []
            let stepStates = perStepLightStates[step]
            for (lightIndex, v1LightID) in v1LightIDs.enumerated() {
                guard lightIndex < stepStates.count else { continue }
                lightActions.append([
                    "address": "/lights/\(v1LightID)/state",  // RELATIVE — bridge resolves user internally
                    "method": "PUT",
                    "body": stepStates[lightIndex]
                ])
            }

            let chunks: [[[String: Any]]] = stride(from: 0, to: max(lightActions.count, 1), by: maxLightActionsPerRule).map {
                Array(lightActions[$0..<min($0 + maxLightActionsPerRule, lightActions.count)])
            }

            for (chunkIndex, chunk) in chunks.enumerated() {
                var actions = chunk
                // Advance sensor on the LAST chunk only (except final step — waits for schedule)
                let isLastChunk = chunkIndex == chunks.count - 1
                if isLastChunk, step < stepCount - 1 {
                    actions.append(
                        v1Client.sensorIncrementCommand(sensorID: sensorID, nextStatus: nextStep)
                    )
                }
                guard actions.count <= 8, !actions.isEmpty else {
                    throw BridgeAnimationError.uploadFailed(
                        "rule for step \(step) chunk \(chunkIndex) has \(actions.count) actions (v1 max 8)")
                }

                let chunkSuffix = chunks.count > 1 ? "c\(chunkIndex)" : ""
                let ruleName = "CG_\(String(preset.name.prefix(10)))_s\(step)\(chunkSuffix)"
                do {
                    let ruleID = try await v1Client.createRule(
                        name: ruleName,
                        conditions: conditions,
                        actions: actions
                    )
                    ruleIDs.append(ruleID)
                    log.info("[BridgeAnim] Created rule \(step).\(chunkIndex): \(ruleID) (\(actions.count) actions) → \(isLastChunk && step < stepCount - 1 ? "advance to \(nextStep)" : "no advance")")
                } catch {
                    log.error("[BridgeAnim] ❌ Rule \(step).\(chunkIndex) creation FAILED: \(error.localizedDescription)")
                    log.error("[BridgeAnim] Rule had \(actions.count) actions for \(v1LightIDs.count) lights")
                    throw error
                }
            }

            try? await Task.sleep(for: .milliseconds(100))
        }

        // ─── 8. Create recurring schedule ───
        let cycleTotalSeconds = max(5, stepInterval * stepCount)
        let scheduleName = "CG_\(String(preset.name.prefix(14)))_tmr"
        // NOTE: Schedules require the FULL /api/{token}/... path in the command address.
        // Using sensorIncrementCommand (relative path) here causes error type:6 on creation.
        let scheduleCommand = v1Client.sensorIncrementScheduleCommand(
            sensorID: sensorID,
            nextStatus: 0  // Restart the chain at step 0
        )
        let scheduleID: String
        do {
            scheduleID = try await v1Client.createRecurringSchedule(
                name: scheduleName,
                intervalSeconds: cycleTotalSeconds,
                command: scheduleCommand
            )
            log.info("[BridgeAnim] Created schedule: \(scheduleID) (every \(cycleTotalSeconds)s)")
        } catch {
            log.error("[BridgeAnim] ❌ Schedule creation FAILED: \(error.localizedDescription)")
            throw error
        }

        // ─── 9. Group in resourcelink ───
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
            log.warning("[BridgeAnim] Resourcelink failed (non-critical): \(error.localizedDescription)")
            resourcelinkID = nil
        }

        // ─── 10. Kick off the chain ───
        // Sensor starts at 99, setting to 0 triggers dx + eq 0 → rule 0 fires → chain starts
        try await v1Client.setSensorStatus(id: sensorID, status: 0)
        log.info("[BridgeAnim] ⚡ Animation started! \(stepCount) steps, \(stepInterval)s each, \(cycleTotalSeconds)s cycle")

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
        case .cascade, .wave, .bounce, .chase, .comet, .pulseCenter, .spiral:
            return Self.maxSteps  // motion patterns need full 8 steps
        case .scatter, .twinkle:
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

    /// Nuclear cleanup: find and delete ALL ChromaGlow (CG_) resources on the bridge.
    /// Use this to clean up orphaned resources from failed/interrupted uploads.
    func purgeAllChromaGlowResources(v1Client: HueV1Client) async {
        log.info("[BridgeAnim] 🧹 Purging ALL ChromaGlow resources from bridge...")

        // Delete schedules with CG_ prefix
        if let schedules = try? await v1Client.fetchSchedules() {
            for (id, schedule) in schedules {
                if let name = schedule["name"] as? String, name.hasPrefix("CG_") {
                    try? await v1Client.deleteSchedule(id: id)
                    log.info("[BridgeAnim] 🧹 Deleted schedule \(id): \(name)")
                }
            }
        }

        // Delete rules with CG_ prefix
        if let rules = try? await v1Client.fetchRules() {
            for (id, rule) in rules {
                if let name = rule["name"] as? String, name.hasPrefix("CG_") {
                    try? await v1Client.deleteRule(id: id)
                    log.info("[BridgeAnim] 🧹 Deleted rule \(id): \(name)")
                }
            }
        }

        // Delete sensors with CG_ prefix
        if let sensors = try? await v1Client.fetchSensors() {
            for (id, sensor) in sensors {
                if let name = sensor["name"] as? String, name.hasPrefix("CG_") {
                    try? await v1Client.deleteSensor(id: id)
                    log.info("[BridgeAnim] 🧹 Deleted sensor \(id): \(name)")
                }
            }
        }

        // Delete scenes with CG_ prefix
        if let scenes = try? await v1Client.fetchScenes() {
            for (id, scene) in scenes {
                if let name = scene["name"] as? String, name.hasPrefix("CG_") {
                    try? await v1Client.deleteScene(id: id)
                    log.info("[BridgeAnim] 🧹 Deleted scene \(id): \(name)")
                }
            }
        }

        // Delete resourcelinks with CG_ prefix
        if let links = try? await v1Client.fetchResourcelinks() {
            for (id, link) in links {
                if let name = link["name"] as? String, name.hasPrefix("CG_") {
                    try? await v1Client.deleteResourcelink(id: id)
                    log.info("[BridgeAnim] 🧹 Deleted resourcelink \(id): \(name)")
                }
            }
        }

        log.info("[BridgeAnim] 🧹 Purge complete")
    }

    // ──────────────────────────────────────────────
    // MARK: - V2 Dynamic Scene (Option B)
    // ──────────────────────────────────────────────

    /// Upload a composition as a v2 dynamic palette scene.
    ///
    /// This is the "zero-overhead" path: creates a single v2 scene with
    /// multiple color palette entries, then recalls it with `dynamic_palette`.
    /// The bridge firmware handles cycling through colors autonomously.
    /// No rules, sensors, or schedules are consumed.
    ///
    /// Best for simple compositions with static motion and gradient palettes.
    /// Complex patterns (cascade, wave, scatter) need the v1 rules chain instead.
    func uploadV2DynamicScene(
        preset: CompositionPreset,
        room: RoomDisplayItem,
        lightIDs: [String],
        gamut: HueColorUtils.Gamut,
        api: HueAPIClient
    ) async throws -> V2DynamicSceneManifest {
        guard !lightIDs.isEmpty else {
            throw BridgeAnimationError.noLightsResolved
        }
        guard !preset.reaction.requiresMic else {
            throw BridgeAnimationError.presetRequiresMic
        }

        // ─── 1. Calculate timing ───
        let cycleDuration = calculateCycleDuration(for: preset)
        let durationMs = max(1000, Int(cycleDuration * 1000))  // min 1 second per transition

        log.info("[BridgeAnim-v2] Upload '\(preset.name)' → dynamic_palette, cycle=\(durationMs)ms")

        // ─── 2. Render one snapshot frame per light for the palette ───
        let paramBox = CompositionParamBox(preset: preset)
        let channelIDs: [UInt8] = (0..<UInt8(min(lightIDs.count, 20))).map { $0 }
        let frames = CompositionEngine.render(
            time: 0,
            channelIDs: channelIDs,
            params: paramBox
        )

        // ─── 3. Build v2 scene actions ───
        let actions: [CreateSceneRequest.SceneAction] = lightIDs.enumerated().compactMap { (index, lightID) in
            guard index < frames.count else { return nil }
            let frame = frames[index]
            let xy = HueColorUtils.clampXYToGamut(x: frame.x, y: frame.y, gamut: gamut)
            let bri = max(1.0, min(100.0, frame.brightness * 100.0))

            return CreateSceneRequest.SceneAction(
                target: .init(rid: lightID, rtype: "light"),
                action: .init(
                    on: .init(on: true),
                    dimming: .init(brightness: bri),
                    color: .init(xy: .init(x: xy.x, y: xy.y)),
                    color_temperature: nil
                )
            )
        }

        // ─── 4. Create v2 scene ───
        let sceneName = "CG_\(String(preset.name.prefix(16)))"
        let groupRtype = room.kind == .zone ? "zone" : "room"
        let request = CreateSceneRequest(
            metadata: .init(name: sceneName),
            group: .init(rid: room.id, rtype: groupRtype),
            actions: actions
        )

        let sceneID = try await api.createSceneReturningID(request)
        log.info("[BridgeAnim-v2] Created v2 scene: \(sceneID)")

        // ─── 5. Activate in dynamic palette mode ───
        try await api.activateDynamicScene(id: sceneID, durationMs: durationMs)
        log.info("[BridgeAnim-v2] ⚡ Dynamic palette activated! duration=\(durationMs)ms")

        return V2DynamicSceneManifest(
            id: UUID(),
            presetID: preset.id,
            presetName: preset.name,
            roomID: room.id,
            roomName: room.name,
            v2SceneID: sceneID,
            durationMs: durationMs,
            createdAt: Date()
        )
    }
}

// MARK: - V2 Dynamic Scene Manifest

/// Tracks a v2 dynamic scene created for bridge-stored animation.
/// Much simpler than the v1 manifest — only one scene, no rules/sensors/schedules.
struct V2DynamicSceneManifest: Codable, Identifiable {
    let id: UUID
    let presetID: UUID
    let presetName: String
    let roomID: String
    let roomName: String
    let v2SceneID: String
    let durationMs: Int
    let createdAt: Date

    /// Composite key for lookup
    var key: String { "\(presetID.uuidString)_\(roomID)" }
}

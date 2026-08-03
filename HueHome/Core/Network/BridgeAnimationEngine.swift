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
///
/// Equatable/Hashable on every stored property is load-bearing, not a
/// convenience: reconciliation computes decisions from a snapshot taken BEFORE
/// a network await, and the whole value IS the freshness fingerprint it
/// re-checks against the store before applying anything (packet 8). A field
/// added here is automatically covered by that check.
struct BridgeAnimationManifest: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let presetID: UUID
    let presetName: String
    let roomID: String
    let roomName: String

    /// The bridge's LAN host at upload time. Historic identity: an IP is a
    /// ROUTE, not an identity — DHCP moves it and two homes can reuse it.
    let bridgeIP: String

    /// The registered `BridgeRecord.id` this animation lives on (packet 8).
    ///
    /// Optional because manifests written before packet 8 recorded only the
    /// host, and those files must keep decoding. Swift's SYNTHESIZED decoder
    /// emits `decodeIfPresent` for an optional stored property, so a legacy
    /// `bridge_animations.json` decodes to nil with no custom code — and a
    /// hand-written `init(from:)` that forgot that would throw, `load()` would
    /// swallow it, and every manifest on disk would be lost. Never back-filled
    /// by guessing: see `UnifiedOrchestrator.resolvedBridgeID(for:)`.
    let bridgeID: String?

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

    /// The same manifest stamped with a resolved bridge id.
    ///
    /// Value-returning so a legacy upgrade is always a deliberate store write
    /// with a new fingerprint, never an in-place mutation that a concurrent
    /// reconciliation pass could not notice.
    func adoptingBridgeID(_ resolved: String) -> BridgeAnimationManifest {
        BridgeAnimationManifest(
            id: id, presetID: presetID, presetName: presetName,
            roomID: roomID, roomName: roomName,
            bridgeIP: bridgeIP, bridgeID: resolved,
            sensorID: sensorID, ruleIDs: ruleIDs, scheduleID: scheduleID,
            sceneIDs: sceneIDs, resourcelinkID: resourcelinkID,
            stepCount: stepCount, intervalSeconds: intervalSeconds,
            cycleDurationSeconds: cycleDurationSeconds, createdAt: createdAt)
    }
}

// MARK: - Liveness (Composer 2 packet 8)

/// The subset of ONE bridge's v1 inventory that bridge-stored animations name.
///
/// Read once per bridge and every manifest on that bridge is judged against
/// this single snapshot — never one inventory read per manifest.
struct BridgeAnimationInventory: Sendable, Equatable {
    /// scheduleID → `status == "enabled"`. An absent key means the schedule
    /// is gone; a present-but-false value means it exists and drives nothing.
    let schedules: [String: Bool]
    let rules: Set<String>
    let sensors: Set<String>
    /// nil = NOT READ, because no manifest on this bridge named a scene.
    /// Deliberately distinct from "read and empty": only the latter is
    /// evidence, and only evidence may authorise a delete.
    let scenes: Set<String>?
    let resourcelinks: Set<String>?
}

/// Exactly what the bridge still holds for one manifest. Cleanup deletes this
/// and nothing else — never a `CG_` name sweep, which is a shared prefix and
/// not an ownership claim (packet 2).
struct BridgeAnimationResidue: Equatable, Sendable {
    var scheduleID: String?
    var ruleIDs: [String] = []
    var sensorID: String?
    var sceneIDs: [String] = []
    var resourcelinkID: String?

    /// True when the bridge proved every resource this manifest names is gone.
    var isEmpty: Bool {
        scheduleID == nil && ruleIDs.isEmpty && sensorID == nil
            && sceneIDs.isEmpty && resourcelinkID == nil
    }
}

enum BridgeAnimationLiveness: Equatable, Sendable {
    /// Schedule exists AND is enabled, sensor exists, every recorded rule
    /// exists, and every recorded scene exists when `sceneIDs` is non-empty.
    ///
    /// The resourcelink is deliberately NOT part of the verdict: `upload`
    /// treats its creation as allowed to fail, so requiring it would declare
    /// healthy animations dead.
    case live
    /// The bridge answered and this animation is not running.
    /// `residue.isEmpty` means the bridge PROVED total absence.
    case notRunning(residue: BridgeAnimationResidue)
    /// The inventory needed to judge this manifest was not read. Retain the
    /// manifest, do nothing, retry later. Never a stand-in for "absent".
    case indeterminate(reason: String)
}

/// What a teardown actually achieved. Replaces the pre-packet-8 `Void` return,
/// which reported completion unconditionally and so could not stop a caller
/// from dropping the only record of resources that are still on the bridge.
enum BridgeAnimationCleanupResult: Equatable, Sendable {
    /// Every targeted resource is gone: each delete was accepted, or the bridge
    /// answered "resource not available". Safe to drop the manifest.
    case removed
    /// The bridge answered and refused at least one delete. Retain and retry.
    case partial(remaining: BridgeAnimationResidue)
    /// No delete reached the bridge at all. Retain and retry.
    case bridgeUnreadable(remaining: BridgeAnimationResidue)
}

// MARK: - BridgeAnimationError

enum BridgeAnimationError: LocalizedError {
    /// The bridge REPORTED less free capacity than this look measurably needs.
    /// The only error permitted to tell the user the bridge is full.
    case bridgeCapacityInsufficient(
        required: BridgeStoredRequirement,
        reported: BridgeReportedCapacity,
        shortages: [BridgeStoredRequirement.Shortage])
    /// Capacity could not be fetched or decoded. The app knows nothing, so it
    /// says nothing about how full the bridge is.
    case bridgeCapacityUnknown(reason: String)
    case noLightsResolved
    case noGroupFound
    case presetRequiresMic
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .bridgeCapacityInsufficient(let required, let reported, let shortages):
            // Five different resources can be short and only ONE of them is
            // about rule slots, so a fixed "needs N free rule slots" sentence
            // would be false four times out of five. Name the number only when
            // rules alone fell short; otherwise stay accurate and general.
            // (The full required-vs-reported picture for all five figures goes
            // to the sanitized diagnostics at the throw site.)
            if shortages == [.rules], let available = reported.rulesAvailable {
                return "Bridge is almost full — this look needs \(required.ruleResources) free rule slots and only \(available) are left."
            }
            return "Bridge is almost full — it doesn't have enough free space to store this look."
        case .bridgeCapacityUnknown:
            return "Couldn't check the free space on this bridge."
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

        // ─── 1. Calculate cycle timing ───
        let stepCount = calculateStepCount(for: preset)
        let cycleDuration = calculateCycleDuration(for: preset)
        let stepInterval = max(3, Int(cycleDuration / Double(stepCount)))  // min 3 seconds between steps
        // Transition time between steps (in deciseconds for v1 API)
        // Use ~80% of step interval for smooth overlap
        let transitionDeciSeconds = max(10, Int(Double(stepInterval) * 8.0))

        log.info("[BridgeAnim] Upload '\(preset.name)' → \(stepCount) steps, \(stepInterval)s/step, cycle=\(cycleDuration)s")

        // ─── 1b. Capacity preflight — BEFORE any resource is created ───
        //
        // Packet 5. Two things changed. The requirement is now computed from
        // the arithmetic the loops below actually execute, in aggregate:
        // `steps × ceil(lights/7)` rules, twice that many conditions, and one
        // action per light per step plus a sensor advance on every non-final
        // step. The old gate asked for a flat 12 free rules — half of what a
        // 20-light 8-step look really needs — so a bridge with 13 free slots
        // passed and then threw partway through the rule loop, leaving
        // orphans behind. Second, availability now comes from the BRIDGE
        // (`/capabilities`) instead of being inferred from hard-coded totals.
        //
        // This is a point-in-time CHECK, not a reservation: nothing in v1 can
        // hold capacity, so a later failure is not evidence of exhaustion and
        // is never reported as such. What it does guarantee is that an upload
        // already known not to fit never starts, and that we fail closed when
        // we cannot tell.
        let requirement = BridgeStoredRequirement(
            lights: lightIDs.count, steps: stepCount)
        let reported: BridgeReportedCapacity
        do {
            reported = try await v1Client.fetchReportedCapacity()
        } catch {
            log.error("[BridgeAnim] capability read failed: \(error.localizedDescription)")
            throw BridgeAnimationError.bridgeCapacityUnknown(
                reason: "capability read failed: \(error.localizedDescription)")
        }
        switch reported.verdict(for: requirement) {
        case .fits:
            log.info("[BridgeAnim] capacity OK — \(reported.diagnosticSummary(for: requirement))")
        case .insufficient(let required, let capacity, let shortages):
            // Every figure goes to the log, whichever single sentence the user
            // ends up seeing.
            log.error("""
                [BridgeAnim] insufficient capacity \
                (short: \(shortages.map(\.rawValue).joined(separator: ", "))) — \
                \(capacity.diagnosticSummary(for: required))
                """)
            throw BridgeAnimationError.bridgeCapacityInsufficient(
                required: required, reported: capacity, shortages: shortages)
        case .unknown(let reason):
            log.error("[BridgeAnim] capacity unknown — \(reason)")
            throw BridgeAnimationError.bridgeCapacityUnknown(reason: reason)
        }

        // ─── 2. Pre-render frames ───
        let paramBox = CompositionParamBox(preset: preset)
        // Packet 5: one render channel per light in the room — no cap. The old
        // `min(lightIDs.count, 20)` was a copy of the REST scheduler's clamp,
        // which was itself a workaround for `LightFrame.channelID` being
        // `UInt8`. Nothing in the v1 API caps a rules chain at 20 lights; the
        // real v1 limits are 8 actions per rule (chunked below) and the
        // bridge's reported resource capacity (preflighted before any create).
        // With the cap gone `frames.count == lightIDs.count`, so the
        // `lightIndex < frames.count` guards below can no longer drop a light.
        let channelIDs: [Int] = Array(0..<lightIDs.count)
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

        // Packet 5: no light may be silently missing from a step. The `20` cap
        // is gone and the room is rendered in full, so every step must now
        // carry a state for every light — the `lightIndex < frames.count`
        // guard above can no longer drop one. This is the belt-and-braces
        // check that the truncation cannot come back quietly: it is the same
        // shape as the `actions.count <= 8` guard below, and it fires BEFORE
        // any resource is created, so a violation costs nothing on the bridge.
        for (step, stepStates) in perStepLightStates.enumerated()
        where stepStates.count != v1LightIDs.count {
            throw BridgeAnimationError.uploadFailed(
                "step \(step) has \(stepStates.count) light states for \(v1LightIDs.count) lights "
                + "— refusing to upload a silently truncated animation")
        }

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
            // The engine holds a client, and a client knows its host but not
            // which BridgeRecord it belongs to. The orchestrator stamps the
            // stable id at save time, where that identity is already exact.
            bridgeID: nil,
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

    /// Stop a bridge-stored animation and clean up its resources, REPORTING
    /// what actually happened.
    ///
    /// `only` narrows the deletes to exactly what a fresh inventory read said
    /// the bridge still holds (reconciliation). `nil` targets every id the
    /// manifest names — byte-for-byte the pre-packet-8 delete set and order,
    /// which the replacement path and packet 2's ordering tests rely on.
    ///
    /// Issues ZERO reads, whichever mode. Verifying by enumeration here would
    /// break packet 2's guarantee that a normal replacement never enumerates
    /// the bridge, so the residue is computed by the reconciler and passed in.
    ///
    /// Every step is attempted even after a failure: aborting early would leave
    /// a partially-torn-down chain whose surviving rules keep firing.
    @discardableResult
    func stop(
        manifest: BridgeAnimationManifest,
        v1Client: HueV1Client,
        only residue: BridgeAnimationResidue? = nil
    ) async -> BridgeAnimationCleanupResult {
        log.info("[BridgeAnim] Stopping animation '\(manifest.presetName)' on '\(manifest.roomName)'")

        let target = residue ?? Self.fullResidue(of: manifest)
        var remaining = BridgeAnimationResidue()
        var bridgeAnswered = false
        var anyFailure = false

        /// Classify one delete. A `HueV1ClientError.apiError` means the bridge
        /// answered and refused; anything else (HTTP status, bad URL, URLError)
        /// never reached it. That difference is what separates "retry later,
        /// the bridge is unreachable" from "this bridge is refusing us".
        func attempt(_ label: String, _ work: () async throws -> Void) async -> Bool {
            do {
                try await work()
                bridgeAnswered = true
                return true
            } catch {
                anyFailure = true
                if error is HueV1ClientError { bridgeAnswered = true }
                log.warning("[BridgeAnim] Failed to delete \(label): \(error.localizedDescription)")
                return false
            }
        }

        // Delete in reverse order of dependency:
        // 1. Schedule (stops the timer)
        if let scheduleID = target.scheduleID {
            if await attempt("schedule \(scheduleID)", { try await v1Client.deleteSchedule(id: scheduleID) }) == false {
                remaining.scheduleID = scheduleID
            }
        }

        // 2. Rules (stops the chain)
        for ruleID in target.ruleIDs {
            if await attempt("rule \(ruleID)", { try await v1Client.deleteRule(id: ruleID) }) == false {
                remaining.ruleIDs.append(ruleID)
            }
        }

        // 3. Sensor (removes the counter)
        if let sensorID = target.sensorID {
            if await attempt("sensor \(sensorID)", { try await v1Client.deleteSensor(id: sensorID) }) == false {
                remaining.sensorID = sensorID
            }
        }

        // 4. Scenes (removes the stored states)
        for sceneID in target.sceneIDs {
            if await attempt("scene \(sceneID)", { try await v1Client.deleteScene(id: sceneID) }) == false {
                remaining.sceneIDs.append(sceneID)
            }
        }

        // 5. Resourcelink (removes the grouping)
        if let rlID = target.resourcelinkID {
            if await attempt("resourcelink \(rlID)", { try await v1Client.deleteResourcelink(id: rlID) }) == false {
                remaining.resourcelinkID = rlID
            }
        }

        guard anyFailure else {
            log.info("[BridgeAnim] ✅ Cleanup complete for '\(manifest.presetName)'")
            return .removed
        }
        if bridgeAnswered {
            log.warning("[BridgeAnim] ⚠ Partial cleanup for '\(manifest.presetName)' — retaining evidence")
            return .partial(remaining: remaining)
        }
        log.warning("[BridgeAnim] ⚠ Bridge unreadable during cleanup of '\(manifest.presetName)' — retaining evidence")
        return .bridgeUnreadable(remaining: remaining)
    }

    // MARK: - Liveness (pure, packet 8)

    /// Every resource id this manifest names, whether or not the bridge still
    /// has it. The delete set when no inventory narrowed it.
    nonisolated static func fullResidue(of m: BridgeAnimationManifest) -> BridgeAnimationResidue {
        BridgeAnimationResidue(
            scheduleID: m.scheduleID,
            ruleIDs: m.ruleIDs,
            sensorID: m.sensorID,
            sceneIDs: m.sceneIDs,
            resourcelinkID: m.resourcelinkID)
    }

    /// What this bridge STILL holds of the manifest's named resources.
    ///
    /// A category the inventory did not read contributes nothing: the caller
    /// must treat that manifest as indeterminate rather than delete a partial
    /// set (see `liveness(of:in:)`).
    nonisolated static func residue(
        of m: BridgeAnimationManifest,
        in inv: BridgeAnimationInventory
    ) -> BridgeAnimationResidue {
        var residue = BridgeAnimationResidue()
        if inv.schedules[m.scheduleID] != nil { residue.scheduleID = m.scheduleID }
        residue.ruleIDs = m.ruleIDs.filter { inv.rules.contains($0) }
        if inv.sensors.contains(m.sensorID) { residue.sensorID = m.sensorID }
        if let scenes = inv.scenes {
            residue.sceneIDs = m.sceneIDs.filter { scenes.contains($0) }
        }
        if let rlID = m.resourcelinkID, let links = inv.resourcelinks, links.contains(rlID) {
            residue.resourcelinkID = rlID
        }
        return residue
    }

    /// Is this manifest's animation still running on this bridge?
    ///
    /// Fails closed in both directions: a category the reconciler did not read
    /// yields `.indeterminate` rather than a verdict, because claiming absence
    /// from an unread inventory is how a live animation gets torn down, and
    /// claiming presence from one is how a phantom row appears.
    nonisolated static func liveness(
        of m: BridgeAnimationManifest,
        in inv: BridgeAnimationInventory
    ) -> BridgeAnimationLiveness {
        if !m.sceneIDs.isEmpty && inv.scenes == nil {
            return .indeterminate(reason: "manifest names scenes but scenes were not read")
        }
        if m.resourcelinkID != nil && inv.resourcelinks == nil {
            return .indeterminate(reason: "manifest names a resourcelink but resourcelinks were not read")
        }

        let scheduleEnabled = inv.schedules[m.scheduleID] == true
        let sensorPresent = inv.sensors.contains(m.sensorID)
        let allRulesPresent = m.ruleIDs.allSatisfy { inv.rules.contains($0) }
        let allScenesPresent = m.sceneIDs.isEmpty
            || (inv.scenes.map { scenes in m.sceneIDs.allSatisfy { scenes.contains($0) } } ?? false)

        if scheduleEnabled && sensorPresent && allRulesPresent && allScenesPresent {
            return .live
        }
        return .notRunning(residue: residue(of: m, in: inv))
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
}

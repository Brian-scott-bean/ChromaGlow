// TransportVocabulary.swift
// ChromaGlow — THE single source of user-facing play-mode words.
//
// Executes the deferred build-23 Phase C ("one transport vocabulary"):
// every surface that names how a look plays — badges, menus, the save
// sheet, the first-run dialog, status sentences, toasts — reads these
// constants. "REST", "transport", and raw enum tags are developer words
// and must never reach the user again (the jargon guard test greps for
// them). "Entertainment Area" stays — it is official Hue vocabulary.

import Foundation

enum TransportVocabulary {

    // ── Mode names (menus / pickers) ─────────────────────────
    static let streamingMenuLabel = "Entertainment Area (Streaming)"
    static let roomOnlyMenuLabel  = "Room Only"
    static let autoTitle          = "Auto (match the scene)"
    static let streamingTitle     = "Entertainment Area — streamed"
    static let roomOnlyTitle      = "Room Only"

    // ── Save-sheet option copy ───────────────────────────────
    static let streamingSubtitle  = "Streaming"
    static let roomModeSubtitle   = "Room mode"
    static let streamingSegment   = "Streaming"
    static let roomSegment        = "Room"

    // ── Badges (mono lane, short; never wrap) ────────────────
    static let badgeStreaming = "AREA"
    static let badgeRoom      = "ROOM"
    static let badgeBridge    = "BRIDGE ⚡"

    // ── Sections / dialogs / menus ───────────────────────────
    static let playModeSection   = "Play mode"
    static let choosePlayTitle   = "How should this play?"
    // "uses this room's Entertainment Area", not "lights the whole" one:
    // this dialog appears BEFORE any availability check, and streaming can
    // still fail over mid-session, so a full-fidelity promise here is one the
    // app cannot keep (packet 5).
    static let choosePlayMessage = "Streaming is the smoothest and uses this room's Entertainment Area; Room Only keeps it to this room and updates a little slower. Your choice is remembered — change it any time from the badge on the running deck."
    static let saveSheetFooter   = "Streaming uses the Entertainment Area when it's available. Room Only plays through this room's controls."
    static let applyWithMenu     = "Apply with Play Mode…"
    static let preferredMenu     = "Preferred Play Mode…"

    // ── Status sentences (mixer row 3) ───────────────────────
    // A stored look is 2–8 pre-rendered steps that cannot move faster than
    // 3 s/step, so "lights keep going" alone oversells it (packet 5).
    static let bridgeStoredStatus = "Running on bridge — close the app, lights keep going, with simpler motion"
    static let fallbackStatus     = "Streaming isn't available right now — playing in Room mode"
    static func roomModeCadenceStatus(liveSeconds: Double?) -> String {
        guard let liveSeconds else { return "Playing in Room mode — updates a little slower" }
        return "Playing in Room mode — updates about every \(String(format: "%.1f", liveSeconds))s"
    }

    /// The Room-mode status sentence for every combination of "why we fell
    /// back" and "is this room served in rotation" (packet 5).
    ///
    /// Those two facts are INDEPENDENT and frequently co-occur — a bridge that
    /// couldn't store a look for a 60-light room is both — so this function is
    /// exhaustive over the pair rather than a priority list that would drop
    /// one of them. Adding a `CompositionFallbackReason` case fails to compile
    /// until its copy exists here.
    ///
    /// Note what is deliberately absent: any light count, any promise that
    /// every light updates every frame, and any claim that the bridge is full
    /// unless capacity was actually MEASURED short. Combined sentences carry
    /// no seconds figure either — with a fallback in play the cadence is not
    /// yet meaningful, and the rotation bound is in sweeps, not seconds.
    static func roomModeStatus(
        fallback: CompositionFallbackReason?,
        largeRoom: Bool,
        liveSeconds: Double?
    ) -> String {
        switch (fallback, largeRoom) {
        case (nil, false):
            return roomModeCadenceStatus(liveSeconds: liveSeconds)
        case (nil, true):
            guard let liveSeconds else { return roomModeRotationStatus }
            return "Playing in Room mode — lights take turns, about every \(String(format: "%.1f", liveSeconds))s per group"

        case (.entertainmentUnavailable, false):
            return fallbackStatus
        case (.entertainmentUnavailable, true):
            return "Streaming isn't available right now, so Room mode is playing; lights take turns updating"

        case (.bridgeCapacityInsufficient, false):
            return "This bridge doesn't have room to store this look — playing in Room mode instead"
        case (.bridgeCapacityInsufficient, true):
            return "This bridge couldn't store this look, so Room mode is playing; lights take turns updating"

        case (.bridgeCapacityUnknown, false):
            return "Couldn't check storage space on this bridge — playing in Room mode instead"
        case (.bridgeCapacityUnknown, true):
            return "Couldn't check storage space on this bridge, so Room mode is playing; lights take turns updating"

        case (.bridgeStoredUploadFailed, false):
            return "This look couldn't be stored on the bridge — playing in Room mode instead"
        case (.bridgeStoredUploadFailed, true):
            return "This look couldn't be stored on the bridge, so Room mode is playing; lights take turns updating"
        }
    }

    /// Large-room rolling delivery with no measured cadence yet. Deliberately
    /// promises no refresh interval: the scheduler is best-effort and the
    /// fairness bound is expressed in sweeps, not wall-clock time.
    static let roomModeRotationStatus =
        "Playing in Room mode — this room is large, so its lights take turns updating"

    // ── Toast fragments (StudioViewModel status lines) ───────
    static let toastStreaming = "streaming"
    static let toastRoomMode  = "Room mode"
    static let toastOneShot   = "one-time"
}

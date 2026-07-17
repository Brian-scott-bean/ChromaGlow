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
    static let choosePlayMessage = "Streaming is the smoothest and lights the whole Entertainment Area; Room Only keeps it to this room and updates a little slower. Your choice is remembered — change it any time from the badge on the running deck."
    static let saveSheetFooter   = "Streaming uses the Entertainment Area when it's available. Room Only plays through this room's controls."
    static let applyWithMenu     = "Apply with Play Mode…"
    static let preferredMenu     = "Preferred Play Mode…"

    // ── Status sentences (mixer row 3) ───────────────────────
    static let bridgeStoredStatus = "Running on bridge — close the app, lights keep going"
    static let fallbackStatus     = "Streaming isn't available right now — playing in Room mode"
    static func roomModeCadenceStatus(liveSeconds: Double?) -> String {
        guard let liveSeconds else { return "Playing in Room mode — updates a little slower" }
        return "Playing in Room mode — updates about every \(String(format: "%.1f", liveSeconds))s"
    }

    // ── Toast fragments (StudioViewModel status lines) ───────
    static let toastStreaming = "streaming"
    static let toastRoomMode  = "Room mode"
    static let toastOneShot   = "one-time"
}

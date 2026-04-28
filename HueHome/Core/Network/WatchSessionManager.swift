// WatchSessionManager.swift
// HueHome — iPhone-side WatchConnectivity manager.
//
// Activates WCSession on app launch and pushes the latest room snapshot
// to the Apple Watch via updateApplicationContext whenever rooms change.
// applicationContext is the right transport here: it is delivered as soon
// as the watch app comes to the foreground, even if the phone was offline
// at the time of the write — no real-time pairing required.

import WatchConnectivity

final class WatchSessionManager: NSObject, WCSessionDelegate {

    static let shared = WatchSessionManager()

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - Push to Watch

    /// Call after every successful room write so the watch stays in sync.
    func push(rooms: [WidgetRoomSnapshot], ip: String, token: String) {
        guard WCSession.default.activationState == .activated else { return }
        guard WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled else { return }

        guard let roomsData = try? JSONEncoder().encode(rooms) else { return }

        let context: [String: Any] = [
            "wc_rooms_v1" : roomsData,
            "wc_bridge_ip": ip,
            "wc_token"    : token
        ]
        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            // Non-fatal — app group is the fallback for widget; watch will
            // retry on next rooms write.
            print("WatchSessionManager: context update failed — \(error)")
        }
    }

    // MARK: - WCSessionDelegate (iPhone-required methods)

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error { print("WatchSessionManager: activation error — \(error)") }
    }

    // These two are iPhone-only (watchOS doesn't call them)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate after paired watch switch
        WCSession.default.activate()
    }
}

// AutomationHandler.swift
// CastChroma — Bridges the gap between UNNotification delivery and Hue API execution.
//
// PROBLEM: AutomationScheduler schedules UNCalendarNotificationTriggers correctly,
// but there was no UNUserNotificationCenterDelegate to handle the notification response
// and actually call the Hue API. Automations showed a banner but never changed lights.
//
// SOLUTION:
//   1. AppDelegate registers as UNUserNotificationCenterDelegate at launch.
//   2. willPresent (foreground) + didReceive (tap from background/closed):
//      both decode userInfo → post NotificationCenter event + store in UserDefaults.
//   3. AppRootView listens for the NotificationCenter event and calls
//      orchestrator.applyAutomationPreset(id:) once loadAll() is complete.
//   4. UserDefaults acts as the cold-start buffer (app was killed, user taps notif,
//      app relaunches → AppRootView reads pending action after loadAll()).

import UIKit
import UserNotifications
import OSLog

// MARK: - Notification Name

extension Notification.Name {
    /// Posted (on MainActor) when an automation notification should be executed immediately.
    /// userInfo key "presetID" contains the preset string.
    static let automationShouldExecute = Notification.Name("castchroma.automationShouldExecute")
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {

    private let log = Logger(subsystem: "com.lightshade.app", category: "AutomationHandler")
    private enum OrientationPrefs {
        static let allowLandscape = "app.allowLandscapeRotation"
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        log.info("AppDelegate: registered as UNUserNotificationCenter delegate")
        StartupTimeline.mark("app.didFinishLaunching")
        #if DEBUG
        MainThreadWatchdog.shared.start()
        #endif
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        let allowLandscape = UserDefaults.standard.bool(forKey: OrientationPrefs.allowLandscape)
        if allowLandscape {
            return .allButUpsideDown
        }
        return .portrait
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate {

    /// Called when a notification is DELIVERED while the app is in the FOREGROUND.
    /// We show the banner AND immediately fire the automation.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let info = notification.request.content.userInfo
        if notification.request.content.categoryIdentifier == AutomationScheduler.categoryID {
            log.info("Automation notification delivered (foreground) — firing immediately")
            // Post-only: the app is alive, so the .automationShouldExecute
            // receiver runs it NOW. Persisting here too left a stale pending
            // key that replayed the automation on the next cold launch
            // (Sleep at 10:30pm re-dimming the house at 7am).
            handle(userInfo: info, delivery: .foreground)
        }
        // Suppress the visual banner — lights are already being applied automatically.
        // Showing "Tap to apply" while executing is confusing UX.
        completionHandler([])
    }

    /// Called when the user TAPS a notification (app was in background or closed).
    /// The app is now launching/foregrounding — post the event so AppRootView can
    /// pick it up after loadAll() has had a chance to configure the orchestrator.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if response.notification.request.content.categoryIdentifier == AutomationScheduler.categoryID {
            log.info("Automation notification tapped — queuing for execution after app init")
            // Persist-only: the tap is foregrounding the app, so the
            // scenePhase/cold-start drain executes and clears the key.
            // Posting here too raced the drain into double execution.
            handle(userInfo: info, delivery: .tapped)
        }
        completionHandler()
    }

    // MARK: - Private

    /// How the notification reached us decides the execution channel —
    /// exactly one of the two, never both:
    /// - `.foreground` (willPresent): the app is alive → post the event;
    ///   persisting too replayed the automation on the NEXT launch.
    /// - `.tapped` (didReceive): the app is foregrounding → persist for the
    ///   scenePhase/cold-start drain; posting too double-executed.
    enum AutomationDelivery { case foreground, tapped }

    private func handle(userInfo: [AnyHashable: Any], delivery: AutomationDelivery) {
        let actionType = userInfo["actionType"] as? String ?? "preset"
        let presetID   = userInfo["presetID"]   as? String ?? ""
        let effectID   = userInfo["effectID"]   as? String ?? ""

        if actionType == "effect", !effectID.isEmpty {
            switch delivery {
            case .tapped:
                UserDefaults.standard.set(effectID, forKey: "pendingAutomationEffectID")
            case .foreground:
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .automationShouldExecute,
                        object: nil,
                        userInfo: ["effectID": effectID, "actionType": "effect"]
                    )
                }
            }
        } else if !presetID.isEmpty {
            switch delivery {
            case .tapped:
                UserDefaults.standard.set(presetID, forKey: "pendingAutomationPresetID")
            case .foreground:
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .automationShouldExecute,
                        object: nil,
                        userInfo: ["presetID": presetID, "actionType": "preset"]
                    )
                }
            }
        } else {
            log.warning("handle(userInfo:): no valid preset or effect ID found — skipping")
        }
    }
}

// MARK: - Preset definitions (shared, used by orchestrator)

/// Preset parameters, backed by the shared LightingPreset catalog so the
/// automation path can never drift from what Dashboard/RoomDetail/widget/watch
/// apply. Kept as its own type because automation payloads persist these ids.
struct AutomationPreset {
    let id:         String
    let brightness: Double
    let mirek:      Int

    static let all: [AutomationPreset] = LightingPreset.all.map {
        AutomationPreset(id: $0.id, brightness: $0.brightness, mirek: $0.mirek)
    }

    static func find(_ id: String) -> AutomationPreset? {
        all.first { $0.id == id }
    }
}

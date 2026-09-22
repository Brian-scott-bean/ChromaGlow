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

import SwiftUI
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
                PendingAutomation.store(effectID, forKey: PendingAutomation.effectKey)
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
                PendingAutomation.store(presetID, forKey: PendingAutomation.presetKey)
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

// MARK: - Pending (tapped) automation buffer

/// Cold-start buffer for a TAPPED automation notification: `didReceive`
/// stores it, AppRootView's cold-start / scenePhase drains apply it once the
/// orchestrator is ready.
///
/// Entries are timestamped and expire: an unstamped key used to survive until
/// ANY later launch drained it (e.g. the tap landed while the drain was
/// gated off in demo), replaying "Sleep" at 7 am.
enum PendingAutomation {
    static let presetKey = "pendingAutomationPresetID"
    static let effectKey = "pendingAutomationEffectID"
    /// A tap is honoured for this long; older entries are discarded unapplied.
    static let maxAge: TimeInterval = 10 * 60

    private static func stampKey(_ key: String) -> String { key + ".queuedAt" }

    static func store(_ id: String, forKey key: String,
                      now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: key)
        defaults.set(now, forKey: stampKey(key))
    }

    /// Removes the entry and returns its id only if it was queued within
    /// `maxAge` (a clock that moved backwards counts as stale). Unstamped
    /// entries from older builds are discarded.
    static func take(forKey key: String,
                     now: Date = Date(), defaults: UserDefaults = .standard) -> String? {
        let id = defaults.string(forKey: key)
        let queuedAt = defaults.object(forKey: stampKey(key)) as? Date
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: stampKey(key))
        guard let id, !id.isEmpty, let queuedAt else { return nil }
        let age = now.timeIntervalSince(queuedAt)
        guard age >= 0, age <= maxAge else { return nil }
        return id
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

// MARK: - Effect plans (shared, used by orchestrator)

/// One grouped_light write of a scheduled effect automation.
struct AutomationGroupWrite: Equatable, Sendable {
    let on: Bool
    let brightness: Double?
    let mirek: Int?
    let xy: CIEPoint?
    /// Hue `dynamics.duration` in ms (0 = instant).
    let durationMs: Int

    struct CIEPoint: Equatable, Sendable {
        let x: Double
        let y: Double
    }
}

/// What a scheduled effect automation writes, derived from the effect's OWN
/// catalog defaults (the automation stores only an effect id, so the
/// EffectLibrary card defaults ARE its settings).
///
/// Every one-shot/gradual effect used to write a hard-coded 70% / 300 mirek
/// in 400 ms: "Wind Down" (a slow dim to 3%) and "Sunset" (a 30-minute fade
/// to darkness) lit the house to 70% white instantly — close to the opposite
/// of what was picked.
///
/// Hue limits honored: mirek 153–500, brightness 0–100, and a transition no
/// longer than the Zigbee ceiling (uint16 × 100 ms). A gradual "Turn Off at
/// End" rides the bridge as ONE fade-to-off transition — an app-side timer
/// would die with the app long before a 30-minute ramp ends.
enum AutomationEffectPlan: Equatable, Sendable {
    /// Bridge-native firmware effect (candle, fire, …) on grouped_light.
    case nativeEffect(String)
    /// grouped_light writes applied in order, with a short pause between
    /// steps so the bridge registers a start snap before the ramp begins.
    case writes([AutomationGroupWrite])

    /// Longest transition a Hue light can execute (65535 × 100 ms).
    static let maxTransitionMs = 6_553_500

    static func plan(for effect: HueEffect) -> AutomationEffectPlan {
        switch effect.strategy {
        case .bridgeNative(let effectName):
            return .nativeEffect(effectName)

        case .oneShot:
            let mirek = slider("mirek", in: effect).map(clampedMirek)
            // Warmth wins when both exist; a colour card (Romance) has no
            // mirek slider, only a swatch.
            let xy = mirek == nil ? color("color", in: effect).map(gamutXY) : nil
            return .writes([AutomationGroupWrite(
                on: true,
                brightness: slider("brightness", in: effect).map(clampedBrightness) ?? 70,
                mirek: mirek,
                xy: xy,
                durationMs: clampedDuration(Int(slider("fade", in: effect) ?? 400))
            )])

        case .gradual:
            var steps: [AutomationGroupWrite] = []
            let startBrightness = slider("startBrightness", in: effect)
            let startMirek = slider("startMirek", in: effect)
            if startBrightness != nil || startMirek != nil {
                // Snap to the start look instantly (Sunrise begins dim + warm).
                steps.append(AutomationGroupWrite(
                    on: true,
                    brightness: startBrightness.map(clampedBrightness),
                    mirek: startMirek.map(clampedMirek),
                    xy: nil,
                    durationMs: 0
                ))
            }
            let rampMs = clampedDuration((duration("duration", in: effect) ?? 900) * 1000)
            let endMirek = slider("endMirek", in: effect).map(clampedMirek)
            if toggle("turnOff", in: effect) == true {
                // Fade to darkness across the whole duration, warming as it goes.
                steps.append(AutomationGroupWrite(
                    on: false, brightness: nil, mirek: endMirek, xy: nil, durationMs: rampMs
                ))
            } else {
                steps.append(AutomationGroupWrite(
                    on: true,
                    brightness: slider("endBrightness", in: effect).map(clampedBrightness),
                    mirek: endMirek,
                    xy: nil,
                    durationMs: rampMs
                ))
            }
            return .writes(steps)

        case .appDriven:
            // Needs a foreground loop a notification can't provide (and the
            // picker doesn't offer these) — a static warm fallback for any
            // automation saved before that filter existed.
            return .writes([AutomationGroupWrite(
                on: true, brightness: 70, mirek: nil, xy: nil, durationMs: 400
            )])
        }
    }

    // MARK: Catalog defaults

    private static func slider(_ key: String, in effect: HueEffect) -> Double? {
        for param in effect.params {
            if case .slider(let k, _, let value, _, _, _) = param, k == key { return value }
        }
        return nil
    }

    private static func duration(_ key: String, in effect: HueEffect) -> Int? {
        for param in effect.params {
            if case .durationPicker(let k, _, let seconds, _, _) = param, k == key { return seconds }
        }
        return nil
    }

    private static func toggle(_ key: String, in effect: HueEffect) -> Bool? {
        for param in effect.params {
            if case .toggle(let k, _, let value) = param, k == key { return value }
        }
        return nil
    }

    private static func color(_ key: String, in effect: HueEffect) -> Color? {
        for param in effect.params {
            if case .colorSwatch(let k, _, let color) = param, k == key { return color }
        }
        return nil
    }

    // MARK: Hue limits

    private static func clampedMirek(_ value: Double) -> Int { min(500, max(153, Int(value.rounded()))) }
    private static func clampedBrightness(_ value: Double) -> Double { min(100, max(0, value)) }
    private static func clampedDuration(_ ms: Int) -> Int { min(maxTransitionMs, max(0, ms)) }

    private static func gamutXY(_ color: Color) -> AutomationGroupWrite.CIEPoint {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: nil)
        let xy = HueColorUtils.xyFrom(red: Double(r), green: Double(g), blue: Double(b))
        let clamped = HueColorUtils.clampXYToGamut(x: xy.x, y: xy.y, gamut: .c)
        return AutomationGroupWrite.CIEPoint(x: clamped.x, y: clamped.y)
    }
}

// AutomationScheduler.swift
// LightShade — Schedules and cancels UNCalendarNotificationTriggers for
// each AppAutomation. One notification per (automation × weekday).

import Foundation
import UserNotifications
import OSLog

// MARK: - AutomationScheduler

final class AutomationScheduler: @unchecked Sendable {

    static let shared = AutomationScheduler()
    private init() {}

    private let log = Logger(subsystem: "com.lightshade.app", category: "AutomationScheduler")

    /// Category identifier used for automation notification actions.
    static let categoryID = "LIGHTSHADE_AUTOMATION"

    // MARK: - Permission

    func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            log.info("Notification permission granted: \(granted)")
            return granted
        } catch {
            log.error("Notification permission error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Schedule

    /// Cancels existing notifications for this automation then re-schedules all active weekdays.
    func schedule(_ automation: AppAutomation) {
        cancel(automation)
        guard automation.isEnabled else { return }

        for weekday in automation.weekdays {
            let id = notificationID(automation: automation, weekday: weekday)

            var comps        = DateComponents()
            comps.weekday    = weekday
            comps.hour       = automation.hour
            comps.minute     = automation.minute
            comps.second     = 0

            let trigger      = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)

            let content      = UNMutableNotificationContent()
            content.title    = automation.name.isEmpty ? "CastChroma" : automation.name
            content.body     = "\(automation.action.displayName) is now active — tap to open the app"
            content.sound    = .default
            content.categoryIdentifier = Self.categoryID
            content.userInfo = [
                "automationID": automation.id.uuidString,
                "presetID":     automation.presetID ?? "",
                "effectID":     automation.effectID ?? "",
                "actionType":   automation.actionTypeRaw
            ]

            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request) { [weak self] err in
                if let err { self?.log.error("Schedule failed (\(id)): \(err.localizedDescription)") }
            }
        }
        log.info("Scheduled '\(automation.name)' × \(automation.weekdays.count) day(s)")
    }

    /// Schedules notifications for every enabled automation in the list.
    func scheduleAll(_ automations: [AppAutomation]) {
        for a in automations { schedule(a) }
    }

    // MARK: - Cancel

    func cancel(_ automation: AppAutomation) {
        let ids = (1...7).map { notificationID(automation: automation, weekday: $0) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    func cancelAll(for automations: [AppAutomation]) {
        for a in automations { cancel(a) }
    }

    // MARK: - Helpers

    private func notificationID(automation: AppAutomation, weekday: Int) -> String {
        "lightshade.automation.\(automation.id.uuidString).\(weekday)"
    }
}

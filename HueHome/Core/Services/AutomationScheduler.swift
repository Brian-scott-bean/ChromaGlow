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

    /// iOS keeps at most 64 pending local-notification requests per app and
    /// SILENTLY discards the rest. One request per automation × weekday
    /// reaches that quickly (10 every-day automations = 70).
    static let pendingRequestCap = 64

    /// One weekly trigger slot (automation × weekday).
    struct Slot: Equatable {
        let automationID: UUID
        let weekday: Int
        let hour: Int
        let minute: Int
    }

    /// Cancels existing notifications for this automation then re-schedules all active weekdays.
    func schedule(_ automation: AppAutomation) {
        cancel(automation)
        guard automation.isEnabled else { return }
        for weekday in automation.weekdays {
            addRequest(for: automation, weekday: weekday)
        }
        log.info("Scheduled '\(automation.name)' × \(automation.weekdays.count) day(s)")
        warnIfAtCap()
    }

    /// Schedules notifications for every enabled automation in the list,
    /// keeping — when there are more slots than iOS will hold — the ones
    /// that fire SOONEST, and saying so instead of letting iOS drop
    /// arbitrary ones silently. Runs on every launch, so the kept window
    /// moves forward with time.
    func scheduleAll(_ automations: [AppAutomation]) {
        for a in automations { cancel(a) }
        let enabled = automations.filter(\.isEnabled)
        let slots = enabled.flatMap { a in
            a.weekdays.map { Slot(automationID: a.id, weekday: $0, hour: a.hour, minute: a.minute) }
        }
        let kept = Self.slotsWithinCap(slots, now: Date(), calendar: .current)
        if kept.count < slots.count {
            log.warning("Automations need \(slots.count) notifications; iOS keeps \(Self.pendingRequestCap) — scheduled the \(kept.count) soonest, \(slots.count - kept.count) deferred to a later launch")
        }
        let byID = Dictionary(enabled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for slot in kept {
            guard let automation = byID[slot.automationID] else { continue }
            addRequest(for: automation, weekday: slot.weekday)
        }
    }

    /// Pure: the slots to schedule under `cap`, soonest next fire first.
    /// Under the cap every slot is kept, in its original order.
    static func slotsWithinCap(_ slots: [Slot], now: Date, calendar: Calendar,
                               cap: Int = pendingRequestCap) -> [Slot] {
        guard slots.count > cap else { return slots }
        return slots
            .map { (slot: $0, fire: nextFire(of: $0, after: now, calendar: calendar)) }
            .sorted { $0.fire < $1.fire }
            .prefix(cap)
            .map(\.slot)
    }

    static func nextFire(of slot: Slot, after now: Date, calendar: Calendar) -> Date {
        var comps = DateComponents()
        comps.weekday = slot.weekday
        comps.hour    = slot.hour
        comps.minute  = slot.minute
        comps.second  = 0
        return calendar.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) ?? .distantFuture
    }

    private func addRequest(for automation: AppAutomation, weekday: Int) {
        let id = notificationID(automation: automation, weekday: weekday)

        var comps        = DateComponents()
        comps.weekday    = weekday
        comps.hour       = automation.hour
        comps.minute     = automation.minute
        comps.second     = 0

        let trigger      = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)

        let content      = UNMutableNotificationContent()
        content.title    = automation.name.isEmpty ? "ChromaGlow" : automation.name
        // Honest copy: a delivered (background) notification runs
        // NOTHING until it is tapped — the tap is what applies it. (In
        // the foreground the banner is suppressed and it applies at once.)
        content.body     = Self.notificationBody(for: automation.action)
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

    /// A single add can't see the whole set — at least make a full queue visible.
    private func warnIfAtCap() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { [weak self] requests in
            guard requests.count >= Self.pendingRequestCap else { return }
            self?.log.warning("\(requests.count) pending notifications — at iOS's \(Self.pendingRequestCap) limit; the latest-firing automations may be dropped until the next launch reschedules")
        }
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

    /// Notification body. Pure — pinned by test.
    static func notificationBody(for action: AutomationAction) -> String {
        "Tap to apply \(action.displayName)."
    }

    private func notificationID(automation: AppAutomation, weekday: Int) -> String {
        "lightshade.automation.\(automation.id.uuidString).\(weekday)"
    }
}

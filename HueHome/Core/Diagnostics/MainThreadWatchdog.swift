// MainThreadWatchdog.swift
// DEBUG-only main-thread hang detector. A utility thread pings the main queue
// every 100ms; if a ping isn't serviced within 250ms the main thread is
// blocked, and on recovery one line is printed:
//
//   🧵HANG main thread blocked ~812ms (phase: loadAll.begin)
//
// The phase label is the last StartupTimeline mark, so every UI freeze in the
// console is timestamped AND named — this is the "what loop is it hung on"
// answer. No private API; overhead is one async no-op per 100ms.

import Foundation
import os

#if DEBUG
final class MainThreadWatchdog: @unchecked Sendable {

    static let shared = MainThreadWatchdog()
    private init() {}

    private let log = Logger(subsystem: "com.lightshade.app", category: "Watchdog")

    /// Threshold before a stall counts as a hang.
    private let hangThreshold: TimeInterval = 0.25
    /// Ping cadence while healthy.
    private let pingInterval: TimeInterval = 0.10

    private let startedLock = NSLock()
    private var started = false

    /// Idempotent; call once from AppDelegate.didFinishLaunching.
    func start() {
        startedLock.lock()
        defer { startedLock.unlock() }
        guard !started else { return }
        started = true

        let thread = Thread { [log, hangThreshold, pingInterval] in
            while true {
                let sentAt = DispatchTime.now()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }

                if sem.wait(timeout: .now() + hangThreshold) == .timedOut {
                    // Main thread is blocked — wait for recovery, then report
                    // the total stall with the phase it happened in.
                    sem.wait()
                    let blockedMs = Int(Double(DispatchTime.now().uptimeNanoseconds - sentAt.uptimeNanoseconds) / 1_000_000)
                    let phase = StartupTimeline.lastMarkPhase
                    let line = "🧵HANG main thread blocked ~\(blockedMs)ms (phase: \(phase))"
                    print(line)
                    log.error("\(line, privacy: .public)")
                }
                Thread.sleep(forTimeInterval: pingInterval)
            }
        }
        thread.name = "MainThreadWatchdog"
        thread.qualityOfService = .utility
        thread.start()
    }
}
#endif

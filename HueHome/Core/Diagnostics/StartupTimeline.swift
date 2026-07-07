// StartupTimeline.swift
// Live startup-phase timeline. One grep-able console line per mark:
//
//   ⏱️TL +1234ms  loadAll.begin  (Δ 56ms)  bridges=2
//
// `+Nms` is wall time since true process start (sysctl kinfo_proc), `Δ` is the
// gap since the previous mark — any stall on the startup path shows up as a
// large Δ labeled with the phase that owned it. Marks mirror to OSLog
// (com.lightshade.app / Startup, always on) and emit an os_signpost event so
// Instruments' Points of Interest gets the same story for free. Console
// filter: ⏱️TL (or 🧵HANG / 🌐 for the companion probes).
//
// Cost per mark: two Date diffs, a lock, a print — safe to leave in DEBUG
// builds permanently; prints are #if DEBUG per house convention.

import Foundation
import os

enum StartupTimeline {

    /// True process start time (exec), not static-init time — so `+Nms` covers
    /// dyld/pre-main too. Falls back to first-touch Date if sysctl fails.
    private static let processStart: Date = {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        if sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 {
            let tv = info.kp_proc.p_starttime
            return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
        }
        return Date()
    }()

    private static let log = Logger(subsystem: "com.lightshade.app", category: "Startup")
    private static let signposter = OSSignposter(subsystem: "com.lightshade.app", category: "Startup")

    /// Last mark, read by MainThreadWatchdog to label hangs with the phase they
    /// happened in. Lock-guarded mirror — marks can arrive from any thread.
    private static let lastMarkLock = NSLock()
    nonisolated(unsafe) private static var _lastMark: (phase: String, at: Date) = ("pre-main", Date())

    static var lastMarkPhase: String {
        lastMarkLock.lock(); defer { lastMarkLock.unlock() }
        return _lastMark.phase
    }

    /// Record a phase boundary. Callable from any thread/actor.
    static func mark(_ phase: String, _ detail: String = "") {
        let now = Date()
        let sinceLaunch = Int(now.timeIntervalSince(processStart) * 1000)
        lastMarkLock.lock()
        let delta = Int(now.timeIntervalSince(_lastMark.at) * 1000)
        _lastMark = (phase, now)
        lastMarkLock.unlock()

        let line = "⏱️TL +\(sinceLaunch)ms  \(phase)  (Δ \(delta)ms)" + (detail.isEmpty ? "" : "  \(detail)")
        #if DEBUG
        print(line)
        #endif
        log.info("\(line, privacy: .public)")
        signposter.emitEvent("StartupMark", "\(phase, privacy: .public) +\(sinceLaunch)ms \(detail, privacy: .public)")
    }
}

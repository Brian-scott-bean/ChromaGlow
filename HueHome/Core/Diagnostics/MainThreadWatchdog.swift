// MainThreadWatchdog.swift
// DEBUG-only main-thread hang detector + in-hang stack sampler.
//
// A utility thread pings the main queue every 100ms; if a ping isn't serviced
// within 250ms the main thread is blocked. While blocked, the watchdog samples
// the main thread's ACTUAL stack at ~1s / ~3s / ~8s into the hang and prints it
// symbolicated:
//
//   🧵HANG-STACK main blocked ~1002ms so far (phase: splash.route) — main thread is in:
//      HueHome  $s7HueHome17SomeSlowFunction… + 124
//      SwiftUICore  …
//
// then on recovery the usual summary line:
//
//   🧵HANG main thread blocked ~18507ms (phase: splash.route)
//
// Sampling technique (the same one crash reporters/APM SDKs use): suspend the
// main thread via its mach port, read pc/lr from ARM_THREAD_STATE64, walk the
// frame-pointer chain with vm_read_overwrite (fails gracefully on bad pointers
// instead of crashing), resume, and only THEN symbolicate with dladdr — dyld
// can take locks, so it must never run while main is suspended.
//
// No private API; DEBUG only; overhead is one async no-op per 100ms plus a few
// microseconds of suspension per sample during an already-visible hang.

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
    /// Additional waits before each in-hang stack sample (cumulative from the
    /// threshold: samples land ~1s, ~3s, ~8s into the hang).
    private let sampleDelays: [TimeInterval] = [0.75, 2.0, 5.0]

    private let startedLock = NSLock()
    private var started = false
    private var mainThreadPort: thread_act_t = 0

    /// Idempotent; call once from AppDelegate.didFinishLaunching (main thread —
    /// that's where the mach port for the MAIN thread is captured).
    func start() {
        startedLock.lock()
        defer { startedLock.unlock() }
        guard !started else { return }
        started = true
        mainThreadPort = pthread_mach_thread_np(pthread_self())

        let mainPort = mainThreadPort
        let delays = sampleDelays
        let thread = Thread { [log, hangThreshold, pingInterval] in
            while true {
                let sentAt = DispatchTime.now()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }

                if sem.wait(timeout: .now() + hangThreshold) == .timedOut {
                    // Main thread is blocked. Sample its stack at staged
                    // offsets while we wait for recovery, then report.
                    var recovered = false
                    for delay in delays where !recovered {
                        recovered = sem.wait(timeout: .now() + delay) != .timedOut
                        guard !recovered else { break }
                        let soFarMs = Int(Double(DispatchTime.now().uptimeNanoseconds - sentAt.uptimeNanoseconds) / 1_000_000)
                        let phase = StartupTimeline.lastMarkPhase
                        let frames = Self.captureStack(of: mainPort)
                        let header = "🧵HANG-STACK main blocked ~\(soFarMs)ms so far (phase: \(phase)) — main thread is in:"
                        print(header)
                        log.error("\(header, privacy: .public)")
                        for frame in frames {
                            print("   \(frame)")
                            log.error("   \(frame, privacy: .public)")
                        }
                    }
                    if !recovered { sem.wait() }

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

    // MARK: - Stack capture

    #if arch(arm64)

    /// Suspend `port`, collect pc/lr and walk the frame-pointer chain, resume,
    /// then symbolicate. Every stack-memory read goes through vm_read_overwrite
    /// so a torn/corrupt frame pointer fails the walk instead of crashing.
    private static func captureStack(of port: thread_act_t, maxFrames: Int = 48) -> [String] {
        var addresses: [UInt64] = []

        guard thread_suspend(port) == KERN_SUCCESS else {
            return ["<thread_suspend failed — no stack captured>"]
        }

        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &state) { statePtr in
            statePtr.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(port, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }

        if kr == KERN_SUCCESS {
            addresses.append(strippedAddress(state.__pc))
            let lr = strippedAddress(state.__lr)
            if lr != 0 { addresses.append(lr) }

            // Frame layout on arm64: fp → { previous fp, return address }.
            var fp = state.__fp
            var lastFP: UInt64 = 0
            while addresses.count < maxFrames,
                  fp != 0, fp % 8 == 0, fp > lastFP,
                  let frame = readFrame(at: fp) {
                let ret = strippedAddress(frame.returnAddress)
                guard ret > 0x1000 else { break }
                addresses.append(ret)
                lastFP = fp
                fp = frame.previousFP
            }
        }

        thread_resume(port)

        // Symbolicate ONLY after resume — dladdr may take dyld locks that the
        // suspended main thread could be holding.
        if kr != KERN_SUCCESS { return ["<thread_get_state failed — no stack captured>"] }
        return addresses.map(symbolicate)
    }

    private struct StackFrame {
        let previousFP: UInt64
        let returnAddress: UInt64
    }

    /// Crash-safe 16-byte read of a stack frame via the mach VM API.
    private static func readFrame(at address: UInt64) -> StackFrame? {
        var buffer = [UInt64](repeating: 0, count: 2)
        var outSize: vm_size_t = 0
        let kr = buffer.withUnsafeMutableBytes { raw -> kern_return_t in
            vm_read_overwrite(
                mach_task_self_,
                vm_address_t(address),
                vm_size_t(16),
                vm_address_t(UInt(bitPattern: raw.baseAddress)),
                &outSize
            )
        }
        guard kr == KERN_SUCCESS, outSize == 16 else { return nil }
        return StackFrame(previousFP: buffer[0], returnAddress: buffer[1])
    }

    /// Strip pointer-authentication / tag bits down to the canonical VA range.
    private static func strippedAddress(_ raw: UInt64) -> UInt64 {
        raw & 0x0000_007F_FFFF_FFFF
    }

    private static func symbolicate(_ address: UInt64) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: UInt(address)), &info) != 0 else {
            return String(format: "0x%llx", address)
        }
        let image = info.dli_fname.flatMap { (URL(fileURLWithPath: String(cString: $0)).lastPathComponent) as String? } ?? "???"
        if let sname = info.dli_sname {
            let symbol = String(cString: sname)
            let offset = address - UInt64(UInt(bitPattern: info.dli_saddr))
            return "\(image)  \(symbol) + \(offset)"
        }
        return String(format: "%@  0x%llx", image, address)
    }

    #else

    private static func captureStack(of port: thread_act_t, maxFrames: Int = 48) -> [String] {
        ["<stack capture unavailable on this architecture>"]
    }

    #endif
}
#endif

// MusicAnalysisProbeView.swift
// ChromaGlow — Debug builds only. Settings → Advanced → Music analysis probe.
//
// Times Apple's Music Understanding on a test song made up in memory (see
// MusicAnalysisProbe): the whole song, rhythm and structure alone, and the
// 4-second windows "the room is the band" would use. Copy the results and
// paste them into the session. No microphone, nothing saved, nothing sent.

#if DEBUG
import SwiftUI
import UIKit
#if canImport(MusicUnderstanding)
@_weakLinked import MusicUnderstanding
#endif

struct MusicAnalysisProbeView: View {
    @State private var lines: [String] = []
    @State private var running = false
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Times Apple's music analysis on a 2¼-minute test song made up on the phone. It doesn't use the microphone, and nothing is saved or sent. Plug in and leave the screen on; a run takes about a minute. To test the background, start it and then leave the app.")
                    .font(.subheadline)
                    .foregroundStyle(LuminousPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(running ? "Running…" : "Start") { start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(running)
                    Button(copied ? "Copied" : "Copy results") {
                        UIPasteboard.general.string = lines.joined(separator: "\n")
                        copied = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(lines.isEmpty || running)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(LuminousPalette.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .background(LuminousPalette.void.ignoresSafeArea())
        .navigationTitle("Music analysis probe")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func start() {
        running = true
        copied = false
        lines = []
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Music analysis probe")
        Task {
            await run()
            running = false
            UIApplication.shared.endBackgroundTask(backgroundTask)
        }
    }

    private func log(_ line: String) { lines.append(line) }

    private var state: String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "?"
        }
    }

    private var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }

    private func run() async {
        let device = UIDevice.current
        log("ChromaGlow music analysis probe — \(Date().formatted(date: .abbreviated, time: .standard))")
        log("\(device.model) · \(device.systemName) \(device.systemVersion) · thermal \(thermal) · low power \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        #if canImport(MusicUnderstanding)
        guard #available(iOS 27.0, *) else {
            log("Needs iOS 27.")
            return
        }
        let t0 = Date()
        let song = await Task.detached(priority: .userInitiated) { MusicAnalysisProbe.makeTestSong() }.value
        log(String(format: "Test song: %.0f s, %.0f BPM, %d sections, made in %.2f s",
                   song.duration, song.bpm, song.sectionStarts.count + 1, Date().timeIntervalSince(t0)))

        await step("Whole song, every analysis (first run)", song: song, types: nil)
        await step("Whole song, every analysis (second run)", song: song, types: nil)
        await step("Whole song, rhythm only", song: song, types: [.rhythm])
        await step("Whole song, structure only", song: song, types: [.structure])
        await windows(song: song, seconds: 4)
        await windows(song: song, seconds: 2)
        log("Done · thermal \(thermal) · app \(state)")
        #else
        log("This SDK has no Music Understanding.")
        #endif
    }

    #if canImport(MusicUnderstanding)
    @available(iOS 27.0, *)
    private func step(_ title: String, song: MusicAnalysisProbe.TestSong, types: Set<AnalysisType>?) async {
        do {
            let r = try await MusicAnalysisProbe.analyze(song, types: types)
            var line = String(format: "%@: %.2f s (%.0f× real time) · app %@ · thermal %@",
                              title, r.seconds, song.duration / max(r.seconds, 1e-3), state, thermal)
            if !r.beats.isEmpty {
                line += String(format: "\n   beats %d, F %.2f vs truth, BPM %@",
                               r.beats.count, MusicAnalysisProbe.beatF(reference: song.beats, found: r.beats),
                               r.bpm.map { String(format: "%.1f", $0) } ?? "—")
            }
            if types == nil || types?.contains(.structure) == true {
                let hits = MusicAnalysisProbe.boundaryHits(truth: song.sectionStarts, found: r.sectionStarts)
                line += String(format: "\n   sections found %d; %d of %d true section starts within 2 s (%@)",
                               r.sectionStarts.count + 1, hits, song.sectionStarts.count,
                               r.sectionStarts.map { String(format: "%.1f", $0) }.joined(separator: " "))
            }
            if !r.instruments.isEmpty { line += "\n   instruments: " + r.instruments.joined(separator: ", ") }
            log(line)
        } catch {
            log("\(title): failed — \(error)")
        }
    }

    @available(iOS 27.0, *)
    private func windows(song: MusicAnalysisProbe.TestSong, seconds: Double) async {
        var times: [Double] = []
        var failures = 0
        var start = 10.0
        while start + seconds < song.duration - 2 && times.count + failures < 12 {
            do {
                times.append(try await MusicAnalysisProbe.analyze(song, start: start, duration: seconds,
                                                                  types: [.instrumentActivity]).seconds)
            } catch {
                failures += 1
            }
            start += 10
        }
        let sorted = times.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        log(String(format: "%.0f s windows, instrument activity ×%d: median %.3f s, max %.3f s, %d failed · app %@ · thermal %@",
                   seconds, times.count, median, sorted.last ?? 0, failures, state, thermal))
    }
    #endif
}
#endif

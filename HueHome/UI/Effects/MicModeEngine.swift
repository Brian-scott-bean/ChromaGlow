// MicModeEngine.swift
// CastChroma — Mic Mode
//
// AVAudioEngine captures mic input → vDSP FFT extracts frequency bands →
// mapped to Hue grouped light brightness + color temperature in real time.
// Rate-limited to 10 commands/sec per Hue bridge spec.

import Foundation
import AVFoundation
import Accelerate
import SwiftUI

// MARK: - Color Mode

enum MicColorMode: String, CaseIterable, Identifiable {
    case reactive = "Reactive"
    case pulse    = "Pulse"
    case warm     = "Warm"
    case cool     = "Cool"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .reactive: return "waveform.path.ecg"
        case .pulse:    return "circle.fill"
        case .warm:     return "flame.fill"
        case .cool:     return "snowflake"
        }
    }

    var color: Color {
        switch self {
        case .reactive: return .purple
        case .pulse:    return Color(hue: 0.11, saturation: 0.9, brightness: 0.95)
        case .warm:     return .orange
        case .cool:     return .cyan
        }
    }
}

// MARK: - Engine

@Observable
@MainActor
final class MicModeEngine {

    // MARK: Published
    var isRunning        = false
    var permissionDenied = false
    var barHeights: [Float] = Array(repeating: 0, count: 20)
    var bassLevel: Float = 0
    var midLevel:  Float = 0
    var highLevel: Float = 0
    var overallLevel: Float = 0

    // MARK: Settings
    var sensitivity:      Double       = 1.0
    var colorMode:        MicColorMode = .reactive
    var selectedRoomIDs:  Set<String>  = []

    // MARK: Private — audio
    private var audioEngine: AVAudioEngine?
    private let bufferSize: AVAudioFrameCount = 2048

    // MARK: Private — smoothing
    private var sBars:    [Float] = Array(repeating: 0, count: 20)
    private var sBass:    Float   = 0
    private var sMid:     Float   = 0
    private var sHigh:    Float   = 0
    private var sOverall: Float   = 0

    // MARK: Private — rate limiting
    private var lastSent: Date = .distantPast
    private let sendInterval: TimeInterval = 0.1   // 10 fps

    // MARK: Dependency
    private weak var orchestrator: UnifiedOrchestrator?

    init(orchestrator: UnifiedOrchestrator) {
        self.orchestrator = orchestrator
    }

    // MARK: - Start / Stop

    func start() {
        Task { await requestAndStart() }
    }

    func stop() {
        // 1. Immediately prevent further processing
        isRunning   = false
        // 2. Remove the audio tap and stop the engine
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        // 3. Deactivate audio session — releases mic hardware
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // 4. Zero out all levels
        barHeights  = Array(repeating: 0, count: 20)
        sBars       = Array(repeating: 0, count: 20)
        bassLevel   = 0; midLevel = 0; highLevel = 0; overallLevel = 0
        sBass       = 0; sMid     = 0; sHigh     = 0; sOverall     = 0
    }

    private func requestAndStart() async {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            await startCapture()
        case .undetermined:
            let ok = await AVAudioApplication.requestRecordPermission()
            if ok { await startCapture() } else { permissionDenied = true }
        default:
            permissionDenied = true
        }
    }

    private func startCapture() async {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true)
        } catch { return }

        let eng  = AVAudioEngine()
        let node = eng.inputNode
        let fmt  = node.outputFormat(forBus: 0)

        node.installTap(onBus: 0, bufferSize: bufferSize, format: fmt) { [weak self] buf, _ in
            guard let self, self.isRunning else { return }
            self.process(buf, sampleRate: Float(fmt.sampleRate))
        }

        do {
            try eng.start()
            audioEngine = eng
            isRunning   = true
        } catch { return }
    }

    // MARK: - FFT Processing (audio thread → publish on MainActor)

    private func process(_ buffer: AVAudioPCMBuffer, sampleRate: Float) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n >= 64 else { return }

        // Nearest power-of-2 ≤ n
        let fftN   = 1 << Int(log2(Float(n)))
        let halfN  = fftN / 2
        let log2n  = vDSP_Length(log2(Float(fftN)))

        // Hann window
        var windowed = [Float](repeating: 0, count: fftN)
        var window   = [Float](repeating: 0, count: fftN)
        vDSP_hann_window(&window, vDSP_Length(fftN), Int32(vDSP_HANN_NORM))
        vDSP_vmul(data, 1, window, 1, &windowed, 1, vDSP_Length(fftN))

        // RMS
        var rms: Float = 0
        vDSP_rmsqv(windowed, 1, &rms, vDSP_Length(fftN))
        let overall = min(rms * Float(sensitivity) * 10.0, 1.0)

        // Pack into split complex
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        windowed.withUnsafeBufferPointer { wBuf in
            wBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
                vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(halfN))
            }
        }

        // FFT
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2)) else { return }
        defer { vDSP_destroy_fftsetup(setup) }
        var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

        // Magnitudes
        var mags = [Float](repeating: 0, count: halfN)
        vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(halfN))
        var scale: Float = 2.0 / Float(fftN)
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(halfN))

        let hzPerBin = sampleRate / Float(fftN)
        let bassEnd  = max(1, Int(200   / hzPerBin))
        let midEnd   = max(bassEnd + 1, Int(2000  / hzPerBin))
        let highEnd  = min(max(midEnd + 1, Int(16000 / hzPerBin)), halfN)

        // Band averages
        let bassSlice = Array(mags[1..<min(bassEnd, halfN)])
        let midSlice  = Array(mags[min(bassEnd, halfN)..<min(midEnd, halfN)])
        let highSlice = Array(mags[min(midEnd, halfN)..<min(highEnd, halfN)])

        func avg(_ a: [Float]) -> Float {
            guard !a.isEmpty else { return 0 }
            var v: Float = 0; vDSP_meanv(a, 1, &v, vDSP_Length(a.count)); return v
        }
        let bass = min(avg(bassSlice) * Float(sensitivity) * 30.0, 1.0)
        let mid  = min(avg(midSlice)  * Float(sensitivity) * 20.0, 1.0)
        let high = min(avg(highSlice) * Float(sensitivity) * 40.0, 1.0)

        // 20 log-spaced bars
        let minLog = log10(Float(20)); let maxLog = log10(Float(16000))
        var bars = [Float](repeating: 0, count: 20)
        for i in 0..<20 {
            let fLow  = pow(10, minLog + Float(i)   * (maxLog - minLog) / 20)
            let fHigh = pow(10, minLog + Float(i+1) * (maxLog - minLog) / 20)
            let bLow  = max(0, Int(fLow  / hzPerBin))
            let bHigh = min(halfN - 1, Int(fHigh / hzPerBin))
            guard bLow < bHigh else { continue }
            var peak: Float = 0
            vDSP_maxv(Array(mags[bLow...bHigh]), 1, &peak, vDSP_Length(bHigh - bLow))
            bars[i] = min(peak * Float(sensitivity) * 15.0, 1.0)
        }

        Task { @MainActor [weak self] in
            self?.applySmoothing(bars: bars, bass: bass, mid: mid, high: high, overall: overall)
            self?.sendLightUpdate()
        }
    }

    // MARK: - Smoothing

    private func applySmoothing(bars: [Float], bass: Float, mid: Float, high: Float, overall: Float) {
        let attack: Float = 0.4; let decay: Float = 0.88
        for i in 0..<20 {
            sBars[i] = bars[i] > sBars[i]
                ? sBars[i] * (1 - attack) + bars[i] * attack
                : sBars[i] * decay
        }
        func smooth(_ s: inout Float, _ new: Float, _ atk: Float, _ dec: Float) {
            s = new > s ? s * (1 - atk) + new * atk : s * dec
        }
        smooth(&sOverall, overall, 0.4, 0.92)
        smooth(&sBass,    bass,    0.5, 0.90)
        smooth(&sMid,     mid,     0.4, 0.90)
        smooth(&sHigh,    high,    0.5, 0.88)

        barHeights   = sBars
        overallLevel = sOverall
        bassLevel    = sBass
        midLevel     = sMid
        highLevel    = sHigh
    }

    // MARK: - Light Control (10 fps rate-limited)

    private func sendLightUpdate() {
        guard isRunning else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSent) >= sendInterval else { return }
        guard !selectedRoomIDs.isEmpty, let orc = orchestrator else { return }
        lastSent = now

        let rooms = orc.allRooms.filter { selectedRoomIDs.contains($0.id) }
        let bri   = max(2.0, Double(overallLevel) * 100.0)
        let on    = overallLevel > 0.03

        for room in rooms {
            guard let glID   = room.groupedLightID,
                  let client = orc.hueClient(for: room.bridgeID) else { continue }

            let mirek: Int
            switch colorMode {
            case .reactive:
                let w = Double(bassLevel), c = Double(highLevel)
                let ratio = w / max(w + c, 0.01)
                mirek = Int(153 + ratio * 297)   // 153 (cool) … 450 (warm)
            case .pulse:    mirek = 366
            case .warm:     mirek = 440
            case .cool:     mirek = 156
            }

            Task {
                try? await client.setGroupedLightEffect(
                    id:         glID,
                    on:         on,
                    brightness: bri,
                    xy:         nil,
                    mirek:      mirek,
                    duration:   80
                )
            }
        }
    }
}

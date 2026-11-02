// RoomSim.swift — play a clean recording "into a room": a small speaker, the
// room's echo (a measured room impulse response, convolved), the phone mic's
// band and background noise. Published numbers show a real room cutting one
// classic tracker's beat F from 0.92 to 0.65 — early reflections make false
// onsets — so the lab scores every song clean and through rooms.

import Accelerate
import Foundation

enum Condition: String, CaseIterable {
    /// The file as recorded.
    case line
    /// A home-like room's echo (measured: C50 ≥ 5 dB, RT60 ≤ 0.8 s), the phone
    /// mic's band, quiet noise (-30 dB).
    case room
    /// A small speaker (no deep bass) in a room, louder noise (-24 dB).
    case speaker
    /// A hall: long or dominant echo (lecture rooms, far from the speaker).
    case hall
}

enum RoomSim {
    /// The condition applied to `x` (48 kHz mono). `rir` is a measured room
    /// impulse response; `seed` picks the noise.
    static func apply(_ condition: Condition, to x: [Float], fs: Double, rir: [Float]?, seed: UInt64) -> [Float] {
        switch condition {
        case .line:
            return x
        case .room, .hall:
            var y = rir.map { withAir(x, convolve(x, $0), fs: fs) } ?? x
            y = micBand(y, fs: fs)
            return addNoise(matchRMS(y, to: x), db: -30, seed: seed)
        case .speaker:
            var y = Synth.highPass(x, fs: fs, cutoff: 180)
            y = Synth.lowPass(y, fs: fs, cutoff: 12_000)
            if let rir { y = withAir(y, convolve(y, rir), fs: fs) }
            y = micBand(y, fs: fs)
            return addNoise(matchRMS(y, to: x), db: -24, seed: seed)
        }
    }

    /// The measured rooms were recorded at 16 kHz, so their response stops at
    /// 8 kHz and would erase every hi-hat. Above 7.5 kHz a real room adds
    /// little but the direct sound (walls and air absorb the top octave
    /// first), so the direct sound's top octave is added back.
    static func withAir(_ dry: [Float], _ wet: [Float], fs: Double) -> [Float] {
        let air = Synth.highPass(dry, fs: fs, cutoff: 7500)
        var out = wet
        for i in 0..<min(out.count, air.count) { out[i] += air[i] }
        return out
    }

    /// The band the lab's synthetic rooms already use (Synth.render).
    static func micBand(_ x: [Float], fs: Double) -> [Float] {
        Synth.lowPass(Synth.highPass(x, fs: fs, cutoff: 120), fs: fs, cutoff: 9000)
    }

    static func rms(_ x: [Float]) -> Float {
        var r: Float = 0
        vDSP_rmsqv(x, 1, &r, vDSP_Length(x.count))
        return r
    }

    static func matchRMS(_ y: [Float], to x: [Float]) -> [Float] {
        let ry = rms(y), rx = rms(x)
        guard ry > 0 else { return y }
        return y.map { $0 * rx / ry }
    }

    /// Pink noise `db` below the signal's RMS.
    static func addNoise(_ x: [Float], db: Double, seed: UInt64) -> [Float] {
        var rng = SplitMix(s: seed)
        let pink = Synth.pinkNoise(count: x.count, rng: &rng)
        let target = Double(rms(x)) * pow(10, db / 20)
        let g = Float(target / Double(max(rms(pink), 1e-9)))
        var out = x
        for i in 0..<out.count { out[i] += pink[i] * g }
        return out
    }

    /// An impulse response ready to convolve: starts at the direct sound
    /// (the propagation delay before it is cut, so annotations stay aligned)
    /// and is scaled to unit peak.
    static func prepareRIR(_ raw: [Float], fs: Double, maxSeconds: Double = 1.5) -> [Float] {
        guard !raw.isEmpty else { return [1] }
        var peak = 0
        for i in 0..<raw.count where abs(raw[i]) > abs(raw[peak]) { peak = i }
        let start = max(0, peak - Int(0.001 * fs))
        let end = min(raw.count, start + Int(maxSeconds * fs))
        let p = abs(raw[peak])
        return raw[start..<end].map { $0 / max(p, 1e-9) }
    }

    /// Linear convolution, cut to the input's length (overlap-add FFT).
    static func convolve(_ x: [Float], _ h: [Float]) -> [Float] {
        guard !x.isEmpty, !h.isEmpty else { return x }
        let m = h.count
        let log2n = vDSP_Length(ceil(log2(Double(2 * m))))
        let nfft = 1 << Int(log2n)
        let block = nfft - m + 1
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return x }
        defer { vDSP_destroy_fftsetup(setup) }

        var hr = [Float](repeating: 0, count: nfft), hi = [Float](repeating: 0, count: nfft)
        for i in 0..<m { hr[i] = h[i] }
        fft(&hr, &hi, setup: setup, log2n: log2n, direction: FFTDirection(FFT_FORWARD))

        var out = [Float](repeating: 0, count: x.count + m - 1)
        var xr = [Float](repeating: 0, count: nfft), xi = [Float](repeating: 0, count: nfft)
        let scale = 1 / Float(nfft)
        var start = 0
        while start < x.count {
            let len = min(block, x.count - start)
            for i in 0..<nfft { xr[i] = i < len ? x[start + i] : 0; xi[i] = 0 }
            fft(&xr, &xi, setup: setup, log2n: log2n, direction: FFTDirection(FFT_FORWARD))
            for i in 0..<nfft {
                let r = xr[i] * hr[i] - xi[i] * hi[i]
                let im = xr[i] * hi[i] + xi[i] * hr[i]
                xr[i] = r; xi[i] = im
            }
            fft(&xr, &xi, setup: setup, log2n: log2n, direction: FFTDirection(FFT_INVERSE))
            let n = min(nfft, out.count - start)
            for i in 0..<n { out[start + i] += xr[i] * scale }
            start += block
        }
        return Array(out.prefix(x.count))
    }

    private static func fft(_ re: inout [Float], _ im: inout [Float], setup: FFTSetup, log2n: vDSP_Length,
                            direction: FFTDirection) {
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, direction)
            }
        }
    }
}

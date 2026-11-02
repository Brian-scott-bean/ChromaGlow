// Corpus.swift — real recordings and their annotations for the beat lab.
//
// The audio never enters the repo (it is public, and README §8 rules that
// recordings never go into it). It lives on the Dev drive:
//
//   /Volumes/Dev/Datasets/chromaglow-beat-corpus/      (or $CHROMAGLOW_CORPUS)
//     raw/<set>/…            each dataset as downloaded, with SOURCE.txt
//     annotations/<set>/…    our plain-text annotations, written by -import
//     manifest.json          every track: audio, annotations, licence, SHA-256
//
// Plain-text annotation formats (one event per line, `#` comments):
//   .beats   `time beatInBar`   beatInBar 1 = a downbeat, 0 = not known
//   .drums   `time kind [velocity]`  kick | snare | hat | tom | cymbal | sidestick |
//                              hatpedal | other; velocity 1…127 when known
//   .lab     `start end label`  sections (EDM labels: intro build drop break outro)

import AVFoundation
import CryptoKit
import Foundation

struct CorpusTrack: Codable {
    var id: String
    var set: String
    /// Relative to the corpus root.
    var audio: String
    var licence: String
    var source: String
    var beats: String?
    var drums: String?
    var sections: String?
    var sha256: String?
    var meta: [String: String]?
}

struct CorpusManifest: Codable {
    var tracks: [CorpusTrack]
    /// Measured room impulse responses (relative paths): home-like rooms (C50
    /// ≥ 5 dB, RT60 ≤ 0.8 s) for `room` and `speaker`, and halls for `hall`.
    var rirs: [String]?
    var hallRirs: [String]?
}

struct Beat { var time: Double; var beatInBar: Int }
struct DrumHit { var time: Double; var kind: String; var velocity: Int = 0 }
struct Section { var start: Double; var end: Double; var label: String }

enum Corpus {
    static var root: URL {
        if let env = ProcessInfo.processInfo.environment["CHROMAGLOW_CORPUS"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: "/Volumes/Dev/Datasets/chromaglow-beat-corpus")
    }

    static var manifestURL: URL { root.appendingPathComponent("manifest.json") }

    static func loadManifest() throws -> CorpusManifest {
        try JSONDecoder().decode(CorpusManifest.self, from: Data(contentsOf: manifestURL))
    }

    static func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    // MARK: Audio

    /// Any file AVFoundation reads, as 48 kHz mono float.
    static func loadAudio(_ url: URL, fs: Double = 48_000) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fs, channels: 1,
                                            interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "Corpus", code: 1, userInfo: [NSLocalizedDescriptionKey: "no converter for \(url.lastPathComponent)"])
        }
        converter.downmix = true
        let chunk: AVAudioFrameCount = 1 << 16
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * fs / inFormat.sampleRate) + 4096)
        var finished = false
        var readError: Error?
        let outCapacity = AVAudioFrameCount(Double(chunk) * fs / inFormat.sampleRate) + 1024
        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { break }
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, inStatus in
                // Reading at the end throws eofErr (-39), so stop before it.
                if finished || file.framePosition >= file.length {
                    finished = true
                    inStatus.pointee = .endOfStream
                    return nil
                }
                let wanted = AVAudioFrameCount(min(Int64(chunk), file.length - file.framePosition))
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else {
                    inStatus.pointee = .endOfStream; return nil
                }
                do { try file.read(into: inBuf, frameCount: wanted) } catch { readError = error }
                if inBuf.frameLength == 0 {
                    finished = true
                    inStatus.pointee = .endOfStream
                    return nil
                }
                inStatus.pointee = .haveData
                return inBuf
            }
            if let convError { throw convError }
            if let readError { throw readError }
            if outBuf.frameLength > 0, let p = outBuf.floatChannelData?[0] {
                out.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream || status == .error || (finished && outBuf.frameLength == 0) { break }
        }
        return out
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Annotations

    static func lines(_ url: URL) throws -> [[String]] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }).map(String.init) }
    }

    static func readBeats(_ url: URL) throws -> [Beat] {
        try lines(url).compactMap { f in
            guard let t = f.first.flatMap(Double.init) else { return nil }
            return Beat(time: t, beatInBar: f.count > 1 ? Int(Double(f[1]) ?? 0) : 0)
        }.sorted { $0.time < $1.time }
    }

    static func readDrums(_ url: URL) throws -> [DrumHit] {
        try lines(url).compactMap { f in
            guard f.count >= 2, let t = Double(f[0]) else { return nil }
            return DrumHit(time: t, kind: f[1], velocity: f.count > 2 ? Int(f[2]) ?? 0 : 0)
        }.sorted { $0.time < $1.time }
    }

    static func readSections(_ url: URL) throws -> [Section] {
        try lines(url).compactMap { f in
            guard f.count >= 3, let s = Double(f[0]), let e = Double(f[1]) else { return nil }
            return Section(start: s, end: e, label: f[2...].joined(separator: " "))
        }
    }

    static func writeBeats(_ beats: [Beat], to url: URL, header: String) throws {
        var s = "# \(header)\n# time beatInBar (1 = downbeat, 0 = unknown)\n"
        for b in beats { s += String(format: "%.4f %d\n", b.time, b.beatInBar) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeDrums(_ hits: [DrumHit], to url: URL, header: String) throws {
        var s = "# \(header)\n# time kind velocity\n"
        for h in hits { s += String(format: "%.4f %@ %d\n", h.time, h.kind, h.velocity) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeSections(_ sections: [Section], to url: URL, header: String) throws {
        var s = "# \(header)\n# start end label\n"
        for x in sections { s += String(format: "%.4f %.4f %@\n", x.start, x.end, x.label) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: url, atomically: true, encoding: .utf8)
    }
}

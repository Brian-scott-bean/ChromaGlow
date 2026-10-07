// SongMemory.swift
// ChromaGlow — Core/Music (Play Along P5)
//
// Where each song's beats fall, remembered. A music service says where a
// track is (its position) and a tempo lookup says how fast it goes — but
// neither says where the beats sit: songs rarely start on a beat. The
// microphone finds that out while the song plays (BeatClock's service
// offset); the song memory keeps it, so the next play of the same song on
// the same speakers locks at once — on the beat and on the one — instead of
// after seconds of listening.
//
// - Key: the tempo cache's track key plus the phone's output route, hashed
//   (SHA-256), so the file holds no readable listening history. The route
//   is in the key because the offset is "as heard in the room": other
//   speakers, other delay. New speakers relearn in seconds.
// - Value: derived numbers only (tempo, beat offset, the one, confidences)
//   — never audio, never names.
// - Learning: only while a music service drives the clock AND the
//   microphone keeps confirming the offset; a circular mean weighted by
//   phase confidence, stored once 8 bars agree and refreshed every 16 more.
// - Persistence: the tempo-cache.json idiom — tolerant decode, `.atomic`,
//   bounded (oldest out).
//
// It serves only the sync it was learned for (Apple's Media Player
// guidance: don't gather information about the user's audio content for
// any other purpose).

import AVFAudio
import CryptoKit
import Foundation

@MainActor
final class SongMemory {

    static let shared = SongMemory()

    struct Entry: Codable, Equatable {
        /// The tempo the offset was learned at (the service's).
        var bpm: Double
        /// Seconds from track t=0 to its first beat, in [0, one beat) — as
        /// heard in the room.
        var beatOffset: Double
        /// Which beat after `beatOffset` is the one, 0..<beatsPerBar (nil:
        /// the bar was never sure).
        var downbeatSlot: Int?
        var beatsPerBar: Int
        var phaseConfidence: Double
        var barConfidence: Double
        var observations: Int
        var updatedAt: Date

        init(bpm: Double, beatOffset: Double, downbeatSlot: Int?, beatsPerBar: Int, phaseConfidence: Double,
             barConfidence: Double, observations: Int, updatedAt: Date) {
            self.bpm = bpm
            self.beatOffset = beatOffset
            self.downbeatSlot = downbeatSlot
            self.beatsPerBar = beatsPerBar
            self.phaseConfidence = phaseConfidence
            self.barConfidence = barConfidence
            self.observations = observations
            self.updatedAt = updatedAt
        }

        enum CodingKeys: String, CodingKey {
            case bpm, beatOffset, downbeatSlot, beatsPerBar, phaseConfidence, barConfidence, observations, updatedAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bpm = try c.decode(Double.self, forKey: .bpm)
            beatOffset = try c.decode(Double.self, forKey: .beatOffset)
            downbeatSlot = try? c.decode(Int.self, forKey: .downbeatSlot)
            beatsPerBar = (try? c.decode(Int.self, forKey: .beatsPerBar)) ?? 4
            phaseConfidence = (try? c.decode(Double.self, forKey: .phaseConfidence)) ?? 0
            barConfidence = (try? c.decode(Double.self, forKey: .barConfidence)) ?? 0
            observations = (try? c.decode(Int.self, forKey: .observations)) ?? 0
            updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? .distantPast
        }
    }

    /// What a drive takes from a remembered song.
    struct Recall: Equatable {
        /// Track t=0 to the start of a bar (mod one bar) when the one is
        /// known; to a beat (mod one beat) when it is not.
        var offset: Double
        var barKnown: Bool
    }

    /// Mean resultant length the offsets must reach before they are stored.
    static let consistency = 0.9
    static let barsToStore = 8.0
    static let barsToRefresh = 16.0
    static let minObservations = 8
    /// A remembered offset only fits the tempo it was learned at.
    static let bpmTolerance = 0.05
    /// Share of the bar votes one beat must win to be stored as the one.
    static let barMajority = 0.75
    static let barConfidenceToStore = 0.5

    private struct FileContents: Codable {
        var entries: [String: Entry] = [:]

        init() {}

        enum CodingKeys: String, CodingKey { case entries }

        /// One damaged entry costs that song, not the whole memory.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let raw = (try? c.decode([String: Lenient].self, forKey: .entries)) ?? [:]
            entries = raw.compactMapValues(\.entry)
        }

        private struct Lenient: Decodable {
            let entry: Entry?
            init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
        }
    }

    /// The song being learned right now (in memory only).
    private struct Learning {
        let key: String
        let bpm: Double
        let beatsPerBar: Int
        let first: Double
        var cosSum = 0.0
        var sinSum = 0.0
        var weight = 0.0
        var slotVotes: [Double]
        var phaseConfidence = 0.0
        var barConfidence = 0.0
        var count = 0
        var countAtStore = 0
        var storedAt: Double?

        init(key: String, bpm: Double, beatsPerBar: Int, first: Double) {
            self.key = key
            self.bpm = bpm
            self.beatsPerBar = beatsPerBar
            self.first = first
            slotVotes = Array(repeating: 0, count: beatsPerBar)
        }
    }

    private let fileURL: URL?
    private let maxEntries: Int
    private let now: () -> Date
    private var contents: FileContents?
    private var learning: Learning?

    nonisolated static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("song-memory.json")
    }

    /// `fileURL` nil keeps the memory in this process only (tests).
    init(fileURL: URL? = SongMemory.defaultFileURL, maxEntries: Int = 1000, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.maxEntries = max(1, maxEntries)
        self.now = now
    }

    // MARK: Keys

    /// The hashed key for a track on an output route.
    nonisolated static func key(for query: TempoQuery, route: String) -> String {
        let digest = SHA256.hash(data: Data("\(query.cacheKey)\u{1F}route:\(route)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The route fingerprint as last seen — refreshed off the main thread at
    /// start and on every route change. The drive reads it once a second and
    /// must never wait on the audio session ("unknown" until the first read
    /// lands: that drive simply finds nothing remembered).
    nonisolated static func cachedRoute() -> String { RouteCache.shared.value }

    /// Start the first route read early (the music session's activation).
    nonisolated static func primeRouteCache() { _ = RouteCache.shared }

    /// The phone's output route as a stable fingerprint: built-in speaker and
    /// receiver count as one; headphones, Bluetooth, AirPlay and car audio
    /// keep their port identity. Asks the audio session: not on the main thread.
    nonisolated static func currentRoute() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else { return "none" }
        return outputs.map { port -> String in
            switch port.portType {
            case .builtInSpeaker, .builtInReceiver: return "builtIn"
            default: return "\(port.portType.rawValue)#\(port.uid)"
            }
        }
        .sorted()
        .joined(separator: ",")
    }

    // MARK: Recall

    /// The remembered grid for `key` at `bpm` (nil: never learned here, or
    /// learned at another tempo).
    func recall(_ key: String, bpm: Double) -> Recall? {
        guard bpm > 0, bpm.isFinite, let entry = load().entries[key], entry.bpm.isFinite,
              abs(entry.bpm - bpm) <= Self.bpmTolerance, entry.beatOffset.isFinite else { return nil }
        let beat = 60 / bpm
        let offset = Self.wrapped(entry.beatOffset, beat)
        if let slot = entry.downbeatSlot, (0..<max(1, entry.beatsPerBar)).contains(slot) {
            return Recall(offset: offset + Double(slot) * beat, barKnown: true)
        }
        return Recall(offset: offset, barKnown: false)
    }

    /// Stored entry (test hook and Debug HUD).
    func entry(_ key: String) -> Entry? { load().entries[key] }

    var count: Int { load().entries.count }

    // MARK: Learning

    /// One confirmed observation of where the grid sits on the track:
    /// `barOffset` is track t=0 to a bar start, modulo one bar, at the
    /// service's `bpm`. Call only while the microphone confirms the offset
    /// (`BeatClock.confirmedServiceOffset`). `t` is host time.
    func observe(_ key: String, bpm: Double, barOffset: Double, beatsPerBar: Int,
                 phaseConfidence: Double, barConfidence: Double, at t: Double) {
        guard bpm >= 20, bpm <= 300, barOffset.isFinite, t.isFinite, (1...16).contains(beatsPerBar),
              phaseConfidence.isFinite, phaseConfidence > 0, barConfidence.isFinite else { return }
        let continuing = learning.map {
            $0.key == key && abs($0.bpm - bpm) <= Self.bpmTolerance && $0.beatsPerBar == beatsPerBar
        } ?? false
        if !continuing {
            // Another song, route or grid: start over.
            var fresh = Learning(key: key, bpm: bpm, beatsPerBar: beatsPerBar, first: t)
            fresh.phaseConfidence = Self.clamp01(phaseConfidence)
            fresh.barConfidence = Self.clamp01(barConfidence)
            learning = fresh
        }
        guard var run = learning else { return }

        let beat = 60 / bpm
        let bar = beat * Double(beatsPerBar)
        let barPosition = Self.wrapped(barOffset, bar)
        let angle = 2 * Double.pi * Self.wrapped(barPosition, beat) / beat
        let w = min(1, phaseConfidence)
        // A slowly forgetting circular mean: an early wobble fades out.
        run.cosSum = run.cosSum * 0.95 + w * cos(angle)
        run.sinSum = run.sinSum * 0.95 + w * sin(angle)
        run.weight = run.weight * 0.95 + w
        let mean = Self.meanOffset(run, beat: beat)
        // Which beat of the bar starts it, voted (and quickly forgotten, so a
        // re-labelled bar — the user tapped the one — takes over).
        let slot = Self.slot(of: barPosition, beatOffset: mean, beat: beat, beatsPerBar: beatsPerBar)
        for i in run.slotVotes.indices { run.slotVotes[i] *= 0.8 }
        run.slotVotes[slot] += w * Self.clamp01(barConfidence)
        run.phaseConfidence += (Self.clamp01(phaseConfidence) - run.phaseConfidence) * 0.2
        run.barConfidence += (Self.clamp01(barConfidence) - run.barConfidence) * 0.2
        run.count += 1
        learning = run

        let resultant = run.weight > 0 ? hypot(run.cosSum, run.sinSum) / run.weight : 0
        guard run.count >= Self.minObservations, resultant >= Self.consistency,
              t - run.first >= Self.barsToStore * bar else { return }
        if let storedAt = run.storedAt, t - storedAt < Self.barsToRefresh * bar { return }
        store(run, beatOffset: mean, at: t)
    }

    private func store(_ run: Learning, beatOffset: Double, at t: Double) {
        var file = load()
        let previous = file.entries[run.key]
        let total = run.slotVotes.reduce(0, +)
        var downbeat: Int?
        if total > 0, run.barConfidence >= Self.barConfidenceToStore,
           let best = run.slotVotes.indices.max(by: { run.slotVotes[$0] < run.slotVotes[$1] }),
           run.slotVotes[best] / total >= Self.barMajority {
            downbeat = best
        } else if let previous, previous.beatsPerBar == run.beatsPerBar, abs(previous.bpm - run.bpm) <= Self.bpmTolerance,
                  Self.circularDistance(previous.beatOffset, beatOffset, period: 60 / run.bpm) < 0.02 {
            // Same beats as last time and no new opinion on the one: keep it.
            downbeat = previous.downbeatSlot
        }
        file.entries[run.key] = Entry(bpm: run.bpm, beatOffset: beatOffset, downbeatSlot: downbeat,
                                      beatsPerBar: run.beatsPerBar, phaseConfidence: run.phaseConfidence,
                                      barConfidence: run.barConfidence,
                                      observations: (previous?.observations ?? 0) + run.count - run.countAtStore,
                                      updatedAt: now())
        while file.entries.count > maxEntries {
            guard let oldest = file.entries.min(by: { $0.value.updatedAt < $1.value.updatedAt }) else { break }
            file.entries.removeValue(forKey: oldest.key)
        }
        persist(file)
        learning?.storedAt = t
        learning?.countAtStore = run.count
    }

    // MARK: Maths

    private static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

    private static func wrapped(_ x: Double, _ m: Double) -> Double {
        guard m > 0, x.isFinite else { return 0 }
        let r = x.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + m : r
    }

    private static func meanOffset(_ run: Learning, beat: Double) -> Double {
        guard run.weight > 0 else { return 0 }
        let angle = wrapped(atan2(run.sinSum, run.cosSum), 2 * Double.pi)
        return wrapped(angle / (2 * Double.pi) * beat, beat)
    }

    /// The beat of the bar (0..<beatsPerBar after `beatOffset`) a bar start
    /// at `barPosition` falls on, robust to jitter around the beat line.
    private static func slot(of barPosition: Double, beatOffset: Double, beat: Double, beatsPerBar: Int) -> Int {
        let k = Int(((barPosition - beatOffset) / beat).rounded())
        return ((k % beatsPerBar) + beatsPerBar) % beatsPerBar
    }

    private static func circularDistance(_ a: Double, _ b: Double, period: Double) -> Double {
        let d = wrapped(a - b, period)
        return min(d, period - d)
    }

    // MARK: Persistence (tempo-cache idiom: tolerant decode, .atomic)

    private func load() -> FileContents {
        if let contents { return contents }
        var loaded = FileContents()
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(FileContents.self, from: data) {
            loaded = decoded   // missing or corrupt → start clean, never throw
        }
        contents = loaded
        return loaded
    }

    private func persist(_ file: FileContents) {
        contents = file
        guard let fileURL, let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // .atomic ONLY — never pair with .withoutOverwriting (M-13 crash class).
        try? data.write(to: fileURL, options: [.atomic])
    }
}

/// The output-route fingerprint, kept current from a utility queue.
private final class RouteCache: @unchecked Sendable {
    static let shared = RouteCache()

    private let lock = NSLock()
    private var cached = "unknown"
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                          object: nil, queue: nil) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let route = SongMemory.currentRoute()
            guard let self else { return }
            self.lock.lock()
            self.cached = route
            self.lock.unlock()
        }
    }
}

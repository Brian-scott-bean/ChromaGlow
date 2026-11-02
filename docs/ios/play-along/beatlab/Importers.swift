// Importers.swift — turn each downloaded dataset into the lab's plain-text
// annotations and one manifest. Reads only; never runs anything from a
// download. Audio stays where it was downloaded (raw/<set>/…).
//
//   run.sh -import            every set found under raw/
//
// Sets (all allow commercial use; licences verified on each set's page, see
// raw/<set>/SOURCE.txt):
//   gmd        Groove MIDI Dataset — drum performances to a click; beats from
//              the MIDI tempo, kick/snare/hat from the notes. Only "beat"
//              takes in 4/4 that have audio (the 2-bar fills are too short).
//   slakh      BabySlakh — full multi-instrument mixes rendered from MIDI;
//              beats from the tempo map, drums from channel 10.
//   guitarset  GuitarSet — solo acoustic guitar with annotated beats/bars.
//   candombe   Candombe — Afro-Uruguayan drumming with beats/downbeats.
//   rirs       BUT ReverbDB — measured room impulse responses, sorted into
//              home-like rooms and halls (16 kHz, 1 s: see RoomSim for how
//              the top octave is kept).
// Not imported: the EDM drop set (Yadati et al.) — its per-track licences
// aren't recorded, and some SoundCloud CC licences forbid commercial use.

import AudioToolbox
import Foundation

// MARK: - MIDI (AudioToolbox's own reader)

struct MidiNote { var time: Double; var note: UInt8; var velocity: UInt8; var channel: UInt8; var track: Int }

struct MidiFile {
    var notes: [MidiNote]
    /// Beats of the tempo map in quarter notes, numbered in bars of the
    /// file's first time signature (0 when it isn't n/4).
    var beats: [Beat]
    var length: Double
}

enum Midi {
    static func read(_ url: URL, lengthSeconds: Double? = nil) throws -> MidiFile {
        var seqOpt: MusicSequence?
        guard NewMusicSequence(&seqOpt) == noErr, let seq = seqOpt else { throw err("sequence") }
        defer { DisposeMusicSequence(seq) }
        let status = MusicSequenceFileLoad(seq, url as CFURL, .midiType, MusicSequenceLoadFlags())
        guard status == noErr else { throw err("load \(url.lastPathComponent): \(status)") }

        var notes: [MidiNote] = []
        var lengthBeats: MusicTimeStamp = 0
        var trackCount: UInt32 = 0
        MusicSequenceGetTrackCount(seq, &trackCount)
        for ti in 0..<trackCount {
            var trackOpt: MusicTrack?
            MusicSequenceGetIndTrack(seq, ti, &trackOpt)
            guard let track = trackOpt else { continue }
            var len: MusicTimeStamp = 0
            var size = UInt32(MemoryLayout<MusicTimeStamp>.size)
            MusicTrackGetProperty(track, kSequenceTrackProperty_TrackLength, &len, &size)
            lengthBeats = max(lengthBeats, len)
            eachEvent(track) { beat, type, data in
                guard type == kMusicEventType_MIDINoteMessage, let data else { return }
                let m = data.assumingMemoryBound(to: MIDINoteMessage.self).pointee
                guard m.velocity > 0 else { return }
                var secs: Float64 = 0
                MusicSequenceGetSecondsForBeats(seq, beat, &secs)
                notes.append(MidiNote(time: secs, note: m.note, velocity: m.velocity, channel: m.channel, track: Int(ti)))
            }
        }

        // Time signatures (meta 0x58) on the tempo track. A file that changes
        // metre gets no bar numbers (BabySlakh has 2/4 and 1/4 bars).
        var numerator = 4, denominator = 4
        var signatures = Set<Int>()
        var tempoOpt: MusicTrack?
        MusicSequenceGetTempoTrack(seq, &tempoOpt)
        if let tempo = tempoOpt {
            var found = false
            eachEvent(tempo) { _, type, data in
                guard type == kMusicEventType_Meta, let data else { return }
                // MIDIMetaEvent is variable-length: the bytes follow `data`.
                let typeOff = MemoryLayout<MIDIMetaEvent>.offset(of: \MIDIMetaEvent.metaEventType)!
                let lenOff = MemoryLayout<MIDIMetaEvent>.offset(of: \MIDIMetaEvent.dataLength)!
                let dataOff = MemoryLayout<MIDIMetaEvent>.offset(of: \MIDIMetaEvent.data)!
                guard data.load(fromByteOffset: typeOff, as: UInt8.self) == 0x58,
                      data.load(fromByteOffset: lenOff, as: UInt32.self) >= 2 else { return }
                let num = Int(data.load(fromByteOffset: dataOff, as: UInt8.self))
                let den = 1 << Int(data.load(fromByteOffset: dataOff + 1, as: UInt8.self))
                signatures.insert(num * 100 + den)
                if !found { numerator = num; denominator = den; found = true }
            }
        }

        var lengthSecs: Float64 = 0
        MusicSequenceGetSecondsForBeats(seq, lengthBeats, &lengthSecs)
        let length = lengthSeconds ?? lengthSecs
        var beats: [Beat] = []
        var b = 0.0
        while true {
            var secs: Float64 = 0
            MusicSequenceGetSecondsForBeats(seq, b, &secs)
            if secs > length + 1e-6 { break }
            let inBar = denominator == 4 && numerator > 0 && signatures.count <= 1 ? Int(b) % numerator + 1 : 0
            beats.append(Beat(time: secs, beatInBar: inBar))
            b += 1
        }
        return MidiFile(notes: notes.sorted { $0.time < $1.time }, beats: beats, length: length)
    }

    private static func eachEvent(_ track: MusicTrack,
                                  _ body: (MusicTimeStamp, MusicEventType, UnsafeRawPointer?) -> Void) {
        var itOpt: MusicEventIterator?
        guard NewMusicEventIterator(track, &itOpt) == noErr, let it = itOpt else { return }
        defer { DisposeMusicEventIterator(it) }
        var has: DarwinBoolean = false
        MusicEventIteratorHasCurrentEvent(it, &has)
        while has.boolValue {
            var beat: MusicTimeStamp = 0
            var type: MusicEventType = 0
            var data: UnsafeRawPointer?
            var size: UInt32 = 0
            MusicEventIteratorGetEventInfo(it, &beat, &type, &data, &size)
            body(beat, type, data)
            MusicEventIteratorNextEvent(it)
            MusicEventIteratorHasCurrentEvent(it, &has)
        }
    }

    static func err(_ s: String) -> NSError { NSError(domain: "Midi", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}

/// General MIDI percussion (and the Roland TD-11 notes Groove MIDI uses) to
/// the lab's drum kinds.
func drumKind(_ note: UInt8) -> String {
    switch note {
    case 35, 36: return "kick"
    case 38, 39, 40: return "snare"
    case 37: return "sidestick"
    case 44: return "hatpedal"
    case 22, 26, 42, 46: return "hat"
    case 41, 43, 45, 47, 48, 50, 58: return "tom"
    case 49, 51, 52, 53, 55, 57, 59: return "cymbal"
    default: return "other"
    }
}

// MARK: - Import

func importCorpus(_ args: [String]) {
    let raw = Corpus.root.appendingPathComponent("raw")
    var tracks: [CorpusTrack] = []
    var rirs: [String] = [], halls: [String] = []
    let fm = FileManager.default
    func exists(_ set: String) -> URL? {
        let u = raw.appendingPathComponent(set)
        return fm.fileExists(atPath: u.path) ? u : nil
    }
    func licence(_ set: URL, fallback: String) -> String {
        guard let text = try? String(contentsOf: set.appendingPathComponent("SOURCE.txt"), encoding: .utf8) else { return fallback }
        for line in text.split(whereSeparator: \.isNewline) where line.lowercased().hasPrefix("licen") {
            return String(line.split(separator: ":", maxSplits: 1).last ?? Substring(fallback)).trimmingCharacters(in: .whitespaces)
        }
        return fallback
    }
    if let dir = exists("groove-midi") { tracks += importGMD(dir, licence: licence(dir, fallback: "CC BY 4.0")) }
    if let dir = exists("babyslakh") { tracks += importSlakh(dir, licence: licence(dir, fallback: "CC BY 4.0")) }
    if let dir = exists("guitarset") { tracks += importGuitarSet(dir, licence: licence(dir, fallback: "CC BY 4.0")) }
    if let dir = exists("candombe") { tracks += importCandombe(dir, licence: licence(dir, fallback: "CC BY 4.0")) }
    if let dir = exists("but-reverbdb") { (rirs, halls) = importRIRs(dir) }
    let manifest = CorpusManifest(tracks: tracks, rirs: rirs, hallRirs: halls)
    do {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: Corpus.manifestURL)
    } catch { print("could not write the manifest: \(error)") }
    let bySet = Dictionary(grouping: tracks, by: \.set).mapValues(\.count)
    print("manifest: \(tracks.count) tracks \(bySet.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")); \(rirs.count) home-like rooms, \(halls.count) halls")
}

/// A relative path under the corpus root.
func rel(_ url: URL) -> String {
    let root = Corpus.root.standardizedFileURL.path
    let p = url.standardizedFileURL.path
    return p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : p
}

func annotationURL(_ set: String, _ id: String, _ ext: String) -> URL {
    Corpus.root.appendingPathComponent("annotations/\(set)/\(id).\(ext)")
}

func files(under dir: URL, ext: String) -> [URL] {
    guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
    var out: [URL] = []
    for case let u as URL in e where u.pathExtension.lowercased() == ext { out.append(u) }
    return out.sorted { $0.path < $1.path }
}

// MARK: Groove MIDI

func importGMD(_ dir: URL, licence: String) -> [CorpusTrack] {
    guard let info = files(under: dir, ext: "csv").first(where: { $0.lastPathComponent == "info.csv" }),
          let text = try? String(contentsOf: info, encoding: .utf8) else {
        print("gmd: no info.csv"); return []
    }
    let base = info.deletingLastPathComponent()
    let rows = text.split(whereSeparator: \.isNewline).map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    guard let header = rows.first else { return [] }
    func col(_ name: String) -> Int? { header.firstIndex(of: name) }
    guard let cMidi = col("midi_filename"), let cAudio = col("audio_filename"), let cType = col("beat_type"),
          let cSig = col("time_signature"), let cStyle = col("style"), let cBPM = col("bpm") else {
        print("gmd: unexpected columns \(header)"); return []
    }
    var out: [CorpusTrack] = []
    for r in rows.dropFirst() where r.count == header.count {
        guard r[cType] == "beat", r[cSig] == "4-4", !r[cAudio].isEmpty else { continue }
        let midiURL = base.appendingPathComponent(r[cMidi])
        let audioURL = base.appendingPathComponent(r[cAudio])
        guard FileManager.default.fileExists(atPath: audioURL.path),
              let midi = try? Midi.read(midiURL), midi.length >= 12 else { continue }
        let id = (r[cMidi] as NSString).deletingPathExtension
        let header = "Groove MIDI Dataset \(r[cMidi]) — beats from the MIDI tempo, hits from the notes"
        let hits = midi.notes.map { DrumHit(time: $0.time, kind: drumKind($0.note), velocity: Int($0.velocity)) }
        let beatsURL = annotationURL("gmd", id, "beats"), drumsURL = annotationURL("gmd", id, "drums")
        do {
            try Corpus.writeBeats(midi.beats, to: beatsURL, header: header)
            try Corpus.writeDrums(hits, to: drumsURL, header: header)
        } catch { print("gmd \(id): \(error)"); continue }
        out.append(CorpusTrack(id: "gmd/\(id)", set: "gmd", audio: rel(audioURL), licence: licence,
                               source: "Groove MIDI Dataset (Magenta)", beats: rel(beatsURL), drums: rel(drumsURL),
                               sections: nil, sha256: nil, meta: ["style": r[cStyle], "bpm": r[cBPM]]))
    }
    print("gmd: \(out.count) tracks")
    return out
}

// MARK: BabySlakh

func importSlakh(_ dir: URL, licence: String) -> [CorpusTrack] {
    var out: [CorpusTrack] = []
    for mix in files(under: dir, ext: "wav") where mix.lastPathComponent == "mix.wav" {
        let trackDir = mix.deletingLastPathComponent()
        let midiURL = trackDir.appendingPathComponent("all_src.mid")
        guard let midi = try? Midi.read(midiURL) else { continue }
        let id = trackDir.lastPathComponent
        let header = "BabySlakh \(id) — beats from the tempo map, drums from MIDI channel 10"
        let hits = midi.notes.filter { $0.channel == 9 }
            .map { DrumHit(time: $0.time, kind: drumKind($0.note), velocity: Int($0.velocity)) }
        let beatsURL = annotationURL("slakh", id, "beats"), drumsURL = annotationURL("slakh", id, "drums")
        do {
            try Corpus.writeBeats(midi.beats, to: beatsURL, header: header)
            if !hits.isEmpty { try Corpus.writeDrums(hits, to: drumsURL, header: header) }
        } catch { print("slakh \(id): \(error)"); continue }
        out.append(CorpusTrack(id: "slakh/\(id)", set: "slakh", audio: rel(mix), licence: licence,
                               source: "BabySlakh (Slakh2100)", beats: rel(beatsURL), drums: hits.isEmpty ? nil : rel(drumsURL),
                               sections: nil, sha256: nil, meta: nil))
    }
    print("slakh: \(out.count) tracks")
    return out
}

// MARK: GuitarSet

func importGuitarSet(_ dir: URL, licence: String) -> [CorpusTrack] {
    let audio = files(under: dir, ext: "wav")
    var byName: [String: URL] = [:]
    for a in audio { byName[a.deletingPathExtension().lastPathComponent] = a }
    var out: [CorpusTrack] = []
    for jams in files(under: dir, ext: "jams") {
        let name = jams.deletingPathExtension().lastPathComponent
        guard let wav = byName[name + "_mic"] ?? byName[name],
              let data = try? Data(contentsOf: jams),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let anns = obj["annotations"] as? [[String: Any]],
              let beatAnn = anns.first(where: { ($0["namespace"] as? String) == "beat_position" }) else { continue }
        var beats: [Beat] = []
        for o in jamsObservations(beatAnn["data"]) {
            guard let t = o["time"] as? Double else { continue }
            let value = o["value"] as? [String: Any]
            let position = (value?["position"] as? NSNumber)?.intValue ?? 0
            let units = (value?["beat_units"] as? NSNumber)?.intValue ?? 4
            beats.append(Beat(time: t, beatInBar: units == 4 ? position : 0))
        }
        guard beats.count >= 8 else { continue }
        let beatsURL = annotationURL("guitarset", name, "beats")
        do { try Corpus.writeBeats(beats.sorted { $0.time < $1.time }, to: beatsURL, header: "GuitarSet \(name)") } catch { continue }
        out.append(CorpusTrack(id: "guitarset/\(name)", set: "guitarset", audio: rel(wav), licence: licence,
                               source: "GuitarSet", beats: rel(beatsURL), drums: nil, sections: nil, sha256: nil, meta: nil))
    }
    print("guitarset: \(out.count) tracks")
    return out
}

/// JAMS stores observations either as a list of objects or as parallel arrays.
func jamsObservations(_ data: Any?) -> [[String: Any]] {
    if let list = data as? [[String: Any]] { return list }
    if let cols = data as? [String: Any], let times = cols["time"] as? [Any] {
        let values = cols["value"] as? [Any] ?? []
        return times.enumerated().map { i, t in
            ["time": (t as? NSNumber)?.doubleValue ?? 0, "value": i < values.count ? values[i] : NSNull()]
        }
    }
    return []
}

// MARK: Candombe

func importCandombe(_ dir: URL, licence: String) -> [CorpusTrack] {
    // `with_bar_number/<name>.csv`: one `time,bar.beat` line per beat, the
    // part after the dot the beat in the bar (1 = downbeat).
    let audio = files(under: dir, ext: "flac") + files(under: dir, ext: "wav")
    var out: [CorpusTrack] = []
    let candidates = files(under: dir, ext: "csv").filter { $0.path.contains("with_bar_number") }
    for a in audio {
        let name = a.deletingPathExtension().lastPathComponent
        guard let ann = candidates.first(where: { $0.deletingPathExtension().lastPathComponent == name }),
              let rows = try? Corpus.lines(ann) else { continue }
        let beats: [Beat] = rows.compactMap { f in
            guard let t = f.first.flatMap(Double.init) else { return nil }
            let label = f.count > 1 ? f[1] : "0"
            let parts = label.split(separator: ".")
            let inBar = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
            return Beat(time: t, beatInBar: inBar)
        }
        guard beats.count >= 8 else { continue }
        let beatsURL = annotationURL("candombe", name, "beats")
        do { try Corpus.writeBeats(beats, to: beatsURL, header: "Candombe \(name)") } catch { continue }
        out.append(CorpusTrack(id: "candombe/\(name)", set: "candombe", audio: rel(a), licence: licence,
                               source: "Candombe beat tracking dataset", beats: rel(beatsURL), drums: nil, sections: nil,
                               sha256: nil, meta: nil))
    }
    print("candombe: \(out.count) tracks")
    return out
}

// MARK: Room impulse responses

struct RoomAcoustics { var c50: Double; var rt60: Double; var drr: Double }

/// Clarity (C50: energy in the first 50 ms after the direct sound against the
/// rest), reverberation time (T20 × 3 from the Schroeder decay) and the
/// direct-to-reverberant ratio (±2.5 ms around the direct sound).
func acoustics(_ h: [Float], fs: Double) -> RoomAcoustics? {
    guard h.count > Int(0.1 * fs) else { return nil }
    var peak = 0
    for i in 0..<h.count where abs(h[i]) > abs(h[peak]) { peak = i }
    let e = h.map { Double($0) * Double($0) }
    func sum(_ a: Int, _ b: Int) -> Double {
        let lo = max(0, a), hi = min(e.count, b)
        return lo < hi ? e[lo..<hi].reduce(0, +) : 0
    }
    let w = Int(0.0025 * fs), c = Int(0.05 * fs)
    let direct = sum(peak - w, peak + w), afterDirect = sum(peak + w, e.count)
    let early = sum(peak - w, peak + c), late = sum(peak + c, e.count)
    var schroeder = [Double](repeating: 0, count: e.count)
    var acc = 0.0
    for i in stride(from: e.count - 1, through: 0, by: -1) { acc += e[i]; schroeder[i] = acc }
    let total = schroeder[0]
    guard total > 0, late > 0, afterDirect > 0 else { return nil }
    let db = schroeder.map { 10 * log10($0 / total + 1e-15) }
    guard let i5 = db.firstIndex(where: { $0 < -5 }), let i25 = db.firstIndex(where: { $0 < -25 }), i25 > i5 else { return nil }
    return RoomAcoustics(c50: 10 * log10(early / late), rt60: Double(i25 - i5) / fs * 3,
                         drr: 10 * log10(direct / afterDirect))
}

/// Every measured response, sorted into home-like rooms (clear, short echo —
/// what a phone across a living room hears) and halls (long or dominant
/// echo — far from the speaker, or a big room). The beat lab found the
/// tracker's score follows clarity closely (corr 0.79 on one song), so the
/// two are scored apart rather than averaged into one number.
func importRIRs(_ dir: URL, homePerRoom: Int = 8, hallPerRoom: Int = 3) -> (home: [String], hall: [String]) {
    let all = files(under: dir, ext: "wav").filter { $0.path.contains("/RIR/") }
    let base = dir.standardizedFileURL.pathComponents.count
    func room(_ u: URL) -> String {
        let c = u.standardizedFileURL.pathComponents
        // …/but-reverbdb/extracted/<room>/MicIDxx/…
        return c.count > base + 1 ? c[base + 1] : ""
    }
    var home: [String: [URL]] = [:], hall: [String: [URL]] = [:]
    var measured = 0
    for u in all {
        guard let h = try? Corpus.loadAudio(u, fs: 16_000), let a = acoustics(h, fs: 16_000) else { continue }
        measured += 1
        if a.c50 >= 5 && a.rt60 <= 0.8 { home[room(u), default: []].append(u) } else { hall[room(u), default: []].append(u) }
    }
    func spread(_ byRoom: [String: [URL]], _ n: Int) -> [String] {
        var out: [String] = []
        for key in byRoom.keys.sorted() {
            let list = byRoom[key]!
            let step = max(1, list.count / n)
            out += stride(from: 0, to: list.count, by: step).prefix(n).map { rel(list[$0]) }
        }
        return out
    }
    let h = spread(home, homePerRoom), l = spread(hall, hallPerRoom)
    print("rirs: measured \(measured) of \(all.count); home-like \(home.values.map(\.count).reduce(0, +)) in \(home.count) rooms → \(h.count) used; halls \(hall.values.map(\.count).reduce(0, +)) in \(hall.count) rooms → \(l.count) used")
    return (h, l)
}

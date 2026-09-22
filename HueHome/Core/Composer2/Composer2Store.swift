// Composer2Store.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// A separate, versioned JSON store for Composer 2 compositions:
// `Documents/composer2-compositions.json`. It never reads or writes the
// legacy `compositions.json`, never touches `CompositionStore.onPersist`,
// and never persists the built-ins. A file it cannot decode is set aside
// (renamed) before the first save, never silently overwritten.

import Foundation
import Observation

@MainActor
@Observable
final class Composer2Store {
    static let shared = Composer2Store()

    /// User-owned compositions only; built-ins come from the library.
    private(set) var compositions: [Composer2Composition] = []
    private(set) var loadFailed = false

    @ObservationIgnored let fileURL: URL
    @ObservationIgnored private var setAsideCorruptFile = false
    /// The file existed but could not be READ (not: could not be decoded) —
    /// e.g. data protection before the first unlock. Such a file is almost
    /// certainly fine, so it is re-read before any save and never replaced
    /// while it stays unreadable.
    @ObservationIgnored private var readDeferred = false
    /// Some saved compositions did not decode (a newer build's data, a
    /// hand edit). The file is copied aside once before the first save
    /// rewrites it without them.
    @ObservationIgnored private var droppedEntries = false

    struct FileEnvelope: Codable {
        static let currentSchema = 1
        var schema: Int
        var compositions: [Composer2Composition]
    }

    nonisolated static var defaultFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("composer2-compositions.json")
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Composer2Store.defaultFileURL
        let read = Composer2Store.readEnvelope(from: self.fileURL)
        compositions = read.compositions
        loadFailed = read.failed
        readDeferred = read.unreadable
        droppedEntries = read.dropped
    }

    var all: [Composer2Composition] {
        Composer2PresetLibrary.all + compositions
    }

    func composition(id: UUID) -> Composer2Composition? {
        if let built = Composer2PresetLibrary.composition(id: id) { return built }
        return compositions.first { $0.id == id }
    }

    /// Upsert. A built-in is never overwritten in place: saving one stores a
    /// user-owned composition with the same id replaced by a fresh identity.
    @discardableResult
    func save(_ composition: Composer2Composition, at date: Date = Date()) -> Composer2Composition {
        var c = composition
        if Composer2PresetLibrary.isBuiltIn(id: c.id) || c.isBuiltIn {
            c = c.duplicated(name: c.name, at: date)
        }
        c.isBuiltIn = false
        c.updatedAt = date
        c.schema = Composer2Composition.currentSchema
        if let i = compositions.firstIndex(where: { $0.id == c.id }) {
            compositions[i] = c
        } else {
            compositions.append(c)
        }
        persist()
        return c
    }

    func delete(id: UUID) {
        let before = compositions.count
        compositions.removeAll { $0.id == id }
        if compositions.count != before { persist() }
    }

    @discardableResult
    func duplicate(_ composition: Composer2Composition, at date: Date = Date()) -> Composer2Composition {
        let copy = composition.duplicated(name: composition.name + " copy", at: date)
        compositions.append(copy)
        persist()
        return copy
    }

    // MARK: Reading

    nonisolated static func readCompositions(from url: URL) -> [Composer2Composition] {
        readEnvelope(from: url).compositions
    }

    struct ReadResult {
        var compositions: [Composer2Composition]
        /// Present but undecodable as a whole.
        var failed: Bool
        /// Present but could not be read from disk at all.
        var unreadable: Bool = false
        /// Decoded, but some entries were skipped.
        var dropped: Bool = false
    }

    private struct FailableEnvelope: Decodable {
        let schema: Int?
        let compositions: [FailableDecodable<Composer2Composition>]?
    }

    nonisolated static func readEnvelope(from url: URL) -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return ReadResult(compositions: [], failed: false) }
        guard let data = try? Data(contentsOf: url) else {
            return ReadResult(compositions: [], failed: false, unreadable: true)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let envelope = try? decoder.decode(FailableEnvelope.self, from: data) {
            let raw = envelope.compositions ?? []
            let items = raw.compactMap(\.value)
            return ReadResult(compositions: items, failed: false, dropped: items.count != raw.count)
        }
        // A bare array is accepted too, for hand-written files.
        if let raw = try? decoder.decode([FailableDecodable<Composer2Composition>].self, from: data) {
            let items = raw.compactMap(\.value)
            return ReadResult(compositions: items, failed: false, dropped: items.count != raw.count)
        }
        return ReadResult(compositions: [], failed: true)
    }

    // MARK: Writing

    private func persist() {
        if readDeferred {
            // The file could not be read at launch. Read it now; merge what
            // is on disk under what the user has done since (theirs wins).
            let retry = Composer2Store.readEnvelope(from: fileURL)
            if retry.unreadable { return }   // still locked: never clobber it
            readDeferred = false
            loadFailed = retry.failed
            droppedEntries = droppedEntries || retry.dropped
            let mine = Set(compositions.map(\.id))
            compositions = retry.compositions.filter { !mine.contains($0.id) } + compositions
        }
        if droppedEntries && !loadFailed {
            droppedEntries = false
            let copy = fileURL.deletingPathExtension()
                .appendingPathExtension("partial-\(Int(Date().timeIntervalSince1970)).bak")
            try? FileManager.default.copyItem(at: fileURL, to: copy)
        }
        if loadFailed && !setAsideCorruptFile {
            setAsideCorruptFile = true
            let aside = fileURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).bak")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let envelope = FileEnvelope(schema: FileEnvelope.currentSchema, compositions: compositions)
        guard let data = try? encoder.encode(envelope) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }
}

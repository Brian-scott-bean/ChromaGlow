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

    private struct FailableEnvelope: Decodable {
        let schema: Int?
        let compositions: [FailableDecodable<Composer2Composition>]?
    }

    nonisolated private static func readEnvelope(from url: URL) -> (compositions: [Composer2Composition], failed: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], false) }
        guard let data = try? Data(contentsOf: url) else { return ([], true) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let envelope = try? decoder.decode(FailableEnvelope.self, from: data) {
            let items = (envelope.compositions ?? []).compactMap(\.value)
            return (items, false)
        }
        // A bare array is accepted too, for hand-written files.
        if let items = try? decoder.decode([FailableDecodable<Composer2Composition>].self, from: data) {
            return (items.compactMap(\.value), false)
        }
        return ([], true)
    }

    // MARK: Writing

    private func persist() {
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

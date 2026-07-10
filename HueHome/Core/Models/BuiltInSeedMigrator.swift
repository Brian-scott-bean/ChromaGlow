// BuiltInSeedMigrator.swift
// ChromaGlow — Composer library
//
// The built-in presets are seeded exactly once, on first launch, by a
// create-only write (M-13). That is the right rule for protecting a user's
// library — and it means a preset added in a later release would never reach
// anyone who had already opened the app. It also means the gamut fixes to
// existing presets would never reach them either.
//
// So the library is reconciled against the shipped catalog on every load:
//
//   • a built-in the file has never seen is added
//   • a built-in the user has never touched is refreshed to its shipped form
//   • a built-in the user HAS touched is left exactly as they left it
//   • anything the user made is never touched at all
//
// This runs in memory. It deliberately adds no write path: persisting during
// load would race the create-only seed and the `ensureLoadedForMutation` sync
// load, and re-earning M-13's guarantees is not worth it. The merged library is
// what the UI reads; the file catches up on the next ordinary save. Because the
// reconciliation is idempotent, a user who never saves simply gets it again on
// every launch, which costs a set difference.
//
// "Never touched" is `updatedAt <= createdAt`. Everything that mutates a preset
// — rename, preferred transport, an edit saved over it — bumps `updatedAt`, and
// the seed writes the two timestamps equal. A refresh re-seeds both, so a
// refreshed preset stays eligible for the next one.

import Foundation

enum BuiltInSeedMigrator {

    struct Result: Equatable {
        let presets: [CompositionPreset]
        let added: [String]
        let refreshed: [String]

        var didChange: Bool { !added.isEmpty || !refreshed.isEmpty }
    }

    /// Timestamps round-trip through JSON as doubles, so compare with a hair of
    /// slack rather than demanding bit equality.
    static let timestampEpsilon: TimeInterval = 0.001

    /// A built-in the user has never modified. Only these may be refreshed.
    static func isUnedited(_ preset: CompositionPreset) -> Bool {
        preset.isBuiltIn
            && preset.updatedAt.timeIntervalSince(preset.createdAt) <= timestampEpsilon
    }

    static func migrate(stored: [CompositionPreset], builtIns: [CompositionPreset]) -> Result {
        // An empty library means "first launch" or "recovered from a bad file".
        // Both want the catalog verbatim, and neither is a migration.
        guard !stored.isEmpty else {
            return Result(presets: builtIns, added: [], refreshed: [])
        }

        let shippedByID = Dictionary(builtIns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var storedIDs = Set<UUID>()
        var refreshed: [String] = []

        var merged: [CompositionPreset] = stored.map { existing in
            storedIDs.insert(existing.id)

            // A user's own creation, or a built-in we no longer ship. Leave it.
            guard let shipped = shippedByID[existing.id], existing.isBuiltIn else { return existing }

            // The user made this one theirs. It is not ours to update.
            guard isUnedited(existing) else { return existing }

            // Nothing to say — already the shipped design.
            guard !designMatches(existing, shipped) else { return existing }

            refreshed.append(shipped.name)
            return shipped
        }

        // Presets shipped since this library was written.
        let newcomers = builtIns.filter { !storedIDs.contains($0.id) }
        merged.append(contentsOf: newcomers)

        return Result(presets: merged, added: newcomers.map(\.name), refreshed: refreshed)
    }

    /// Everything a user could see or hear, ignoring identity and timestamps.
    /// Two presets that match here would render identically, so replacing one
    /// with the other is a no-op worth skipping.
    static func designMatches(_ a: CompositionPreset, _ b: CompositionPreset) -> Bool {
        a.name == b.name
            && a.icon == b.icon
            && a.accentColorHex == b.accentColorHex
            && a.category == b.category
            && a.seasonMonths == b.seasonMonths
            && a.palette == b.palette
            && a.motion == b.motion
            && a.envelope == b.envelope
            && a.reaction == b.reaction
            && a.preferredTransport == b.preferredTransport
            && a.sequence == b.sequence
    }
}

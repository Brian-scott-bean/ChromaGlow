// CompositionStore.swift
// ChromaGlow — Composer v0.17.0
//
// JSON persistence for saved compositions.
// Loads on app launch, saves on every create/edit/delete.
// Built-in presets included on first launch (56 starter presets).

import Foundation

// MARK: - CompositionStore

/// `@unchecked Sendable` invariant: `presets` and `isLoaded` are mutated only on
/// the main actor. The synchronous `load()` runs in the (main-actor) context that
/// constructs the store, and the async path applies its result inside `MainActor.run`.
/// The off-main read (`readPresets`) is a pure static that touches no instance state.
@Observable
final class CompositionStore: @unchecked Sendable {

    private(set) var presets: [CompositionPreset] = []
    /// True once presets reflect the file (or the seeded defaults). Guards the async
    /// load against a racing mutation and lets `ensureLoadedForMutation()` know if a
    /// synchronous load is still owed.
    private(set) var isLoaded = false

    private let fileURL: URL

    /// - Parameters:
    ///   - fileURL: injectable for tests only — production persists to Documents/compositions.json.
    ///   - loadsSynchronously: `true` (default) reads + decodes the file on the calling
    ///     thread during init — the original behavior, kept for tests and any caller that
    ///     reads `presets` immediately. `false` returns instantly with an empty `presets`
    ///     and reads off-main, publishing when ready — used by StudioViewModel so the
    ///     Studio tab's eager construction never blocks the main thread on file I/O.
    init(fileURL: URL? = nil, loadsSynchronously: Bool = true) {
        self.fileURL = fileURL ?? {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return docs.appendingPathComponent("compositions.json")
        }()
        if loadsSynchronously {
            load()
        } else {
            Task { [weak self] in await self?.applyAsyncLoad() }
        }
    }

    // MARK: - CRUD

    func save(_ preset: CompositionPreset) {
        ensureLoadedForMutation()
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        persist()
    }

    func delete(_ preset: CompositionPreset) {
        ensureLoadedForMutation()
        if preset.isBuiltIn {
            // Built-in presets reset to default instead of deleting
            if let original = Self.builtInPresets.first(where: { $0.name == preset.name }) {
                save(original)
            }
            return
        }
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    func duplicate(_ preset: CompositionPreset) -> CompositionPreset {
        ensureLoadedForMutation()
        let copy = CompositionPreset(
            id: UUID(),
            name: "\(preset.name) Copy",
            icon: preset.icon,
            accentColorHex: preset.accentColorHex,
            isBuiltIn: false,
            category: .myCreations,
            seasonMonths: preset.seasonMonths,
            palette: preset.palette,
            motion: preset.motion,
            envelope: preset.envelope,
            reaction: preset.reaction,
            createdAt: Date(),
            updatedAt: Date(),
            aiPrompt: preset.aiPrompt,
            providerModel: preset.providerModel,
            preferredTransport: preset.preferredTransport
        )
        presets.append(copy)
        persist()
        return copy
    }

    // MARK: - Filtering

    func presets(for category: PresetCategory) -> [CompositionPreset] {
        switch category {
        case .all: return presets
        default: return presets.filter { $0.category == category }
        }
    }

    /// Presets that are seasonally relevant right now.
    var seasonalPresets: [CompositionPreset] {
        presets.filter { $0.isInSeason }
    }

    // MARK: - Persistence

    /// Synchronous load — reads + decodes on the calling thread and publishes.
    private func load() {
        let result = Self.readPresets(from: fileURL)
        presets = result.presets
        isLoaded = true
        if result.seedNeedsPersist { persist() }
    }

    /// Off-main variant: reads + decodes on a background executor, then applies on
    /// the main actor. No-ops if a mutation already forced a synchronous load
    /// (`isLoaded == true`) so it can never clobber freshly-saved user data.
    /// The first-launch seed is also written INSIDE the detached task — encoding
    /// 20 nested presets + an atomic file write used to run on the main thread via
    /// MainActor.run, landing squarely in the post-pairing work storm.
    private func applyAsyncLoad() async {
        if isLoaded { return }
        let url = fileURL
        let result = await Task.detached(priority: .userInitiated) {
            let r = CompositionStore.readPresets(from: url)
            if r.seedNeedsPersist {
                CompositionStore.persistSeed(r.presets, to: url)
            }
            return r
        }.value
        await MainActor.run {
            guard !self.isLoaded else { return }   // sync load won the race — keep its data
            self.presets = result.presets
            self.isLoaded = true
        }
    }

    /// First-launch seed writer — encode + create-only write, off-main.
    /// `.withoutOverwriting` (alone — combining it with `.atomic` is an assertion
    /// failure in Data.write, not a thrown error) makes this a no-op loser if a
    /// synchronous load (ensureLoadedForMutation → load → persist) already created
    /// the file: the seed can never clobber a file that user data has since been
    /// written to (M-13). Its O_EXCL create semantics mean the file either appears
    /// fully written or the call errors; a partial file from a crash mid-write is
    /// handled by readPresets' backup-and-defaults recovery. seedNeedsPersist is
    /// only true when the file did not exist at read.
    nonisolated private static func persistSeed(_ presets: [CompositionPreset], to url: URL) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: url, options: [.withoutOverwriting])
    }

    /// If an async load is still in flight, load synchronously before any mutation so
    /// save/delete/duplicate can never persist over a not-yet-loaded library (M-13).
    private func ensureLoadedForMutation() {
        if !isLoaded { load() }
    }

    /// Pure, thread-safe read of the compositions file. Touches no instance state,
    /// so it is safe to run off the main actor. Returns the presets to publish plus
    /// whether the first-launch seed still needs persisting (the caller does that,
    /// on the main actor). M-13: this read path must NEVER destroy user data.
    ///  - Elements decode leniently: one malformed preset is dropped, the rest survive.
    ///  - On ANY decode problem the original file is backed up first and the source is
    ///    never overwritten from here — the next user-initiated save() is the first writer.
    nonisolated static func readPresets(from fileURL: URL) -> (presets: [CompositionPreset], seedNeedsPersist: Bool) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // First launch — seed with built-in presets (caller persists).
            return (builtInPresets, true)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let wrapped = try JSONDecoder().decode([FailableDecodable<CompositionPreset>].self, from: data)
            let good = wrapped.compactMap(\.value)
            if good.count < wrapped.count {
                print("[CompositionStore] ⚠ \(wrapped.count - good.count) preset(s) failed to decode — keeping \(good.count), backing up the original file")
                backUpCompositionsFile(fileURL)
            }
            guard !good.isEmpty else { return (builtInPresets, false) }

            // The seed is create-only, so presets shipped after this file was
            // written would never arrive. Reconcile in memory on every load —
            // no new write path, nothing to race the seed (see BuiltInSeedMigrator).
            let migration = BuiltInSeedMigrator.migrate(stored: good, builtIns: builtInPresets)
            if migration.didChange {
                print("[CompositionStore] Built-ins reconciled — added \(migration.added.count), refreshed \(migration.refreshed.count)")
            }
            return (migration.presets, false)
        } catch {
            // The file is not a decodable array at all. Preserve the bytes in a
            // timestamped .bak, run in-memory on defaults, and DO NOT persist —
            // overwriting the source on a read failure is how the library used to vanish.
            print("[CompositionStore] Failed to load: \(error). Backing up file and running on defaults (source NOT overwritten).")
            backUpCompositionsFile(fileURL)
            return (builtInPresets, false)
        }
    }

    /// Copies compositions.json to a timestamped sibling before any recovery
    /// path can lose data (M-13).
    nonisolated private static func backUpCompositionsFile(_ fileURL: URL) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("compositions-\(formatter.string(from: Date())).bak")
        do {
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
            print("[CompositionStore] Backed up compositions.json → \(backupURL.lastPathComponent)")
        } catch {
            print("[CompositionStore] ⚠ Backup failed: \(error)")
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(presets)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[CompositionStore] Failed to save: \(error)")
        }
    }

    // MARK: - Built-in Presets (56)

    // swiftlint:disable function_body_length
    static let builtInPresets: [CompositionPreset] = {
        let now = Date()

        // ── Ambient (5) ─────────────────────────────────────────────

        let sunsetCascade = CompositionPreset(
            id: UUID(uuidString: "00000001-0001-0001-0001-000000000001")!,
            name: "Sunset Cascade", icon: "sun.horizon.fill",
            accentColorHex: "#FF6B35", isBuiltIn: true,
            category: .ambient, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.5500, y: 0.3900),   // amber
                color2: CodableColor(x: 0.6400, y: 0.3300)),  // deep red
            motion: MotionConfig(pattern: .cascade, speed: 25, forward: true),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 40, depth: 40),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let oceanDrift = CompositionPreset(
            id: UUID(uuidString: "00000001-0001-0001-0001-000000000002")!,
            name: "Ocean Drift", icon: "water.waves",
            accentColorHex: "#0A84FF", isBuiltIn: true,
            category: .ambient, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.1600, y: 0.2300),   // teal
                color2: CodableColor(x: 0.1549, y: 0.0626)),  // deep blue
            motion: MotionConfig(pattern: .wave, speed: 40),
            envelope: EnvelopeConfig(shape: .swell, bpm: 30, depth: 35),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let northernLights = CompositionPreset(
            id: UUID(uuidString: "00000001-0001-0001-0001-000000000003")!,
            name: "Northern Lights", icon: "aurora",
            accentColorHex: "#30D158", isBuiltIn: true,
            category: .ambient, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.1700, y: 0.7000),   // green
                color2: CodableColor(x: 0.3200, y: 0.1500)),  // purple
            motion: MotionConfig(pattern: .wave, speed: 15),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 20, depth: 30),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let cozyEvening = CompositionPreset(
            id: UUID(uuidString: "00000001-0001-0001-0001-000000000004")!,
            name: "Cozy Evening", icon: "house.fill",
            accentColorHex: "#FF9500", isBuiltIn: true,
            category: .ambient, seasonMonths: nil,
            palette: PaletteConfig(mode: .temperature, temperature: 400),
            motion: MotionConfig(pattern: .static),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 24, depth: 20),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let heartbeat = CompositionPreset(
            id: UUID(uuidString: "00000001-0001-0001-0001-000000000005")!,
            name: "Heartbeat", icon: "heart.fill",
            accentColorHex: "#FF453A", isBuiltIn: true,
            category: .ambient, seasonMonths: nil,
            palette: PaletteConfig(mode: .solid,
                color1: CodableColor.warmWhite),
            motion: MotionConfig(pattern: .static),
            envelope: EnvelopeConfig(shape: .heartbeat, bpm: 72, depth: 60),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        // ── Energetic (3) ───────────────────────────────────────────

        let bassDrop = CompositionPreset(
            id: UUID(uuidString: "00000002-0001-0001-0001-000000000001")!,
            name: "Bass Drop", icon: "speaker.wave.3.fill",
            accentColorHex: "#BF5AF2", isBuiltIn: true,
            category: .energetic, seasonMonths: nil,
            palette: PaletteConfig(mode: .spectrum),
            motion: MotionConfig(pattern: .scatter, speed: 75),
            envelope: EnvelopeConfig(shape: .pulse, bpm: 128, depth: 80),
            reaction: ReactionConfig(source: .micBass, sensitivity: 85, targets: [.brightness]),
            createdAt: now, updatedAt: now
        )

        let clubMode = CompositionPreset(
            id: UUID(uuidString: "00000002-0001-0001-0001-000000000002")!,
            name: "Club Mode", icon: "music.note.list",
            accentColorHex: "#FF4D8C", isBuiltIn: true,
            category: .energetic, seasonMonths: nil,
            palette: PaletteConfig(mode: .spectrum),
            motion: MotionConfig(pattern: .cascade, speed: 80),
            envelope: EnvelopeConfig(shape: .pulse, bpm: 140, depth: 70),
            reaction: ReactionConfig(source: .micAmplitude, sensitivity: 75, targets: [.brightness]),
            createdAt: now, updatedAt: now
        )

        let stormChase = CompositionPreset(
            id: UUID(uuidString: "00000002-0001-0001-0001-000000000003")!,
            name: "Storm Chase", icon: "cloud.bolt.fill",
            accentColorHex: "#668AFF", isBuiltIn: true,
            category: .energetic, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor.white,
                color2: CodableColor(x: 0.1549, y: 0.0626)),  // deep blue
            motion: MotionConfig(pattern: .scatter, speed: 50),
            envelope: EnvelopeConfig(shape: .flicker, bpm: 90, depth: 70),
            reaction: ReactionConfig(source: .micTreble, sensitivity: 80, targets: [.brightness]),
            createdAt: now, updatedAt: now
        )

        // ── Holiday (12) ────────────────────────────────────────────

        let christmas = CompositionPreset(
            id: UUID(uuidString: "00000003-0001-0001-0001-000000000001")!,
            name: "Christmas Classic", icon: "gift.fill",
            accentColorHex: "#FF3B30", isBuiltIn: true,
            category: .holiday, seasonMonths: [12],
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.6400, y: 0.3300),   // red
                color2: CodableColor(x: 0.1700, y: 0.7000)),  // green
            // Phase 2: theater-chase — the classic red/green holiday string.
            motion: MotionConfig(pattern: .chase, speed: 25, spread: 55, offset: 65),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 30, depth: 30),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let winterWonderland = CompositionPreset(
            id: UUID(uuidString: "00000003-0001-0001-0001-000000000002")!,
            name: "Winter Wonderland", icon: "snowflake",
            accentColorHex: "#64D2FF", isBuiltIn: true,
            category: .holiday, seasonMonths: [12, 1, 2],
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.1800, y: 0.1800),   // ice blue
                color2: CodableColor.white),
            // Phase 2: gentle snowfall shimmer over a soft ice wash.
            motion: MotionConfig(pattern: .twinkle, speed: 15, spread: 80, offset: 45),
            envelope: EnvelopeConfig(shape: .swell, bpm: 24, depth: 15),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let halloween = CompositionPreset(
            id: UUID(uuidString: "00000003-0001-0001-0001-000000000003")!,
            name: "Halloween Haunt", icon: "moon.stars.fill",
            accentColorHex: "#FF9500", isBuiltIn: true,
            category: .holiday, seasonMonths: [10],
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.5600, y: 0.4000),   // orange
                color2: CodableColor(x: 0.3200, y: 0.1500)),  // purple
            // Phase 2: a slow comet prowling the room — head glow, long tail.
            motion: MotionConfig(pattern: .comet, speed: 30, spread: 45),
            envelope: EnvelopeConfig(shape: .flicker, bpm: 60, depth: 70),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let valentines = CompositionPreset(
            id: UUID(uuidString: "00000003-0001-0001-0001-000000000004")!,
            name: "Valentine's Glow", icon: "heart.fill",
            accentColorHex: "#FF375F", isBuiltIn: true,
            category: .holiday, seasonMonths: [2],
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.6400, y: 0.3300),   // red
                color2: CodableColor(x: 0.5359, y: 0.2347)),  // pink
            motion: MotionConfig(pattern: .static),
            envelope: EnvelopeConfig(shape: .heartbeat, bpm: 60, depth: 50),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let fourthOfJuly = CompositionPreset(
            id: UUID(uuidString: "00000003-0001-0001-0001-000000000005")!,
            name: "4th of July", icon: "star.fill",
            accentColorHex: "#0A84FF", isBuiltIn: true,
            category: .holiday, seasonMonths: [7],
            palette: PaletteConfig(mode: .spectrum,
                color1: CodableColor(x: 0.6400, y: 0.3300),   // red
                color2: CodableColor.white,
                color3: CodableColor(x: 0.1549, y: 0.0626)),  // blue
            motion: MotionConfig(pattern: .cascade, speed: 70),
            envelope: EnvelopeConfig(shape: .pulse, bpm: 120, depth: 60),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let stPatricks = CompositionPreset(
            id: UUID(uuidString: "00000003-0001-0001-0001-000000000006")!,
            name: "St. Patrick's", icon: "leaf.fill",
            accentColorHex: "#30D158", isBuiltIn: true,
            category: .holiday, seasonMonths: [3],
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.1920, y: 0.6808),   // bright green
                color2: CodableColor(x: 0.1700, y: 0.5000)),  // forest green
            motion: MotionConfig(pattern: .wave, speed: 35),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 40, depth: 30),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let easter = CompositionPreset(
            id: UUID(uuidString: "00000003-0001-0001-0001-000000000007")!,
            name: "Easter Pastels", icon: "hare.fill",
            accentColorHex: "#FFD1DC", isBuiltIn: true,
            category: .holiday, seasonMonths: [4],
            palette: PaletteConfig(mode: .spectrum, saturation: 40),
            motion: MotionConfig(pattern: .wave, speed: 20),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 30, depth: 20),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let hanukkah = CompositionPreset(
            id: UUID(uuidString: "00000003-0001-0001-0001-000000000008")!,
            name: "Hanukkah", icon: "sparkles",
            accentColorHex: "#0A84FF", isBuiltIn: true,
            category: .holiday, seasonMonths: [12],
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.1549, y: 0.0626),   // blue
                color2: CodableColor.white),
            motion: MotionConfig(pattern: .cascade, speed: 20),
            envelope: EnvelopeConfig(shape: .swell, bpm: 30, depth: 25),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let diwali = CompositionPreset(
            id: UUID(uuidString: "00000003-0001-0001-0001-000000000009")!,
            name: "Diwali", icon: "flame.fill",
            accentColorHex: "#FFD60A", isBuiltIn: true,
            category: .holiday, seasonMonths: [10, 11],
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.4500, y: 0.4100),   // gold
                color2: CodableColor(x: 0.5600, y: 0.4000)),  // deep orange
            // Phase 2: diya-lamp twinkle — golden sparkles over a warm base.
            motion: MotionConfig(pattern: .twinkle, speed: 40, spread: 65, offset: 60),
            envelope: EnvelopeConfig(shape: .flicker, bpm: 60, depth: 50),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let newYears = CompositionPreset(
            id: UUID(uuidString: "00000003-0001-0001-0001-00000000000A")!,
            name: "New Year's Eve", icon: "party.popper.fill",
            accentColorHex: "#FFD60A", isBuiltIn: true,
            category: .holiday, seasonMonths: [12, 1],
            palette: PaletteConfig(mode: .spectrum),
            // Phase 2: multi-head spectrum chase, beat-ready — tap Tempo (or
            // let the clock hear the music) and the party locks to the beat.
            motion: MotionConfig(pattern: .chase, speed: 80, spread: 40, offset: 100),
            envelope: EnvelopeConfig(shape: .pulse, bpm: 140, depth: 75),
            reaction: ReactionConfig(source: .beat, targets: [.brightness, .color],
                                     motionBeatsPerCycle: 4),
            createdAt: now, updatedAt: now
        )

        let thanksgiving = CompositionPreset(
            id: UUID(uuidString: "00000003-0001-0001-0001-00000000000B")!,
            name: "Thanksgiving", icon: "leaf.fill",
            accentColorHex: "#C77A30", isBuiltIn: true,
            category: .holiday, seasonMonths: [11],
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.5500, y: 0.3900),   // warm amber
                color2: CodableColor(x: 0.6400, y: 0.3300)),  // deep red
            motion: MotionConfig(pattern: .static),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 24, depth: 20),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let mardiGras = CompositionPreset(
            id: UUID(uuidString: "00000003-0001-0001-0001-00000000000C")!,
            name: "Mardi Gras", icon: "theatermasks.fill",
            accentColorHex: "#BF5AF2", isBuiltIn: true,
            category: .holiday, seasonMonths: [2, 3],
            palette: PaletteConfig(mode: .spectrum,
                color1: CodableColor(x: 0.3200, y: 0.1500),   // purple
                color2: CodableColor(x: 0.4500, y: 0.4100),   // gold
                color3: CodableColor(x: 0.1700, y: 0.7000)),  // green
            motion: MotionConfig(pattern: .cascade, speed: 70),
            envelope: EnvelopeConfig(shape: .pulse, bpm: 120, depth: 60),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        // ── Catalog expansion (2026-07) ─────────────────────────────
        // Palette stops are computed sRGB -> CIE xy, projected into gamut C
        // and pulled 1% toward D65, so every stop is a colour a real bulb can
        // show. PresetCatalogTests holds the rest of the bar: flash rate under
        // 3Hz, legal renders at 1 and 20 lights, no jumping at low speed, and
        // motion that actually differs across lights — a "scatter" pattern over
        // a "temperature" palette does not, because scatter varies only phase
        // (its weight is a constant 1.0) and temperature ignores phase.

        let savannaSunset = CompositionPreset(
            id: UUID(uuidString: "00000004-0001-0001-0001-000000000001")!,
            name: "Savanna Sunset", icon: "sun.horizon.fill",
            accentColorHex: "#FF9F0A", isBuiltIn: true,
            category: .nature, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.6343, y: 0.3513),
                color2: CodableColor(x: 0.4998, y: 0.4263),
                color3: CodableColor(x: 0.6481, y: 0.3189)),
            motion: MotionConfig(pattern: .wave, speed: 22, spread: 70, offset: 55),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 26, depth: 22, minBrightness: 30, maxBrightness: 100),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let tropicalTwilight = CompositionPreset(
            id: UUID(uuidString: "00000004-0001-0001-0001-000000000002")!,
            name: "Tropical Twilight", icon: "palmtree.fill",
            accentColorHex: "#FF7AB2", isBuiltIn: true,
            category: .nature, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.4995, y: 0.2546),
                color2: CodableColor(x: 0.2104, y: 0.1059),
                color3: CodableColor(x: 0.1597, y: 0.3031)),
            motion: MotionConfig(pattern: .cascade, speed: 28, spread: 75, offset: 60),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 24, depth: 25, minBrightness: 28, maxBrightness: 100),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let springBlossom = CompositionPreset(
            id: UUID(uuidString: "00000004-0001-0001-0001-000000000003")!,
            name: "Spring Blossom", icon: "camera.macro",
            accentColorHex: "#FFB3D1", isBuiltIn: true,
            category: .nature, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.3733, y: 0.3002),
                color2: CodableColor(x: 0.3809, y: 0.3863),
                color3: CodableColor(x: 0.3064, y: 0.3990)),
            motion: MotionConfig(pattern: .wave, speed: 18, spread: 65, offset: 50),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 22, depth: 18, minBrightness: 40, maxBrightness: 96),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let forestCanopy = CompositionPreset(
            id: UUID(uuidString: "00000004-0001-0001-0001-000000000004")!,
            name: "Forest Canopy", icon: "tree.fill",
            accentColorHex: "#34C759", isBuiltIn: true,
            category: .nature, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.1914, y: 0.5529),
                color2: CodableColor(x: 0.2842, y: 0.5505),
                color3: CodableColor(x: 0.1822, y: 0.5010)),
            motion: MotionConfig(pattern: .scatter, speed: 16, spread: 60, offset: 55),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 20, depth: 24, minBrightness: 30, maxBrightness: 92),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let oceanDepths = CompositionPreset(
            id: UUID(uuidString: "00000004-0001-0001-0001-000000000005")!,
            name: "Ocean Depths", icon: "water.waves",
            accentColorHex: "#0A84FF", isBuiltIn: true,
            category: .nature, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.1574, y: 0.1583),
                color2: CodableColor(x: 0.1599, y: 0.3111),
                color3: CodableColor(x: 0.1551, y: 0.1273)),
            motion: MotionConfig(pattern: .wave, speed: 20, spread: 80, offset: 60),
            envelope: EnvelopeConfig(shape: .swell, bpm: 20, depth: 30, minBrightness: 22, maxBrightness: 94),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let mistyMorning = CompositionPreset(
            id: UUID(uuidString: "00000004-0001-0001-0001-000000000006")!,
            name: "Misty Morning", icon: "cloud.fog.fill",
            accentColorHex: "#B0C4DE", isBuiltIn: true,
            category: .nature, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.2785, y: 0.3015),
                color2: CodableColor(x: 0.3112, y: 0.3219)),
            motion: MotionConfig(pattern: .scatter, speed: 12, spread: 50, offset: 45),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 22, depth: 14, minBrightness: 38, maxBrightness: 88),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let thunderhead = CompositionPreset(
            id: UUID(uuidString: "00000004-0001-0001-0001-000000000007")!,
            name: "Thunderhead", icon: "cloud.bolt.fill",
            accentColorHex: "#5E5CE6", isBuiltIn: true,
            category: .nature, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.2161, y: 0.1714),
                color2: CodableColor(x: 0.2266, y: 0.1777),
                color3: CodableColor(x: 0.2210, y: 0.1785)),
            motion: MotionConfig(pattern: .twinkle, speed: 30, spread: 70, offset: 40),
            envelope: EnvelopeConfig(shape: .flicker, bpm: 40, depth: 45, minBrightness: 12, maxBrightness: 100),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let desertDusk = CompositionPreset(
            id: UUID(uuidString: "00000004-0001-0001-0001-000000000008")!,
            name: "Desert Dusk", icon: "sun.dust.fill",
            accentColorHex: "#FF9500", isBuiltIn: true,
            category: .nature, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.6037, y: 0.3501),
                color2: CodableColor(x: 0.3034, y: 0.1641)),
            motion: MotionConfig(pattern: .wave, speed: 17, spread: 68, offset: 52),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 22, depth: 20, minBrightness: 32, maxBrightness: 96),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let galaxy = CompositionPreset(
            id: UUID(uuidString: "00000005-0001-0001-0001-000000000001")!,
            name: "Galaxy", icon: "sparkles",
            accentColorHex: "#BF5AF2", isBuiltIn: true,
            category: .cosmic, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.2203, y: 0.0907),
                color2: CodableColor(x: 0.3229, y: 0.1512),
                color3: CodableColor(x: 0.1716, y: 0.0820)),
            motion: MotionConfig(pattern: .spiral, speed: 24, spread: 78, offset: 62),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 20, depth: 26, minBrightness: 24, maxBrightness: 96),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let starlight = CompositionPreset(
            id: UUID(uuidString: "00000005-0001-0001-0001-000000000002")!,
            name: "Starlight", icon: "star.fill",
            accentColorHex: "#F5F5F7", isBuiltIn: true,
            category: .cosmic, seasonMonths: nil,
            palette: PaletteConfig(mode: .temperature, temperature: 200),
            motion: MotionConfig(pattern: .twinkle, speed: 22, spread: 85, offset: 35),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 24, depth: 20, minBrightness: 30, maxBrightness: 92),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let meteorShower = CompositionPreset(
            id: UUID(uuidString: "00000005-0001-0001-0001-000000000003")!,
            name: "Meteor Shower", icon: "sparkle",
            accentColorHex: "#64D2FF", isBuiltIn: true,
            category: .cosmic, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.1670, y: 0.1679),
                color2: CodableColor(x: 0.2007, y: 0.2966)),
            motion: MotionConfig(pattern: .comet, speed: 55, spread: 72, offset: 68),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 40, depth: 28, minBrightness: 18, maxBrightness: 100),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let bloodMoon = CompositionPreset(
            id: UUID(uuidString: "00000005-0001-0001-0001-000000000004")!,
            name: "Blood Moon", icon: "moon.fill",
            accentColorHex: "#FF453A", isBuiltIn: true,
            category: .cosmic, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.6561, y: 0.3028),
                color2: CodableColor(x: 0.6010, y: 0.3317)),
            motion: MotionConfig(pattern: .pulseCenter, speed: 14, spread: 70, offset: 50),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 24, depth: 24, minBrightness: 26, maxBrightness: 90),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let bluePlanet = CompositionPreset(
            id: UUID(uuidString: "00000005-0001-0001-0001-000000000005")!,
            name: "Blue Planet", icon: "globe.americas.fill",
            accentColorHex: "#0A84FF", isBuiltIn: true,
            category: .cosmic, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.1554, y: 0.1395),
                color2: CodableColor(x: 0.1599, y: 0.3109),
                color3: CodableColor(x: 0.1552, y: 0.1320)),
            motion: MotionConfig(pattern: .spiral, speed: 18, spread: 74, offset: 58),
            envelope: EnvelopeConfig(shape: .swell, bpm: 22, depth: 22, minBrightness: 30, maxBrightness: 94),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let nebulaDrift = CompositionPreset(
            id: UUID(uuidString: "00000005-0001-0001-0001-000000000006")!,
            name: "Nebula Drift", icon: "aqi.medium",
            accentColorHex: "#FF6EC7", isBuiltIn: true,
            category: .cosmic, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.1996, y: 0.0725),
                color2: CodableColor(x: 0.4411, y: 0.2345),
                color3: CodableColor(x: 0.1581, y: 0.2429)),
            motion: MotionConfig(pattern: .wave, speed: 15, spread: 82, offset: 64),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 20, depth: 20, minBrightness: 32, maxBrightness: 94),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let fireside = CompositionPreset(
            id: UUID(uuidString: "00000006-0001-0001-0001-000000000001")!,
            name: "Fireside", icon: "flame.fill",
            accentColorHex: "#FF9F0A", isBuiltIn: true,
            category: .cozy, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.6355, y: 0.3504),
                color2: CodableColor(x: 0.5167, y: 0.4098),
                color3: CodableColor(x: 0.6748, y: 0.3209)),
            motion: MotionConfig(pattern: .twinkle, speed: 26, spread: 62, offset: 45),
            envelope: EnvelopeConfig(shape: .flicker, bpm: 34, depth: 32, minBrightness: 26, maxBrightness: 96),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let candlelitDinner = CompositionPreset(
            id: UUID(uuidString: "00000006-0001-0001-0001-000000000002")!,
            name: "Candlelit Dinner", icon: "flame",
            accentColorHex: "#FFB84D", isBuiltIn: true,
            category: .cozy, seasonMonths: nil,
            palette: PaletteConfig(mode: .temperature, temperature: 450),
            motion: MotionConfig(pattern: .twinkle, speed: 14, spread: 55, offset: 40),
            envelope: EnvelopeConfig(shape: .flicker, bpm: 24, depth: 20, minBrightness: 34, maxBrightness: 88),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let goldenHour = CompositionPreset(
            id: UUID(uuidString: "00000006-0001-0001-0001-000000000003")!,
            name: "Golden Hour", icon: "sun.max.fill",
            accentColorHex: "#FFCC66", isBuiltIn: true,
            category: .cozy, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.5215, y: 0.4121),
                color2: CodableColor(x: 0.4054, y: 0.4006)),
            motion: MotionConfig(pattern: .wave, speed: 12, spread: 60, offset: 48),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 20, depth: 14, minBrightness: 44, maxBrightness: 98),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let amberEvening = CompositionPreset(
            id: UUID(uuidString: "00000006-0001-0001-0001-000000000004")!,
            name: "Amber Evening", icon: "lamp.table.fill",
            accentColorHex: "#FF9F0A", isBuiltIn: true,
            category: .cozy, seasonMonths: nil,
            palette: PaletteConfig(mode: .temperature, temperature: 470),
            motion: MotionConfig(pattern: .static, speed: 0),
            envelope: EnvelopeConfig(shape: .steady, minBrightness: 20, maxBrightness: 76),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let readingNook = CompositionPreset(
            id: UUID(uuidString: "00000006-0001-0001-0001-000000000005")!,
            name: "Reading Nook", icon: "book.fill",
            accentColorHex: "#FFD79A", isBuiltIn: true,
            category: .cozy, seasonMonths: nil,
            palette: PaletteConfig(mode: .temperature, temperature: 370),
            motion: MotionConfig(pattern: .static, speed: 0),
            envelope: EnvelopeConfig(shape: .steady, minBrightness: 20, maxBrightness: 90),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let rainyCafe = CompositionPreset(
            id: UUID(uuidString: "00000006-0001-0001-0001-000000000006")!,
            name: "Rainy Café", icon: "cup.and.saucer.fill",
            accentColorHex: "#C99A6E", isBuiltIn: true,
            category: .cozy, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.4595, y: 0.3758),
                color2: CodableColor(x: 0.4194, y: 0.3673)),
            motion: MotionConfig(pattern: .scatter, speed: 10, spread: 48, offset: 42),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 20, depth: 12, minBrightness: 40, maxBrightness: 84),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let deepFocus = CompositionPreset(
            id: UUID(uuidString: "00000007-0001-0001-0001-000000000001")!,
            name: "Deep Focus", icon: "brain.head.profile",
            accentColorHex: "#64D2FF", isBuiltIn: true,
            category: .focus, seasonMonths: nil,
            palette: PaletteConfig(mode: .temperature, temperature: 180),
            motion: MotionConfig(pattern: .static, speed: 0),
            envelope: EnvelopeConfig(shape: .steady, minBrightness: 20, maxBrightness: 100),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let energize = CompositionPreset(
            id: UUID(uuidString: "00000007-0001-0001-0001-000000000002")!,
            name: "Energize", icon: "bolt.fill",
            accentColorHex: "#FFFFFF", isBuiltIn: true,
            category: .focus, seasonMonths: nil,
            palette: PaletteConfig(mode: .temperature, temperature: 160),
            motion: MotionConfig(pattern: .static, speed: 0),
            envelope: EnvelopeConfig(shape: .steady, minBrightness: 20, maxBrightness: 100),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let unwind = CompositionPreset(
            id: UUID(uuidString: "00000007-0001-0001-0001-000000000003")!,
            name: "Unwind", icon: "figure.mind.and.body",
            accentColorHex: "#FF9F80", isBuiltIn: true,
            category: .focus, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.5004, y: 0.3482),
                color2: CodableColor(x: 0.3896, y: 0.3513)),
            motion: MotionConfig(pattern: .wave, speed: 10, spread: 55, offset: 45),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 22, depth: 16, minBrightness: 36, maxBrightness: 86),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let meditation = CompositionPreset(
            id: UUID(uuidString: "00000007-0001-0001-0001-000000000004")!,
            name: "Meditation", icon: "leaf.fill",
            accentColorHex: "#66D6A6", isBuiltIn: true,
            category: .focus, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.1993, y: 0.4414),
                color2: CodableColor(x: 0.2819, y: 0.3629)),
            motion: MotionConfig(pattern: .wave, speed: 8, spread: 52, offset: 44),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 20, depth: 18, minBrightness: 34, maxBrightness: 82),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let sunriseWake = CompositionPreset(
            id: UUID(uuidString: "00000007-0001-0001-0001-000000000005")!,
            name: "Sunrise Wake", icon: "sunrise.fill",
            accentColorHex: "#FFB000", isBuiltIn: true,
            category: .focus, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.3170, y: 0.1624),
                color2: CodableColor(x: 0.5775, y: 0.3702),
                color3: CodableColor(x: 0.3917, y: 0.3866)),
            motion: MotionConfig(pattern: .wave, speed: 9, spread: 58, offset: 50),
            envelope: EnvelopeConfig(shape: .swell, bpm: 22, depth: 24, minBrightness: 20, maxBrightness: 100),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let nightEase = CompositionPreset(
            id: UUID(uuidString: "00000007-0001-0001-0001-000000000006")!,
            name: "Night Ease", icon: "moon.stars.fill",
            accentColorHex: "#6E7BC9", isBuiltIn: true,
            category: .focus, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.2129, y: 0.1772),
                color2: CodableColor(x: 0.2235, y: 0.1998)),
            motion: MotionConfig(pattern: .wave, speed: 8, spread: 50, offset: 46),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 20, depth: 20, minBrightness: 22, maxBrightness: 70),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let neonNights = CompositionPreset(
            id: UUID(uuidString: "00000002-0001-0001-0001-000000000004")!,
            name: "Neon Nights", icon: "light.beacon.max.fill",
            accentColorHex: "#FF2D95", isBuiltIn: true,
            category: .energetic, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.5387, y: 0.2372),
                color2: CodableColor(x: 0.1596, y: 0.3009),
                color3: CodableColor(x: 0.2127, y: 0.0788)),
            motion: MotionConfig(pattern: .chase, speed: 72, spread: 60, offset: 70),
            envelope: EnvelopeConfig(shape: .pulse, bpm: 128, depth: 60, minBrightness: 16, maxBrightness: 100),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let discoInferno = CompositionPreset(
            id: UUID(uuidString: "00000002-0001-0001-0001-000000000005")!,
            name: "Disco Inferno", icon: "circle.grid.cross.fill",
            accentColorHex: "#FF375F", isBuiltIn: true,
            category: .energetic, seasonMonths: nil,
            palette: PaletteConfig(mode: .spectrum, saturation: 100),
            motion: MotionConfig(pattern: .spiral, speed: 80, spread: 75, offset: 66),
            envelope: EnvelopeConfig(shape: .pulse, bpm: 132, depth: 65, minBrightness: 14, maxBrightness: 100),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let festivalSunset = CompositionPreset(
            id: UUID(uuidString: "00000002-0001-0001-0001-000000000006")!,
            name: "Festival Sunset", icon: "music.note",
            accentColorHex: "#FF6B35", isBuiltIn: true,
            category: .energetic, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.6006, y: 0.2783),
                color2: CodableColor(x: 0.5321, y: 0.4152),
                color3: CodableColor(x: 0.2151, y: 0.0897)),
            motion: MotionConfig(pattern: .cascade, speed: 62, spread: 72, offset: 60),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 120, depth: 45, minBrightness: 22, maxBrightness: 100),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let synthwave = CompositionPreset(
            id: UUID(uuidString: "00000002-0001-0001-0001-000000000007")!,
            name: "Synthwave", icon: "waveform.path",
            accentColorHex: "#FF00A0", isBuiltIn: true,
            category: .energetic, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.5236, y: 0.2268),
                color2: CodableColor(x: 0.1601, y: 0.3187)),
            motion: MotionConfig(pattern: .comet, speed: 68, spread: 76, offset: 64),
            envelope: EnvelopeConfig(shape: .pulse, bpm: 124, depth: 55, minBrightness: 18, maxBrightness: 100),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let arcade = CompositionPreset(
            id: UUID(uuidString: "00000002-0001-0001-0001-000000000008")!,
            name: "Arcade", icon: "gamecontroller.fill",
            accentColorHex: "#30D158", isBuiltIn: true,
            category: .energetic, seasonMonths: nil,
            palette: PaletteConfig(mode: .spectrum, saturation: 90),
            motion: MotionConfig(pattern: .chase, speed: 76, spread: 58, offset: 72),
            envelope: EnvelopeConfig(shape: .pulse, bpm: 136, depth: 62, minBrightness: 14, maxBrightness: 100),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let filmNoir = CompositionPreset(
            id: UUID(uuidString: "00000008-0001-0001-0001-000000000001")!,
            name: "Film Noir", icon: "camera.filters",
            accentColorHex: "#D0D0D0", isBuiltIn: true,
            category: .cinematic, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.3052, y: 0.3191),
                color2: CodableColor(x: 0.3123, y: 0.3232)),
            motion: MotionConfig(pattern: .scatter, speed: 12, spread: 45, offset: 40),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 20, depth: 22, minBrightness: 24, maxBrightness: 78),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let sciFiCorridor = CompositionPreset(
            id: UUID(uuidString: "00000008-0001-0001-0001-000000000002")!,
            name: "Sci-Fi Corridor", icon: "cube.transparent",
            accentColorHex: "#00E5FF", isBuiltIn: true,
            category: .cinematic, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.1596, y: 0.3009),
                color2: CodableColor(x: 0.1597, y: 0.1862)),
            motion: MotionConfig(pattern: .chase, speed: 34, spread: 66, offset: 60),
            envelope: EnvelopeConfig(shape: .pulse, bpm: 60, depth: 40, minBrightness: 18, maxBrightness: 96),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let hauntedManor = CompositionPreset(
            id: UUID(uuidString: "00000008-0001-0001-0001-000000000003")!,
            name: "Haunted Manor", icon: "house.fill",
            accentColorHex: "#8E44AD", isBuiltIn: true,
            category: .cinematic, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.3396, y: 0.1498),
                color2: CodableColor(x: 0.2734, y: 0.5885)),
            motion: MotionConfig(pattern: .twinkle, speed: 24, spread: 68, offset: 42),
            envelope: EnvelopeConfig(shape: .flicker, bpm: 30, depth: 40, minBrightness: 14, maxBrightness: 90),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let enchantedForest = CompositionPreset(
            id: UUID(uuidString: "00000008-0001-0001-0001-000000000004")!,
            name: "Enchanted Forest", icon: "sparkles.rectangle.stack",
            accentColorHex: "#5AC8A8", isBuiltIn: true,
            category: .cinematic, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.1768, y: 0.4314),
                color2: CodableColor(x: 0.2038, y: 0.4008),
                color3: CodableColor(x: 0.2676, y: 0.1892)),
            motion: MotionConfig(pattern: .twinkle, speed: 20, spread: 72, offset: 48),
            envelope: EnvelopeConfig(shape: .breathe, bpm: 22, depth: 22, minBrightness: 28, maxBrightness: 92),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        let deepSeaDive = CompositionPreset(
            id: UUID(uuidString: "00000008-0001-0001-0001-000000000005")!,
            name: "Deep Sea Dive", icon: "fish.fill",
            accentColorHex: "#0AB6D8", isBuiltIn: true,
            category: .cinematic, seasonMonths: nil,
            palette: PaletteConfig(mode: .gradient,
                color1: CodableColor(x: 0.1561, y: 0.1658),
                color2: CodableColor(x: 0.1605, y: 0.2789)),
            motion: MotionConfig(pattern: .wave, speed: 14, spread: 76, offset: 58),
            envelope: EnvelopeConfig(shape: .swell, bpm: 20, depth: 26, minBrightness: 20, maxBrightness: 88),
            reaction: ReactionConfig(),
            createdAt: now, updatedAt: now
        )

        return [
            // Ambient
            sunsetCascade, oceanDrift, northernLights, cozyEvening, heartbeat,
            // Energetic
            bassDrop, clubMode, stormChase,
            // Holiday
            christmas, winterWonderland, halloween, valentines,
            fourthOfJuly, stPatricks, easter, hanukkah,
            diwali, newYears, thanksgiving, mardiGras,
            // Nature
            savannaSunset, tropicalTwilight, springBlossom, forestCanopy,
            oceanDepths, mistyMorning, thunderhead, desertDusk,
            // Cosmic
            galaxy, starlight, meteorShower, bloodMoon,
            bluePlanet, nebulaDrift,
            // Cozy
            fireside, candlelitDinner, goldenHour, amberEvening,
            readingNook, rainyCafe,
            // Focus
            deepFocus, energize, unwind, meditation,
            sunriseWake, nightEase,
            // Energetic
            neonNights, discoInferno, festivalSunset, synthwave,
            arcade,
            // Cinematic
            filmNoir, sciFiCorridor, hauntedManor, enchantedForest,
            deepSeaDive,
        ]
    }()
    // swiftlint:enable function_body_length
}

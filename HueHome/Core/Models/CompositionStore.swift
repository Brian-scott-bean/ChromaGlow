// CompositionStore.swift
// ChromaGlow — Composer v0.17.0
//
// JSON persistence for saved compositions.
// Loads on app launch, saves on every create/edit/delete.
// Built-in presets included on first launch (20 starter presets).

import Foundation

// MARK: - CompositionStore

@Observable
final class CompositionStore {

    private(set) var presets: [CompositionPreset] = []

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("compositions.json")
    }()

    init() {
        load()
    }

    // MARK: - CRUD

    func save(_ preset: CompositionPreset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        persist()
    }

    func delete(_ preset: CompositionPreset) {
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

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // First launch — seed with built-in presets
            presets = Self.builtInPresets
            persist()
            return
        }
        // M-13: this read path must NEVER destroy user data.
        //  - Elements decode leniently: one malformed preset is dropped, the
        //    rest survive (the whole-array decode used to throw and reseed).
        //  - On ANY decode problem the original file is backed up first and
        //    the source is never overwritten from this path — the next
        //    user-initiated save() is the first legitimate writer.
        do {
            let data = try Data(contentsOf: fileURL)
            let wrapped = try JSONDecoder().decode([FailableDecodable<CompositionPreset>].self, from: data)
            let good = wrapped.compactMap(\.value)
            if good.count < wrapped.count {
                print("[CompositionStore] ⚠ \(wrapped.count - good.count) preset(s) failed to decode — keeping \(good.count), backing up the original file")
                backUpCompositionsFile()
            }
            presets = good.isEmpty ? Self.builtInPresets : good
        } catch {
            // The file is not a decodable array at all. Preserve the bytes in
            // a timestamped .bak, run in-memory on defaults, and DO NOT
            // persist() — overwriting the source on a read failure is how the
            // whole library used to vanish.
            print("[CompositionStore] Failed to load: \(error). Backing up file and running on defaults (source NOT overwritten).")
            backUpCompositionsFile()
            presets = Self.builtInPresets
        }
    }

    /// Copies compositions.json to a timestamped sibling before any recovery
    /// path can lose data (M-13).
    private func backUpCompositionsFile() {
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

    // MARK: - Built-in Presets (20)

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
                color2: CodableColor(x: 0.1500, y: 0.0600)),  // deep blue
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
                color2: CodableColor(x: 0.1500, y: 0.0600)),  // deep blue
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
                color2: CodableColor(x: 0.5400, y: 0.2300)),  // pink
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
                color3: CodableColor(x: 0.1500, y: 0.0600)),  // blue
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
                color1: CodableColor(x: 0.2100, y: 0.7100),   // bright green
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
                color1: CodableColor(x: 0.1500, y: 0.0600),   // blue
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

        return [
            // Ambient
            sunsetCascade, oceanDrift, northernLights, cozyEvening, heartbeat,
            // Energetic
            bassDrop, clubMode, stormChase,
            // Holiday
            christmas, winterWonderland, halloween, valentines,
            fourthOfJuly, stPatricks, easter, hanukkah,
            diwali, newYears, thanksgiving, mardiGras,
        ]
    }()
    // swiftlint:enable function_body_length
}

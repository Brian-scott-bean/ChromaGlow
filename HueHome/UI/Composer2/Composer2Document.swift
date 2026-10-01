// Composer2Document.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The one mutable document behind the whole screen. Quick, Customize,
// Advanced and Expert are four views into `composition`; nothing here is
// duplicated per mode. Edits are synchronous (a slider writes straight into
// the value) and the live runtime reads the value on its next frame.

import Foundation
import Observation

/// The three tabs of the Composer: start from a look, tune it, or build it.
enum Composer2Mode: String, CaseIterable, Identifiable {
    case looks, tune, layers
    var id: String { rawValue }
    var title: String {
        switch self {
        case .looks: return "Looks"
        case .tune: return "Tune"
        case .layers: return "Layers"
        }
    }
    var symbol: String {
        switch self {
        case .looks: return "square.grid.2x2.fill"
        case .tune: return "slider.horizontal.3"
        case .layers: return "square.3.layers.3d"
        }
    }
}

enum Composer2Editor: String, Identifiable, CaseIterable {
    case palette, motion, rhythm, space, events, audio, variation, layer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .palette: return "Color"
        case .motion: return "Motion"
        case .rhythm: return "Rhythm"
        case .space: return "Space"
        case .audio: return "Sound"
        case .variation: return "Variation"
        case .events: return "Moments"
        case .layer: return "Layer"
        }
    }
    var symbol: String {
        switch self {
        case .events: return "bolt.fill"
        case .layer: return "square.2.layers.3d"
        default: return dimension?.symbol ?? "circle"
        }
    }
    var dimension: Composer2Dimension? {
        switch self {
        case .palette: return .palette
        case .motion: return .motion
        case .rhythm: return .rhythm
        case .space: return .space
        case .audio: return .audio
        case .variation: return .variation
        case .events, .layer: return nil
        }
    }
}

/// What the screen knows about the room it is composing for.
struct Composer2RoomContext: Equatable {
    var room: RoomDisplayItem?
    var lights: [LightDisplayItem] = []
    var layout: Composer2SlotLayout = .empty
    var isDemo: Bool = false
    /// Compact connection line for the header ("Living Room · 5 lights").
    var connectionText: String = ""
    /// The header's connection pill opens the area chooser (several areas,
    /// or one already picked that can be changed).
    var canChooseArea = false

    static let none = Composer2RoomContext()

    var roomName: String { room?.name ?? "No room" }
    var lightCount: Int { layout.isEmpty ? lights.count : layout.lightCount }
}

@MainActor
@Observable
final class Composer2Document {
    var composition: Composer2Composition
    var mode: Composer2Mode = .looks
    var selectedLayerID: UUID
    var selectedSlots: Set<Int> = []
    var activeEditor: Composer2Editor? = nil
    var roomContext: Composer2RoomContext
    var isDirty = false
    /// The stored composition this document was opened from (nil = unsaved).
    var sourceID: UUID?
    /// A look waiting for the user's OK to replace unsaved changes (a mood
    /// chip tapped with edits pending). Nothing is discarded silently.
    var pendingReplacement: Composer2Composition?

    /// Fired after every edit; the playback center hooks it to flush Room-mode writes.
    @ObservationIgnored var onEdit: (() -> Void)?

    /// What a dimension held when it was switched off, per behavior, so
    /// switching it back on restores it (a Chase came back as Flow, Bass as
    /// Amplitude, tuned variation as "Organic", lightning as the default
    /// event spec). Session memory only — never saved.
    struct DimensionStash {
        var motionKind: Composer2Motion.Kind?
        var rhythmShape: Composer2Rhythm.Shape?
        var audioSource: Composer2AudioModulation.Source?
        var variationAmount: Double?
        var events: Composer2EventSpec?
    }
    @ObservationIgnored var dimensionStash: [UUID: DimensionStash] = [:]

    /// Events on/off for the selected behavior, restoring the spec it had.
    func setEvents(enabled: Bool, default fallback: Composer2EventSpec) {
        let id = selectedLayer.id
        if !enabled, let current = selectedLayer.events {
            dimensionStash[id, default: DimensionStash()].events = current
        }
        let restored = dimensionStash[id]?.events ?? fallback
        editSelectedLayer { $0.events = enabled ? restored : nil }
    }

    init(composition: Composer2Composition, roomContext: Composer2RoomContext = .none) {
        self.composition = composition
        self.roomContext = roomContext
        self.selectedLayerID = composition.layers.first?.id ?? UUID()
        self.sourceID = composition.id
        syncSelectionToSelectedLayer()
    }

    // MARK: Selection

    var selectedLayerIndex: Int {
        composition.layers.firstIndex { $0.id == selectedLayerID } ?? 0
    }

    var selectedLayer: Composer2Layer {
        guard !composition.layers.isEmpty else { return .blank() }
        return composition.layers[min(selectedLayerIndex, composition.layers.count - 1)]
    }

    var hasSelectedLayer: Bool { !composition.layers.isEmpty }

    func select(layerID: UUID) {
        guard composition.layers.contains(where: { $0.id == layerID }) else { return }
        selectedLayerID = layerID
        syncSelectionToSelectedLayer()
    }

    /// The on-screen light selection belongs to ONE behavior: it is read back
    /// from that behavior's mask whenever the selected behavior changes. A
    /// document-wide set leaked across behaviors — picking lights for the
    /// sparkle layer and then one light on the base layer rewrote the base
    /// layer's mask with the sparkle layer's lights plus one.
    func syncSelectionToSelectedLayer() {
        guard hasSelectedLayer else {
            selectedSlots = []
            return
        }
        let mask = selectedLayer.mask
        selectedSlots = mask.kind == .slots && !mask.invert ? Set(mask.slots.filter { $0 >= 0 }) : []
    }

    // MARK: Undo

    /// Earlier versions of the composition, newest last. A drag is one step:
    /// edits closer together than `undoCoalesce` fold into the step before.
    private(set) var undoStack: [Composer2Composition] = []
    private(set) var redoStack: [Composer2Composition] = []
    @ObservationIgnored private var lastUndoPush: Double = -.infinity
    /// Injectable clock (seconds) for tests.
    @ObservationIgnored var undoClock: () -> Double = { Date().timeIntervalSinceReferenceDate }
    static let undoLimit = 60
    static let undoCoalesce: Double = 0.6

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func recordUndo(_ previous: Composer2Composition) {
        let t = undoClock()
        if t - lastUndoPush >= Composer2Document.undoCoalesce || undoStack.isEmpty {
            undoStack.append(previous)
            if undoStack.count > Composer2Document.undoLimit { undoStack.removeFirst() }
        }
        lastUndoPush = t
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(composition)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(composition)
        restore(next)
    }

    private func restore(_ version: Composer2Composition) {
        let layerIndex = selectedLayerIndex
        composition = version
        if !version.layers.contains(where: { $0.id == selectedLayerID }) {
            selectedLayerID = version.layers[min(layerIndex, max(0, version.layers.count - 1))].id
        }
        syncSelectionToSelectedLayer()
        isDirty = true
        lastUndoPush = -.infinity
        onEdit?()
    }

    // MARK: Editing

    func edit(_ mutate: (inout Composer2Composition) -> Void) {
        let before = composition
        // Mutate a copy, then store it. Mutating `composition` in place held
        // write access for the whole closure, so an editor closure that read
        // the document (`stops`, `selectedLayer`…) aborted the app with a
        // Swift exclusivity violation — the palette "+" crash (build 60).
        var next = before
        mutate(&next)
        guard next != before else { return }
        composition = next
        recordUndo(before)
        isDirty = true
        onEdit?()
    }

    func editSelectedLayer(_ mutate: (inout Composer2Layer) -> Void) {
        guard !composition.layers.isEmpty else { return }
        let index = min(selectedLayerIndex, composition.layers.count - 1)
        edit { $0.layers[index] = { var l = $0.layers[index]; mutate(&l); return l }($0) }
    }

    func editLayer(id: UUID, _ mutate: (inout Composer2Layer) -> Void) {
        guard let index = composition.layers.firstIndex(where: { $0.id == id }) else { return }
        edit { composition in
            var layer = composition.layers[index]
            mutate(&layer)
            composition.layers[index] = layer
        }
    }

    /// Replace the whole composition (mood chips, presets, reopening a saved one).
    func load(_ new: Composer2Composition, asSource: Bool = true) {
        undoStack.removeAll()
        redoStack.removeAll()
        lastUndoPush = -.infinity
        composition = new
        selectedLayerID = new.layers.first?.id ?? UUID()
        syncSelectionToSelectedLayer()
        isDirty = false
        if asSource { sourceID = new.id }
        onEdit?()
    }

    /// Open another look. With unsaved edits it waits in
    /// `pendingReplacement` for a confirmation instead of discarding them.
    func requestReplacement(_ next: Composer2Composition) {
        var incoming = next
        incoming.target = composition.target
        if isDirty {
            pendingReplacement = incoming
        } else {
            load(incoming)
        }
    }

    func confirmPendingReplacement() {
        guard let next = pendingReplacement else { return }
        pendingReplacement = nil
        load(next)
    }

    /// After a save: the document now IS the saved composition — clean, and
    /// owned — but the user keeps their place. Reloading moved the selection
    /// back to the first behavior, so the open editor silently switched layers.
    func adoptSaved(_ saved: Composer2Composition) {
        let index = selectedLayerIndex
        composition = saved
        sourceID = saved.id
        isDirty = false
        if saved.layers.indices.contains(index) {
            selectedLayerID = saved.layers[index].id
        } else {
            selectedLayerID = saved.layers.first?.id ?? UUID()
        }
        syncSelectionToSelectedLayer()
        onEdit?()
    }

    func rename(_ name: String, subtitle: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit {
            $0.name = trimmed
            if let subtitle { $0.subtitle = subtitle }
        }
    }

    var usesAudio: Bool { composition.usesAudio }

    // MARK: Expert stack

    @discardableResult
    func addLayer(_ layer: Composer2Layer) -> Composer2Layer {
        var fresh = layer
        fresh.id = UUID()
        edit { $0.layers.append(fresh) }
        selectedLayerID = fresh.id
        syncSelectionToSelectedLayer()
        return fresh
    }

    /// Returns false when the last behavior would be removed.
    @discardableResult
    func removeLayer(id: UUID) -> Bool {
        guard composition.layers.count > 1, let index = composition.layers.firstIndex(where: { $0.id == id }) else { return false }
        edit { $0.layers.remove(at: index) }
        if selectedLayerID == id {
            selectedLayerID = composition.layers[min(index, composition.layers.count - 1)].id
            syncSelectionToSelectedLayer()
        }
        return true
    }

    func duplicateLayer(id: UUID) {
        guard let index = composition.layers.firstIndex(where: { $0.id == id }) else { return }
        var copy = composition.layers[index]
        copy.id = UUID()
        copy.name += " copy"
        edit { $0.layers.insert(copy, at: index + 1) }
        selectedLayerID = copy.id
        syncSelectionToSelectedLayer()
    }

    func moveLayer(id: UUID, up: Bool) {
        guard let index = composition.layers.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index - 1 : index + 1
        guard target >= 0, target < composition.layers.count else { return }
        edit { $0.layers.swapAt(index, target) }
    }

    /// Drag-and-drop reorder: put `id` where `targetID` sits.
    func moveLayer(id: UUID, onto targetID: UUID) {
        guard id != targetID,
              let from = composition.layers.firstIndex(where: { $0.id == id }),
              let to = composition.layers.firstIndex(where: { $0.id == targetID }) else { return }
        edit { composition in
            let layer = composition.layers.remove(at: from)
            composition.layers.insert(layer, at: to)
        }
    }

    /// True when the document came from a composition the user owns (so
    /// Save can overwrite it); built-ins and imports always save as new.
    var isSourceUserOwned: Bool {
        guard let sourceID else { return false }
        return Composer2Store.shared.compositions.contains { $0.id == sourceID }
    }

    /// Bring a legacy Composer preset in as one behavior (non-destructive).
    func importLegacy(_ preset: CompositionPreset, now: Date = Date()) {
        var imported = Composer2LegacyImport.composition(from: preset, now: now)
        imported.target = composition.target
        load(imported, asSource: false)
        sourceID = nil
        isDirty = true   // an import is unsaved work until the user saves it
    }

    func setLayer(id: UUID, enabled: Bool) {
        editLayer(id: id) { $0.enabled = enabled }
    }

    // MARK: Space helpers

    /// Apply the current node selection to the selected layer's mask.
    func applySelectionToMask() {
        let slots = selectedSlots.sorted()
        editSelectedLayer { layer in
            if slots.isEmpty {
                layer.mask = .wholeRoom
            } else {
                layer.mask = .slots(slots)
            }
        }
    }

    func toggleSlot(_ slot: Int) {
        if selectedSlots.contains(slot) { selectedSlots.remove(slot) } else { selectedSlots.insert(slot) }
        applySelectionToMask()
    }
}

// MARK: - Dimension on/off semantics

extension Composer2Dimension {
    /// Whether the dimension is "doing something" on this layer.
    func isOn(in layer: Composer2Layer) -> Bool {
        switch self {
        case .palette: return true
        case .motion: return layer.motion.kind != .static
        case .rhythm: return layer.rhythm.shape != .steady
        case .space: return true
        case .audio: return layer.audio.isActive
        case .variation: return layer.variation.amount > 0
        }
    }
}

extension Composer2Document {
    /// Turn a dimension off without losing its settings, and back on with a
    /// sensible restore (the last kind is kept in the value itself where possible).
    func setDimension(_ dimension: Composer2Dimension, on: Bool) {
        let id = selectedLayer.id
        var stash = dimensionStash[id] ?? DimensionStash()
        editSelectedLayer { layer in
            switch dimension {
            case .palette, .space:
                break
            case .motion:
                if on {
                    if layer.motion.kind == .static { layer.motion.kind = stash.motionKind ?? .flow }
                } else {
                    if layer.motion.kind != .static { stash.motionKind = layer.motion.kind }
                    layer.motion.kind = .static
                }
            case .rhythm:
                if on {
                    if layer.rhythm.shape == .steady { layer.rhythm.shape = stash.rhythmShape ?? .breathe }
                } else {
                    if layer.rhythm.shape != .steady { stash.rhythmShape = layer.rhythm.shape }
                    layer.rhythm.shape = .steady
                }
            case .audio:
                if on {
                    if !layer.audio.isActive { layer.audio.source = stash.audioSource ?? .amplitude }
                } else {
                    if layer.audio.isActive { stash.audioSource = layer.audio.source }
                    layer.audio.source = .off
                }
            case .variation:
                if on {
                    if layer.variation.amount <= 0 {
                        if let amount = stash.variationAmount {
                            layer.variation.amount = amount   // the rest of it was never touched
                        } else {
                            layer.variation = Composer2Variation.organic.withSeed(layer.variation.seed)
                        }
                    }
                } else {
                    if layer.variation.amount > 0 { stash.variationAmount = layer.variation.amount }
                    layer.variation.amount = 0
                }
            }
        }
        dimensionStash[id] = stash
    }
}

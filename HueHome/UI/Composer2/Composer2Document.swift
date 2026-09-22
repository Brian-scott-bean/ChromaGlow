// Composer2Document.swift
// ChromaGlow — Composer 2 lab (experimental).
//
// The one mutable document behind the whole screen. Quick, Customize,
// Advanced and Expert are four views into `composition`; nothing here is
// duplicated per mode. Edits are synchronous (a slider writes straight into
// the value) and the live runtime reads the value on its next frame.

import Foundation
import Observation

enum Composer2Mode: String, CaseIterable, Identifiable {
    case quick, customize, advanced, expert
    var id: String { rawValue }
    var title: String {
        switch self {
        case .quick: return "Quick"
        case .customize: return "Customize"
        case .advanced: return "Advanced"
        case .expert: return "Expert"
        }
    }
}

enum Composer2Editor: String, Identifiable, CaseIterable {
    case palette, motion, rhythm, space, audio, variation, events
    var id: String { rawValue }
    var title: String {
        switch self {
        case .palette: return "Palette"
        case .motion: return "Motion"
        case .rhythm: return "Rhythm"
        case .space: return "Space"
        case .audio: return "Audio"
        case .variation: return "Variation"
        case .events: return "Events"
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
        case .events: return nil
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

    static let none = Composer2RoomContext()

    var roomName: String { room?.name ?? "No room" }
    var lightCount: Int { layout.isEmpty ? lights.count : layout.lightCount }
}

@MainActor
@Observable
final class Composer2Document {
    var composition: Composer2Composition
    var mode: Composer2Mode = .customize
    var selectedLayerID: UUID
    var selectedSlots: Set<Int> = []
    var activeEditor: Composer2Editor? = nil
    var roomContext: Composer2RoomContext
    var isDirty = false
    /// The stored composition this document was opened from (nil = unsaved).
    var sourceID: UUID?

    /// Fired after every edit; the playback center hooks it to flush Room-mode writes.
    @ObservationIgnored var onEdit: (() -> Void)?

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

    // MARK: Editing

    func edit(_ mutate: (inout Composer2Composition) -> Void) {
        mutate(&composition)
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
        composition = new
        selectedLayerID = new.layers.first?.id ?? UUID()
        syncSelectionToSelectedLayer()
        isDirty = false
        if asSource { sourceID = new.id }
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

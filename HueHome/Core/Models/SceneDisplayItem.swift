// SceneDisplayItem.swift
// HueHome Pro — Epic 4 / Story 4.1
//
// SceneDisplayItem  — per-room scene chip (used in RoomDetailView scene strip)
// GlobalSceneItem   — cross-bridge scene with room context (used in ScenesTabView grid)

import SwiftUI

// ══════════════════════════════════════════════════════════
// MARK: - SceneDisplayItem  (per-room)
// ══════════════════════════════════════════════════════════

struct SceneDisplayItem: Identifiable, Hashable {
    let id: String
    var name: String     // var — allows optimistic rename via copy-mutate-assign
    var isActive: Bool

    // Derived from name — used for chip accent colour and icon.
    var accentColor: Color { SceneDisplayItem.color(for: name) }
    var icon: String       { SceneDisplayItem.icon(for: name) }

    // ──────────────────────────────────────────────
    // MARK: - Name → Color
    // ──────────────────────────────────────────────

    static func color(for name: String) -> Color {
        let n = name.lowercased()
        if n.contains("relax")                          { return Color(red: 1.0, green: 0.60, blue: 0.20) }
        if n.contains("energize")                       { return Color(red: 0.25, green: 0.70, blue: 1.0) }
        if n.contains("concentrat") || n.contains("focus") { return Color(red: 0.75, green: 0.90, blue: 1.0) }
        if n.contains("read")                           { return Color(red: 1.0,  green: 0.88, blue: 0.50) }
        if n.contains("bright")                         { return Color(red: 1.0,  green: 0.95, blue: 0.70) }
        if n.contains("dim")                            { return Color(red: 0.55, green: 0.30, blue: 0.85) }
        if n.contains("nightlight") || n.contains("night light") { return Color(red: 1.0, green: 0.20, blue: 0.05) }
        if n.contains("night")                          { return Color(red: 0.40, green: 0.20, blue: 0.70) }
        if n.contains("sleep")                          { return Color(red: 0.25, green: 0.15, blue: 0.60) }
        if n.contains("romance")                        { return Color(red: 1.0,  green: 0.20, blue: 0.45) }
        if n.contains("party") || n.contains("disco")  { return Color(red: 0.90, green: 0.20, blue: 0.85) }
        if n.contains("galaxy") || n.contains("space") { return Color(red: 0.35, green: 0.20, blue: 0.95) }
        if n.contains("spring")                         { return Color(red: 0.40, green: 0.90, blue: 0.45) }
        if n.contains("summer")                         { return Color(red: 1.0,  green: 0.75, blue: 0.15) }
        if n.contains("autumn") || n.contains("fall")  { return Color(red: 0.95, green: 0.45, blue: 0.15) }
        if n.contains("winter") || n.contains("arctic"){ return Color(red: 0.50, green: 0.82, blue: 1.0) }
        if n.contains("golden") || n.contains("warm")  { return Color(red: 1.0,  green: 0.65, blue: 0.25) }
        if n.contains("cool")                           { return Color(red: 0.40, green: 0.75, blue: 0.95) }
        if n.contains("fire") || n.contains("flame")   { return Color(red: 1.0,  green: 0.35, blue: 0.00) }
        if n.contains("ocean") || n.contains("tropical"){ return Color(red: 0.00, green: 0.75, blue: 0.85) }
        if n.contains("forest") || n.contains("nature"){ return Color(red: 0.25, green: 0.75, blue: 0.35) }
        return Color(red: 0.60, green: 0.40, blue: 0.90)    // default purple
    }

    // ──────────────────────────────────────────────
    // MARK: - Name → SF Symbol
    // ──────────────────────────────────────────────

    static func icon(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("relax")                             { return "moon.stars.fill" }
        if n.contains("energize")                          { return "bolt.fill" }
        if n.contains("concentrat") || n.contains("focus") { return "brain.head.profile" }
        if n.contains("read")                              { return "book.fill" }
        if n.contains("bright")                            { return "sun.max.fill" }
        if n.contains("nightlight") || n.contains("night light") { return "moon.zzz.fill" }
        if n.contains("dim")                               { return "moon.fill" }
        if n.contains("night")                             { return "moon.fill" }
        if n.contains("sleep")                             { return "zzz" }
        if n.contains("romance")                           { return "heart.fill" }
        if n.contains("party") || n.contains("disco")      { return "music.note" }
        if n.contains("galaxy") || n.contains("space")     { return "sparkles" }
        if n.contains("spring")                            { return "leaf.fill" }
        if n.contains("summer")                            { return "sun.horizon.fill" }
        if n.contains("autumn") || n.contains("fall")      { return "wind.snow" }
        if n.contains("winter") || n.contains("arctic")    { return "snowflake" }
        if n.contains("warm") || n.contains("golden")      { return "flame.fill" }
        if n.contains("cool")                              { return "thermometer.snowflake" }
        if n.contains("fire") || n.contains("flame")       { return "flame.fill" }
        if n.contains("ocean") || n.contains("tropical")   { return "water.waves" }
        if n.contains("forest") || n.contains("nature")    { return "tree.fill" }
        if n.contains("movie") || n.contains("cinema")     { return "popcorn.fill" }
        if n.contains("dinner") || n.contains("eating")    { return "fork.knife" }
        return "wand.and.stars"
    }

    static func == (lhs: SceneDisplayItem, rhs: SceneDisplayItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// ══════════════════════════════════════════════════════════
// MARK: - GlobalSceneItem  (cross-bridge, used by ScenesTabView)
//
// Carries room + bridge context so the Scenes tab can display
// room labels, activate via the correct bridge client, and
// support cross-bridge deduplication.
//
// id = "\(bridgeID):\(bridgeSceneID)" — globally unique.
// ══════════════════════════════════════════════════════════

struct GlobalSceneItem: Identifiable, Hashable {
    let id:            String   // globally unique composite key
    let bridgeSceneID: String   // real Hue scene UUID (used for API calls)
    let name:          String
    let roomID:        String   // Hue room/zone UUID on this bridge
    let bridgeID:      String   // which bridge owns this scene

    var isActive:   Bool
    var isDynamic:  Bool        // true = Hue dynamic palette scene (colours auto-cycle)
    var speed:      Double      // recall dynamics.speed 0.0–1.0; default 0.5

    // Reuse per-room colour + icon logic
    var accentColor: Color { SceneDisplayItem.color(for: name) }
    var icon:        String { SceneDisplayItem.icon(for: name) }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// HueDataModels.swift
// HueHome Pro — Stage 1 + Stage 2A SwiftData Model Layer
// Local-only metadata and logs — nothing here is sent to the Bridge.
// Bridge truth lives in the API. Local models are user overrides + history.

import SwiftUI
import SwiftData

// MARK: - Bridge Registry (Stage 2A)

/// One registered Philips Hue Bridge. The app supports N bridges simultaneously.
/// Credentials (ip + token) are stored in Keychain keyed by bridge.id;
/// this model stores everything else (name, order, accent color, last-seen stats).
@Model
final class BridgeRecord {
    @Attribute(.unique) var id: String    // UUID — also the Keychain credential key
    var name:            String           // user-given name (e.g. "Main Bridge")
    var host:            String           // IP address on local network
    var port:            Int              // 443 (HTTPS) or 80 (HTTP)
    var locationLabel:   String?          // "Living Area", "Garage", etc.
    var accentHex:       String?          // per-bridge accent color shown in UI
    var sortOrder:       Int
    var isActive:        Bool             // enabled/disabled — disabled = no SSE, no fetch
    var deviceCount:     Int             // last-known device count from Bridge
    var firmwareVersion: String?         // last-seen firmware
    var addedAt:         Date
    var lastSeenAt:      Date?

    init(
        id: String = UUID().uuidString,
        name: String,
        host: String,
        port: Int = 443,
        locationLabel: String? = nil,
        accentHex: String? = nil,
        sortOrder: Int = 999,
        isActive: Bool = true
    ) {
        self.id            = id
        self.name          = name
        self.host          = host
        self.port          = port
        self.locationLabel = locationLabel
        self.accentHex     = accentHex
        self.sortOrder     = sortOrder
        self.isActive      = isActive
        self.deviceCount   = 0
        self.addedAt       = Date()
        self.lastSeenAt    = nil
    }
}

// MARK: - Local Room Metadata

/// User customizations for a Bridge room — stored locally, never synced to Bridge
@Model
final class HueLocalRoom {
    @Attribute(.unique) var roomID: String   // matches Bridge room.id
    var bridgeID:     String?               // which bridge this room belongs to (nil = legacy single-bridge)
    var nameOverride:  String?               // custom display name
    var iconOverride:  String?               // SF Symbol name override
    var sortOrder:     Int                   // user-defined order (lower = first)
    var isPinned:      Bool                  // pinned rooms appear at top
    var isHidden:      Bool                  // hidden rooms don't show on dashboard
    var accentHex:     String?               // per-room color override (future)
    var groupTag:      String?               // custom room group label
    var createdAt:     Date
    var updatedAt:     Date

    // ──────────────────────────────────────────────
    // MARK: - Instant-startup cache (Stage 2A perf)
    // Written after each successful loadAll(). Read on launch to show
    // the dashboard immediately without waiting for the first API response.
    // ──────────────────────────────────────────────
    var cachedName:       String?   // last-seen room name from Bridge
    var lastIsOn:         Bool      // last-known on/off state
    var lastBrightness:   Double    // last-known brightness (1–100)
    var cachedLightCount: Int       // last-known light count
    var cachedArchetype:  String?   // last-seen archetype for icon

    init(
        roomID: String,
        bridgeID: String? = nil,
        nameOverride: String? = nil,
        iconOverride: String? = nil,
        sortOrder: Int = 999,
        isPinned: Bool = false,
        isHidden: Bool = false,
        accentHex: String? = nil,
        groupTag: String? = nil
    ) {
        self.roomID            = roomID
        self.bridgeID          = bridgeID
        self.nameOverride      = nameOverride
        self.iconOverride      = iconOverride
        self.sortOrder         = sortOrder
        self.isPinned          = isPinned
        self.isHidden          = isHidden
        self.accentHex         = accentHex
        self.groupTag          = groupTag
        self.createdAt         = Date()
        self.updatedAt         = Date()
        // Cache defaults
        self.cachedName        = nil
        self.lastIsOn          = false
        self.lastBrightness    = 100
        self.cachedLightCount  = 0
        self.cachedArchetype   = nil
    }
}

// MARK: - Local Scene Metadata

@Model
final class HueLocalScene {
    @Attribute(.unique) var sceneID: String   // matches Bridge scene.id
    var swatchHex:        String?             // color swatch override
    var sceneDescription: String?            // user description (not 'description' — conflicts with @Model)
    var sortOrder:        Int
    var isFavourite:      Bool
    var updatedAt:        Date

    init(sceneID: String, swatchHex: String? = nil, sceneDescription: String? = nil, sortOrder: Int = 999, isFavourite: Bool = false) {
        self.sceneID          = sceneID
        self.swatchHex        = swatchHex
        self.sceneDescription = sceneDescription
        self.sortOrder        = sortOrder
        self.isFavourite      = isFavourite
        self.updatedAt        = Date()
    }
}

// MARK: - Effect Preset

/// A saved effect engine configuration — named, sharable
@Model
final class EffectPreset {
    var id:          String
    var name:        String
    var emoji:       String
    var engineType:  String    // e.g. "rhythm.heartbeat", "chaos.candle"
    var paramsJSON:  String    // encoded param dictionary
    var isFavourite: Bool
    var isBuiltIn:   Bool      // system presets are read-only
    var createdAt:   Date
    var lastUsedAt:  Date?

    init(id: String = UUID().uuidString, name: String, emoji: String, engineType: String, paramsJSON: String, isFavourite: Bool = false, isBuiltIn: Bool = false) {
        self.id          = id
        self.name        = name
        self.emoji       = emoji
        self.engineType  = engineType
        self.paramsJSON  = paramsJSON
        self.isFavourite = isFavourite
        self.isBuiltIn   = isBuiltIn
        self.createdAt   = Date()
        self.lastUsedAt  = nil
    }
}

// MARK: - Favourite Color Swatch

@Model
final class FavouriteColor {
    var id:         String
    var hex:        String
    var name:       String?
    var sortOrder:  Int
    var lastUsedAt: Date?

    init(id: String = UUID().uuidString, hex: String, name: String? = nil, sortOrder: Int = 999) {
        self.id         = id
        self.hex        = hex
        self.name       = name
        self.sortOrder  = sortOrder
        self.lastUsedAt = nil
    }
}

// MARK: - Activity Event (SSE Log)

/// One logged event from the Bridge SSE stream
@Model
final class ActivityEvent {
    var id:           String
    var timestamp:    Date
    var resourceType: String    // e.g. "grouped_light", "light", "motion"
    var resourceID:   String
    var eventType:    String    // "update", "add", "delete"
    var roomName:     String?   // denormalized for display
    var detail:       String    // human-readable summary

    init(id: String = UUID().uuidString, resourceType: String, resourceID: String, eventType: String, roomName: String? = nil, detail: String) {
        self.id           = id
        self.timestamp    = Date()
        self.resourceType = resourceType
        self.resourceID   = resourceID
        self.eventType    = eventType
        self.roomName     = roomName
        self.detail       = detail
    }
}

// MARK: - Energy Snapshot

/// Daily energy estimate per room
@Model
final class EnergySnapshot {
    var id:          String
    var date:        Date        // start of day
    var roomID:      String
    var roomName:    String
    var estimatedWh: Double      // watt-hours

    init(id: String = UUID().uuidString, date: Date, roomID: String, roomName: String, estimatedWh: Double) {
        self.id          = id
        self.date        = date
        self.roomID      = roomID
        self.roomName    = roomName
        self.estimatedWh = estimatedWh
    }
}

// MARK: - App Settings (single row)

@Model
final class AppSettings {
    @Attribute(.unique) var singleton: String = "main"
    var themeMode:      String   // "dark", "light", "system"
    var accentColor:    String   // "amber", "indigo", "teal", "rose", "violet", "mint", "graphite"
    var cardStyle:      String   // "glassmorphic", "solid", "minimal", "neon"
    var animationSpeed: String   // "fast", "normal", "slow", "none"
    var hapticsLevel:   String   // "off", "subtle", "normal", "strong"
    var brightnessUnit: String   // "percent", "raw"
    var tempUnit:       String   // "kelvin", "label"
    var tempScale:      String   // "fahrenheit", "celsius"
    var dashboardLayout: String  // "grid2", "grid3", "grid4", "list", "compact"
    var isPro:          Bool     // StoreKit local cache

    init() {
        self.themeMode       = "system"
        self.accentColor     = "amber"
        self.cardStyle       = "glassmorphic"
        self.animationSpeed  = "normal"
        self.hapticsLevel    = "normal"
        self.brightnessUnit  = "percent"
        self.tempUnit        = "kelvin"
        self.tempScale       = "fahrenheit"
        self.dashboardLayout = "grid2"
        self.isPro           = false
    }
}

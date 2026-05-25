// HueDataModelsTests.swift
// ChromaGlow — Unit Tests
// Tests for SwiftData local models — creation, defaults, property setting.
// Uses an in-memory ModelContainer (no disk I/O, no side effects).

import XCTest
import SwiftData
@testable import ChromaGlow

@MainActor
final class HueDataModelsTests: XCTestCase {

    var container: ModelContainer!
    var context:   ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([
            HueLocalRoom.self,
            HueLocalScene.self,
            EffectPreset.self,
            FavouriteColor.self,
            ActivityEvent.self,
            EnergySnapshot.self,
            AppSettings.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context   = ModelContext(container)
    }

    override func tearDown() async throws {
        context   = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - HueLocalRoom

    func testLocalRoomDefaultValues() throws {
        let room = HueLocalRoom(roomID: "room-001")
        context.insert(room)
        try context.save()

        XCTAssertEqual(room.roomID, "room-001")
        XCTAssertNil(room.nameOverride)
        XCTAssertNil(room.iconOverride)
        XCTAssertEqual(room.sortOrder, 999)
        XCTAssertFalse(room.isPinned)
        XCTAssertFalse(room.isHidden)
        XCTAssertNil(room.accentHex)
        XCTAssertNil(room.groupTag)
    }

    func testLocalRoomCustomValues() throws {
        let room = HueLocalRoom(
            roomID: "room-002",
            nameOverride: "Brian's Room",
            iconOverride: "bed.double.fill",
            sortOrder: 1,
            isPinned: true,
            isHidden: false,
            accentHex: "#FF9500",
            groupTag: "Upstairs"
        )
        context.insert(room)
        try context.save()

        XCTAssertEqual(room.nameOverride, "Brian's Room")
        XCTAssertEqual(room.iconOverride, "bed.double.fill")
        XCTAssertEqual(room.sortOrder, 1)
        XCTAssertTrue(room.isPinned)
        XCTAssertEqual(room.accentHex, "#FF9500")
        XCTAssertEqual(room.groupTag, "Upstairs")
    }

    func testLocalRoomPersistsAndFetches() throws {
        let room = HueLocalRoom(roomID: "room-fetch-test", nameOverride: "Fetched Room")
        context.insert(room)
        try context.save()

        let descriptor = FetchDescriptor<HueLocalRoom>(
            predicate: #Predicate { $0.roomID == "room-fetch-test" }
        )
        let results = try context.fetch(descriptor)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.nameOverride, "Fetched Room")
    }

    // MARK: - HueLocalScene

    func testLocalSceneDefaultValues() throws {
        let scene = HueLocalScene(sceneID: "scene-001")
        context.insert(scene)
        try context.save()

        XCTAssertEqual(scene.sceneID, "scene-001")
        XCTAssertNil(scene.swatchHex)
        XCTAssertNil(scene.sceneDescription)
        XCTAssertEqual(scene.sortOrder, 999)
        XCTAssertFalse(scene.isFavourite)
    }

    func testLocalSceneFavouriteFlag() throws {
        let scene = HueLocalScene(sceneID: "scene-fav", isFavourite: true)
        context.insert(scene)
        try context.save()
        XCTAssertTrue(scene.isFavourite)
    }

    // MARK: - EffectPreset

    func testEffectPresetCreation() throws {
        let preset = EffectPreset(
            name: "Heartbeat",
            emoji: "❤️",
            engineType: "rhythm.heartbeat",
            paramsJSON: "{\"bpm\":72,\"amplitude\":0.8}",
            isBuiltIn: true
        )
        context.insert(preset)
        try context.save()

        XCTAssertFalse(preset.id.isEmpty)
        XCTAssertEqual(preset.name, "Heartbeat")
        XCTAssertEqual(preset.emoji, "❤️")
        XCTAssertEqual(preset.engineType, "rhythm.heartbeat")
        XCTAssertTrue(preset.isBuiltIn)
        XCTAssertFalse(preset.isFavourite)
        XCTAssertNil(preset.lastUsedAt)
    }

    func testEffectPresetUniqueIDsGenerated() throws {
        let p1 = EffectPreset(name: "A", emoji: "✨", engineType: "flow", paramsJSON: "{}")
        let p2 = EffectPreset(name: "B", emoji: "🔥", engineType: "chaos", paramsJSON: "{}")
        context.insert(p1)
        context.insert(p2)
        try context.save()
        XCTAssertNotEqual(p1.id, p2.id)
    }

    // MARK: - FavouriteColor

    func testFavouriteColorCreation() throws {
        let color = FavouriteColor(hex: "#FFC107", name: "Amber", sortOrder: 0)
        context.insert(color)
        try context.save()

        XCTAssertEqual(color.hex, "#FFC107")
        XCTAssertEqual(color.name, "Amber")
        XCTAssertEqual(color.sortOrder, 0)
        XCTAssertNil(color.lastUsedAt)
        XCTAssertFalse(color.id.isEmpty)
    }

    // MARK: - ActivityEvent

    func testActivityEventCreation() throws {
        let event = ActivityEvent(
            resourceType: "grouped_light",
            resourceID: "gl-001",
            eventType: "update",
            roomName: "Living Room",
            detail: "Turned ON at 80%"
        )
        context.insert(event)
        try context.save()

        XCTAssertFalse(event.id.isEmpty)
        XCTAssertEqual(event.resourceType, "grouped_light")
        XCTAssertEqual(event.eventType, "update")
        XCTAssertEqual(event.roomName, "Living Room")
        XCTAssertLessThanOrEqual(event.timestamp.timeIntervalSinceNow, 1.0) // recent
    }

    func testMultipleActivityEventsAreSeparate() throws {
        let e1 = ActivityEvent(resourceType: "light", resourceID: "l-001", eventType: "update", detail: "Dimmed")
        let e2 = ActivityEvent(resourceType: "motion", resourceID: "m-001", eventType: "update", detail: "Motion detected")
        context.insert(e1)
        context.insert(e2)
        try context.save()

        let all = try context.fetch(FetchDescriptor<ActivityEvent>())
        XCTAssertEqual(all.count, 2)
        XCTAssertNotEqual(e1.id, e2.id)
    }

    // MARK: - EnergySnapshot

    func testEnergySnapshotCreation() throws {
        let snapshot = EnergySnapshot(
            date: Date(),
            roomID: "room-001",
            roomName: "Living Room",
            estimatedWh: 120.5
        )
        context.insert(snapshot)
        try context.save()

        XCTAssertEqual(snapshot.roomID, "room-001")
        XCTAssertEqual(snapshot.estimatedWh, 120.5, accuracy: 0.01)
        XCTAssertFalse(snapshot.id.isEmpty)
    }

    // MARK: - AppSettings

    func testAppSettingsDefaults() throws {
        let settings = AppSettings()
        context.insert(settings)
        try context.save()

        XCTAssertEqual(settings.themeMode, "system")
        XCTAssertEqual(settings.accentColor, "amber")
        XCTAssertEqual(settings.cardStyle, "glassmorphic")
        XCTAssertEqual(settings.animationSpeed, "normal")
        XCTAssertEqual(settings.hapticsLevel, "normal")
        XCTAssertEqual(settings.dashboardLayout, "grid2")
        XCTAssertFalse(settings.isPro)
    }

    func testAppSettingsCanBeUpdated() throws {
        let settings = AppSettings()
        context.insert(settings)
        try context.save()

        settings.isPro = true
        settings.themeMode = "dark"
        settings.dashboardLayout = "list"
        try context.save()

        XCTAssertTrue(settings.isPro)
        XCTAssertEqual(settings.themeMode, "dark")
        XCTAssertEqual(settings.dashboardLayout, "list")
    }
}

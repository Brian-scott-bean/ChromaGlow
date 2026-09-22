// Composer2LabRecoveryTests.swift
// ChromaGlow — Composer 2 lab (experimental), v2.1.
//
// Stability and recovery: the playback owner must survive rapid taps,
// dismissal mid-start, backgrounding, replacement and repeated Dashboard
// stops without ever leaving a session the app cannot clear — reinstalling
// the app is never the recovery path.

import XCTest
@testable import HueHome

@MainActor
final class Composer2LabRecoveryTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("c2-recovery-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func document(room: RoomDisplayItem? = Composer2LabFixtures.room("r1"),
                          composition: Composer2Composition = Composer2PresetLibrary.auroraDrift) -> Composer2Document {
        var context = Composer2RoomContext(room: room)
        context.lights = Composer2LabFixtures.lights
        context.layout = Composer2SlotLayout.estimated(lights: Composer2LabFixtures.lights)
        return Composer2Document(composition: composition, roomContext: context)
    }

    /// `attached`: the Composer 2 screen is showing (auditions need a viewer).
    private func center(now: Double = 100, attached: Bool = true) -> Composer2PlaybackCenter {
        let c = Composer2PlaybackCenter(observeApplication: false)
        c.now = { now }
        if attached { c.attachScreen() }
        return c
    }

    /// Spin the main actor until `condition` holds (bounded; no time waits).
    private func settle(_ condition: () -> Bool) async {
        var spins = 0
        while !condition() && spins < 20_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertTrue(condition(), "condition never held")
    }

    // MARK: Cold launch claims nothing

    func testColdStartOwnsNothingAndAutoStartsNothing() {
        let c = center(attached: false)
        XCTAssertNil(c.session)
        XCTAssertEqual(c.status, .idle)
        XCTAssertFalse(c.isLive)
        XCTAssertFalse(c.isBusy)
        XCTAssertFalse(c.takeoverPending)
        XCTAssertFalse(c.hasAttachedScreen)
        XCTAssertNil(c.retainedDocument(for: "r1"))
        XCTAssertEqual(c.statusText, Composer2Copy.previewOnly)
        // A saved composition on disk is data, not a claim: loading the store
        // starts nothing.
        let url = tempDir.appendingPathComponent("composer2-compositions.json")
        let seeded = Composer2Store(fileURL: url)
        _ = seeded.save(Composer2PresetLibrary.lavaLamp.duplicated(name: "Mine", at: Date(timeIntervalSince1970: 1)))
        let reloaded = Composer2Store(fileURL: url)
        XCTAssertEqual(reloaded.compositions.count, 1)
        XCTAssertNil(c.session)
        XCTAssertEqual(c.status, .idle)
    }

    // MARK: Corrupted persistence

    func testCorruptTruncatedHugeAndEmptyStoresLoadAsEmptyWithoutCrashing() throws {
        let cases: [(String, Data)] = [
            ("truncated", Data("{\"schema\":1,\"compositions\":[{\"id\":\"0000".utf8)),
            ("huge junk", Data(repeating: UInt8(ascii: "["), count: 512 * 1024)),
            ("zeros", Data(count: 4096)),
            ("empty", Data()),
            ("wrong root", Data("[1,2,3]".utf8)),
            ("wrong types", Data("{\"schema\":\"x\",\"compositions\":{\"a\":1}}".utf8)),
            ("future schema", Data("{\"schema\":99,\"compositions\":[{\"id\":\"11111111-1111-1111-1111-111111111111\",\"future\":true}]}".utf8))
        ]
        for (name, bytes) in cases {
            let url = tempDir.appendingPathComponent("\(name.replacingOccurrences(of: " ", with: "-")).json")
            try bytes.write(to: url)
            let loaded = Composer2Store.readCompositions(from: url)
            if name == "future schema" {
                XCTAssertEqual(loaded.count, 1, "\(name): a forward schema still decodes what it can")
            } else {
                XCTAssertTrue(loaded.isEmpty, "\(name): corrupt data loads as nothing")
            }
            let store = Composer2Store(fileURL: url)
            XCTAssertEqual(store.compositions.count, loaded.count, name)
            XCTAssertEqual(store.all.count, Composer2PresetLibrary.all.count + loaded.count, "\(name): built-ins always present")
            XCTAssertEqual(try Data(contentsOf: url), bytes, "\(name): loading never rewrites the file")
        }
    }

    func testMissingStoreFileIsFineAndSavingRecreatesIt() throws {
        let url = tempDir.appendingPathComponent("nested/missing/composer2-compositions.json")
        let store = Composer2Store(fileURL: url)
        XCTAssertTrue(store.compositions.isEmpty)
        let saved = store.save(Composer2PresetLibrary.auroraDrift.duplicated(name: "Again", at: Date(timeIntervalSince1970: 5)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(Composer2Store.readCompositions(from: url).map(\.id), [saved.id])
    }

    // MARK: Rapid Live / Stop and repeated open/close

    func testRapidStartStopStartIsSerializedAndEndsConsistent() async {
        let gw = Composer2FakeGateway()
        let c = center()
        let doc = document()
        let out = Composer2LiveOutput(composition: doc.composition)
        let t1 = Task { await c.start(document: doc, output: out, gateway: gw, audition: true) }
        let t2 = Task { await c.stop(gateway: gw) }
        let t3 = Task { await c.start(document: doc, output: out, gateway: gw, audition: true) }
        let t4 = Task { await c.stop(gateway: gw) }
        _ = await (t1.value, t2.value, t3.value, t4.value)
        XCTAssertNil(c.session)
        XCTAssertEqual(c.status, .idle)
        XCTAssertEqual(gw.startCalls.count, 2)
        XCTAssertEqual(gw.stopCalls, ["r1", "r1"])
        XCTAssertEqual(gw.publishCalls.count, 2)
        XCTAssertEqual(gw.retireCalls, ["r1", "r1"], "every start's row was retired by its stop")
        XCTAssertNil(gw.boxes.last?.frameSource, "nothing left bound")
        XCTAssertFalse(c.isBusy)
    }

    func testRepeatedOpenAndCloseLeavesNoScreenOrSession() async {
        let gw = Composer2FakeGateway()
        let c = center(attached: false)
        for _ in 0..<25 {
            c.attachScreen()
            let doc = document()
            let out = Composer2LiveOutput(composition: doc.composition)
            _ = await c.start(document: doc, output: out, gateway: gw, audition: true)
            c.detachScreen()
            await c.endAudition(gateway: gw)?.value
        }
        XCTAssertFalse(c.hasAttachedScreen)
        XCTAssertNil(c.session)
        XCTAssertEqual(c.status, .idle)
        XCTAssertEqual(gw.startCalls.count, 25)
        XCTAssertEqual(gw.stopCalls.count, 25)
        XCTAssertEqual(gw.retireCalls.count, 25)
        XCTAssertTrue(gw.boxes.allSatisfy { $0.frameSource == nil })
    }

    func testDetachBelowZeroIsClamped() {
        let c = center(attached: false)
        c.detachScreen(); c.detachScreen()
        XCTAssertFalse(c.hasAttachedScreen)
        c.attachScreen()
        XCTAssertTrue(c.hasAttachedScreen)
    }

    // MARK: Close while starting

    func testClosingTheScreenWhileAnAuditionIsStartingStopsItOnArrival() async {
        let gw = Composer2FakeGateway()
        gw.foreignControllerPresent = true   // start suspends on the takeover question
        let c = center(attached: false)
        c.attachScreen()
        let doc = document()
        let out = Composer2LiveOutput(composition: doc.composition)
        let task = Task { await c.start(document: doc, output: out, gateway: gw, audition: true) }
        await settle { c.takeoverPending }
        XCTAssertTrue(c.isBusy)
        // The user swipes the cover away mid-start.
        c.detachScreen()
        _ = c.endAudition(gateway: gw)
        c.answerTakeover(true)
        let status = await task.value
        XCTAssertEqual(status, .idle, "an audition nobody is watching is stopped as soon as it starts")
        await settle { !c.isBusy }
        XCTAssertNil(c.session)
        XCTAssertEqual(gw.startCalls.count, 1)
        XCTAssertEqual(gw.stopCalls, ["r1"])
        XCTAssertEqual(gw.retireCalls, ["r1"])
        XCTAssertNil(gw.boxes[0].frameSource)
    }

    func testAppliedStartSurvivesTheScreenClosingMidStart() async {
        let gw = Composer2FakeGateway()
        gw.foreignControllerPresent = true
        let c = center(attached: false)
        c.attachScreen()
        let doc = document()
        let out = Composer2LiveOutput(composition: doc.composition)
        let task = Task { await c.start(document: doc, output: out, gateway: gw, audition: false) }
        await settle { c.takeoverPending }
        c.detachScreen()
        c.answerTakeover(true)
        let status = await task.value
        XCTAssertEqual(status, .live)
        XCTAssertTrue(c.isLive)
        XCTAssertEqual(c.session?.isAudition, false)
        XCTAssertTrue(gw.stopCalls.isEmpty)
        await c.stop(gateway: gw)
    }

    // MARK: Attended takeover

    func testTakeoverApprovedStartsAndDeclinedKeepsTheOtherShow() async {
        let gw = Composer2FakeGateway()
        gw.foreignControllerPresent = true
        let c = center(attached: false)
        c.attachScreen()
        let doc = document()
        let out = Composer2LiveOutput(composition: doc.composition)

        let approve = Task { await c.start(document: doc, output: out, gateway: gw, audition: true) }
        await settle { c.takeoverPending }
        XCTAssertEqual(c.status, .starting)
        XCTAssertEqual(c.statusText, Composer2Copy.takeoverWaiting)
        c.answerTakeover(true)
        let approved = await approve.value
        XCTAssertEqual(approved, .live)
        XCTAssertFalse(c.takeoverPending)
        XCTAssertEqual(gw.takeoverAsked, 1)
        XCTAssertTrue(c.isLive)
        await c.stop(gateway: gw)

        let decline = Task { await c.start(document: doc, output: out, gateway: gw, audition: true) }
        await settle { c.takeoverPending }
        c.answerTakeover(false)
        let declined = await decline.value
        XCTAssertEqual(declined, .failed(Composer2Copy.takeoverDeclined))
        XCTAssertFalse(c.takeoverPending)
        XCTAssertNil(c.session)
        XCTAssertNil(gw.boxes[1].frameSource, "nothing stays bound after a decline")
        XCTAssertEqual(gw.stopCalls, ["r1"], "declining sends no stop (the other app keeps its show)")
        XCTAssertEqual(gw.publishCalls.count, 1, "no Now Playing row for a declined start")
        c.clearNotice()
        XCTAssertEqual(c.status, .idle)
    }

    func testTakeoverFailureAfterApprovalIsReportedAndUnbound() async {
        let gw = Composer2FakeGateway()
        gw.foreignControllerPresent = true
        gw.startOutcome = .failed("Could not take over")
        let c = center()
        let doc = document()
        let out = Composer2LiveOutput(composition: doc.composition)
        let task = Task { await c.start(document: doc, output: out, gateway: gw, audition: true) }
        await settle { c.takeoverPending }
        c.answerTakeover(true)
        let failed = await task.value
        XCTAssertEqual(failed, .failed("Could not take over"))
        XCTAssertNil(c.session)
        XCTAssertNil(gw.boxes[0].frameSource)
        XCTAssertTrue(gw.publishCalls.isEmpty)
    }

    func testAnsweringWithNoQuestionPendingIsHarmless() {
        let c = center()
        c.answerTakeover(true)
        c.answerTakeover(false)
        XCTAssertFalse(c.takeoverPending)
        XCTAssertEqual(c.status, .idle)
    }

    // MARK: Background / foreground

    func testSilenceWhileInactiveIsNotAnEndingAndTheClockReArmsOnReturn() async {
        let gw = Composer2FakeGateway()
        let c = center(now: 100)
        let doc = document()
        let out = Composer2LiveOutput(composition: doc.composition)
        _ = await c.start(document: doc, output: out, gateway: gw, audition: false)
        c.noteApplicationActive(false)
        c.now = { 200 }   // 100 s of silence in the background
        XCTAssertTrue(c.tickHeartbeat())
        XCTAssertEqual(c.status, .live, "background silence is expected")
        c.noteApplicationActive(true)
        c.now = { 200.4 }
        XCTAssertTrue(c.tickHeartbeat())
        XCTAssertEqual(c.status, .live, "grace period restarts on return")
        c.now = { 204 }
        XCTAssertTrue(c.tickHeartbeat())
        XCTAssertEqual(c.status, .reconnecting)
        c.now = { 209 }
        XCTAssertFalse(c.tickHeartbeat())
        XCTAssertEqual(c.status, .ended(Composer2Copy.liveEndedLost))
        XCTAssertEqual(gw.retireCalls, ["r1"])
        // A lost session is fenced with a stop, so a late re-entry of our
        // look can never play on with no owner.
        await settle { gw.stopCalls == ["r1"] }
    }

    // MARK: Dashboard / Now Playing stop

    func testApplyThenDismissThenDashboardStopStopsTheRealSession() async {
        let gw = Composer2FakeGateway()
        let c = center(attached: false)
        c.attachScreen()
        let doc = document()
        let out = Composer2LiveOutput(composition: doc.composition)
        _ = await c.start(document: doc, output: out, gateway: gw, audition: false)
        XCTAssertEqual(gw.publishCalls.map(\.roomID), ["r1"])
        XCTAssertEqual(gw.publishCalls[0].name, doc.composition.name)
        XCTAssertNotNil(gw.stopHandler, "the Dashboard route was installed on start")
        c.detachScreen()
        XCTAssertNil(c.endAudition(gateway: gw), "applied playback survives dismissal")
        XCTAssertTrue(c.isLive)

        let stopped = await gw.stopHandler!("b1", "r1")
        XCTAssertTrue(stopped)
        XCTAssertNil(c.session)
        XCTAssertEqual(c.status, .idle)
        XCTAssertFalse(c.isLive, "the entry card's pill is gone")
        XCTAssertEqual(gw.stopCalls, ["r1"])
        XCTAssertEqual(gw.retireCalls, ["r1"])
        XCTAssertNil(gw.boxes[0].frameSource)
        XCTAssertNil(c.retainedDocument(for: "r1"))
    }

    func testRepeatedDashboardStopIsSafeAndNeverStopsAReplacement() async {
        let gw = Composer2FakeGateway()
        let c = center()
        let doc = document()
        let out = Composer2LiveOutput(composition: doc.composition)
        _ = await c.start(document: doc, output: out, gateway: gw, audition: false)
        let owned1 = await c.stopIfOwning(bridgeID: "b1", roomID: "r1")
        XCTAssertTrue(owned1)
        let owned2 = await c.stopIfOwning(bridgeID: "b1", roomID: "r1")
        XCTAssertFalse(owned2, "second Stop: nothing of ours left")
        let owned3 = await c.stopIfOwning(bridgeID: nil, roomID: "r1")
        XCTAssertFalse(owned3)
        XCTAssertEqual(gw.stopCalls, ["r1"], "exactly one stop reached the transport")

        // A Studio look replaced us in r1 (our session ended); its Stop must not
        // be answered by us.
        _ = await c.start(document: doc, output: out, gateway: gw, audition: false)
        gw.driving = false
        c.now = { 200 }
        XCTAssertFalse(c.tickHeartbeat())
        XCTAssertNil(c.session)
        let owned4 = await c.stopIfOwning(bridgeID: "b1", roomID: "r1")
        XCTAssertFalse(owned4, "not ours any more")
        XCTAssertEqual(gw.stopCalls, ["r1"], "the replacement was left alone")

        // Replaced but the heartbeat has not noticed yet: the Dashboard's Stop
        // is still not ours — the box identity says so.
        gw.driving = true
        _ = await c.start(document: doc, output: out, gateway: gw, audition: false)
        gw.driving = false
        let owned4b = await c.stopIfOwning(bridgeID: "b1", roomID: "r1")
        XCTAssertFalse(owned4b, "a replacement's row is never stopped by room alone")
        XCTAssertEqual(gw.stopCalls, ["r1"])
        await c.stop(gateway: gw)
        XCTAssertEqual(gw.stopCalls, ["r1"], "our own Stop never reaches a transport that plays another look")
        XCTAssertNil(c.session)
        gw.driving = true

        // Our session in r1, a Stop for r2 or another bridge is not ours.
        _ = await c.start(document: doc, output: out, gateway: gw, audition: false)
        let owned5 = await c.stopIfOwning(bridgeID: "b1", roomID: "r2")
        XCTAssertFalse(owned5)
        let owned6 = await c.stopIfOwning(bridgeID: "b9", roomID: "r1")
        XCTAssertFalse(owned6)
        XCTAssertTrue(c.isLive)
        let owned7 = await c.stopIfOwning(bridgeID: nil, roomID: "r1")
        XCTAssertTrue(owned7, "room-only compatibility stop matches our room")
        XCTAssertNil(c.session)
    }

    func testStopWithNothingRunningIsHarmlessAndClearsAStuckStart() async {
        let gw = Composer2FakeGateway()
        let c = center()
        await c.stop(gateway: gw)
        await c.stop(gateway: gw)
        XCTAssertTrue(gw.stopCalls.isEmpty)
        XCTAssertEqual(c.status, .idle)
        let owned8 = await c.stopIfOwning(bridgeID: "b1", roomID: "r1")
        XCTAssertFalse(owned8)
    }

    func testLostSessionLetsGoAndIsFencedWithAStop() async {
        let gw = Composer2FakeGateway()
        let c = center(now: 100)
        let doc = document()
        let out = Composer2LiveOutput(composition: doc.composition)
        _ = await c.start(document: doc, output: out, gateway: gw, audition: false)
        let box = gw.boxes[0]
        gw.claimed = false
        gw.driving = false
        c.now = { 120 }
        XCTAssertFalse(c.tickHeartbeat())
        XCTAssertEqual(c.status, .ended(Composer2Copy.liveEndedLost))
        XCTAssertNil(box.frameSource)
        XCTAssertNil(c.output)
        await settle { gw.stopCalls == ["r1"] }
        gw.claimed = true
        gw.driving = true
        // A fresh start on the same room binds a NEW box; the old one is inert.
        _ = await c.start(document: doc, output: out, gateway: gw, audition: true)
        XCTAssertTrue(gw.boxes[1].frameSource === out)
        await c.stop(gateway: gw)
        XCTAssertNil(gw.boxes[1].frameSource)
    }

    // MARK: Saved looks from the Studio card

    func testSavedLookPlaysAppliedAndTogglesOffFromTheCard() async {
        let gw = Composer2FakeGateway()
        let c = center()
        let composition = Composer2PresetLibrary.lavaLamp.duplicated(name: "Mine", at: Date(timeIntervalSince1970: 1))
        let doc = document(composition: composition)
        let out = Composer2LiveOutput(composition: composition)
        _ = await c.start(document: doc, output: out, gateway: gw, audition: false)
        XCTAssertEqual(c.session?.compositionID, composition.id, "the card can tell which look is playing")
        XCTAssertEqual(c.session?.compositionName, "Mine")
        XCTAssertEqual(c.session?.isAudition, false)
        XCTAssertEqual(gw.publishCalls.last?.name, "Mine")
        // Renaming the saved look while it plays updates the row and the pill.
        doc.rename("Mine 2")
        XCTAssertEqual(c.session?.compositionName, "Mine 2")
        XCTAssertEqual(gw.publishCalls.last?.name, "Mine 2")
        await c.stop(gateway: gw)
        XCTAssertNil(c.session)
    }

    /// Tapping a second saved look while the first plays in the same room
    /// must switch looks — it used to return early and keep the old one.
    func testSecondSavedLookInTheSameRoomReplacesThePlayingOneWithoutRestarting() async {
        let gw = Composer2FakeGateway()
        let c = center()
        let first = Composer2PresetLibrary.lavaLamp.duplicated(name: "First", at: Date(timeIntervalSince1970: 1))
        let second = Composer2PresetLibrary.thunderstorm.duplicated(name: "Second", at: Date(timeIntervalSince1970: 2))
        let doc1 = document(composition: first)
        let out1 = Composer2LiveOutput(composition: first)
        _ = await c.start(document: doc1, output: out1, gateway: gw, audition: false)
        let box = gw.boxes.first
        XCTAssertTrue(box?.frameSource === out1)

        let doc2 = document(composition: second)
        let out2 = Composer2LiveOutput(composition: second)
        let status = await c.start(document: doc2, output: out2, gateway: gw, audition: false)
        XCTAssertEqual(status, .live)
        XCTAssertEqual(gw.startCalls.count, 1, "the running transport is reused, not restarted")
        XCTAssertEqual(gw.stopCalls, [], "no stop between the two looks")
        XCTAssertEqual(c.session?.compositionID, second.id)
        XCTAssertEqual(c.session?.compositionName, "Second")
        XCTAssertEqual(gw.publishCalls.last?.name, "Second", "the Now Playing row follows the new look")
        XCTAssertTrue(box?.frameSource === out2, "the lights now render the second look")
        XCTAssertTrue(c.output === out2)
        XCTAssertTrue(c.retainedDocument(for: "r1") === doc2)

        // Edits to the first document no longer reach the runtime.
        doc1.rename("Stale")
        XCTAssertEqual(c.session?.compositionName, "Second")
        // Edits to the second one do.
        doc2.rename("Second, edited")
        XCTAssertEqual(c.session?.compositionName, "Second, edited")

        await c.stop(gateway: gw)
        XCTAssertEqual(gw.stopCalls, ["r1"])
        XCTAssertNil(box?.frameSource)
    }

    /// A takeover question nobody can see must not hold the chain forever:
    /// the Dashboard's Stop for ANY room waited behind it.
    func testUnansweredTakeoverIsDeclinedAndNeverBlocksAStrangersStop() async {
        let gw = Composer2FakeGateway()
        gw.foreignControllerPresent = true
        let c = center()
        c.takeoverTimeout = 0.05
        let doc = document()
        let out = Composer2LiveOutput(composition: doc.composition)
        let start = Task { await c.start(document: doc, output: out, gateway: gw, audition: false) }
        await settle { c.takeoverPending }
        // A Stop for a room we do not own answers at once, pending question or not.
        let answered = await c.stopIfOwning(bridgeID: "b1", roomID: "r9")
        XCTAssertFalse(answered)
        let status = await start.value
        XCTAssertEqual(status, .failed(Composer2Copy.takeoverDeclined), "the silence was read as Keep existing")
        XCTAssertFalse(c.takeoverPending)
        XCTAssertNil(c.session)
    }

    /// Picking another room while a start is in flight must not leave the
    /// first room playing under a screen that now describes the second.
    func testRoomChangedDuringStartStopsTheStaleSession() async {
        let gw = Composer2FakeGateway()
        gw.foreignControllerPresent = true
        let c = center()
        let doc = document()
        let out = Composer2LiveOutput(composition: doc.composition)
        let start = Task { await c.start(document: doc, output: out, gateway: gw, audition: true) }
        await settle { c.takeoverPending }
        doc.roomContext = Composer2RoomContext(room: Composer2LabFixtures.room("r2"))
        c.answerTakeover(true)
        _ = await start.value
        XCTAssertNil(c.session)
        XCTAssertEqual(c.status, .idle)
        XCTAssertEqual(gw.stopCalls, ["r1"])
    }

    func testDocumentSaveOwnershipAndLegacyImport() throws {
        let url = tempDir.appendingPathComponent("composer2-compositions.json")
        let store = Composer2Store(fileURL: url)
        let doc = document()
        XCTAssertFalse(doc.isSourceUserOwned, "a built-in is never overwritten")
        let saved = store.save(doc.composition.duplicated(name: "Owned", at: Date(timeIntervalSince1970: 1)))
        doc.load(saved, asSource: true)
        XCTAssertEqual(doc.sourceID, saved.id)
        // Ownership is judged against the shared store, which does not hold this temp store's row.
        XCTAssertFalse(Composer2Store.shared.compositions.contains { $0.id == saved.id })
        XCTAssertFalse(doc.isSourceUserOwned)

        let legacy = CompositionPreset(id: UUID(uuidString: "0000000C-0009-0009-0009-000000000001")!, name: "Old Lava",
                                       icon: "flame", accentColorHex: "#FF5500", isBuiltIn: false, category: .ambient,
                                       seasonMonths: nil, palette: PaletteConfig(), motion: MotionConfig(),
                                       envelope: EnvelopeConfig(), reaction: ReactionConfig(),
                                       createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        doc.importLegacy(legacy, now: Date(timeIntervalSince1970: 9))
        XCTAssertEqual(doc.composition.name, "Old Lava")
        XCTAssertNil(doc.sourceID, "an import is unsaved until the user saves it")
        XCTAssertEqual(doc.composition.layers.count, 1)
        XCTAssertEqual(doc.composition.layers[0].audio.brightnessMode, .dimWhenQuiet, "legacy semantics kept")
        XCTAssertTrue(doc.isDirty)
    }

    func testDragReorderMovesALayerOntoAnother() {
        let doc = document(composition: Composer2PresetLibrary.hauntedHouse)
        let ids = doc.composition.layers.map(\.id)
        XCTAssertEqual(ids.count, 4)
        doc.moveLayer(id: ids[3], onto: ids[0])
        XCTAssertEqual(doc.composition.layers.map(\.id), [ids[3], ids[0], ids[1], ids[2]])
        doc.moveLayer(id: ids[3], onto: ids[3])
        XCTAssertEqual(doc.composition.layers.map(\.id), [ids[3], ids[0], ids[1], ids[2]], "self-drop is a no-op")
        doc.moveLayer(id: UUID(), onto: ids[0])
        XCTAssertEqual(doc.composition.layers.count, 4, "unknown ids are ignored")
    }
}

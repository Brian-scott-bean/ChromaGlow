// FrameDeadlinePacerTests.swift
// HueHome Pro — Unit Tests
//
// Play Along P0.3: the composition stream paces to a fixed grid. Frames that
// finish early or a little late keep their slots; a loop that falls a whole
// frame behind re-anchors instead of bursting through the missed slots.

import XCTest
@testable import HueHome

final class FrameDeadlinePacerTests: XCTestCase {

    private let t0 = ContinuousClock.now
    private func ms(_ v: Int) -> ContinuousClock.Instant { t0 + .milliseconds(v) }

    func testFramesKeepTheirSlotsWhateverTheirWorkTook() {
        var pacer = FrameDeadlinePacer(interval: .milliseconds(40), start: t0)
        // Work of 10, 25 and 39 ms used to stretch each frame to 50/65/79 ms.
        XCTAssertEqual(pacer.deadline(after: ms(10)), ms(40))
        XCTAssertEqual(pacer.deadline(after: ms(65)), ms(80))
        XCTAssertEqual(pacer.deadline(after: ms(119)), ms(120))
        XCTAssertEqual(pacer.next, ms(160))
    }

    func testASlightlyLateFrameCatchesUpByOneSlotOnly() {
        var pacer = FrameDeadlinePacer(interval: .milliseconds(40), start: t0)
        // Finished 20 ms past its slot: the due time is already past, so the
        // next frame renders at once — and the grid is unchanged.
        XCTAssertEqual(pacer.deadline(after: ms(60)), ms(40))
        XCTAssertEqual(pacer.deadline(after: ms(70)), ms(80))
    }

    func testFallingAWholeFrameBehindReanchorsInsteadOfBursting() {
        var pacer = FrameDeadlinePacer(interval: .milliseconds(40), start: t0)
        _ = pacer.deadline(after: ms(10))                       // slot 40, next 80
        // A 100 ms stall: 60 ms past the 80 ms slot is more than a frame.
        XCTAssertEqual(pacer.deadline(after: ms(140)), ms(180), "re-anchored on now + one frame")
        XCTAssertEqual(pacer.deadline(after: ms(150)), ms(220), "the new grid holds")
    }
}

import XCTest
@testable import QingJieCore

final class ScrollAutoAdvanceTests: XCTestCase {
    func testWaitsForMatchAndStopsAtStationaryTail() {
        var advance = ScrollAutoAdvance()
        XCTAssertEqual(advance.observe(.unchanged, height: 600, now: 0), .advance)
        XCTAssertEqual(advance.observe(.settling, height: 600, now: 0.9), .wait)
        XCTAssertEqual(advance.observe(.appended(120), height: 720, now: 1), .advance)
        XCTAssertEqual(advance.observe(.unchanged, height: 720, now: 1.2), .wait)
        XCTAssertEqual(advance.observe(.unchanged, height: 720, now: 2), .advance)
        XCTAssertEqual(advance.observe(.unchanged, height: 720, now: 3), .advance)
        XCTAssertEqual(advance.observe(.unchanged, height: 720, now: 4), .stopped)
    }
    func testNewContentResetsStationaryCounter() {
        var advance = ScrollAutoAdvance()
        for time in 0...2 { XCTAssertEqual(advance.observe(.unchanged, height: 600, now: Double(time)), .advance) }
        XCTAssertEqual(advance.observe(.appended(40), height: 640, now: 2.2), .wait)
        XCTAssertEqual(advance.observe(.unchanged, height: 640, now: 3), .advance)
        XCTAssertEqual(advance.observe(.unchanged, height: 640, now: 4), .advance)
    }
    func testNeverAdvancesAcrossMissingOverlapOrProlongedAnimation() {
        for outcome in [StitchOutcome.noOverlap, .backwards, .limitReached] {
            var advance = ScrollAutoAdvance()
            XCTAssertEqual(advance.observe(outcome, height: 600, now: 0), .lostOverlap)
        }
        var advance = ScrollAutoAdvance()
        XCTAssertEqual(advance.observe(nil, height: 600, now: 0), .wait)
        XCTAssertEqual(advance.observe(.unchanged, height: 600, now: 1), .advance)
        XCTAssertEqual(advance.observe(.settling, height: 600, now: 4.9), .wait)
        XCTAssertEqual(advance.observe(.settling, height: 600, now: 5), .lostOverlap)
    }
}

import XCTest
@testable import QingJieCore

final class RecordingOptionsTests: XCTestCase {
    func testRetinaLandscapeAndPortraitFitWithoutStretching() {
        XCTAssertEqual(RecordingResolution.fullHD.outputSize(for: CGSize(width: 3024, height: 1964)), CGSize(width: 1662, height: 1080))
        XCTAssertEqual(RecordingResolution.fullHD.outputSize(for: CGSize(width: 1964, height: 3024)), CGSize(width: 1080, height: 1662))
        XCTAssertEqual(RecordingResolution.uhd.outputSize(for: CGSize(width: 5120, height: 2880)), CGSize(width: 3840, height: 2160))
    }
    func testSmallAndOddSelectionsAreNotUpscaled() {
        XCTAssertEqual(RecordingResolution.fullHD.outputSize(for: CGSize(width: 853, height: 479)), CGSize(width: 852, height: 478))
        XCTAssertEqual(RecordingResolution.hd.outputSize(for: CGSize(width: 640, height: 360)), CGSize(width: 640, height: 360))
    }
    func testNativeEncodingLimitAndInvalidGeometry() {
        let size = RecordingResolution.native.outputSize(for: CGSize(width: 10000, height: 6000))
        XCTAssertEqual(size, CGSize(width: 4096, height: 2456))
        for source in [CGSize.zero, CGSize(width: -1, height: 900), CGSize(width: CGFloat.infinity, height: 900)] {
            XCTAssertEqual(RecordingResolution.uhd.outputSize(for: source), .zero)
        }
    }
    func testAudioIsOptInAndFrameRateIsValidated() throws {
        var options = RecordingOptions()
        XCTAssertFalse(options.systemAudio); XCTAssertFalse(options.microphone)
        XCTAssertTrue(options.mouseClicks); XCTAssertTrue(options.showsCursor)
        options.frameRate = 0
        XCTAssertEqual(options.validated.frameRate, 30)
        options.frameRate = 60; options.microphone = true; options.systemAudio = true
        XCTAssertEqual(try JSONDecoder().decode(RecordingOptions.self, from: JSONEncoder().encode(options)), options)
    }
}

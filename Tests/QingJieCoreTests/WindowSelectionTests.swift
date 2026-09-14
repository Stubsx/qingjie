import XCTest
@testable import QingJieCore

final class WindowSelectionTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private func targets(_ windows: [CaptureWindow], display: CGRect? = nil) -> [WindowSelectionTarget] {
        let display = display ?? self.display
        return WindowSelection.targets(from: windows, display: display, localSize: display.size, excludingPID: 99)
    }
    func testFrontmostWindowWinsOnlyWhereItContainsPointer() {
        let front = CaptureWindow(id: 2, ownerPID: 2, frame: CGRect(x: 200, y: 200, width: 400, height: 400))
        let back = CaptureWindow(id: 1, ownerPID: 1, frame: CGRect(x: 100, y: 100, width: 900, height: 650))
        let list = targets([front, back])
        XCTAssertEqual(WindowSelection.target(at: CGPoint(x: 300, y: 300), in: list)?.id, 2)
        XCTAssertEqual(WindowSelection.target(at: CGPoint(x: 120, y: 120), in: list)?.id, 1)
        XCTAssertNil(WindowSelection.target(at: CGPoint(x: 1200, y: 800), in: list))
    }
    func testSystemSurfacesHiddenHelpersAndOwnAppAreExcluded() {
        let rect = CGRect(x: 50, y: 50, width: 800, height: 600)
        let windows = [
            CaptureWindow(id: 1, ownerPID: 99, frame: rect),
            CaptureWindow(id: 2, ownerPID: 1, frame: rect, layer: -2147483623),
            CaptureWindow(id: 3, ownerPID: 1, frame: rect, layer: 25),
            CaptureWindow(id: 4, ownerPID: 1, frame: rect, layer: 101),
            CaptureWindow(id: 5, ownerPID: 1, frame: rect, alpha: 0),
            CaptureWindow(id: 6, ownerPID: 1, frame: rect, isOnScreen: false),
            CaptureWindow(id: 7, ownerPID: 1, frame: CGRect(x: 0, y: 0, width: 1, height: 800)),
            CaptureWindow(id: 8, ownerPID: 1, frame: rect, layer: 3),
            CaptureWindow(id: 9, ownerPID: 1, frame: rect)
        ]
        XCTAssertEqual(targets(windows).map(\.id), [8, 9])
    }
    func testLeftDisplayUsesLocalTopLeftCoordinates() {
        let left = CGRect(x: -1920, y: 180, width: 1920, height: 1080)
        let window = CaptureWindow(id: 1, ownerPID: 1, frame: CGRect(x: -1800, y: 230, width: 900, height: 700))
        XCTAssertEqual(targets([window], display: left).first?.rect, CGRect(x: 120, y: 50, width: 900, height: 700))
    }
    func testDisplayAboveMainUsesNegativeQuartzY() {
        let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let window = CaptureWindow(id: 1, ownerPID: 1, frame: CGRect(x: 120, y: -900, width: 800, height: 600))
        XCTAssertEqual(targets([window], display: above).first?.rect, CGRect(x: 120, y: 180, width: 800, height: 600))
    }
    func testSpanningWindowIsClippedSeparatelyOnEachDisplay() {
        let window = CaptureWindow(id: 1, ownerPID: 1, frame: CGRect(x: -300, y: 120, width: 900, height: 600))
        XCTAssertEqual(targets([window]).first?.rect, CGRect(x: 0, y: 120, width: 600, height: 600))
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(targets([window], display: left).first?.rect, CGRect(x: 1620, y: 120, width: 300, height: 600))
    }
    func testOffscreenAndInvalidBoundsProduceNoTarget() {
        XCTAssertTrue(targets([CaptureWindow(id: 1, ownerPID: 1, frame: CGRect(x: 1500, y: 0, width: 400, height: 300)),
                               CaptureWindow(id: 2, ownerPID: 1, frame: .null)]).isEmpty)
        XCTAssertTrue(WindowSelection.targets(from: [], display: .zero, localSize: display.size, excludingPID: 99).isEmpty)
    }
    func testRetinaWindowCropRoundsOnceAndIncludesEdgePixels() {
        let window = CaptureWindow(id: 1, ownerPID: 1, frame: CGRect(x: 10.25, y: 20.5, width: 800.5, height: 600.25))
        let rect = targets([window]).first!.rect
        XCTAssertEqual(rect, window.frame)
        XCTAssertEqual(CaptureGeometry.pixelRect(selection: rect, bounds: display.size, pixels: CGSize(width: 2880, height: 1800)),
                       CGRect(x: 20, y: 41, width: 1602, height: 1201))
    }
    func testWindowCoordinatesScaleToOverlayWithoutChangingZOrder() {
        let windows = [CaptureWindow(id: 2, ownerPID: 1, frame: CGRect(x: 200, y: 100, width: 400, height: 300)),
                       CaptureWindow(id: 1, ownerPID: 1, frame: display)]
        let list = WindowSelection.targets(from: windows, display: display, localSize: CGSize(width: 720, height: 450), excludingPID: 99)
        XCTAssertEqual(list.map(\.id), [2, 1])
        XCTAssertEqual(list.first?.rect, CGRect(x: 100, y: 50, width: 200, height: 150))
    }
}

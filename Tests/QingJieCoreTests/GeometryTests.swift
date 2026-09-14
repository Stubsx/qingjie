import XCTest
@testable import QingJieCore

final class GeometryTests: XCTestCase {
    func testReverseDirectionSelection() {
        XCTAssertEqual(CaptureGeometry.rectangle(from: CGPoint(x: 180, y: 90), to: CGPoint(x: 20, y: 10)),
                       CGRect(x: 20, y: 10, width: 160, height: 80))
    }
    func testRetinaCropAndClipping() {
        let rect = CaptureGeometry.pixelRect(selection: CGRect(x: -10, y: 10.25, width: 110.25, height: 80.25),
                                             bounds: CGSize(width: 100, height: 100), pixels: CGSize(width: 200, height: 200))
        XCTAssertEqual(rect, CGRect(x: 0, y: 20, width: 200, height: 161))
    }
    func testOffscreenAndEmptySelectionsAreRejected() {
        XCTAssertNil(CaptureGeometry.pixelRect(selection: CGRect(x: 101, y: 0, width: 2, height: 2),
                                              bounds: CGSize(width: 100, height: 100), pixels: CGSize(width: 200, height: 200)))
        XCTAssertNil(CaptureGeometry.pixelRect(selection: .zero, bounds: .zero, pixels: .zero))
    }
    func testScaledCanvasPointMapping() {
        let frame = CaptureGeometry.fit(image: CGSize(width: 2000, height: 1000), in: CGSize(width: 1064, height: 664))
        XCTAssertEqual(frame, CGRect(x: 32, y: 82, width: 1000, height: 500))
        XCTAssertEqual(CaptureGeometry.imagePoint(CGPoint(x: 532, y: 332), displayedIn: frame,
                                                  imageSize: CGSize(width: 2000, height: 1000)), CGPoint(x: 1000, y: 500))
    }
    func testOnePixelEdgeRemainsInsideImage() {
        let rect = CaptureGeometry.pixelRect(selection: CGRect(x: 99.75, y: 99.75, width: 2, height: 2),
                                             bounds: CGSize(width: 100, height: 100), pixels: CGSize(width: 200, height: 200))
        XCTAssertEqual(rect, CGRect(x: 199, y: 199, width: 1, height: 1))
    }
    func testToolbarPrefersOutsideSelectionAndAvoidsEdges() {
        let screen = CGSize(width: 1440, height: 900), toolbar = CGSize(width: 680, height: 106)
        let selection = CGRect(x: 100, y: 100, width: 800, height: 400)
        let below = CaptureGeometry.toolbarFrame(selection: selection, bounds: screen, size: toolbar)
        XCTAssertEqual(below.minY, selection.maxY + 10)
        XCTAssertFalse(below.intersects(selection))
        let bottomSelection = CGRect(x: 1300, y: 720, width: 140, height: 180)
        let above = CaptureGeometry.toolbarFrame(selection: bottomSelection, bounds: screen, size: toolbar)
        XCTAssertEqual(above.maxY, bottomSelection.minY - 10)
        XCTAssertLessThanOrEqual(above.maxX, screen.width - 10)
    }
    func testFullscreenAndTinySelectionKeepToolbarVisible() {
        for screen in [CGSize(width: 1024, height: 768), CGSize(width: 1440, height: 900), CGSize(width: 600, height: 400)] {
            for selection in [CGRect(origin: .zero, size: screen), CGRect(x: 1, y: 1, width: 3, height: 3),
                              CGRect(x: screen.width - 3, y: screen.height - 3, width: 3, height: 3)] {
                let toolbar = CaptureGeometry.toolbarFrame(selection: selection, bounds: screen, size: CGSize(width: 680, height: 106))
                XCTAssertTrue(CGRect(origin: .zero, size: screen).insetBy(dx: 9, dy: 9).contains(toolbar))
                XCTAssertGreaterThan(toolbar.width, 0)
                XCTAssertGreaterThan(toolbar.height, 0)
            }
        }
    }
}

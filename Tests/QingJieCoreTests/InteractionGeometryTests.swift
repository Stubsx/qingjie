import XCTest
@testable import QingJieCore

final class InteractionGeometryTests: XCTestCase {
    func testCaptureBorderHitBandsAndCornerPriority() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertEqual(InteractionGeometry.resizeHandle(at: CGPoint(x: 270, y: 104), rect: rect), .edge(.top))
        XCTAssertEqual(InteractionGeometry.resizeHandle(at: CGPoint(x: 350, y: 406), rect: rect), .edge(.bottom))
        XCTAssertEqual(InteractionGeometry.resizeHandle(at: CGPoint(x: 94, y: 230), rect: rect), .edge(.left))
        XCTAssertEqual(InteractionGeometry.resizeHandle(at: CGPoint(x: 496, y: 170), rect: rect), .edge(.right))
        XCTAssertEqual(InteractionGeometry.resizeHandle(at: CGPoint(x: 106, y: 106), rect: rect), .corner(.topLeft))
        XCTAssertNil(InteractionGeometry.resizeHandle(at: CGPoint(x: 300, y: 110), rect: rect))
        XCTAssertNil(InteractionGeometry.resizeHandle(at: CGPoint(x: 90, y: 100), rect: rect))
        XCTAssertNil(InteractionGeometry.resizeHandle(at: CGPoint(x: 300, y: 250), rect: rect))
    }
    func testEdgeDragMovesWholeRectangle() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300), bounds = CGRect(x: 0, y: 0, width: 800, height: 700)
        let cases: [(RectEdge, CGPoint, CGRect)] = [
            (.top, CGPoint(x: 130, y: 80), CGRect(x: 130, y: 80, width: 400, height: 300)),
            (.bottom, CGPoint(x: 60, y: 240), CGRect(x: 60, y: 240, width: 400, height: 300)),
            (.left, CGPoint(x: 220, y: 130), CGRect(x: 220, y: 130, width: 400, height: 300)),
            (.right, CGPoint(x: 90, y: 40), CGRect(x: 90, y: 40, width: 400, height: 300))
        ]
        for (edge, point, expected) in cases {
            for shift in [false, true] {
                XCTAssertEqual(InteractionGeometry.resize(rect, handle: .edge(edge), to: point, bounds: bounds, square: shift), expected)
            }
        }
        XCTAssertEqual(InteractionGeometry.resize(rect, handle: .edge(.top), to: rect.origin, bounds: bounds), rect)
    }
    func testOverlappingCornerBandsChooseNearestCorner() {
        for size in [CGSize(width: 12, height: 12), CGSize(width: 12, height: 100), CGSize(width: 100, height: 12)] {
            let rect = CGRect(origin: CGPoint(x: 100, y: 100), size: size)
            for corner in RectCorner.allCases {
                let point = corner.point(in: rect)
                XCTAssertEqual(InteractionGeometry.resizeHandle(at: point, rect: rect), .corner(corner))
                let inward = CGPoint(x: point.x + (point.x < rect.midX ? 2 : -2),
                                     y: point.y + (point.y < rect.midY ? 2 : -2))
                XCTAssertEqual(InteractionGeometry.resizeHandle(at: inward, rect: rect), .corner(corner))
            }
        }
    }
    func testCornerToEdgeTransitionHasNoGap() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertEqual(InteractionGeometry.resizeHandle(at: CGPoint(x: 109, y: 104), rect: rect), .corner(.topLeft))
        XCTAssertEqual(InteractionGeometry.resizeHandle(at: CGPoint(x: 109.1, y: 104), rect: rect), .edge(.top))
        XCTAssertEqual(InteractionGeometry.resizeHandle(at: CGPoint(x: 496, y: 109), rect: rect), .corner(.topRight))
        XCTAssertEqual(InteractionGeometry.resizeHandle(at: CGPoint(x: 496, y: 109.1), rect: rect), .edge(.right))
    }
    func testEdgeMoveClampsToScreenBounds() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300), bounds = CGRect(x: 0, y: 0, width: 800, height: 700)
        XCTAssertEqual(InteractionGeometry.resize(rect, handle: .edge(.top), to: CGPoint(x: -50, y: -50), bounds: bounds),
                       CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(InteractionGeometry.resize(rect, handle: .edge(.right), to: CGPoint(x: 900, y: 900), bounds: bounds),
                       CGRect(x: 400, y: 400, width: 400, height: 300))
    }
    func testEveryCornerKeepsOppositeAnchor() {
        let rect = CGRect(x: 200, y: 200, width: 200, height: 200), bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        for corner in RectCorner.allCases {
            let start = corner.point(in: rect), anchor = corner.opposite.point(in: rect)
            let next = CGPoint(x: start.x + (start.x < anchor.x ? -50 : 50), y: start.y + (start.y < anchor.y ? -70 : 70))
            let result = InteractionGeometry.resize(rect, corner: corner, to: next, bounds: bounds)
            XCTAssertEqual(result.width, 250); XCTAssertEqual(result.height, 270)
            XCTAssertEqual(corner.opposite.point(in: result), anchor)
        }
    }
    func testResizeClipsToScreenAndCanCrossAnchor() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 200), bounds = CGRect(x: 0, y: 0, width: 500, height: 400)
        XCTAssertEqual(InteractionGeometry.resize(rect, corner: .topLeft, to: CGPoint(x: -100, y: -100), bounds: bounds),
                       CGRect(x: 0, y: 0, width: 300, height: 300))
        XCTAssertEqual(InteractionGeometry.resize(rect, corner: .bottomRight, to: CGPoint(x: 50, y: 60), bounds: bounds),
                       CGRect(x: 50, y: 60, width: 50, height: 40))
    }
    func testDegenerateResizeKeepsUsableSelectionAndShiftMakesSquare() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 150), bounds = CGRect(x: 0, y: 0, width: 500, height: 400)
        XCTAssertEqual(InteractionGeometry.resize(rect, corner: .bottomRight, to: CGPoint(x: 101, y: 101), bounds: bounds), rect)
        XCTAssertEqual(InteractionGeometry.resize(rect, corner: .bottomRight, to: CGPoint(x: 400, y: 300), bounds: bounds, square: true),
                       CGRect(x: 100, y: 100, width: 200, height: 200))
    }
    func testCornerHitDoesNotClaimEntireBorderOrInterior() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertEqual(InteractionGeometry.corner(at: CGPoint(x: 104, y: 104), rect: rect, radius: 9), .topLeft)
        XCTAssertNil(InteractionGeometry.corner(at: CGPoint(x: 300, y: 100), rect: rect, radius: 9))
        XCTAssertNil(InteractionGeometry.corner(at: CGPoint(x: 300, y: 200), rect: rect, radius: 9))
    }
    func testLineHitUsesSegmentAndHandlesZeroLength() {
        XCTAssertEqual(InteractionGeometry.distance(CGPoint(x: 50, y: 10), toSegmentFrom: .zero, to: CGPoint(x: 100, y: 0)), 10, accuracy: 0.001)
        XCTAssertEqual(InteractionGeometry.distance(CGPoint(x: 103, y: 4), toSegmentFrom: .zero, to: CGPoint(x: 100, y: 0)), 5, accuracy: 0.001)
        XCTAssertEqual(InteractionGeometry.distance(CGPoint(x: 3, y: 4), toSegmentFrom: .zero, to: .zero), 5, accuracy: 0.001)
    }
    func testPreviewPrefersEmptyLeftOrRightAndStaysOnScreen() {
        let bounds = CGRect(x: 0, y: 32, width: 1512, height: 900)
        for selection in [CGRect(x: 600, y: 80, width: 800, height: 780), CGRect(x: 40, y: 80, width: 850, height: 780)] {
            let preview = InteractionGeometry.scrollPreviewFrame(selection: selection, bounds: bounds)
            XCTAssertFalse(preview.intersects(selection)); XCTAssertTrue(bounds.contains(preview))
            XCTAssertEqual(preview.width, 320); XCTAssertEqual(preview.height, 680)
        }
    }
    func testPreviewFitsHorizontalSpaceAndFullscreenFallback() {
        let bounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let selection = CGRect(x: 20, y: 20, width: 984, height: 200)
        let preview = InteractionGeometry.scrollPreviewFrame(selection: selection, bounds: bounds)
        XCTAssertFalse(preview.intersects(selection)); XCTAssertTrue(bounds.contains(preview))
        XCTAssertTrue(bounds.contains(InteractionGeometry.scrollPreviewFrame(selection: bounds, bounds: bounds)))
    }
}

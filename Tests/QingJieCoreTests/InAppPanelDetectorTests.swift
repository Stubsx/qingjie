import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import QingJieCore

final class InAppPanelDetectorTests: XCTestCase {
    private let size = CGSize(width: 1000, height: 700)
    private let panel = CGRect(x: 250, y: 170, width: 500, height: 340)
    private var window: WindowSelectionTarget { .init(id: 1, rect: CGRect(origin: .zero, size: size), name: "浏览器") }
    private func sample(panel: CGRect?, dark: Bool = false, scale: Int = 1, lowContrast: Bool = false,
                        rounded: Bool = false, nested: Bool = false, outlineOnly: Bool = false) -> CGImage {
        let width = 1000 * scale, height = 700 * scale
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let point = CGPoint(x: CGFloat(x) / CGFloat(scale), y: CGFloat(y) / CGFloat(scale))
            var inside = panel?.contains(point) ?? false
            if rounded, let panel, inside {
                let cx = min(max(point.x, panel.minX + 20), panel.maxX - 20)
                let cy = min(max(point.y, panel.minY + 20), panel.maxY - 20)
                inside = hypot(point.x - cx, point.y - cy) <= 20
            }
            var gray: UInt8 = dark ? 22 : 140
            if inside {
                gray = dark ? 62 : lowContrast ? 152 : 250
                if rounded, let panel, point.y < panel.minY + 45 { gray = dark ? 56 : 234 }
                if nested, CGRect(x: 350, y: 310, width: 300, height: 140).contains(point) { gray = 180 }
                if outlineOnly, let panel { gray = panel.insetBy(dx: 2, dy: 2).contains(point) ? 140 : 250 }
                if x / scale > 300 && x / scale < 680 && (y / scale == 240 || y / scale == 290) { gray = dark ? 180 : 40 }
            }
            let i = (y * width + x) * 4
            bytes[i] = gray; bytes[i + 1] = gray; bytes[i + 2] = gray
        } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    func testLightDialogSnapsInsideAndFallsBackOutside() {
        let targets = InAppPanelDetector.enrich([window], image: sample(panel: panel), localSize: size)
        XCTAssertEqual(targets.first?.panels, [panel])
        XCTAssertEqual(WindowSelection.target(at: CGPoint(x: 400, y: 300), in: targets)?.rect, panel)
        XCTAssertEqual(WindowSelection.target(at: CGPoint(x: 100, y: 100), in: targets)?.rect, window.rect)
        XCTAssertEqual(WindowSelection.target(at: CGPoint(x: 400, y: 300), in: targets, wholeWindow: true)?.rect, window.rect)
    }
    func testDarkDialogAndRetinaBounds() {
        for scale in [1, 2, 3] {
            let targets = InAppPanelDetector.enrich([window], image: sample(panel: panel, dark: true, scale: scale), localSize: size)
            XCTAssertEqual(targets.first?.panels.count, 1)
            if let actual = targets.first?.panels.first {
                XCTAssertEqual(actual.minX, panel.minX, accuracy: 1 / CGFloat(scale))
                XCTAssertEqual(actual.minY, panel.minY, accuracy: 1 / CGFloat(scale))
                XCTAssertEqual(actual.width, panel.width, accuracy: 1 / CGFloat(scale))
                XCTAssertEqual(actual.height, panel.height, accuracy: 1 / CGFloat(scale))
            }
        }
    }
    func testWeakBoundariesAndNoDialogUseNativeWindow() {
        for image in [sample(panel: nil), sample(panel: panel, lowContrast: true)] {
            let targets = InAppPanelDetector.enrich([window], image: image, localSize: size)
            XCTAssertEqual(targets.first?.panels, [])
            XCTAssertEqual(WindowSelection.target(at: CGPoint(x: 400, y: 300), in: targets)?.rect, window.rect)
        }
    }
    func testSmallControlsAndPageSizedSurfacesAreNotDialogs() {
        for rect in [CGRect(x: 200, y: 170, width: 180, height: 30), CGRect(x: 10, y: 70, width: 980, height: 600)] {
            XCTAssertTrue(InAppPanelDetector.enrich([window], image: sample(panel: rect), localSize: size)[0].panels.isEmpty)
        }
    }
    func testOccludedPanelCannotOverrideTheFrontWindow() {
        let front = WindowSelectionTarget(id: 2, rect: CGRect(x: 600, y: 100, width: 300, height: 400))
        let targets = InAppPanelDetector.enrich([front, window], image: sample(panel: panel), localSize: size)
        XCTAssertTrue(targets.allSatisfy { $0.panels.isEmpty })
        XCTAssertEqual(WindowSelection.target(at: CGPoint(x: 650, y: 200), in: targets)?.id, 2)
    }
    func testInvalidInputsAndDesktopHaveNoPanelTargets() {
        XCTAssertTrue(InAppPanelDetector.enrich([], image: sample(panel: panel), localSize: size).isEmpty)
        XCTAssertEqual(InAppPanelDetector.enrich([window], image: sample(panel: panel), localSize: .zero), [window])
    }
    func testRoundedDialogsWithDifferentHeaderShadeKeepTheOuterBounds() {
        for dark in [false, true] {
            let result = InAppPanelDetector.enrich([window], image: sample(panel: panel, dark: dark, scale: 2, rounded: true), localSize: size)
            XCTAssertEqual(result[0].panels, [panel])
        }
    }
    func testNestedCardsDoNotStealTheOuterDialog() {
        let result = InAppPanelDetector.enrich([window], image: sample(panel: panel, nested: true), localSize: size)
        XCTAssertEqual(result[0].panels, [panel])
        XCTAssertEqual(WindowSelection.target(at: CGPoint(x: 500, y: 400), in: result)?.rect, panel)
    }
    func testThinOutlineDoesNotCreateAFalseWindow() {
        let result = InAppPanelDetector.enrich([window], image: sample(panel: panel, outlineOnly: true), localSize: size)
        XCTAssertTrue(result[0].panels.isEmpty)
    }
    func testUserProvidedWebDialogFixtureWhenAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["QINGJIE_PANEL_FIXTURE"] else { throw XCTSkip("Optional local user-provided screenshot") }
        let url = URL(fileURLWithPath: path)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let pixels = CGSize(width: image.width, height: image.height)
        let app = WindowSelectionTarget(id: 1, rect: CGRect(x: pixels.width * 0.02, y: pixels.height * 0.035,
                                                           width: pixels.width * 0.96, height: pixels.height * 0.93), name: "浏览器")
        let start = Date()
        let targets = InAppPanelDetector.enrich([app], image: image, localSize: pixels)
        let selected = try XCTUnwrap(WindowSelection.target(at: CGPoint(x: pixels.width * 0.5, y: pixels.height * 0.5), in: targets))
        print("Panel fixture: \(selected.rect), candidates=\(targets[0].panels), elapsed=\(Date().timeIntervalSince(start))s")
        XCTAssertEqual(selected.rect.minX / pixels.width, 0.322, accuracy: 0.003)
        XCTAssertEqual(selected.rect.minY / pixels.height, 0.330, accuracy: 0.003)
        XCTAssertEqual(selected.rect.maxX / pixels.width, 0.678, accuracy: 0.003)
        XCTAssertEqual(selected.rect.maxY / pixels.height, 0.742, accuracy: 0.003)
        XCTAssertEqual(WindowSelection.target(at: CGPoint(x: pixels.width * 0.15, y: pixels.height * 0.2), in: targets)?.rect, app.rect)
    }
}

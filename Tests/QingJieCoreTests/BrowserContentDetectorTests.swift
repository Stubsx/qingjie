import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import QingJieCore

final class BrowserContentDetectorTests: XCTestCase {
    private let size = CGSize(width: 1200, height: 850)
    private let rect = CGRect(x: 40, y: 30, width: 1100, height: 780)
    private func sample(scale: Int = 1, dark: Bool = false, tabs: Int = 40, toolbar: Int = 52,
                        bookmarks: Int = 0, divider: Bool = true, field: Bool = true, dialog: Bool = false) -> CGImage {
        let width = 1200 * scale, height = 850 * scale
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let point = CGPoint(x: Double(x) / Double(scale), y: Double(y) / Double(scale))
            let localY = Int(point.y - rect.minY), localX = point.x - rect.minX
            var gray: UInt8 = 90
            if rect.contains(point) {
                gray = dark ? 28 : 255
                if localY < tabs { gray = dark ? 18 : 214 }
                let fieldTop = tabs + (toolbar - 32) / 2
                if field && localY >= fieldTop && localY < fieldTop + 32 && localX >= 100 && localX < 980 { gray = dark ? 52 : 238 }
                if bookmarks > 0 && localY >= tabs + toolbar + 8 && localY < tabs + toolbar + bookmarks - 8 && Int(localX) % 130 < 65 { gray = dark ? 180 : 80 }
                if divider && localY == tabs + toolbar + bookmarks { gray = dark ? 65 : 220 }
                if dialog && localY > tabs + toolbar {
                    gray = CGRect(x: 300, y: 270, width: 500, height: 350).contains(point) ? 250 : 130
                }
            }
            let i = (y * width + x) * 4
            bytes[i] = gray; bytes[i + 1] = gray; bytes[i + 2] = gray
        } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    func testMeasuredToolbarAtDifferentScalesAndHeights() throws {
        for scale in [1, 2, 3] { for tabs in [32, 44] { for toolbar in [44, 56] {
            let result = try XCTUnwrap(BrowserContentDetector.contentRect(window: rect, occluders: [],
                image: sample(scale: scale, tabs: tabs, toolbar: toolbar), localSize: size))
            XCTAssertEqual(result, CGRect(x: rect.minX, y: rect.minY + CGFloat(tabs + toolbar), width: rect.width,
                                          height: rect.height - CGFloat(tabs + toolbar)))
        } } }
    }
    func testDarkAndBookmarksBar() throws {
        for dark in [false, true] { for bookmarks in [0, 30] {
            let result = try XCTUnwrap(BrowserContentDetector.contentRect(window: rect, occluders: [],
                image: sample(scale: 2, dark: dark, bookmarks: bookmarks), localSize: size))
            XCTAssertEqual(result.minY, rect.minY + CGFloat(92 + bookmarks))
        } }
    }
    func testSameColorPageWithoutDividerUsesMeasuredFieldPadding() throws {
        let result = try XCTUnwrap(BrowserContentDetector.contentRect(window: rect, occluders: [],
            image: sample(tabs: 44, toolbar: 56, divider: false), localSize: size))
        XCTAssertEqual(result.minY, rect.minY + 100)
    }
    func testNoAddressFieldAndObscuredHeaderFallBack() {
        XCTAssertNil(BrowserContentDetector.contentRect(window: rect, occluders: [], image: sample(field: false), localSize: size))
        XCTAssertNil(BrowserContentDetector.contentRect(window: rect, occluders: [CGRect(x: 500, y: 80, width: 300, height: 200)],
                                                        image: sample(), localSize: size))
        XCTAssertNotNil(BrowserContentDetector.contentRect(window: rect, occluders: [CGRect(x: 500, y: 400, width: 300, height: 200)],
                                                           image: sample(), localSize: size))
        XCTAssertNotNil(BrowserContentDetector.contentRect(window: rect, occluders: [CGRect(x: 500, y: 140, width: 300, height: 200)],
                                                           image: sample(), localSize: size))
    }
    func testNativeMetadataAndClippingControlEligibility() {
        for bundle in ["com.google.Chrome", "com.microsoft.edgemac", "com.apple.finder"] {
            for frame in [rect, CGRect(x: -40, y: 30, width: 1100, height: 780), CGRect(x: 40, y: -30, width: 1100, height: 780)] {
                let targets = WindowSelection.targets(from: [.init(id: 1, ownerPID: 1, frame: frame, bundleIdentifier: bundle)],
                                                       display: CGRect(origin: .zero, size: size), localSize: size, excludingPID: 2)
                XCTAssertEqual(targets[0].canDetectBrowserContent, frame == rect && bundle != "com.apple.finder")
            }
        }
    }
    func testDialogPageAndWholeWindowSelectionHierarchy() throws {
        let native = WindowSelectionTarget(id: 1, rect: rect, name: "Chrome", canDetectBrowserContent: true)
        let targets = InAppPanelDetector.enrich([native], image: sample(dialog: true), localSize: size)
        let content = try XCTUnwrap(targets[0].browserContent)
        XCTAssertEqual(WindowSelection.target(at: CGPoint(x: 500, y: 400), in: targets)?.rect, CGRect(x: 300, y: 270, width: 500, height: 350))
        XCTAssertEqual(WindowSelection.target(at: CGPoint(x: 150, y: 400), in: targets)?.rect, content)
        XCTAssertEqual(WindowSelection.target(at: CGPoint(x: 500, y: 70), in: targets)?.rect, rect)
        XCTAssertEqual(WindowSelection.target(at: CGPoint(x: 500, y: 400), in: targets, wholeWindow: true)?.rect, rect)
        let ordinary = WindowSelectionTarget(id: 1, rect: rect)
        XCTAssertNil(InAppPanelDetector.enrich([ordinary], image: sample(), localSize: size)[0].browserContent)
    }
    func testUserProvidedChromeContentFixtureWhenAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["QINGJIE_BROWSER_FIXTURE"] else { throw XCTSkip("Optional local user-provided screenshot") }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let localSize = CGSize(width: image.width / 2, height: image.height / 2)
        let window = WindowSelectionTarget(id: 1, rect: CGRect(x: 42, y: 42, width: 2048, height: 1122), name: "Google Chrome", canDetectBrowserContent: true)
        let start = Date()
        let targets = InAppPanelDetector.enrich([window], image: image, localSize: localSize)
        let content = try XCTUnwrap(targets[0].browserContent)
        print("Browser fixture: \(content), elapsed=\(Date().timeIntervalSince(start))s")
        XCTAssertEqual(content.minX, 42); XCTAssertEqual(content.width, 2048); XCTAssertEqual(content.maxY, 1164)
        XCTAssertEqual(content.minY, 126, accuracy: 2)
        XCTAssertEqual(WindowSelection.target(at: CGPoint(x: 1000, y: 400), in: targets)?.rect, content)
        XCTAssertEqual(WindowSelection.target(at: CGPoint(x: 1000, y: 80), in: targets)?.rect, window.rect)
    }
}

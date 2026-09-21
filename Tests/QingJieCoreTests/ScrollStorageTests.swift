import XCTest
import CoreGraphics
import ImageIO
@testable import QingJieCore

final class ScrollStorageTests: XCTestCase {
    private func frame(_ offset: Int = 0, width: Int = 128, height: Int = 200) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt64(y + offset + 1) &* 6364136223846793005 &+ UInt64(x / 4 + 1) &* 1442695040888963407
                let i = (y * width + x) * 4
                bytes[i] = UInt8(20 + (value ^ (value >> 33)) % 220)
                bytes[i + 1] = UInt8(20 + (value ^ (value >> 29)) % 220)
                bytes[i + 2] = UInt8(20 + (value ^ (value >> 31)) % 220)
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    private func pixels(_ image: CGImage) -> Data {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: context.bytesPerRow * image.height)
    }
    private func decode(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func stitcher(budget: Int = 0) throws -> VerticalStitcher {
        try VerticalStitcher(first: frame(), contentRegion: CGRect(x: 0, y: 0, width: 128, height: 200), memoryBudget: budget)
    }
    func testDiskBackedStitchAndPreviewPreservePixels() throws {
        let stitcher = try stitcher()
        for offset in stride(from: 73, through: 1460, by: 73) {
            XCTAssertEqual(try stitcher.append(frame(offset)), .appended(73))
            XCTAssertEqual(stitcher.residentImageBytes, 0)
        }
        XCTAssertTrue(stitcher.usesDiskCache)
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(frame(0, height: 1660)))
        let file = try stitcher.exportPNG()
        XCTAssertEqual(pixels(try decode(file.url)), pixels(frame(0, height: 1660)))
        let preview = try stitcher.preview()
        XCTAssertLessThanOrEqual(preview.height, 260)
        let previewBytes = pixels(preview)
        XCTAssertTrue(stride(from: 3, to: previewBytes.count, by: 4).allSatisfy { previewBytes[$0] == 255 })
    }
    func testBottomCropPreservesExactPrefixAndCanBeAdjustedOrResumed() throws {
        for budget in [0, 1024 * 1024] {
            let stitcher = try stitcher(budget: budget)
            for offset in stride(from: 73, through: 730, by: 73) { _ = try stitcher.append(frame(offset)) }
            for height in [1, 199, 200, 273, 389, 900, 930] {
                let expected = frame(0, height: height)
                XCTAssertEqual(pixels(try stitcher.compose(height: height)), pixels(expected))
                let file = try stitcher.exportPNG(height: height)
                XCTAssertEqual(pixels(try decode(file.url)), pixels(expected))
                XCTAssertEqual(stitcher.totalHeight, 930)
            }
            XCTAssertEqual(try stitcher.append(frame(803)), .appended(73))
            XCTAssertEqual(pixels(try stitcher.compose()), pixels(frame(0, height: 1003)))
        }
    }
    func testBottomCropAppliesAppearanceAtTheNewEdgeAndRejectsInvalidHeights() throws {
        let stitcher = try stitcher()
        for offset in stride(from: 73, through: 730, by: 73) { _ = try stitcher.append(frame(offset)) }
        let appearance = ScreenshotAppearance(roundedCorners: true, shadow: true)
        let file = try stitcher.exportPNG(appearance: appearance, height: 511)
        let actual = try decode(file.url), expected = try appearance.render(frame(0, height: 511))
        XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
        XCTAssertLessThanOrEqual(zip(pixels(actual), pixels(expected)).map { abs(Int($0) - Int($1)) }.max() ?? 0, 1)
        for height in [-1, 0, 931] {
            XCTAssertThrowsError(try stitcher.compose(height: height))
            XCTAssertThrowsError(try stitcher.exportPNG(height: height))
        }
        XCTAssertEqual(stitcher.residentImageBytes, 0)
    }
    func testBandedAppearanceMatchesWholeImageAtJoinsAndTransparentEdges() throws {
        let stitcher = try stitcher()
        for offset in stride(from: 73, through: 1460, by: 73) { _ = try stitcher.append(frame(offset)) }
        let image = try stitcher.compose()
        for appearance in [ScreenshotAppearance(roundedCorners: true),
                           ScreenshotAppearance(roundedCorners: true, shadow: true, cornerRadius: 30,
                                                shadowBlur: 18, shadowOffset: 9, shadowOpacity: 0.4),
                           ScreenshotAppearance(shadow: true, shadowBlur: 48, shadowOffset: 32)] {
            let expected = try appearance.render(image, pixelsPerPoint: 2)
            let file = try stitcher.exportPNG(appearance: appearance, pixelsPerPoint: 2)
            let actual = try decode(file.url)
            XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
            let a = pixels(actual), b = pixels(expected)
            let difference = zip(a, b).map { abs(Int($0) - Int($1)) }
            // PNG unpremultiplication can round color channels by one.
            XCTAssertLessThanOrEqual(difference.max() ?? 0, 1)
        }
    }
    func testCacheAndExportLifetimesAndCancellationCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var stitcher: VerticalStitcher? = try VerticalStitcher(first: frame(), memoryBudget: 0, temporaryRoot: root)
        let directory = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let before = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count
        XCTAssertThrowsError(try stitcher!.exportPNG(checkCancellation: { throw CancellationError() }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, before)
        var file: ScrollPNGFile? = try stitcher!.exportPNG()
        stitcher = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: file!.url.path))
        XCTAssertEqual(pixels(try decode(file!.url)), pixels(frame()))
        file = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testCacheFailurePreservesAcceptedContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let stitcher = try VerticalStitcher(first: frame(), contentRegion: CGRect(x: 0, y: 0, width: 128, height: 200),
                                          memoryBudget: 128 * 200 * 4, temporaryRoot: root)
        XCTAssertThrowsError(try stitcher.append(frame(73)))
        XCTAssertEqual(stitcher.totalHeight, 200)
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(frame()))
        try FileManager.default.removeItem(at: root)
        XCTAssertEqual(try stitcher.append(frame(73)), .appended(73))
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(frame(0, height: 273)))
    }
    func testAutomaticCapturePassesFormerHeightAndPixelCaps() throws {
        let width = 800, height = 200, budget = 1024 * 1024
        let stitcher = try VerticalStitcher(first: frame(width: width), contentRegion: CGRect(x: 0, y: 0, width: width, height: height), memoryBudget: budget)
        for offset in stride(from: 97, through: 41_225, by: 97) {
            try autoreleasepool {
                XCTAssertEqual(try stitcher.append(frame(offset, width: width)), .appended(97))
                XCTAssertLessThanOrEqual(stitcher.residentImageBytes, budget)
            }
        }
        XCTAssertGreaterThan(stitcher.totalHeight, 40_000)
        XCTAssertGreaterThan(stitcher.width * stitcher.totalHeight, 32_000_000)
        let file = try stitcher.exportPNG()
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file.url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, width)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, stitcher.totalHeight)
        let thumbnail = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 560
        ] as CFDictionary))
        XCTAssertLessThanOrEqual(thumbnail.height, 560)
    }
    func testSlowScrollingPassesFormerThousandFrameCap() throws {
        let stitcher = try stitcher(budget: 512 * 1024)
        for offset in 1...1002 { XCTAssertEqual(try stitcher.append(frame(offset)), .appended(1)) }
        XCTAssertEqual(stitcher.frameCount, 1003)
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(frame(0, height: 1202)))
    }
    func testDefaultBudgetAutomaticallySpillsWithoutConfiguration() throws {
        let width = 512, budget = ScrollImageStorage.automaticMemoryBudget
        let stitcher = try VerticalStitcher(first: frame(width: width), contentRegion: CGRect(x: 0, y: 0, width: width, height: 200))
        let target = budget / (width * 4) + 400
        for offset in stride(from: 97, through: target, by: 97) {
            try autoreleasepool { XCTAssertEqual(try stitcher.append(frame(offset, width: width)), .appended(97)) }
        }
        XCTAssertTrue(stitcher.usesDiskCache)
        XCTAssertTrue(stitcher.prefersFileExport)
        XCTAssertLessThanOrEqual(stitcher.residentImageBytes, budget)
    }
}

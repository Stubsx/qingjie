import XCTest
import CoreGraphics
@testable import QingJieCore

final class VerticalStitcherTests: XCTestCase {
    /// A repeatable document containing distinct short horizontal and vertical strokes.
    private func frame(offset: Int, height: Int = 640, width: Int = 320, header: Int = 0, footer: Int = 0, seed: Int = 1, period: Int = 0,
                       left: Int = 0, right: Int = 0, sidebarSeed: Int = 1) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let row = y < header ? y - 10000 : y >= height - footer ? y - height + 20000 : offset + y - header
            let documentY = period > 0 ? ((row % period) + period) % period : row
            for x in 0..<width {
                let side = x < left || x >= width - right
                let sourceY = side ? y + sidebarSeed * 1700 : documentY
                let value = UInt64(abs(sourceY / 3 + seed * 7129)) &* 6364136223846793005 &+ UInt64(x / 5 + 1) &* 1442695040888963407
                let level = UInt8(20 + (value ^ (value >> 33)) % 220)
                let i = (y * width + x) * 4
                bytes[i] = level; bytes[i + 1] = level; bytes[i + 2] = level
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    private func pixels(_ image: CGImage) -> Data {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }
    func testExactStitchAcrossUnevenScrollDistances() throws {
        let stitcher = try VerticalStitcher(first: frame(offset: 0))
        for (offset, delta) in [(137, 137), (381, 244), (498, 117), (901, 403)] {
            XCTAssertEqual(try stitcher.append(frame(offset: offset)), .appended(delta))
        }
        XCTAssertEqual(stitcher.totalHeight, 1541)
        XCTAssertEqual(stitcher.frameCount, 5)
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(frame(offset: 0, height: 1541)))
    }
    func testDuplicatesDoNotExtendTheImage() throws {
        let stitcher = try VerticalStitcher(first: frame(offset: 0))
        XCTAssertEqual(try stitcher.append(frame(offset: 0)), .unchanged)
        XCTAssertEqual(stitcher.frameCount, 1); XCTAssertEqual(stitcher.totalHeight, 640)
    }
    func testSinglePixelScrollIsNotDropped() throws {
        let stitcher = try VerticalStitcher(first: frame(offset: 0))
        XCTAssertEqual(try stitcher.append(frame(offset: 1)), .appended(1))
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(frame(offset: 0, height: 641)))
    }
    func testReverseScrollAndReturnToFurthestPosition() throws {
        let stitcher = try VerticalStitcher(first: frame(offset: 200))
        XCTAssertEqual(try stitcher.append(frame(offset: 100)), .backwards)
        XCTAssertEqual(try stitcher.append(frame(offset: 200)), .unchanged)
        XCTAssertEqual(try stitcher.append(frame(offset: 377)), .appended(177))
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(frame(offset: 200, height: 817)))
    }

    private func elasticFrame(offset: Int, blank: Int, header: Int = 0, footer: Int = 0) -> CGImage {
        let image = frame(offset: offset, header: header, footer: footer)
        let context = CGContext(data: nil, width: 320, height: 640, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 320, height: 640))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: footer, width: 320, height: blank))
        return context.makeImage()!
    }

    func testElasticBlankTailDoesNotBecomePermanentContent() throws {
        let stitcher = try VerticalStitcher(first: frame(offset: 0))
        XCTAssertEqual(try stitcher.append(frame(offset: 200)), .appended(200))
        let original = pixels(try stitcher.compose())
        for extra in [22, 38, 14] {
            XCTAssertEqual(try stitcher.append(elasticFrame(offset: 200 + extra, blank: extra), allowQuietTail: false), .settling)
            XCTAssertEqual(pixels(try stitcher.compose()), original)
        }
        XCTAssertEqual(try stitcher.append(frame(offset: 200), allowQuietTail: false), .unchanged)
        XCTAssertEqual(stitcher.totalHeight, 840)
        XCTAssertEqual(try stitcher.append(frame(offset: 310), allowQuietTail: false), .appended(110))
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(frame(offset: 0, height: 950)))
    }

    func testStableRealPagePaddingCanStillBeCaptured() throws {
        let stitcher = try VerticalStitcher(first: frame(offset: 0))
        let image = elasticFrame(offset: 24, blank: 24)
        XCTAssertEqual(try stitcher.append(image, allowQuietTail: false), .settling)
        XCTAssertEqual(stitcher.frameCount, 1)
        XCTAssertEqual(try stitcher.append(image, allowQuietTail: true), .appended(24))
        XCTAssertEqual(stitcher.totalHeight, 664)
        XCTAssertEqual(try stitcher.append(image, allowQuietTail: false), .unchanged)
    }

    func testHeldElasticTailIsReclaimedWhenItSpringsBack() throws {
        for budget: Int? in [nil, 0] {
            let stitcher = try VerticalStitcher(first: frame(offset: 0, header: 42, footer: 39), memoryBudget: budget)
            _ = try stitcher.append(frame(offset: 200, header: 42, footer: 39))
            let expected = pixels(try stitcher.compose())
            let held = elasticFrame(offset: 227, blank: 27, header: 42, footer: 39)
            XCTAssertEqual(try stitcher.append(held), .appended(27))
            XCTAssertEqual(try stitcher.append(held), .unchanged)
            XCTAssertEqual(try stitcher.append(frame(offset: 200, header: 42, footer: 39)), .unchanged)
            XCTAssertEqual(stitcher.totalHeight, 840)
            XCTAssertEqual(pixels(try stitcher.compose()), expected)
        }
    }

    func testElasticTailWithFixedChromeDoesNotDuplicateFooter() throws {
        let first = frame(offset: 0, header: 42, footer: 39)
        let stitcher = try VerticalStitcher(first: first)
        _ = try stitcher.append(frame(offset: 170, header: 42, footer: 39))
        let original = pixels(try stitcher.compose())
        XCTAssertEqual(try stitcher.append(elasticFrame(offset: 193, blank: 23, header: 42, footer: 39), allowQuietTail: false), .settling)
        XCTAssertEqual(try stitcher.append(frame(offset: 170, header: 42, footer: 39)), .unchanged)
        XCTAssertEqual(pixels(try stitcher.compose()), original)
    }
    func testRejectedFrameDoesNotPoisonSubsequentMatching() throws {
        let stitcher = try VerticalStitcher(first: frame(offset: 0))
        XCTAssertEqual(try stitcher.append(frame(offset: 2400, seed: 5)), .noOverlap)
        XCTAssertEqual(try stitcher.append(frame(offset: 159)), .appended(159))
    }
    func testFixedHeaderAndFooterAppearOnlyOnce() throws {
        let stitcher = try VerticalStitcher(first: frame(offset: 0, header: 42, footer: 39))
        XCTAssertEqual(try stitcher.append(frame(offset: 171, header: 42, footer: 39)), .appended(171))
        XCTAssertEqual(try stitcher.append(frame(offset: 318, header: 42, footer: 39)), .appended(147))
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(frame(offset: 0, height: 958, header: 42, footer: 39)))
    }
    func testLimitsPreserveAlreadyAcceptedImage() throws {
        let stitcher = try VerticalStitcher(first: frame(offset: 0), limits: .init(maximumPixels: 320 * 800, maximumHeight: 800))
        XCTAssertEqual(try stitcher.append(frame(offset: 180)), .limitReached)
        XCTAssertEqual(stitcher.totalHeight, 640)
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(frame(offset: 0)))
    }
    func testSizeChangeIsRejected() throws {
        let stitcher = try VerticalStitcher(first: frame(offset: 0))
        XCTAssertThrowsError(try stitcher.append(frame(offset: 180, width: 321)))
    }
    func testPreviewIsBoundedAndKeepsAspectRatio() throws {
        let stitcher = try VerticalStitcher(first: frame(offset: 0))
        _ = try stitcher.append(frame(offset: 300))
        let preview = try stitcher.preview()
        XCTAssertLessThanOrEqual(preview.height, 260); XCTAssertLessThanOrEqual(preview.width, 160)
        XCTAssertEqual(Double(preview.width) / Double(preview.height), 320.0 / 940.0, accuracy: 0.01)
    }
    func testPreviewDoesNotIntroduceTransparentHorizontalSeams() throws {
        let region = CGRect(x: 0, y: 0, width: 320, height: 640)
        let stitcher = try VerticalStitcher(first: frame(offset: 0), contentRegion: region)
        var offset = 0
        for delta in [1, 3, 7, 13, 29, 61, 137, 244, 117, 403] {
            offset += delta
            XCTAssertEqual(try stitcher.append(frame(offset: offset)), .appended(delta))
        }
        // The full-size result is opaque; preview scaling must not create transparent
        // rows at the joins, including strips shorter than one destination pixel.
        for (height, width) in [(260, 160), (4096, 119), (4096, 213), (4096, 640)] {
            let preview = try stitcher.preview(maximumHeight: height, maximumWidth: width)
            let data = pixels(preview)
            let translucent = stride(from: 3, to: data.count, by: 4).filter { data[$0] != 255 }.count
            XCTAssertEqual(translucent, 0, "Unexpected transparent pixels at \(preview.width) × \(preview.height)")
        }
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(frame(offset: 0, height: 640 + offset)))
    }
    func testPreviewPreservesBackgroundAcrossFixedChromeAndThinStrips() throws {
        func document(offset: Int) -> CGImage {
            let context = CGContext(data: nil, width: 320, height: 640, bitsPerComponent: 8, bytesPerRow: 320 * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(frame(offset: offset, header: 42, footer: 39), in: CGRect(x: 0, y: 0, width: 320, height: 640))
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 640))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 280, y: 0, width: 40, height: 640))
            return context.makeImage()!
        }
        let stitcher = try VerticalStitcher(first: document(offset: 0),
                                          contentRegion: CGRect(x: 0, y: 0, width: 320, height: 640))
        var offset = 0
        for delta in [137, 1, 3, 7, 29, 61, 117, 244] {
            offset += delta
            XCTAssertEqual(try stitcher.append(document(offset: offset)), .appended(delta))
        }
        XCTAssertEqual(stitcher.scrollingRegion, CGRect(x: 0, y: 42, width: 320, height: 559))
        for (height, width) in [(1, 1), (37, 17), (260, 160), (4096, 119), (4096, 213), (4096, 640)] {
            let preview = try stitcher.preview(maximumHeight: height, maximumWidth: width)
            let data = pixels(preview)
            XCTAssertTrue(stride(from: 3, to: data.count, by: 4).allSatisfy { data[$0] == 255 })
            guard preview.width >= 17 else { continue }
            for x in [preview.width / 16, preview.width * 15 / 16] {
                let expected = Array(data[(x * 4)..<(x * 4 + 4)])
                let changedRows = (0..<preview.height).filter { y in
                    let start = (y * preview.width + x) * 4
                    return Array(data[start..<(start + 4)]) != expected
                }
                XCTAssertTrue(changedRows.isEmpty, "Background has horizontal bands at \(preview.width) × \(preview.height): \(changedRows)")
            }
        }
    }
    func testBlankOrRepeatedContentIsNotGuessed() throws {
        func blank(_ level: CGFloat) -> CGImage {
            let context = CGContext(data: nil, width: 320, height: 640, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: level, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 320, height: 640))
            return context.makeImage()!
        }
        let stitcher = try VerticalStitcher(first: blank(1))
        XCTAssertEqual(try stitcher.append(blank(0.8)), .noOverlap)
        XCTAssertEqual(stitcher.totalHeight, 640)
    }
    func testAmbiguousRepeatedRowsAreRejected() throws {
        let stitcher = try VerticalStitcher(first: frame(offset: 0, period: 128))
        XCTAssertEqual(try stitcher.append(frame(offset: 37, period: 128)), .noOverlap)
        XCTAssertEqual(stitcher.totalHeight, 640)
    }

    func testFixedTopAndBothSidebarsAreNotRepeated() throws {
        let stitcher = try VerticalStitcher(first: frame(offset: 0, header: 72, footer: 36, left: 85, right: 55))
        for (offset, delta) in [(83, 83), (220, 137), (431, 211)] {
            XCTAssertEqual(try stitcher.append(frame(offset: offset, header: 72, footer: 36, left: 85, right: 55)), .appended(delta))
        }
        XCTAssertEqual(stitcher.outputRegion, CGRect(x: 85, y: 0, width: 180, height: 640))
        XCTAssertEqual(stitcher.scrollingRegion, CGRect(x: 85, y: 72, width: 180, height: 532))
        let expected = frame(offset: 0, height: 1071, header: 72, footer: 36).cropping(to: CGRect(x: 85, y: 0, width: 180, height: 1071))!
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(expected))
    }

    func testNarrowContentWithWideSidebarAndTallHeader() throws {
        let stitcher = try VerticalStitcher(first: frame(offset: 0, header: 202, left: 200))
        XCTAssertEqual(try stitcher.append(frame(offset: 141, header: 202, left: 200)), .appended(141))
        XCTAssertEqual(stitcher.width, 120)
        let expected = frame(offset: 0, height: 781, header: 202).cropping(to: CGRect(x: 200, y: 0, width: 120, height: 781))!
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(expected))
    }

    func testManualContentRegionIgnoresChangingChrome() throws {
        let region = CGRect(x: 80, y: 60, width: 190, height: 550)
        let stitcher = try VerticalStitcher(first: frame(offset: 0, header: 60, footer: 30, left: 80, right: 50), contentRegion: region)
        XCTAssertEqual(try stitcher.append(frame(offset: 153, header: 60, footer: 30, left: 80, right: 50, sidebarSeed: 7)), .appended(153))
        XCTAssertEqual(stitcher.outputRegion, region)
        let expected = frame(offset: 0, height: 703).cropping(to: CGRect(x: 80, y: 0, width: 190, height: 703))!
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(expected))
    }

    func testSidebarAnimationAfterLockDoesNotAffectStitching() throws {
        let stitcher = try VerticalStitcher(first: frame(offset: 0, left: 80, right: 40))
        XCTAssertEqual(try stitcher.append(frame(offset: 71, left: 80, right: 40)), .appended(71))
        XCTAssertEqual(try stitcher.append(frame(offset: 71, left: 80, right: 40, sidebarSeed: 8)), .unchanged)
        XCTAssertEqual(try stitcher.append(frame(offset: 213, left: 80, right: 40, sidebarSeed: 9)), .appended(142))
    }

    func testFailedOrReverseMatchDoesNotCommitAutomaticCrop() throws {
        let first = frame(offset: 0, left: 80, right: 40)
        let stitcher = try VerticalStitcher(first: first)
        XCTAssertEqual(try stitcher.append(frame(offset: 1800, left: 80, right: 40)), .noOverlap)
        XCTAssertEqual(stitcher.width, 320); XCTAssertFalse(stitcher.layoutLocked)
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(first))
        XCTAssertEqual(try stitcher.append(frame(offset: -101, left: 80, right: 40)), .backwards)
        XCTAssertEqual(stitcher.width, 320)
        XCTAssertEqual(try stitcher.append(frame(offset: 135, left: 80, right: 40)), .appended(135))
        XCTAssertEqual(stitcher.width, 200)
    }

    func testContinuousSmallScrollsDoNotNeedDuplicateFrames() throws {
        let stitcher = try VerticalStitcher(first: frame(offset: 0, left: 80))
        for offset in stride(from: 11, through: 330, by: 11) {
            XCTAssertEqual(try stitcher.append(frame(offset: offset, left: 80)), .appended(11))
        }
        let expected = frame(offset: 0, height: 970).cropping(to: CGRect(x: 80, y: 0, width: 240, height: 970))!
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(expected))
    }

    func testInvalidManualRegionIsRejected() throws {
        for region in [CGRect(x: -1, y: 0, width: 100, height: 100), CGRect(x: 260, y: 0, width: 100, height: 100),
                       CGRect(x: 10, y: 10, width: 70, height: 100), CGRect(x: 0.5, y: 0, width: 100, height: 100)] {
            XCTAssertThrowsError(try VerticalStitcher(first: frame(offset: 0), contentRegion: region))
        }
    }

    func testMotionRecognitionFindsPaneBetweenAnimatedSidebars() throws {
        let stitcher = try VerticalStitcher(first: frame(offset: 0, header: 60, footer: 30, left: 80, right: 50))
        XCTAssertEqual(try stitcher.append(frame(offset: 137, header: 60, footer: 30, left: 80, right: 50, sidebarSeed: 7)), .appended(137))
        XCTAssertTrue(stitcher.usesMotionRecognition)
        XCTAssertEqual(stitcher.outputRegion, CGRect(x: 80, y: 0, width: 190, height: 640))
        XCTAssertEqual(try stitcher.append(frame(offset: 251, header: 60, footer: 30, left: 80, right: 50, sidebarSeed: 11)), .appended(114))
        let expected = frame(offset: 0, height: 891, header: 60, footer: 30).cropping(to: CGRect(x: 80, y: 0, width: 190, height: 891))!
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(expected))
    }

    func testAnimationWithoutDocumentScrollCannotCreateContent() throws {
        let first = frame(offset: 0, header: 60, left: 80, right: 50)
        let stitcher = try VerticalStitcher(first: first)
        _ = try stitcher.append(frame(offset: 0, header: 60, left: 80, right: 50, sidebarSeed: 9))
        XCTAssertEqual(stitcher.frameCount, 1)
        XCTAssertFalse(stitcher.layoutLocked)
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(first))
    }

    func testMotionRecognitionHandlesReverseBeforeFirstAppend() throws {
        let stitcher = try VerticalStitcher(first: frame(offset: 200, left: 80, right: 50))
        XCTAssertEqual(try stitcher.append(frame(offset: 90, left: 80, right: 50, sidebarSeed: 7)), .backwards)
        XCTAssertFalse(stitcher.layoutLocked)
        XCTAssertEqual(try stitcher.append(frame(offset: 310, left: 80, right: 50, sidebarSeed: 9)), .appended(110))
    }

    private func twoPanes(leftOffset: Int, rightOffset: Int) -> CGImage {
        let context = CGContext(data: nil, width: 600, height: 640, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(frame(offset: leftOffset, width: 280, header: 42), in: CGRect(x: 0, y: 0, width: 280, height: 640))
        context.draw(frame(offset: 0, width: 80), in: CGRect(x: 280, y: 0, width: 40, height: 640))
        context.draw(frame(offset: rightOffset, width: 280, header: 42, seed: 3), in: CGRect(x: 320, y: 0, width: 280, height: 640))
        return context.makeImage()!
    }

    func testPointerChoosesBetweenIndependentlyMovingPanes() throws {
        let first = twoPanes(leftOffset: 0, rightOffset: 0)
        let next = twoPanes(leftOffset: 117, rightOffset: 169)
        let left = try VerticalStitcher(first: first), right = try VerticalStitcher(first: first)
        XCTAssertEqual(try left.append(next, focusPoint: CGPoint(x: 130, y: 300)), .appended(117))
        XCTAssertEqual(try right.append(next, focusPoint: CGPoint(x: 450, y: 300)), .appended(169))
        XCTAssertEqual(left.outputRegion, CGRect(x: 0, y: 0, width: 280, height: 640))
        XCTAssertEqual(right.outputRegion, CGRect(x: 320, y: 0, width: 280, height: 640))
        XCTAssertEqual(pixels(try left.compose()), pixels(frame(offset: 0, height: 757, width: 280, header: 42)))
        XCTAssertEqual(pixels(try right.compose()), pixels(frame(offset: 0, height: 809, width: 280, header: 42, seed: 3)))
    }

    func testEquallyStrongIndependentPanesAreNotGuessedWithoutPointer() throws {
        let first = twoPanes(leftOffset: 0, rightOffset: 0)
        let stitcher = try VerticalStitcher(first: first)
        XCTAssertEqual(try stitcher.append(twoPanes(leftOffset: 117, rightOffset: 169)), .noOverlap)
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(first))
    }

    private func gutterFrame(offset: Int, height: Int = 640, width: Int = 320, thumbY: Int? = nil,
                             dark: Bool = false, documentMarkY: Int? = nil, colored: Bool = false,
                             scale: Int = 1, header: Int = 0, footer: Int = 0) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(frame(offset: offset, height: height, width: width, header: header, footer: footer), in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: dark ? 0.12 : 0.97, alpha: 1))
        context.fill(CGRect(x: width - 40 * scale, y: 0, width: 40 * scale, height: height))
        for y in [thumbY, documentMarkY.map { $0 - offset }].compactMap({ $0 }) {
            context.setFillColor(colored ? CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1) : CGColor(gray: dark ? 0.55 : 0.66, alpha: 1))
            let rect = CGRect(x: width - 16 * scale, y: height - y - 80 * scale, width: 8 * scale, height: 80 * scale)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: CGFloat(4 * scale), cornerHeight: CGFloat(4 * scale), transform: nil)); context.fillPath()
        }
        return context.makeImage()!
    }

    func testScrollThumbsAreRemovedFromFirstFrameAndEveryNewStrip() throws {
        let region = CGRect(x: 0, y: 0, width: 320, height: 640)
        for dark in [false, true] {
            let sample = try ScrollBarSample(image: gutterFrame(offset: 0, thumbY: 460, dark: dark))
            XCTAssertNotNil(sample.mask)
            let stitcher = try VerticalStitcher(first: gutterFrame(offset: 0, thumbY: 460, dark: dark), contentRegion: region)
            let reference = try VerticalStitcher(first: gutterFrame(offset: 0, dark: dark), contentRegion: region)
            for (offset, delta, thumb) in [(160, 160, 470), (300, 140, 510), (490, 190, 548)] {
                XCTAssertEqual(try stitcher.append(gutterFrame(offset: offset, thumbY: thumb, dark: dark)), .appended(delta))
                _ = try reference.append(gutterFrame(offset: offset, dark: dark))
            }
            XCTAssertEqual(stitcher.width, 320)
            XCTAssertEqual(pixels(try stitcher.compose()), pixels(gutterFrame(offset: 0, height: 1130, dark: dark)))
            // Full-size preview exercises the same masks without resampling.
            XCTAssertEqual(pixels(try stitcher.preview(maximumHeight: 4096, maximumWidth: 640)), pixels(try stitcher.compose()))
            for size in [(260, 160), (37, 17), (4096, 119), (4096, 213)] {
                XCTAssertEqual(pixels(try stitcher.preview(maximumHeight: size.0, maximumWidth: size.1)),
                               pixels(try reference.preview(maximumHeight: size.0, maximumWidth: size.1)))
            }
        }
    }

    func testScrollbarCanAppearAfterCaptureStartsAndFadeOut() throws {
        let region = CGRect(x: 0, y: 0, width: 320, height: 640)
        let stitcher = try VerticalStitcher(first: gutterFrame(offset: 0), contentRegion: region)
        XCTAssertEqual(try stitcher.append(gutterFrame(offset: 60, thumbY: 520)), .appended(60))
        XCTAssertEqual(try stitcher.append(gutterFrame(offset: 120)), .appended(60))
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(gutterFrame(offset: 0, height: 760)))

        let fading = try VerticalStitcher(first: gutterFrame(offset: 0, thumbY: 200), contentRegion: region)
        XCTAssertEqual(try fading.append(gutterFrame(offset: 60)), .appended(60))
        XCTAssertEqual(pixels(try fading.compose()), pixels(gutterFrame(offset: 0, height: 700)))
    }

    func testDocumentMarksAtTheRightEdgeArePreserved() throws {
        let region = CGRect(x: 0, y: 0, width: 320, height: 640)
        for position in [260, 650] {
            let stitcher = try VerticalStitcher(first: gutterFrame(offset: 0, documentMarkY: position), contentRegion: region)
            XCTAssertEqual(try stitcher.append(gutterFrame(offset: 160, documentMarkY: position)), .appended(160))
            XCTAssertEqual(try stitcher.append(gutterFrame(offset: 300, documentMarkY: position)), .appended(140))
            XCTAssertEqual(pixels(try stitcher.compose()), pixels(gutterFrame(offset: 0, height: 940, documentMarkY: position)))
        }
    }

    func testConfirmedScrollbarDoesNotEraseLaterDocumentMarksInSameColumn() throws {
        let region = CGRect(x: 0, y: 0, width: 320, height: 640)
        let stitcher = try VerticalStitcher(first: gutterFrame(offset: 0, thumbY: 140), contentRegion: region)
        XCTAssertEqual(try stitcher.append(gutterFrame(offset: 60, thumbY: 160)), .appended(60))
        XCTAssertEqual(try stitcher.append(gutterFrame(offset: 120)), .appended(60))
        XCTAssertEqual(try stitcher.append(gutterFrame(offset: 280, documentMarkY: 780)), .appended(160))
        XCTAssertEqual(try stitcher.append(gutterFrame(offset: 400, documentMarkY: 780)), .appended(120))
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(gutterFrame(offset: 0, height: 1040, documentMarkY: 780)))
    }

    func testColoredEdgeContentAndUnconfirmedThumbArePreserved() throws {
        let region = CGRect(x: 0, y: 0, width: 320, height: 640)
        let first = gutterFrame(offset: 0, thumbY: 200)
        let stitcher = try VerticalStitcher(first: first, contentRegion: region)
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(first))
        XCTAssertEqual(try stitcher.append(gutterFrame(offset: -100, thumbY: 210)), .backwards)
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(first))
        XCTAssertEqual(try stitcher.append(gutterFrame(offset: 2000, thumbY: 210)), .noOverlap)
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(first))
        XCTAssertNil(try ScrollBarSample(image: gutterFrame(offset: 0, thumbY: 200, colored: true)).mask)
        XCTAssertNil(try ScrollBarSample(image: gutterFrame(offset: 0, thumbY: 200, documentMarkY: 430)).mask)
        XCTAssertNil(try ScrollBarSample(image: frame(offset: 0)).mask)
    }

    func testScrollbarCleanupWorksWithAutomaticLayoutAndRetinaPixels() throws {
        for scale in [1, 2] {
            let width = 441 * scale, height = 640 * scale, delta = 160 * scale
            let stitcher = try VerticalStitcher(first: gutterFrame(offset: 0, height: height, width: width, thumbY: 420 * scale, scale: scale))
            XCTAssertEqual(try stitcher.append(gutterFrame(offset: delta, height: height, width: width, thumbY: 470 * scale, scale: scale)), .appended(delta))
            let expected = gutterFrame(offset: 0, height: height + delta, width: width, scale: scale)
                .cropping(to: CGRect(x: Int(stitcher.outputRegion.minX), y: 0, width: stitcher.width, height: stitcher.totalHeight))!
            XCTAssertEqual(pixels(try stitcher.compose()), pixels(expected))
        }
    }

    func testScrollbarCleanupPreservesManualBoundsAndFixedChrome() throws {
        for budget: Int? in [nil, 0] {
            let region = CGRect(x: 40, y: 0, width: 280, height: 640)
            let stitcher = try VerticalStitcher(first: gutterFrame(offset: 0, thumbY: 440, header: 42, footer: 39), contentRegion: region, memoryBudget: budget)
            for (offset, thumb) in [(1, 440), (160, 470), (300, 500)] {
                _ = try stitcher.append(gutterFrame(offset: offset, thumbY: thumb, header: 42, footer: 39))
            }
            XCTAssertEqual(stitcher.outputRegion, region)
            let expected = gutterFrame(offset: 0, height: 940, header: 42, footer: 39)
                .cropping(to: CGRect(x: 40, y: 0, width: 280, height: 940))!
            XCTAssertEqual(pixels(try stitcher.compose()), pixels(expected))
        }
    }
}

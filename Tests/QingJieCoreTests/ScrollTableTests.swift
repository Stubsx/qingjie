import XCTest
import CoreGraphics
@testable import QingJieCore

final class ScrollTableTests: XCTestCase {
    /// Separated table columns share one scroll offset. The last column repeats its values.
    /// A stationary sidebar, when present, has its own vertically detailed content.
    private func table(offset: Int, height: Int = 640, sidebar: Int = 0, footer: Int = 0,
                       shadowTone: Int? = nil, edgeStatus: Int = 0) -> CGImage {
        let width = 1000, header = 40
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let documentY = y - header + offset
            for x in 0..<width {
                var level = 255
                if y < header {
                    level = y == header - 1 ? 190 : ((x / 15 + y / 6) % 3 == 0 ? 215 : 248)
                } else if y >= height - footer {
                    level = shadowTone.map { [217, 235, 250][y - height + footer] + $0 } ?? 190
                } else if x < sidebar {
                    level = (x / 7 + y / 5) % 4 == 0 ? 90 : 228
                } else if x >= 970 && edgeStatus > 0 {
                    level = (x / 5 + y / 7 + edgeStatus) % 3 == 0 ? 90 : 228
                } else {
                    level = (documentY / 40) % 2 == 0 ? 255 : 246
                    let column = x >= sidebar + 20 && x < 310 ? 0 : x >= 490 && x < 650 ? 1 : x >= 825 && x < 975 ? 2 : -1
                    if column >= 0 && documentY % 40 >= 10 && documentY % 40 < 26 {
                        let row = column == 2 ? 5 : documentY / 40
                        let pattern = (row * 37 + x / 5 * 17) % 29
                        if pattern < 17 && x % 5 < 3 { level = 35 + pattern * 4 }
                    }
                }
                let i = (y * width + x) * 4
                bytes[i] = UInt8(level); bytes[i + 1] = UInt8(level); bytes[i + 2] = UInt8(level)
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

    func testSeparatedColumnsAndRepeatingValuesKeepFullWidth() throws {
        let stitcher = try VerticalStitcher(first: table(offset: 0))
        XCTAssertEqual(try stitcher.append(table(offset: 118)), .appended(118))
        XCTAssertEqual(stitcher.width, 1000)
        XCTAssertEqual(try stitcher.append(table(offset: 271)), .appended(153))
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(table(offset: 0, height: 911)))
    }

    func testTableColumnsMergeWithoutIncludingStationarySidebar() throws {
        let stitcher = try VerticalStitcher(first: table(offset: 0, sidebar: 120))
        XCTAssertEqual(try stitcher.append(table(offset: 118, sidebar: 120)), .appended(118))
        XCTAssertEqual(stitcher.outputRegion, CGRect(x: 120, y: 0, width: 880, height: 640))
        let expected = table(offset: 0, height: 758, sidebar: 120).cropping(to: CGRect(x: 120, y: 0, width: 880, height: 758))!
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(expected))
    }

    func testThinFixedFooterStaysAtEndInsteadOfInsideSeams() throws {
        for thickness in [1, 2, 6] {
            let stitcher = try VerticalStitcher(first: table(offset: 0, footer: thickness))
            XCTAssertEqual(try stitcher.append(table(offset: 118, footer: thickness)), .appended(118))
            XCTAssertEqual(try stitcher.append(table(offset: 271, footer: thickness)), .appended(153))
            XCTAssertEqual(stitcher.scrollingRegion.maxY, CGFloat(640 - thickness))
            XCTAssertEqual(pixels(try stitcher.compose()), pixels(table(offset: 0, height: 911, footer: thickness)))
        }
    }

    func testSmallEdgeRefreshDoesNotCutOffTheLastTableColumn() throws {
        let stitcher = try VerticalStitcher(first: table(offset: 0, edgeStatus: 1))
        XCTAssertEqual(try stitcher.append(table(offset: 118, edgeStatus: 2)), .appended(118))
        XCTAssertEqual(stitcher.width, 1000)
    }

    func testThreePixelShadowWithSlightToneChangeAppearsOnlyAtBottom() throws {
        let stitcher = try VerticalStitcher(first: table(offset: 0, footer: 3, shadowTone: 0))
        XCTAssertEqual(try stitcher.append(table(offset: 118, footer: 3, shadowTone: 1)), .appended(118))
        XCTAssertEqual(try stitcher.append(table(offset: 271, footer: 3, shadowTone: 2)), .appended(153))
        XCTAssertEqual(stitcher.scrollingRegion.maxY, 637)
        XCTAssertEqual(pixels(try stitcher.compose()), pixels(table(offset: 0, height: 911, footer: 3, shadowTone: 2)))
    }
}

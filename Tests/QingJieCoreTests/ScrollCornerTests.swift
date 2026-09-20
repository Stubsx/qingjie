import XCTest
import CoreGraphics
import ImageIO
@testable import QingJieCore

final class ScrollCornerTests: XCTestCase {
    /// A window with real content at its edges and desktop showing through its corners.
    private func frame(offset: Int = 0, height: Int = 640, transparent: Bool = false) -> CGImage {
        let width = 320
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt64((y + offset) / 3 + 7129) &* 6364136223846793005 &+ UInt64(x / 5 + 1) &* 1442695040888963407
                let level = UInt8(20 + (value ^ (value >> 33)) % 220), i = (y * width + x) * 4
                bytes[i] = level; bytes[i + 1] = level; bytes[i + 2] = level
            }
        }
        let source = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                             provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if !transparent {
            context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1)); context.fill(rect)
        }
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 48, cornerHeight: 48, transform: nil)); context.clip()
        context.draw(source, in: rect)
        return context.makeImage()!
    }

    private func pixels(_ image: CGImage) -> Data {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: context.bytesPerRow * image.height)
    }

    func testViewportCornersOnlyRemainAtOuterEnds() throws {
        for budget: Int? in [nil, 0] {
            for transparent in [false, true] {
                let first = frame(transparent: transparent)
                let stitcher = try VerticalStitcher(first: first, memoryBudget: budget)
                var offset = 0
                // Thin increments followed by large scrolls exercise replacement across older strips.
                for shift in [137, 1, 3, 244, 117, 403, 1] {
                    offset += shift
                    XCTAssertEqual(try stitcher.append(frame(offset: offset, transparent: transparent)), .appended(shift))
                    let expected = frame(height: 640 + offset, transparent: transparent)
                    XCTAssertEqual(stitcher.width, 320)
                    XCTAssertEqual(stitcher.totalHeight, expected.height)
                    XCTAssertTrue(pixels(try stitcher.compose()) == pixels(expected), "Viewport corner repeated after offset \(offset)")
                }
                let file = try stitcher.exportPNG()
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(file.url as CFURL, nil))
                let exported = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertTrue(pixels(exported) == pixels(frame(height: 640 + offset, transparent: transparent)))
                let appearance = ScreenshotAppearance(roundedCorners: true, cornerRadius: 64)
                let styled = try stitcher.exportPNG(appearance: appearance)
                let styledSource = try XCTUnwrap(CGImageSourceCreateWithURL(styled.url as CFURL, nil))
                let styledImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(styledSource, 0, nil))
                let expected = try appearance.render(frame(height: 640 + offset, transparent: transparent))
                // PNG unpremultiplication can round RGB channels by one.
                let difference = zip(pixels(styledImage), pixels(expected)).map { abs(Int($0) - Int($1)) }
                XCTAssertLessThanOrEqual(difference.max() ?? 0, 1)
            }
        }
    }
}

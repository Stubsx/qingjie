import CoreGraphics
import XCTest
@testable import QingJieCore

final class ScreenshotAppearanceTests: XCTestCase {
    private func sample(width: Int = 240, height: Int = 160, hole: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0.25, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if hole { context.clear(CGRect(x: width / 2 - 10, y: height / 2 - 10, width: 20, height: 20)) }
        return context.makeImage()!
    }
    private func rgba(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self), i = (y * image.width + x) * 4
        return Array(UnsafeBufferPointer(start: data + i, count: 4))
    }
    func testDisabledAppearanceReturnsOriginalPixelsAndDimensions() throws {
        let source = sample()
        XCTAssertTrue(try ScreenshotAppearance().render(source) === source)
    }
    func testRoundedPNGHasTransparentCornersAndUnchangedInterior() throws {
        let source = sample(), result = try ScreenshotAppearance(roundedCorners: true).render(source)
        XCTAssertEqual(result.width, 240); XCTAssertEqual(result.height, 160)
        for (x,y) in [(0,0), (239,0), (0,159), (239,159)] { XCTAssertEqual(rgba(result,x,y)[3], 0) }
        XCTAssertEqual(rgba(result,120,80), rgba(source,120,80))
        XCTAssertEqual(rgba(result,120,0)[3], 255)
    }
    func testRadiusUsesScreenPointsOnRetinaDisplays() throws {
        let style = ScreenshotAppearance(roundedCorners: true), source = sample()
        let normal = try style.render(source), retina = try style.render(source, pixelsPerPoint: 2)
        XCTAssertEqual(rgba(normal,4,4)[3],255)
        XCTAssertEqual(rgba(retina,4,4)[3],0)
        XCTAssertEqual(rgba(retina,8,8)[3],255)
        XCTAssertEqual(retina.width,source.width)
    }
    func testShadowAddsTransparentPaddingAndFallsBelowImage() throws {
        let source = sample(), result = try ScreenshotAppearance(roundedCorners: true, shadow: true).render(source, pixelsPerPoint: 2)
        XCTAssertEqual(result.width,408); XCTAssertEqual(result.height,328)
        XCTAssertEqual(rgba(result,0,0)[3],0)
        XCTAssertEqual(rgba(result,204,164),rgba(source,120,80))
        let top = rgba(result,204,74)[3], bottom = rgba(result,204,254)[3]
        XCTAssertGreaterThan(bottom,0); XCTAssertGreaterThan(bottom,top)
        XCTAssertLessThan(bottom,128)
    }
    func testShadowCanBeUsedWithSquareCornersAndPreservesSourceAlpha() throws {
        let source = sample(hole: true), result = try ScreenshotAppearance(shadow: true).render(source)
        XCTAssertEqual(rgba(result,42,42)[3],255)
        XCTAssertEqual(rgba(result,162,122)[3],0)
    }
    func testTinySelectionAndInvalidScalesAreHandled() throws {
        let source = sample(width: 8,height: 6), style = ScreenshotAppearance(roundedCorners: true)
        let result = try style.render(source,pixelsPerPoint: 2)
        XCTAssertEqual(result.width,8); XCTAssertEqual(result.height,6)
        for scale: CGFloat in [0,-1,.infinity,.nan,1000] { XCTAssertThrowsError(try style.render(source,pixelsPerPoint: scale)) }
    }
    func testCustomRadiusChangesOnlyTheCornersAndZeroIsSquare() throws {
        let source = sample()
        let small = try ScreenshotAppearance(roundedCorners: true, cornerRadius: 16).render(source)
        let large = try ScreenshotAppearance(roundedCorners: true, cornerRadius: 48).render(source)
        let square = try ScreenshotAppearance(roundedCorners: true, cornerRadius: 0).render(source)
        XCTAssertEqual(rgba(small,10,10)[3],255)
        XCTAssertEqual(rgba(large,10,10)[3],0)
        XCTAssertEqual(rgba(square,0,0),rgba(source,0,0))
        XCTAssertEqual(rgba(large,120,80),rgba(source,120,80))
        let retina = try ScreenshotAppearance(roundedCorners: true, cornerRadius: 24).render(source,pixelsPerPoint: 2)
        XCTAssertEqual(rgba(retina,10,10),rgba(large,10,10))
    }
    func testCustomShadowSizeExpandsItsReachAndRetinaPadding() throws {
        let source = sample()
        let small = try ScreenshotAppearance(shadow: true, shadowBlur: 6).render(source)
        let large = try ScreenshotAppearance(shadow: true, shadowBlur: 24).render(source)
        XCTAssertEqual(small.width,288); XCTAssertEqual(large.width,396)
        XCTAssertGreaterThan(rgba(large,198,258)[3],rgba(small,144,204)[3])
        let retina = try ScreenshotAppearance(shadow: true, shadowBlur: 24, shadowOffset: 10).render(source,pixelsPerPoint: 2)
        XCTAssertEqual(retina.width,568); XCTAssertEqual(retina.height,488)
        XCTAssertEqual(rgba(retina,284,244),rgba(source,120,80))
    }
    func testOpacityChangesShadowWeightAndZeroRemovesPadding() throws {
        let source = sample()
        let light = try ScreenshotAppearance(shadow: true, shadowOpacity: 0.15).render(source)
        let heavy = try ScreenshotAppearance(shadow: true, shadowOpacity: 0.75).render(source)
        XCTAssertEqual(light.width,heavy.width)
        XCTAssertGreaterThan(rgba(heavy,162,210)[3],rgba(light,162,210)[3])
        XCTAssertEqual(rgba(heavy,162,122),rgba(light,162,122))
        XCTAssertTrue(try ScreenshotAppearance(shadow: true, shadowOpacity: 0).render(source) === source)
        let rounded = try ScreenshotAppearance(roundedCorners: true, shadow: true, shadowOpacity: 0).render(source)
        XCTAssertEqual(rounded.width,source.width); XCTAssertEqual(rgba(rounded,0,0)[3],0)
    }
    func testCustomOffsetMovesShadowDownAndSupportsAHardShadow() throws {
        let source = sample()
        let centered = try ScreenshotAppearance(shadow: true, shadowOffset: 0).render(source)
        let shifted = try ScreenshotAppearance(shadow: true, shadowOffset: 20).render(source)
        XCTAssertGreaterThan(rgba(shifted,176,224)[3],rgba(centered,156,204)[3])
        XCTAssertLessThan(rgba(shifted,176,48)[3],rgba(centered,156,28)[3])
        let hard = try ScreenshotAppearance(shadow: true, shadowBlur: 0, shadowOffset: 8, shadowOpacity: 0.5).render(source)
        XCTAssertEqual(hard.width,256)
        XCTAssertGreaterThan(rgba(hard,128,172)[3],100)
        XCTAssertEqual(rgba(hard,128,3)[3],0)
    }
    func testInvalidParametersAreBoundedBeforeRendering() throws {
        let invalid = ScreenshotAppearance(roundedCorners: true, shadow: true,
                                           cornerRadius: .nan, shadowBlur: .infinity, shadowOffset: -.infinity, shadowOpacity: .nan)
        XCTAssertEqual(invalid, ScreenshotAppearance(roundedCorners: true, shadow: true))
        let bounded = ScreenshotAppearance(roundedCorners: true, shadow: true,
                                           cornerRadius: 1000, shadowBlur: -2, shadowOffset: 1000, shadowOpacity: 4)
        XCTAssertEqual(bounded.cornerRadius,64); XCTAssertEqual(bounded.shadowBlur,0)
        XCTAssertEqual(bounded.shadowOffset,32); XCTAssertEqual(bounded.shadowOpacity,1)
        XCTAssertNoThrow(try invalid.render(sample(width: 4,height: 6),pixelsPerPoint: 2))
        XCTAssertNoThrow(try bounded.render(sample(width: 4,height: 6),pixelsPerPoint: 2))
    }
}

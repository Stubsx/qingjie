import XCTest
import CoreGraphics
@testable import QingJieCore

final class PDFExportTests: XCTestCase {
    private func image(width: Int = 512, height: Int = 2400, gap: Range<Int>? = nil) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for y in stride(from: 0, to: height, by: 2) {
            if gap?.contains(y) == true { continue }
            let color = CGColor(red: CGFloat((y / 100) % 3) / 3, green: 0.3, blue: 0.5, alpha: 1)
            context.setFillColor(color)
            for x in stride(from: 20, to: width - 20, by: 17) {
                context.fill(CGRect(x: x, y: height - y - 2, width: 8, height: 2))
            }
        }
        return context.makeImage()!
    }
    private func ranges(_ image: CGImage) throws -> [Range<Int>] {
        try ScreenshotPDF.pageRanges(width: image.width, height: image.height) { context, rows in
            context.draw(image, in: CGRect(x: 0, y: rows.upperBound - image.height, width: image.width, height: image.height))
        }
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func testPaginationFindsWhitespaceWithoutDroppingOrRepeatingRows() throws {
        let capacity = Int(floor(512 * ScreenshotPDF.contentRect.height / ScreenshotPDF.contentRect.width))
        let gap = (capacity - 42)..<(capacity - 24)
        let pages = try ranges(image(gap: gap))
        XCTAssertTrue(gap.contains(pages[0].upperBound))
        XCTAssertEqual(pages.first?.lowerBound, 0); XCTAssertEqual(pages.last?.upperBound, 2400)
        XCTAssertEqual(pages.reduce(0) { $0 + $1.count }, 2400)
        for index in 1..<pages.count { XCTAssertEqual(pages[index - 1].upperBound, pages[index].lowerBound) }
        XCTAssertTrue(pages.allSatisfy { !$0.isEmpty && $0.count <= capacity })
    }
    func testDenseImageFallsBackToFullPagesAndKeepsShortTail() throws {
        let capacity = Int(floor(512 * ScreenshotPDF.contentRect.height / ScreenshotPDF.contentRect.width))
        let pages = try ranges(image(height: capacity * 2 + 13))
        XCTAssertEqual(pages, [0..<capacity, capacity..<(capacity * 2), (capacity * 2)..<(capacity * 2 + 13)])
        XCTAssertEqual(try ranges(image(width: 1, height: 3)).reduce(0) { $0 + $1.count }, 3)
    }
    func testNativePDFPagesHaveCorrectDimensionsAndThumbnail() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("test.pdf"), source = image()
        let count = try ScreenshotPDF.write(source, to: url)
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertEqual(document.numberOfPages, count); XCTAssertGreaterThan(count, 1)
        for index in 1...count {
            let box = try XCTUnwrap(document.page(at: index)).getBoxRect(.mediaBox)
            XCTAssertEqual(box.width, ScreenshotPDF.pageSize.width, accuracy: 0.01)
            XCTAssertEqual(box.height, ScreenshotPDF.pageSize.height, accuracy: 0.01)
        }
        let thumbnail = try ScreenshotPDF.thumbnail(at: url)
        XCTAssertEqual(thumbnail.pages, count)
        XCTAssertLessThanOrEqual(thumbnail.image.height, 560)
        XCTAssertGreaterThan(thumbnail.image.width, 300)
    }
    func testCancellationDuringWritingPreservesDestinationAndCleansPartialFile() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("existing.pdf"), original = Data([1, 2, 3])
        try original.write(to: url)
        var checks = 0
        XCTAssertThrowsError(try ScreenshotPDF.write(image(height: 3000), to: url) {
            checks += 1; if checks == 10 { throw CancellationError() }
        })
        XCTAssertEqual(checks, 10)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).map(\.lastPathComponent), [url.lastPathComponent])
    }
    func testDiskBackedSourceExportsPDFWithoutComposingWholeImage() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = image(width: 800, height: 2400)
        let stitcher = try VerticalStitcher(first: source, contentRegion: CGRect(x: 0, y: 0, width: 800, height: 2400), memoryBudget: 0)
        let count = try stitcher.exportPDF(to: root.appendingPathComponent("disk.pdf"))
        XCTAssertTrue(stitcher.usesDiskCache); XCTAssertEqual(stitcher.residentImageBytes, 0)
        XCTAssertEqual(count, try ranges(source).count)
    }
    func testVeryLongPDFUsesSmallBandsAndKeepsEveryPage() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("long.pdf"), width = 1200, height = 100_000
        var maximumRows = 0
        let count = try ScreenshotPDF.write(to: url, width: width, height: height) { context, rows in
            maximumRows = max(maximumRows, rows.count)
            for y in stride(from: rows.lowerBound / 40 * 40, to: rows.upperBound, by: 40) {
                context.setFillColor(CGColor(red: CGFloat((y / 40) % 7) / 8, green: 0.4, blue: 0.6, alpha: 1))
                for x in stride(from: 24, to: width - 24, by: 23) {
                    context.fill(CGRect(x: x, y: rows.upperBound - y - 16, width: 12, height: 16))
                }
            }
        }
        XCTAssertLessThanOrEqual(maximumRows, 600)
        XCTAssertGreaterThan(count, 50)
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertEqual(document.numberOfPages, count)
        XCTAssertEqual(try ScreenshotPDF.thumbnail(at: url).pages, count)
    }
}

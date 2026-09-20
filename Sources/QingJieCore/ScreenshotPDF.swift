import CoreGraphics
import CoreText
import Foundation
import Darwin

/// Image-based, paginated PDF using only the system graphics framework.
public enum ScreenshotPDF {
    static let pageSize = CGSize(width: 595.2756, height: 841.8898)
    static let contentRect = CGRect(x: 24, y: 42, width: pageSize.width - 48, height: pageSize.height - 66)

    public static func thumbnail(at url: URL, maximumDimension: Int = 560) throws -> (image: CGImage, pages: Int) {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else { throw PDFError.invalidImage }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { throw PDFError.invalidImage }
        let scale = CGFloat(max(1, min(2048, maximumDimension))) / max(box.width, box.height)
        let width = max(1, Int(ceil(box.width * scale))), height = max(1, Int(ceil(box.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PDFError.invalidImage
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw PDFError.invalidImage }
        return (image, document.numberOfPages)
    }

    @discardableResult public static func write(_ image: CGImage, to url: URL,
                                                checkCancellation: () throws -> Void = {}) throws -> Int {
        try write(to: url, width: image.width, height: image.height, checkCancellation: checkCancellation) { context, rows in
            context.draw(image, in: CGRect(x: 0, y: rows.upperBound - image.height, width: image.width, height: image.height))
        }
    }

    /// `draw` receives source-pixel coordinates, with the requested rows filling the context.
    @discardableResult static func write(to url: URL, width: Int, height: Int,
                                        checkCancellation: () throws -> Void = {},
                                        draw: (CGContext, Range<Int>) throws -> Void) throws -> Int {
        guard width > 0, height > 0, width <= Int(Int32.max) / 4, height <= Int(Int32.max) else { throw PDFError.invalidImage }
        let pages = try pageRanges(width: width, height: height, checkCancellation: checkCancellation, draw: draw)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".qingjie-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sink = try PDFSink(url: temporary)
        var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
            guard let info else { return 0 }
            return Unmanaged<PDFSink>.fromOpaque(info).takeUnretainedValue().write(bytes, count: count)
        }, releaseConsumer: nil)
        guard let consumer = CGDataConsumer(info: Unmanaged.passUnretained(sink).toOpaque(), cbks: &callbacks) else { throw PDFError.writeFailed }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox,
                                  [kCGPDFContextCreator: "轻截"] as CFDictionary) else { throw PDFError.writeFailed }
        var closed = false
        defer { if !closed { pdf.closePDF() }; withExtendedLifetime(sink) {} }
        let scale = contentRect.width / CGFloat(width)
        let bandRows = max(1, min(512, 8 * 1024 * 1024 / (width * 4)))
        for (index, rows) in pages.enumerated() {
            try checkCancellation()
            pdf.beginPDFPage(nil)
            pdf.setFillColor(CGColor(gray: 1, alpha: 1)); pdf.fill(mediaBox)
            for top in stride(from: rows.lowerBound, to: rows.upperBound, by: bandRows) {
                try checkCancellation()
                try autoreleasepool {
                    let band = top..<min(top + bandRows, rows.upperBound)
                    let bitmap = try render(width: width, rows: band, sampleWidth: width, draw: draw)
                    guard let image = bitmap.makeImage() else { throw PDFError.invalidImage }
                    let rect = CGRect(x: contentRect.minX,
                                      y: contentRect.maxY - CGFloat(band.upperBound - rows.lowerBound) * scale,
                                      width: contentRect.width, height: CGFloat(band.count) * scale)
                    pdf.saveGState(); pdf.setShouldAntialias(false); pdf.interpolationQuality = .none
                    pdf.draw(image, in: rect); pdf.restoreGState()
                }
                if sink.failed { throw PDFError.writeFailed }
            }
            drawPageNumber(index + 1, total: pages.count, in: pdf)
            pdf.endPDFPage()
        }
        pdf.closePDF(); closed = true
        try sink.finish()
        try checkCancellation()
        guard let document = CGPDFDocument(temporary as CFURL), document.numberOfPages == pages.count else { throw PDFError.writeFailed }
        guard rename(temporary.path, url.path) == 0 else { throw PDFError.writeFailed }
        return pages.count
    }

    static func pageRanges(width: Int, height: Int, checkCancellation: () throws -> Void = {},
                           draw: (CGContext, Range<Int>) throws -> Void) throws -> [Range<Int>] {
        guard width > 0, height > 0 else { throw PDFError.invalidImage }
        let capacity = max(1, Int(floor(CGFloat(width) * contentRect.height / contentRect.width)))
        var result: [Range<Int>] = [], start = 0
        while start < height {
            try checkCancellation()
            var end = min(height, start + capacity)
            if end < height {
                let lookback = max(4, min(600, capacity / 7))
                let search = max(start + capacity / 2, end - lookback)..<end
                if search.count >= 4 {
                    end = try autoreleasepool {
                        let sample = try render(width: width, rows: search, sampleWidth: min(384, width), draw: draw)
                        return search.lowerBound + whitespaceCut(in: sample, sourceWidth: width)
                    }
                }
            }
            guard end > start else { throw PDFError.invalidImage }
            result.append(start..<end); start = end
        }
        return result
    }

    // Search backward for a quiet run of rows; borders can remain, text strokes cannot.
    private static func whitespaceCut(in image: CGContext, sourceWidth: Int) -> Int {
        guard image.width >= 4 else { return image.height }
        guard let bytes = image.data?.assumingMemoryBound(to: UInt8.self) else { return image.height }
        let minimumGap = max(2, min(6, sourceWidth / 350))
        var runEnd = image.height, runLength = 0
        var bestCut = image.height, bestScore = -Double.infinity
        func considerRun() {
            guard runLength >= minimumGap else { return }
            let cut = runEnd == image.height ? image.height : runEnd - runLength / 2
            // Wider paragraph/card gaps can beat a nearby gap between two text lines.
            let score = Double(min(runLength, minimumGap * 16)) - Double(image.height - cut) * 0.12
            if score > bestScore { bestScore = score; bestCut = cut }
        }
        for y in stride(from: image.height - 1, through: 0, by: -1) {
            let sampleColumns = [0, image.width / 4, image.width / 2, image.width * 3 / 4, image.width - 1]
            let background = (0..<3).map { channel in
                sampleColumns.map { Int(bytes[y * image.bytesPerRow + $0 * 4 + channel]) }.sorted()[2]
            }
            var foreground = 0
            for x in 0..<image.width {
                let i = y * image.bytesPerRow + x * 4
                let difference = (0..<3).map { abs(Int(bytes[i + $0]) - background[$0]) }.max() ?? 0
                if difference > 18 { foreground += 1 }
            }
            if foreground <= max(2, image.width / 100) {
                if runLength == 0 { runEnd = y + 1 }
                runLength += 1
            } else {
                considerRun(); runLength = 0
            }
        }
        considerRun()
        return bestCut
    }

    private static func render(width: Int, rows: Range<Int>, sampleWidth: Int,
                               draw: (CGContext, Range<Int>) throws -> Void) throws -> CGContext {
        guard let context = CGContext(data: nil, width: sampleWidth, height: rows.count, bitsPerComponent: 8,
                                      bytesPerRow: sampleWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw PDFError.invalidImage
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: sampleWidth, height: rows.count))
        context.scaleBy(x: CGFloat(sampleWidth) / CGFloat(width), y: 1)
        context.interpolationQuality = .high; context.setShouldAntialias(false)
        try draw(context, rows)
        return context
    }

    private static func drawPageNumber(_ number: Int, total: Int, in context: CGContext) {
        let text = NSAttributedString(string: "\(number) / \(total)", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 9, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.5, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(text)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: (pageSize.width - width) / 2, y: 20)
        CTLineDraw(line, context)
    }

    public enum PDFError: LocalizedError {
        case invalidImage, writeFailed
        public var errorDescription: String? {
            switch self {
            case .invalidImage: return "无法生成 PDF，请重试。"
            case .writeFailed: return "PDF 未能保存，请检查剩余空间或选择其他位置。"
            }
        }
    }

    private final class PDFSink {
        private let handle: FileHandle
        private(set) var failed = false
        init(url: URL) throws {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw PDFError.writeFailed }
            handle = try FileHandle(forWritingTo: url)
        }
        deinit { try? handle.close() }
        func write(_ bytes: UnsafeRawPointer, count: Int) -> Int {
            guard !failed else { return 0 }
            do {
                try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes), count: count, deallocator: .none))
                return count
            } catch { failed = true; return 0 }
        }
        func finish() throws {
            guard !failed else { throw PDFError.writeFailed }
            try handle.synchronize(); try handle.close()
        }
    }
}

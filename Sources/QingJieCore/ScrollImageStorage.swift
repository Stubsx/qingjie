import CoreGraphics
import Foundation
import ImageIO
import Darwin

/// Private, per-capture files. The lock also lets a later launch reclaim crash leftovers.
public final class ScrollTemporaryDirectory {
    public let url: URL
    private var lockFD: Int32 = -1

    public init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("QingJie-Scroll", isDirectory: true)) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for old in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard UUID(uuidString: old.lastPathComponent) != nil else { continue }
            let fd = open(old.appendingPathComponent(".lock").path, O_RDWR | O_NOFOLLOW)
            if fd >= 0 {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { try? fm.removeItem(at: old) }
                Darwin.close(fd)
            }
        }
        url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        lockFD = open(url.appendingPathComponent(".lock").path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }
            try? fm.removeItem(at: url); throw StitchError.storageUnavailable
        }
    }
    deinit {
        try? FileManager.default.removeItem(at: url)
        if lockFD >= 0 { Darwin.close(lockFD) }
    }
    func checkSpace(for bytes: Int) throws {
        var stats = statvfs()
        guard statvfs(url.path, &stats) == 0 else { throw StitchError.storageUnavailable }
        let available = UInt64(stats.f_bavail) * UInt64(stats.f_frsize)
        guard available > UInt64(max(0, bytes)) + 128 * 1024 * 1024 else { throw StitchError.storageFull }
    }
}

public final class ScrollPNGFile {
    public let url: URL
    private let directory: ScrollTemporaryDirectory
    init(directory: ScrollTemporaryDirectory, url: URL) { self.directory = directory; self.url = url }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Only the pressure flag crosses queues; raster storage itself stays on the capture worker.
private final class ScrollMemoryPressure: @unchecked Sendable {
    static let shared = ScrollMemoryPressure()
    private let lock = NSLock()
    private var pressured = false
    private let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
    var isHigh: Bool { lock.lock(); defer { lock.unlock() }; return pressured }
    private init() {
        source.setEventHandler { [weak self] in
            guard let self else { return }
            lock.lock(); pressured = !source.data.contains(.normal); lock.unlock()
        }
        source.resume()
    }
}

final class ScrollImageStorage {
    static var automaticMemoryBudget: Int {
        // Leave room for the current screen frame, compositing and the rest of the app.
        Int(min(128 * 1024 * 1024, max(32 * 1024 * 1024, ProcessInfo.processInfo.physicalMemory / 128)))
    }
    let memoryBudget: Int
    private(set) var hasSpilled = false
    private var directory: ScrollTemporaryDirectory?
    private let temporaryRoot: URL?
    private struct WeakRaster { weak var value: Raster? }
    private var entries: [WeakRaster] = []
    var residentBytes: Int { entries.reduce(0) { $0 + ($1.value?.residentBytes ?? 0) } }
    var shouldStream: Bool { hasSpilled || ScrollMemoryPressure.shared.isHigh }

    init(memoryBudget: Int? = nil, temporaryRoot: URL? = nil) {
        self.memoryBudget = max(0, memoryBudget ?? Self.automaticMemoryBudget)
        self.temporaryRoot = temporaryRoot
    }
    func workspace() throws -> ScrollTemporaryDirectory {
        if let directory { return directory }
        let result = try temporaryRoot.map { try ScrollTemporaryDirectory(root: $0) } ?? ScrollTemporaryDirectory()
        directory = result; return result
    }
    func keep(_ image: CGImage) -> Raster {
        let raster = Raster(image, cachesPreview: memoryBudget > 0)
        entries.append(WeakRaster(value: raster)); return raster
    }
    func trim() throws {
        entries.removeAll { $0.value == nil }
        var bytes = residentBytes
        let target = ScrollMemoryPressure.shared.isHigh ? min(memoryBudget, 8 * 1024 * 1024) : memoryBudget
        guard bytes > target else { return }
        let directory = try workspace()
        for entry in entries {
            guard bytes > target else { break }
            guard let raster = entry.value, raster.residentBytes > 0 else { continue }
            let size = raster.residentBytes
            try autoreleasepool { try raster.spill(to: directory) }
            bytes -= size; hasSpilled = true
        }
    }

    final class Raster {
        let width: Int
        let height: Int
        private var image: CGImage?
        private var thumbnail: CGImage?
        private var thumbnailWidth = 0
        private let cachesPreview: Bool
        private var file: URL?
        // A checkpoint may outlive its originating store.
        private var directory: ScrollTemporaryDirectory?
        var residentBytes: Int {
            (image.map { $0.bytesPerRow * $0.height } ?? 0) + (thumbnail.map { $0.bytesPerRow * $0.height } ?? 0)
        }
        init(_ image: CGImage, cachesPreview: Bool) {
            self.image = image; self.cachesPreview = cachesPreview; width = image.width; height = image.height
        }
        deinit { if let file { try? FileManager.default.removeItem(at: file) } }
        func load(previewWidth: Int? = nil) throws -> CGImage {
            if let image { return image }
            if let previewWidth, let thumbnail, thumbnailWidth >= previewWidth, thumbnailWidth <= previewWidth * 2 {
                return thumbnail
            }
            guard let file, let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw StitchError.storageUnavailable
            }
            let result: CGImage?
            if let previewWidth, width > previewWidth {
                result = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, Int(ceil(Double(max(width, height)) * Double(previewWidth) / Double(width)))),
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            } else {
                result = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }
            guard let result else { throw StitchError.storageUnavailable }
            if let previewWidth, cachesPreview { thumbnail = result; thumbnailWidth = previewWidth }
            return result
        }
        func spill(to directory: ScrollTemporaryDirectory) throws {
            guard let image else { thumbnail = nil; return }
            try directory.checkSpace(for: residentBytes * 2)
            let url = directory.url.appendingPathComponent(UUID().uuidString + ".png")
            var succeeded = false
            defer { if !succeeded { try? FileManager.default.removeItem(at: url) } }
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                throw StitchError.storageUnavailable
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw StitchError.storageUnavailable }
            file = url; self.directory = directory; self.image = nil; thumbnail = nil; succeeded = true
        }
    }
}

import Foundation
import CoreGraphics

public enum RecordingResolution: String, Codable, CaseIterable, Sendable {
    case native, hd, fullHD, qhd, uhd
    public var title: String {
        switch self {
        case .native: return "原始尺寸"
        case .hd: return "720p"
        case .fullHD: return "1080p"
        case .qhd: return "1440p"
        case .uhd: return "4K"
        }
    }
    /// Fit without stretching or upscaling; H.264 needs even dimensions.
    /// Portrait recordings use the same preset with its axes swapped.
    public func outputSize(for source: CGSize) -> CGSize {
        guard source.width.isFinite, source.height.isFinite, source.width >= 2, source.height >= 2 else { return .zero }
        let limit: CGSize
        switch self {
        case .native: limit = CGSize(width: 4096, height: 4096)
        case .hd: limit = CGSize(width: 1280, height: 720)
        case .fullHD: limit = CGSize(width: 1920, height: 1080)
        case .qhd: limit = CGSize(width: 2560, height: 1440)
        case .uhd: limit = CGSize(width: 3840, height: 2160)
        }
        let portrait = source.height > source.width
        let maximum = portrait ? CGSize(width: limit.height, height: limit.width) : limit
        let scale = min(1, maximum.width / source.width, maximum.height / source.height)
        return CGSize(width: max(2, floor(source.width * scale / 2) * 2),
                      height: max(2, floor(source.height * scale / 2) * 2))
    }
}

public struct RecordingOptions: Codable, Equatable, Sendable {
    public static let frameRates = [15, 24, 30, 60]
    public var resolution: RecordingResolution = .fullHD
    public var frameRate = 30
    public var systemAudio = false
    public var microphone = false
    public var showsCursor = true
    public var mouseClicks = true
    public init() {}
    public var validated: Self {
        var value = self
        if !Self.frameRates.contains(value.frameRate) { value.frameRate = 30 }
        return value
    }
}

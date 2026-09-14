import Foundation

public struct UpdateInfo: Codable, Equatable, Sendable {
    public struct Package: Codable, Equatable, Sendable {
        public let url: String
        public let sha256: String
        public let bytes: Int?
        public init(url: String, sha256: String, bytes: Int? = nil) {
            self.url = url; self.sha256 = sha256; self.bytes = bytes
        }
    }
    public let version: String
    public let build: Int
    public let notes: String?
    public let url: String?
    public let package: Package?
    public init(version: String, build: Int, notes: String? = nil, url: String? = nil, package: Package? = nil) {
        self.version = version; self.build = build; self.notes = notes; self.url = url; self.package = package
    }
}

public enum VersionComparison {
    /// 逐段比对数字版本号；段数不同按 0 补齐，全部相同再比对 build 号。
    public static func isNewer(_ version: String, build: Int, than installedVersion: String, installedBuild: Int) -> Bool {
        let candidate = version.split(separator: ".").compactMap { Int($0) }
        let current = installedVersion.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(candidate.count, current.count) {
            let a = index < candidate.count ? candidate[index] : 0
            let b = index < current.count ? current[index] : 0
            if a != b { return a > b }
        }
        return build > installedBuild
    }
}

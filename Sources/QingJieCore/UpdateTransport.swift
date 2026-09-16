import CryptoKit
import Foundation

public struct UpdateTransportError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

public enum UpdateTransport {
    public static func feedRequest(_ endpoint: URL) -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        // raw gist/CDN 和运行中的客户端都可能保留旧版本；每次读取使用独立请求。
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "check", value: UUID().uuidString)]
        return freshRequest(components.url!)
    }

    private static func freshRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    public static func fetchInfo(from endpoint: URL, using session: URLSession) async throws -> UpdateInfo {
        let (data, response) = try await session.data(for: feedRequest(endpoint))
        try validateResponse(response)
        return try JSONDecoder().decode(UpdateInfo.self, from: data)
    }

    static func validateResponse(_ response: URLResponse?) throws {
        guard let response = response as? HTTPURLResponse else {
            throw UpdateTransportError(message: "服务器没有返回有效的 HTTP 响应。")
        }
        guard response.statusCode == 200 else {
            throw UpdateTransportError(message: "服务器返回 HTTP \(response.statusCode)，请稍后重试。")
        }
    }

    public static func download(_ package: UpdateInfo.Package, to destination: URL,
                                progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let url = URL(string: package.url), url.scheme == "https", url.host != nil else {
            throw UpdateTransportError(message: "该版本没有有效的 HTTPS 安装包地址。")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForResource = 600
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = UpdateDownloadDelegate(destination: destination, expectedBytes: package.bytes,
                                                  progress: progress) { result in
                continuation.resume(with: result)
            }
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: freshRequest(url)).resume()
        }
    }

    public static func verifyArchive(_ archive: URL, package: UpdateInfo.Package) throws {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        if let expected = package.bytes, data.count != expected {
            throw UpdateTransportError(message: "安装包大小与更新信息不符（预期 \(expected) 字节，收到 \(data.count) 字节），请重新检查更新后重试。")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(package.sha256) == .orderedSame else {
            throw UpdateTransportError(message: "安装包与更新信息的 SHA-256 不符，可能是发布包已变更或下载损坏；请重新检查更新后重试。")
        }
    }
}

// URLSession 在同一串行 delegateQueue 中调用这些方法；只从 didCompleteWithError 完成 continuation。
final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedBytes: Int?
    private let progress: @Sendable (Double) -> Void
    private let completion: (Result<Void, Error>) -> Void
    private var result: Result<Void, Error>?
    private var completed = false

    init(destination: URL, expectedBytes: Int?, progress: @escaping @Sendable (Double) -> Void,
         completion: @escaping (Result<Void, Error>) -> Void) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.progress = progress
        self.completion = completion
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Int64(expectedBytes ?? 0)
        guard total > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        result = Result {
            // HTTP 错误页也会进入此回调，必须在保存文件前检查状态。
            try UpdateTransport.validateResponse(downloadTask.response)
            if downloadTask.response?.mimeType?.lowercased() == "text/html" {
                throw UpdateTransportError(message: "下载地址返回了网页，未返回安装包，请稍后重试。")
            }
            try FileManager.default.moveItem(at: location, to: destination)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !completed else { return }
        completed = true
        defer { session.finishTasksAndInvalidate() }
        if let error {
            completion(.failure(error))
        } else {
            completion(result ?? .failure(UpdateTransportError(message: "下载未生成安装包，请重试。")))
        }
    }
}

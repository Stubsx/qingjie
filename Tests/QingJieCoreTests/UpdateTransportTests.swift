import XCTest
@testable import QingJieCore

final class UpdateTransportTests: XCTestCase {
    private let endpoint = URL(string: "https://example.com/latest.json")!
    private let abcSHA = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func testRefreshReadsChangedPackageForSameVersion() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); FeedProtocol.requests = [] }
        let first = try await UpdateTransport.fetchInfo(from: endpoint, using: session)
        let refreshed = try await UpdateTransport.fetchInfo(from: endpoint, using: session)
        XCTAssertEqual(first.version, refreshed.version)
        XCTAssertEqual(first.build, refreshed.build)
        XCTAssertNotEqual(first.package?.sha256, refreshed.package?.sha256)
        XCTAssertNotEqual(FeedProtocol.requests[0].url, FeedProtocol.requests[1].url)
        XCTAssertEqual(FeedProtocol.requests[1].value(forHTTPHeaderField: "Cache-Control"), "no-cache")
    }

    func testHTTPFailuresAreRejectedBeforeSaving() throws {
        for status in [403, 404, 500] {
            try withDirectory { directory in
                let source = directory.appendingPathComponent("error.html")
                let destination = directory.appendingPathComponent("package.zip")
                try Data("Not Found".utf8).write(to: source)
                var results: [Result<Void, Error>] = []
                let delegate = UpdateDownloadDelegate(destination: destination, expectedBytes: nil, progress: { _ in }) { results.append($0) }
                let session = URLSession(configuration: .ephemeral)
                let task = ResponseTask(url: endpoint, status: status)
                delegate.urlSession(session, downloadTask: task, didFinishDownloadingTo: source)
                delegate.urlSession(session, task: task, didCompleteWithError: nil)
                XCTAssertEqual(results.count, 1)
                XCTAssertThrowsError(try results[0].get()) { XCTAssertTrue($0.localizedDescription.contains("HTTP \(status)")) }
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            }
        }
    }

    func testHTMLSuccessResponseIsRejected() throws {
        try withDirectory { directory in
            let source = directory.appendingPathComponent("error.html")
            try Data("<html>login</html>".utf8).write(to: source)
            var result: Result<Void, Error>?
            let delegate = UpdateDownloadDelegate(destination: directory.appendingPathComponent("package.zip"), expectedBytes: nil, progress: { _ in }) { result = $0 }
            let session = URLSession(configuration: .ephemeral)
            let task = ResponseTask(url: endpoint, status: 200, type: "text/html")
            delegate.urlSession(session, downloadTask: task, didFinishDownloadingTo: source)
            delegate.urlSession(session, task: task, didCompleteWithError: nil)
            XCTAssertThrowsError(try XCTUnwrap(result).get()) { XCTAssertTrue($0.localizedDescription.contains("网页")) }
        }
    }

    func testSuccessfulDownloadIsSavedAndCompletesOnce() throws {
        try withDirectory { directory in
            let source = directory.appendingPathComponent("download")
            let destination = directory.appendingPathComponent("package.zip")
            try Data("abc".utf8).write(to: source)
            var results: [Result<Void, Error>] = []
            let delegate = UpdateDownloadDelegate(destination: destination, expectedBytes: 3, progress: { _ in }) { results.append($0) }
            let session = URLSession(configuration: .ephemeral)
            let task = ResponseTask(url: endpoint, status: 200)
            delegate.urlSession(session, downloadTask: task, didFinishDownloadingTo: source)
            delegate.urlSession(session, task: task, didCompleteWithError: nil)
            delegate.urlSession(session, task: task, didCompleteWithError: nil)
            XCTAssertEqual(results.count, 1)
            try results[0].get()
            XCTAssertEqual(try Data(contentsOf: destination), Data("abc".utf8))
        }
    }

    func testFileMoveFailureCompletesOnlyOnce() throws {
        try withDirectory { directory in
            var results: [Result<Void, Error>] = []
            let delegate = UpdateDownloadDelegate(destination: directory.appendingPathComponent("missing/package.zip"), expectedBytes: nil, progress: { _ in }) { results.append($0) }
            let session = URLSession(configuration: .ephemeral)
            let task = ResponseTask(url: endpoint, status: 200)
            let source = directory.appendingPathComponent("source")
            try Data("abc".utf8).write(to: source)
            delegate.urlSession(session, downloadTask: task, didFinishDownloadingTo: source)
            XCTAssertTrue(results.isEmpty)
            delegate.urlSession(session, task: task, didCompleteWithError: nil)
            delegate.urlSession(session, task: task, didCompleteWithError: nil)
            XCTAssertEqual(results.count, 1)
            XCTAssertThrowsError(try results[0].get())
        }
    }

    func testMissingFileAndNetworkErrorAlwaysComplete() {
        for error: Error? in [nil, URLError(.timedOut)] {
            var result: Result<Void, Error>?
            let delegate = UpdateDownloadDelegate(destination: endpoint, expectedBytes: nil, progress: { _ in }) { result = $0 }
            let session = URLSession(configuration: .ephemeral)
            delegate.urlSession(session, task: ResponseTask(url: endpoint, status: 200), didCompleteWithError: error)
            XCTAssertThrowsError(try XCTUnwrap(result).get())
        }
    }

    func testSizeAndSHARejectStaleMetadataOrCorruption() throws {
        try withDirectory { directory in
            let archive = directory.appendingPathComponent("package.zip")
            try Data("abc".utf8).write(to: archive)
            try UpdateTransport.verifyArchive(archive, package: .init(url: endpoint.absoluteString, sha256: abcSHA.uppercased(), bytes: 3))
            XCTAssertThrowsError(try UpdateTransport.verifyArchive(archive, package: .init(url: endpoint.absoluteString, sha256: abcSHA, bytes: 4))) {
                XCTAssertTrue($0.localizedDescription.contains("大小"))
            }
            XCTAssertThrowsError(try UpdateTransport.verifyArchive(archive, package: .init(url: endpoint.absoluteString, sha256: String(repeating: "0", count: 64), bytes: 3))) {
                XCTAssertTrue($0.localizedDescription.contains("SHA-256"))
            }
        }
    }

    func testLivePublishedPackage() async throws {
        guard ProcessInfo.processInfo.environment["QINGJIE_TEST_LIVE_UPDATE"] == "1" else {
            throw XCTSkip("显式启用时验证真实 gist → GitHub 下载链路")
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let info = try await UpdateTransport.fetchInfo(from: URL(string: "https://gist.githubusercontent.com/Stubsx/6b32edfa0f8eb36dfc5ee9ed2de582be/raw/latest.json")!, using: session)
        let package = try XCTUnwrap(info.package)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("package.zip")
        try await UpdateTransport.download(package, to: archive, progress: { _ in })
        try UpdateTransport.verifyArchive(archive, package: package)
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private final class ResponseTask: URLSessionDownloadTask, @unchecked Sendable {
    private let stub: HTTPURLResponse
    override var response: URLResponse? { stub }
    init(url: URL, status: Int, type: String = "application/zip") {
        stub = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!
        super.init()
    }
}

private final class FeedProtocol: URLProtocol, @unchecked Sendable {
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let json = """
        {"version":"0.6.17","build":26,"package":{"url":"https://example.com/app.zip","sha256":"revision-\(Self.requests.count)"}}
        """
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

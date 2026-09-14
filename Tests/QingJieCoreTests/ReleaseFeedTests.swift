import XCTest
@testable import QingJieCore

final class ReleaseFeedTests: XCTestCase {
    func testNewerVersionOrBuild() {
        XCTAssertTrue(VersionComparison.isNewer("0.7.0", build: 26, than: "0.6.16", installedBuild: 25))
        XCTAssertTrue(VersionComparison.isNewer("1.0", build: 1, than: "0.9.9", installedBuild: 99))
        XCTAssertTrue(VersionComparison.isNewer("0.6.16", build: 26, than: "0.6.16", installedBuild: 25))
    }
    func testSameOrOlderIsNotNewer() {
        XCTAssertFalse(VersionComparison.isNewer("0.6.16", build: 25, than: "0.6.16", installedBuild: 25))
        XCTAssertFalse(VersionComparison.isNewer("0.6.9", build: 30, than: "0.6.16", installedBuild: 25))
        XCTAssertFalse(VersionComparison.isNewer("0.6", build: 25, than: "0.6.1", installedBuild: 20))
    }
    func testDecodesFeedWithPackage() throws {
        let json = """
        {"version":"0.7.0","build":26,"notes":"修复滚动截图","url":"https://example.com/release",
         "package":{"url":"https://example.com/app.zip","sha256":"ab12","bytes":1024}}
        """
        let info = try JSONDecoder().decode(UpdateInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.version, "0.7.0")
        XCTAssertEqual(info.package?.sha256, "ab12")
        XCTAssertEqual(info.package?.bytes, 1024)
    }
    func testDecodesLegacyFeedWithoutPackage() throws {
        let json = #"{"version":"0.6.16","build":25,"notes":null,"url":null}"#
        let info = try JSONDecoder().decode(UpdateInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.build, 25)
        XCTAssertNil(info.package)
    }
}

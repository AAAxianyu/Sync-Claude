import XCTest
@testable import SyncCore

extension CoreTests {
    func testInstalledBuildsCanSwitchWithoutAnExactVersionMatch() throws {
        for version in ["4.29.0", "4.4212.0", "4.4212.1", "4.16336.0", "5.0-beta", "4.4212"] {
            let candidate = Engine(home: root, process: process, version: version)
            XCTAssertTrue(try candidate.status().compatible, version)
            _ = try candidate.switchProfile(id: "official")
            XCTAssertEqual(try candidate.mode(), "1p", version)
            _ = try candidate.switchProfile(id: gateway)
            XCTAssertEqual(try candidate.mode(), "3p", version)
        }
    }

    func testUnverifiedBuildRefreshesOfficialUsage() async throws {
        let candidate = Engine(home: root, process: process, version: "4.16336.0")
        try selectOfficial(a)
        let result = try await candidate.refreshUsage(credential: { account in
            XCTAssertEqual(account, self.a)
            return UsageCredential(token: "fixture", plan: "pro")
        }, fetch: { _ in try self.usageData(12) })
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(try candidate.officialUsage().first?.windows.first?.utilization, 12)
    }

    func testMissingDesktopAllowsArchiveButRefusesWritesAndUsageRefresh() async throws {
        let candidate = Engine(home: root, process: process, version: "未安装")
        XCTAssertFalse(try candidate.status().compatible)
        XCTAssertThrowsError(try candidate.switchProfile(id: "official"))
        XCTAssertEqual(process.stops, 0)
        XCTAssertEqual(try candidate.mode(), "3p")
        XCTAssertNoThrow(try candidate.archive())
        try selectOfficial(a)
        do {
            _ = try await candidate.refreshUsage(credential: { _ in
                XCTFail("Missing Desktop must not read credentials")
                throw SyncError("unexpected credential access")
            }, fetch: { _ in
                XCTFail("Missing Desktop must not request usage")
                return Data()
            })
            XCTFail("Expected usage refresh to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("未检测到 Claude Desktop"))
        }
    }
}

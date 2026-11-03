import XCTest
@testable import SyncCore

extension CoreTests {
    func workspace(_ profile: String, _ account: String, _ organization: String) throws -> URL {
        let directory = engine.support.appendingPathComponent("\(profile)/claude-code-sessions/\(account)/\(organization)")
        try privateDir(directory)
        return directory
    }

    func testWorkspaceAccountSwitchRoundTripPreservesNativeChoiceAndUnrelatedAccounts() throws {
        let ap = try owner("Claude", a), at = try workspace("Claude", a, gateway)
        let bp = try owner("Claude", b), bt = try workspace("Claude", b, gateway)
        let api = try owner("Claude-3p", a)
        try selectOfficial(a); _ = try engine.saveAccount(name: "A")
        let aid = try XCTUnwrap(engine.accounts().first?["id"] as? String)
        try selectOfficial(b)
        let nativeChoice = Data("B native workspace cookie fixture".utf8)
        try atomicData(nativeChoice, engine.first.appendingPathComponent("Cookies"))
        _ = try engine.saveAccount(name: "B")
        let bid = try XCTUnwrap(engine.accounts().first { $0["account"] as? String == b }?["id"] as? String)
        _ = try engine.switchProfile(id: aid)
        for (directory, id) in [(ap, sid), (at, gateway), (bp, a), (bt, b)] { _ = try fixture(directory, id: id) }
        let apiBefore = try digestTree(api)
        XCTAssertEqual(try engine.switchProfile(id: bid).added, 6)
        XCTAssertEqual(try engine.accountID(), b)
        XCTAssertEqual(try Data(contentsOf: engine.first.appendingPathComponent("Cookies")), nativeChoice)
        for target in [bp, bt] {
            for id in [sid, gateway, a, b] { XCTAssertTrue(exists(target.appendingPathComponent("local_\(id).json"))) }
        }
        XCTAssertEqual(try engine.switchProfile(id: aid).added, 6)
        for target in [ap, at] {
            for id in [sid, gateway, a, b] { XCTAssertTrue(exists(target.appendingPathComponent("local_\(id).json"))) }
        }
        XCTAssertEqual(try engine.status().profiles.filter { $0.kind == "account" }.map(\.workspaceCount), [2, 2])
        XCTAssertEqual(try digestTree(api), apiBefore)
        XCTAssertFalse(exists(engine.state.appendingPathComponent("pending.json")))
    }

    func testWorkspaceSyncMergesBothDirectionsAndKeepsExistingMetadata() throws {
        let personal = try owner("Claude", b), team = try workspace("Claude", b, gateway)
        try selectOfficial(b)
        let p = try fixture(personal), t = try fixture(team, id: a)
        let before = try [p, t].map { try Data(contentsOf: $0) }
        XCTAssertEqual(try engine.sync().added, 2)
        XCTAssertEqual(try [p, t].map { try Data(contentsOf: $0) }, before)
        for (directory, id) in [(team, sid), (personal, a)] {
            let copy = try readJSON(directory.appendingPathComponent("local_\(id).json"))
            XCTAssertEqual(copy["permissionMode"] as? String, "default")
            XCTAssertNil(copy["alwaysAllowedReasons"]); XCTAssertNil(copy["remoteMcpServersConfig"])
        }
        XCTAssertEqual(try engine.sync().added, 0)
        _ = try deletionMarker(team)
        _ = try engine.sync()
        for directory in [personal, team] {
            XCTAssertFalse(exists(directory.appendingPathComponent("local_\(sid).json")))
            XCTAssertTrue(exists(directory.appendingPathComponent("local_\(a).json")))
        }
        XCTAssertTrue(exists(root.appendingPathComponent(".claude/projects/-fixture/\(sid).jsonl")))
    }

    func testWorkspaceFirstSaveAndAPISwitchIncludeEveryKnownWorkspace() throws {
        let source = try owner("Claude", a)
        _ = try fixture(source); _ = try taskFixture(source)
        let personal = try owner("Claude", b), team = try workspace("Claude", b, gateway)
        try selectOfficial(b)
        XCTAssertEqual(try engine.saveAccount(name: "Personal and Team").added, 2)
        for directory in [personal, team] { XCTAssertEqual(try tasks(directory).count, 1) }
        let apiPersonal = try owner("Claude-3p", b), apiTeam = try workspace("Claude-3p", b, gateway)
        let unrelated = try owner("Claude-3p", a), before = try digestTree(unrelated)
        try atomicJSON(["lastKnownAccountUuid": b], engine.third.appendingPathComponent("config.json"))
        XCTAssertEqual(try engine.switchProfile(id: gateway).added, 2)
        for directory in [apiPersonal, apiTeam] {
            XCTAssertTrue(exists(directory.appendingPathComponent("local_\(sid).json")))
            XCTAssertEqual(try tasks(directory).count, 1)
        }
        XCTAssertEqual(try digestTree(unrelated), before)
    }

    func testWorkspaceTasksShareRuntimeAndNotificationsButKeepOwnPermissions() throws {
        let source = try owner("Claude", a), personal = try owner("Claude", b)
        let team = try workspace("Claude", b, gateway)
        try selectOfficial(b)
        _ = try scheduledRun(source)
        _ = try taskFixture(source, changes: ["notifySessionId": "local_" + sid])
        _ = try taskFixture(personal, changes: ["notifySessionId": "local_" + sid, "approvedPermissions": [["toolName": "personal-only"]]])
        _ = try taskFixture(source, id: "paused", enabled: false)
        try editTask(personal) { $0["lastScheduledFor"] = "2026-11-02T09:00:00Z" }
        _ = try engine.sync()
        for directory in [personal, team] {
            let items = try tasks(directory)
            XCTAssertEqual(items.count, 2)
            let task = try XCTUnwrap(items.first { $0["id"] as? String == "daily-review" })
            XCTAssertEqual(task["lastScheduledFor"] as? String, "2026-11-02T09:00:00Z")
            XCTAssertEqual(task["notifySessionId"] as? String, "local_" + sid)
            XCTAssertEqual(items.first { $0["id"] as? String == "paused" }?["enabled"] as? Bool, false)
            XCTAssertEqual(try readJSON(directory.appendingPathComponent("local_\(sid).json"))["scheduledTaskId"] as? String, "daily-review")
        }
        let personalTask = try XCTUnwrap(tasks(personal).first { $0["id"] as? String == "daily-review" })
        let teamTask = try XCTUnwrap(tasks(team).first { $0["id"] as? String == "daily-review" })
        XCTAssertEqual(personalTask["approvedPermissions"] as? [[String: String]], [["toolName": "personal-only"]])
        XCTAssertEqual(personalTask["permissionMode"] as? String, "bypassPermissions")
        XCTAssertEqual(teamTask["permissionMode"] as? String, "default"); XCTAssertNil(teamTask["approvedPermissions"])
        XCTAssertEqual(personalTask["missedRunScanFloor"] as? String, teamTask["missedRunScanFloor"] as? String)
        let before = try [personal, team].map { try digestTree($0) }
        _ = try engine.sync()
        XCTAssertEqual(try [personal, team].map { try digestTree($0) }, before)
        XCTAssertNil(try engine.readScheduleLedger()["activeOwner"])
        XCTAssertEqual(try engine.readScheduleLedger()["lastTargets"] as? [String], try engine.syncTargets().map(\.key).sorted())
    }

    func testWorkspaceNewTaskIsNotMistakenForSiblingDeletion() throws {
        let personal = try owner("Claude", b), team = try workspace("Claude", b, gateway)
        try selectOfficial(b); _ = try taskFixture(personal); _ = try engine.sync()
        _ = try taskFixture(team, id: "team-created")
        _ = try engine.sync()
        for directory in [personal, team] { XCTAssertEqual(try tasks(directory).count, 2) }
        try editTask(team, id: "team-created") { $0["enabled"] = false }
        _ = try engine.sync()
        XCTAssertEqual(try tasks(personal).first { $0["id"] as? String == "team-created" }?["enabled"] as? Bool, false)
    }

    func testWorkspaceTaskRemovalPropagatesFromEitherPreviouslySyncedWorkspace() throws {
        let source = try owner("Claude", a), personal = try owner("Claude", b)
        let team = try workspace("Claude", b, gateway)
        try selectOfficial(b); _ = try taskFixture(source); _ = try engine.sync()
        // A completely missing manifest is not removal, even though its peer still exists.
        try fm.removeItem(at: team.appendingPathComponent("scheduled-tasks.json"))
        _ = try engine.sync(); XCTAssertEqual(try tasks(team).count, 1)
        try emptySchedule(team)
        _ = try engine.sync()
        for directory in [source, personal, team] { XCTAssertTrue(try tasks(directory).isEmpty) }
        _ = try engine.sync()
        XCTAssertTrue(try tasks(team).isEmpty)
        XCTAssertTrue(exists(root.appendingPathComponent(".claude/scheduled-tasks/daily-review/SKILL.md")))
    }

    func testWorkspaceNewlyDiscoveredDirectoryIsNotADeletionAndGetsRecordsOnNextSync() throws {
        let source = try owner("Claude", a), personal = try owner("Claude", b)
        try selectOfficial(b); _ = try taskFixture(source); _ = try fixture(source); _ = try engine.sync()
        // Native Claude creates this directory when the user first opens Code in a new workspace.
        let team = try workspace("Claude", b, gateway)
        try emptySchedule(team)
        XCTAssertEqual(try engine.sync().added, 1)
        for directory in [source, personal, team] { XCTAssertEqual(try tasks(directory).count, 1) }
        XCTAssertTrue(exists(team.appendingPathComponent("local_\(sid).json")))
    }

    func testWorkspaceTaskConflictRollsBackAllDirectoriesAndAccountSwitch() throws {
        let personal = try owner("Claude", b), team = try workspace("Claude", b, gateway)
        try selectOfficial(b); _ = try engine.saveAccount(name: "B")
        let bid = try XCTUnwrap(engine.accounts().first?["id"] as? String)
        let source = try owner("Claude", a)
        try selectOfficial(a); _ = try engine.saveAccount(name: "A")
        _ = try taskFixture(personal)
        _ = try taskFixture(team, changes: ["cronExpression": "0 8 * * *"])
        _ = try fixture(source)
        let before = try [personal, team, engine.first.appendingPathComponent("config.json"), engine.first.appendingPathComponent("Cookies")].map { try digestTree($0) }
        XCTAssertThrowsError(try engine.switchProfile(id: bid))
        XCTAssertEqual(try [personal, team, engine.first.appendingPathComponent("config.json"), engine.first.appendingPathComponent("Cookies")].map { try digestTree($0) }, before)
        XCTAssertEqual(try engine.accountID(), a)
        XCTAssertTrue(process.running); XCTAssertFalse(exists(engine.state.appendingPathComponent("pending.json")))
    }

    func testWorkspaceRemovalVersusEditPreservesBothSidesOnConflict() throws {
        let personal = try owner("Claude", b), team = try workspace("Claude", b, gateway)
        try selectOfficial(b); _ = try taskFixture(personal); _ = try engine.sync()
        try emptySchedule(team); try editTask(personal) { $0["enabled"] = false }
        let before = try [personal, team, engine.scheduleLedger].map { try digestTree($0) }
        XCTAssertThrowsError(try engine.sync())
        XCTAssertEqual(try [personal, team, engine.scheduleLedger].map { try digestTree($0) }, before)
    }

    func testWorkspaceInterruptedTaskWritesRecoverEveryDestinationAndLedger() throws {
        let source = try owner("Claude", a), personal = try owner("Claude", b)
        let team = try workspace("Claude", b, gateway)
        try selectOfficial(b); _ = try taskFixture(source); _ = try engine.sync()
        try editTask(source) { $0["enabled"] = false }
        let before = try [personal, team, engine.scheduleLedger].map { try digestTree($0) }
        let tx = try Transaction(root: engine.state, operation: "workspace interrupted write")
        let targets = try engine.syncTargets()
        tx.beforeWrite = {
            if let first = try? self.tasks(personal).first, first["enabled"] as? Bool == false {
                throw SyncError("injected interruption after first workspace write")
            }
        }
        XCTAssertThrowsError(try engine.synchronizeTasks(from: targets, into: targets, transaction: tx))
        XCTAssertEqual(try tasks(personal)[0]["enabled"] as? Bool, false)
        try Transaction.recover(root: engine.state)
        XCTAssertEqual(try [personal, team, engine.scheduleLedger].map { try digestTree($0) }, before)
        XCTAssertFalse(exists(tx.pending))
    }

    func testWorkspaceCleanupRequiresTaskCopiesInEveryCurrentWorkspace() throws {
        let source = try owner("Claude", a), personal = try owner("Claude", b)
        let team = try workspace("Claude", b, gateway)
        try selectOfficial(b); _ = try taskFixture(source); _ = try engine.sync()
        let sourceOwner = try XCTUnwrap(engine.history.owners().first { $0.directory.path == source.path })
        XCTAssertTrue(try engine.tasksPreservedOutside(sourceOwner))
        try editTask(team) { $0["lastScheduledFor"] = "2026-10-01T09:00:00Z" }
        XCTAssertFalse(try engine.tasksPreservedOutside(sourceOwner))
        _ = try engine.sync()
        XCTAssertTrue(try engine.tasksPreservedOutside(sourceOwner))
        let active = try XCTUnwrap(engine.history.owners().first { $0.directory.path == personal.path })
        XCTAssertFalse(try engine.tasksPreservedOutside(active))
    }

    func testWorkspaceLegacyTaskBaselineStillDetectsRemoval() throws {
        let source = try owner("Claude", a), personal = try owner("Claude", b)
        try selectOfficial(b); _ = try taskFixture(source); _ = try engine.sync()
        var ledger = try engine.readScheduleLedger(); ledger.removeValue(forKey: "lastTargets")
        try atomicJSON(ledger, engine.scheduleLedger)
        try emptySchedule(personal)
        let team = try workspace("Claude", b, gateway)
        _ = try engine.sync()
        for directory in [source, personal, team] { XCTAssertTrue(try tasks(directory).isEmpty) }
    }
}

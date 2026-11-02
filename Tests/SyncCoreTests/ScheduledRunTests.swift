import XCTest
@testable import SyncCore

extension CoreTests {
    func completeRun(_ directory: URL, id: String? = nil) throws -> URL {
        let id = id ?? sid, file = try scheduledRun(directory, id: id)
        let event: [String: Any] = ["type": "assistant", "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "Done."]]]]
        var bytes = try JSONSerialization.data(withJSONObject: event); bytes.append(10)
        try atomicData(bytes, root.appendingPathComponent(".claude/projects/-fixture/\(id).jsonl"))
        return file
    }
    func testRunRemovalKeepsTaskAndPromptAndSupportsSeparatePermanentPurge() throws {
        let first = try owner("Claude", a), second = try owner("Claude", b)
        try selectOfficial(b)
        _ = try completeRun(first)
        let original = try taskFixture(first, changes: ["notifySessionId": "local_" + sid])
        _ = try engine.sync()
        let prompt = URL(fileURLWithPath: original["filePath"] as! String), before = try Data(contentsOf: prompt)
        let preview = try engine.previewScheduledRunRemoval(ids: ["local_" + sid])
        XCTAssertEqual(preview.notificationReferences, 2)
        XCTAssertEqual(try engine.removeScheduledRuns(preview).added, 1)
        for directory in [first, second] {
            XCTAssertFalse(exists(directory.appendingPathComponent("local_\(sid).json")))
            XCTAssertTrue(exists(directory.appendingPathComponent("deleted_\(sid)")))
            let task = try XCTUnwrap(tasks(directory).first)
            XCTAssertEqual(task["enabled"] as? Bool, true)
            XCTAssertEqual(task["cronExpression"] as? String, original["cronExpression"] as? String)
            XCTAssertEqual(task["lastScheduledFor"] as? String, original["lastScheduledFor"] as? String)
            XCTAssertNil(task["notifySessionId"])
        }
        let transcript = root.appendingPathComponent(".claude/projects/-fixture/\(sid).jsonl")
        XCTAssertTrue(exists(transcript))
        XCTAssertEqual(try Data(contentsOf: prompt), before)
        _ = try engine.sync(); XCTAssertTrue(try engine.scheduledRuns().isEmpty)
        let purge = try engine.previewSessionPurge(ids: ["local_" + sid])
        XCTAssertFalse(purge.files.contains { $0.path == prompt.path })
        _ = try engine.purgeDeletedSessions(purge)
        XCTAssertFalse(exists(transcript))
        XCTAssertEqual(try Data(contentsOf: prompt), before)
        XCTAssertEqual(try tasks(second).count, 1)
    }
    func testRunRemovalRejectsWorkingWaitingAndInterruptedRuns() throws {
        let directory = try owner("Claude", b)
        let file = try completeRun(directory)
        process.workers = 1
        XCTAssertFalse(try XCTUnwrap(engine.scheduledRuns().first).canRemove)
        XCTAssertThrowsError(try engine.previewScheduledRunRemoval(ids: ["local_" + sid]))
        process.workers = 0
        var value = try readJSON(file); value["interruptedAwaitingPerson"] = true; try atomicJSON(value, file)
        XCTAssertFalse(try XCTUnwrap(engine.scheduledRuns().first).canRemove)
        value["interruptedAwaitingPerson"] = NSNull(); value["cutTurn"] = NSNull(); try atomicJSON(value, file)
        XCTAssertTrue(try XCTUnwrap(engine.scheduledRuns().first).canRemove)
        value["armedWorkAtQuit"] = ["reason": "resume"]; try atomicJSON(value, file)
        XCTAssertFalse(try XCTUnwrap(engine.scheduledRuns().first).canRemove)
    }
    func testCompletedTurnsAndArchivedFlagAloneDoNotPermitRunRemoval() throws {
        let directory = try owner("Claude", b), file = try scheduledRun(directory)
        var value = try readJSON(file); value["isArchived"] = true; try atomicJSON(value, file)
        XCTAssertFalse(try XCTUnwrap(engine.scheduledRuns().first).canRemove)
        XCTAssertThrowsError(try engine.previewScheduledRunRemoval(ids: ["local_" + sid]))
        XCTAssertTrue(try engine.deletedSessionRecords().isEmpty)
    }
    func testStaleRunPreviewAndNewWorkersAreRecheckedBeforeDeletion() throws {
        let directory = try owner("Claude", b), file = try completeRun(directory)
        let preview = try engine.previewScheduledRunRemoval(ids: ["local_" + sid])
        process.workers = 1
        XCTAssertThrowsError(try engine.removeScheduledRuns(preview))
        XCTAssertEqual(process.stops, 0)
        process.workers = 0
        var value = try readJSON(file); value["title"] = "New content"; try atomicJSON(value, file)
        XCTAssertThrowsError(try engine.removeScheduledRuns(preview))
        XCTAssertTrue(exists(file))
        XCTAssertTrue(try engine.history.deletedSessions().isEmpty)
        XCTAssertFalse(exists(engine.state.appendingPathComponent("pending.json")))
    }
    func testRunRemovalSelectsOnlyScheduledRunsAndChecksAllCopies() throws {
        let first = try owner("Claude", a), second = try owner("Claude", b)
        _ = try completeRun(first); _ = try fixture(first, id: gateway)
        let copy = try completeRun(second)
        XCTAssertEqual(try engine.scheduledRuns().count, 1)
        XCTAssertThrowsError(try engine.previewScheduledRunRemoval(ids: ["local_" + gateway]))
        var value = try readJSON(copy); value["scheduledTaskId"] = "different-task"; try atomicJSON(value, copy)
        XCTAssertFalse(try XCTUnwrap(engine.scheduledRuns().first).canRemove)
    }
    func testRunRemovalPreservesOtherHistoryAndSharedTranscriptGuard() throws {
        let directory = try owner("Claude", b)
        _ = try completeRun(directory)
        let other = try fixture(directory, id: gateway)
        var value = try readJSON(other); value["cliSessionId"] = sid; try atomicJSON(value, other)
        let preview = try engine.previewScheduledRunRemoval(ids: ["local_" + sid])
        _ = try engine.removeScheduledRuns(preview)
        XCTAssertTrue(exists(other))
        XCTAssertThrowsError(try engine.previewSessionPurge(ids: ["local_" + sid]))
    }
    func testIncompleteOrToolWaitingTranscriptBlocksRunRemoval() throws {
        let directory = try owner("Claude", b)
        _ = try completeRun(directory)
        let transcript = root.appendingPathComponent(".claude/projects/-fixture/\(sid).jsonl")
        var data = try Data(contentsOf: transcript); data.removeLast(); try atomicData(data, transcript)
        XCTAssertFalse(try XCTUnwrap(engine.scheduledRuns().first).canRemove)
        try atomicData(Data("{\"type\":\"assistant\",\"message\":{\"stop_reason\":\"tool_use\",\"content\":[]}}\n".utf8), transcript)
        XCTAssertFalse(try XCTUnwrap(engine.scheduledRuns().first).canRemove)
        try atomicData(Data("{\"type\":\"result\",\"subtype\":\"error_during_execution\"}\n".utf8), transcript)
        XCTAssertTrue(try XCTUnwrap(engine.scheduledRuns().first).canRemove)
    }
    func testCleanupOnlyAllowsFullyPreservedTasksAndKeepsSharedPrompt() throws {
        let source = try prepareCleanup(), target = try owner("Claude", b)
        let task = try taskFixture(source)
        XCTAssertFalse(try cleanupPreview(source).canClean)
        _ = try engine.sync()
        let preview = try cleanupPreview(source)
        XCTAssertTrue(preview.canClean)
        _ = try engine.cleanAccountRecords([preview])
        XCTAssertFalse(exists(source))
        XCTAssertTrue(exists(URL(fileURLWithPath: task["filePath"] as! String)))
        XCTAssertEqual(try tasks(target).count, 1)
        let removed = try XCTUnwrap(engine.removedAccountRecords().first)
        try emptySchedule(target); _ = try engine.sync()
        _ = try engine.restoreAccountRecords(id: removed.id)
        XCTAssertTrue(try tasks(source).isEmpty, "Restoring an old directory must not revive a deleted task")
    }
    func testCleanupBlocksUnsyncedTaskChangesAndMissingPrompt() throws {
        let source = try prepareCleanup(); _ = try owner("Claude", b)
        let task = try taskFixture(source); _ = try engine.sync()
        try editTask(source) { $0["enabled"] = false }
        XCTAssertFalse(try cleanupPreview(source).canClean)
        _ = try engine.sync(); XCTAssertTrue(try cleanupPreview(source).canClean)
        try fm.removeItem(atPath: task["filePath"] as! String)
        XCTAssertFalse(try cleanupPreview(source).canClean)
    }
    func testSavingNewAccountAutomaticallyImportsSessionsAndTasks() throws {
        let source = try owner("Claude", a), target = try owner("Claude", b)
        _ = try taskFixture(source); _ = try scheduledRun(source)
        try selectOfficial(b)
        XCTAssertEqual(try engine.saveAccount(name: "B").added, 1)
        XCTAssertEqual(try tasks(target).count, 1)
        XCTAssertTrue(exists(target.appendingPathComponent("local_\(sid).json")))
    }
    func testRemovingNotificationReferenceDoesNotSwallowUnrelatedTaskEdit() throws {
        let source = try owner("Claude", a), target = try owner("Claude", b)
        try selectOfficial(b); _ = try completeRun(source)
        _ = try taskFixture(source, changes: ["notifySessionId": "local_" + sid]); _ = try engine.sync()
        try editTask(source) { $0["cronExpression"] = "0 8 * * *" }
        _ = try engine.removeScheduledRuns(engine.previewScheduledRunRemoval(ids: ["local_" + sid]))
        _ = try engine.sync()
        XCTAssertEqual(try tasks(target)[0]["cronExpression"] as? String, "0 8 * * *")
    }
    func testFailureAfterRunRemovalRollsBackDeletionIntent() throws {
        let source = try owner("Claude", a), target = try owner("Claude", b)
        try selectOfficial(b); _ = try taskFixture(source); _ = try engine.sync()
        try emptySchedule(target); _ = try engine.sync()
        // An independently recreated task conflicts with an existing task tombstone.
        _ = try taskFixture(source, changes: ["createdAt": 2000])
        let file = try completeRun(target), preview = try engine.previewScheduledRunRemoval(ids: ["local_" + sid])
        XCTAssertThrowsError(try engine.removeScheduledRuns(preview))
        XCTAssertTrue(exists(file))
        XCTAssertFalse(exists(target.appendingPathComponent("deleted_\(sid)")))
        XCTAssertTrue(try engine.history.deletedSessions().isEmpty)
        XCTAssertFalse(exists(engine.state.appendingPathComponent("pending.json")))
    }
}

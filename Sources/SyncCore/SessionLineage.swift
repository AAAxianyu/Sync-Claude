import Foundation
import CoreFoundation

/// Desktop's sidebar derives its tree from these fields, independently of the JSONL body.
/// Only relationship/display metadata crosses accounts; wakeups, grants and shared-checkout
/// execution state are deliberately excluded from spawnedFrom.
enum SessionLineage {
    static let keys: Set<String> = ["spawnedFrom", "forkedFromSessionId", "forkedAtMessageUuid", "lineageDetached"]
    static let flags = ["sideSession", "userFork", "handOff", "btw"]

    static func hasMetadata(_ value: [String: Any]) -> Bool {
        keys.contains { value[$0] != nil && !(value[$0] is NSNull) }
    }

    static func portable(_ value: [String: Any], session: String) throws -> [String: Any] {
        func invalid() -> SyncError { SyncError("会话 \(session) 的父子关联格式无法安全同步，原记录保留。") }
        func text(_ raw: Any?, allowEmpty: Bool = false) throws -> String? {
            guard let raw, !(raw is NSNull) else { return nil }
            guard let string = raw as? String, allowEmpty || !string.isEmpty else { throw invalid() }
            return string
        }
        func localID(_ raw: Any?) throws -> String? {
            guard let id = try text(raw) else { return nil }
            guard validSession(id), id.lowercased() != session.lowercased() else { throw invalid() }
            return id
        }
        func flag(_ raw: Any?) throws -> Bool? {
            guard let raw, !(raw is NSNull) else { return nil }
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid() }
            return number.boolValue
        }
        var result: [String: Any] = [:]
        if let parent = try localID(value["forkedFromSessionId"]) { result["forkedFromSessionId"] = parent }
        if let point = try text(value["forkedAtMessageUuid"]) {
            guard uuid(point), result["forkedFromSessionId"] != nil else { throw invalid() }
            result["forkedAtMessageUuid"] = point
        }
        if let detached = try flag(value["lineageDetached"]) { result["lineageDetached"] = detached }
        if let raw = value["spawnedFrom"], !(raw is NSNull) {
            guard let source = raw as? [String: Any], let parent = try localID(source["sessionId"]) else { throw invalid() }
            var link: [String: Any] = ["sessionId": parent]
            for key in ["taskId", "title", "name"] {
                if let string = try text(source[key], allowEmpty: true) { link[key] = string }
            }
            for key in flags {
                if let enabled = try flag(source[key]) { link[key] = enabled }
            }
            if let raw = source["deletedParent"], !(raw is NSNull) {
                guard let previous = raw as? [String: Any], let id = try localID(previous["sessionId"]) else { throw invalid() }
                var old: [String: Any] = ["sessionId": id]
                if let title = try text(previous["title"], allowEmpty: true) { old["title"] = title }
                link["deletedParent"] = old
            }
            result["spawnedFrom"] = link
        }
        return result
    }

    /// Ignore cosmetic labels when detecting conflicting parentage at the same revision.
    static func identity(_ value: [String: Any]) throws -> String {
        var identity = value
        if identity["lineageDetached"] as? Bool == false { identity.removeValue(forKey: "lineageDetached") }
        if var link = identity["spawnedFrom"] as? [String: Any] {
            link.removeValue(forKey: "title"); link.removeValue(forKey: "name")
            for key in flags where link[key] as? Bool == false { link.removeValue(forKey: key) }
            if var old = link["deletedParent"] as? [String: Any] {
                old.removeValue(forKey: "title"); link["deletedParent"] = old
            }
            identity["spawnedFrom"] = link
        }
        return try sha(jsonData(identity))
    }

    /// Mirrors the parent precedence used by both verified Desktop sidebar adapters.
    /// Runtime/permission state is irrelevant to the graph and is never consulted.
    static func parent(of value: [String: Any]) -> String? {
        if value["lineageDetached"] as? Bool == true { return nil }
        let link = value["spawnedFrom"] as? [String: Any]
        let spawned = link?["sessionId"] as? String, fork = value["forkedFromSessionId"] as? String
        let previous = (link?["deletedParent"] as? [String: Any])?["sessionId"] as? String
        let parent: String?
        if link?["sideSession"] as? Bool == true, link?["userFork"] as? Bool != true,
           fork == nil || fork == spawned || fork == previous { parent = spawned }
        else { parent = fork ?? spawned }
        return parent.flatMap { validSession($0) ? $0.lowercased() : nil }
    }

    static func validateGraph(_ records: [String: [String: Any]], startingAt starts: Set<String>) throws {
        var completed = Set<String>()
        for start in starts {
            var path = Set<String>(), cursor: String? = start.lowercased()
            while let id = cursor, let value = records[id], !completed.contains(id) {
                guard path.insert(id).inserted else { throw SyncError("会话树存在循环父子关联，已停止同步并保留原记录。") }
                cursor = parent(of: value)
            }
            completed.formUnion(path)
        }
    }
}

/// Resolve from verified versions, not just index.json: a newer legacy import can have
/// replaced the index entry with a copy whose ancestry was stripped by older Sync Claude.
final class SessionLineageResolver {
    let vault: URL
    let live: [String: [Record]]
    private var cache: [String: [String: Any]] = [:]
    init(vault: URL, records: [Record]) {
        self.vault = vault; live = Dictionary(grouping: records, by: \.id)
    }

    func resolve(session id: String, cli: String) throws -> [String: Any] {
        let key = id + "/" + cli
        if let value = cache[key] { return value }
        var candidates: [(value: [String: Any], time: Double, live: Bool)] = []
        func append(_ value: [String: Any], live: Bool) {
            guard value["sessionId"] as? String == id, value["cliSessionId"] as? String == cli,
                  SessionLineage.hasMetadata(value) else { return }
            candidates.append((value, (value["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0, live))
        }
        for record in live[id] ?? [] { append(record.value, live: true) }
        let folder = vault.appendingPathComponent("records/" + id)
        try safePath(folder)
        if exists(folder) {
            for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                try safePath(file)
                let bytes = try Data(contentsOf: file)
                guard file.pathExtension == "json", file.deletingPathExtension().lastPathComponent == sha(bytes),
                      let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      value["sessionId"] as? String == id else { throw SyncError("会话树恢复所需的历史归档校验失败，未修改会话。") }
                append(value, live: false)
            }
        }
        // Use archives only when no live copy retains lineage. A current detach/reparent
        // choice may have an older lastActivityAt than a previously archived conversation.
        if candidates.contains(where: \.live) { candidates = candidates.filter(\.live) }
        guard let newest = candidates.map(\.time).max() else { cache[key] = [:]; return [:] }
        let latest = candidates.filter { $0.time == newest }
        let values = try latest.map { try SessionLineage.portable($0.value, session: id) }
        guard Set(try values.map(SessionLineage.identity)).count <= 1 else {
            throw SyncError("会话 \(id) 存在不同的父子关联，无法确定应恢复哪一层级；请先在 Claude 中确认原会话关系。")
        }
        let result = try values.sorted { try sha(jsonData($0)) < sha(jsonData($1)) }.first ?? [:]
        cache[key] = result
        return result
    }
}

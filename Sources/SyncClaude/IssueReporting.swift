import AppKit
import SyncCore

enum IssueReporter {
    static func open() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let system = ProcessInfo.processInfo.operatingSystemVersion
        // Use only app/system versions. Raw errors can contain private paths or account data.
        let body = """
        ## 问题描述

        请描述无法使用的功能和预期结果。

        ## 复现步骤

        1.

        ## 错误提示

        请补充错误提示或截图，并遮去账号、密钥和私有内容。

        ## 运行环境

        - Sync Claude \(version) (\(build))
        - Claude Desktop \(Engine().version)
        - macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)
        """
        var components = URLComponents(string: "https://github.com/Chiiz0/Sync-Claude/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "title", value: "功能无法正常使用"),
            URLQueryItem(name: "body", value: body)
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}

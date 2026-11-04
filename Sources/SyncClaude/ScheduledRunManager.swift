import SwiftUI
import SyncCore

struct ScheduledRunManager: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let remove: (ScheduledRunRemovalPreview) -> Void
    @State private var records: [ScheduledRunInfo] = []
    @State private var selection = Set<String>()
    @State private var expandedTasks = Set<String>()
    @State private var task = ""
    @State private var owner = ""
    @State private var days = 0
    @State private var completedOnly = false
    @State private var loading = false
    @State private var error: String?
    @State private var preview: ScheduledRunRemovalPreview?
    var visible: [ScheduledRunInfo] {
        records.filter {
            (task.isEmpty || $0.taskID == task) && (owner.isEmpty || $0.owners.contains(owner))
                && (!completedOnly || $0.canRemove)
                && (days == 0 || $0.lastActivity / 1000 >= Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970)
        }
    }
    var removableIDs: Set<String> { Set(visible.filter(\.canRemove).map(\.id)) }
    private var groups: [ScheduledRunGroup] {
        Dictionary(grouping: visible, by: \.taskID).map { id, runs in
            ScheduledRunGroup(id: id, runs: runs.sorted {
                if $0.lastActivity != $1.lastActivity { return $0.lastActivity > $1.lastActivity }
                return $0.id < $1.id
            })
        }.sorted {
            if $0.lastActivity != $1.lastActivity { return $0.lastActivity > $1.lastActivity }
            return $0.id < $1.id
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("定时任务运行历史").font(.title2.weight(.semibold))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("刷新") { Task { await load() } }.disabled(loading)
            }
            Text("单独移除已结束的本机 Code 运行记录，保留任务、提示词、启用状态与后续调度。").foregroundStyle(.secondary)
            HStack {
                Picker("任务", selection: $task) {
                    Text("全部任务").tag("")
                    ForEach(Set(records.map(\.taskID)).sorted(), id: \.self) { Text($0).tag($0) }
                }
                Picker("账户/组织", selection: $owner) {
                    Text("全部账户/组织").tag("")
                    ForEach(Set(records.flatMap(\.owners)).sorted(), id: \.self) { key in
                        Text(key.split(separator: "/").map { String($0.prefix(8)) }.joined(separator: " / ")).tag(key)
                    }
                }
                Picker("时间", selection: $days) {
                    Text("全部时间").tag(0); Text("近 7 天").tag(7); Text("近 30 天").tag(30)
                }.frame(width: 155)
            }
            HStack {
                Toggle("仅显示已确认结束、可移除的运行", isOn: $completedOnly).toggleStyle(.checkbox)
                Spacer()
                Text("\(groups.count) 个任务 · \(visible.count) 次运行 · \(removableIDs.count) 条可移除").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        taskGroup(group)
                    }
                    if visible.isEmpty && !loading { Text("没有符合条件的本机任务运行记录").foregroundStyle(.secondary).padding() }
                }
            }.frame(minHeight: 240, maxHeight: 390)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                Button("提交 Issue…") { IssueReporter.open() }.font(.caption)
            }
            Text("移除后会传播到所有账户。正文与备份保留，可在“已删除会话”中另行预览并永久清理。等待输入、中断待续或缺少结束证据的记录暂不可移除。存在 Code 进程时会先确认正常退出，退出后再次核对所选记录。云端与 Cowork 不在此范围。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("全选可移除项") { selection = removableIDs }.disabled(loading || removableIDs.isEmpty)
                Button("取消全选") { selection.removeAll() }.disabled(loading || selection.isEmpty)
                Text("已选 \(selection.count) 条").font(.caption)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("移除所选运行历史…", role: .destructive) { prepare() }.disabled(loading || model.busy || selection.isEmpty || model.status?.compatible != true)
            }
        }.padding(24).frame(width: 800)
        .task { await load() }
        .onChange(of: task) { _ in selection.removeAll() }
        .onChange(of: owner) { _ in selection.removeAll() }
        .onChange(of: days) { _ in selection.removeAll() }
        .onChange(of: completedOnly) { _ in selection.removeAll() }
        .alert("移除 \(preview?.runs.count ?? 0) 条运行历史？", isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            Button("移除列表记录", role: .destructive) { if let preview { remove(preview) }; preview = nil }
            Button("取消", role: .cancel) { preview = nil }
        } message: {
            Text("Claude 会正常退出并重开。所选记录会从所有账户列表移除，归档和目录恢复不会重新带回。任务与后续调度保留；正文、附件、项目文件和备份不在此次删除范围。\n\n将解除 \(preview?.notificationReferences ?? 0) 处指向这些运行的通知会话引用，避免任务继续向已移除的会话发送通知。")
        }
    }
    private func taskGroup(_ group: ScheduledRunGroup) -> some View {
        let ids = group.removableIDs
        let selectedCount = selection.intersection(ids).count
        return DisclosureGroup(isExpanded: Binding(
            get: { expandedTasks.contains(group.id) },
            set: { if $0 { expandedTasks.insert(group.id) } else { expandedTasks.remove(group.id) } }
        )) {
            VStack(spacing: 8) {
                ForEach(group.runs) { row in runRow(row) }
            }.padding(.top, 10).padding(.leading, 12)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(group.id).font(.headline).lineLimit(1).help(group.id)
                    Text("\(group.runs.count) 次运行 · \(ids.count) 条可移除 · 已选 \(selectedCount) 条").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(!ids.isEmpty && ids.isSubset(of: selection) ? "取消本组选中" : "全选本组") {
                    if ids.isSubset(of: selection) { selection.subtract(ids) }
                    else { selection.formUnion(ids) }
                }.buttonStyle(.borderless).disabled(loading || ids.isEmpty)
            }
        }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
    func runRow(_ row: ScheduledRunInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("选择 \(row.title)", isOn: Binding(
                get: { selection.contains(row.id) },
                set: { if $0 { selection.insert(row.id) } else { selection.remove(row.id) } }
            )).labelsHidden().toggleStyle(.checkbox).disabled(loading || !row.canRemove)
            VStack(alignment: .leading, spacing: 5) {
                Text(row.title).font(.subheadline.weight(.medium))
                Text(Date(timeIntervalSince1970: row.lastActivity / 1000).formatted(date: .abbreviated, time: .shortened)).font(.caption)
                Text(row.project).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(row.blockedReason ?? "已结束 · 可移除列表记录").font(.caption).foregroundStyle(row.canRemove ? Color.secondary : Color.orange)
                Text("\(row.owners.count) 个账户副本").font(.caption2).foregroundStyle(.secondary).help(row.owners.joined(separator: "\n"))
            }
            Spacer()
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
    }
    func load() async {
        guard !loading else { return }
        loading = true; error = nil
        let engine = model.engine
        do {
            records = try await Task.detached { try engine.scheduledRuns() }.value
            if !task.isEmpty && !records.contains(where: { $0.taskID == task }) { task = "" }
            if !owner.isEmpty && !records.contains(where: { $0.owners.contains(owner) }) { owner = "" }
            selection.formIntersection(removableIDs)
            expandedTasks.formIntersection(records.map(\.taskID))
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    func prepare() {
        guard !loading else { return }
        loading = true; error = nil
        let engine = model.engine, ids = selection.sorted()
        Task {
            do { preview = try await Task.detached { try engine.previewScheduledRunRemoval(ids: ids) }.value }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

private struct ScheduledRunGroup: Identifiable {
    let id: String
    let runs: [ScheduledRunInfo]
    var lastActivity: Double { runs.first?.lastActivity ?? 0 }
    var removableIDs: Set<String> { Set(runs.filter(\.canRemove).map(\.id)) }
}

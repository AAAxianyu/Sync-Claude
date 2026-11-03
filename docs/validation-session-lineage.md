# Claude Code 侧栏会话树修复（待发布）

验证日期：2026-11-03。对应用户截图中的展开子会话列表和紫色分叉标记。当前公开 v0.1.6 尚未包含此修复。

## 原因与原生格式依据

`History.merge` 旧导入白名单未包含 `spawnedFrom`、`forkedFromSessionId`、`forkedAtMessageUuid`、`lineageDetached`。这些字段位于账户/工作区内的 `local_<uuid>.json`，而正文仍通过原有 `cliSessionId` 读取共享 JSONL，因此会出现内容仍在但侧栏层级丢失。已有目标记录又被跳过，后续同步不能自动补回关系。

只读检查当前安装 Claude Desktop 4.4212.0 的 app.asar，并对照此前保存的 4.29.0 模块：

- 原生元数据序列化/反序列化保留上述四个字段。
- 侧栏父关系解析首先尊重 `lineageDetached`；随后区分 `sideSession`、`userFork`、`handOff`、显式分叉与建议任务，并使用 `deletedParent` 处理已删除父会话的关系。
- 4.4212.0 模块 `index.chunk-BReS2dO4.js` 的 SHA-256 为 `9d5d663e167752a62bca6fc7c0a202155ad7bbd4ab1a0d6915fcf55bd0a7be73`，4.29.0 缓存模块 `index.chunk-BaALgXPu.js` 为 `e827a977ce212a86f421f5f87d67338ff8928dc60aa81bad17e8516f749408a9`。不修改或分发客户端模块。

## 修复行为

- 新导入记录保留本地父会话 ID、分叉消息 UUID、脱离层级状态，以及 `spawnedFrom` 内的 `sessionId`、`taskId`、`name`、`title`、`sideSession`、`userFork`、`handOff`、`btw`、`deletedParent`。
- 不复制 `wakeParent`、`sharedCheckout`、`sharedFolder`、权限批准或其他执行状态。新记录沿用默认权限；已有记录保留目标自己的权限、标题和设置。
- 仅修复完全没有会话树字段的旧副本；已有明确父关系或 `lineageDetached` 保持不变。与定时任务关联修复在同一事务中完成。
- 关联来源必须同时匹配 `sessionId` 和 `cliSessionId`。优先使用仍保留关联的当前原始记录；没有时才使用该会话经过内容哈希核验的历史版本，不只依赖可能已经指向无关联副本的最新索引。
- 同优先级来源按 `lastActivityAt` 选择较新版本；最新版本结构冲突时停止，不按目录顺序猜测。当前显式脱离状态可以优先于旧归档，因为层级操作不一定更新正文活动时间。
- 写入前校验目标工作区的结果图，拒绝新增循环。找不到父记录或父会话已删除时保留原始引用但不复活父记录；删除同步继续生效。
- 所有修复通过现有写前备份/事务恢复，成功提示包含修复的副本数量。找不到有效来源的记录保持原状，不从标题或正文推断关联。

## 验证

- 修复接入前，两项代表性回归测试出现 5 个失败断言，复现新导入丢失层级和旧导入不修复。
- 新增 16 项回归，覆盖四层会话树、个人/团队多工作区、官方账号往返切换、重复同步、旧副本和旧归档恢复、CLI 身份不匹配、SSH 目标保护、脱离/重新挂接选择、分叉种类与已删除父关系、来源冲突、循环、归档篡改、非法关联和部分写入中断恢复。
- `swift test`：Claude 4.29.0 适配配置，共 154 项通过。
- `SYNC_CLAUDE_TEST_DESKTOP_VERSION=4.4212.0 swift test`：共 154 项通过。
- `zsh scripts/build-app.sh`：Release 构建与 ad-hoc 签名通过，`codesign --verify --deep --strict` 通过。这是未发布的开发构建，没有新增公证发行包。
- 使用隔离 home、8 条合成会话、两个目标工作区和 FakeProcess，实际运行 Engine 同步，分别得到旧副本修复和新导入结果。把前后数据交给两个版本的原生侧栏解析函数：`userLinksAttach` 开/关均通过，6 条有效父链接及 fork/side_session/hand_off/suggested_task 分类与原始记录一致；旧版副本在修复前全部无父链接。此项是原生函数回放，不是客户端 UI 验收。

本地证据保留在忽略目录：`.build/lineage-regression-before.log`、`.build/lineage-regression-after.log`、`.build/lineage-tests-final-4.29.0.log`、`.build/lineage-tests-final-4.4212.0.log`、`.build/lineage-build-final.log`、`.build/lineage-oracle/`。原生模块只读研究证据在 `.build/subtask-research-4.4212.0/`。不提交用户账号、会话元数据或正文。

## 验收边界

没有切换用户真实账号、改写用户历史、替换已安装应用或发布新版。当前证据证明同步逻辑及客户端解析函数能保留树关系；截图中具体任务在真实客户端的显示仍需新版安装后确认。无法从本机记录/归档找回的关系不会自动重建。项目收藏和用户自定义侧栏分组仍不在此修复范围。

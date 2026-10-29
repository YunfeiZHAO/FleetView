# 网页 chat 停在上下文压缩那一刻

| 字段 | 内容 |
|---|---|
| 发现日期 | 2026-10-26 |
| 状态 | 已修复（build 229 部署） |
| 影响 | 一张 Claude 卡片的网页 chat 停在 07:46，之后一个多小时的对话（含最终结果表）在网页上看不到；终端里一切正常 |
| 对应代码版本 | `9d1498b`（运行中的是 build 214 = `6fb77ea`，这段代码两者相同） |
| 修复 | `Sources/FleetView/Remote/Conversation.swift`：`activePath`、`latestUserText`（`70e76a7`） |

## 现象

卡片「cowork dependency samples」（qwen_cowork，terminal `B4CD3E07-047E-4328-BBB6-0FC58704E246`，会话 `69bf53d0-6db9-4122-ad48-7463fef9fb91`）。终端屏幕上最后是 08:52 的结果表，网页 chat 的最后一条是 07:46:06 的一个工具调用，之后不再更新。

`GET /conversation?id=B4CD3E07…` 返回的 `info.session` 是正确的 `69bf53d0…`，所以不是认错了 transcript。文件本身已经写到 08:52:28，是解析时把 07:46 之后的记录全部当成了「另一个分支」过滤掉了。

## 经过（transcript 记录）

| 时间 | 事件 |
|---|---|
| 07:45:15 | 用户输入提示（「DA 的 CRM 数据：…」），这也是卡片的 `lastPrompt` |
| 07:45:57 – 07:46:19 | 几次工具调用。最后一条是 `attachment/environment`（`7b82e9a0`） |
| 07:47:51 | 自动压缩（`trigger: auto`，969,666 → 12,353 token）。`compact_boundary` 的 `parentUuid` 是 null，`preservedMessages.allUuids` 列出原样保留的 7 条，包括 `7b82e9a0` |
| 07:47 – 08:49 | 同一轮继续工作，期间收到后台任务的 `<task-notification>` |
| 08:52:28 | 本轮结束 |

## 根因

`Conversation.activePath` 要先从 transcript 的树里挑出当前分支的末端。挑法是：在所有叶子（没有子记录的记录）里，从新到旧找第一个「往回走遇到的最近一条 user 文本等于这张卡的 `lastPrompt`」的叶子。这是为了处理多张卡 resume 同一会话、共用一个文件的情况。

压缩让这个挑法选错了，原因有两层：

1. **压缩留下的假叶子。** Claude Code 压缩时原样保留最新的几条记录，但这些记录留在边界之前的旧链里，只有最后一条还没写盘的（这里是 `68b205d8`）写在边界之后、挂到摘要下面。于是旧链上剩下的最后一条（`7b82e9a0`）在硬盘上没有子记录，看起来像一根被放弃的分支的末端。实际上对话带着它进入了压缩后的会话。TreeGraph 早就处理过同一现象（见 `continuesFrom` 的注释：2.1.280 在 162 个边界里有 154 个这样写），网页 chat 的解析没有处理。
2. **真正的末端匹配不上提问。** 从 08:52 的真正末端往回走，最先遇到的 user 文本是后台任务通知；就算没有通知，也会先遇到压缩摘要（「This session is being continued from a previous conversation…」）。用户输入的那条提示在压缩边界之前，从这边走不到。

结果是真正的末端匹配失败，而假叶子往回走正好遇到那条提示，匹配成功。当前分支就被定成了到 07:46:19 为止的旧链，之后的记录全被过滤掉。只要压缩发生在用户最后一次输入之后的同一轮里，就会出现这种情况，直到用户再输入一次为止。

## 修复

- `activePath`：读出每个 `compact_boundary` 的 `logicalParentUuid` 和 `preservedMessages`（`allUuids`，没有就用 `uuids`），这些记录不算分支末端。本例里候选叶子只剩真正的末端，匹配失败后走原有的回退逻辑（`last-prompt` 的 `leafUuid` 往下走到底），得到正确的分支。
- `latestUserText`：跳过不是人输入的 user 记录，包括 `isMeta`、`isCompactSummary`、`promptSource: "system"`，以及以 `<task-notification` 开头的文本（旧版本只靠这个包装标记）。规则和 TreeGraph 的 `injected` 一致。没有压缩的会话里，后台通知不会再让真正的末端匹配不上自己的提示。

## 验证

- 把 `Conversation.swift` 的新旧两版分别和一个小 harness 单独编译（`AgentHome`/`FV`/`RemoteServer` 用桩代替），对这个 transcript 调 `Conversation.parse`，传入卡片自己的 `lastPrompt`：旧版最后一条是 07:46:06，和网页上看到的一致；新版最后一条是 08:52:28，和终端一致。
- 回归：state.json 里 17 张有 Claude transcript 的卡片，新旧输出逐字节相同的 16 张，不同的只有这一张。硬盘上最近修改的 400 个 Claude transcript（ownPrompt 取 `history.jsonl` 里该会话最后一次输入），398 个相同。另外 2 个不同：一个是本例，另一个是 10-21 的 `0d1ae69f`，旧版停在 14:07:47，新版到文件末尾 14:14:41，是同一个问题。
- `swift build` 通过。
- 部署后（2026-10-26 19:58，build 229）在运行中的 FleetView 上：`GET /conversation?id=B4CD3E07…` 返回 81 条，最后一条是 08:52:28 的结果表，和终端一致。

## 没覆盖的

- 压缩之后，网页 chat 只显示边界之后的记录：摘要作为一条 user 消息，加上之后的对话。边界之前原样保留的那几条不会接到摘要后面显示（CLI 会显示）。这次没有改。
- 多张卡共用一个已压缩会话时，提示匹配不能跨过压缩边界，所有卡都会走回退逻辑，显示最新的分支。

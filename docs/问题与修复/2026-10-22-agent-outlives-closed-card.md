# 关掉卡片后 agent 进程还在

| 字段 | 内容 |
|---|---|
| 发现日期 | 2026-10-22 |
| 状态 | 已修复（build 229 部署） |
| 影响 | 一个已关闭卡片背后的 Claude 继续运行了 46 小时：占满一个 CPU 核，一直占着一个 sub-pool 租约，同一会话同时存在两个进程。board 上看不出任何异常 |
| 对应代码版本 | `6fb77ea`（工作区另有其他会话未提交的改动） |
| 修复 | 新增 `Sources/FleetView/Support/ProcessReaper.swift`；修改 `Sources/FleetView/Remote/RemoteServer.swift`（`stop`、`killAllSessions`）、`Sources/FleetView/Headless.swift`（`AppStartup.stop`）。未提交 |

## 现象

board 已经清空，但 `ps | grep sp-claude` 还能看到一串进程。逐个查过之后，真正的残留只有两组，其余是当时正在用的会话本身。

1. PID 90622 的 `sp-claude --resume 81fb8dee-b6d5-46a1-9010-76aa54921283`，以及它的子进程 claude 90631。
   - 父进程已经是 launchd（ppid 1），没有控制终端，fd 0/1/2 都已关闭。
   - 运行了 1 天 22 小时，CPU 时间累计 1539 分钟，当时占用 97%。
   - `sample` 显示主线程在 JIT 代码里做很深的递归，没有在等 I/O，是在空转。
   - 到 API 代理（127.0.0.1:7897）的连接处于 CLOSE_WAIT，说明已经没有在调用模型。
   - 外层 sp-claude 和代理之间还有一条 ESTABLISHED 连接。它的临时 home `/tmp/sp-claude-1zq90x51/.credentials.json` 修改时间是 10-22 15:59，说明租约还在被刷新。
   - claude 下面挂着两个后台 shell（30858、41345），都是 `until …; do sleep 3; done`，等的是 code_sense 里永远不会再出现的文件。
2. PID 80031 那组（同一进程组里还有 80030、80032）：`tail -F jobs/opus55h_cs204v200_r1.launch.log | ugrep …`，外加一个 `while true … sleep 60` 循环。这是会话 `/tmp/sp-claude-_2iiwdaz` 启动的后台 shell，已经跑了 5 天 12 小时，所属的 claude 早已不在，临时目录也已删除。

另外还有 4 个和关卡片无关的残留，是 agent 在工作中用 `&`/nohup 起的服务，起它们的 shell 退出后被 launchd 收养：
- datagen-vision2web scratchpad 里的 Django `runserver 0.0.0.0:41401`（1 天）
- FleetView 某次会话 scratchpad/webtest 里的 `srv.py page.html 8793` 和 `server.py page.html 8791`（4 天）
- `~/Documents/Codex/2026-10-15/nin/outputs/vision2web-batch2-fix` 里的 `compress_traces.py`（3 天）

## 经过（审计日志 `~/.fleetview/logs/audit-2026-10-2*.jsonl`）

卡片是 code_sense 项目的「15个新的任务」，terminal id `A8932880-0871-42E3-835F-9D1C6472A5B7`。

| 时间 | 事件 |
|---|---|
| 10-21 00:41:54 | 卡片创建（fork 出来的，原名「⑂ 你连局域网的air测试」）；00:41:58 起 sp-claude 90622 → claude 90631 |
| 10-21 12:06 | 会话 compact |
| 10-21 约 13:18、14:05 | 起两个 `until` 后台 shell |
| 10-21 15:45:58 | working → idle |
| 10-21 15:46:34 | idle → closed：窗口被关，`RemoteServer.stop` 执行了 `kill-session` |
| 10-21 15:46:36 | 点了这张卡，`reopenTerminal` 重开 |
| 10-21 15:46:38 | 新 pane 里执行 `sp-claude --resume 81fb8dee…`，第二个进程开始在同一会话上工作 |
| 10-22 18:00 | 第二个进程最后一轮结束 |
| 10-22 23:01:11 | 卡片被移除，第二个进程正常退出 |
| 10-22 约 23:18 | 手动 SIGKILL 90631；90622 随后自己收尾退出，删掉了临时目录，归还了租约 |

也就是说，从 15:46:34 开始卡片显示 closed，但第一个进程一直没退。之后两天里，同一个会话背后始终有两个 claude。

## 根因

FleetView 这边：关卡片只做一件事，`tmux kill-session`（Close All 是 `kill-server`）。pty 关闭后，前台进程组收到 SIGHUP，FleetView 指望 agent 收到后自己退出，之后不再检查。CLAUDE.md 写的「a card that says "closed" means the agent behind it is stopped」，实际上没有任何代码在保证。

sp-claude 这边：它给 SIGINT/SIGTERM/SIGHUP 都装了处理函数，收到后转发给 claude，然后无限期 `await proc.wait()`（`sub_pool_client/_cli_core.py`）。它从不升级成 SIGKILL，所以 claude 不退，它也不退，租约就一直挂着。

Claude 这边：claude 2.1.280 收到挂断后关掉了自己的终端 fd，但没有退出，主线程进入死循环。触发条件没有复现出来。在隔离的 `tmux -L fvtest` 里我试了三种情况，kill-session 后都在几秒内退干净了，后台 shell 也一起被清掉：
- 空闲的 claude
- 有 `run_in_background` 任务在跑的 claude
- 和 FleetView 结构一样的 zsh → sp-claude → 有后台任务的 claude

出事的会话很大（transcript 19.7 MB，累计约 2985 万 token，做过 compact，开过很多 subagent），可能和这个有关，但没有证据。二进制没有符号，`sample` 只能看到递归的形状。

80031 那组的来历查不到：它的 claude 退出时没有带走后台 shell。正常的 SIGHUP 退出会清掉后台 shell（上面的测试验证过），所以那个 claude 大概率是被硬杀或崩溃的。

## 修复

`ProcessReaper`：kill 之前把进程记下来，kill 之后再检查一遍。

kill 之前（主线程上同步执行，在真实进程表上 1 ms 以内）：
1. `tmux list-panes -s -t <session> -F '#{pane_pid}'`（Close All 用 `list-panes -a`）拿到 pane 进程。tmux 给每个 pane 都 setsid，所以 pane 进程就是一个会话的 leader。
2. 用 `sysctl(KERN_PROC_ALL)` 读出本用户的全部进程，再对每个进程调 `getsid`。
3. 记下这些进程：
   - pane 会话里的所有进程：shell、agent、包着 agent 的 sp-claude、MCP server 等；
   - 父进程在 pane 会话里、自己是另一个会话 leader 的进程，连同它整个会话。这就是 agent 的后台 shell：Claude 的 `run_in_background` 会 setsid，pane 的会话管不到它们，而且它们起的子进程即使被 launchd 收养，也还留在那个会话里。
4. 以上进程里，命令行自称 daemon 的（参数里有单独的 `daemon`，或者含 `daemon`、以 `--bg` 开头的 flag）连同其后代一律排除。这类进程是故意启动来长期存在的，比如 Codex 的 `app-server --managed-daemon` / `app-server daemon pid-update-loop`，以及 Claude 的 `daemon run`、`--daemon-worker`、`--bg-pty-host`。同一个 home 下的 agent 共用一个 daemon，关一张卡不能把它一起杀掉。验证时看到 Codex 的 app-server 在 codex 退出后照样在跑，ppid 变成了 1。
5. 每个进程按 (pid, 启动时间) 记录，后面每次发信号前都核对启动时间，避免 pid 被复用后误杀。

kill 之后（后台线程，每 0.1 秒看一次，全部消失就立刻结束）：
1. 给挂断 3 秒。正常的 agent 这时已经退干净，什么日志都不会写。
2. 还活着的进程全部发 SIGTERM，在 `~/.fleetview/fleetview.log` 写一行 `reaper: N process(es) outlived the hangup of …`。
3. 再过 3 秒，对仍然活着的最内层进程发 SIGKILL。这里的「最内层」只看同一会话内的父子关系：sp-claude 在 claude 的会话里，算包装进程，先不杀；卡死的 claude 只是后台 shell 的父进程，不同会话，不算。最初的写法没有区分会话，结果卡死的 agent 因为「有子进程」被当成包装进程，和真正的包装进程在同一时刻被杀，sp-claude 来不及归还租约。测试抓到了这个问题，已经改掉。
4. 再给包装进程 2 秒自己收尾（sp-claude 在 claude 退出后会写回 home、删临时目录、释放租约），然后对剩下的全部 SIGKILL。
5. 每轮都会把存活进程新起的子进程（daemon 除外）一并纳入。
6. 结束时写审计事件 `fleetview.terminal.reaped`（category `process`）。数据里有被处理的进程列表、用过的信号、SIGKILL 之后仍存活的进程数；有存活就记为 failure。

退出 FleetView：上面的计时器会随进程一起消失。`AppStartup.stop` 因此会等待未完成的清理，最多 10 秒。只有刚关过卡片（包括 `closeTerminalsOnQuit` 触发的 Close All）而进程还没退干净时，才真的需要等；正常情况下立即返回。不开 `closeTerminalsOnQuit` 的普通退出不会 kill 任何 session，也就没有东西可等。

关卡片、Remove Terminal、拖到别的项目（会先关再 `--resume` 重开）、Close All 都走 `RemoteServer.stop` / `killAllSessions`，所以都覆盖到了。重开后的新 pane 不是旧进程的后代，不会被误伤；这恰好就是这次「关了马上又点开」的情况。

## 验证

单独用 swiftc 把 `ProcessReaper.swift` 和一个小 harness 编译在一起（链接已编好的 `FleetViewAudit` 目标文件），在 `tmux -L fvtest` 里跑，没有启动 FleetView。被测的进程结构和这次出事时一样：
- `wrapper.py`：模拟 sp-claude，只转发 HUP/TERM/INT 并等待，子进程退出后过 0.5 秒写一个标记文件；
- `wedged_agent.py`：忽略 SIGHUP 和 SIGTERM，把 0/1/2 指向 /dev/null，然后空转；
- 一个 `start_new_session` 的 `zsh -c 'until false; do sleep 1; done'`：模拟后台 shell；
- 一个带 `--managed-daemon` 参数的 python：模拟 daemon。

| 场景 | 结果 |
|---|---|
| 卡死的 agent，`kill-session` | 4 个进程熬过了挂断（包装进程、agent、后台 zsh、sleep）。SIGTERM 之后 agent 和后台 zsh 被 SIGKILL，包装进程自己退出并写出了标记文件；daemon 保留。共 6.9 秒 |
| `kill-server`：一个 session 是卡死的 agent，一个是真实的空闲 claude | 真实的 claude 收到挂断后自己退出，不在名单里；卡死的那组按上面的方式处理；daemon 保留；同机其他会话没受影响。6.7 秒 |
| 正常进程（`sleep 1000`），`kill-session` | 挂断后立即退出，清理器什么都没记，0.0 秒返回 |

`swift build` 通过。没有部署：生产 FleetView 不能被第二个实例替换，需要退出后用 `./scripts/package_app.sh --install` 安装。

## 没有覆盖的

- 关卡片之前就已经被 launchd 收养的进程，比如本次那 4 个服务。它们不在 pane 的进程树里；如果起它们的后台 shell 也已退出，就连会话都找不到了。只有当它们所在的后台 shell 会话在关卡片时还活着，才会被一起清掉。
- pane 会话里用 `nohup` 起、有意要扛过挂断的进程，也会在 3 秒后被清理。这是有意为之：卡片关掉，就意味着这个终端里的东西都停了。
- daemon 是按命令行识别的。以后出现命令行不自称 daemon、却又是多个 agent 共用的常驻进程，会被误杀；要在 `ProcessReaper.isDaemon` 里补上。
- Claude 为什么会在 SIGHUP 之后空转，没有查清。

## 以后怎么查

```sh
# 没有终端、父进程已是 launchd 的 agent
ps -axo pid,ppid,etime,%cpu,tty,command | awk '$2==1 && /claude|codex|sp-claude|sp-codex/'
# 清理器动过手的记录
grep 'reaper:' ~/.fleetview/fleetview.log
grep -h '"fleetview.terminal.reaped"' ~/.fleetview/logs/audit-*.jsonl
# 某个进程在哪个会话、是不是会话 leader（stat 里有 s）
ps -o pid,ppid,pgid,stat,tty,command -p <pid>
```

清理手法：sp-claude 下面的 claude 要 SIGKILL claude 本身，不要杀 sp-claude。这样 sp-claude 会正常收尾、归还租约；claude 也不会走退出流程，不会往一个已经被别的进程续写过的 transcript 里追加旧内容。后台 shell 自成进程组，用 `kill -TERM -<pgid>` 整组杀掉。

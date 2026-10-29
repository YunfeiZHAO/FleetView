# 关掉的终端窗口留下僵尸进程

| 字段 | 内容 |
|---|---|
| 发现日期 | 2026-10-30 |
| 状态 | 已修复（build 234 部署） |
| 影响 | 生产 FleetView（PID 58735，10-26 21:05 启动）名下累积了 42 个 `<defunct>` 子进程，每关掉一个终端窗口就多一个，直到 FleetView 退出才会被清掉。只占进程号，不占 CPU 和内存；本机每个用户的进程上限是 5333 |
| 对应代码版本 | `2e4f3b1` |
| 修复 | `Sources/FleetView/Terminal/TerminalWindowController.swift`：新增 `ChildReaper`，`windowWillClose` 在 SwiftTerm 没有回收子进程时自己回收 |

## 现象

另一个会话在排查机器上的残留进程时发现：37 个（到这次排查时是 42 个）僵尸进程，父进程都是 FleetView。最早的 10-26 生成，到 10-29 还在增加。

被移除卡片的 agent 本身没有残留。把所有 claude/codex 进程逐个往上找父进程，凡是不属于任何还活着的 fleetview pane 的，只剩 4 个 `codex app-server daemon`，这是 `ProcessReaper` 有意保留的。

## 怎么查到的

僵尸的命令行已经看不到了（`<defunct>`），只能从 PID 和启动时间推断它原来是什么：

- 有 17 个僵尸的 PID 落在 58754–58774 之间，启动时间是 21:05:23，比 FleetView 晚 1 秒。同一批 PID 里，58755、58768、58770、58771 还活着，命令行是 `tmux -L fleetview … new-session -A -s fv_<id>`。它们是启动时 `reconnectLiveTerminals` 给每张卡拉起的 tmux 客户端。这 4 张卡现在还在看板上，同一批里的另外 17 张后来被移除了。
- 从这次启动以来，审计日志里有 42 次 `terminal-removed`，和僵尸的数量一致。

所以僵尸是终端窗口里那个 `tmux attach` 客户端：窗口关掉后它已经退出了，但没人调用 `waitpid` 回收。

## 根因

`windowWillClose` 调用 `termView.process.terminate()` 来结束窗口的子进程。在 SwiftTerm 1.14.0 里：

- `LocalProcess.terminate()` 发出 SIGTERM，紧接着调用 `childStopped()`，而 `childStopped()` 会取消 `childMonitor`，也就是监听子进程退出的那个 dispatch source。
- `waitpid` 只在 `childMonitor` 的回调 `processTerminated()` 里调用。

监听在子进程真正退出之前就被取消了，所以没有任何代码回收它。移除卡片、关闭窗口、隐藏窗口（隐藏也是关窗口）都走这条路径。只有 shell 自己退出的情况（不经过 `terminate()`）会被正常回收。

## 修复

窗口关闭时，只要 SwiftTerm 没有报告过子进程退出，FleetView 就自己回收这个 pid（`ChildReaper.collect`）。`processTerminated` 只有在 SwiftTerm 自己 `waitpid` 之后才会被调用，所以用它来判断 SwiftTerm 有没有回收过（`childReaped`）。已经回收过的 pid 可能已被系统分配给别的进程，不能再等待。

回收的方式是轮询 `waitpid(pid, WNOHANG)`，间隔从 0.05 秒开始，每次乘 4，上限 60 秒。

第一版用的是 `DispatchSource.makeProcessSource(.exit)` 监听退出，再配合挂上监听后立刻检查一次。测试中 30 次里 30 次仍然留下僵尸：监听如果是在 SIGTERM 之后、子进程退出之前挂上的，就不会触发。加了日志输出以后时序变了，它又能触发，所以这个问题第一眼很像偶发。改成轮询以后就不依赖这个时序了。如果客户端不理 SIGTERM，代价是每分钟一次系统调用。

## 验证

在 scratchpad 里用同一版 SwiftTerm（`.build/checkouts/SwiftTerm`，v1.14.0）做了一个小程序：用 `LocalProcess` 起 `/bin/sleep 1000`，按 `windowWillClose` 的方式结束，1 秒后用 `ps` 看状态。`ChildReaper` 的代码从源文件原样抽出来。每种情况跑 30 次：

| 情况 | 结果 |
|---|---|
| 只 `terminate()`（旧代码） | 30/30 留下僵尸（`Z`） |
| `terminate()` + `ChildReaper`（新代码） | 30/30 进程已回收 |
| 子进程自己退出（`sh -c 'exit 3'`） | SwiftTerm 自己回收，`processTerminated` 被调用，`ChildReaper` 不介入 |

`swift build` 通过。

## 没有覆盖的

- 部署 build 234 时退出了旧实例，那 42 个僵尸随之消失；新实例重新接上 18 个窗口后，名下 0 个僵尸。修复本身是在上面的测试程序里验证的，没有为了验证去关用户的窗口。
- `LocalProcess` 的 `deinit` 也会取消 `childMonitor`。如果以后有路径不经过 `windowWillClose` 就释放了终端视图，同样的问题还会出现。

## 以后怎么查

```sh
# FleetView 名下的僵尸
ps -axo pid,ppid,stat,lstart,comm | awk 'NR==1 || $3 ~ /Z/'
# 和它同一批启动、还活着的兄弟进程，用来推断僵尸原来是什么
ps -axo pid,ppid,stat,lstart,command | awk -v p=<FleetView pid> '$2==p' | grep -v defunct
```

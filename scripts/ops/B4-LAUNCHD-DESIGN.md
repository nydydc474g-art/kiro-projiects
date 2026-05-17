# B.4 launchd 常驻运行设计

> 不是"写个 plist"。是把前台调试态的 ops-watcher 安全地转为 macOS launchd
> 管理的常驻进程，同时解决三个在前台模式下被掩盖的真问题。

## 三个真问题

### 问题 1：SR 启动顺序（代理未就绪时 started 通知丢失）

**现象**：macOS 重启后 launchd 立即拉起 ops-watcher，但 Shadowrocket（SR）
的 PacketTunnel.appex 还没起来 → `TELEGRAM_PROXY_URL=http://127.0.0.1:1082`
连接被拒 → started 通知 http_code=000 → 用户手机上看不到"watcher 上线了"。

**约束**：
- SR 是 GUI app（Login Item），不受 launchd 直接调度
- launchd plist 的 `KeepAlive` / `WatchPaths` 无法表达"等另一个 Login Item 就绪"
- 不能让 watcher 依赖 SR——SR 挂了 watcher 主流程不能停

**解决方案：启动延迟 + heartbeat 兜底**

1. plist 设 `ThrottleInterval=30`（进程退出后至少 30s 才重启，macOS 默认 10s）
2. ops-watcher.sh 新增 `--launchd` 入口，与前台 `main_loop` 等价但：
   - 启动时 sleep `$OPS_STARTUP_DELAY`（默认 15s，env 可覆盖）
   - sleep 期间不处理 request（只等代理端口就绪）
   - sleep 结束后正常 `load_telegram_env` + `notify_lifecycle started`
3. heartbeat（默认 6h，测试时 60s）是"三件事都活着"的端到端证明：
   - 如果 started 丢了，6h 内第一次 heartbeat 会到手机 → 间接确认 watcher 活着
   - 如果 heartbeat 也丢了 → 排查信号

**为什么不用 retry started**：
- retry 带来"多少次算放弃"的策略复杂度
- started 只是通知，不影响 watcher 主流程
- heartbeat 已经是兜底信号，丢一个 started 的损失 < retry 机制的复杂度

### 问题 2：fswatch 模式下 heartbeat 漏 tick

**现象**：当前 fswatch 模式下 heartbeat 只在"有文件事件唤醒时" check。如果
长时间（> HEARTBEAT_INTERVAL）没有 proposal 投递，fswatch 阻塞在 read，
`check_heartbeat` 不被执行 → 用户手机上 6h+ 没有 heartbeat → 误以为 watcher 死了。

**前台 polling 模式不存在这个问题**：每 2s 一个 tick，heartbeat 总能被 check。

**解决方案：混合模式（fswatch 做 proposal 感知 + 独立 timer tick 做心跳）**

```
main_loop (launchd mode)
    │
    ├── fswatch $REQUESTS_DIR  ──→  proposal 事件处理
    │                                 + check_lifecycle_edge
    │                                 + check_heartbeat
    │
    └── background: while true; do
            sleep $HEARTBEAT_CHECK_INTERVAL   # 默认 300s = 5 min
            check_heartbeat                   # 只有到间隔才真发
        done
```

实现方式：bash 后台子进程 `&` + trap 在 watcher 退出时 `kill` 子进程。

`HEARTBEAT_CHECK_INTERVAL`（默认 300s）是"多久 check 一次是否该发 heartbeat"：
- heartbeat 真正发送间隔仍由 `HEARTBEAT_INTERVAL`（默认 6h）控制
- 300s check 间隔意味着 heartbeat 最坏延迟 5 分钟——对 6h 间隔完全可接受
- 不用 1s 级别 check（浪费 CPU wakeup，macOS 笔记本场景有 power impact）

**为什么不用 fswatch timeout / 多路 read**：
- `fswatch` 没有 `--timeout` 选项（GNU inotifywait 有，fswatch 没有）
- bash `read -t` 在 `-d ''`（NUL delimiter）模式下行为在 bash 3.2 不可靠
- 后台 timer 子进程是最简、最可审计的方案

### 问题 3：前台调试态 vs 常驻态语义一致

**需求**：开发者在前台 `bash ops-watcher.sh` 调试时的行为必须和 launchd 拉起
时完全一致（除了 startup delay）。否则"在前台测过了"不能证明"launchd 下也行"。

**差异点清单 + 处理**：

| 维度 | 前台（当前） | launchd 常驻 | 处理 |
|------|-------------|-------------|------|
| stdout/stderr | 终端可见 | 重定向到日志 | plist `StandardOutPath` / `StandardErrorPath` |
| SIGINT | Ctrl-C → trap → stopped | 不会收到 SIGINT | trap SIGTERM（launchd 停服务发 SIGTERM） |
| SIGTERM | 手动 kill → trap → stopped | launchd unload → SIGTERM | 已有 trap，行为一致 |
| 启动延迟 | 无（人在终端看着） | 15s delay 等 SR | `--launchd` 入口独有 |
| 环境变量 | 继承 shell 环境 | launchd 最小环境 | plist `EnvironmentVariables` 显式设 PATH |
| CWD | 用户当前目录 | `/` (launchd 默认) | plist `WorkingDirectory` 设 $HOME/ai_sandbox |
| heartbeat timer | polling 天然覆盖 | 独立后台子进程 | `--launchd` 启用混合模式 |
| 进程崩溃 | 人看到退出 | launchd 自动重启 | plist `KeepAlive=true` + ThrottleInterval |
| kill -9 / OOM | 人发现 | launchd 重启 + 无 stopped 通知 | heartbeat 兜底（设计内盲区） |

**结论**：引入 `--launchd` 作为 launchd 专用入口点。与 `main_loop`（无参数）的
行为差异只有：startup delay + 混合 heartbeat timer。其余路径完全相同。

## plist 设计

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.caimin.ops-watcher</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/caimin/ai_sandbox/scripts/ops/ops-watcher.sh</string>
        <string>--launchd</string>
    </array>

    <key>WorkingDirectory</key>
    <string>/Users/caimin/ai_sandbox</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
        <key>HOME</key>
        <string>/Users/caimin</string>
    </dict>

    <key>KeepAlive</key>
    <true/>

    <key>ThrottleInterval</key>
    <integer>30</integer>

    <key>StandardOutPath</key>
    <string>/Users/caimin/ai_sandbox/ops_spool/ops-watcher.stdout.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/caimin/ai_sandbox/ops_spool/ops-watcher.stderr.log</string>

    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
```

### plist 字段说明

| 字段 | 值 | 原因 |
|------|-----|------|
| `Label` | `com.caimin.ops-watcher` | 全局唯一标识 |
| `ProgramArguments` | `bash ... --launchd` | 用 `--launchd` 入口（含 startup delay + 混合 timer） |
| `WorkingDirectory` | `~/ai_sandbox` | 脚本内 `$PROJECT_DIR` 默认值就是这里 |
| `EnvironmentVariables.PATH` | 含 `/opt/homebrew/bin` | Apple Silicon homebrew 的 jq/fswatch/docker 在这里 |
| `KeepAlive` | `true` | 进程退出（含崩溃）后 launchd 自动重启 |
| `ThrottleInterval` | `30` | 重启间隔下限 30s（避免快速死循环吃 CPU） |
| `StandardOutPath` | `ops_spool/...stdout.log` | 前台时打到终端的信息不丢 |
| `StandardErrorPath` | `ops_spool/...stderr.log` | bash 级别的 FATAL / 意外 stderr |
| `ProcessType` | `Background` | 告诉 macOS 这是低优先级后台进程（不竞争 QoS） |

### 安装 / 卸载命令

```bash
# 安装
cp scripts/ops/com.caimin.ops-watcher.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.caimin.ops-watcher.plist

# 查看状态
launchctl list | grep ops-watcher

# 停止（发 SIGTERM，触发 stopped 通知）
launchctl unload ~/Library/LaunchAgents/com.caimin.ops-watcher.plist

# 重新加载（更新 plist 后）
launchctl unload ~/Library/LaunchAgents/com.caimin.ops-watcher.plist
launchctl load ~/Library/LaunchAgents/com.caimin.ops-watcher.plist
```

### 前台调试时

```bash
# 前台模式（不变，和之前一样）
bash scripts/ops/ops-watcher.sh

# 如果想模拟 launchd 行为但在前台看输出：
bash scripts/ops/ops-watcher.sh --launchd
# （会有 15s startup delay，然后正常运行，Ctrl-C 仍然可用）
```

## ops-watcher.sh 需要的改动

### 新增 `--launchd` 入口（在 case 块加一条）

```bash
  --launchd)
    main_loop_launchd
    ;;
```

### 新增 `main_loop_launchd` 函数

与 `main_loop` 的差异：
1. 开头加 `sleep $OPS_STARTUP_DELAY`
2. 启动后台 heartbeat timer 子进程
3. trap 里加 `kill $HEARTBEAT_TIMER_PID` 清理子进程

```bash
# launchd 专用入口：startup delay + 混合 heartbeat timer
# 其余行为与 main_loop 完全一致
OPS_STARTUP_DELAY="${OPS_STARTUP_DELAY:-15}"
HEARTBEAT_CHECK_INTERVAL="${HEARTBEAT_CHECK_INTERVAL:-300}"

main_loop_launchd() {
  # 启动延迟：等待代理客户端就绪
  if [ "$OPS_STARTUP_DELAY" -gt 0 ]; then
    echo "[ops-watcher] launchd mode: waiting ${OPS_STARTUP_DELAY}s for proxy readiness..."
    sleep "$OPS_STARTUP_DELAY"
  fi

  ensure_dirs
  load_baseline
  check_snapshot_dir
  load_telegram_env
  write_event "info" "watcher started (launchd)" "" \
    "$(jq -n --arg pd "$PROJECT_DIR" --arg sd "$SNAPSHOT_DIR" --arg delay "$OPS_STARTUP_DELAY" \
      '{project_dir: $pd, snapshot_dir: $sd, startup_delay: $delay, mode: "launchd"}')"

  local snap_id
  snap_id=$(cat "$SNAPSHOT_DIR/.snapshot-id" 2>/dev/null || echo "unknown")
  notify_lifecycle "started" "snapshot=${snap_id}, mode=launchd"

  # 后台 heartbeat timer（解决 fswatch 阻塞时漏 tick 的问题）
  _heartbeat_timer() {
    while true; do
      sleep "$HEARTBEAT_CHECK_INTERVAL"
      check_heartbeat
    done
  }
  _heartbeat_timer &
  local HEARTBEAT_TIMER_PID=$!

  # 清理：watcher 退出时 kill 后台 timer + 发 stopped
  trap 'kill $HEARTBEAT_TIMER_PID 2>/dev/null; notify_lifecycle "stopped" "graceful shutdown"; exit 0' INT TERM

  check_lifecycle_edge

  echo "[ops-watcher] PROJECT_DIR=$PROJECT_DIR"
  echo "[ops-watcher] SNAPSHOT_DIR=$SNAPSHOT_DIR"
  echo "[ops-watcher] mode=launchd (heartbeat timer PID=$HEARTBEAT_TIMER_PID, interval=${HEARTBEAT_CHECK_INTERVAL}s)"
  echo "[ops-watcher] watching $REQUESTS_DIR"

  if command -v fswatch >/dev/null 2>&1; then
    echo "[ops-watcher] using fswatch + background heartbeat timer"
    check_heartbeat
    for id in $(list_pending_requests); do
      process_request "$id" || true
    done
    fswatch -0 "$REQUESTS_DIR" | while IFS= read -r -d '' _; do
      sleep 0.2
      check_lifecycle_edge
      check_heartbeat
      for id in $(list_pending_requests); do
        process_request "$id" || true
      done
    done
  else
    echo "[ops-watcher] fswatch missing, falling back to polling every ${POLL_INTERVAL}s"
    while true; do
      check_lifecycle_edge
      check_heartbeat
      for id in $(list_pending_requests); do
        process_request "$id" || true
      done
      sleep "$POLL_INTERVAL"
    done
  fi
}
```

## 已知盲区（设计内接受）

| 盲区 | 后果 | 兜底 |
|------|------|------|
| `kill -9` / OOM kill | 无 stopped 通知 | heartbeat 缺失 = 异常信号 |
| SR 启动 > 15s | started 通知丢 | heartbeat 6h 内兜底 |
| launchd 环境缺少工具 | watcher 启动 FATAL exit → 30s 后重试 | stderr.log 有记录 |
| stdout/stderr 日志无 rotation | 文件无限增长 | 手动或 newsyslog.conf（Phase 5） |

## 日志管理（简易方案，不在 B.4 实施）

launchd stdout/stderr 日志不自动 rotate。暂时用 `> ops-watcher.stdout.log`
手动清空或写个 cron 定期 truncate。正式 rotation 留到 Phase 5（低优先级，
文件增长速度很慢——每个 tick 一行 echo，每个 proposal 几行）。

## 测试验证清单（B.4 生产实测时用）

| # | 动作 | 期望 |
|---|------|------|
| 1 | `launchctl load ...plist` | watcher 15s 后发 started (http_code=200) |
| 2 | 等 HEARTBEAT_INTERVAL（测试用 60s） | 手机收到 heartbeat |
| 3 | `touch .ops-watcher.disabled` | 手机收到 disabled |
| 4 | `rm .ops-watcher.disabled` | 手机收到 resumed |
| 5 | `launchctl unload ...plist` | 手机收到 stopped |
| 6 | 再 `launchctl load` | watcher 重新 15s delay → started |
| 7 | `kill -9 <pid>` | launchd 30s 后重启 → 新 started（无 stopped for killed one） |
| 8 | `bash ops-watcher.sh`（前台，不加 --launchd） | 行为与之前完全一致（无 delay、polling heartbeat） |

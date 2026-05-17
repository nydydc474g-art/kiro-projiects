#!/bin/bash
# ops-watcher.sh
# Step A: 静态判定内核（不接 Telegram，不动 compose）
#
# 状态流（顺序固定）：
#   request detected
#     → .ops-watcher.disabled?           → disabled
#     → load manifest (jq parse)         → rejected (malformed)
#     → schema field present?            → rejected
#     → path in BLOCK list?              → blocked
#     → base_snapshot stale?             → stale
#     → conflict with pending?           → conflict
#         (supersedes 合法 → 旧 = superseded, 新继续)
#     → static scan compose globals?     → blocked
#     → manifest field whitelist?        → rejected
#     → isolated preflight ok?           → preflight_failed
#     → classify risk (LOW/MEDIUM/HIGH)
#     → accepted_for_review
#
# 关键抽象（B.1 hotfix v2）：
#   get_effective_status(id) = proposal 当前生命周期投影
#   任何决策（conflict 占位、supersedes target、未来 apply 队列）都通过此函数，
#   不直接读 <id>.json.status。详见函数注释 + OPS-WATCHER-DESIGN.md。
#
# 输出：
#   ops_spool/events.jsonl                每个动作一行 JSON
#   ops-results/<id>.json                 权威记录（含 manifest 完整副本）
#   ops-results/<id>.<status>.<risk>.summary   单行人/机两可读路标
#
# 调用：
#   ops-watcher.sh                        前台主循环（fswatch + fallback polling）
#   ops-watcher.sh --once <request-id>    单次处理调试用
#   ops-watcher.sh --process-all          一次性处理所有 pending request

set -eo pipefail

# ===== 配置 =====
PROJECT_DIR="${PROJECT_DIR:-$HOME/ai_sandbox}"
WORKSPACE_DIR="$PROJECT_DIR/agent_workspace"
# B.1: snapshot 物理位置从 agent_workspace/.snapshot/ 迁到 project root snapshot/
# OPS_SNAPSHOT_DIR 用于宿主机迁移期/调试时显式覆盖
SNAPSHOT_DIR="${OPS_SNAPSHOT_DIR:-$PROJECT_DIR/snapshot}"
PROPOSALS_DIR="$WORKSPACE_DIR/ops-proposals"
REQUESTS_DIR="$WORKSPACE_DIR/ops-requests"
RESULTS_DIR="$WORKSPACE_DIR/ops-results"
OPS_SPOOL_DIR="$PROJECT_DIR/ops_spool"
EVENTS_LOG="$OPS_SPOOL_DIR/events.jsonl"
PROPOSALS_ARCHIVE="$OPS_SPOOL_DIR/proposals"
DISABLED_FLAG="$PROJECT_DIR/.ops-watcher.disabled"
BASELINE_FILE="$PROJECT_DIR/scripts/ops/ops-baseline.json"

# B.2: Telegram 单向通知配置
TELEGRAM_ENV_FILE="$PROJECT_DIR/.ops-watcher.env"
NOTIFIED_FILE="$OPS_SPOOL_DIR/.notified.txt"   # proposal 通知幂等表（仅 proposal，不含 lifecycle 事件）
LIFECYCLE_STATE_FILE="$OPS_SPOOL_DIR/.lifecycle-state"  # 边沿检测：disabled / enabled
TELEGRAM_DISABLED=0  # load_telegram_env 可置 1 关闭通知（不影响 watcher 主流程）
# B.2 hotfix: 专用 Telegram 代理变量（替代曾用过的全局 HTTPS_PROXY）
# 设计意图：作用域局部化——watcher 未来加任何别的 HTTP 调用都不会被这个变量绑架
# 空值 = 直连 api.telegram.org（生产环境若宿主机能直连 telegram 即留空）
TELEGRAM_PROXY_URL=""
LAST_TELEGRAM_HTTP_CODE=""  # send_telegram_raw 写入；调用方读它写诊断日志

# Polling fallback interval (when fswatch absent)
POLL_INTERVAL=2

# sha256 工具
if command -v sha256sum >/dev/null 2>&1; then
  SHA256_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA256_CMD="shasum -a 256"
else
  echo "FATAL: neither sha256sum nor shasum found" >&2
  exit 1
fi

# ===== 工具函数 =====

ts_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

ensure_dirs() {
  mkdir -p "$RESULTS_DIR" "$OPS_SPOOL_DIR" "$PROPOSALS_ARCHIVE"
  # events.jsonl 不预创建，第一次 write_event 时再生成
}

# 写 ops_spool/events.jsonl 单行
write_event() {
  local level="$1" msg="$2"
  local id="${3:-}"
  local extra_json="${4:-}"
  [ -z "$extra_json" ] && extra_json='{}'
  ensure_dirs
  jq -n -c \
    --arg ts "$(ts_utc)" \
    --arg level "$level" \
    --arg msg "$msg" \
    --arg id "$id" \
    --argjson extra "$extra_json" \
    '{ts: $ts, level: $level, msg: $msg, proposal_id: $id} + $extra' \
    >> "$EVENTS_LOG"
}

# 文件 sha256
file_sha256() {
  $SHA256_CMD "$1" | awk '{print $1}'
}

# B.1 fix v2: proposal 当前生命周期投影（不只是初始裁决）
#
# Why: <id>.json 一旦写入即只读（协议不变量），但 proposal 实际状态会通过
# sibling 文件演进（.superseded.json 现在；.applied.json / .rolled_back.json 未来）。
# 任何 watcher 决策（conflict 占位、supersedes target 是否合法、未来 apply 队列）
# 都必须读 effective_status，不能直接读 .json.status——否则就会用过期视图判断当前。
#
# 一期 sibling: .superseded.json
# 未来 sibling: .applied.json / .rolled_back.json (Phase 4)
#
# Returns one of:
#   "" (proposal 不存在)
#   pending (有 proposal 目录但 watcher 还没处理出 result)
#   accepted_for_review / blocked / rejected / preflight_failed /
#   stale / conflict / disabled (来自 .json.status，无 sibling)
#   superseded (sibling 投影；可在 Phase 4 扩为 applied / rolled_back)
get_effective_status() {
  local id="$1"
  local proposal_dir="$PROPOSALS_DIR/$id"
  local result_file="$RESULTS_DIR/$id.json"

  # 不存在 = ""
  if [ ! -d "$proposal_dir" ]; then
    echo ""
    return 0
  fi

  # 没 result = pending（watcher 还没处理或 proposal 还没 submit）
  if [ ! -f "$result_file" ]; then
    echo "pending"
    return 0
  fi

  # sibling 优先（按 lifecycle 演进顺序检查）
  # 一期只有 superseded；Phase 4 在此处加 applied / rolled_back
  if [ -f "$RESULTS_DIR/$id.superseded.json" ]; then
    echo "superseded"
    return 0
  fi

  # 回落到初始裁决
  jq -r '.status // "unknown"' "$result_file" 2>/dev/null || echo "unknown"
}

# 加载 baseline
load_baseline() {
  if [ ! -f "$BASELINE_FILE" ]; then
    echo "FATAL: baseline file missing: $BASELINE_FILE" >&2
    exit 1
  fi
  if ! jq empty "$BASELINE_FILE" 2>/dev/null; then
    echo "FATAL: baseline file is not valid JSON: $BASELINE_FILE" >&2
    exit 1
  fi
}

# 启动自检：snapshot 目录存在且已初始化
# B.1: 提早失败 — 否则第一个 proposal 才会因为 snap_id=unknown 一路飘到 stale，事后难定位
check_snapshot_dir() {
  if [ ! -d "$SNAPSHOT_DIR" ]; then
    echo "FATAL: SNAPSHOT_DIR does not exist: $SNAPSHOT_DIR" >&2
    echo "       run: bash scripts/ops/init-snapshot.sh" >&2
    echo "       (or set OPS_SNAPSHOT_DIR to point at an existing snapshot tree)" >&2
    exit 1
  fi
  if [ ! -e "$SNAPSHOT_DIR/current" ]; then
    echo "FATAL: $SNAPSHOT_DIR/current missing — snapshot not initialized" >&2
    echo "       run: bash scripts/ops/init-snapshot.sh" >&2
    exit 1
  fi
  if [ ! -L "$SNAPSHOT_DIR/current" ]; then
    echo "FATAL: $SNAPSHOT_DIR/current is not a symlink (manual repair needed)" >&2
    exit 1
  fi
  if [ ! -f "$SNAPSHOT_DIR/.snapshot-id" ] || [ ! -f "$SNAPSHOT_DIR/.snapshot-hash" ]; then
    echo "FATAL: top-level snapshot metadata missing (.snapshot-id / .snapshot-hash)" >&2
    echo "       run: bash scripts/ops/init-snapshot.sh" >&2
    exit 1
  fi
}

# ===== 结果写入 =====

# write_result <id> <status> <risk_level> <reason> <details_json> <preflight_json>
# manifest 副本由读取 PROPOSALS_DIR/<id>/manifest.json 内嵌
write_result() {
  local id="$1" status="$2" risk_level="$3" reason="$4"
  local details_json="${5:-}"
  local preflight_json="${6:-}"
  [ -z "$details_json" ] && details_json='{}'
  [ -z "$preflight_json" ] && preflight_json='{}'

  ensure_dirs

  local proposal_dir="$PROPOSALS_DIR/$id"
  local manifest_json='null'
  if [ -f "$proposal_dir/manifest.json" ] && jq empty "$proposal_dir/manifest.json" 2>/dev/null; then
    manifest_json=$(cat "$proposal_dir/manifest.json")
  fi

  local result_file="$RESULTS_DIR/$id.json"
  local tmp
  tmp=$(mktemp "$RESULTS_DIR/.$id.XXXXXX")
  trap "rm -f '$tmp'" RETURN

  if ! jq -n \
    --arg id "$id" \
    --arg status "$status" \
    --arg risk "$risk_level" \
    --arg reason "$reason" \
    --arg ts "$(ts_utc)" \
    --argjson manifest "$manifest_json" \
    --argjson details "$details_json" \
    --argjson preflight "$preflight_json" \
    '{
      proposal_id: $id,
      status: $status,
      risk_level: $risk,
      reason: $reason,
      reviewed_at: $ts,
      watcher_step: "step_a_static_review",
      manifest: $manifest,
      details: $details,
      preflight: $preflight,
      applied_files: null
    }' > "$tmp"; then
    write_event "error" "FATAL: write_result render failed, refusing to publish" "$id" \
      "$(jq -n --arg s "$status" --arg r "$risk_level" '{status:$s, risk:$r}')"
    rm -f "$tmp"
    trap - RETURN
    return 1
  fi

  # 不变量：只有非空且合法 JSON 能发布到权威 result 位置；否则拒绝 notify/consume/archive。
  if [ ! -s "$tmp" ] || ! jq -e . "$tmp" >/dev/null 2>&1; then
    write_event "error" "FATAL: write_result produced invalid or empty JSON, refusing to publish" "$id" \
      "$(jq -n --arg s "$status" --arg r "$risk_level" '{status:$s, risk:$r}')"
    rm -f "$tmp"
    trap - RETURN
    return 1
  fi

  mv "$tmp" "$result_file"
  trap - RETURN

  # 写 summary 路标（派生视图，丢失可重建）
  write_summary "$id" "$status" "$risk_level"
}

# 派生视图：单行 summary
write_summary() {
  local id="$1" status="$2" risk_level="$3"
  local result_file="$RESULTS_DIR/$id.json"
  [ -f "$result_file" ] || return 0

  # 提取 changes 摘要：path 列表逗号连接
  local changes_summary
  changes_summary=$(jq -r '
    if .manifest and (.manifest.changes | length > 0) then
      [.manifest.changes[] | "\(.path) (\(.summary // "modify"))"] | join(", ")
    else
      "no changes"
    end
  ' "$result_file" 2>/dev/null || echo "(unparseable)")

  local reason
  reason=$(jq -r '.reason // ""' "$result_file" 2>/dev/null || echo "")

  local summary_file="$RESULTS_DIR/$id.${status}.${risk_level}.summary"
  printf '%s | %s | %s | %s | %s\n' "$id" "$status" "$risk_level" "$changes_summary" "$reason" > "$summary_file"
}

# 归档 proposal 到 ops_spool
archive_proposal() {
  local id="$1"
  local proposal_dir="$PROPOSALS_DIR/$id"
  [ -d "$proposal_dir" ] || return 0
  local archive_dir="$PROPOSALS_ARCHIVE/$id"
  mkdir -p "$archive_dir"
  cp -r "$proposal_dir/." "$archive_dir/" 2>/dev/null || true
}

# 消费 request 文件（处理完移到 .processed/）
consume_request() {
  local id="$1"
  local req="$REQUESTS_DIR/$id.json"
  if [ -f "$req" ]; then
    mkdir -p "$REQUESTS_DIR/.processed"
    mv "$req" "$REQUESTS_DIR/.processed/$id.json" 2>/dev/null || rm -f "$req"
  fi
}

# ===== B.2: Telegram 单向摘要通知 =====
#
# 设计边界（不可逾越）：
# 1. 单向：只 sendMessage，永远不调 getUpdates / 不开 webhook
# 2. 通知策略 = status × risk matrix（不只看 risk 档位）：
#    推送：accepted_for_review × {LOW,MEDIUM,HIGH}; blocked × BLOCK
#    静默（仅写 events.jsonl）：conflict / stale / rejected / preflight_failed /
#                               disabled / superseded
# 3. 幂等：proposal 通知用 (id, status, risk) 三元组去重，写 .notified.txt
#    幂等只在 sendMessage HTTP 200 之后才写——失败永不伪装为已通知
# 4. lifecycle 事件（started/stopped/disabled/resumed）不写幂等表
#    （否则 watcher 第二次启动就发不出 started）
# 5. 失败不阻断：Telegram POST 失败只写 events.jsonl ERROR，watcher 主流程不感知
# 6. superseded sibling 静默：依赖 Phase 4 apply 阶段二次 effective_status 校验兜底
#    （Telegram 只说"它曾值得看"，apply 必须查"它现在还值不值得 apply"）

# 启动时加载 Telegram env；权限不对则降级（不崩）
load_telegram_env() {
  if [ ! -f "$TELEGRAM_ENV_FILE" ]; then
    TELEGRAM_DISABLED=1
    write_event "warning" "telegram disabled: env file missing" "" \
      "$(jq -n --arg f "$TELEGRAM_ENV_FILE" '{env_file: $f, reason: "missing"}')"
    return 0
  fi

  local perms
  if [ "$(uname)" = "Darwin" ]; then
    perms=$(stat -f "%A" "$TELEGRAM_ENV_FILE" 2>/dev/null || echo "")
  else
    perms=$(stat -c "%a" "$TELEGRAM_ENV_FILE" 2>/dev/null || echo "")
  fi
  if [ "$perms" != "600" ]; then
    TELEGRAM_DISABLED=1
    write_event "warning" "telegram disabled: env file perms not 600" "" \
      "$(jq -n --arg f "$TELEGRAM_ENV_FILE" --arg p "$perms" '{env_file: $f, perms: $p, expected: "600"}')"
    return 0
  fi

  set -a
  # shellcheck disable=SC1090
  . "$TELEGRAM_ENV_FILE"
  set +a

  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    TELEGRAM_DISABLED=1
    write_event "warning" "telegram disabled: required vars missing" "" \
      '{"missing":"TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID"}'
    return 0
  fi

  # B.2 hotfix: 收下专用代理变量；空值 = 直连
  # 同时清理任何意外通过 env 文件 source 进来的全局 HTTPS_PROXY/HTTP_PROXY
  # （历史 .ops-watcher.env 可能残留 HTTPS_PROXY=...，避免它影响 watcher 内
  #  其他 curl 的行为；只用 TELEGRAM_PROXY_URL 显式传给 send_telegram_raw）
  TELEGRAM_PROXY_URL="${TELEGRAM_PROXY_URL:-}"
  unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy ALL_PROXY all_proxy

  TELEGRAM_DISABLED=0
}

# 决策：(status, risk) → 是否推送 proposal 通知
# 推送：accepted_for_review × LOW/MEDIUM/HIGH; blocked × BLOCK
# 其他全部静默
should_notify_proposal() {
  local status="$1" risk="$2"
  case "$status" in
    accepted_for_review)
      case "$risk" in
        LOW|MEDIUM|HIGH) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    blocked)
      [ "$risk" = "BLOCK" ] && return 0 || return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# 文案分层：LOW/MEDIUM/HIGH/BLOCK
# 不带 manifest 自由文本 hunks（防 agent 借 Telegram 留言）；reason 截断 200 字符
format_proposal_message() {
  local id="$1" status="$2" risk="$3"
  local result_file="$RESULTS_DIR/$id.json"
  [ -f "$result_file" ] || { echo "(missing result for $id)"; return; }

  local reason paths n_changes svcs
  reason=$(jq -r '.manifest.reason // ""' "$result_file" | head -c 200)
  paths=$(jq -r '[.manifest.changes[].path] | join(", ")' "$result_file" 2>/dev/null || echo "")
  n_changes=$(jq -r '[.manifest.changes[] | "\(.path) (\(.summary // "modify"))"] | join(", ")' "$result_file" 2>/dev/null || echo "")
  svcs=$(jq -r '.manifest.affected_services // [] | join(",")' "$result_file" 2>/dev/null || echo "")
  local watcher_reason
  watcher_reason=$(jq -r '.reason // ""' "$result_file" | head -c 200)

  local short="${id##*-}"  # 取 id 末段（hex 后缀）方便手机阅读

  case "$risk" in
    LOW)
      printf '✅ ops %s\n   %s · LOW · %s\n   %s\n   reason: %s\n   apply: ops %s' \
        "$short" "$status" "$svcs" "$n_changes" "$reason" "$short"
      ;;
    MEDIUM)
      printf '🟡 ops %s\n   %s · MEDIUM · %s\n   %s\n   reason: %s\n   apply: ops %s\n   diff:  ops-diff %s' \
        "$short" "$status" "$svcs" "$n_changes" "$reason" "$short" "$short"
      ;;
    HIGH)
      printf '🔴 ops %s · HIGH RISK — REVIEW CAREFULLY\n   %s · HIGH · %s\n   %s\n   reason: %s\n   review: ops-diff %s\n   apply (must use --high): ops-apply --high %s' \
        "$short" "$status" "$svcs" "$n_changes" "$reason" "$short" "$short"
      ;;
    BLOCK)
      printf '🚨 BLOCKED · ops %s — agent attempted invariant touch\n   reason: %s\n   path: %s\n   audit: ops-spool view %s\n   (no apply — review agent behavior)' \
        "$short" "$watcher_reason" "$paths" "$short"
      ;;
    *)
      printf 'ops %s · %s · %s\n   %s' "$short" "$status" "$risk" "$n_changes"
      ;;
  esac
}

# Telegram POST；成功返回 0，失败返回 1（调用方决定要不要记 events.jsonl）
# 失败不抛错——curl 退出非 0 是常态（网络抖动/token 错），不让 watcher 主流程崩
# B.2 hotfix: 暴露 LAST_TELEGRAM_HTTP_CODE 给调用方写诊断日志
#   000 = curl 连接失败（代理端口不通 / DNS / TLS 等）
#   200 = ok
#   401 = token 错；400/404 = chat_id 错；429 = rate limit
send_telegram_raw() {
  local text="$1"
  LAST_TELEGRAM_HTTP_CODE=""
  [ "$TELEGRAM_DISABLED" = "1" ] && return 1
  if ! command -v curl >/dev/null 2>&1; then
    LAST_TELEGRAM_HTTP_CODE="no_curl"
    return 1
  fi
  # B.2 hotfix: 显式 --proxy 而不是依赖 HTTPS_PROXY 环境变量
  # 1. 局部化：未来 watcher 加任何别的 curl 调用不会被这条代理绑架
  # 2. 可读性：从这一行就能看出 telegram 调用走不走代理、走哪个
  # 3. SR 端口飘移时只改 .ops-watcher.env 一行
  # bash 3.2 兼容：空数组展开 "${arr[@]}" 安全；不可用 ${arr[@]:-}
  local proxy_args
  proxy_args=()
  if [ -n "$TELEGRAM_PROXY_URL" ]; then
    proxy_args=(--proxy "$TELEGRAM_PROXY_URL")
  fi
  local http_code
  http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
    --max-time 10 \
    "${proxy_args[@]}" \
    -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "disable_web_page_preview=true" \
    2>/dev/null) || http_code="000"
  LAST_TELEGRAM_HTTP_CODE="$http_code"
  [ "$http_code" = "200" ] || return 1
  return 0
}

# 发 proposal 通知 + 幂等去重
# 关键：只有 sendMessage 成功才追加 .notified.txt
# 失败永远不写 .notified.txt——一次网络故障不能伪装成"已通知"
notify_proposal() {
  local id="$1" status="$2" risk="$3"
  [ "$TELEGRAM_DISABLED" = "1" ] && return 0
  should_notify_proposal "$status" "$risk" || return 0

  local key="${id}:${status}:${risk}"
  if [ -f "$NOTIFIED_FILE" ] && grep -qxF "$key" "$NOTIFIED_FILE"; then
    return 0
  fi

  local msg
  msg=$(format_proposal_message "$id" "$status" "$risk")

  if send_telegram_raw "$msg"; then
    mkdir -p "$(dirname "$NOTIFIED_FILE")"
    echo "$key" >> "$NOTIFIED_FILE"
    write_event "info" "telegram sent" "$id" \
      "$(jq -n --arg s "$status" --arg r "$risk" --arg c "$LAST_TELEGRAM_HTTP_CODE" \
        '{kind: "proposal", status: $s, risk: $r, http_code: $c}')"
  else
    # B.2 hotfix: 把 http_code 记进 events.jsonl 方便排查
    # 000 = 连接失败（代理端口不通最常见）/ 401 token 错 / 400 chat_id 错
    write_event "error" "telegram send failed" "$id" \
      "$(jq -n --arg s "$status" --arg r "$risk" --arg c "$LAST_TELEGRAM_HTTP_CODE" \
        '{kind: "proposal", status: $s, risk: $r, http_code: $c}')"
  fi
}

# Lifecycle 事件通知（不进幂等表）
# 边沿检测：disabled/resumed 只在 .ops-watcher.disabled 状态切换时发
# 当前 lifecycle state 存 .lifecycle-state（仅 enabled/disabled 两种）
notify_lifecycle() {
  local kind="$1"  # started | stopped | disabled | resumed
  local extra="${2:-}"
  [ "$TELEGRAM_DISABLED" = "1" ] && return 0

  local msg
  case "$kind" in
    started)
      msg="ℹ️ ops-watcher started"
      [ -n "$extra" ] && msg="$msg ($extra)"
      ;;
    stopped)
      msg="ℹ️ ops-watcher stopped"
      [ -n "$extra" ] && msg="$msg ($extra)"
      ;;
    disabled)
      msg="ℹ️ ops-watcher disabled (.ops-watcher.disabled touched, queue paused)"
      ;;
    resumed)
      msg="ℹ️ ops-watcher resumed (.ops-watcher.disabled removed, queue active)"
      ;;
    *)
      return 0
      ;;
  esac

  if send_telegram_raw "$msg"; then
    write_event "info" "telegram sent" "" \
      "$(jq -n --arg k "$kind" --arg c "$LAST_TELEGRAM_HTTP_CODE" \
        '{kind: "lifecycle", event: $k, http_code: $c}')"
  else
    write_event "error" "telegram send failed" "" \
      "$(jq -n --arg k "$kind" --arg c "$LAST_TELEGRAM_HTTP_CODE" \
        '{kind: "lifecycle", event: $k, http_code: $c}')"
  fi
}

# 边沿检测：调用前后比对 .ops-watcher.disabled 是否切换
# 只在切换瞬间发 disabled / resumed 通知
check_lifecycle_edge() {
  local current
  if [ -f "$DISABLED_FLAG" ]; then
    current="disabled"
  else
    current="enabled"
  fi

  local prev=""
  [ -f "$LIFECYCLE_STATE_FILE" ] && prev=$(cat "$LIFECYCLE_STATE_FILE" 2>/dev/null || echo "")

  if [ "$current" != "$prev" ]; then
    case "$current" in
      disabled) notify_lifecycle disabled ;;
      enabled)
        # 仅当 prev 是 disabled 时才算 resumed（首次启动 prev="" 不发 resumed）
        [ "$prev" = "disabled" ] && notify_lifecycle resumed
        ;;
    esac
    mkdir -p "$(dirname "$LIFECYCLE_STATE_FILE")"
    echo "$current" > "$LIFECYCLE_STATE_FILE"
  fi
}

# B.2 hotfix: heartbeat 端到端存活信号
#
# 为什么需要：lifecycle 通知只在边沿发——"watcher 还活着 + 代理通 + telegram 通"
# 三件事任一坏掉都没信号（守序的失败 = 沉默的失败）。heartbeat 每 N 小时发一次，
# 是端到端证明（错过 1 次 = 6h 内某环坏了）。
#
# 设计选择：
# - 不进 .notified.txt 幂等表（每次都发是设计目的，不需要去重）
# - 失败也推进 last 时间——不补发、不重试。错过 1 个 tick 就错过；下一个 tick
#   再试。这避免代理离线时 polling 模式 2 秒一次刷 events.jsonl error 洪流。
# - 缺失的 heartbeat 本身就是"出问题"信号——你 6h 没收到 heartbeat 就该排查
# - 默认 21600s = 6h（4 次/天，足够发现长时间死机；可通过 OPS_HEARTBEAT_INTERVAL 调）
#
# 不变量：heartbeat 永不写 .notified.txt（与 lifecycle 一致：proposal 才进幂等表）
HEARTBEAT_STATE_FILE="$OPS_SPOOL_DIR/.last-heartbeat"
HEARTBEAT_INTERVAL="${OPS_HEARTBEAT_INTERVAL:-21600}"  # 6h 默认

check_heartbeat() {
  [ "$TELEGRAM_DISABLED" = "1" ] && return 0

  local now last elapsed
  now=$(date -u +%s)
  last=0
  if [ -f "$HEARTBEAT_STATE_FILE" ]; then
    last=$(cat "$HEARTBEAT_STATE_FILE" 2>/dev/null || echo 0)
    # 防御：cat 出来非数字（文件被外部改坏）→ 视为 0 强制发一次
    case "$last" in
      ''|*[!0-9]*) last=0 ;;
    esac
  fi
  elapsed=$((now - last))
  [ "$elapsed" -lt "$HEARTBEAT_INTERVAL" ] && return 0

  # 收集状态：snapshot id / 待处理 request / 最近一次 result
  local snap_id queue last_proposal
  snap_id=$(cat "$SNAPSHOT_DIR/.snapshot-id" 2>/dev/null || echo "unknown")
  queue=$(find "$REQUESTS_DIR" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | wc -l | tr -d ' ')
  last_proposal=$(ls -t "$RESULTS_DIR"/*.json 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null | sed 's/\.json$//' || echo "")
  [ -z "$last_proposal" ] && last_proposal="none"
  # 截短 ID 显示（取最后 6 位 hex 后缀）
  local short
  if [ "$last_proposal" = "none" ]; then
    short="none"
  else
    short=$(echo "$last_proposal" | awk -F- '{print $NF}')
  fi

  local msg
  msg=$(printf "📊 watcher heartbeat\nsnapshot=%s queue=%s last=%s" \
    "$snap_id" "$queue" "$short")

  # 关键：无论成功失败都推进 last_time，避免代理临时挂掉时刷屏
  echo "$now" > "$HEARTBEAT_STATE_FILE"

  if send_telegram_raw "$msg"; then
    write_event "info" "heartbeat sent" "" \
      "$(jq -n --arg s "$snap_id" --arg q "$queue" --arg l "$last_proposal" --arg c "$LAST_TELEGRAM_HTTP_CODE" \
        '{kind: "heartbeat", snapshot_id: $s, queue: $q, last_proposal: $l, http_code: $c}')"
  else
    write_event "error" "heartbeat send failed" "" \
      "$(jq -n --arg s "$snap_id" --arg c "$LAST_TELEGRAM_HTTP_CODE" \
        '{kind: "heartbeat", snapshot_id: $s, http_code: $c}')"
  fi
}

# ===== 状态机：检查模块 =====

# 检查 disabled
check_disabled() {
  [ -f "$DISABLED_FLAG" ]
}

# 检查 manifest 可解析 + 必要字段
# 返回 0 = 通过；返回 1 = 失败（已写好 reason）
check_manifest_schema() {
  local id="$1" reason_var="$2"
  local manifest="$PROPOSALS_DIR/$id/manifest.json"

  if [ ! -f "$manifest" ]; then
    eval "$reason_var=\"manifest.json missing\""
    return 1
  fi
  if ! jq empty "$manifest" 2>/dev/null; then
    eval "$reason_var=\"manifest.json is not valid JSON\""
    return 1
  fi

  # 必填字段
  local required_fields=("proposal_id" "base_snapshot_id" "base_snapshot_hash" "reason" "expected_effect" "affected_services" "rebuild_strategy" "changes" "verification")
  for f in "${required_fields[@]}"; do
    local val
    val=$(jq -r ".${f} // empty" "$manifest")
    if [ -z "$val" ]; then
      eval "$reason_var=\"manifest field missing or empty: ${f}\""
      return 1
    fi
  done

  # 关键字段类型/非空
  local n_changes n_svcs
  n_changes=$(jq '.changes | length' "$manifest")
  if [ "$n_changes" = "0" ]; then
    eval "$reason_var=\"changes is empty\""
    return 1
  fi
  n_svcs=$(jq '.affected_services | length' "$manifest")
  if [ "$n_svcs" = "0" ]; then
    eval "$reason_var=\"affected_services is empty\""
    return 1
  fi
  local n_verifs
  n_verifs=$(jq '.verification | length' "$manifest")
  if [ "$n_verifs" = "0" ]; then
    eval "$reason_var=\"verification is empty (Phase 1.2 contract)\""
    return 1
  fi

  return 0
}

# A.1-2: candidate file 重验
# watcher 不信任 helper 写入的 manifest，重新校验候选文件本体：
#   - 必须存在
#   - 不能是 symlink
#   - 必须是普通文件
#   - 实际 sha256 必须等于 manifest 声明
#   - 全部 changes 都是 no-op vs snapshot 时拒绝
check_candidate_files() {
  local id="$1" reason_var="$2"
  local manifest="$PROPOSALS_DIR/$id/manifest.json"
  local proposal_dir="$PROPOSALS_DIR/$id"

  local n
  n=$(jq '.changes | length' "$manifest")
  local i=0
  local n_noop=0
  while [ $i -lt "$n" ]; do
    local p declared_sha
    p=$(jq -r ".changes[$i].path" "$manifest")
    declared_sha=$(jq -r ".changes[$i].sha256 // \"\"" "$manifest")
    local file="$proposal_dir/$p"

    # (a) 必须存在
    if [ ! -e "$file" ]; then
      eval "$reason_var=\"changes[$i].path '$p' missing in proposal dir\""
      return 1
    fi
    # (b) 不能是 symlink（在 -f 之前检查）
    if [ -L "$file" ]; then
      eval "$reason_var=\"changes[$i].path '$p' is a symlink (not allowed)\""
      return 1
    fi
    # (c) 必须是普通文件（拒绝 directory / device / fifo / 等）
    if [ ! -f "$file" ]; then
      eval "$reason_var=\"changes[$i].path '$p' is not a regular file\""
      return 1
    fi
    # (d) 实际 sha256 必须等于 declared
    if [ -n "$declared_sha" ]; then
      local actual_sha
      actual_sha=$(file_sha256 "$file")
      if [ "$actual_sha" != "$declared_sha" ]; then
        eval "$reason_var=\"changes[$i].path '$p' sha256 drift (manifest=$declared_sha, actual=$actual_sha)\""
        return 1
      fi
    fi
    # (e) no-op 统计：候选与 snapshot 内容完全相同
    local snap_file="$SNAPSHOT_DIR/current/$p"
    if [ -f "$snap_file" ]; then
      local snap_sha
      snap_sha=$(file_sha256 "$snap_file")
      if [ "$snap_sha" = "$(file_sha256 "$file")" ]; then
        n_noop=$((n_noop + 1))
      fi
    fi
    i=$((i + 1))
  done

  # (f) 全 no-op 拒绝
  if [ "$n_noop" -gt 0 ] && [ "$n_noop" = "$n" ]; then
    eval "$reason_var=\"all $n change(s) are no-op vs snapshot\""
    return 1
  fi

  return 0
}

# A.1-1: baseline invariant compare
# 仅当 changes 含 docker-compose.yml 时检查
# 拒绝场景：
#   - agent 服务的 read_only / cap_drop / security_opt / user 与 baseline 不一致
#   - agent 必须挂载的卷（baseline.agent_volumes_required）有任何一项缺失
# 工具缺失：
#   - 无 docker → 视为 inconclusive；compose 改动时拒绝（保守）
check_baseline_invariants() {
  local id="$1" reason_var="$2"
  local manifest="$PROPOSALS_DIR/$id/manifest.json"
  local proposal_dir="$PROPOSALS_DIR/$id"

  # 是否改了 compose
  local compose_in_proposal=""
  local n
  n=$(jq '.changes | length' "$manifest")
  local i=0
  while [ $i -lt "$n" ]; do
    local p
    p=$(jq -r ".changes[$i].path" "$manifest")
    if [ "$p" = "docker-compose.yml" ]; then
      compose_in_proposal="$proposal_dir/docker-compose.yml"
      break
    fi
    i=$((i + 1))
  done

  # 没改 compose 就不检查
  [ -z "$compose_in_proposal" ] && return 0
  [ -f "$compose_in_proposal" ] || return 0

  # 必须有 docker 才能验证 invariants（保守拒绝）
  if ! command -v docker >/dev/null 2>&1; then
    eval "$reason_var=\"compose changed but docker unavailable to verify baseline invariants\""
    return 1
  fi

  # 用 docker compose config 拿到结构化 JSON
  local compose_json
  if ! compose_json=$(docker compose -f "$compose_in_proposal" config --format json 2>/dev/null); then
    eval "$reason_var=\"compose config parse failed (cannot verify invariants)\""
    return 1
  fi

  # === 1. agent 服务安全字段比对 ===
  local expected actual

  # read_only
  expected=$(jq -r '.agent_service_invariants.read_only' "$BASELINE_FILE")
  actual=$(echo "$compose_json" | jq -r '.services.agent.read_only // false')
  if [ "$actual" != "$expected" ]; then
    eval "$reason_var=\"agent.read_only=$actual, baseline requires $expected\""
    return 1
  fi

  # cap_drop（必须包含 baseline 列出的所有项；不限制额外项）
  local required_caps
  required_caps=$(jq -r '.agent_service_invariants.cap_drop[]' "$BASELINE_FILE")
  while IFS= read -r cap; do
    [ -z "$cap" ] && continue
    if ! echo "$compose_json" | jq -e --arg c "$cap" '.services.agent.cap_drop | index($c)' >/dev/null 2>&1; then
      eval "$reason_var=\"agent.cap_drop missing required: $cap\""
      return 1
    fi
  done <<< "$required_caps"

  # security_opt（必须包含 baseline 列出的所有项）
  local required_secopts
  required_secopts=$(jq -r '.agent_service_invariants.security_opt_required[]' "$BASELINE_FILE")
  while IFS= read -r opt; do
    [ -z "$opt" ] && continue
    if ! echo "$compose_json" | jq -e --arg o "$opt" '.services.agent.security_opt | index($o)' >/dev/null 2>&1; then
      eval "$reason_var=\"agent.security_opt missing required: $opt\""
      return 1
    fi
  done <<< "$required_secopts"

  # user
  expected=$(jq -r '.agent_service_invariants.user' "$BASELINE_FILE")
  actual=$(echo "$compose_json" | jq -r '.services.agent.user // ""')
  if [ "$actual" != "$expected" ]; then
    eval "$reason_var=\"agent.user='$actual', baseline requires '$expected'\""
    return 1
  fi

  # === 2. agent 必须挂载的卷比对 ===
  # docker compose config 把 volumes 展开成对象数组（{type, source, target, read_only}）
  # 提取成 "<source>:<target>:<mode>" 字符串
  local mounts_normalized
  mounts_normalized=$(echo "$compose_json" | jq -r '
    .services.agent.volumes // [] | map(
      if type == "object" then
        "\(.source // "")" + ":" + "\(.target // "")" +
        (if .read_only then ":ro" else ":rw" end)
      else
        .
      end
    ) | .[]
  ')

  local required_vols
  required_vols=$(jq -r '.agent_volumes_required[]' "$BASELINE_FILE")
  while IFS= read -r req; do
    [ -z "$req" ] && continue
    # baseline 里是 "./agent_workspace:/app/workspace:rw"
    # 提取 target 和 mode；source 跳过（绝对/相对路径差异）
    local req_target req_mode
    req_target=$(echo "$req" | awk -F: '{print $2}')
    req_mode=$(echo "$req" | awk -F: '{print $3}')

    local found=0
    while IFS= read -r m; do
      [ -z "$m" ] && continue
      local m_target m_mode
      m_target=$(echo "$m" | awk -F: '{print $2}')
      m_mode=$(echo "$m" | awk -F: '{print $3}')
      if [ "$m_target" = "$req_target" ] && [ "$m_mode" = "$req_mode" ]; then
        found=1
        break
      fi
    done <<< "$mounts_normalized"

    if [ "$found" = "0" ]; then
      eval "$reason_var=\"agent missing required volume mount: $req\""
      return 1
    fi
  done <<< "$required_vols"

  return 0
}

# 检查 changes 中是否有 BLOCK 路径
check_block_paths() {
  local id="$1" reason_var="$2"
  local manifest="$PROPOSALS_DIR/$id/manifest.json"
  local block_re
  block_re=$(jq -r '.block_paths_in_changes_regex' "$BASELINE_FILE")

  local n
  n=$(jq '.changes | length' "$manifest")
  local i=0
  while [ $i -lt "$n" ]; do
    local p
    p=$(jq -r ".changes[$i].path" "$manifest")
    if echo "$p" | grep -qE "$block_re"; then
      eval "$reason_var=\"changes path '$p' touches BLOCK invariant (matches: $block_re)\""
      return 1
    fi
    i=$((i + 1))
  done
  return 0
}

# 检查 stale：base_snapshot_id 和 base_snapshot_hash 与 current 一致
check_stale() {
  local id="$1" reason_var="$2"
  local manifest="$PROPOSALS_DIR/$id/manifest.json"

  local cur_id_file="$SNAPSHOT_DIR/.snapshot-id"
  local cur_hash_file="$SNAPSHOT_DIR/.snapshot-hash"
  if [ ! -f "$cur_id_file" ] || [ ! -f "$cur_hash_file" ]; then
    eval "$reason_var=\"snapshot meta missing on host\""
    return 1
  fi

  local cur_id cur_hash base_id base_hash
  cur_id=$(cat "$cur_id_file")
  cur_hash=$(cat "$cur_hash_file")
  base_id=$(jq -r '.base_snapshot_id' "$manifest")
  base_hash=$(jq -r '.base_snapshot_hash' "$manifest")

  if [ "$base_id" != "$cur_id" ]; then
    eval "$reason_var=\"base_snapshot_id mismatch (proposal=$base_id, current=$cur_id)\""
    return 1
  fi
  if [ "$base_hash" != "$cur_hash" ]; then
    eval "$reason_var=\"base_snapshot_hash mismatch (proposal=$base_hash, current=$cur_hash)\""
    return 1
  fi
  return 0
}

# 检查 conflict（同 path 已有 pending proposal 且未声明 supersedes）
# 返回值：0=无冲突，1=conflict（reason 已写），2=合法 supersedes（superseded_id 已写）
check_conflict() {
  local id="$1" reason_var="$2" superseded_var="$3"
  local manifest="$PROPOSALS_DIR/$id/manifest.json"
  local supersedes
  supersedes=$(jq -r '.supersedes // empty' "$manifest")

  # 提取本 proposal 的 paths
  local our_paths
  our_paths=$(jq -r '.changes[].path' "$manifest" | sort -u)

  # B.1 fix v2: 通过 effective_status 抽象判定占位
  # 占位 = effective_status ∈ {accepted_for_review, pending}
  # （pending = 已 submit 还没出 result；accepted_for_review = 出了 result 仍占位）
  # 其他状态（superseded / blocked / rejected / preflight_failed / stale / conflict / disabled）
  # 都已闭合，不再占用任何路径
  #
  # supersedes target 必须当前仍占位（即 accepted_for_review；不能是 pending，因为
  # 一个还没被审查的 proposal 不应被新 proposal "替代"——新的应该等旧的先出结果）
  local pending_ids=()
  for d in "$PROPOSALS_DIR"/*/; do
    [ -d "$d" ] || continue
    local other
    other=$(basename "$d")
    [ "$other" = "$id" ] && continue
    # 必须真的提交过（有 submit request 痕迹）
    [ -f "$REQUESTS_DIR/$other.json" ] || [ -f "$REQUESTS_DIR/.processed/$other.json" ] || continue
    local other_eff
    other_eff=$(get_effective_status "$other")
    case "$other_eff" in
      accepted_for_review|pending)
        pending_ids+=("$other")
        ;;
      *)
        # 闭合状态（含 superseded / blocked / 等），跳过
        ;;
    esac
  done

  # 处理 supersedes 声明
  # 注意：supersedes target 必须 effective_status == accepted_for_review
  # （pending 不允许；闭合状态肯定不在 pending_ids 里所以也找不到）
  if [ -n "$supersedes" ]; then
    local target_eff
    target_eff=$(get_effective_status "$supersedes")
    if [ "$target_eff" != "accepted_for_review" ]; then
      eval "$reason_var=\"supersedes target '$supersedes' has effective_status='$target_eff' (must be accepted_for_review)\""
      return 1
    fi
  fi

  # 检查每个 pending 是否与本 proposal 路径冲突
  for pid in "${pending_ids[@]}"; do
    local other_paths
    other_paths=$(jq -r '.changes[].path' "$PROPOSALS_DIR/$pid/manifest.json" 2>/dev/null | sort -u)
    if [ -z "$other_paths" ]; then
      continue
    fi
    # 求交集
    local intersect
    intersect=$(comm -12 <(echo "$our_paths") <(echo "$other_paths") || true)
    if [ -n "$intersect" ]; then
      # 有路径重叠
      if [ "$pid" = "$supersedes" ]; then
        # 显式替代：旧的标记为 superseded
        eval "$superseded_var=\"$pid\""
        # 继续检查其他 pending
        continue
      else
        # 未声明替代 → conflict
        eval "$reason_var=\"path conflict with pending proposal '$pid' on: $(echo "$intersect" | tr '\n' ',' | sed 's/,$//')\""
        return 1
      fi
    fi
  done

  return 0
}

# 全局规则扫描：扫 compose / Dockerfile 是否有禁字段
# 注意：扫的是 proposal 内的 *候选* 文件（如果改了 docker-compose.yml）
# 没改这些文件就跳过
check_global_rules() {
  local id="$1" reason_var="$2"
  local manifest="$PROPOSALS_DIR/$id/manifest.json"
  local proposal_dir="$PROPOSALS_DIR/$id"

  # 改了 docker-compose.yml 才检查
  local compose_in_proposal=""
  local n
  n=$(jq '.changes | length' "$manifest")
  local i=0
  while [ $i -lt "$n" ]; do
    local p
    p=$(jq -r ".changes[$i].path" "$manifest")
    if [ "$p" = "docker-compose.yml" ]; then
      compose_in_proposal="$proposal_dir/docker-compose.yml"
      break
    fi
    i=$((i + 1))
  done

  if [ -n "$compose_in_proposal" ] && [ -f "$compose_in_proposal" ]; then
    # 扫禁字段
    local forbidden_keys
    forbidden_keys=$(jq -r '.global_forbidden_compose_keys[]' "$BASELINE_FILE")
    while IFS= read -r key; do
      [ -z "$key" ] && continue
      # 简单的"行级"检测：YAML 里出现 'key:' 或 'key :'
      if grep -qE "^[[:space:]]*${key}[[:space:]]*:" "$compose_in_proposal"; then
        eval "$reason_var=\"docker-compose.yml contains forbidden key: ${key}\""
        return 1
      fi
    done <<< "$forbidden_keys"

    # 扫禁挂载
    local forbidden_vols
    forbidden_vols=$(jq -r '.global_forbidden_volume_patterns[]' "$BASELINE_FILE")
    while IFS= read -r pat; do
      [ -z "$pat" ] && continue
      if grep -qE "$pat" "$compose_in_proposal"; then
        eval "$reason_var=\"docker-compose.yml volume matches forbidden pattern: ${pat}\""
        return 1
      fi
    done <<< "$forbidden_vols"

    # 扫禁网络模式
    local forbidden_nets
    forbidden_nets=$(jq -r '.global_forbidden_network_modes[]' "$BASELINE_FILE")
    while IFS= read -r mode; do
      [ -z "$mode" ] && continue
      if grep -qE "network_mode[[:space:]]*:[[:space:]]*['\"]?${mode}['\"]?" "$compose_in_proposal"; then
        eval "$reason_var=\"docker-compose.yml uses forbidden network_mode: ${mode}\""
        return 1
      fi
    done <<< "$forbidden_nets"

    # 扫禁命名空间模式
    local forbidden_ns
    forbidden_ns=$(jq -r '.global_forbidden_namespace_modes[]' "$BASELINE_FILE")
    while IFS= read -r ns_pat; do
      [ -z "$ns_pat" ] && continue
      if grep -qF "$ns_pat" "$compose_in_proposal"; then
        eval "$reason_var=\"docker-compose.yml contains forbidden namespace mode: ${ns_pat}\""
        return 1
      fi
    done <<< "$forbidden_ns"
  fi

  return 0
}

# manifest 字段白名单校验（路径 / 服务 / verification 名）
check_manifest_whitelists() {
  local id="$1" reason_var="$2"
  local manifest="$PROPOSALS_DIR/$id/manifest.json"

  local path_re
  path_re=$(jq -r '.allowed_proposal_paths_regex' "$BASELINE_FILE")

  # 路径白名单
  local n
  n=$(jq '.changes | length' "$manifest")
  local i=0
  while [ $i -lt "$n" ]; do
    local p
    p=$(jq -r ".changes[$i].path" "$manifest")
    if ! echo "$p" | grep -qE "$path_re"; then
      eval "$reason_var=\"changes[$i].path '$p' not in allowed_proposal_paths_regex\""
      return 1
    fi
    i=$((i + 1))
  done

  # 服务白名单
  local allowed_svcs_json
  allowed_svcs_json=$(jq -c '.allowed_services' "$BASELINE_FILE")
  local n_svcs
  n_svcs=$(jq '.affected_services | length' "$manifest")
  i=0
  while [ $i -lt "$n_svcs" ]; do
    local svc
    svc=$(jq -r ".affected_services[$i]" "$manifest")
    if ! echo "$allowed_svcs_json" | jq -e --arg s "$svc" 'index($s)' >/dev/null 2>&1; then
      eval "$reason_var=\"affected_services[$i]='$svc' not in allowed_services\""
      return 1
    fi
    i=$((i + 1))
  done

  # verification 名格式（Phase 5 之前不强制白名单）
  local n_verifs
  n_verifs=$(jq '.verification | length' "$manifest")
  i=0
  while [ $i -lt "$n_verifs" ]; do
    local v
    v=$(jq -r ".verification[$i]" "$manifest")
    if ! echo "$v" | grep -qE '^[a-zA-Z0-9_-]+$'; then
      eval "$reason_var=\"verification[$i]='$v' invalid format\""
      return 1
    fi
    i=$((i + 1))
  done

  # 如果 baseline 的 allowed_verifications 非空，则做严格白名单
  local allowed_verifs_count
  allowed_verifs_count=$(jq '.allowed_verifications | length' "$BASELINE_FILE")
  if [ "$allowed_verifs_count" -gt 0 ]; then
    local allowed_verifs_json
    allowed_verifs_json=$(jq -c '.allowed_verifications' "$BASELINE_FILE")
    i=0
    while [ $i -lt "$n_verifs" ]; do
      local v
      v=$(jq -r ".verification[$i]" "$manifest")
      if ! echo "$allowed_verifs_json" | jq -e --arg s "$v" 'index($s)' >/dev/null 2>&1; then
        eval "$reason_var=\"verification[$i]='$v' not in allowed_verifications\""
        return 1
      fi
      i=$((i + 1))
    done
  fi

  return 0
}

# 隔离临时目录预演：把 proposal 文件 overlay 到 snapshot 副本，跑 compose config + hadolint
# 返回 0 = ok（preflight_json 写入 details）；1 = 失败
isolated_preflight() {
  local id="$1" reason_var="$2" preflight_var="$3"
  local manifest="$PROPOSALS_DIR/$id/manifest.json"
  local proposal_dir="$PROPOSALS_DIR/$id"

  local tmp_dir
  tmp_dir=$(mktemp -d "/tmp/proposal-${id}.XXXXXX")
  trap "rm -rf '$tmp_dir'" RETURN

  # Copy snapshot/current to tmp
  if [ ! -d "$SNAPSHOT_DIR/current" ]; then
    eval "$reason_var=\"snapshot/current missing on host\""
    eval "$preflight_var='{\"status\":\"setup_failed\"}'"
    return 1
  fi
  cp -r "$SNAPSHOT_DIR/current/." "$tmp_dir/" 2>/dev/null || true

  # Overlay proposal files
  local n
  n=$(jq '.changes | length' "$manifest")
  local i=0
  local touched_compose=0
  local touched_dockerfile=0
  while [ $i -lt "$n" ]; do
    local p
    p=$(jq -r ".changes[$i].path" "$manifest")
    local src="$proposal_dir/$p"
    local dst="$tmp_dir/$p"
    if [ -f "$src" ]; then
      mkdir -p "$(dirname "$dst")"
      cp "$src" "$dst"
    fi
    case "$p" in
      docker-compose.yml) touched_compose=1 ;;
      Dockerfile) touched_dockerfile=1 ;;
    esac
    i=$((i + 1))
  done

  # 1. docker compose config（如果改了 compose）
  local compose_status="not_run"
  local compose_msg=""
  if [ "$touched_compose" = "1" ]; then
    if command -v docker >/dev/null 2>&1; then
      if docker compose -f "$tmp_dir/docker-compose.yml" config >/dev/null 2>"$tmp_dir/.compose_err"; then
        compose_status="ok"
      else
        compose_status="failed"
        compose_msg=$(head -c 500 "$tmp_dir/.compose_err" 2>/dev/null || echo "")
      fi
    else
      compose_status="skipped_missing_tool"
      write_event "warning" "docker missing, compose config skipped" "$id" '{}'
    fi
  fi

  # 2. hadolint Dockerfile（如果改了 Dockerfile）
  local hadolint_status="not_run"
  local hadolint_msg=""
  if [ "$touched_dockerfile" = "1" ]; then
    if command -v hadolint >/dev/null 2>&1; then
      if hadolint "$tmp_dir/Dockerfile" >"$tmp_dir/.hadolint_out" 2>&1; then
        hadolint_status="ok"
      else
        # hadolint 即使有 warning 也返回非 0；区分 error/warning
        hadolint_status="warnings"
        hadolint_msg=$(head -c 500 "$tmp_dir/.hadolint_out" 2>/dev/null || echo "")
        # 不阻断，仅记录
      fi
    else
      hadolint_status="skipped_missing_tool"
      write_event "warning" "hadolint missing, Dockerfile lint skipped" "$id" '{}'
    fi
  fi

  # 组装 preflight json
  local pj
  pj=$(jq -n \
    --arg cs "$compose_status" \
    --arg cm "$compose_msg" \
    --arg hs "$hadolint_status" \
    --arg hm "$hadolint_msg" \
    '{
      compose_config: {status: $cs, message: $cm},
      dockerfile_lint: {status: $hs, message: $hm}
    }')
  eval "$preflight_var=\$pj"

  # 失败判定：compose config failed = 硬失败；hadolint warnings 不阻断
  if [ "$compose_status" = "failed" ]; then
    eval "$reason_var=\"compose config failed: $compose_msg\""
    return 1
  fi

  return 0
}

# 风险分级
classify_risk() {
  local id="$1"
  local manifest="$PROPOSALS_DIR/$id/manifest.json"

  local n
  n=$(jq '.changes | length' "$manifest")
  local i=0
  local has_compose=0 has_dockerfile=0 has_squid_conf=0 has_proxy_list=0 has_litellm=0 has_collector_code=0 has_notifier_code=0 has_verifications=0
  while [ $i -lt "$n" ]; do
    local p
    p=$(jq -r ".changes[$i].path" "$manifest")
    case "$p" in
      docker-compose.yml) has_compose=1 ;;
      Dockerfile) has_dockerfile=1 ;;
      proxy/squid.conf) has_squid_conf=1 ;;
      proxy/allowed_domains.txt) has_proxy_list=1 ;;
      config/litellm_config.yaml) has_litellm=1 ;;
      collector/Dockerfile) has_dockerfile=1 ;;
      notifier/Dockerfile) has_dockerfile=1 ;;
      collector/collector.py) has_collector_code=1 ;;
      notifier/notifier.py) has_notifier_code=1 ;;
      scripts/ops/verifications/*) has_verifications=1 ;;
    esac
    i=$((i + 1))
  done

  # HIGH：任何 compose 改动
  if [ "$has_compose" = "1" ]; then
    echo "HIGH"
    return
  fi

  # MEDIUM：Dockerfile / squid.conf / litellm config / 服务代码
  if [ "$has_dockerfile" = "1" ] || [ "$has_squid_conf" = "1" ] || [ "$has_litellm" = "1" ] || [ "$has_collector_code" = "1" ] || [ "$has_notifier_code" = "1" ]; then
    echo "MEDIUM"
    return
  fi

  # LOW：白名单数据 / verification 脚本
  echo "LOW"
}

# ===== 处理一个 request =====

# 终结一个 proposal 的处理：write_result + consume_request + archive_proposal + notify
# 单一出口确保 notify_proposal 的覆盖与 write_result 严格一致；任何新增状态都在这里加
finalize_proposal() {
  local id="$1" status="$2" risk="$3" reason="$4"
  local details="${5:-}"
  local preflight="${6:-}"
  [ -z "$details" ] && details='{}'
  [ -z "$preflight" ] && preflight='{}'

  # 不变量：先发布并验证权威 result，才能推进生命周期和发通知。
  if ! write_result "$id" "$status" "$risk" "$reason" "$details" "$preflight"; then
    write_event "error" "finalize_proposal: write_result failed, NOT notifying (avoid split-brain)" "$id" '{}'
    return 1
  fi

  consume_request "$id"
  archive_proposal "$id"
  # B.2: should_notify_proposal 内部按 status × risk matrix 过滤；
  # 推送条件不满足时静默返回，不影响主流程
  notify_proposal "$id" "$status" "$risk" || true
}

process_request() {
  local id="$1"

  write_event "info" "processing request" "$id" '{}'

  # 1. disabled
  if check_disabled; then
    write_event "info" "watcher disabled, skipping" "$id" '{}'
    finalize_proposal "$id" "disabled" "UNKNOWN" "watcher is disabled (.ops-watcher.disabled exists)"
    return
  fi

  # 2. manifest schema
  local reason=""
  if ! check_manifest_schema "$id" reason; then
    write_event "error" "manifest schema rejected: $reason" "$id" '{}'
    finalize_proposal "$id" "rejected" "UNKNOWN" "$reason"
    return
  fi

  # 3. BLOCK paths
  reason=""
  if ! check_block_paths "$id" reason; then
    write_event "error" "BLOCK path detected: $reason" "$id" '{}'
    finalize_proposal "$id" "blocked" "BLOCK" "$reason"
    return
  fi

  # 3b. (A.1-2) candidate file 重验（watcher 不信任 helper）
  reason=""
  if ! check_candidate_files "$id" reason; then
    write_event "error" "candidate file check rejected: $reason" "$id" '{}'
    finalize_proposal "$id" "rejected" "UNKNOWN" "$reason"
    return
  fi

  # 4. stale
  reason=""
  if ! check_stale "$id" reason; then
    write_event "warning" "stale: $reason" "$id" '{}'
    finalize_proposal "$id" "stale" "UNKNOWN" "$reason"
    return
  fi

  # 5. conflict
  reason=""
  local superseded_id=""
  local conflict_rc=0
  check_conflict "$id" reason superseded_id || conflict_rc=$?
  if [ "$conflict_rc" != "0" ]; then
    write_event "warning" "conflict: $reason" "$id" '{}'
    finalize_proposal "$id" "conflict" "UNKNOWN" "$reason"
    return
  fi
  if [ -n "$superseded_id" ]; then
    # 把旧 proposal 状态改为 superseded
    write_event "info" "superseding old proposal" "$superseded_id" "$(jq -n --arg new "$id" '{superseded_by: $new}')"
    # 旧 proposal 写一个 sibling 事件 + 更新 summary
    local old_result="$RESULTS_DIR/$superseded_id.json"
    if [ -f "$old_result" ]; then
      # 不改原 result，写 sibling
      jq -n \
        --arg id "$superseded_id" \
        --arg by "$id" \
        --arg ts "$(ts_utc)" \
        '{
          ref_proposal_id: $id,
          event_type: "superseded",
          superseded_by: $by,
          occurred_at: $ts
        }' > "$RESULTS_DIR/${superseded_id}.superseded.json"
    fi
    # 旧 proposal 加一个 superseded summary
    printf '%s | superseded | UNKNOWN | superseded by %s | -\n' "$superseded_id" "$id" \
      > "$RESULTS_DIR/${superseded_id}.superseded.UNKNOWN.summary"
    # B.2: superseded 静默不通知（依赖 Phase 4 apply 二次校验 effective_status 兜底）
  fi

  # 6. global rules
  reason=""
  if ! check_global_rules "$id" reason; then
    write_event "error" "global rule violation: $reason" "$id" '{}'
    finalize_proposal "$id" "blocked" "BLOCK" "$reason"
    return
  fi

  # 6b. (A.1-1) baseline invariants（compose 改动时验证）
  reason=""
  if ! check_baseline_invariants "$id" reason; then
    write_event "error" "baseline invariant violation: $reason" "$id" '{}'
    finalize_proposal "$id" "blocked" "BLOCK" "$reason"
    return
  fi

  # 7. manifest whitelists
  reason=""
  if ! check_manifest_whitelists "$id" reason; then
    write_event "error" "manifest whitelist rejected: $reason" "$id" '{}'
    finalize_proposal "$id" "rejected" "UNKNOWN" "$reason"
    return
  fi

  # 8. preflight
  reason=""
  local preflight_json='{}'
  local preflight_rc=0
  isolated_preflight "$id" reason preflight_json || preflight_rc=$?
  if [ "$preflight_rc" != "0" ]; then
    write_event "error" "preflight failed: $reason" "$id" "$preflight_json"
    finalize_proposal "$id" "preflight_failed" "UNKNOWN" "$reason" '{}' "$preflight_json"
    return
  fi

  # 9. classify
  local risk
  risk=$(classify_risk "$id")

  # 10. accepted
  write_event "info" "accepted_for_review" "$id" "$(jq -n --arg r "$risk" '{risk_level: $r}')"
  finalize_proposal "$id" "accepted_for_review" "$risk" "passed all static checks" '{}' "$preflight_json"
}

# ===== 主循环 / CLI =====

list_pending_requests() {
  ls "$REQUESTS_DIR"/*.json 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.json$//' || true
}

main_loop() {
  ensure_dirs
  load_baseline
  check_snapshot_dir
  load_telegram_env
  write_event "info" "watcher started" "" "$(jq -n --arg pd "$PROJECT_DIR" --arg sd "$SNAPSHOT_DIR" '{project_dir: $pd, snapshot_dir: $sd}')"

  # B.2: 塔台可见性——started 不进幂等表，每次主循环启动都发
  local snap_id
  snap_id=$(cat "$SNAPSHOT_DIR/.snapshot-id" 2>/dev/null || echo "unknown")
  notify_lifecycle "started" "snapshot=${snap_id}"

  # B.2: SIGTERM/SIGINT 时通知 stopped；幂等表/lifecycle-state 都不动
  # （主循环可能被 launchd / Ctrl-C / kill 多种方式终止）
  trap 'notify_lifecycle "stopped" "graceful shutdown"; exit 0' INT TERM

  # 首次启动写入 lifecycle 初态（避免下一轮把 enabled 当成"resumed"）
  check_lifecycle_edge

  echo "[ops-watcher] PROJECT_DIR=$PROJECT_DIR"
  echo "[ops-watcher] SNAPSHOT_DIR=$SNAPSHOT_DIR"
  echo "[ops-watcher] watching $REQUESTS_DIR"
  echo "[ops-watcher] press Ctrl-C to stop"

  # B.2 hotfix: heartbeat 注入
  # - polling 模式：每个 POLL_INTERVAL（2s）check 一次，几乎实时发出
  # - fswatch 模式：仅在事件唤醒时 check——若长时间（> HEARTBEAT_INTERVAL）
  #   无 proposal 流量会错过 tick。已知局限性，B.4 launchd 重构时考虑用
  #   独立 timer 进程或切到混合模式（fswatch + 60s tick）解决
  if command -v fswatch >/dev/null 2>&1; then
    echo "[ops-watcher] using fswatch"
    # Process any pending first
    check_lifecycle_edge
    check_heartbeat
    for id in $(list_pending_requests); do
      process_request "$id" || true
    done
    fswatch -0 "$REQUESTS_DIR" | while IFS= read -r -d '' _; do
      sleep 0.2  # debounce
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

# ===== 入口 =====

case "${1:-}" in
  --once)
    shift
    [ -z "${1:-}" ] && { echo "Usage: ops-watcher.sh --once <request-id>" >&2; exit 1; }
    ensure_dirs
    load_baseline
    check_snapshot_dir
    load_telegram_env  # B.2: 单次模式仍发 proposal 通知；不发 started/stopped
    process_request "$1"
    ;;
  --process-all)
    ensure_dirs
    load_baseline
    check_snapshot_dir
    load_telegram_env  # B.2: 同上
    for id in $(list_pending_requests); do
      process_request "$id" || true
    done
    ;;
  --help|-h)
    cat <<EOF
Usage:
  ops-watcher.sh                  Main loop (fswatch + fallback polling)
  ops-watcher.sh --once <id>      Process one request
  ops-watcher.sh --process-all    Process all pending requests once and exit

Files:
  Project root: $PROJECT_DIR
  Requests:     $REQUESTS_DIR
  Results:      $RESULTS_DIR
  Events:       $EVENTS_LOG
  Baseline:     $BASELINE_FILE
  Disabled:     touch $DISABLED_FLAG to pause processing

See: OPS-WATCHER-DESIGN.md (Step A)
EOF
    ;;
  "")
    main_loop
    ;;
  *)
    echo "Unknown command: $1" >&2
    echo "Try: ops-watcher.sh --help" >&2
    exit 1
    ;;
esac

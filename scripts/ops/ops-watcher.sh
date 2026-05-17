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
  local level="$1" msg="$2" id="${3:-}" extra_json="${4:-{\}}"
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
  local details_json="${5:-{\}}"
  local preflight_json="${6:-{\}}"

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

  jq -n \
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
    }' > "$tmp"

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

  # 找所有"pending"（已 submit 但还没 result）proposals，排除自己
  local pending_ids=()
  for d in "$PROPOSALS_DIR"/*/; do
    [ -d "$d" ] || continue
    local other
    other=$(basename "$d")
    [ "$other" = "$id" ] && continue
    # 必须有 submit request 且无 result
    [ -f "$REQUESTS_DIR/$other.json" ] || [ -f "$REQUESTS_DIR/.processed/$other.json" ] || continue
    if [ -f "$RESULTS_DIR/$other.json" ]; then
      local other_status
      other_status=$(jq -r '.status' "$RESULTS_DIR/$other.json" 2>/dev/null || echo "unknown")
      # 只有 accepted_for_review 是真正"占位"的；其他终态不视为 conflict
      [ "$other_status" = "accepted_for_review" ] || continue
      # B.1 fix: 若该 proposal 已被 sibling 标记为 superseded，亦不视为占位
      [ -f "$RESULTS_DIR/$other.superseded.json" ] && continue
    fi
    pending_ids+=("$other")
  done

  # 处理 supersedes 声明
  if [ -n "$supersedes" ]; then
    # 必须确实存在且是 pending
    local found=0
    for pid in "${pending_ids[@]}"; do
      if [ "$pid" = "$supersedes" ]; then
        found=1
        break
      fi
    done
    if [ "$found" = "0" ]; then
      eval "$reason_var=\"supersedes target '$supersedes' not found among pending proposals\""
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

process_request() {
  local id="$1"

  write_event "info" "processing request" "$id" '{}'

  # 1. disabled
  if check_disabled; then
    write_event "info" "watcher disabled, skipping" "$id" '{}'
    write_result "$id" "disabled" "UNKNOWN" "watcher is disabled (.ops-watcher.disabled exists)" '{}' '{}'
    consume_request "$id"
    archive_proposal "$id"
    return
  fi

  # 2. manifest schema
  local reason=""
  if ! check_manifest_schema "$id" reason; then
    write_event "error" "manifest schema rejected: $reason" "$id" '{}'
    write_result "$id" "rejected" "UNKNOWN" "$reason" '{}' '{}'
    consume_request "$id"
    archive_proposal "$id"
    return
  fi

  # 3. BLOCK paths
  reason=""
  if ! check_block_paths "$id" reason; then
    write_event "error" "BLOCK path detected: $reason" "$id" '{}'
    write_result "$id" "blocked" "BLOCK" "$reason" '{}' '{}'
    consume_request "$id"
    archive_proposal "$id"
    return
  fi

  # 3b. (A.1-2) candidate file 重验（watcher 不信任 helper）
  reason=""
  if ! check_candidate_files "$id" reason; then
    write_event "error" "candidate file check rejected: $reason" "$id" '{}'
    write_result "$id" "rejected" "UNKNOWN" "$reason" '{}' '{}'
    consume_request "$id"
    archive_proposal "$id"
    return
  fi

  # 4. stale
  reason=""
  if ! check_stale "$id" reason; then
    write_event "warning" "stale: $reason" "$id" '{}'
    write_result "$id" "stale" "UNKNOWN" "$reason" '{}' '{}'
    consume_request "$id"
    archive_proposal "$id"
    return
  fi

  # 5. conflict
  reason=""
  local superseded_id=""
  local conflict_rc=0
  check_conflict "$id" reason superseded_id || conflict_rc=$?
  if [ "$conflict_rc" != "0" ]; then
    write_event "warning" "conflict: $reason" "$id" '{}'
    write_result "$id" "conflict" "UNKNOWN" "$reason" '{}' '{}'
    consume_request "$id"
    archive_proposal "$id"
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
  fi

  # 6. global rules
  reason=""
  if ! check_global_rules "$id" reason; then
    write_event "error" "global rule violation: $reason" "$id" '{}'
    write_result "$id" "blocked" "BLOCK" "$reason" '{}' '{}'
    consume_request "$id"
    archive_proposal "$id"
    return
  fi

  # 6b. (A.1-1) baseline invariants（compose 改动时验证）
  reason=""
  if ! check_baseline_invariants "$id" reason; then
    write_event "error" "baseline invariant violation: $reason" "$id" '{}'
    write_result "$id" "blocked" "BLOCK" "$reason" '{}' '{}'
    consume_request "$id"
    archive_proposal "$id"
    return
  fi

  # 7. manifest whitelists
  reason=""
  if ! check_manifest_whitelists "$id" reason; then
    write_event "error" "manifest whitelist rejected: $reason" "$id" '{}'
    write_result "$id" "rejected" "UNKNOWN" "$reason" '{}' '{}'
    consume_request "$id"
    archive_proposal "$id"
    return
  fi

  # 8. preflight
  reason=""
  local preflight_json='{}'
  local preflight_rc=0
  isolated_preflight "$id" reason preflight_json || preflight_rc=$?
  if [ "$preflight_rc" != "0" ]; then
    write_event "error" "preflight failed: $reason" "$id" "$preflight_json"
    write_result "$id" "preflight_failed" "UNKNOWN" "$reason" '{}' "$preflight_json"
    consume_request "$id"
    archive_proposal "$id"
    return
  fi

  # 9. classify
  local risk
  risk=$(classify_risk "$id")

  # 10. accepted
  write_event "info" "accepted_for_review" "$id" "$(jq -n --arg r "$risk" '{risk_level: $r}')"
  write_result "$id" "accepted_for_review" "$risk" "passed all static checks" '{}' "$preflight_json"
  consume_request "$id"
  archive_proposal "$id"
}

# ===== 主循环 / CLI =====

list_pending_requests() {
  ls "$REQUESTS_DIR"/*.json 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.json$//' || true
}

main_loop() {
  ensure_dirs
  load_baseline
  check_snapshot_dir
  write_event "info" "watcher started" "" "$(jq -n --arg pd "$PROJECT_DIR" --arg sd "$SNAPSHOT_DIR" '{project_dir: $pd, snapshot_dir: $sd}')"

  echo "[ops-watcher] PROJECT_DIR=$PROJECT_DIR"
  echo "[ops-watcher] SNAPSHOT_DIR=$SNAPSHOT_DIR"
  echo "[ops-watcher] watching $REQUESTS_DIR"
  echo "[ops-watcher] press Ctrl-C to stop"

  if command -v fswatch >/dev/null 2>&1; then
    echo "[ops-watcher] using fswatch"
    # Process any pending first
    for id in $(list_pending_requests); do
      process_request "$id" || true
    done
    fswatch -0 "$REQUESTS_DIR" | while IFS= read -r -d '' _; do
      sleep 0.2  # debounce
      for id in $(list_pending_requests); do
        process_request "$id" || true
      done
    done
  else
    echo "[ops-watcher] fswatch missing, falling back to polling every ${POLL_INTERVAL}s"
    while true; do
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
    process_request "$1"
    ;;
  --process-all)
    ensure_dirs
    load_baseline
    check_snapshot_dir
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

#!/bin/bash
# ops-helper.sh
# agent 容器内的 proposal 提交助手
# 安装位置：/usr/local/bin/ops-propose（由 Dockerfile COPY）
#
# Phase 1.2 关键改动：
#   - random_suffix 改用 od（避免 SIGPIPE）
#   - add 拒绝 symlink + realpath 校验（必须仍在 proposal 目录内）
#   - manifest 同时写 base_snapshot_id + base_snapshot_hash（双重锚定）
#   - PROPOSAL_PATH_ALLOWED 收窄到具体文件白名单
#   - submit 校验 verification 非空
#   - submit 拒绝全 no-op 提案

set -eo pipefail

WORKSPACE="${WORKSPACE:-/app/workspace}"
SNAPSHOT="$WORKSPACE/.snapshot"
PROPOSALS="$WORKSPACE/ops-proposals"
REQUESTS="$WORKSPACE/ops-requests"
RESULTS="$WORKSPACE/ops-results"

# PROPOSAL_PATH_ALLOWED：manifest.changes[].path 必须在以下规则内
# 一期收窄到具体文件枚举（不允许新增任意 .py / .conf / .txt）
# 新增文件留作 Phase 2 风险分级的扩展点（"add new code file" 自动升级到 MEDIUM/HIGH）
PATH_ALLOW_REGEX='^(docker-compose\.yml|Dockerfile|proxy/squid\.conf|proxy/allowed_domains\.txt|collector/collector\.py|collector/Dockerfile|notifier/notifier\.py|notifier/Dockerfile|config/litellm_config\.yaml|scripts/ops/verifications/[a-zA-Z0-9_-]+\.sh)$'

# affected_services 白名单
ALLOWED_SERVICES=("agent" "squid" "collector" "notifier" "litellm" "cliproxyapi")

# sha256 工具
if command -v sha256sum >/dev/null 2>&1; then
  SHA256_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA256_CMD="shasum -a 256"
else
  echo "ERROR: neither sha256sum nor shasum found" >&2
  exit 1
fi

# ===== 工具函数 =====

usage() {
  cat <<EOF
Usage: ops-propose <command> [args]

Commands:
  new <reason>                    Create new proposal (returns proposal_id)
  status <id>                     Show proposal status
  add <id> <path>                 Stage a candidate file (must exist as regular file in proposal dir, no symlinks)
  manifest <id>                   Print current manifest
  set-effect <id> <text>          Set expected_effect
  set-affected <id> <svc1,svc2>   Set affected_services (must be in whitelist)
  set-verification <id> <name1,name2>
  set-supersedes <id> <old_id>
  validate <id>                   Run all checks without submitting
  submit <id>                     Submit proposal for review
  result <id>                     Read apply result (after watcher processes)
  list                            List all proposals
  clean                           Remove stale empty drafts (>24h, no changes)

Allowed services: ${ALLOWED_SERVICES[*]}

Allowed paths (Phase 1.2, specific files only):
  docker-compose.yml / Dockerfile
  proxy/squid.conf / proxy/allowed_domains.txt
  collector/collector.py / collector/Dockerfile
  notifier/notifier.py / notifier/Dockerfile
  config/litellm_config.yaml
  scripts/ops/verifications/<name>.sh

Workflow:
  1. ID=\$(ops-propose new "increase squid timeout")
  2. # Edit files under /app/workspace/ops-proposals/\$ID/
  3. ops-propose add \$ID proxy/allowed_domains.txt
  4. ops-propose set-effect \$ID "agent can reach example.com"
  5. ops-propose set-affected \$ID squid
  6. ops-propose set-verification \$ID squid_denies_example_org
  7. ops-propose validate \$ID    # Iterate until clean
  8. ops-propose submit \$ID
  9. ops-propose result \$ID      # After watcher processes

See: OPS-WATCHER-DESIGN.md
EOF
}

ensure_dirs() {
  mkdir -p "$PROPOSALS" "$REQUESTS" "$RESULTS"
}

# 随机后缀（不触发 SIGPIPE）
random_suffix() {
  if [ -r /dev/urandom ]; then
    LC_ALL=C od -An -N3 -tx1 /dev/urandom | tr -d ' \n'
  else
    # 退化：用纳秒
    date +%N 2>/dev/null | tail -c 7 || echo "yyyyyy"
  fi
}

file_sha256() {
  local f="$1"
  $SHA256_CMD "$f" | awk '{print $1}'
}

# 原子更新 manifest：mktemp 在同目录 + mv + trap
jq_update() {
  local manifest="$1"
  shift
  local dir
  dir=$(dirname "$manifest")
  local tmp
  tmp=$(mktemp "$dir/.manifest.XXXXXX")
  trap "rm -f '$tmp'" EXIT

  jq "$@" "$manifest" > "$tmp"
  mv "$tmp" "$manifest"

  trap - EXIT
}

# 验证路径在 PROPOSAL_PATH_ALLOWED 内
check_path_allowed() {
  local path="$1"
  if ! echo "$path" | grep -qE "$PATH_ALLOW_REGEX"; then
    echo "ERROR: path '$path' is NOT in PROPOSAL_PATH_ALLOWED whitelist" >&2
    echo "       Allowed: docker-compose.yml, Dockerfile, proxy/squid.conf, proxy/allowed_domains.txt," >&2
    echo "                collector/{collector.py,Dockerfile}, notifier/{notifier.py,Dockerfile}," >&2
    echo "                config/litellm_config.yaml, scripts/ops/verifications/*.sh" >&2
    echo "       Note: claude_config/ is readable in .snapshot but NOT modifiable via proposal." >&2
    return 1
  fi
}

# 验证服务名
check_service_allowed() {
  local svc="$1"
  for s in "${ALLOWED_SERVICES[@]}"; do
    if [ "$svc" = "$s" ]; then
      return 0
    fi
  done
  echo "ERROR: service '$svc' is NOT in allowed list: ${ALLOWED_SERVICES[*]}" >&2
  return 1
}

# 校验文件是普通文件且不是 symlink，且 realpath 仍在 proposal 目录内
check_file_safe() {
  local file="$1" proposal_dir="$2"

  # 拒绝 symlink
  if [ -L "$file" ]; then
    echo "ERROR: '$file' is a symlink (not allowed in proposals)" >&2
    return 1
  fi

  # 必须是普通文件
  if [ ! -f "$file" ]; then
    echo "ERROR: '$file' is not a regular file" >&2
    return 1
  fi

  # realpath 必须仍在 proposal 目录内
  local file_real proposal_real
  if command -v realpath >/dev/null 2>&1; then
    file_real=$(realpath "$file")
    proposal_real=$(realpath "$proposal_dir")
  else
    # macOS / 老系统兜底（python 一般可用）
    file_real=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$file" 2>/dev/null || echo "$file")
    proposal_real=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$proposal_dir" 2>/dev/null || echo "$proposal_dir")
  fi

  case "$file_real" in
    "$proposal_real"/*) ;;
    *)
      echo "ERROR: '$file' resolves to '$file_real' which is OUTSIDE proposal directory '$proposal_real'" >&2
      return 1
      ;;
  esac
}

cleanup_stale_tmp() {
  local id="$1"
  local dir="$PROPOSALS/$id"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -name '.manifest.*' -mmin +60 -delete 2>/dev/null || true
}

# 读取 snapshot 顶层 metadata
read_snapshot_meta() {
  local field="$1"  # "id" or "hash"
  local file="$SNAPSHOT/.snapshot-${field}"
  if [ -f "$file" ]; then
    cat "$file"
  else
    echo "unknown"
  fi
}

# ===== 命令实现 =====

new_proposal() {
  local reason="$1"
  if [ -z "$reason" ]; then
    echo "ERROR: reason required" >&2
    return 1
  fi
  ensure_dirs

  local ts
  ts=$(date -u +"%Y%m%d-%H%M%S")
  local suffix
  suffix=$(random_suffix)
  local id="${ts}-${suffix}"

  local dir="$PROPOSALS/$id"
  if [ -d "$dir" ]; then
    echo "ERROR: proposal $id already exists (id collision, try again)" >&2
    return 1
  fi
  mkdir -p "$dir"

  # 读取 snapshot 元数据
  local snapshot_id snapshot_hash
  snapshot_id=$(read_snapshot_meta "id")
  snapshot_hash=$(read_snapshot_meta "hash")

  local manifest="$dir/manifest.json"
  local tmp
  tmp=$(mktemp "$dir/.manifest.XXXXXX")
  trap "rm -f '$tmp'" EXIT
  jq -n \
    --arg id "$id" \
    --arg snap_id "$snapshot_id" \
    --arg snap_hash "$snapshot_hash" \
    --arg reason "$reason" \
    '{
      proposal_id: $id,
      base_snapshot_id: $snap_id,
      base_snapshot_hash: $snap_hash,
      supersedes: null,
      reason: $reason,
      expected_effect: "",
      affected_services: [],
      rebuild_strategy: "minimal",
      changes: [],
      verification: []
    }' > "$tmp"
  mv "$tmp" "$manifest"
  trap - EXIT

  echo "$id"
}

show_status() {
  local id="$1"
  local dir="$PROPOSALS/$id"
  [ -d "$dir" ] || { echo "ERROR: proposal $id not found" >&2; return 1; }
  echo "=== Proposal $id ==="
  echo "Path: $dir"

  if ls "$RESULTS/$id"*.json >/dev/null 2>&1; then
    echo "Status: has result(s)"
    for f in "$RESULTS/$id"*.json; do
      echo "  $(basename "$f"):"
      jq '{status, watcher_decision, applied_at, rejected_at, event_type}' "$f" 2>/dev/null | sed 's/^/    /'
    done
  elif [ -f "$REQUESTS/$id.json" ]; then
    echo "Status: submitted, awaiting watcher"
  else
    echo "Status: draft"
  fi

  echo "--- Manifest ---"
  jq . "$dir/manifest.json"
}

add_change() {
  local id="$1" path="$2"
  local dir="$PROPOSALS/$id"
  [ -d "$dir" ] || { echo "ERROR: proposal $id not found" >&2; return 1; }
  [ -n "$path" ] || { echo "ERROR: path required" >&2; return 1; }

  # 路径白名单
  check_path_allowed "$path" || return 1

  local file="$dir/$path"

  # 文件安全校验（非 symlink + realpath 在 proposal 内）
  check_file_safe "$file" "$dir" || return 1

  local manifest="$dir/manifest.json"
  [ -f "$manifest" ] || { echo "ERROR: manifest.json missing" >&2; return 1; }

  # 去重检测
  local existing
  existing=$(jq -r --arg p "$path" '.changes[] | select(.path == $p) | .path' "$manifest")
  local change_op="add"
  if [ -n "$existing" ]; then
    change_op="update"
  fi

  # 与 snapshot 比较
  local snapshot_file="$SNAPSHOT/current/$path"
  local change_type="modify"
  local summary=""
  local is_noop=0
  if [ ! -e "$snapshot_file" ]; then
    change_type="add"
    summary="new file"
  else
    local added removed
    added=$(diff "$snapshot_file" "$file" 2>/dev/null | grep -c '^>' || true)
    removed=$(diff "$snapshot_file" "$file" 2>/dev/null | grep -c '^<' || true)
    summary="+${added}/-${removed} lines"
    if [ "$added" = "0" ] && [ "$removed" = "0" ]; then
      summary="no changes vs snapshot"
      is_noop=1
    fi
  fi

  # sha256
  local sha
  sha=$(file_sha256 "$file")

  jq_update "$manifest" \
    --arg path "$path" \
    --arg type "$change_type" \
    --arg summary "$summary" \
    --arg sha "$sha" \
    '.changes = ([.changes[] | select(.path != $path)] + [{path: $path, type: $type, summary: $summary, sha256: $sha}])'

  if [ "$change_op" = "add" ]; then
    echo "Added: $path ($change_type, $summary, sha256: ${sha:0:12}...)"
  else
    echo "Updated: $path ($change_type, $summary, sha256: ${sha:0:12}...)"
  fi

  if [ "$is_noop" = "1" ]; then
    echo "WARN: this change is a no-op vs snapshot. Submit will reject if all changes are no-op." >&2
  fi
}

set_field() {
  local id="$1" field="$2" value="$3"
  local manifest="$PROPOSALS/$id/manifest.json"
  [ -f "$manifest" ] || { echo "ERROR: proposal $id not found" >&2; return 1; }

  case "$field" in
    affected_services)
      IFS=',' read -ra SVCS <<< "$value"
      local clean_arr=()
      for svc in "${SVCS[@]}"; do
        svc=$(echo "$svc" | tr -d ' ')
        [ -z "$svc" ] && continue
        check_service_allowed "$svc" || return 1
        clean_arr+=("$svc")
      done
      local arr_json
      arr_json=$(printf '%s\n' "${clean_arr[@]}" | jq -R . | jq -s 'unique')
      jq_update "$manifest" --argjson v "$arr_json" '.affected_services = $v'
      ;;
    verification)
      IFS=',' read -ra ITEMS <<< "$value"
      local clean_arr=()
      for v in "${ITEMS[@]}"; do
        v=$(echo "$v" | tr -d ' ')
        [ -z "$v" ] && continue
        if ! echo "$v" | grep -qE '^[a-zA-Z0-9_-]+$'; then
          echo "ERROR: verification name '$v' invalid (only [a-zA-Z0-9_-])" >&2
          return 1
        fi
        clean_arr+=("$v")
      done
      local arr_json
      arr_json=$(printf '%s\n' "${clean_arr[@]}" | jq -R . | jq -s 'unique')
      jq_update "$manifest" --argjson v "$arr_json" '.verification = $v'
      ;;
    expected_effect|reason)
      jq_update "$manifest" --arg v "$value" ".${field} = \$v"
      ;;
    supersedes)
      if [ -z "$value" ] || [ "$value" = "null" ]; then
        jq_update "$manifest" '.supersedes = null'
      else
        jq_update "$manifest" --arg v "$value" '.supersedes = $v'
      fi
      ;;
    *)
      echo "ERROR: unknown field '$field'" >&2
      return 1
      ;;
  esac

  echo "Set $field"
}

# 重新计算所有 changes 的 sha256
recompute_hashes() {
  local id="$1"
  local manifest="$PROPOSALS/$id/manifest.json"
  local dir="$PROPOSALS/$id"

  local n
  n=$(jq '.changes | length' "$manifest")
  if [ "$n" = "0" ]; then
    return 0
  fi

  local i=0
  local drift=0
  while [ $i -lt $n ]; do
    local p
    p=$(jq -r ".changes[$i].path" "$manifest")
    local stored_sha
    stored_sha=$(jq -r ".changes[$i].sha256 // \"\"" "$manifest")
    local file="$dir/$p"
    if [ ! -f "$file" ]; then
      echo "WARN: changes[$i].path '$p' missing on disk" >&2
      drift=1
    else
      local actual_sha
      actual_sha=$(file_sha256 "$file")
      if [ -n "$stored_sha" ] && [ "$stored_sha" != "$actual_sha" ]; then
        echo "WARN: changes[$i].path '$p' sha256 drifted (manifest=$stored_sha, actual=$actual_sha)" >&2
        echo "      Re-add with: ops-propose add $id $p" >&2
        drift=1
      fi
    fi
    i=$((i + 1))
  done
  return $drift
}

do_validate() {
  local id="$1"
  local dir="$PROPOSALS/$id"
  [ -d "$dir" ] || { echo "ERROR: proposal $id not found" >&2; return 1; }

  cleanup_stale_tmp "$id"

  local manifest="$dir/manifest.json"
  [ -f "$manifest" ] || { echo "ERROR: manifest.json missing" >&2; return 1; }

  if ! jq empty "$manifest" 2>/dev/null; then
    echo "FAIL: manifest.json is not valid JSON" >&2
    return 1
  fi

  local errors=0

  # 必填：base_snapshot_id
  local snap_id
  snap_id=$(jq -r '.base_snapshot_id' "$manifest")
  if [ "$snap_id" = "unknown" ] || [ -z "$snap_id" ] || [ "$snap_id" = "null" ]; then
    echo "FAIL: base_snapshot_id is 'unknown' (snapshot not initialized when this proposal was created)" >&2
    errors=$((errors + 1))
  fi

  # 必填：base_snapshot_hash
  local snap_hash
  snap_hash=$(jq -r '.base_snapshot_hash // ""' "$manifest")
  if [ "$snap_hash" = "unknown" ] || [ -z "$snap_hash" ] || [ "$snap_hash" = "null" ]; then
    echo "FAIL: base_snapshot_hash is missing (proposal predates Phase 1.2)" >&2
    errors=$((errors + 1))
  fi

  # 必填：reason
  local reason
  reason=$(jq -r '.reason // ""' "$manifest")
  if [ -z "$reason" ]; then
    echo "FAIL: reason is empty" >&2
    errors=$((errors + 1))
  fi

  # 必填：expected_effect
  local effect
  effect=$(jq -r '.expected_effect // ""' "$manifest")
  if [ -z "$effect" ]; then
    echo "FAIL: expected_effect is empty (use: ops-propose set-effect $id \"...\")" >&2
    errors=$((errors + 1))
  fi

  # 必填：affected_services 非空 + 白名单
  local n_svcs
  n_svcs=$(jq '.affected_services | length' "$manifest")
  if [ "$n_svcs" = "0" ]; then
    echo "FAIL: affected_services is empty (use: ops-propose set-affected $id <svc>)" >&2
    errors=$((errors + 1))
  else
    local i=0
    while [ $i -lt "$n_svcs" ]; do
      local svc
      svc=$(jq -r ".affected_services[$i]" "$manifest")
      if ! check_service_allowed "$svc" 2>/dev/null; then
        echo "FAIL: affected_services[$i]='$svc' not in whitelist: ${ALLOWED_SERVICES[*]}" >&2
        errors=$((errors + 1))
      fi
      i=$((i + 1))
    done
  fi

  # 必填：verification 非空（Phase 1.2 新增）
  local n_verifs
  n_verifs=$(jq '.verification | length' "$manifest")
  if [ "$n_verifs" = "0" ]; then
    echo "FAIL: verification is empty (use: ops-propose set-verification $id <name1,name2>)" >&2
    echo "      Reason: a proposal without verification cannot prove its expected_effect" >&2
    errors=$((errors + 1))
  fi

  # 必填：changes 非空 + 路径白名单 + 文件存在
  local n_changes
  n_changes=$(jq '.changes | length' "$manifest")
  if [ "$n_changes" = "0" ]; then
    echo "FAIL: changes is empty (use: ops-propose add $id <path>)" >&2
    errors=$((errors + 1))
  else
    local i=0
    local n_noop=0
    while [ $i -lt "$n_changes" ]; do
      local p
      p=$(jq -r ".changes[$i].path" "$manifest")
      if ! check_path_allowed "$p" 2>/dev/null; then
        echo "FAIL: changes[$i].path='$p' not in PROPOSAL_PATH_ALLOWED whitelist" >&2
        errors=$((errors + 1))
      fi
      if [ ! -f "$dir/$p" ]; then
        echo "FAIL: changes[$i].path='$p' file does not exist in proposal dir" >&2
        errors=$((errors + 1))
      fi
      # 统计 no-op
      local s
      s=$(jq -r ".changes[$i].summary // \"\"" "$manifest")
      if [ "$s" = "no changes vs snapshot" ]; then
        n_noop=$((n_noop + 1))
      fi
      i=$((i + 1))
    done

    # 全 no-op 拒绝（Phase 1.2 新增）
    if [ "$n_noop" -gt 0 ] && [ "$n_noop" = "$n_changes" ]; then
      echo "FAIL: all $n_changes change(s) are no-op vs snapshot. Edit candidate files first." >&2
      errors=$((errors + 1))
    fi

    # sha256 漂移
    if ! recompute_hashes "$id"; then
      errors=$((errors + 1))
    fi
  fi

  if [ $errors -gt 0 ]; then
    echo "" >&2
    echo "Validation FAILED with $errors error(s)" >&2
    return 1
  fi

  echo "Validation PASSED"
  echo "Manifest summary:"
  jq '{proposal_id, base_snapshot_id, base_snapshot_hash, reason, expected_effect, affected_services, changes: [.changes[] | {path, type, summary}], verification}' "$manifest"
}

submit() {
  local id="$1"
  local dir="$PROPOSALS/$id"
  [ -d "$dir" ] || { echo "ERROR: proposal $id not found" >&2; return 1; }

  ensure_dirs

  if ! do_validate "$id"; then
    echo "" >&2
    echo "Submission BLOCKED — fix errors above and try again." >&2
    return 1
  fi

  local req="$REQUESTS/$id.json"
  if [ -f "$req" ]; then
    echo "ERROR: proposal $id already submitted (request exists at $req)" >&2
    return 1
  fi

  local tmp
  tmp=$(mktemp "$REQUESTS/.req.XXXXXX")
  trap "rm -f '$tmp'" EXIT
  jq -n \
    --arg id "$id" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{proposal_id: $id, submitted_at: $ts}' > "$tmp"
  mv "$tmp" "$req"
  trap - EXIT

  echo "Submitted: $id"
  echo "Watcher will process. Check result with: ops-propose result $id"
}

result() {
  local id="$1"
  local primary="$RESULTS/$id.json"
  if [ ! -f "$primary" ]; then
    echo "No result yet for $id"
    return 1
  fi

  echo "=== Primary result ==="
  cat "$primary"

  local siblings
  siblings=$(ls "$RESULTS/$id".*.json 2>/dev/null || true)
  if [ -n "$siblings" ]; then
    echo ""
    echo "=== Subsequent events ==="
    for f in $siblings; do
      echo "--- $(basename "$f") ---"
      cat "$f"
    done
  fi
}

list_proposals() {
  ensure_dirs
  echo "Proposals in $PROPOSALS:"
  if ! ls -d "$PROPOSALS"/*/ >/dev/null 2>&1; then
    echo "  (none)"
    return 0
  fi
  for d in "$PROPOSALS"/*/; do
    [ -d "$d" ] || continue
    local id
    id=$(basename "$d")
    local status="draft"
    if [ -f "$RESULTS/$id.json" ]; then
      status=$(jq -r '.status // .watcher_decision // "unknown"' "$RESULTS/$id.json" 2>/dev/null || echo "unknown")
    elif [ -f "$REQUESTS/$id.json" ]; then
      status="submitted"
    fi
    local n_changes
    n_changes=$(jq '.changes | length' "$d/manifest.json" 2>/dev/null || echo "?")
    echo "  $id  [$status]  changes=$n_changes"
  done
}

clean_drafts() {
  ensure_dirs
  local now
  now=$(date +%s)
  local cutoff=$((now - 86400))
  local cleaned=0
  local kept=0

  if ! ls -d "$PROPOSALS"/*/ >/dev/null 2>&1; then
    echo "Nothing to clean."
    return 0
  fi

  for d in "$PROPOSALS"/*/; do
    [ -d "$d" ] || continue
    local id
    id=$(basename "$d")

    if [ -f "$REQUESTS/$id.json" ] || [ -f "$RESULTS/$id.json" ]; then
      kept=$((kept + 1))
      continue
    fi

    local n_changes
    n_changes=$(jq '.changes | length' "$d/manifest.json" 2>/dev/null || echo "0")
    if [ "$n_changes" != "0" ]; then
      kept=$((kept + 1))
      continue
    fi

    local mtime
    if [ "$(uname)" = "Darwin" ]; then
      mtime=$(stat -f %m "$d/manifest.json" 2>/dev/null || echo "0")
    else
      mtime=$(stat -c %Y "$d/manifest.json" 2>/dev/null || echo "0")
    fi
    if [ "$mtime" -lt "$cutoff" ]; then
      rm -rf "$d"
      cleaned=$((cleaned + 1))
      echo "Cleaned: $id"
    else
      kept=$((kept + 1))
    fi
  done
  echo "Done. Cleaned: $cleaned, kept: $kept"
}

# ===== 命令分发 =====

case "${1:-}" in
  new)              shift; new_proposal "$@" ;;
  status)           shift; show_status "$@" ;;
  add)              shift; add_change "$@" ;;
  manifest)         shift; cat "$PROPOSALS/$1/manifest.json" ;;
  set-effect)       shift; set_field "$1" expected_effect "$2" ;;
  set-affected)     shift; set_field "$1" affected_services "$2" ;;
  set-verification) shift; set_field "$1" verification "$2" ;;
  set-supersedes)   shift; set_field "$1" supersedes "$2" ;;
  set-reason)       shift; set_field "$1" reason "$2" ;;
  validate)         shift; do_validate "$@" ;;
  submit)           shift; submit "$@" ;;
  result)           shift; result "$@" ;;
  list)             list_proposals ;;
  clean)            clean_drafts ;;
  -h|--help|help|"") usage ;;
  *) echo "Unknown command: $1" >&2; usage; exit 1 ;;
esac

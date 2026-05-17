#!/bin/bash
# ops-helper.sh
# agent 容器内的 proposal 提交助手
# 安装位置：/usr/local/bin/ops-propose（由 Dockerfile COPY）
#
# 用法：
#   ops-propose new <reason>           # 创建新 proposal 目录，返回 ID
#   ops-propose add <id> <path>        # 把候选文件加入 proposal
#   ops-propose submit <id>            # 提交审批

set -eo pipefail

WORKSPACE="${WORKSPACE:-/app/workspace}"
SNAPSHOT="$WORKSPACE/.snapshot"
PROPOSALS="$WORKSPACE/ops-proposals"
REQUESTS="$WORKSPACE/ops-requests"
RESULTS="$WORKSPACE/ops-results"

usage() {
  cat <<EOF
Usage: ops-propose <command> [args]

Commands:
  new <reason>              Create new proposal, prints proposal_id
  status <id>               Show proposal status
  add <id> <path>           Stage a candidate file (must already exist in proposal dir)
  manifest <id>             Print current manifest
  set-affected <id> <svc1,svc2>
  set-verification <id> <name1,name2>
  set-supersedes <id> <old_id>
  submit <id>               Submit proposal for review
  result <id>               Read apply result (after watcher processes)
  list                      List all proposals

Workflow:
  1. ID=\$(ops-propose new "increase squid timeout")
  2. # Edit files under /app/workspace/ops-proposals/\$ID/
  3. ops-propose set-affected \$ID squid
  4. ops-propose set-verification \$ID squid_denies_example_org
  5. ops-propose submit \$ID
  6. # Wait for watcher to process; check result:
  7. ops-propose result \$ID
EOF
}

ensure_dirs() {
  mkdir -p "$PROPOSALS" "$REQUESTS"
}

new_proposal() {
  local reason="$1"
  if [ -z "$reason" ]; then
    echo "ERROR: reason required" >&2
    return 1
  fi
  ensure_dirs

  local id
  id=$(date -u +"%Y%m%d-%H%M%S")
  local dir="$PROPOSALS/$id"
  mkdir -p "$dir"

  local snapshot_id="unknown"
  if [ -f "$SNAPSHOT/.snapshot-id" ]; then
    snapshot_id=$(cat "$SNAPSHOT/.snapshot-id")
  fi

  cat > "$dir/manifest.json" <<EOF
{
  "proposal_id": "$id",
  "base_snapshot_id": "$snapshot_id",
  "supersedes": null,
  "reason": "$reason",
  "expected_effect": "",
  "affected_services": [],
  "rebuild_strategy": "minimal",
  "changes": [],
  "verification": []
}
EOF

  echo "$id"
}

show_status() {
  local id="$1"
  local dir="$PROPOSALS/$id"
  [ -d "$dir" ] || { echo "ERROR: proposal $id not found"; return 1; }
  echo "=== Proposal $id ==="
  echo "Path: $dir"
  if [ -f "$RESULTS/$id.json" ]; then
    echo "Result:"
    cat "$RESULTS/$id.json"
  elif [ -f "$REQUESTS/$id.json" ]; then
    echo "Status: submitted, awaiting watcher"
  else
    echo "Status: draft"
  fi
}

add_change() {
  local id="$1" path="$2"
  local dir="$PROPOSALS/$id"
  [ -d "$dir" ] || { echo "ERROR: proposal $id not found"; return 1; }
  [ -n "$path" ] || { echo "ERROR: path required"; return 1; }

  local file="$dir/$path"
  [ -f "$file" ] || { echo "ERROR: file $file does not exist; create it first"; return 1; }

  # 计算 summary（diff 行数）
  local snapshot_file="$SNAPSHOT/$path"
  local summary=""
  local change_type="modify"
  if [ ! -e "$snapshot_file" ]; then
    change_type="add"
    summary="new file"
  else
    local added removed
    added=$(diff "$snapshot_file" "$file" 2>/dev/null | grep -c '^>' || true)
    removed=$(diff "$snapshot_file" "$file" 2>/dev/null | grep -c '^<' || true)
    summary="+${added}/-${removed} lines"
  fi

  # 更新 manifest
  local manifest="$dir/manifest.json"
  local tmp
  tmp=$(mktemp)
  jq --arg path "$path" --arg type "$change_type" --arg summary "$summary" \
    '.changes += [{"path":$path,"type":$type,"summary":$summary}]' \
    "$manifest" > "$tmp" && mv "$tmp" "$manifest"

  echo "Added: $path ($change_type, $summary)"
}

set_field() {
  local id="$1" field="$2" value="$3"
  local manifest="$PROPOSALS/$id/manifest.json"
  [ -f "$manifest" ] || { echo "ERROR: proposal $id not found"; return 1; }

  local tmp
  tmp=$(mktemp)
  case "$field" in
    affected_services|verification)
      # 逗号分隔转 JSON array
      local arr
      arr=$(echo "$value" | jq -R 'split(",") | map(select(length>0))')
      jq --argjson v "$arr" ".${field} = \$v" "$manifest" > "$tmp"
      ;;
    *)
      jq --arg v "$value" ".${field} = \$v" "$manifest" > "$tmp"
      ;;
  esac
  mv "$tmp" "$manifest"
  echo "Set $field"
}

submit() {
  local id="$1"
  local dir="$PROPOSALS/$id"
  [ -d "$dir" ] || { echo "ERROR: proposal $id not found"; return 1; }
  [ -f "$dir/manifest.json" ] || { echo "ERROR: manifest.json missing"; return 1; }

  ensure_dirs

  # 校验 manifest 有 changes
  local n_changes
  n_changes=$(jq '.changes | length' "$dir/manifest.json")
  if [ "$n_changes" = "0" ]; then
    echo "ERROR: proposal has no changes; use 'add' first" >&2
    return 1
  fi

  # 写 request
  cat > "$REQUESTS/$id.json" <<EOF
{
  "proposal_id": "$id",
  "submitted_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

  echo "Submitted: $id"
  echo "Watcher will process. Check result with: ops-propose result $id"
}

result() {
  local id="$1"
  local f="$RESULTS/$id.json"
  if [ -f "$f" ]; then
    cat "$f"
  else
    echo "No result yet for $id"
    return 1
  fi
}

list_proposals() {
  ensure_dirs
  echo "Proposals:"
  for d in "$PROPOSALS"/*/; do
    [ -d "$d" ] || continue
    local id
    id=$(basename "$d")
    local status="draft"
    [ -f "$REQUESTS/$id.json" ] && status="submitted"
    [ -f "$RESULTS/$id.json" ] && status=$(jq -r '.status // "unknown"' "$RESULTS/$id.json")
    echo "  $id  [$status]"
  done
}

case "${1:-}" in
  new)              shift; new_proposal "$@" ;;
  status)           shift; show_status "$@" ;;
  add)              shift; add_change "$@" ;;
  manifest)         shift; cat "$PROPOSALS/$1/manifest.json" ;;
  set-affected)     shift; set_field "$1" affected_services "$2" ;;
  set-verification) shift; set_field "$1" verification "$2" ;;
  set-supersedes)   shift; set_field "$1" supersedes "$2" ;;
  set-effect)       shift; set_field "$1" expected_effect "$2" ;;
  submit)           shift; submit "$@" ;;
  result)           shift; result "$@" ;;
  list)             list_proposals ;;
  -h|--help|help|"") usage ;;
  *) echo "Unknown command: $1"; usage; exit 1 ;;
esac

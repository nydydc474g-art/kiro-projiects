#!/bin/bash
# ============================================================
# collect-audit.sh — 宿主机审计日志分析器
#
# 读取 ./audit_spool/ 下的权威和备份日志
#
# 用法：
#   ./collect-audit.sh                     # 实时查看（合并权威+备份）
#   ./collect-audit.sh --dump              # 导出全量 JSONL（仅权威）
#   ./collect-audit.sh --security-only     # 只看安全事件
#   ./collect-audit.sh --stats             # 统计摘要
#   ./collect-audit.sh --diff              # 交叉验证
#   ./collect-audit.sh --follow            # 持续跟踪
# ============================================================
set -euo pipefail

SANDBOX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SPOOL_DIR="${SANDBOX_DIR}/audit_spool"
COLLECTOR_FILE="${SPOOL_DIR}/audit-collector.jsonl"
AGENT_FILE="${SPOOL_DIR}/audit-agent.jsonl"

DUMP=false
SECURITY_ONLY=false
STATS=false
DIFF=false
FOLLOW=false

usage() {
  echo "用法："
  echo "  $0                     实时查看（合并权威+备份）               "
  echo "  $0 --dump              导出权威日志 JSONL                     "
  echo "  $0 --security-only     仅显示安全事件                         "
  echo "  $0 --stats             统计摘要                               "
  echo "  $0 --diff              交叉验证                               "
  echo "  $0 --follow            持续跟踪                               "
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dump) DUMP=true; shift ;;
    --security-only) SECURITY_ONLY=true; shift ;;
    --stats) STATS=true; shift ;;
    --diff) DIFF=true; shift ;;
    --follow) FOLLOW=true; shift ;;
    -h|--help) usage ;;
    *) echo "未知参数: $1"; usage ;;
  esac
done

# --- 合并读取（静态模式） ---
read_all() {
  {
    [ -f "$COLLECTOR_FILE" ] && cat "$COLLECTOR_FILE"
    [ -f "$AGENT_FILE" ] && cat "$AGENT_FILE"
  } | jq -s 'sort_by(.timestamp)[]' -c 2>/dev/null || { echo "[collect-audit] WARN: jq parse failed on audit log" >&2; true; }
}

# --- 持续跟踪（逐行实时，不聚合排序） ---
follow_stream() {
  tail -q -F "$COLLECTOR_FILE" "$AGENT_FILE" 2>/dev/null | while IFS= read -r line; do
    echo "$line" | jq -c '.' 2>/dev/null || true
  done
}

# --- 格式化输出 ---
format_line() {
  local line="$1"
  local ts event tool risk blocked exit_code

  ts=$(echo "$line" | jq -r '.timestamp // ""' 2>/dev/null)
  event=$(echo "$line" | jq -r '.event // ""' 2>/dev/null)
  tool=$(echo "$line" | jq -r '.tool_name // ""' 2>/dev/null)
  risk=$(echo "$line" | jq -r '.risk_level // "none"' 2>/dev/null)
  blocked=$(echo "$line" | jq -r '.blocked_by // ""' 2>/dev/null)
  exit_code=$(echo "$line" | jq -r '.exit_code // ""' 2>/dev/null)

  case "$risk" in
    high)   risk_color="\033[1;31m" ;;
    medium) risk_color="\033[1;33m" ;;
    low)    risk_color="\033[1;36m" ;;
    *)      risk_color="\033[0m" ;;
  esac

  local icon=""
  [ "$event" = "PRE" ] && icon="🎯"
  [ "$event" = "POST" ] && icon="✅"

  printf "%b" "${risk_color}" 2>/dev/null || true
  printf "%s %s %-10s " "$ts" "$icon" "$tool"
  [ -n "$exit_code" ] && printf "exit=%s " "$exit_code"
  if [ "$risk" != "none" ]; then
    printf "%brisk=%-6s%b " "${risk_color}" "$risk" "\033[0m"
    [ -n "$blocked" ] && printf "blocked_by=%-20s " "$blocked"
  fi
  printf "\n"
}

# --- 主逻辑 ---
if [ "$STATS" = true ]; then
  echo "=== 审计统计 ==="
  echo ""

  LOGS=$(read_all)
  if [ -z "$LOGS" ]; then
    echo "无审计记录 (检查 audit_spool/ 目录)"
    exit 0
  fi

  TOTAL=$(echo "$LOGS" | wc -l | tr -d ' ')
  PRE_COUNT=$(echo "$LOGS" | jq -r 'select(.event=="PRE") | .event' 2>/dev/null | wc -l | tr -d ' ')
  POST_COUNT=$(echo "$LOGS" | jq -r 'select(.event=="POST") | .event' 2>/dev/null | wc -l | tr -d ' ')

  echo "总事件数: $TOTAL"
  echo "  PreToolUse:  $PRE_COUNT"
  echo "  PostToolUse: $POST_COUNT"
  echo ""

  echo "--- 工具使用频率 ---"
  echo "$LOGS" | jq -r 'select(.event=="PRE") | .tool_name' 2>/dev/null | sort | uniq -c | sort -rn || true
  echo ""

  echo "--- 风险分布 ---"
  echo "$LOGS" | jq -r '.risk_level' 2>/dev/null | sort | uniq -c | sort -rn || true
  echo ""

  echo "--- 安全事件 (risk_level != none) ---"
  echo "$LOGS" | jq 'select(.risk_level != "none") | {timestamp, tool_name, risk_level, blocked_by, stdout: .stdout[0:200]}' 2>/dev/null || true

elif [ "$SECURITY_ONLY" = true ]; then
  if [ "$FOLLOW" = true ]; then
    follow_stream | jq 'select(.risk_level != "none")' 2>/dev/null || true
  else
    read_all | jq 'select(.risk_level != "none")' 2>/dev/null || true
  fi

elif [ "$DUMP" = true ]; then
  [ -f "$COLLECTOR_FILE" ] && cat "$COLLECTOR_FILE"

elif [ "$DIFF" = true ]; then
  echo "=== 交叉验证 ==="
  echo ""

  if [ ! -f "$COLLECTOR_FILE" ]; then
    echo "权威日志不存在: $COLLECTOR_FILE"
  fi
  if [ ! -f "$AGENT_FILE" ]; then
    echo "备份日志不存在: $AGENT_FILE"
  fi

  COLLECTOR_COUNT=$( [ -f "$COLLECTOR_FILE" ] && wc -l < "$COLLECTOR_FILE" | tr -d ' ' || echo "0" )
  AGENT_COUNT=$( [ -f "$AGENT_FILE" ] && wc -l < "$AGENT_FILE" | tr -d ' ' || echo "0" )
  echo "权威日志 (collector): $COLLECTOR_COUNT 条"
  echo "备份日志 (agent):    $AGENT_COUNT 条"

  # 时间戳范围对比
  if [ -f "$COLLECTOR_FILE" ] && [ "$COLLECTOR_COUNT" -gt 0 ]; then
    C_FIRST=$(head -1 "$COLLECTOR_FILE" | jq -r '.timestamp' 2>/dev/null)
    C_LAST=$(tail -1 "$COLLECTOR_FILE" | jq -r '.timestamp' 2>/dev/null)
    echo "  时间范围: $C_FIRST ~ $C_LAST"
  fi
  if [ -f "$AGENT_FILE" ] && [ "$AGENT_COUNT" -gt 0 ]; then
    A_FIRST=$(head -1 "$AGENT_FILE" | jq -r '.timestamp' 2>/dev/null)
    A_LAST=$(tail -1 "$AGENT_FILE" | jq -r '.timestamp' 2>/dev/null)
    echo "  时间范围: $A_FIRST ~ $A_LAST"
  fi

  echo ""
  if [ "$AGENT_COUNT" -gt "$COLLECTOR_COUNT" ]; then
    GAP=$((AGENT_COUNT - COLLECTOR_COUNT))
    echo "⚠️  备份比权威多 $GAP 条 → collector 可能有过停机窗口"
  elif [ "$COLLECTOR_COUNT" -gt "$AGENT_COUNT" ]; then
    GAP=$((COLLECTOR_COUNT - AGENT_COUNT))
    echo "⚠️  权威比备份多 $GAP 条 → agent 备份写入可能有问题"
  else
    echo "✅ 记录数一致"
  fi

else
  # 默认: 实时查看
  if [ "$FOLLOW" = true ]; then
    follow_stream | while IFS= read -r line; do
      format_line "$line"
    done
  else
    read_all | while IFS= read -r line; do
      format_line "$line"
    done
  fi
fi

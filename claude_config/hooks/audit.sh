#!/bin/bash
# ============================================================
# audit.sh — Claude Code Hook 审计脚本 (Log Offloading + Deep)
#
# 核心设计：
#   1. TCP → collector (权威路径), workspace (便捷副本)
#   2. JSON 通过 stdin 喂给 Python，不经过环境变量
#   3. stdout 截断、安全转义、结构化字段
#   4. tool_input/tool_response 用 --argjson 保留为真正的 JSON 对象
# ============================================================
set -u

SCHEMA_VERSION="1.0"
AUDIT_SOURCE="hook"
MAX_STDOUT_LENGTH=4096
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EVENT="${1:-UNKNOWN}"
WORKSPACE_LOG="/app/workspace/audit-trail.log"

INPUT_JSON=$(cat 2>/dev/null || true)
if [ -z "$INPUT_JSON" ] || ! echo "$INPUT_JSON" | jq empty 2>/dev/null; then
  INPUT_JSON="{}"
fi

TOOL_NAME=$(echo "$INPUT_JSON" | jq -r '.tool_name // "unknown"')
EVENT_NAME=$(echo "$INPUT_JSON" | jq -r '.hook_event_name // ""')

RAW_STDOUT=""
RAW_STDERR=""
EXIT_CODE=""
INTERRUPTED="false"

if [ "$EVENT" = "POST" ]; then
  RAW_STDOUT=$(echo "$INPUT_JSON" | jq -r '.tool_response.stdout // ""')
  RAW_STDERR=$(echo "$INPUT_JSON" | jq -r '.tool_response.stderr // ""')
  EXIT_CODE=$(echo "$INPUT_JSON" | jq -r '.tool_response.exitCode // ""')
  INTERRUPTED=$(echo "$INPUT_JSON" | jq -r '.tool_response.interrupted // "false"')
  [ "$EXIT_CODE" = "null" ] && EXIT_CODE=""
fi

STDOUT_TRUNCATED="false"
if [ "${#RAW_STDOUT}" -gt "$MAX_STDOUT_LENGTH" ]; then
  STDOUT_TRUNCATED="true"
  RAW_STDOUT="${RAW_STDOUT:0:$MAX_STDOUT_LENGTH}...[truncated]"
fi

# --- 安全事件检测 ---
RISK_LEVEL="none"
BLOCKED_BY=""

combined="$RAW_STDOUT $RAW_STDERR"
cmd_input=$(echo "$INPUT_JSON" | jq -r '.tool_input.command // ""' 2>/dev/null || true)

if echo "$combined" | grep -qiE "ERR_ACCESS_DENIED|403 Forbidden|Blocked by Zero-Trust"; then
  RISK_LEVEL="low"; BLOCKED_BY="squid|nginx"
elif echo "$combined" | grep -qi "Read-only file system"; then
  RISK_LEVEL="low"; BLOCKED_BY="read_only_fs"
elif echo "$combined" | grep -qiE "docker: command not found|containerd: command not found"; then
  RISK_LEVEL="low"; BLOCKED_BY="tool_not_available"
fi

if echo "$cmd_input" | grep -qiE '\brm\s+-rf\b|\bdd\s+if=|\b:\(\)\s*\{|\bchmod\s+777\b|\b(curl|wget)[^;&|]*[|][[:space:]]*(sh|bash)\b|\b(sh|bash)[[:space:]]+<\(|\b(curl|wget)[[:space:]][^;&|]*((-|--)(o|O|output)[=[:space:]]|>)[^;&|]*([;&]|&&)[[:space:]]*(chmod[[:space:]]+\+x[[:space:]]+[^;&|]*([;&]|&&)[[:space:]]*)?(\./|sh[[:space:]]+|bash[[:space:]]+)|python3?[[:space:]].*urllib.*(request|urlopen).*exec|python3?[[:space:]].*subprocess.*check_output'; then
  RISK_LEVEL="medium"
  [ -z "$BLOCKED_BY" ] && BLOCKED_BY="dangerous_pattern"
fi
if echo "$cmd_input" | grep -qiE '(^|[;&|[:space:]])(pip3?|python3?[[:space:]]+-m[[:space:]]+pip)[[:space:]]+install\b|(^|[;&|[:space:]])npm[[:space:]]+(install|ci)\b|(^|[;&|[:space:]])git[[:space:]]+clone\b'; then
  RISK_LEVEL="medium"
  [ -z "$BLOCKED_BY" ] && BLOCKED_BY="external_code_fetch_or_package_install"
fi
if echo "$cmd_input" | grep -qiE '(^|[;&|[:space:]])(npx|pnpm[[:space:]]+dlx|yarn[[:space:]]+dlx|bunx)\b|(^|[;&|[:space:]])(npm[[:space:]]+install([[:space:]]+[^;&|]*)?[[:space:]]+(-g|--global)([[:space:]]|$)|yarn[[:space:]]+global[[:space:]]+add\b|pnpm[[:space:]]+add([[:space:]]+[^;&|]*)?[[:space:]]+-g([[:space:]]|$)|pip3?[[:space:]]+install([[:space:]]+[^;&|]*)?[[:space:]]+--user([[:space:]]|$)|python3?[[:space:]]+-m[[:space:]]+pip[[:space:]]+install([[:space:]]+[^;&|]*)?[[:space:]]+--user([[:space:]]|$)|pipx[[:space:]]+install\b)|(^|[;&|[:space:]])((pip3?|python3?[[:space:]]+-m[[:space:]]+pip)[[:space:]]+install[^;&|]*(git\+https?://|https?://)|(npm|pnpm|yarn)[[:space:]]+(install|add)[^;&|]*(git\+https?://|https?://|github:))|git[[:space:]]+clone[^;&|]*([;&]|&&)[[:space:]]*(cd[[:space:]]+[^;&|]+[;&][[:space:]]*)?(sh[[:space:]]+|bash[[:space:]]+|\.\/[^[:space:];&|]*|make[[:space:]]+install\b|npm[[:space:]]+run\b|python3?[[:space:]]+setup\.py\b)'; then
  RISK_LEVEL="high"
  [ -z "$BLOCKED_BY" ] && BLOCKED_BY="blocked_remote_code_execution_or_install"
fi
if echo "$cmd_input" | grep -qiE '(^|[[:space:]])[^;|&]*(\.gemini|oauth_creds|\.env|secret|token|credential)[^;|&]*'; then
  RISK_LEVEL="high"
  [ -z "$BLOCKED_BY" ] && BLOCKED_BY="credential_directory_access"
fi
if echo "$cmd_input" | grep -qiE '(^|[;&|][[:space:]]*)(sudo|su[[:space:]]+-|passwd|useradd|usermod)([[:space:]]|$)'; then
  RISK_LEVEL="high"
  [ -z "$BLOCKED_BY" ] && BLOCKED_BY="privilege_escalation_attempt"
fi
if echo "$cmd_input" | grep -qiE '(^|[;&|[:space:]])(nmap|masscan)\b|\bnc[[:space:]][^;&|]*-[A-Za-z]*z|for[[:space:]]+[^;&|]*in[[:space:]][^;&|]*(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)'; then
  RISK_LEVEL="high"
  [ -z "$BLOCKED_BY" ] && BLOCKED_BY="network_scan"
fi
if echo "$cmd_input" | grep -qiE 'git[[:space:]]+config.*hooksPath|git[[:space:]]+-c[[:space:]].*hooksPath|git[[:space:]]+commit.*--no-verify|git[[:space:]]+commit.*[[:space:]]-n([[:space:]]|$)|GIT_CONFIG_NOSYSTEM'; then
  RISK_LEVEL="high"
  [ -z "$BLOCKED_BY" ] && BLOCKED_BY="git_hook_bypass_attempt"
elif echo "$cmd_input" | grep -qiE 'git[[:space:]]+reset[[:space:]].*--hard|git[[:space:]]+clean[[:space:]].*-[A-Za-z]*f[A-Za-z]*[dx]?|git[[:space:]]+restore([[:space:]][^;&|]*)?[[:space:]]+(\.|:/)([[:space:];&|]|$)|git[[:space:]]+checkout([[:space:]][^;&|]*)?[[:space:]]+--[[:space:]]+(\.|:/)([[:space:];&|]|$)|git[[:space:]]+branch[[:space:]]+-D\b|git[[:space:]]+rebase\b|git[[:space:]]+push[[:space:]].*(--force|-f)([[:space:]]|$)'; then
  RISK_LEVEL="high"
  [ -z "$BLOCKED_BY" ] && BLOCKED_BY="destructive_git_operation"
elif echo "$cmd_input" | grep -qiE '(^|[;&|][[:space:]]*)git[[:space:]]+(add|commit|push|tag|branch|checkout|restore|reset|clean|rebase)\b'; then
  RISK_LEVEL="medium"
  [ -z "$BLOCKED_BY" ] && BLOCKED_BY="git_write_or_history_operation"
elif echo "$cmd_input" | grep -qiE '(^|[;&|][[:space:]]*)git[[:space:]]+(status|diff|log|show)\b'; then
  RISK_LEVEL="low"
  [ -z "$BLOCKED_BY" ] && BLOCKED_BY="git_read_operation"
fi

# --- 构建审计日志 JSON (--argjson 深嵌套版) ---
AUDIT_JSON=$(jq -c -n \
  --arg schema_version "$SCHEMA_VERSION" \
  --arg audit_source "$AUDIT_SOURCE" \
  --arg timestamp "$TIMESTAMP" \
  --arg event "$EVENT" \
  --arg tool_name "$TOOL_NAME" \
  --arg hook_event_name "$EVENT_NAME" \
  --arg exit_code "$EXIT_CODE" \
  --arg interrupted "$INTERRUPTED" \
  --arg stdout_truncated "$STDOUT_TRUNCATED" \
  --arg stdout "$RAW_STDOUT" \
  --arg stderr "$RAW_STDERR" \
  --arg risk_level "$RISK_LEVEL" \
  --arg blocked_by "$BLOCKED_BY" \
  --argjson tool_input "$(echo "$INPUT_JSON" | jq '.tool_input // {}')" \
  --argjson tool_response "$(echo "$INPUT_JSON" | jq '.tool_response // {}')" \
  '{
    schema_version: $schema_version,
    audit_source: $audit_source,
    timestamp: $timestamp,
    event: $event,
    tool_name: $tool_name,
    hook_event_name: $hook_event_name,
    exit_code: $exit_code,
    interrupted: $interrupted,
    stdout_truncated: $stdout_truncated,
    stdout: $stdout,
    stderr: $stderr,
    risk_level: $risk_level,
    blocked_by: $blocked_by,
    tool_input: $tool_input,
    tool_response: $tool_response
  }' 2>/dev/null || echo "{}")

# --- 发送到 Collector (TCP 主路径) ---
# JSON 通过 stdin 传入 Python，不经过环境变量
python3 -c "
import socket, sys, json, time
line = sys.stdin.read().rstrip('\n')
if not line:
    sys.exit(0)
json.loads(line)
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(2)
try:
    s.connect(('collector', 5140))
    s.sendall((line + '\n').encode())
except Exception:
    pass
finally:
    s.close()
" <<< "$AUDIT_JSON" 2>/dev/null || true

# --- 便捷副本（工作区日志，Agent 可读写但非权威） ---
if [ "$EVENT" = "PRE" ]; then
  {
    echo "${TIMESTAMP} | 🎯 意图 | ${TOOL_NAME} | event=${EVENT_NAME}"
    echo "  COMMAND: $(echo "$INPUT_JSON" | jq -r '.tool_input.command // ""')"
  } >> "$WORKSPACE_LOG" 2>/dev/null || true
else
  {
    echo "${TIMESTAMP} | ✅ 完成 | ${TOOL_NAME} | event=${EVENT_NAME} | risk=${RISK_LEVEL}"
    echo "  STDOUT: $(echo "$RAW_STDOUT" | head -3)"
    echo "  EXIT: ${EXIT_CODE}"
  } >> "$WORKSPACE_LOG" 2>/dev/null || true
fi

exit 0

#!/bin/bash
set -u

SCHEMA_VERSION="1.0"
AUDIT_SOURCE="stop_hook"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
WORKSPACE_LOG="/app/workspace/audit-trail.log"
MAX_SUMMARY_LENGTH=320

INPUT_JSON=$(cat 2>/dev/null || true)
if [ -z "$INPUT_JSON" ] || ! echo "$INPUT_JSON" | jq empty 2>/dev/null; then
  INPUT_JSON="{}"
fi

stop_hook_active=$(echo "$INPUT_JSON" | jq -r '.stop_hook_active // "false"')
if [ "$stop_hook_active" = "true" ]; then
  exit 0
fi

last_message=$(echo "$INPUT_JSON" | jq -r '.last_assistant_message // ""')
summary=$(printf '%s' "$last_message" \
  | tr '\n\r' '  ' \
  | sed 's/[[:space:]]\+/ /g' \
  | sed 's/^ //; s/ $//' \
  | cut -c1-"$MAX_SUMMARY_LENGTH")

tail_summary=$(python3 -c '
import re, sys
text = sys.stdin.read()
text = re.sub(r"\s+", " ", text).strip()
parts = [p.strip() for p in re.split(r"(?<=[。！？.!?])\s*", text) if p.strip()]
base = parts[-1] if parts else text
print(base if base else "")
' <<< "$last_message" 2>/dev/null || true)

if [ -z "$summary" ]; then
  summary="Claude Code 已结束本轮回复"
fi
if [ -z "$tail_summary" ]; then
  tail_summary="已结束本轮回复"
fi

AUDIT_JSON=$(jq -c -n \
  --arg schema_version "$SCHEMA_VERSION" \
  --arg audit_source "$AUDIT_SOURCE" \
  --arg timestamp "$TIMESTAMP" \
  --arg event "TASK_FINISHED" \
  --arg tool_name "Stop" \
  --arg hook_event_name "Stop" \
  --arg summary "$summary" \
  --arg tail_summary "$tail_summary" \
  '{
    schema_version: $schema_version,
    audit_source: $audit_source,
    timestamp: $timestamp,
    event: $event,
    tool_name: $tool_name,
    hook_event_name: $hook_event_name,
    risk_level: "none",
    blocked_by: "",
    summary: $summary,
    tail_summary: $tail_summary
  }' 2>/dev/null || echo "{}")

python3 -c "
import json, socket, sys
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

if [ -d "$(dirname "$WORKSPACE_LOG")" ]; then
  {
    echo "${TIMESTAMP} | 🏁 结束 | Stop"
    echo "  SUMMARY: ${summary}"
  } >> "$WORKSPACE_LOG" 2>/dev/null || true
fi

exit 0

#!/bin/bash
# ============================================================
# guard-read.sh — 阻断 CC Read 工具访问 .gemini 凭据目录
# PreToolUse hook for Read matcher only
# ============================================================
set -u

INPUT_JSON=$(cat 2>/dev/null || true)
if [ -z "$INPUT_JSON" ] || ! echo "$INPUT_JSON" | jq empty 2>/dev/null; then
  exit 0
fi

file_path=$(echo "$INPUT_JSON" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)

if [ -z "$file_path" ] || [ "$file_path" = "null" ]; then
  exit 0
fi

if echo "$file_path" | grep -qiE '\.gemini'; then
  echo "BLOCKED: credential directory access via Read tool: $file_path" >&2
  exit 2
fi

exit 0

#!/bin/bash
set -e
SANDBOX_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

MODELS=(
  "deepseek-v4-pro"
  "deepseek-v4-flash"
  "claude-opus"
  "claude-sonnet"
  "gemini-pro"
  "gpt-5"
)

show_usage() {
  echo "用法："
  echo "  $0 <模型名>"
  echo ""
  echo "可用模型："
  current=$(grep "^ANTHROPIC_MODEL=" "$SANDBOX_DIR/.env" 2>/dev/null | cut -d= -f2)
  for m in "${MODELS[@]}"; do
    if [ "$m" = "$current" ]; then
      echo "  ► $m  ← 当前"
    else
      echo "    $m"
    fi
  done
}

switch_model() {
  local model="$1"
  local env_file="$SANDBOX_DIR/.env"

  case "$model" in
    deepseek-v4-pro)   subagent="deepseek-v4-flash" ;;
    claude-opus)       subagent="claude-sonnet" ;;
    claude-sonnet)     subagent="claude-sonnet" ;;
    gemini-pro)        subagent="gemini-pro" ;;
    gpt-5)             subagent="gpt-5" ;;
    *)                 subagent="$model" ;;
  esac

  sed -i '' "s|^ANTHROPIC_MODEL=.*|ANTHROPIC_MODEL=${model}|" "$env_file"
  sed -i '' "s|^ANTHROPIC_DEFAULT_OPUS_MODEL=.*|ANTHROPIC_DEFAULT_OPUS_MODEL=${model}|" "$env_file"
  sed -i '' "s|^ANTHROPIC_DEFAULT_SONNET_MODEL=.*|ANTHROPIC_DEFAULT_SONNET_MODEL=${model}|" "$env_file"
  sed -i '' "s|^ANTHROPIC_DEFAULT_HAIKU_MODEL=.*|ANTHROPIC_DEFAULT_HAIKU_MODEL=${subagent}|" "$env_file"
  sed -i '' "s|^CLAUDE_CODE_SUBAGENT_MODEL=.*|CLAUDE_CODE_SUBAGENT_MODEL=${subagent}|" "$env_file"

  echo "✅ 已切换到：$model（subagent: $subagent）"
  echo "⚠️  执行以下命令生效："
  echo "   cd $SANDBOX_DIR && docker compose down agent && docker compose up -d agent"
}

case "${1:-}" in
  "") show_usage ;;
  *)  switch_model "$1" ;;
esac

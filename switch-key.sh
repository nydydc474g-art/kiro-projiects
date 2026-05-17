#!/bin/bash
set -e
SANDBOX_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

show_usage() {
  echo "用法："
  echo "  $0 deepseek sk-你的新key"
  echo "  $0 anthropic sk-ant-你的新key"
  echo "  $0 gemini 你的key"
  echo "  $0 cliproxyapi sk-cliproxy-新key"
  echo ""
  echo "当前 key（脱敏）："
  grep -E "^(DEEPSEEK|ANTHROPIC|GEMINI|CLIPROXYAPI)_KEY=" "$SANDBOX_DIR/.env" 2>/dev/null | \
    sed 's/\(=.\{8\}\).*/\1***/'
}

update_key() {
  local provider="$1"
  local new_key="$2"
  local key_name="${provider^^}_API_KEY"

  if grep -q "^${key_name}=" "$SANDBOX_DIR/.env" 2>/dev/null; then
    sed -i '' "s|^${key_name}=.*|${key_name}=${new_key}|" "$SANDBOX_DIR/.env"
  else
    echo "${key_name}=${new_key}" >> "$SANDBOX_DIR/.env"
  fi

  echo "✅ 已更新 $key_name"
  echo "⚠️  执行以下命令生效："
  echo "   cd $SANDBOX_DIR && docker compose down litellm && docker compose up -d litellm"
}

case "${1:-}" in
  deepseek|anthropic|gemini|cliproxyapi) update_key "$1" "$2" ;;
  *) show_usage ;;
esac

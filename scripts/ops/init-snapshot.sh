#!/bin/bash
# init-snapshot.sh
# 初始化或刷新 .snapshot/ — agent 只读快照
# 用途：watcher 启动时调用；apply 成功后调用以更新快照

set -eo pipefail

PROJECT_DIR="${PROJECT_DIR:-$HOME/ai_sandbox}"
SNAPSHOT_DIR="$PROJECT_DIR/agent_workspace/.snapshot"

# 哪些路径是 agent 应该看到的"生产配置树"
# 注意：绝对不包括 .env / audit_spool / .git / cliproxyapi/auths / agent_workspace 自身
INCLUDE_PATHS=(
  "docker-compose.yml"
  "Dockerfile"
  "proxy"
  "collector"
  "notifier"
  "config"
  "scripts/ops/verifications"
  "claude_config"
)

# 排除模式（即使在 INCLUDE 内也不进 snapshot）
EXCLUDE_PATTERNS=(
  ".env"
  ".env.*"
  "*.log"
  "auths"
  ".git"
)

mkdir -p "$SNAPSHOT_DIR"

# 清空旧 snapshot（保留目录本身以维持挂载）
find "$SNAPSHOT_DIR" -mindepth 1 -delete 2>/dev/null || true

# 复制白名单路径
for p in "${INCLUDE_PATHS[@]}"; do
  src="$PROJECT_DIR/$p"
  if [ -e "$src" ]; then
    dest="$SNAPSHOT_DIR/$p"
    mkdir -p "$(dirname "$dest")"
    if [ -d "$src" ]; then
      # 用 rsync 排除敏感模式
      EXCLUDE_ARGS=()
      for ex in "${EXCLUDE_PATTERNS[@]}"; do
        EXCLUDE_ARGS+=(--exclude="$ex")
      done
      rsync -a "${EXCLUDE_ARGS[@]}" "$src/" "$dest/"
    else
      cp "$src" "$dest"
    fi
  fi
done

# 写 snapshot ID
SNAPSHOT_ID=$(date -u +"%Y%m%dT%H%M%SZ")
echo "$SNAPSHOT_ID" > "$SNAPSHOT_DIR/.snapshot-id"

echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] snapshot refreshed: $SNAPSHOT_ID"
echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] snapshot path: $SNAPSHOT_DIR"

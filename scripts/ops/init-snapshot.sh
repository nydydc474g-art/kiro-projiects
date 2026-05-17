#!/bin/bash
# init-snapshot.sh
# 初始化或刷新 .snapshot/ — agent 只读快照
# 用途：watcher 启动时调用；apply 成功后调用以更新快照
#
# 设计要点：
#   - 严格白名单复制，绝不包含 .env / audit_spool / .git / cliproxyapi/auths
#   - 原子刷新：rsync 到临时目录 → mv 替换，避免 agent 在中途读到半成品
#   - 写入 .snapshot-id（时间戳）+ .snapshot-hash（内容哈希），双校验防漂移

set -eo pipefail

PROJECT_DIR="${PROJECT_DIR:-$HOME/ai_sandbox}"
WORKSPACE_DIR="$PROJECT_DIR/agent_workspace"
SNAPSHOT_DIR="$WORKSPACE_DIR/.snapshot"

# SNAPSHOT_INCLUDED：agent 通过 .snapshot 可读的"生产现状"
# 注意：这与 PROPOSAL_PATH_ALLOWED 不同——见 OPS-WATCHER-DESIGN.md
# claude_config/ 在这里（agent 能看到当前防线）
# 但不在 PROPOSAL_PATH_ALLOWED 内（agent 不能提案改动）
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
  "__pycache__"
  "*.pyc"
)

# 必备命令：优先 rsync，fallback 到 cp（macOS 默认有 rsync）
USE_RSYNC=1
if ! command -v rsync >/dev/null 2>&1; then
  USE_RSYNC=0
fi

# macOS 用 shasum -a 256，Linux 用 sha256sum
if command -v sha256sum >/dev/null 2>&1; then
  SHA256_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA256_CMD="shasum -a 256"
else
  echo "ERROR: neither sha256sum nor shasum found" >&2
  exit 1
fi

# 准备工作
mkdir -p "$WORKSPACE_DIR"

# 临时构建目录（在同一文件系统上，保证 mv 原子）
STAGING_DIR=$(mktemp -d "$WORKSPACE_DIR/.snapshot.staging.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT

# 构建 rsync 排除参数
EXCLUDE_ARGS=()
for ex in "${EXCLUDE_PATTERNS[@]}"; do
  EXCLUDE_ARGS+=(--exclude="$ex")
done

# 复制白名单路径到 staging
copy_with_excludes() {
  local src="$1" dest="$2"
  if [ "$USE_RSYNC" = "1" ]; then
    rsync -a "${EXCLUDE_ARGS[@]}" "$src/" "$dest/"
  else
    # cp -r + find 删除 fallback
    cp -r "$src/." "$dest/"
    for ex in "${EXCLUDE_PATTERNS[@]}"; do
      find "$dest" -name "$ex" -prune -exec rm -rf {} + 2>/dev/null || true
    done
  fi
}

for p in "${INCLUDE_PATHS[@]}"; do
  src="$PROJECT_DIR/$p"
  if [ -e "$src" ]; then
    dest="$STAGING_DIR/$p"
    mkdir -p "$(dirname "$dest")"
    if [ -d "$src" ]; then
      mkdir -p "$dest"
      copy_with_excludes "$src" "$dest"
    else
      cp "$src" "$dest"
    fi
  fi
done

# 生成 snapshot ID（UTC 时间戳）
SNAPSHOT_ID=$(date -u +"%Y%m%dT%H%M%SZ")
echo "$SNAPSHOT_ID" > "$STAGING_DIR/.snapshot-id"

# 生成内容哈希：只算业务文件内容（排除 .snapshot-id 和 .snapshot-hash 自身）
# 这样：
#   - snapshot-id 不同 + hash 相同 = 同秒/快速重刷无内容变化 → 可接受
#   - snapshot-id 相同 + hash 不同 = 时间戳没变但内容漂了 → 异常，需告警
#   - snapshot-id 不同 + hash 不同 = 正常的内容变更
SNAPSHOT_HASH=$(
  cd "$STAGING_DIR" && \
  find . -type f ! -name '.snapshot-hash' ! -name '.snapshot-id' -print0 | \
  LC_ALL=C sort -z | \
  xargs -0 $SHA256_CMD | \
  $SHA256_CMD | \
  awk '{print $1}'
)
echo "$SNAPSHOT_HASH" > "$STAGING_DIR/.snapshot-hash"

# 原子替换：先把旧 snapshot 移到一边，再把 staging 上位
# 这一步要尽量短，避免 agent 看到中间状态
OLD_BACKUP=""
if [ -d "$SNAPSHOT_DIR" ]; then
  OLD_BACKUP=$(mktemp -d "$WORKSPACE_DIR/.snapshot.old.XXXXXX")
  mv "$SNAPSHOT_DIR" "$OLD_BACKUP/snapshot"
fi
mv "$STAGING_DIR" "$SNAPSHOT_DIR"

# 清理旧 snapshot
if [ -n "$OLD_BACKUP" ]; then
  rm -rf "$OLD_BACKUP"
fi

# trap 不需要再清 staging（已被 mv 走）
trap - EXIT

echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] snapshot refreshed"
echo "  path: $SNAPSHOT_DIR"
echo "  id:   $SNAPSHOT_ID"
echo "  hash: $SNAPSHOT_HASH"

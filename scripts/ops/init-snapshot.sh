#!/bin/bash
# init-snapshot.sh
# 初始化或刷新 .snapshot/ — agent 只读快照
# 用途：watcher 启动时调用；apply 成功后调用以更新快照
#
# Phase 1.2 设计：
#   .snapshot/                     ← 稳定挂载点（compose bind mount 不变）
#     versions/
#       <snapshot-id>/             ← 每次 refresh 创建新版本目录
#         .snapshot-id
#         .snapshot-hash
#         <files>
#     current -> versions/<id>     ← 相对 symlink（整目录搬走仍自洽）
#     .snapshot-id                 ← 顶层指针，方便 agent helper 读
#     .snapshot-hash               ← 顶层指针
#
# refresh 7 步定序：
#   1. 构建 versions/<new-id>.staging/
#   2. 写入 .snapshot-id / .snapshot-hash 到 staging 内
#   3. mv staging → versions/<new-id>           (原子)
#   4. ln -sfn "versions/<new-id>" current.new  (相对路径)
#   5. mv current.new current                    (原子切换)
#   6. 顶层 metadata 原子写（.snapshot-id / .snapshot-hash）
#   7. 双向校验（顶层 == versions/current 内）

set -eo pipefail

PROJECT_DIR="${PROJECT_DIR:-$HOME/ai_sandbox}"
WORKSPACE_DIR="$PROJECT_DIR/agent_workspace"
SNAPSHOT_DIR="$WORKSPACE_DIR/.snapshot"
VERSIONS_DIR="$SNAPSHOT_DIR/versions"

# SNAPSHOT_INCLUDED：agent 通过 .snapshot/current 可读的"生产现状"
# 注意：这与 PROPOSAL_PATH_ALLOWED 不同——见 OPS-WATCHER-DESIGN.md
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

# 排除模式
EXCLUDE_PATTERNS=(
  ".env"
  ".env.*"
  "*.log"
  "auths"
  ".git"
  "__pycache__"
  "*.pyc"
)

# 工具发现
USE_RSYNC=1
if ! command -v rsync >/dev/null 2>&1; then
  USE_RSYNC=0
fi

if command -v sha256sum >/dev/null 2>&1; then
  SHA256_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA256_CMD="shasum -a 256"
else
  echo "ERROR: neither sha256sum nor shasum found" >&2
  exit 1
fi

mkdir -p "$WORKSPACE_DIR" "$SNAPSHOT_DIR" "$VERSIONS_DIR"

# 生成 snapshot ID
SNAPSHOT_ID=$(date -u +"%Y%m%dT%H%M%SZ")

# === Step 1: 构建 staging 目录 ===
STAGING_DIR="$VERSIONS_DIR/${SNAPSHOT_ID}.staging"
if [ -e "$STAGING_DIR" ]; then
  rm -rf "$STAGING_DIR"
fi
mkdir -p "$STAGING_DIR"
trap 'rm -rf "$STAGING_DIR" "$VERSIONS_DIR/$SNAPSHOT_ID.staging" 2>/dev/null || true' EXIT

# 构建 rsync 排除参数
EXCLUDE_ARGS=()
for ex in "${EXCLUDE_PATTERNS[@]}"; do
  EXCLUDE_ARGS+=(--exclude="$ex")
done

copy_with_excludes() {
  local src="$1" dest="$2"
  if [ "$USE_RSYNC" = "1" ]; then
    rsync -a "${EXCLUDE_ARGS[@]}" "$src/" "$dest/"
  else
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

# === Step 2: 写入元数据到 staging ===
echo "$SNAPSHOT_ID" > "$STAGING_DIR/.snapshot-id"

# 计算内容哈希：排除 .snapshot-id 和 .snapshot-hash 自身
SNAPSHOT_HASH=$(
  cd "$STAGING_DIR" && \
  find . -type f ! -name '.snapshot-hash' ! -name '.snapshot-id' -print0 | \
  LC_ALL=C sort -z | \
  xargs -0 $SHA256_CMD | \
  $SHA256_CMD | \
  awk '{print $1}'
)
echo "$SNAPSHOT_HASH" > "$STAGING_DIR/.snapshot-hash"

# === Step 3: 原子提交 staging → versions/<id> ===
VERSION_DIR="$VERSIONS_DIR/$SNAPSHOT_ID"
if [ -e "$VERSION_DIR" ]; then
  # 同 ID 已存在（同秒重刷），先移走旧的
  rm -rf "$VERSION_DIR"
fi
mv "$STAGING_DIR" "$VERSION_DIR"

# === Step 4-5: 切换 current symlink（相对路径 + 原子覆盖）===
# ln -sfn 在 Linux/macOS 上都是原子替换 symlink（内部 rename(2)）
# 不能先创 current.new 再 mv：mv 看到 current 是 symlink 指向目录，
# 会把 current.new 移动 *进* 那个目录，而不是替换 symlink 本身！
cd "$SNAPSHOT_DIR"
# 防御：如果 current 存在且是真目录，停止（手工修复）
if [ -e "current" ] && [ ! -L "current" ]; then
  echo "FATAL: 'current' exists but is not a symlink (manual cleanup needed)" >&2
  exit 1
fi
ln -sfn "versions/$SNAPSHOT_ID" "current"
cd - >/dev/null

# === Step 6: 顶层 metadata 原子写 ===
# 先写 .new，再 mv，避免半成品被读到
echo "$SNAPSHOT_ID" > "$SNAPSHOT_DIR/.snapshot-id.new"
mv -f "$SNAPSHOT_DIR/.snapshot-id.new" "$SNAPSHOT_DIR/.snapshot-id"
echo "$SNAPSHOT_HASH" > "$SNAPSHOT_DIR/.snapshot-hash.new"
mv -f "$SNAPSHOT_DIR/.snapshot-hash.new" "$SNAPSHOT_DIR/.snapshot-hash"

# === Step 7: 双向校验 ===
TOP_ID=$(cat "$SNAPSHOT_DIR/.snapshot-id")
TOP_HASH=$(cat "$SNAPSHOT_DIR/.snapshot-hash")
INNER_ID=$(cat "$SNAPSHOT_DIR/current/.snapshot-id")
INNER_HASH=$(cat "$SNAPSHOT_DIR/current/.snapshot-hash")

VERIFY_OK=1
if [ "$TOP_ID" != "$INNER_ID" ]; then
  echo "WARN: snapshot-id mismatch (top=$TOP_ID, current=$INNER_ID)" >&2
  VERIFY_OK=0
fi
if [ "$TOP_HASH" != "$INNER_HASH" ]; then
  echo "WARN: snapshot-hash mismatch (top=$TOP_HASH, current=$INNER_HASH)" >&2
  VERIFY_OK=0
fi

# 校验完成，trap 不再需要清理
trap - EXIT

if [ "$VERIFY_OK" = "1" ]; then
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] snapshot refreshed"
else
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] snapshot refreshed WITH WARNINGS"
fi
echo "  path:   $SNAPSHOT_DIR"
echo "  id:     $SNAPSHOT_ID"
echo "  hash:   $SNAPSHOT_HASH"
echo "  current → versions/$SNAPSHOT_ID"

# 列出当前所有版本（不自动 prune）
N_VERSIONS=$(find "$VERSIONS_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '*.staging' 2>/dev/null | wc -l | tr -d ' ')
echo "  versions kept: $N_VERSIONS (no auto-prune in Phase 1.2)"

#!/bin/bash
set -eo pipefail

echo "========================================="
echo "  第二层安全审计: 宿主机暴露面 + Docker Daemon"
echo "  运行环境: macOS (Docker Desktop)"
echo "========================================="

# --- 配置 ---
PROJECT_DIR="/Users/caimin/ai_sandbox"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
ENV_FILE="$PROJECT_DIR/.env"
WORKSPACE_DIR="$PROJECT_DIR/agent_workspace"

PASS=0
WARN=0
FAIL=0

pass() { echo "✅ $1"; PASS=$((PASS + 1)); }
warn() { echo "⚠️  $1"; WARN=$((WARN + 1)); }
fail() { echo "❌ $1"; FAIL=$((FAIL + 1)); }

echo -e "\n=== 1. Docker Socket 暴露 ==="

# 1.1 compose 中是否挂载了 docker.sock
if grep -q 'docker.sock' "$COMPOSE_FILE" 2>/dev/null; then
  fail "docker-compose.yml 挂载了 /var/run/docker.sock"
else
  pass "docker-compose.yml 未挂载 Docker socket"
fi

# 1.2 宿主机 docker.sock 权限（macOS 通过 VM，检查 socket 文件）
SOCK_PATH="/var/run/docker.sock"
if [ -e "$SOCK_PATH" ]; then
  SOCK_PERMS=$(stat -f "%Lp" "$SOCK_PATH" 2>/dev/null || stat -c "%a" "$SOCK_PATH" 2>/dev/null || echo "unknown")
  SOCK_GROUP=$(stat -f "%Sg" "$SOCK_PATH" 2>/dev/null || stat -c "%G" "$SOCK_PATH" 2>/dev/null || echo "unknown")
  if [ "$SOCK_PERMS" = "660" ] || [ "$SOCK_PERMS" = "600" ]; then
    pass "Docker socket 权限为 $SOCK_PERMS (group: $SOCK_GROUP)"
  elif [ "$SOCK_PERMS" = "666" ]; then
    warn "Docker socket 权限为 666（任意用户可访问），建议收紧"
  else
    warn "Docker socket 权限为 $SOCK_PERMS (group: $SOCK_GROUP)，请确认是否合理"
  fi
else
  pass "宿主机 $SOCK_PATH 不存在（macOS Docker Desktop 通过 VM 隔离）"
fi

# 1.3 确认没有容器以 privileged 运行
PRIV_CONTAINERS=$(docker ps --format '{{.Names}}' | while read -r name; do
  docker inspect --format '{{.HostConfig.Privileged}}' "$name" 2>/dev/null | grep -c "true" || true
done | paste -sd+ - | bc 2>/dev/null || echo "0")
if [ "$PRIV_CONTAINERS" -gt 0 ] 2>/dev/null; then
  fail "存在 $PRIV_CONTAINERS 个 privileged 容器"
else
  pass "无 privileged 容器运行"
fi


echo -e "\n=== 2. 端口暴露 ==="

# 2.1 compose 文件中的 ports 声明
PUBLISHED_PORTS=$(grep -cE '^\s+ports:' "$COMPOSE_FILE" || true)
if [ "$PUBLISHED_PORTS" -gt 0 ]; then
  fail "docker-compose.yml 存在 ports: 声明，服务可能暴露到宿主机"
  grep -A2 'ports:' "$COMPOSE_FILE" || true
else
  pass "docker-compose.yml 零端口 publish（所有服务仅内网通信）"
fi

# 2.2 运行时实际绑定检查
LISTENING=$(docker ps --format '{{.Names}}\t{{.Ports}}' | grep -v "^$" || true)
HAS_HOST_BIND=$(echo "$LISTENING" | grep -c '0.0.0.0\|:::' || true)
if [ "$HAS_HOST_BIND" -gt 0 ]; then
  fail "存在绑定到宿主机的端口:"
  echo "$LISTENING" | grep '0.0.0.0\|:::'
else
  pass "运行时无容器端口绑定到宿主机 0.0.0.0/:::"
fi


echo -e "\n=== 3. 宿主机文件权限 ==="

# 3.1 agent_workspace 权限
if [ -d "$WORKSPACE_DIR" ]; then
  WS_OWNER=$(stat -f "%Su:%Sg" "$WORKSPACE_DIR" 2>/dev/null || stat -c "%U:%G" "$WORKSPACE_DIR" 2>/dev/null || echo "unknown")
  WS_PERMS=$(stat -f "%Lp" "$WORKSPACE_DIR" 2>/dev/null || stat -c "%a" "$WORKSPACE_DIR" 2>/dev/null || echo "unknown")
  if [ "$WS_PERMS" = "755" ] || [ "$WS_PERMS" = "750" ]; then
    pass "agent_workspace 权限 $WS_PERMS (owner: $WS_OWNER)"
  elif [ "$WS_PERMS" = "777" ]; then
    fail "agent_workspace 权限为 777，任何人可读写"
  else
    warn "agent_workspace 权限 $WS_PERMS (owner: $WS_OWNER)，建议 750 或 755"
  fi
else
  warn "agent_workspace 目录不存在: $WORKSPACE_DIR"
fi

# 3.2 audit_spool 权限
AUDIT_DIR="$PROJECT_DIR/audit_spool"
if [ -d "$AUDIT_DIR" ]; then
  AS_OWNER=$(stat -f "%Su:%Sg" "$AUDIT_DIR" 2>/dev/null || stat -c "%U:%G" "$AUDIT_DIR" 2>/dev/null || echo "unknown")
  AS_PERMS=$(stat -f "%Lp" "$AUDIT_DIR" 2>/dev/null || stat -c "%a" "$AUDIT_DIR" 2>/dev/null || echo "unknown")
  pass "audit_spool 权限 $AS_PERMS (owner: $AS_OWNER)"
else
  warn "audit_spool 目录不存在: $AUDIT_DIR"
fi

# 3.3 claude_config 权限（应为只读挂载源）
CONFIG_DIR="$PROJECT_DIR/claude_config"
if [ -d "$CONFIG_DIR" ]; then
  CC_OWNER=$(stat -f "%Su:%Sg" "$CONFIG_DIR" 2>/dev/null || stat -c "%U:%G" "$CONFIG_DIR" 2>/dev/null || echo "unknown")
  CC_PERMS=$(stat -f "%Lp" "$CONFIG_DIR" 2>/dev/null || stat -c "%a" "$CONFIG_DIR" 2>/dev/null || echo "unknown")
  pass "claude_config 权限 $CC_PERMS (owner: $CC_OWNER) — compose 中以 :ro 挂载"
else
  warn "claude_config 目录不存在: $CONFIG_DIR"
fi


echo -e "\n=== 4. Docker Daemon 配置 ==="

# 4.1 Docker Desktop 版本
DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
pass "Docker Engine 版本: $DOCKER_VERSION"

# 4.2 userns-remap
USERNS=$(docker info --format '{{.SecurityOptions}}' 2>/dev/null || echo "")
if echo "$USERNS" | grep -q 'userns'; then
  pass "userns-remap 已启用"
else
  warn "userns-remap 未启用（macOS Docker Desktop 默认不支持，依赖 VM 隔离层）"
fi

# 4.3 seccomp
if echo "$USERNS" | grep -q 'seccomp'; then
  pass "seccomp 已启用（默认 profile）"
else
  warn "seccomp 信息未检测到"
fi

# 4.4 AppArmor / 等效机制
if echo "$USERNS" | grep -q 'apparmor'; then
  pass "AppArmor 已启用"
else
  # macOS 不使用 AppArmor，使用 sandbox/seatbelt
  warn "AppArmor 不可用（macOS 依赖 Docker Desktop VM 的 LinuxKit 沙箱）"
fi

# 4.5 Docker Desktop VM 隔离确认
DOCKER_PLATFORM=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || echo "unknown")
if echo "$DOCKER_PLATFORM" | grep -qi 'docker desktop\|linuxkit'; then
  pass "运行在 Docker Desktop VM 中 ($DOCKER_PLATFORM)，宿主机有额外 VM 隔离层"
else
  warn "运行环境: $DOCKER_PLATFORM（非 Docker Desktop，请确认隔离机制）"
fi

# 4.6 no-new-privileges 在 compose 中声明
NNP_COUNT=$(grep -c 'no-new-privileges' "$COMPOSE_FILE" || true)
SERVICES_SHOULD_HAVE=3  # agent, collector, notifier
if [ "$NNP_COUNT" -ge "$SERVICES_SHOULD_HAVE" ]; then
  pass "no-new-privileges 声明 $NNP_COUNT 处（agent/collector/notifier）"
else
  warn "no-new-privileges 仅声明 $NNP_COUNT 处，建议 agent/collector/notifier 均设置"
fi


echo -e "\n=== 5. 宿主机网络 ==="

# 5.1 宿主机监听端口（仅关注非系统端口）
echo "宿主机对外监听端口（排除 localhost-only）:"
EXTERNAL_LISTEN=$(lsof -iTCP -sTCP:LISTEN -nP 2>/dev/null | grep -v '127\.0\.0\.1\|localhost\|\[::1\]' | grep -v "^COMMAND" || true)
if [ -z "$EXTERNAL_LISTEN" ]; then
  pass "宿主机无非 localhost 的 TCP 监听端口"
else
  LISTEN_COUNT=$(echo "$EXTERNAL_LISTEN" | wc -l | tr -d ' ')
  warn "宿主机有 $LISTEN_COUNT 个非 localhost 监听端口（请人工确认是否必要）:"
  echo "$EXTERNAL_LISTEN" | head -20
fi

# 5.2 Tailscale 状态
if command -v tailscale >/dev/null 2>&1; then
  TS_STATUS=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('BackendState','unknown'))" 2>/dev/null || echo "unknown")
  if [ "$TS_STATUS" = "Running" ]; then
    warn "Tailscale 处于 Running 状态（远程可达），请确认 ACL 是否最小化"
  elif [ "$TS_STATUS" = "Stopped" ] || [ "$TS_STATUS" = "NeedsLogin" ]; then
    pass "Tailscale 状态: $TS_STATUS（不对外暴露）"
  else
    warn "Tailscale 状态: $TS_STATUS"
  fi
else
  pass "Tailscale 未安装或不在 PATH"
fi

# 5.3 SSH 服务
SSH_RUNNING=$(launchctl list 2>/dev/null | grep -c 'com.openssh.sshd' || true)
if [ "$SSH_RUNNING" -gt 0 ]; then
  warn "SSH 远程登录已启用（通过 macOS 共享设置），确认是否必要"
else
  pass "SSH 远程登录未启用"
fi

# 5.4 防火墙状态
FW_STATUS=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || echo "unknown")
if echo "$FW_STATUS" | grep -qi 'enabled'; then
  pass "macOS 应用防火墙已启用"
else
  warn "macOS 应用防火墙未启用，建议开启（系统设置 → 网络 → 防火墙）"
fi


echo -e "\n=== 6. 备份与恢复 ==="

# 6.1 agent_workspace 是否有 git 仓库
if [ -d "$WORKSPACE_DIR/.git" ]; then
  LAST_COMMIT=$(cd "$WORKSPACE_DIR" && git log -1 --format='%h %s (%cr)' 2>/dev/null || echo "unknown")
  pass "agent_workspace 有 Git 仓库，最新 commit: $LAST_COMMIT"
else
  warn "agent_workspace 没有 Git 仓库，无法通过 git 恢复"
fi

# 6.2 检查是否有定期 bundle/snapshot 机制
if crontab -l 2>/dev/null | grep -q 'git bundle\|rsync.*agent_workspace\|snapshot'; then
  pass "存在定期备份 cron job"
else
  warn "未检测到 agent_workspace 定期备份 cron job（建议: git bundle 或 rsync）"
fi

# 6.3 Time Machine 覆盖检查
TM_EXCLUDE=$(tmutil isexcluded "$WORKSPACE_DIR" 2>/dev/null || echo "unknown")
if echo "$TM_EXCLUDE" | grep -qi 'excluded'; then
  warn "agent_workspace 被 Time Machine 排除，无系统级备份覆盖"
else
  pass "agent_workspace 未被 Time Machine 排除（可作为最后恢复手段）"
fi


echo -e "\n=== 7. .env 保护 ==="

# 7.1 .env 文件权限
if [ -f "$ENV_FILE" ]; then
  ENV_PERMS=$(stat -f "%Lp" "$ENV_FILE" 2>/dev/null || stat -c "%a" "$ENV_FILE" 2>/dev/null || echo "unknown")
  ENV_OWNER=$(stat -f "%Su:%Sg" "$ENV_FILE" 2>/dev/null || stat -c "%U:%G" "$ENV_FILE" 2>/dev/null || echo "unknown")
  if [ "$ENV_PERMS" = "600" ] || [ "$ENV_PERMS" = "640" ]; then
    pass ".env 权限 $ENV_PERMS (owner: $ENV_OWNER)"
  elif [ "$ENV_PERMS" = "644" ]; then
    warn ".env 权限 $ENV_PERMS (world-readable)，建议 chmod 600"
  else
    warn ".env 权限 $ENV_PERMS (owner: $ENV_OWNER)，建议 600"
  fi
else
  warn ".env 文件不存在: $ENV_FILE"
fi

# 7.2 .env 是否被 git 跟踪
if [ -d "$PROJECT_DIR/.git" ]; then
  ENV_TRACKED=$(cd "$PROJECT_DIR" && git ls-files --error-unmatch .env 2>/dev/null && echo "tracked" || echo "untracked")
  if [ "$ENV_TRACKED" = "tracked" ]; then
    fail ".env 被 Git 跟踪！密钥可能泄露到远程仓库"
  else
    pass ".env 未被 Git 跟踪"
  fi

  # 7.3 .gitignore 中是否包含 .env
  if [ -f "$PROJECT_DIR/.gitignore" ]; then
    if grep -qE '^\s*\.env\s*$|^\s*\.env\b' "$PROJECT_DIR/.gitignore" 2>/dev/null; then
      pass ".gitignore 包含 .env 规则"
    else
      warn ".gitignore 未显式包含 .env 规则"
    fi
  else
    warn "$PROJECT_DIR/.gitignore 不存在"
  fi
fi

# 7.4 .env 内容是否明文（检查常见 key 变量是否有值）
if [ -f "$ENV_FILE" ]; then
  REAL_KEYS=$(grep -cE '^[A-Z_]+_KEY=.{8,}' "$ENV_FILE" 2>/dev/null || true)
  if [ "$REAL_KEYS" -gt 0 ]; then
    warn ".env 含 $REAL_KEYS 个明文 API Key（macOS Keychain 或 age 加密可进一步加固）"
  else
    pass ".env 无明文长 key（或使用了间接引用）"
  fi
fi


echo -e "\n=== 8. Docker 镜像供应链 ==="

# 8.1 基础镜像是否锁定 digest
echo "compose 引用的镜像:"
IMAGES_IN_COMPOSE=$(grep -E '^\s+image:' "$COMPOSE_FILE" | sed 's/.*image:\s*//' | tr -d '"' || true)
PINNED=0
UNPINNED=0
while IFS= read -r img; do
  [ -z "$img" ] && continue
  if echo "$img" | grep -q '@sha256:'; then
    pass "  $img — 已锁定 digest"
    PINNED=$((PINNED + 1))
  elif echo "$img" | grep -qE ':(latest|main-latest)$'; then
    warn "  $img — 使用 floating tag，建议锁定版本或 digest"
    UNPINNED=$((UNPINNED + 1))
  else
    warn "  $img — 未锁定 digest（但有版本 tag）"
    UNPINNED=$((UNPINNED + 1))
  fi
done <<< "$IMAGES_IN_COMPOSE"

# 8.2 本地构建镜像（Dockerfile）安全检查
echo ""
echo "本地 Dockerfile 基础镜像:"
DOCKERFILES=$(find "$PROJECT_DIR" -name 'Dockerfile' -not -path '*/.git/*' 2>/dev/null || true)
while IFS= read -r df; do
  [ -z "$df" ] && continue
  FROM_LINE=$(grep -m1 '^FROM ' "$df" 2>/dev/null || echo "unknown")
  if echo "$FROM_LINE" | grep -q '@sha256:'; then
    pass "  $df: $FROM_LINE — 已锁定"
  else
    warn "  $df: $FROM_LINE — 未锁定 digest"
  fi
done <<< "$DOCKERFILES"

# 8.3 镜像漏洞扫描提示
if command -v docker scout >/dev/null 2>&1; then
  pass "docker scout 可用，建议定期运行: docker scout cves <image>"
elif command -v trivy >/dev/null 2>&1; then
  pass "trivy 可用，建议定期运行: trivy image <image>"
else
  warn "未安装镜像漏洞扫描工具（建议: docker scout 或 trivy）"
fi


echo -e "\n========================================="
echo "  审计结果汇总"
echo "========================================="
echo "  PASS: $PASS"
echo "  WARN: $WARN"
echo "  FAIL: $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "🚨 存在 $FAIL 个 FAIL 项，需要立即处理"
  exit 1
elif [ "$WARN" -gt 3 ]; then
  echo "⚠️  存在 $WARN 个 WARN 项，建议逐项评估"
  exit 0
else
  echo "🟢 宿主机暴露面整体良好"
  exit 0
fi

# Ops Watcher 开发日志与设计文档

> 目标：让 agent 在容器内自主完成 Docker 基础设施开发（改 Dockerfile/compose/配置 → 触发重建 → 自测验证），无需人工逐步介入。

## 设计概要

```
agent（容器内）                 watcher（宿主机常驻）
    │                                │
    ├─ 修改配置文件 ──────────────────┤ （文件在 workspace 可写区域）
    │                                │
    ├─ 写 .ops/request.json ─────────┤
    │                                ├─ 检测到请求
    │                                ├─ 安全基线检查（白名单对比）
    │                                ├─ 通过 → docker compose up -d --build
    │                                ├─ 不通过 → 拒绝 + 写原因
    │                                ├─ 写 .ops/response.json
    ├─ 读 response.json ─────────────┤
    ├─ 容器内验证（curl/测试）────────┤
    │                                │
```

## 安全模型

### agent 能做什么

- ✅ 修改 Dockerfile（装包、改构建逻辑）
- ✅ 修改 docker-compose.yml（新增服务、改环境变量、改 depends_on）
- ✅ 修改 squid.conf / allowed_domains.txt
- ✅ 修改 collector/notifier 代码
- ✅ 写 request.json 触发 rebuild/restart
- ✅ 容器内验证结果

### agent 不能做什么

- ❌ 直接执行 docker 命令（容器内没有 docker CLI 和 socket）
- ❌ 修改 compose 安全基线字段而通过 watcher 检查
- ❌ 绕过 guard.sh（宿主机 :ro bind mount 覆盖镜像内容）
- ❌ 访问非白名单网络（squid.conf 在宿主机侧，compose 里 :ro 挂载）

### 为什么 Dockerfile 后门无效

| 攻击手法 | 为什么不生效 |
|----------|-------------|
| 装 docker CLI | 容器内无 docker.sock 挂载 |
| 装 ncat/socat 反弹 shell | squid 白名单拦截出站 |
| 改 guard.sh 内容 | compose bind mount :ro 覆盖镜像文件 |
| 加 cron job | read_only fs + 无 crond 运行 |
| 装提权工具 | cap_drop ALL + no-new-privileges |
| 改 entrypoint 绕过 hook | compose command 字段被基线锁定 |

### 三层防御关系

```
watcher 白名单基线 → 锁死 compose 运行时限制（不可放权）
compose bind mount → 锁死 guard/audit/squid.conf（不可篡改）
squid 白名单       → 锁死网络出口（不可外联）
```

## Watcher 安全检查：白名单基线

不做黑名单（"有没有加危险的东西"），做白名单对比（"安全字段有没有被改"）。

### 被保护的字段（agent 改了就拒绝执行）

针对 `agent` 服务：
- `read_only: true`
- `cap_drop: [ALL]`
- `security_opt: [no-new-privileges:true]`
- `volumes` 中的挂载路径和 :ro/:rw 模式
- 不允许出现：`privileged`、`cap_add`、`pid: host`、`network_mode: host`、`ipc: host`

针对所有服务：
- 不允许出现 `docker.sock` 挂载
- 不允许出现 `privileged: true`
- 网络必须包含 `sandbox_net`（internal: true）

### agent 可以自由修改的字段

- `image` / `build`
- `environment`（环境变量）
- `depends_on`
- `command` / `entrypoint`（但安全效果被 bind mount 和 compose 限制兜底）
- `tmpfs` 大小
- `mem_limit` / `cpus` / `pids_limit`（可放宽资源但不影响安全）
- 新增服务（但新服务也会被全局规则约束）

## 实施计划

### Phase 1：基础 watcher 脚本

- [ ] `ops-watcher.sh` — 宿主机常驻 fswatch 脚本
- [ ] 请求/响应协议：request.json → response.json
- [ ] 白名单动作：rebuild / restart / logs / status
- [ ] 白名单服务：6 个已有服务 + 可扩展
- [ ] 速率限制：同一服务 30 秒内只允许一次 rebuild

### Phase 2：安全基线检查

- [ ] `ops-security-check.sh` — watcher 调用的前置检查脚本
- [ ] 从 compose 提取安全关键字段并与基线文件对比
- [ ] 基线文件 `ops-baseline.json`（首次运行自动生成，人工确认后锁定）
- [ ] 全局黑名单扫描（docker.sock / privileged / host 网络等）
- [ ] 检查失败时写详细拒绝原因到 response.json

### Phase 3：配置文件可写

- [ ] 决定哪些配置文件放入 workspace 可写区域（或软链接方案）
- [ ] compose 中 agent 的 volumes 新增可写配置目录
- [ ] 确保 :ro bind mount 仍然覆盖运行时关键文件（guard/audit）

### Phase 4：agent 侧 helper

- [ ] agent 容器内的 `ops-request` 命令封装（写 request + 轮询 response）
- [ ] 超时处理（watcher 未响应时 agent 知道失败了）
- [ ] 与 audit.sh 集成（ops 操作也留审计痕迹）

### Phase 5：集成测试

- [ ] agent 修改白名单域名 → rebuild squid → 验证新域名可访问
- [ ] agent 修改 Dockerfile 装包 → rebuild agent → 验证包可用
- [ ] agent 尝试加 privileged → watcher 拒绝 → 验证拒绝消息
- [ ] agent 尝试挂载 docker.sock → watcher 拒绝
- [ ] agent 尝试去掉 cap_drop → watcher 拒绝
- [ ] 连续快速 rebuild → 速率限制生效

### Phase 6：文档与上线

- [ ] 更新 DOCKER-USAGE-MANUAL.md
- [ ] 更新 DOCKER-DEVELOPMENT-LOG.md
- [ ] watcher 启动方式（tmux / launchd / 手动）
- [ ] 生产同步 SOP：dev 验证 → diff review → rsync → e2e + host-audit

## 依赖

- macOS: `brew install fswatch jq`
- 宿主机已有: docker, docker compose, bash, git

## 已知约束

- bash 3.2：不用 set -u，grep 零匹配用 || true
- fswatch 事件可能重复触发：用 mv 原子消费 + 时间戳去重
- agent rebuild agent 会杀掉自己当前会话：可接受，新容器正常启动

## 决策记录

| 问题 | 决策 | 理由 |
|------|------|------|
| 配置文件放置 | 额外 bind mount 一个 `/project:rw` 目录，指向 `~/ai_sandbox` | agent 能改所有配置文件；但 guard/audit 仍由 `claude_config:/app/.claude:ro` 覆盖，运行时不可篡改 |
| 新增服务 | 必须预注册白名单，agent 不能自由加服务 | 新增服务可能绕过全局安全规则（比如加一个不走 sandbox_net 的服务），风险最小化 |
| Telegram 通知 | ✅ watcher 每次执行/拒绝都推通知 | 你手机能实时看到 agent 在干什么基础设施操作 |
| 人工确认模式 | ❌ 不做 | 违背目标（让 agent 自主闭环），安全靠基线检查兜底 |

### 配置文件方案细节

```yaml
# compose 中 agent 新增挂载
volumes:
  - .:/project:rw                        # agent 可改所有配置文件
  - ./agent_workspace:/app/workspace:rw  # 原有工作目录
  - ./claude_config:/app/.claude:ro      # guard/audit 不可篡改（覆盖 /project 里的同名目录）
  - ./audit_spool:/var/log/audit:ro      # 审计日志只读
```

安全保证：
- agent 能写 `/project/docker-compose.yml`、`/project/Dockerfile`、`/project/proxy/squid.conf`
- 但 `/app/.claude/` 由后挂载的 :ro 覆盖，agent 无法通过 `/project/claude_config/` 篡改运行时 guard
- watcher 白名单基线检查确保 compose 安全字段不变
- squid.conf 改了要 rebuild 才生效，rebuild 经 watcher 检查

### 新增服务预注册

agent 想加新服务时：
1. 修改 compose 添加服务定义
2. 写 request.json `{"action":"register_service","service":"gemini"}`
3. watcher **拒绝**，response 写："新增服务需人工确认，请通知操作者"
4. watcher 推 Telegram："agent 请求注册新服务 gemini，请确认"
5. 你确认后手动加入 watcher 白名单
6. 后续 agent 可以自由 rebuild/restart 该服务

这样 agent 能独立完成新服务的代码编写和配置，只有"首次注册"需要你点头。

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

### 配置文件方案：为什么 bind mount `.:/project:rw` 风险最小

三个候选方案对比：

| 方案 | agent 能改什么 | 新增风险 |
|------|---------------|----------|
| A. 软链接到 workspace | 只有你手动 ln -s 的文件 | 最小，但每次加新文件要你操作，违背自主化目标 |
| B. bind mount `.:/project:rw` | 整个 ai_sandbox | 中等 |
| C. 全放 workspace 内 | 整个项目结构在 workspace 里 | 最大（workspace 是 agent 唯一可写目录，混在一起容易误删） |

选 B 的核心论点：**agent 能"写"不等于能"生效"。**

```
agent 写 /project/docker-compose.yml    → 文件改了，但容器不会自动重启
agent 写 /project/claude_config/guard.sh → 文件改了，但当前运行时不受影响
agent 写 /project/proxy/squid.conf      → 文件改了，但 squid 没 reload
```

所有改动必须经过 watcher 的 rebuild 才能生效 → watcher 执行前做安全基线检查 → 检查不过不执行。

#### 敏感文件（如 guard.sh）的四层防护

| 层 | 机制 | 说明 |
|----|------|------|
| 1 | guard.sh 自身路径规则 | agent 用 Bash/Write/Edit 工具改敏感路径 → exit 2 阻断 |
| 2 | :ro bind mount 覆盖 | CC 运行时读的是 `/app/.claude:ro`，不是 `/project/claude_config/` |
| 3 | watcher 检查 | rebuild 前可额外验证关键文件 hash |
| 4 | git diff | 你最终同步生产前 review 所有改动 |

第 1 层在日常就直接挡住，后面三层是纵深冗余。

#### compose 挂载细节

```yaml
volumes:
  - .:/project:rw                        # agent 可改所有配置文件
  - ./agent_workspace:/app/workspace:rw  # 原有工作目录
  - ./claude_config:/app/.claude:ro      # guard/audit 不可篡改（后挂载覆盖）
  - ./audit_spool:/var/log/audit:ro      # 审计日志只读
```

### 新增服务预注册：为什么不允许自由加服务

核心威胁：全局规则覆盖不全时新服务可绕过安全约束。

```yaml
# 这三行单独看都不违规，但组合起来开了宿主机端口
image: alpine
network_mode: bridge
ports:
  - "0.0.0.0:2222:22"
```

全局规则要覆盖所有危险组合 → 黑名单思路 → 永远有绕过。

预注册成本极低：
1. agent 写好新服务的 compose 配置
2. watcher 推 Telegram："agent 请求注册新服务 gemini"
3. 你看一眼确认（只需确认一次）
4. 一行命令加入白名单
5. 后续 agent 自由 rebuild/restart

#### "点错头"会怎样

你误确认了一个恶意服务 → agent 能 rebuild 它 → **但 watcher 仍对所有服务执行全局安全检查**：

- 无 privileged → ✅ 拦截
- 无 docker.sock → ✅ 拦截
- 无 cap_add → ✅ 拦截
- 必须 sandbox_net → ✅ 拦截
- 无 host 网络/pid/ipc → ✅ 拦截
- **无 ports 声明** → ✅ 拦截（零端口 publish 是全局约束）

点头只是让 watcher 认识这个服务名，**不是跳过检查**。

最坏后果 = agent 多跑一个无害但无用的容器，浪费一点内存。无安全风险。

### 全局安全检查清单（对所有服务生效，包括新注册的）

```bash
# watcher 对 compose 文件的全局扫描（任何一项命中即拒绝）
- privileged: true
- docker.sock（任何路径形式）
- cap_add
- pid: host
- network_mode: host
- ipc: host
- userns_mode: host
- ports:（零端口 publish 是项目基线）
- /:/（挂载宿主机根目录）
- /Users/（挂载用户 home）
- /var/run/（挂载运行时目录）
```

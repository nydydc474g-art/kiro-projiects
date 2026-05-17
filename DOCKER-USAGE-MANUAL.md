# Docker 沙箱使用手册

## 安全不变量（新 agent 必读）

| 事实 | 说明 |
|------|------|
| agent 内无真实 API key | `ANTHROPIC_API_KEY=sandbox-dummy-token`；真实 LLM key 在 litellm 侧 |
| squid ACL 强制白名单 | `http_access deny all` 兜底，非白名单域名直接拒绝 |
| workspace 是唯一可写宿主机路径 | `/app/workspace` → 宿主机 `agent_workspace/`；其余全部 `:ro` 或 tmpfs |
| 容器根文件系统只读 | `read_only: true` + `cap_drop: ALL` + `no-new-privileges` |
| 审计不可篡改 | agent 对 `audit_spool` 只有 `:ro`；权威日志由独立 collector 容器写入 |
| guard.sh 是速刹车不是绝对防线 | 正则可被间接绕过，真正的安全边界是容器隔离 + 网络白名单 |
| Gemini CLI 已移除 | 容器内无 gemini/gemini-helper/OAuth 凭据，相关文档为历史参考 |

---

## 架构概览（CC-Only 最终版）

```
Docker Compose (6 services)
  ├── squid        :3128    HTTP/HTTPS 代理白名单（ACL 强制）
  ├── litellm      :4000    LLM 路由（DeepSeek/Claude/Gemini/GPT-5）
  ├── collector    :5140    审计日志收集（权威）
  ├── notifier     -        Telegram 安全告警
  ├── cliproxyapi  :8317    GPT-5 OAuth 兼容接口
  └── agent        -        CC 沙箱（Claude Code 唯一 agent）

网络:
  sandbox_net (internal: true)  → agent/collector/notifier 内网通信
  internet_access (internal: false) → squid/litellm/cliproxyapi 出外网
```

### 通讯流程

```
CC 执行工具 → PreToolUse hook → audit.sh 记录意图 (PRE)
            → guard.sh 检查 Bash 命令 (通过/block)
            → 执行
            → PostToolUse hook → audit.sh 记录结果 (POST)
            → TCP → collector:5140 → audit-collector.jsonl
            → notifier 轮询 → Telegram 告警 (medium/high)
```

### 网络架构

```
sandbox_net (internal: true)       internet_access
  ├── agent                         ├── squid
  ├── collector                     ├── litellm
  ├── notifier                      └── cliproxyapi
  └── cliproxyapi (双网卡)
```

- agent 出网必须经 squid:3128，squid 通过 ACL 引用 `allowed_domains.txt`
- Anthropic 域名被 `extra_hosts` 劫持到 1.1.1.1（防绕过 litellm）
- CONNECT 仅允许 443 端口
- squid DNS 8.8.8.8（sandbox_net 无 DNS 服务）

---

## 快速启动

### 前置条件

- Docker Desktop 已安装运行
- `.env` 文件已配置 API keys（LLM key、Telegram token 等）

### 启动

```bash
cd /Users/caimin/ai_sandbox
docker compose up -d
docker compose ps   # 预期 6 个服务均为 Up
```

### 进入容器

```bash
docker compose exec -it agent bash
cc --dangerously-skip-permissions
```

### 停止

```bash
docker compose down
```

---

## 日常使用

```bash
# 非交互
docker compose exec agent cc -p "分析项目结构"

# 交互
docker compose exec -it agent cc --dangerously-skip-permissions

# 恢复会话
docker compose exec -it agent cc --resume <session-id>

# 查看服务状态
docker compose ps
docker compose logs --tail=50 agent
docker compose logs --tail=20 collector
```

---

## 安全机制

### 容器层

| 机制 | 配置 |
|------|------|
| 能力限制 | `cap_drop: ALL` |
| 提权禁止 | `no-new-privileges: true` |
| 只读根文件系统 | `read_only: true` |
| 资源限制 | `mem_limit: 2g`、`cpus: 2.0`、`pids_limit: 256` |
| 内网隔离 | `sandbox_net: internal: true` |
| 域名劫持 | `extra_hosts` 劫持 Anthropic 域名到 1.1.1.1 |

### Hook 层（PreToolUse / PostToolUse）

| Hook | 触发范围 | 职责 |
|------|----------|------|
| audit.sh PRE | 所有工具 | 记录意图 + 风险分级 |
| guard.sh PRE | Bash | 阻断高危命令 |
| guard-read.sh PRE | Read | 阻断 .gemini 目录访问 |
| audit.sh POST | 所有工具 | 记录结果 |
| stop-summary.sh | Stop | 写 TASK_FINISHED 到 collector |

### guard.sh 阻断列表

| 类别 | 阻断内容 |
|------|----------|
| Git destructive | reset --hard、clean -fd、restore .、push -f、rebase、branch -D |
| Git hook bypass | --no-verify、hooksPath 篡改 |
| 远程执行 | curl/wget pipe sh、curl -o && bash、python urllib exec |
| 远程包执行 | npx、pnpm dlx、yarn dlx、bunx |
| 全局安装 | npm -g、pip --user、pipx |
| 远程包安装 | pip git+https://、npm https:// |
| clone 后执行 | git clone && ./install.sh |
| 网络扫描 | nmap、nc -z、内网 IP 遍历 |
| 凭据目录 | 任何命令访问 `.gemini/` 路径 |
| 系统破坏 | rm -rf、dd if=、mkfs |
| workspace 框架 | 删除 .git/inbox/output/scratch/exports |

### 允许的操作

```bash
pip install requests          # 普通包安装（标记 medium）
npm install lodash            # 普通包安装（标记 medium）
git clone https://...         # 克隆（标记 medium）
git status / diff / log       # 读操作（标记 low）
```

### 网络白名单

| 类别 | 域名 |
|------|------|
| LLM API | api.anthropic.com, api.deepseek.com, chatgpt.com |
| Google | .google.com, .gstatic.com, .googleusercontent.com |
| GitHub | github.com, api.github.com, raw.githubusercontent.com |
| PyPI | pypi.org, files.pythonhosted.org |
| npm | registry.npmjs.org, npmjs.com, nodejs.org |
| 文档 | docs.python.org, developer.mozilla.org, .readthedocs.io |
| 语言生态 | go.dev, crates.io, stackoverflow.com |
| 搜索 API | api.tavily.com, api.search.brave.com, api.exa.ai, google.serper.dev |
| Reader | r.jina.ai, s.jina.ai |
| 告警 | api.telegram.org |

---

## 监控与审计

### 权威日志

```bash
# 最新 20 条
tail -20 audit_spool/audit-collector.jsonl | jq -c '{ts:.timestamp,event:.event,tool:.tool_name,risk:.risk_level}'

# 只看被阻断的高风险
tail -500 audit_spool/audit-collector.jsonl | jq -c 'select(.risk_level=="high")'

# 按工具统计
tail -1000 audit_spool/audit-collector.jsonl | jq -r '.tool_name' | sort | uniq -c | sort -rn
```

### Notifier 行为

| 场景 | 通知 |
|------|------|
| 正常完成 | 简短完成摘要 |
| 单次高风险已拦截 | "✅ 高风险已处理"，通常不需要介入 |
| 5 分钟内同类重复 3 次 | "🔴 需要判断"，建议立即查看 |
| 已发过升级提醒后收口 | 轻量收口，不重复制造紧张 |

通知回答四件事：发生了什么 / 当前状态 / 你需要处理吗 / 建议先查什么。

### 宿主机监控

```bash
./scripts/ops/monitor.sh --stats          # 统计汇总
./scripts/ops/monitor.sh --security-only  # 只看安全事件
./scripts/ops/monitor.sh --diff           # collector vs agent 差距
./scripts/ops/monitor.sh --dump           # 全文输出
./scripts/ops/healthcheck.sh              # 服务状态 + collector 心跳 + 最近发送异常
```

`collector` 每 300 秒写入一次 `HEARTBEAT`；宿主机 `healthcheck.sh` 以 600 秒为过期阈值。这样即使 agent 长时间没有任务，也能区分“系统安静”与“审计链断了”。

---

## E2E 回归测试

修改 hook/安全规则后运行：

```bash
cd /Users/caimin/ai_sandbox
./scripts/e2e-test.sh
```

共 11 组验证：
1. 防护规则挂载（宿主机 + 容器内 + 运行时三层一致）
2. Gemini CLI 已从 agent 运行面移除
3. Squid 白名单文件内容齐全
4. **Squid 白名单实际生效**（非白名单域名被拒）
5. `search-helper` 已安装
6. 常规链路落盘（Audit → Collector）
7. 意图留痕与事前阻断（PRE + guard exit 2）
8. 物理隔离边界（`/var/log/audit` 只读）
9. 限定路径 Git 回滚
10. 真实 CC 触发（Write 工具全链路审计）
11. Git / 远程脚本执行 / 开发增强网络高风险专项

全部绿勾 = 安全基座稳定。测试期间收到少量"高风险已处理"通知属于预期。

---

## 故障诊断

| 现象 | 检查 |
|------|------|
| CC API 连接失败 | `docker compose logs litellm --tail=20` |
| 命令被 BLOCKED | guard.sh 规则触发，看 stderr |
| 非白名单域名被拒 | 正常行为；如需新增：`echo domain >> proxy/allowed_domains.txt && docker compose restart squid` |
| notifier 不推送 | `docker compose logs notifier --tail=20`、检查 Telegram token/chat_id |
| 不确定系统是否整体健康 | `./scripts/ops/healthcheck.sh` |
| collector 是否只是空闲而非失效 | `tail -50 audit_spool/audit-collector.jsonl \| jq -c 'select(.event=="HEARTBEAT")'` |
| 重启后 hook 不生效 | `docker compose restart agent`（启动时从 `/app/.claude` 拷贝到 `~/.claude`） |
| squid 拒绝日志 | `docker compose logs squid --tail=50 \| grep DENIED` |

---

## 配置修改指南

| 修改项 | 操作 |
|--------|------|
| 模型路由 | 编辑 `config/litellm_config.yaml` → `docker compose restart litellm` |
| 白名单 | `echo domain >> proxy/allowed_domains.txt` → `docker compose restart squid` |
| Hook 规则 | 编辑 `claude_config/hooks/` → `docker compose restart agent` → 验证 grep |
| CC 权限 | 编辑 `claude_config/settings.json` → `docker compose restart agent` |
| 镜像重建 | `docker compose build agent && docker compose up -d agent` |

注意：`squid.conf` 通过 `acl allowed_sites dstdomain "/etc/squid/allowed_domains.txt"` 引用白名单文件，`http_access deny all` 兜底。修改白名单只需编辑 txt 文件并重启 squid，不需要改 squid.conf。

---

## 维护与清理

```bash
# 重建镜像
docker compose build agent
docker compose up -d --build agent

# 清理 .tmp artifact
docker compose exec agent rm -rf /app/workspace/.tmp/gemini-*

# 日志轮转（已配置）
# collector/notifier: max-size 10m, max-file 3
# agent: max-size 50m, max-file 5

# 备份
# agent_workspace/ 是宿主机目录，直接 git commit 或 cp 即可
```

---

## 审计日志格式

每条记录是单行 JSON（jq -c 输出）：

| 字段 | 说明 |
|------|------|
| schema_version | "1.0" |
| timestamp | UTC ISO8601 |
| event | PRE / POST / TASK_FINISHED / TCP_FAIL / RATE_LIMIT |
| tool_name | Bash / Read / Write / Edit / Stop 等 |
| risk_level | none / low / medium / high |
| blocked_by | 阻断原因（空 = 未阻断） |
| exit_code | 命令退出码（仅 POST） |
| tool_input | 原始输入 JSON |
| tool_response | 原始响应 JSON |

---

## 参考文件

| 文件 | 内容 |
|------|------|
| `DOCKER-DEVELOPMENT-LOG.md` | 端到端开发日志（含当前状态摘要） |
| `HANDOFF.md` | 交接文档 |
| `audit-framework-maintenance.md` | 审计框架维护手册 |
| `MEMORY.md` | 项目协作偏好 |
| `scripts/e2e-test.sh` | 11 组回归测试 |
| `scripts/ops/monitor.sh` | 宿主机审计分析 |

---

## 附录：历史设计（已废弃，仅供回溯）

> 以下内容记录 2026-05-12 ~ 05-13 Gemini Wrapper 阶段的设计。2026-05-14 之后已从 agent 镜像移除 Gemini CLI、gemini-helper、Policy Engine 和容器内 OAuth 凭据。**不要按以下命令操作当前环境。**

### Gemini Wrapper 命令

```bash
gemini-helper search "query"       # 网络搜索
gemini-helper scan "prompt"        # 项目扫描
gemini-helper review "prompt"      # 代码审查
gemini-helper audit "prompt"       # 安全审计
gemini-helper mechanical "prompt"  # 批量分析
gemini-helper diagnose "prompt"    # 日志诊断
gemini-helper shell                # 人工交互（OAuth 登录入口）
```

### Gemini 认证

每次容器重启后需 OAuth 登录（约 30s）。凭据存 tmpfs，用完即删。

### 五层防线（历史）

1. CC 自身安全判断
2. Gemini CLI 自带沙箱（路径白名单）
3. guard.sh 目录级规则
4. guard-read.sh（CC Read 工具）
5. audit.sh（high risk 留痕）

### 已知绕过（历史）

- YOLO 模式下 Gemini CLI 不走 CC hook
- 通配符 `.gem?ni`、变量拼接、软链接、base64 编码可绕过 guard.sh 正则
- 缓解：用完即删凭据，物理删除是最终保障

### 旧架构图（含 Gemini Wrapper 层）

```
Docker 容器层 → CC Hook 层 → Wrapper 层（gemini-helper）→ Gemini CLI 沙箱 → 审计层 → 网络层
```

详细图表见 `DOCKER-DEVELOPMENT-LOG.md` 第三、四阶段。

### 已废弃组件

- Gemini Wrapper（gemini-helper）：已从镜像移除
- Gemini CLI Policy Engine（security.toml）：随 Gemini CLI 移除
- Token Server（gemini-proxy）：移至 `deprecated/`

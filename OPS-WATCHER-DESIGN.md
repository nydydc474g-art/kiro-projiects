# Ops Watcher 开发日志与设计文档（v2）

> 目标：让 agent 能自主迭代基础设施（改 Dockerfile/compose/配置 → 触发重建 → 自测验证），同时保持当前安全模型不变。
>
> 核心原则：**agent 提交变更提案，watcher 浓缩判断材料，人类做最终裁决，机器执行落地。**

## 设计演进史

### v1 初稿（已废弃）

直觉方案：bind mount `.:/project:rw` + watcher 自动 rebuild。

被否决的核心原因（功劳归 review）：

1. `.:/project:rw` 暴露 `.env` / `audit_spool/` / `cliproxyapi/auths/` / `.git/`，击穿"workspace 唯一可写"基线
2. watcher 自动 rebuild = agent 拥有受限的宿主机执行代理，性质从"沙箱内程序"变成"宿主机控制面参与者"
3. `:ro` 覆盖只是延时器：agent 改 `/project/claude_config/guard.sh` → rebuild agent → 新容器加载被篡改的 guard
4. Dockerfile 后门不一定要逃逸宿主机，能污染下一代 agent 也已经足够危险
5. "完全自治"和"完全安全"在新增基础设施这件事上不天然兼容

### v2 终稿（本文档）

核心改变：**Proposal-Apply 模式 + 人工裁决闸门 + 机器铺路。**

agent 永远不直接接触生产树。它在 workspace 里产出"提案"，watcher 自动做安全检查与材料整理，你通过 Telegram 看 10 秒后跑一条命令裁决，apply 脚本完成落地与回滚。

## 设计概要

```
agent (容器内)              watcher (宿主机常驻)             你 (手机/SSH)
   │                                │                              │
   ├─ 读 /app/workspace/.snapshot/ ──┤ (只读快照)                   │
   ├─ 写 ops-proposals/<id>/        │                              │
   │   ├── manifest.json            │                              │
   │   └── 候选文件                  │                              │
   └─ 写 request.json ──────────────┼─ 检测                        │
                                    ├─ 静态检查（临时目录预演）       │
                                    ├─ 风险分级 LOW/MEDIUM/HIGH/BLOCK │
                                    ├─ stale/conflict 检测           │
                                    ├─ 生成 diff 摘要                │
                                    ├─ 写 ops_spool/events.jsonl    │
                                    └─ Telegram 通知 ──────────────►│
                                                                    │
                                                          ops <id>  │
                                    ┌─ apply-proposal.sh ◄──────────┘
                                    │   ├─ 拒绝 dirty tree
                                    │   ├─ git tag snapshot
                                    │   ├─ 复制 manifest 声明文件
                                    │   ├─ git commit (only declared)
                                    │   ├─ docker compose up <affected>
                                    │   ├─ settling window + healthcheck
                                    │   ├─ verification subset
                                    │   └─ 成功 → 写 ops-results/<id>.json
                                    │      失败 → git reset --hard + 重建
                                    │
                                    └─ 通知（你 + agent）
```

## 安全模型

### 不变量（绝对不会被破坏）

1. **agent 内无真实 API key**
2. **agent 唯一可写宿主机路径 = `agent_workspace/`**
3. **审计不可篡改**（audit_spool 对 agent :ro，guard.sh 对 agent 不可写）
4. **零端口 publish 到宿主机**
5. **container 安全字段不被放权**（read_only/cap_drop/no-new-privileges）

### agent 能做什么

- ✅ 读 `/app/workspace/.snapshot/` 看当前生产配置
- ✅ 写 `ops-proposals/<id>/` 产出候选文件
- ✅ 在 manifest.json 声明改了哪些文件、为什么、影响哪些服务、如何验证
- ✅ 写 request.json 触发审批流

### agent 不能做什么

- ❌ 直接读写生产树（`.env` / `audit_spool/` / `.git/` / `cliproxyapi/auths/` 等不在挂载范围）
- ❌ 直接执行 docker 命令（无 docker.sock 挂载）
- ❌ 触碰 guard.sh / audit.sh / settings.json（生成 BLOCK proposal，不可审批）
- ❌ 让 watcher 跑任意 shell（verification 是命名检查项，不是自由命令）

### Dockerfile/compose 后门为什么仍然失效

| 攻击手法 | 防御层 |
|---------|-------|
| 改 guard.sh 内容 | 路径触发 BLOCK，不进入审批流 |
| 加 `privileged: true` | watcher 全局规则拒绝 |
| 挂载 docker.sock | watcher 全局规则拒绝 |
| 挂载宿主机敏感路径 | watcher 全局规则拒绝（/、/Users/、/var/run/、/etc/） |
| 加 `ports:` 暴露宿主机 | watcher 全局规则拒绝 |
| 装恶意工具到镜像 | 容器运行时仍受 squid + cap_drop + read_only 约束，工具有也用不了 |
| 改 entrypoint 绕过 hook | claude_config:/app/.claude:ro 后挂载覆盖 |

## Proposal 协议

### 目录结构

```
agent_workspace/
├── .snapshot/                       # watcher 维护的只读快照
│   ├── .snapshot-id                 # 当前快照 ID（YYYYMMDDTHHMMSSZ）
│   ├── docker-compose.yml
│   ├── Dockerfile
│   ├── proxy/
│   ├── collector/
│   └── notifier/
├── ops-proposals/<id>/
│   ├── manifest.json
│   └── <候选文件，路径与生产对应>
├── ops-requests/
│   └── <id>.json                    # agent 触发审批
└── ops-results/
    └── <id>.json                    # watcher 写回结果，agent 可读
```

### manifest.json 格式

```json
{
  "proposal_id": "20260517-1430",
  "base_snapshot_id": "20260517T142015Z",
  "supersedes": null,
  "reason": "增加 Tavily 搜索能力",
  "expected_effect": "agent 能通过 squid 访问 api.tavily.com",
  "affected_services": ["squid"],
  "rebuild_strategy": "minimal",
  "changes": [
    {
      "path": "proxy/allowed_domains.txt",
      "type": "modify",
      "summary": "+ api.tavily.com"
    }
  ],
  "verification": [
    "agent_can_resolve_tavily",
    "squid_denies_example_org"
  ]
}
```

字段说明：

| 字段 | 必填 | 说明 |
|------|------|------|
| proposal_id | 是 | 时间戳 ID，全局唯一 |
| base_snapshot_id | 是 | 基于哪一版生产快照生成。watcher apply 前对比，不一致则 stale |
| supersedes | 否 | 显式声明替代哪个 pending proposal。无声明且文件冲突 → CONFLICT |
| reason / expected_effect | 是 | 给人看的，必须能在 Telegram 摘要里说明白 |
| affected_services | 是 | 决定 rebuild 范围。完整性会被静态检查校验 |
| rebuild_strategy | 是 | minimal（只 rebuild 列出的服务）/ full |
| changes | 是 | 严格枚举每个改动文件，path 必须在白名单内 |
| verification | 否 | 命名检查项，从 `scripts/ops/verifications/` 选 |

## Watcher 安全检查

### 风险分级（实际效果而非文件类型）

| 级别 | 判定规则 |
|------|---------|
| **LOW** | 只动数据/文案，不改安全字段，不改基础设施。例：白名单加条目、notifier 文案、collector 行为微调 |
| **MEDIUM** | 改了构建产物或代理规则。例：Dockerfile 装包、squid.conf 改 ACL、新增白名单整段域名 |
| **HIGH** | 任何 compose 改动 / 新服务 / 资源/网络/存储拓扑 / 任何修改 hook 的尝试 |
| **BLOCK** | 触碰 guard.sh / audit.sh / settings.json / .env / audit_spool 路径 |

**BLOCK 处理**：可观测但不可审批
- proposal 仍生成，watcher 标记 BLOCKED
- 不进入 apply 队列
- Telegram 红色警告通知（这代表 agent 试图触碰绝对不变量，可能是行为异常的早期信号）
- 写 ops_spool/events.jsonl
- 写 ops-results/<id>.json status=blocked，agent 知道结果

### 全局规则（对所有改动生效，包括新服务）

任何一项命中即拒绝：

```
- privileged: true
- docker.sock 挂载（任何路径形式）
- cap_add
- pid: host / network_mode: host / ipc: host / userns_mode: host
- ports: 任何形式
- 挂载 / / /Users/ / /var/run/ / /etc/ 等宿主机敏感路径
```

### 路径白名单（changes 数组中的 path 必须在内）

```
docker-compose.yml
Dockerfile
proxy/squid.conf
proxy/allowed_domains.txt
collector/**          (除 Dockerfile 外的代码文件)
notifier/**
config/litellm_config.yaml
scripts/ops/verifications/*.sh   (新增命名检查项)
```

不在白名单的 path → 拒绝。

### 静态检查流程（隔离临时目录预演）

```bash
TMP=/tmp/proposal-${ID}
cp -r .snapshot/* $TMP/
cp -r ops-proposals/${ID}/<changes> $TMP/<相应路径>

docker compose -f $TMP/docker-compose.yml config       # YAML 解析+校验
hadolint $TMP/Dockerfile                                # Dockerfile lint
diff -r .snapshot/ $TMP/                                # 生成 diff 摘要

# 全局规则扫描 + 风险分级
# 验证 affected_services 完整性（改了 Dockerfile 但 affected_services 没列 agent → 标记可疑）
# 验证 verification 都是已注册的命名检查项
```

预演不污染生产。

### 状态检查

| 状态 | 触发条件 |
|------|---------|
| pending | 新提交，待 apply |
| stale | base_snapshot_id != current_snapshot_id（生产已变化） |
| conflict | 同文件已有 pending proposal 且未声明 supersedes |
| blocked | 触碰绝对不变量 |
| applied | 成功落地 |
| rejected | 静态检查失败 |
| rolled_back | apply 后失败已回滚 |
| expired | TTL 24h 未处理 |

## Apply 流程

### 命令接口

```bash
ops <id>                       # 等同 apply-proposal.sh <id> --apply（LOW/MEDIUM）
ops-diff <id>                  # 看完整 diff
ops-apply --high <id>          # HIGH 必须显式 --high，制造心理摩擦
ops-apply <id> --check         # 重跑安全检查不落地
ops-apply <id> --stage         # 复制到 staging 不 commit
ops-apply <id> --apply         # 真正落地
ops-apply <id> --rollback      # 回滚到上一个 snapshot
```

### Apply 阶段

```bash
# 1. 前置检查
- 拒绝 dirty tree (git diff --quiet && git diff --cached --quiet)
- proposal 状态必须是 pending
- 重跑静态检查（防止 proposal 文件被改过）

# 2. 快照
git tag "snapshot/pre-apply-${ID}"

# 3. 落地
for change in $(jq -r '.changes[].path' manifest.json); do
  cp ops-proposals/${ID}/${change} ./${change}
done
git add $(jq -r '.changes[].path' manifest.json)   # 只 add 声明的文件
git commit -m "ops: apply proposal ${ID}"

# 4. Rebuild（最小重启）
for svc in $(jq -r '.affected_services[]' manifest.json); do
  docker compose up -d --build "$svc"
done

# 5. Settling window
sleep ${settling_window}   # agent/squid/litellm: 30s, collector/notifier: 15s, 配置 reload: 10s

# 6. Healthcheck
docker compose ps --format json | check_no_exited_or_restarting

# 7. Verification
for v in $(jq -r '.verification[]' manifest.json); do
  bash scripts/ops/verifications/${v}.sh || FAIL=1
done

# 8. 决定
if FAIL; then
  git reset --hard "snapshot/pre-apply-${ID}"
  for svc in $(jq -r '.affected_services[]' manifest.json); do
    docker compose up -d --build "$svc"   # rollback rebuild
  done
  status=rolled_back
else
  status=applied
fi

# 9. 写结果
echo "{...}" > ops-results/${ID}.json     # agent 可读
推送 Telegram 通知
刷新 .snapshot/ + 生成新 snapshot_id
```

## 通知格式

### LOW 提案

```
✅ LOW 提案 #20260517-1430
目的：增加 Tavily 搜索能力
影响：squid
改动：proxy/allowed_domains.txt (+ api.tavily.com)
检查：通过
建议：可应用
cmd: ops 1430
```

### MEDIUM 提案

```
🟡 MEDIUM 提案 #20260517-1430
目的：升级 collector 心跳频率
影响：collector
改动摘要：
  collector/collector.py: heartbeat 300s → 60s
检查：通过
verification: collector_heartbeat_recent
cmd: ops 1430
```

### HIGH 提案

```
🔴 HIGH 提案 #20260517-1430
目的：新增 gemini-cli 服务
影响：agent / 新服务
风险清单：
  - 新增服务（即使受全局规则约束）
  - Dockerfile 改动
  - compose 拓扑变更
完整 diff: ops-diff 1430
应用: ops-apply --high 1430
```

### BLOCKED 提案

```
🚨 BLOCKED 提案 #20260517-1430
试图触碰绝对不变量：claude_config/hooks/guard.sh
此提案不可审批，已仅记录。
建议复核 agent 行为。
查看: ops-spool view 1430
```

### Apply 结果

```
✅ Applied #20260517-1430
rebuild: squid (8s)
healthcheck: ok
verification: 2/2 passed
新 snapshot: 20260517T143842Z
```

```
❌ Rolled back #20260517-1430
rebuild 成功，但 verification 失败：
  squid_denies_example_org: FAIL (got 200, expected blocked)
已回滚到 pre-apply 快照
```

## 目录与审计

### 路径划分

```
~/ai_sandbox/
├── .ops-watcher.disabled       # 紧急停止开关（touch 即生效）
├── audit_spool/                # agent 行为审计（collector 写）
├── ops_spool/                  # 宿主机 watcher 发布审计
│   ├── events.jsonl            # watcher 每个动作
│   ├── proposals/<id>/         # 历史 proposal 归档
│   └── snapshots/              # 状态记录
├── scripts/ops/
│   ├── apply-proposal.sh
│   ├── ops-watcher.sh
│   ├── verifications/          # 命名检查项目录
│   │   ├── agent_can_resolve_tavily.sh
│   │   ├── squid_denies_example_org.sh
│   │   └── ...
│   └── ops-baseline.json       # compose 安全字段基线
└── agent_workspace/
    ├── .snapshot/              # watcher 写，agent :ro
    ├── ops-proposals/<id>/     # agent 写
    ├── ops-requests/           # agent 写
    └── ops-results/            # watcher 写，agent :ro
```

### 审计流不混池

| 流 | 作用 | 写入者 | 读取者 |
|----|------|--------|--------|
| audit_spool/ | agent 工具调用审计 | collector | notifier, 你 |
| ops_spool/ | watcher 发布审计 | watcher | 你 |

两条流互相参照（proposal 应用后会触发 agent 行为，可在两个流里交叉验证），但永不混入同一文件。

## 实施计划

### Phase 1：proposal 协议骨架

- [ ] 设计 manifest.json schema 与校验
- [ ] 创建 `agent_workspace/` 子目录结构（ops-proposals/ ops-requests/ ops-results/ .snapshot/）
- [ ] compose 中 agent 新增 `.snapshot:ro` 挂载
- [ ] watcher 初始化脚本：首次运行生成 .snapshot 与 .snapshot-id
- [ ] agent 侧 helper 命令封装（写 manifest + request 的便捷工具）

### Phase 2：watcher 静态检查 + 风险分级

- [ ] `ops-watcher.sh` 主循环（fswatch 监听 ops-requests/）
- [ ] manifest schema 验证
- [ ] 全局规则扫描（黑名单字段）
- [ ] 路径白名单校验
- [ ] 隔离临时目录预演（compose config / hadolint）
- [ ] 风险分级（LOW/MEDIUM/HIGH/BLOCK）
- [ ] stale / conflict / supersedes 状态机
- [ ] affected_services 完整性校验
- [ ] verification 命名项校验

### Phase 3：Telegram 通知 + ops_spool 审计

- [ ] 通知格式（4 档 + apply 结果）
- [ ] ops_spool/events.jsonl 写入
- [ ] BLOCK 红色警告
- [ ] proposal 归档到 ops_spool/proposals/<id>/

### Phase 4：apply 脚本

- [ ] `scripts/ops/apply-proposal.sh`
- [ ] dirty tree 检查
- [ ] git tag 快照
- [ ] 严格按 manifest 复制 + git commit
- [ ] 最小 rebuild
- [ ] settling window + healthcheck
- [ ] verification subset 执行
- [ ] 失败 rollback
- [ ] 写 ops-results
- [ ] 刷新 .snapshot

### Phase 5：verification 脚本库

- [ ] `scripts/ops/verifications/` 目录
- [ ] 一期内置：agent_can_resolve_tavily / squid_denies_example_org / collector_heartbeat_recent / e2e_subset_audit
- [ ] 每个脚本固定参数，无自由 shell

### Phase 6：集成测试

- [ ] LOW 提案：白名单加 1 个域名，自动应用
- [ ] MEDIUM 提案：Dockerfile 装包，应用
- [ ] HIGH 提案：新增服务，--high 显式应用
- [ ] BLOCK：尝试改 guard.sh，验证不进入审批流
- [ ] stale：手动改生产，验证 stale 检测
- [ ] conflict：两个 proposal 撞同一文件
- [ ] rollback：构造 verification 失败，验证自动回滚
- [ ] 全局规则：试图加 privileged / docker.sock / ports，验证拒绝
- [ ] 紧急停止：touch .ops-watcher.disabled，验证 watcher 不再处理

### Phase 7：文档与上线

- [ ] 更新 DOCKER-USAGE-MANUAL.md（新增 ops 命令章节）
- [ ] 更新 DOCKER-DEVELOPMENT-LOG.md（checkpoint）
- [ ] watcher 启动方式（launchd plist）
- [ ] 生产 SOP

## 决策记录（v2 修正）

| 设计点 | v1 提议 | v2 终稿 | 修正理由 |
|--------|---------|---------|---------|
| 配置文件挂载 | `.:/project:rw` | proposal 模式 + .snapshot:ro | v1 暴露 .env / audit_spool / .git，击穿基线 |
| guard.sh 保护 | :ro 覆盖运行时 | BLOCK 路径，proposal 不可审批 | :ro 只是延时器，rebuild 后失效 |
| BLOCK 处理 | 拒绝生成 | 可观测但不可审批 | 留下安全信号比消失更安全 |
| 快照 | tar/cp | git tag + clean tree precondition | git add -A 会扫入运行态杂物 |
| verification | 自由命令模板 | 命名检查项，watcher 仅执行白名单 | 参数可控 = 半个 shell |
| 体验优化 | .command 双击 | shell alias `ops <id>` | 复制比双击多一层意识 |
| 审计流 | audit_spool 共用 | ops_spool 独立 | 语义不同，不混池 |
| 并发控制 | 仅 TTL | base_snapshot_id + supersedes | TTL 解决"久"，snapshot 解决"旧" |
| 验证时机 | 立即判定 | settling window + healthcheck | docker compose up 返回 0 ≠ 服务健康 |
| Rebuild 范围 | docker compose up -d --build | 按 affected_services 最小重启 | 工程化，速度+定位+影响面可见 |

## 紧急停止

```bash
touch ~/ai_sandbox/.ops-watcher.disabled
```

watcher 检测到此文件存在则不处理任何 proposal/request，并 Telegram 通知"watcher 已禁用，proposals 排队中"。

恢复：

```bash
rm ~/ai_sandbox/.ops-watcher.disabled
```

## 依赖

- macOS: `brew install fswatch jq hadolint`
- 宿主机已有: docker, docker compose, bash, git
- bash 3.2 兼容：所有 grep 零匹配处必须 `|| true`

## 已知约束

- agent rebuild agent 会杀掉自己当前会话：可接受，新容器正常启动
- 新增服务首个 proposal 仍需通过通用 HIGH 流程（不需要单独"预注册"步骤——HIGH 的 `--high` 显式确认即可）
- watcher 自身的 bug 是宿主机级风险点：脚本要求保持极简，所有外部输入经 jq 解析（无 eval），所有路径经白名单校验



---

## Checkpoint：Phase 1 完成（2026-05-17）

- `scripts/ops/init-snapshot.sh`：宿主机生成 `.snapshot/`，严格白名单复制（不含 .env/.git/auths/audit_spool）
- `scripts/ops/ops-helper.sh`：agent 容器内 `ops-propose` 命令（new/add/set-*/submit/result/list）
- `scripts/ops/README.md`：进度记录 + 验证步骤

待办（Phase 1.1，进入 Phase 2 前必修）：

### 路径与白名单
1. SNAPSHOT_INCLUDED vs PROPOSAL_PATH_ALLOWED 概念澄清
2. ops-helper add 路径白名单校验，敏感路径（claude_config 等）helper 层先拒绝

### Manifest 完整性
3. jq -n 生成初始 manifest（防引号注入）
4. 原子更新（mktemp + mv + trap）
5. add 去重 by path
6. add 计算并写入 sha256
7. validate 顺手清理陈旧 `.manifest.*`

### Submit 严格校验
8. `jq empty` 验合法 JSON
9. `base_snapshot_id != "unknown"`
10. `changes[].path` 文件存在
11. `reason` 非空
12. `expected_effect` 非空
13. `affected_services` 非空且元素均在白名单

### 命令与体验
14. 独立 `validate` 命令
15. usage 补 set-effect 和 validate
16. `clean` 命令（仅 draft + changes 空 + 24h 前，不动有 changes 的半成品）

### Snapshot 强化
17. init-snapshot.sh 原子刷新（mktemp -d → rsync → mv）
18. `.snapshot-hash` 内容哈希（防同秒重刷/手工改 snapshot）
19. proposal id 加短随机后缀防同秒冲突

### Result 不可变性（J 终稿）
20. result 内嵌 manifest 完整副本
21. result 内嵌 applied_files 与 sha256
22. result 单文件只读，后续状态走 sibling（如 `<id>.rollback.json`）

### 设计澄清

**SNAPSHOT_INCLUDED vs PROPOSAL_PATH_ALLOWED**

| 维度 | 含义 |
|------|------|
| SNAPSHOT_INCLUDED | agent 通过 `.snapshot/` 可读的"生产现状" |
| PROPOSAL_PATH_ALLOWED | manifest.changes[].path 允许的白名单 |

两者**不重叠** = "只读知情，不可提案改动"。

例如 `claude_config/`：
- ✅ 在 SNAPSHOT_INCLUDED：agent 能看到当前 guard.sh / audit.sh / settings.json，理解防线现状
- ❌ 不在 PROPOSAL_PATH_ALLOWED：agent 无法提案改动这些文件
- helper 在 `add` 阶段就拒绝（前端防脏）
- watcher 仍保留 BLOCK 检测（后端不信任前端，纵深冗余）

下一步：Phase 1.1 完成后进入 Phase 2（compose 挂载 + watcher 主循环 + 风险分级）。

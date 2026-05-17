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



---

## Checkpoint：Phase 1.1 完成 + Phase 1.2 待办（2026-05-17）

Phase 1.1 在生产宿主机（macOS）实测通过，22 项硬化全部到位，16 项自动化测试 + 4 项手动负向测试全过。

### 在 review 中发现的待修问题（Phase 1.2）

#### 实质性 bug

1. **`random_suffix()` SIGPIPE bug**
   实测产出 ID `20260517-062236-gwhxxx`，三位真随机后缀加上了固定的 `xxx`。
   原因：`tr ... < /dev/urandom | head -c 3` 在 `set -o pipefail` 下，head 读够 3 字符后 tr 收到 SIGPIPE，整条 pipeline 视为失败 → `|| echo "xxx"` 触发追加。
   修复：改用 `LC_ALL=C od -An -N3 -tx1 /dev/urandom | tr -d ' \n'`，od 一次性读 3 字节后正常退出，无 SIGPIPE。

2. **bind mount 与目录 mv 替换的 inode 冲突**
   当前 `init-snapshot.sh` 用 `mv old → backup; mv staging → snapshot` 替换。
   宿主机视角是原子的，但 bind mount 绑定的是原目录 inode 而非路径名。
   Phase 2 计划把 `.snapshot:/app/workspace/.snapshot:ro` 挂给 agent 后，宿主机替换目录会让 agent 容器仍指向旧 inode，宿主机以为刷新了，agent 还在读旧 snapshot——直接伤害 base_snapshot_id 的可信度。
   修复：改为 `versions/<id>/ + current symlink` 结构，refresh 时只原子切换 current symlink。bind mount 稳定挂 `.snapshot/` 根目录不动。

#### 结构性收紧

3. **`add` 不拒绝 symlink**
   当前只检查 `[ -f ]` 会跟随 symlink。proposal 里如果放了 `proxy/allowed_domains.txt -> /etc/passwd`，helper 仍会算 hash 写 manifest。
   修复：
   - `[ -L ]` 直接拒绝
   - `realpath` 必须仍在 proposal 目录内

4. **manifest 缺 `base_snapshot_hash`**
   snapshot 已有 id + hash，但 manifest 只写了 id。Phase 2 watcher apply 前应该双重校验：id 防版本错位，hash 防内容漂移。

#### 设计收紧

5. **PROPOSAL_PATH_ALLOWED 偏宽**
   当前 `collector/[^/]+\.(py|txt|conf)` 允许 agent 提案新增任意文件名。
   一期收窄到具体文件白名单（collector.py / Dockerfile / squid.conf 等枚举）。
   "新增代码文件"是与"修改既有文件"不同的风险层级，留作 Phase 2 风险分级的扩展点（自动升 MEDIUM/HIGH）。

6. **`verification` 非空校验缺失**
   manifest 字段已设计但 validate 未要求非空。watcher 后面要靠它生成验证计划。
   修复：submit 校验加上 `verification | length > 0`，且每个 name 后续在 watcher 白名单内。

7. **空 proposal 不该 submit**
   当前 add 时若候选文件与 snapshot 完全一致，会标 `no changes vs snapshot` 但仍进 .changes。
   修复：helper add 仍允许（提示 WARN 给 agent 迭代用），submit 时若全部 changes 都是 no-op，拒绝。

#### 文档

8. README 负向测试示例不严谨（`new` 生成新 ID，但示例引用 `test-block`，没串起来）。修。

### Phase 1.2 设计：versions/current 结构

```
.snapshot/                          ← 稳定挂载点（compose bind mount）
  versions/
    <snapshot-id-1>/
      .snapshot-id
      .snapshot-hash
      docker-compose.yml
      Dockerfile
      proxy/
      ...
    <snapshot-id-2>/
      ...
  current -> versions/<latest-id>   ← 相对 symlink（整目录搬走仍自洽）
  .snapshot-id                      ← 顶层指针，等价于 cat current/.snapshot-id
  .snapshot-hash                    ← 顶层指针，等价于 cat current/.snapshot-hash
```

agent 读 `.snapshot/current/...` 或顶层 `.snapshot/.snapshot-id`。
watcher 双向校验：顶层值 == versions/current 内值，不一致 → WARN（识别外部篡改）。

### Refresh 7 步定序

```bash
# 1. 构建 versions/<new-id>.staging/
# 2. 写入 .snapshot-id / .snapshot-hash 到 staging 内
# 3. mv versions/<new-id>.staging → versions/<new-id>     (原子)
# 4. ln -sfn "versions/<new-id>" current.new              (相对路径)
# 5. mv current.new current                                (原子切换)
# 6. 顶层 metadata 原子写：
#    - 写 .snapshot-id.new + mv → .snapshot-id
#    - 写 .snapshot-hash.new + mv → .snapshot-hash
# 7. 双向校验（顶层 == versions/current 内），不一致输出 WARN（不回滚，让下次校验抓住）
```

第 6 步失败可被双向校验检测到 = 设计意图（不静默掩盖）。

### versions/ 保留策略

- Phase 1.2：不自动 prune（顺其自然，避免 bug）
- Phase 2+：watcher 根据保留窗口清理（默认保留最近 N 个）

### 测试覆盖（Phase 1.2 结束后跑）

原 16 项 + 新增 4 项负向：

| # | 测试 |
|---|------|
| N1 | symlink proposal 被拒（add 阶段） |
| N2 | 顶层 .snapshot-id 与 versions/current/.snapshot-id 不一致被检测 |
| N3 | verification=[] 时 submit 被拒 |
| N4 | 全部 change 都是 no-op 时 submit 被拒 |

`base_snapshot_hash` 正向写入并入原有正向测试。

### 实施顺序

1. `init-snapshot.sh`：versions/current 结构 + 7 步定序 + 双向校验输出
2. `ops-helper.sh`：random_suffix / symlink 防御 / base_snapshot_hash / 收窄白名单 / verification 必填 / 空变更拒绝
3. `README.md`：结构图 + 保留策略 + 修负向测试示例
4. 测试套件扩展（16 + 4 负向 + base_snapshot_hash 正向）
5. 一次提交推送

完成 Phase 1.2 后才进入 Phase 2（compose 挂载 + watcher 主循环 + 风险分级）。



---

## Checkpoint：Phase 1.2 完成（2026-05-17）

8 项实测发现修复全部落地，27 项自动化测试通过，生产宿主机上一次跑通。

### 关键交付

- `init-snapshot.sh`：versions/current 相对 symlink + 7 步定序 + 双向校验输出
- `ops-helper.sh`：30 项硬化（jq -n / 原子更新 / sha256 铆钉 / symlink 防御 / base_snapshot_hash 双锚 / 路径收窄 / verification 必填 / no-op 拒绝 / 等）
- `README.md`：新结构图 + 保留策略 + 完整验证步骤

### 生产实测（宿主机）

```
[2026-05-17T06:37:56Z] snapshot refreshed
  path:   /Users/caimin/ai_sandbox/agent_workspace/.snapshot
  id:     20260517T063756Z
  hash:   570f163bdfca5a9792339c3549e9fe83c92952a849f9b80eca0d4b655003307b
  current → versions/20260517T063756Z
  versions kept: 1 (no auto-prune in Phase 1.2)
```

helper 流程 `add → set-effect → set-affected → set-verification → validate → submit` 全链路通过，proposal id 正确含 6 位真随机 hex 后缀（`cfb964`，不再是 SIGPIPE 触发的 `xxx`）。

---

## Phase 2 拆分：Step A + Step B

考虑到上下文预算与代码体量，Phase 2 拆为两步：

### Step A（本轮）：watcher 骨架 + 静态检查 + 本地闭环

不接 Telegram，不动 compose，纯宿主机本地闭环。

待办：

1. `ops-watcher.sh` 主循环（fswatch 监听 ops-requests/）
2. 静态检查模块：
   - manifest schema 重校验（不信任 helper 前端）
   - 全局规则扫描（privileged / docker.sock / ports / host 网络 / 敏感路径挂载）
   - 路径白名单校验
   - 隔离临时目录预演（`docker compose config` + `hadolint`）
   - 风险分级 LOW/MEDIUM/HIGH/BLOCK
   - stale 检测（base_snapshot_id != current）
   - 内容漂移检测（base_snapshot_hash != current 顶层）
   - conflict 检测（同文件已有 pending 且无 supersedes）
3. `ops_spool/events.jsonl` 审计流
4. 写 ops-results/<id>.json（含 manifest 完整副本 + applied_files placeholder + watcher_decision）
5. 紧急停止开关 `.ops-watcher.disabled`
6. `ops-baseline.json` 安全字段基线
7. Step A 测试脚本（临时目录模拟 proposal → watcher 处理 → 检查 result）

完成后宿主机：
```bash
bash scripts/ops/ops-watcher.sh &
# 另一终端 submit proposal
# 看 ops_spool/events.jsonl 和 ops-results 的反应
```

### Step B（下一轮）：Telegram + compose 挂载 + 真实集成

- compose 中给 agent 加 `.snapshot:ro` 挂载
- Dockerfile COPY `ops-helper.sh` → `/usr/local/bin/ops-propose`
- watcher Telegram 通知（4 档 + apply 结果）
- 集成测试：agent 容器内真实 submit → watcher 实际处理 → Telegram 收到通知

Step B 仍只做"静态检查"，不真实 docker compose up（那是 Phase 4 apply-proposal.sh 的事）。



---

## Checkpoint：Step A + A.1 完成（2026-05-17）

### 已交付

| 文件 | 行数 | 角色 |
|------|------|------|
| `scripts/ops/init-snapshot.sh` | ~190 | versions/current 结构 + 7 步定序 + 双向校验 |
| `scripts/ops/ops-helper.sh` | ~440 | agent 容器内 ops-propose（new/add/set-*/validate/submit） |
| `scripts/ops/ops-baseline.json` | 61 | watcher 唯一安全合同 |
| `scripts/ops/ops-watcher.sh` | ~960 | 14 个检查模块 + 主循环 + 状态机 |
| `scripts/ops/README.md` | ~200 | 状态流图 + 命名规则 + 验证步骤 |

### Step A 状态流（顺序固定）

```
disabled → manifest schema → BLOCK paths → candidate files →
stale → conflict (with supersedes) → global rules →
baseline invariants → manifest whitelists → preflight →
classify → accepted_for_review
```

### Step A.1 修复的 3 个缺口

1. **baseline 没被 watcher 使用** → 实装 `check_baseline_invariants`，`docker compose config --format json` 比对 agent 安全字段 + 必需挂载，docker 缺失保守拒绝
2. **watcher 信任 manifest 没重验候选文件** → 实装 `check_candidate_files`，重跑 exists/symlink/regular/sha256/no-op 检查
3. **`check_manifest_whitelists` 废线** → 删除

### 测试覆盖

16 类自动化场景全过：
```
T1  合法 LOW                    → accepted_for_review LOW
T2  claude_config 路径          → blocked BLOCK
T3  compose privileged          → blocked BLOCK
T4  compose ports               → blocked BLOCK
T5  stale                       → stale
T6  conflict                    → conflict
T7  watcher disabled            → disabled
T8  hadolint missing            → accepted MEDIUM (skipped_missing_tool)
T10 malformed JSON              → rejected
T11 supersedes 合法替代          → 新 accepted, 旧 superseded sibling
T12 删 read_only (A.1-1)        → blocked BLOCK
T13 删 cap_drop ALL (A.1-1)     → blocked BLOCK
T14 删 audit_spool:ro (A.1-1)   → blocked BLOCK
T15 candidate 缺失 (A.1-2)      → rejected
T16 sha256 漂移 (A.1-2)         → rejected
T17 symlink (A.1-2)             → rejected
T18 candidate 是目录 (A.1-2)    → rejected
```

### 生产宿主机实测确认

```
[2026-05-17T06:55:29Z] snapshot refreshed
  id: 20260517T065529Z
  hash: 570f163bdfca5a9792339c3549e9fe83c92952a849f9b80eca0d4b655003307b

helper → submit → watcher 全链路：
  Submitted: 20260517-065617-2e08a7
  20260517-065617-2e08a7 | accepted_for_review | LOW | proxy/allowed_domains.txt (+1/-0 lines) | passed all static checks

baseline invariant 真比对（A.1-1 验证）：
  20260517-071105-bb0219 | blocked | BLOCK | docker-compose.yml (+3/-3 lines) | agent.read_only=false, baseline requires true
```

### Step B（下窗口启动）

详见 `HANDOFF-OPS-WATCHER.md`。范围：

- compose 挂载 `.snapshot:ro`
- Dockerfile COPY ops-helper.sh → `/usr/local/bin/ops-propose`
- Telegram 通知（4 档 + 启停）
- launchd plist 开机自启
- agent 容器内集成测试

不做（留给后续）：
- apply-proposal.sh（Phase 4）
- verifications/ 命名检查项库（Phase 5）
- 真实 docker compose up（Phase 4）

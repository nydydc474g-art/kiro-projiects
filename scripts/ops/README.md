# Ops Watcher 脚本目录

> 实施进度：**Step A.1 完成 + B.0/B.1 完成**（静态判定内核 + agent 容器接入 + snapshot 物理迁移到项目根）

## 文件清单

| 文件 | 阶段 | 作用 |
|------|------|------|
| `init-snapshot.sh` | Phase 1.2 ✅ | 宿主机生成/刷新 `snapshot/`（versions/current 结构，7 步定序） |
| `ops-helper.sh` | Phase 1.2 ✅ + B.1 | agent 容器内 proposal 助手；支持 `OPS_SNAPSHOT` 覆盖（宿主机调试用） |
| `ops-baseline.json` | Step A ✅ + B.1 | watcher 安全基线；`agent_volumes_required` 含 snapshot :ro 挂载 |
| `ops-watcher.sh` | Step A.1 ✅ + B.1 | watcher 主循环 + 14 个检查模块；启动自检 SNAPSHOT_DIR/current 存在 |
| `MIGRATION-SOP.md` | B.1 ✅ | snapshot 物理位置迁移手册（Plan C：保留身份 mv） |
| `verifications/` | Phase 5 ⏳ | 命名检查项目录（待补） |
| `apply-proposal.sh` | Phase 4 ⏳ | apply/rollback 脚本（待补） |

## 核心概念

### SNAPSHOT_INCLUDED vs PROPOSAL_PATH_ALLOWED

| 维度 | 含义 |
|------|------|
| **SNAPSHOT_INCLUDED** | agent 通过 `.snapshot/current/` 可读的"生产现状" |
| **PROPOSAL_PATH_ALLOWED** | manifest.changes[].path 允许的白名单 |

**两者不重叠 = "只读知情，不可提案改动"**。例：`claude_config/` 在 SNAPSHOT_INCLUDED（agent 看得到当前防线）但不在 PROPOSAL_PATH_ALLOWED，helper 拒绝、watcher 也拒绝。

### snapshot 目录结构（B.1 起的物理布局）

```
~/ai_sandbox/snapshot/              ← 宿主机物理位置（B.1: 从 agent_workspace/.snapshot 迁出）
  versions/
    <snapshot-id-1>/                ← 每次 refresh 创建新版本目录
      .snapshot-id
      .snapshot-hash
      docker-compose.yml
      ...
  current -> versions/<id>          ← 相对 symlink（ln -sfn 原子覆盖）
  .snapshot-id                      ← 顶层指针，agent helper 直接读
  .snapshot-hash                    ← 顶层指针

# 容器内（agent 视角，不变）
/app/workspace/.snapshot/           ← 来自 ./snapshot:ro 挂载，嵌套在 :rw workspace 内
```

容器内挂载点保持 `/app/workspace/.snapshot`，agent 的 helper 不需要任何
代码改动。宿主机调试期可显式覆盖：

```bash
# 宿主机调试
OPS_SNAPSHOT=~/ai_sandbox/snapshot bash scripts/ops/ops-helper.sh ...
OPS_SNAPSHOT_DIR=~/ai_sandbox/snapshot bash scripts/ops/ops-watcher.sh --once <id>
```

详见 `MIGRATION-SOP.md`。

### 状态流（Step A.1）

```
request detected
  ↓
.ops-watcher.disabled?       → disabled
  ↓ no
load manifest (jq parse)     → rejected (malformed)
schema fields present?       → rejected
  ↓ ok
path matches BLOCK regex?    → blocked      (claude_config/ / .env / audit_spool/ / cliproxyapi/auths/)
  ↓ ok
candidate file 重验          → rejected
  (exists / not symlink / regular file / sha256 matches / not all no-op)
  ↓ ok
base_snapshot_id != current  → stale
or base_snapshot_hash != current
  ↓ ok
conflict on same path?
  has supersedes target?
    yes & target valid       → mark old as superseded; continue
    yes & target invalid     → rejected (declared supersedes target not found)
    no                       → conflict
  ↓ ok
global rules scan
  (privileged / docker.sock / cap_add / ports / host net / namespace modes)
                              → blocked
baseline invariants (compose 改动时)
  agent service: read_only / cap_drop / security_opt / user
  agent volumes: required mounts present (target + ro/rw 一致)
  docker missing → 保守拒绝
                              → blocked
manifest whitelists
  (path regex / service in baseline / verification name format)
                              → rejected
  ↓ ok
isolated preflight
  (docker compose config + hadolint, on tmp overlay)
  hadolint missing → skipped_missing_tool (warning, NOT blocking)
                              → preflight_failed
  ↓ ok
risk classify (LOW / MEDIUM / HIGH)
  ↓
accepted_for_review
```

### Status vs Risk

正交字段：

```json
{ "status": "accepted_for_review", "risk_level": "HIGH" }
{ "status": "blocked",             "risk_level": "BLOCK" }
{ "status": "stale",               "risk_level": "UNKNOWN" }
```

风险分级（按 manifest.changes 路径）：

| 级别 | 触发路径 |
|------|---------|
| LOW | proxy/allowed_domains.txt / scripts/ops/verifications/* |
| MEDIUM | Dockerfile / proxy/squid.conf / config/litellm_config.yaml / collector/* / notifier/* |
| HIGH | docker-compose.yml |
| BLOCK | claude_config/* / .env / audit_spool/* / cliproxyapi/auths/* |

### effective_status：当前生命周期投影（不是 .json.status）

`ops-results/<id>.json.status` 是 proposal 的**初始裁决**，写入即只读。但 proposal 实际状态会通过 sibling 文件继续演进——所以**watcher 任何决策都不读 `.json.status`，读 `get_effective_status(id)`**。

| 来源 | 含义 |
|------|------|
| `<id>.json.status` | 初始裁决（不可变） |
| `get_effective_status(id)` | 当前生命周期投影（动态） |

读取规则（在 ops-watcher.sh 中实现）：

1. proposal 目录不存在 → `""`
2. 没 `<id>.json` → `pending`（已 submit 等 watcher / 还没 submit 的草稿）
3. 任意 lifecycle sibling 文件存在 → 取 sibling 状态（一期：`.superseded.json` → `superseded`；Phase 4：`.applied.json` / `.rolled_back.json`）
4. 否则 → `.json.status`

watcher 内部决策的两条具体规则：

- 占位检测：`effective_status ∈ {accepted_for_review, pending}` 视为占位
- supersedes target：必须 `effective_status == accepted_for_review`

详见 `OPS-WATCHER-DESIGN.md` 的 effective_status 段——这是 B.1 hotfix v2 引入的抽象，**几个月后最容易被误读**的就是这一层。下游脚本（apply-proposal.sh / 任何 lifecycle 检查）必须沿用同一函数，不要绕开。

### Result 文件命名

```
ops-results/<id>.json                                  ← 权威记录（永不改）
ops-results/<id>.<status>.<risk_level>.summary         ← 派生视图（路标）
ops-results/<id>.superseded.json                       ← sibling 事件
ops-results/<id>.superseded.UNKNOWN.summary
```

不变量：summary 是派生视图。冲突时以 `<id>.json` 为准。

## ops-baseline.json

watcher 唯一的安全配置文件，一期内容：

| 字段 | 作用 |
|------|------|
| `agent_service_invariants` | agent 服务必须保持的安全字段（read_only / cap_drop / security_opt / user） |
| `agent_volumes_required` | agent 必须挂载的卷（不能删） |
| `global_forbidden_compose_keys` | privileged / cap_add / ports |
| `global_forbidden_volume_patterns` | docker.sock / `/:` / `/Users/` / `/etc/` / `/var/run/` |
| `global_forbidden_network_modes` | host |
| `global_forbidden_namespace_modes` | pid: host / ipc: host / userns_mode: host |
| `allowed_services` | 6 个服务 |
| `allowed_proposal_paths_regex` | 具体文件白名单 |
| `block_paths_in_changes_regex` | 触碰即 BLOCK 的路径 |
| `allowed_verifications` | 一期空数组（仅校验名格式），Phase 5 强制白名单 |

baseline 不做全量 compose 镜像，只承载安全不变量。

## 紧急停止

```bash
touch ~/ai_sandbox/.ops-watcher.disabled
```

watcher 会把后续 proposal 直接判 disabled，不进入处理流。恢复：

```bash
rm ~/ai_sandbox/.ops-watcher.disabled
```

## 命令

```bash
# 主循环（前台）
bash scripts/ops/ops-watcher.sh

# 单次处理调试
bash scripts/ops/ops-watcher.sh --once <proposal-id>

# 一次性处理所有 pending
bash scripts/ops/ops-watcher.sh --process-all

# 帮助
bash scripts/ops/ops-watcher.sh --help
```

## 验证步骤（Step A，宿主机）

> 容器内集成测试见 `MIGRATION-SOP.md` 末尾"smoke test"段。下面是宿主机
> 直接调用 helper 的快速验证路径——主要给开发期 / 调试期用。

### 1. 准备

```bash
cd ~/ai_sandbox
bash scripts/ops/init-snapshot.sh
ls -la snapshot/                   # B.1 起的新位置（项目根，独立于 agent_workspace）
```

### 2. 跑一个合法 LOW proposal（宿主机直调 helper）

```bash
export WORKSPACE=~/ai_sandbox/agent_workspace
# B.1: 宿主机调试时显式指向新 snapshot 位置（容器内不需要这个）
export OPS_SNAPSHOT=~/ai_sandbox/snapshot
ID=$(bash scripts/ops/ops-helper.sh new "test add tavily")
mkdir -p $WORKSPACE/ops-proposals/$ID/proxy
cp $OPS_SNAPSHOT/current/proxy/allowed_domains.txt $WORKSPACE/ops-proposals/$ID/proxy/
echo "api.tavily.com" >> $WORKSPACE/ops-proposals/$ID/proxy/allowed_domains.txt
bash scripts/ops/ops-helper.sh add $ID proxy/allowed_domains.txt
bash scripts/ops/ops-helper.sh set-effect $ID "agent reaches tavily"
bash scripts/ops/ops-helper.sh set-affected $ID squid
bash scripts/ops/ops-helper.sh set-verification $ID squid_denies_example_org
bash scripts/ops/ops-helper.sh submit $ID

# 让 watcher 处理（OPS_SNAPSHOT_DIR 同样可显式覆盖；watcher 默认也读新位置）
bash scripts/ops/ops-watcher.sh --once $ID

# 看结果
ls $WORKSPACE/ops-results/
cat $WORKSPACE/ops-results/$ID.*.summary
jq . $WORKSPACE/ops-results/$ID.json
```

预期：

```
$ID | accepted_for_review | LOW | proxy/allowed_domains.txt (+1/-0 lines) | passed all static checks
```

### 3. 看 events.jsonl

```bash
cat ~/ai_sandbox/ops_spool/events.jsonl | jq -c .
```

每个动作一行，带 timestamp / level / proposal_id / 详细 msg。

## 设计参考

详见仓库根目录 `OPS-WATCHER-DESIGN.md`（设计演进 + 各 Phase checkpoint）。

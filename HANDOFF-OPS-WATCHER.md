# Ops Watcher 交接文档（HANDOFF）

> 状态：Step A + A.1 完成，Step B 待启动。
> 分支：`ops-watcher`
> 仓库：https://github.com/nydydc474g-art/kiro-projiects/tree/ops-watcher

---

## 一句话现状

Watcher 静态判定内核已生产实测通过：proposal 提交 → 14 项静态检查 → 写权威结果 + 单行路标 + 审计流。**还没接 Telegram，还没改 compose，还没让 agent 容器真正能用 ops-propose。**

---

## 给下个窗口的第一句话

> "继续 ops-watcher 项目的 Step B。读 `OPS-WATCHER-DESIGN.md` 与 `HANDOFF-OPS-WATCHER.md`，然后实施 Step B。"

下个窗口拿到这两个文档就能完整接上。

---

## 已落地（生产宿主机实测过）

### 文件

```
仓库根/
  OPS-WATCHER-DESIGN.md           ← 完整设计文档（v1→v2 演进 + 各 Phase checkpoint）
  HANDOFF-OPS-WATCHER.md          ← 本文档
  scripts/ops/
    init-snapshot.sh              ← 宿主机刷 snapshot（versions/current 结构）
    ops-helper.sh                 ← agent 容器内 ops-propose 命令
    ops-baseline.json             ← watcher 唯一安全合同
    ops-watcher.sh                ← 14 个检查模块 + 主循环
    README.md                     ← 状态流图 + 命名规则 + 验证步骤
```

### 实测确认

| 项 | 状态 | 证据 |
|----|------|------|
| `init-snapshot.sh` 跑通 | ✅ | 生产宿主机：`versions/20260517T065529Z`, hash `570f163b...` |
| `ops-helper.sh` 全流程 | ✅ | 16 项自动化测试 + 生产实测：proposal 创建/校验/提交 |
| `ops-watcher.sh` 静态判定 | ✅ | 16 类自动化测试全过（19 PASS / 0 FAIL） |
| baseline invariant 真比对 | ✅ | 生产实测：删 read_only → "agent.read_only=false, baseline requires true" → blocked / BLOCK |

### 状态流（不可变）

```
request detected
  ↓
disabled?              → disabled
manifest jq parse fail → rejected (malformed)
schema fields missing  → rejected
BLOCK path?            → blocked
candidate files 重验    → rejected   (A.1-2: exists/symlink/regular/sha256/no-op)
stale (id|hash)?       → stale
conflict (path overlap)→ conflict (除非显式 supersedes 合法)
global rules           → blocked    (privileged/docker.sock/cap_add/ports/host net/ns)
baseline invariants    → blocked    (A.1-1: agent read_only/cap_drop/security_opt/user/必需挂载)
manifest whitelists    → rejected   (path regex / service / verification 名格式)
isolated preflight     → preflight_failed (compose config + hadolint)
risk classify          → LOW / MEDIUM / HIGH
accepted_for_review
```

### 状态枚举

```
accepted_for_review  / rejected      / blocked       / stale
conflict             / superseded    / preflight_failed / disabled
```

`status` 与 `risk_level` 正交（HIGH 也能 stale，LOW 也能 blocked）。

---

## Step B 范围（下个窗口要做的）

### 必做

1. **compose 修改** — agent 服务新增挂载，让容器内 helper 能真正读写：
   ```yaml
   - ./agent_workspace/.snapshot:/app/workspace/.snapshot:ro
   ```
   ops-proposals / ops-requests / ops-results 已经在 `agent_workspace/` 内，无需新增挂载。

2. **Dockerfile 修改** — agent 镜像 COPY ops-helper.sh：
   ```dockerfile
   COPY scripts/ops/ops-helper.sh /usr/local/bin/ops-propose
   RUN chmod +x /usr/local/bin/ops-propose
   ```

3. **Telegram 通知模块** — watcher 收到 result 后推送：
   - 4 档样式（LOW / MEDIUM / HIGH / BLOCKED + apply 结果，apply 这部分先留空 placeholder）
   - watcher 启动/停止
   - 决策：直接 curl Telegram API（已在 .env 有 token）还是走现有 collector？
     - **建议**：watcher 直接 curl，避免引入对 collector 的依赖循环（watcher 是宿主机进程，collector 是容器内进程）

4. **launchd plist** — watcher 开机自启 + 进程崩溃自动重启
   - 文件位置：`~/Library/LaunchAgents/com.caimin.ops-watcher.plist`
   - 用 `launchctl load` 加载

5. **集成测试** — agent 容器内真实跑：
   ```bash
   docker exec -it agent ops-propose new "test"
   # ... add / set-* / submit
   # 在另一终端看 watcher 处理
   # Telegram 收到通知
   ```

### 不做（留给后续 Phase）

- ❌ apply-proposal.sh（Phase 4）
- ❌ verifications/ 命名检查项库（Phase 5）
- ❌ 真实 docker compose up（Phase 4）
- ❌ git tag 快照 + rollback（Phase 4）

---

## 关键决策与不变量（不要破坏）

### 安全不变量

1. **agent 内无真实 API key**（容器内继续用 dummy token）
2. **agent 唯一可写宿主机路径 = `agent_workspace/`**（`.snapshot/` 是 :ro 挂载）
3. **审计不可篡改**（audit_spool 对 agent :ro，guard.sh 对 agent 不可写）
4. **零端口 publish 到宿主机**
5. **container 安全字段不被放权**（read_only/cap_drop/no-new-privileges）
6. **watcher 不主动 docker compose up**（Step B 仅做静态判定 + 通知）

### 协议不变量

1. **`ops-results/<id>.json` 一旦写入即只读**（后续状态走 `<id>.<event>.json` sibling）
2. **summary 是派生视图**（冲突时以 `<id>.json` 为准）
3. **status 与 risk_level 正交**（不要合并）
4. **PROPOSAL_PATH_ALLOWED 是具体文件白名单**（不是目录通配）
5. **claude_config/ 在 SNAPSHOT_INCLUDED 但不在 PROPOSAL_PATH_ALLOWED**（只读知情，不可提案改动）
6. **watcher 不信任 helper**（Step A.1 已落地：watcher 重跑所有 helper 校验）

### 工程不变量

1. **bash 3.2 兼容**（不用 `set -u`，grep 零匹配 `|| true`）
2. **jq -n 生成 JSON**（不拼字符串）
3. **mktemp + mv 原子写**（trap 兜底清理）
4. **current symlink 用 `ln -sfn`**（不要 `mv current.new current`，会进 symlink 指向的目录）

---

## 用户环境（下个窗口需要知道）

```
宿主机：macOS Mac mini (Docker Desktop 29.4.0)
Shell：/bin/bash 3.2（默认）
项目路径：/Users/caimin/ai_sandbox
GitHub：nydydc474g-art/kiro-projiects（public 仓库）
分支：ops-watcher
.env：chmod 600，含真实 API key 和 Telegram token
防火墙：已启用
SSH + Tailscale：已启用，iPhone 远程
```

### 用户偏好

- 先问环境，先看完文件再给意见
- 不要枚举式防御
- 提交前在生产宿主机实测
- handoff / checkpoint 用日志方式追加，不要重写
- macOS bash 3.2 + `set -eo pipefail` 下，`grep` 零匹配 = exit 1 = 经典坑

---

## Step B 启动 SOP（下个窗口给 Kiro）

```
1. 看 OPS-WATCHER-DESIGN.md 最后一段（Phase 2 拆分 → Step B 范围）
2. 看 HANDOFF-OPS-WATCHER.md 全文
3. 看 scripts/ops/README.md（了解状态流和命名）
4. ls 看仓库现状，确认 5 个文件都在
5. 与用户确认 Step B 拆分顺序：
   建议：
     B.1 compose 挂载 + Dockerfile + 容器内验证 helper 能用
     B.2 Telegram 通知模块（先 watcher 启动 + accepted_for_review 通知）
     B.3 完整 4 档通知 + 集成测试
     B.4 launchd plist + 开机自启
6. 不要先动 launchd（最后再做，避免开发期被自动重启干扰）
7. Step B 完成后：写 STEP-B-COMPLETE.md（追加，不重写）
```

---

## 测试套件（保留在 sandbox 仓库历史，不在生产）

`.test-step-a1.sh`（已删除）覆盖 16 类场景：
- T1 valid LOW
- T2 claude_config blocked
- T3-T4 compose privileged/ports
- T5 stale
- T6 conflict
- T7 disabled
- T8 hadolint missing
- T10 malformed JSON
- T11 supersedes
- T12-T14 baseline invariants（删 read_only / cap_drop / audit_spool）
- T15-T18 candidate 重验（缺失/sha漂移/symlink/目录）

下个窗口如要扩展测试，模式参考 commit `b70a987` 之前的 `.test-step-a1.sh`（GitHub 历史可查）。

---

## 紧急联系

如发现生产环境异常：

```bash
# 立即停 watcher
touch ~/ai_sandbox/.ops-watcher.disabled

# 看 watcher 干了什么
tail ~/ai_sandbox/ops_spool/events.jsonl | jq -c .

# 看最近的 result
ls -lt ~/ai_sandbox/agent_workspace/ops-results/*.summary | head
```

watcher 自身不接触 docker（Step A），最坏后果只是写错误的 result 文件——可直接 rm 重来。

---

完。



---

## Checkpoint：B.0 + B.1 完成（2026-05-17）

> 追加日志，不改前文。前文"Step B 必做"列表保留了当时的决策快照。

### B.0 — 仓库卫生（commit `ffc3e1f`）

发现 main 分支上三个服务的 build context / Dockerfile 与生产机现实不一致：
- 根 `Dockerfile` 是 notifier 内容（python），但 compose 让 agent build 它
- `notifier/` 与 `collector/` 子目录在 git 上根本不存在
- `proxy/`、`config/`、`scripts/search-helper.py` 等路径 compose / Dockerfile
  期望子目录但实际散在根目录

→ 一次干净的目录整理：
```
Dockerfile               agent (node:20-slim + claude-code), banner 自报
notifier/Dockerfile      notifier (python + telegram), banner 自报
notifier/notifier.py
collector/Dockerfile     collector (python + audit), banner 自报
collector/collector.py
proxy/{squid.conf,allowed_domains.txt}
config/litellm_config.yaml
scripts/search-helper.py
```

每个 Dockerfile 头部带 banner 注释列出"我是哪个 + 不要和哪个搞混"，
解决"三个服务都叫 Dockerfile，agent grep 容易选错"的歧义问题。

生产实测：`docker compose build agent / notifier / collector` 三者皆通过。

### B.1 — snapshot 物理迁移 + agent 接入

#### 架构决策（Plan B）

snapshot 的"所有权"属于 watcher，不属于 agent。把它塞进 agent_workspace/
让两种生命周期不同的东西（watcher 产物 vs agent 工作产物）共用同一目录树，
并污染 agent_workspace 的独立 git repo 状态。修正：

- 宿主机：`~/ai_sandbox/snapshot/` (watcher 产物，独立)
- agent_workspace 仍然是 agent 唯一可写 :rw 挂载源
- 容器内挂载点不变（`/app/workspace/.snapshot`），agent 心智模型未受影响
- compose 形态：`./snapshot:/app/workspace/.snapshot:ro` 嵌套在 :rw workspace 内

不升级到 B'（`/app/snapshot` 容器内独立路径）的理由：
`.snapshot/current/...` 心智模型已深度嵌入 helper / watcher / 文档，B 在
macOS Docker Desktop overlayfs + iptables backend 上**实测**嵌套 :ro 成立。
未来 Docker Desktop 升级若改变此行为，回退到 B' 是单一变量切换。

#### 迁移协议（Plan C — 保留身份迁移）

不选"清空 pending 后 init 新位置"（A），不选"直接 init 让旧 proposal stale"（B），
选 C：**先把现有 snapshot 原样 mv 到新位置**（保留 versions/ + current symlink +
.snapshot-id + .snapshot-hash），mv 之后用三铆钉对账校验"身份没变"，挂载
ro 触摸测试通过，smoke test 用旧 snapshot id 跑一次 proposal 通过，最后才
决定是否 refresh。

把"目录搬家"和"事实版本前进"拆开成两个独立动作，事后审计可还原。
完整步骤：`scripts/ops/MIGRATION-SOP.md`。

#### 落地清单

| 文件 | 改动 |
|------|------|
| `init-snapshot.sh` | `SNAPSHOT_DIR="${OPS_SNAPSHOT_DIR:-$PROJECT_DIR/snapshot}"` |
| `ops-watcher.sh` | 同上 + 新函数 `check_snapshot_dir`（启动自检 fatal exit），main_loop / --once / --process-all 三处入口都调 |
| `ops-helper.sh` | `SNAPSHOT="${OPS_SNAPSHOT:-$WORKSPACE/.snapshot}"`（容器内默认行为不变） |
| `docker-compose.yml` | agent.volumes 加 `./snapshot:/app/workspace/.snapshot:ro` |
| `ops-baseline.json` | `agent_volumes_required` 加新挂载（baseline 与 compose 同步生效，互相对账） |
| `Dockerfile`（agent） | `COPY scripts/ops/ops-helper.sh /usr/local/bin/ops-propose` + chmod |
| `OPS-WATCHER-DESIGN.md` | 目录结构图 + 挂载形态注释（标记"实测成立"） |
| `MIGRATION-SOP.md` | 新文件，Plan C 完整步骤 |

helper escape hatch (`OPS_SNAPSHOT` / `OPS_SNAPSHOT_DIR`) 让宿主机
迁移期/调试期不需要撬脚本骨头：
```bash
# 宿主机调试时指向旧位置（迁移前）
OPS_SNAPSHOT=~/ai_sandbox/agent_workspace/.snapshot bash scripts/ops/ops-helper.sh ...
# 或指向新位置
OPS_SNAPSHOT_DIR=~/ai_sandbox/snapshot bash scripts/ops/ops-watcher.sh --once <id>
```

容器内默认（不设环境变量）行为完全不变。

### 已知遗留：DOCKER_INSECURE_NO_IPTABLES_RAW

用户生产机 `docker info` 显示 `WARNING: DOCKER_INSECURE_NO_IPTABLES_RAW is set`。
这是 Docker Desktop 实验态防火墙模式，会让 raw iptables 表绕过容器隔离的
部分检查。**和 ops-watcher 当前范围无关**，但下游某天处理网络隔离假设
（apply-proposal? Phase 4？）时需要重新评估。先记账，不在 B.x 处理。

### 还没做（B.2-B.4）

- B.2 Telegram 单向摘要通知（独立 .ops-watcher.env，权限不对则降级不崩）
  - 单向：只 sendMessage，永远不 getUpdates / 不开 webhook
  - 摘要：id / status / risk / 路径列表 / +N/-M 行
  - 有限 hunk：每 change 最多 5 行 unified diff，整体 ≤4KB
  - 频控：同 proposal_id 60s 内只发一次
  - 失败不阻断：Telegram POST 失败只写 events.jsonl ERROR
- B.3 集成测试 SOP（agent 容器内真实跑 ops-propose 全链路）
- B.4 launchd plist 开机自启（最后做）


---

## Checkpoint：B.1 生产实测完成（2026-05-17）

### 现场指纹
```
Date:               2026-05-17
Host:               macOS Mac mini (/Users/caimin/ai_sandbox)
Docker Server:      29.4.0
Storage Driver:     overlayfs
Firewall Backend:   iptables
DOCKER_INSECURE_NO_IPTABLES_RAW: set (out of scope, flagged for Phase 4)
```

### 完整证据链（每步都有真实 proposal id 留底）

```
OLD_ID:     20260517T065529Z (Step A.1 时代遗留)
SMOKE_ID:   20260517-083443-1e08bc → conflict (老 065617 占位)
SMOKE2_ID:  20260517-084006-28b44c → accepted_for_review LOW (supersedes 065617)
NEW_ID:     20260517T085136Z (init-snapshot 后)
POST_ID:    20260517-085137-2227da → conflict (老 065617 仍占位; B.1 hotfix 修复后会变 accepted)
```

### 核心目标达成

| 维度 | 证据 |
|---|---|
| Plan B 嵌套 :ro 挂载实测成立 | Phase 5 四种写操作全部 `Read-only file system` exit≠0，最后 cat .snapshot-id 仍是 OLD_ID |
| Plan C 身份保留 mv 成功 | Phase 3 三铆钉对账 + 双向校验全 OK；OLD_ID/HASH/CURRENT 完整保留 |
| 容器 ops-propose 命令到位 | Phase 6.1 `which` 返回 `/usr/local/bin/ops-propose` (21KB) |
| watcher 启动自检（compose 改动 + 新挂载 + 新 baseline） | Phase 4.6 rebuild 后 docker compose ps Up，无报错 |
| refresh 正确性（NEW_ID ≠ OLD_ID + bidirectional） | Phase 7.A.4 全 4/4 OK |
| bind mount 透明性 | Phase 7.A.6 refresh 后容器立刻读到 NEW_ID/NEW_HASH，无缓存 |
| 旧世界 happy path（supersedes） | Phase 6.7 SMOKE2 → accepted_for_review LOW + 065617 出现 superseded sibling |
| 新世界 helper 读到 NEW_ID | Phase 7.B.4 `matches: true`（base_snapshot_id == NEW_ID） |

### macOS Docker Desktop 实测细节

- 嵌套 `:ro` 在 `:rw` 子路径上**实测成立**（virtiofs / overlayfs 后端）
- 已知诊断噪音：`docker exec agent ls -la /app/workspace/.snapshot/` 输出第一行
  `ls: ... current: No such file or directory`，但下面照样列出 current symlink
  完整属性，且 `cat current/...` 完全可用。这是 virtiofs 处理嵌套挂载下 symlink
  的 lstat-vs-stat 差异，不影响实际功能。下游脚本不要依赖 `ls` 的 exit code
  判定 current 可用性，应该直接 `readlink` / `cat current/<file>` 验证。

### Step A.1 遗留 bug 在 B.1 实测中暴露并修复

`check_conflict` 判定老 proposal 占位时只看 `<id>.json.status`，不看
`<id>.superseded.json` sibling。导致已被 supersedes 的老 proposal 在 watcher
眼里仍然占位，新 proposal 即使显式 set-supersedes 一个**不同的**已 superseded 的
proposal，仍会撞老的。

修复：`scripts/ops/ops-watcher.sh` `check_conflict` 中 accepted_for_review 判定
后增加一行 `[ -f "$RESULTS_DIR/$other.superseded.json" ] && continue`。
4 行 hotfix，含注释。bash -n 通过。

### 还没做（B.2-B.4）

- B.2 Telegram 单向摘要通知（独立 .ops-watcher.env，权限不对则降级不崩）
- B.3 集成测试 SOP（agent 容器内真实跑 ops-propose 全链路）
- B.4 launchd plist 开机自启（最后做）

### MIGRATION-SOP.md 已发现的小问题（待 B.2 顺手修）

1. `docker compose up -d agent` 不会 rebuild 镜像；新 ops-propose 不会进容器。
   正确做法：`docker compose build agent && docker compose up -d agent`。
   B.1 实测中通过 Phase 4.6 增补步骤修正。
2. zsh 默认不识别 `# 注释`，命令块顶部用 `# ===` 装饰行会让 zsh 把分隔字符
   当命令名报 not found。SOP 应避免此风格，或显式 `setopt interactive_comments`。


---

## Checkpoint：B.1 hotfix v2 完成（2026-05-17）

### 抽象层补全

`<id>.json.status` 是 proposal 的**初始裁决**，但 proposal 实际状态会通过 sibling 文件演进。任何 watcher 决策（conflict 占位、supersedes target 是否合法、未来 apply 队列）都必须读"当前生命周期投影"，而不是初始裁决。

`get_effective_status(id)` 是这个投影的单一真相来源：

```
""                       proposal 不存在
pending                  目录在但还没出 result
accepted_for_review      仍占位（可被 supersede / 与其他 proposal 冲突）
superseded               sibling 投影（一期）；Phase 4 加 applied / rolled_back
blocked / rejected /
preflight_failed /
stale / conflict /
disabled                 已闭合（不占位）
```

### 生产实测三组验证

| 测试 | 输入 | 期望 reason | 实际 reason | OK |
|---|---|---|---|---|
| A | supersede conflict-state target (085137) | 必须 accepted_for_review | effective_status='conflict' (must be accepted_for_review) | yes |
| B | supersede already-superseded target (065617) | 必须 accepted_for_review | effective_status='superseded' (must be accepted_for_review) | yes |
| C | 不带 supersedes 改占位 path (084006 在占位) | 报 path conflict | path conflict with pending proposal '20260517-084006-28b44c' | yes |

### 现场 effective_status 总览（hotfix v2 视角）

```
20260517-065617-2e08a7   superseded            (最早占位，已被 084006 supersede)
20260517-071105-bb0219   blocked               (Step A.1 baseline 测试遗留)
20260517-083443-1e08bc   conflict
20260517-084006-28b44c   accepted_for_review   <- 当前唯一占位
20260517-085137-2227da   conflict
20260517-085656-c8d445   conflict
20260517-090438-511312   conflict   (TEST A)
20260517-090449-841981   conflict   (TEST B)
20260517-090510-69721c   conflict   (TEST C)
```

watcher 视野与现实完全一致。

### 设计意义

抽象层补对，下游不用再补丁：
- Phase 4 加 `<id>.applied.json` / `<id>.rolled_back.json` 时，`get_effective_status` 加 2 行 case 即可
- conflict / 未来 apply 队列 / 任何 lifecycle 判定都不需要再改一行
- "幽灵换个名字回来"在抽象层闭合，不会再以新形式涌现

### 还没做（B.2-B.4，不变）

- B.2 Telegram 单向摘要通知
- B.3 集成测试 SOP
- B.4 launchd plist 开机自启




---

## Checkpoint：B.2 Telegram 单向摘要通知（2026-05-17）

### 已交付（沙箱完成；待生产实测）

| 文件 | 改动 |
|------|------|
| `scripts/ops/ops-watcher.sh` | 新增 7 个函数：`load_telegram_env / should_notify_proposal / format_proposal_message / send_telegram_raw / notify_proposal / notify_lifecycle / check_lifecycle_edge`；新增统一终结点 `finalize_proposal`（write_result + consume + archive + notify 4 件套合并）；main_loop 加 started/stopped/edge 钩子；--once / --process-all 仅 load env 不发 lifecycle |
| `scripts/ops/.ops-watcher.env.example` | 新增模板（chmod 600 + 仅含 TELEGRAM_BOT_TOKEN/CHAT_ID） |
| `OPS-WATCHER-DESIGN.md` | 追加 B.2 checkpoint：status × risk matrix + 三条实现约束 + Phase 4 兜底声明 |

### 通知策略（status × risk matrix）

推送：accepted_for_review × {LOW,MEDIUM,HIGH}; blocked × BLOCK
静默：conflict / stale / rejected / preflight_failed / disabled / superseded

### 三条 hardening 约束（已落地）

1. `.notified.txt` 只存 proposal 三元组 `<id>:<status>:<risk>`；lifecycle 事件不写
2. disabled/resumed 边沿检测，state file `ops_spool/.lifecycle-state`
3. `.notified.txt` 只在 sendMessage HTTP 200 之后追加；失败只记 events.jsonl ERROR

### Superseded 静默 → Phase 4 兜底

apply-proposal.sh 必须在 apply 前重读 `get_effective_status`，拒绝非 accepted_for_review 的目标。已写入 OPS-WATCHER-DESIGN.md，Phase 4 实施时绕不过去。

### 还没测的

- 真 Telegram 推送（生产机 chmod 600 + 真 token + 一次 LOW proposal）
- lifecycle 4 档：started 上线、touch disabled flag → 收到 disabled、rm flag → 收到 resumed、Ctrl-C → 收到 stopped
- 网络故障下 .notified.txt 不被污染（断网模拟）

### B.3 / B.4 待办（不变）

- B.3 集成测试 SOP（agent 容器内真实跑 ops-propose 全链路 + Telegram 实测）
- B.4 launchd plist 开机自启



---

## Checkpoint：B.2 hotfix（2026-05-17）

### 触发原因

B.2 沙箱完成、生产首次实测：手机收不到 started，events.jsonl 全是 `error
"telegram send failed"`。诊断闭环（用户自己钉死的）：SR (Shadowrocket-on-Mac)
监听端口从 1086 飘到 1082，`.ops-watcher.env` 用的是过期端口。

### 已交付（沙箱完成；待生产实测）

| 文件 | 改动 |
|---|---|
| `scripts/ops/ops-watcher.sh` | 4 处：`TELEGRAM_PROXY_URL` 专用变量替代全局 HTTPS_PROXY；`load_telegram_env` 主动 unset 全局代理变量；`LAST_TELEGRAM_HTTP_CODE` 暴露 curl http_code 给 events.jsonl 诊断；`check_heartbeat` + 主循环 hook |
| `scripts/ops/.ops-watcher.env.example` | 加 `TELEGRAM_PROXY_URL` 注释 + 现实约束声明 |
| `OPS-WATCHER-DESIGN.md` | 追加 B.2 hotfix checkpoint：4 处改动 + 设计意图 + bash 3.2 兼容陷阱 + 不变量保持 |

### 关键设计决策（不破坏不变量）

1. **代理作用域局部化**：`TELEGRAM_PROXY_URL` 只对 sendMessage 一处生效，
   不再用 `HTTPS_PROXY`（全局开关 = 污染面太大）
2. **诊断可见性**：events.jsonl 出现 `telegram send failed` 时附带 http_code
   字段（000=连接失败 / 401=token错 / 400=chat_id错 / 429=rate limit）
3. **heartbeat 端到端心跳**：每 6h 发 `📊 watcher heartbeat snapshot=... queue=...
   last=...`，是"watcher + 代理 + telegram"三件事都活着的端到端证明
4. **失败推进时间戳**：heartbeat 失败也写 `.last-heartbeat`，避免代理离线时
   polling 模式 2s 一次刷 error 洪流（缺失的 heartbeat 本身就是出问题信号）

### 现实约束（写进文档）

> 依赖本地代理时，若 watcher 由 launchd 自启而代理客户端（SR/ClashX/Surge）
> 尚未就绪，started 通知可能发不出。watcher 主流程不受影响（write_event ERROR
> 兜底），但用户在手机上观察不到 started。**这是依赖本地代理出口的天然代价，
> 不是 watcher bug**。修复方案：B.4 launchd plist 加启动顺序约束 + heartbeat
> 心跳作为侧面信号（heartbeat 间隔内代理上线后第一个 tick 就有信号）。

### 用户操作（生产机最小动作）

```bash
SANDBOX=/Users/caimin/ai_sandbox
BASE=https://raw.githubusercontent.com/nydydc474g-art/kiro-projiects/ops-watcher-step-b-hotfix

curl -fsSL "$BASE/scripts/ops/ops-watcher.sh" -o "$SANDBOX/scripts/ops/ops-watcher.sh"
curl -fsSL "$BASE/scripts/ops/.ops-watcher.env.example" -o "$SANDBOX/scripts/ops/.ops-watcher.env.example"
chmod +x "$SANDBOX/scripts/ops/ops-watcher.sh"

# 改 .ops-watcher.env：把 HTTPS_PROXY=http://127.0.0.1:XXXX 改为 TELEGRAM_PROXY_URL=
sed -i '' 's|^HTTPS_PROXY=|TELEGRAM_PROXY_URL=|' "$SANDBOX/.ops-watcher.env"
chmod 600 "$SANDBOX/.ops-watcher.env"
cat "$SANDBOX/.ops-watcher.env"   # 确认是 TELEGRAM_PROXY_URL=...

# Ctrl-C 现在跑着的旧 watcher，重启
bash "$SANDBOX/scripts/ops/ops-watcher.sh"
```

期望：手机收到 started + events.jsonl 出现 `info "telegram sent"` 且
`http_code: "200"`。

### B.3 / B.4 待办（不变）

- B.3 完整生产 SOP：lifecycle 4 档 + proposal 4 档 + heartbeat（间隔可临时设
  60s 加速测试）一次性测完
- B.4 launchd plist 开机自启，加 SR 启动顺序约束 + heartbeat 作为侧面信号



---

## Checkpoint：B.2 hotfix 生产实测通过（2026-05-17）

```
manifest 拉新代码 → sed 改 .ops-watcher.env 一行 → 重启 watcher
↓
手机收到：ℹ️ ops-watcher started (snapshot=20260517T085136Z)
```

hotfix 三件事一次落地全过：`TELEGRAM_PROXY_URL` + `LAST_TELEGRAM_HTTP_CODE`
诊断 + heartbeat。配置层（端口 1082）+ 代码层（专用变量 + http_code 暴露 +
心跳）一起到位。

### 排查回血记录（以防再现类似问题）

#### 现场症状

- watcher 主循环正常上线（终端显示 `[ops-watcher] using fswatch`）
- 手机收不到 started 通知
- events.jsonl 末尾两条：`{"lvl":"error","event":"started"}` + `{"lvl":"error","event":"stopped"}`

#### 现象解读（事后回看是清晰的）

events.jsonl 里 lifecycle 事件**走 error 分支**意味着：
- watcher 主流程没崩（事件被记下了）
- TELEGRAM_DISABLED ≠ 1（否则 lifecycle 会 early return 不写日志）
- env 加载完成 + token/chat_id 都已读到
- 唯一失败的就是 `send_telegram_raw` 的 curl 调用本身

**但当时绕远的核心原因**：B.2 原版 `send_telegram_raw` 抛掉 curl 的
`%{http_code}` 没记日志，events.jsonl 只看到 `telegram send failed` 这 6 个字，
区分不出"代理端口不通 (000)" / "token 错 (401)" / "chat_id 错 (400)"。
诊断信息缺失就是开发债，把后面 1 小时的回路都浪费了。

#### 用户钉死根因的关键诊断手法

按用户原话："**同一 token 经不同代理端口经 getMe 直接对照测**"：

```
HTTPS_PROXY=http://127.0.0.1:1086 经 getMe → connection refused
HTTPS_PROXY=http://127.0.0.1:1082 经 getMe → ok:true
```

一个变量比另一个变量精确（端口号），就直接对照测——立刻钉死是端口飘移，
不是 token / 不是 SNI 阻断 / 不是 macOS curl 病态。

下次类似症状的诊断顺序（钉死/排除环节，不要绕到中间结论）：

1. `tail -5 events.jsonl | jq -c '{lvl,msg,extra}'` 看 watcher 自己的失败原因
2. **现在已经有 http_code**（hotfix 后），看 `extra.http_code`：
   - `000` → 代理端口不通 / DNS 失败 / TLS 被中间设备 reset
   - `401` → token 错
   - `400 / 404` → chat_id 错
   - `429` → rate limit
3. 只有 `000` 才需要进一步分层诊断（nc / curl --noproxy / curl 别的域名）

这里的关键教训：**给失败路径足够的诊断信息是不可妥协的**。`telegram send failed`
不带 http_code = 把所有失败模式合并成一个，浪费定位时间。hotfix 已修。

#### 我的反思（chat-agent 反复回头记录）

诊断中我有 4 个错误前提，每个都让排查绕了一段路：

1. **直觉性误判 1**：见到 `SSL_ERROR_SYSCALL` 立刻归因"GFW 对 telegram 域名做 SNI
   阻断"。现实：SR 在 Mac 上**确实**接管了浏览器流量（用户实测能上 telegram
   网页），是宿主机 curl 用的过期代理端口。
2. **直觉性误判 2**：误以为"iOS 版 SR 装在 Apple Silicon Mac 上不工作"。现实：
   PacketTunnel.appex 真在跑，端口配置只是飘了。
3. **盲区**：B.2 没把 http_code 写进 events.jsonl 是开发债。
4. **越界**：用户多次给反证（"浏览器能上 google"、"bot 定时消息能收"），我没
   立刻撤回错误结论，仍按错前提推下去。直到用户当面钉死才转向。

教训：**用户的现场观察是事实证据，不是需要驳斥的对象**。下次类似现象，先
拿用户的反证当锚点，反推自己结论的弱点，不要按预设结论推到最后。

### 分支拓扑（下个窗口的入口）

```
main
└── ops-watcher-step-b               ← Step A + A.1 + B.0 + B.1 + B.2 沙箱稿（未生产实测）
    └── ops-watcher-step-b-hotfix    ← B.2 hotfix（已生产实测通过 ★ 当前推荐分支）
        commit 5d4d6b4 — TELEGRAM_PROXY_URL + http_code 诊断 + heartbeat
        commit 5ce4c9b — feat(B.2): Telegram one-way summary notifications
```

**生产宿主机当前运行的代码 = `ops-watcher-step-b-hotfix` 分支 5d4d6b4**。
config: `~/ai_sandbox/.ops-watcher.env` 含 `TELEGRAM_PROXY_URL=http://127.0.0.1:1082`。

### 给下个窗口的入口指令

> "继续 ops-watcher 项目的 Step B.3。读 `OPS-WATCHER-DESIGN.md` 与
> `HANDOFF-OPS-WATCHER.md`，然后实施 B.3 完整生产实测 SOP。
> 当前分支：`ops-watcher-step-b-hotfix`。生产已运行此分支代码，started
> 通知收到了，但 lifecycle 4 档 + proposal 4 档 + heartbeat 都还没系统测过。"

### B.3 完整测试清单（下窗口要做）

heartbeat 间隔默认 6h，测试时建议先用短间隔加速：

```bash
# 临时 60s 间隔加速测试
OPS_HEARTBEAT_INTERVAL=60 bash scripts/ops/ops-watcher.sh
```

#### Lifecycle 4 档边沿测试

| 动作 | 期望手机收到 | 期望 events.jsonl |
|---|---|---|
| `bash ops-watcher.sh` | started | `info "telegram sent"` `kind=lifecycle event=started http_code=200` |
| `touch .ops-watcher.disabled` | disabled (next loop iteration) | 同上 `event=disabled` |
| `rm .ops-watcher.disabled` | resumed | 同上 `event=resumed` |
| `Ctrl-C` | stopped | 同上 `event=stopped` |

注意：**首次启动 prev="" 不发 resumed**（设计内）。`.lifecycle-state` 文件
内容验证：`cat ops_spool/.lifecycle-state` 应该等于 `enabled`。

#### Proposal 4 档（status × risk matrix）

| 提交内容 | 期望 status × risk | 期望手机 | 期望幂等表 |
|---|---|---|---|
| 白名单加 1 域名 | accepted_for_review × LOW | ✅ 通知 | `<id>:accepted_for_review:LOW` |
| Dockerfile 装包 | accepted_for_review × MEDIUM | 🟡 通知 | `<id>:accepted_for_review:MEDIUM` |
| 新增服务 | accepted_for_review × HIGH | 🔴 通知 | `<id>:accepted_for_review:HIGH` |
| 改 guard.sh 路径 | blocked × BLOCK | 🚨 通知 | `<id>:blocked:BLOCK` |
| supersedes 走通 | superseded sibling | **静默** | 不进幂等表 |

#### Heartbeat

设 `OPS_HEARTBEAT_INTERVAL=60` 启动，等 60s 后手机应该收到：
```
📊 watcher heartbeat
snapshot=... queue=... last=...
```
然后 60s 再一次。**不进幂等表**，每次都发是设计目的。

#### 失败路径（断网模拟）

- 关掉 SR / 把 `TELEGRAM_PROXY_URL` 改成假端口
- 触发一个 LOW proposal
- 期望：events.jsonl 出现 `error "telegram send failed"` `http_code=000`
- **关键**：`.notified.txt` 不应被污染（`grep <id> .notified.txt` 应该为空）
- 恢复 SR 后再触发一个 LOW（或重提同 proposal）：`.notified.txt` 这时才追加

#### B.4 之前的已知约束（不需要在 B.3 测，但要写进文档）

- fswatch 模式长时间无 proposal 流量会错过 heartbeat tick（B.4 launchd 重构时再改）
- launchd 自启时若 SR 还没起来，started 通知会丢——主流程不受影响（B.4 加启动顺序约束）
- `kill -9` / OOM kill 不触发 stopped 通知——这是设计内盲区，靠 heartbeat 兜底

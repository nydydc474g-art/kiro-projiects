# Ops Watcher 交接文档（HANDOFF）

> 状态：Step A + A.1 完成，Step B 待启动。
> 分支：`ops-watcher`
> 仓库：https://github.com/nydydc474g-art/kiro-projiects/tree/ops-watcher

---

## ⚠️ 最新进度指针（覆盖以下旧入口，2026-05-17）

> **本文件追加式更新，前文不重写。**
> 如果你是新窗口的 agent，先读这一段定位进度，再按指引跳到末段。

- 当前最新分支：`ops-watcher-step-b-hotfix`（含 commit `3c0a60c` line 573 修复 + `26696aa` 文档同步）
- 生产宿主机当前实际跑的：**`ops-watcher-step-b-hotfix` 头部代码** + watcher 在前台 polling 模式跑着
- env 当前形态：`TELEGRAM_PROXY_URL=http://127.0.0.1:1082`（cutover 已完成）
- B.2 hotfix 三件事 + line 573 修复**全部生产实证通过**（详见末段 checkpoint）
- Lifecycle 4 档：started ✅ disabled ✅ resumed ✅ / stopped 留到 B.3 末尾
- B.3 proposal 4 档：LOW ✅ `20260517-122027-ea3b87` / MEDIUM ✅ `20260517-122337-7f1f91` / HIGH ✅ `20260517-123059-9048d1` / BLOCK 待做
- 下窗口（如果是新会话接手 B.3 之后阶段）的入口：跳到末段最新一条 checkpoint
  `Checkpoint：B.2 hotfix 生产实证 + line 573 修复（2026-05-17）`

历史快照（仅供查阅，不要照做）：
- 末段 `下窗口必跑：Cutover SOP` —— cutover 已完成，**SOP 不再需要执行**
- 末段 `Checkpoint：B.2 hotfix 沙箱完成；生产仍未实测` —— 已被新 checkpoint 覆盖
- 中段 `### 分支拓扑（下个窗口的入口）`（约 line 700，埋在 B.2 hotfix 段内）
  —— 当时分支信息已过期，**以本节正下方 `## 当前分支拓扑（最新）` 为准**

---

## 当前分支拓扑（最新，2026-05-17 晚）

```
main
├── ops-watcher-step-b               Step A + A.1 + B.0 + B.1 + B.2 沙箱稿
│                                    （5ce4c9b 头）
│                                    生产**已不再跑这份**，cutover 后切到 hotfix 分支
│
└── ops-watcher-step-b-hotfix        当前生产分支 ★
    │   ↓ 提交链（最新在上）
    ├── 26696aa  docs(B.2): hotfix production-verified + line 573 fix + lifecycle 3/4
    ├── 3c0a60c  fix(B.2): heartbeat queue count — replace ls glob with find  ★ 关键 fix
    ├── bab4733  docs(B.2): correct hotfix verification status — sandbox done, production untested
    ├── d1a1210  docs(B.2): branch topology + B.3 checklist + cutover SOP (当时叙事有误，bab4733 已纠正)
    ├── 5d4d6b4  fix(B.2): TELEGRAM_PROXY_URL + http_code diagnostics + heartbeat
    └── 5ce4c9b  feat(B.2): Telegram one-way summary notifications  (= ops-watcher-step-b 头)
```

**生产宿主机当前运行的代码 = `ops-watcher-step-b-hotfix` 分支头**（HEAD =
26696aa；可执行代码到 3c0a60c 即生效，26696aa 之后只动文档）。
config: `~/ai_sandbox/.ops-watcher.env` = `TELEGRAM_PROXY_URL=http://127.0.0.1:1082`。
watcher 进程 PID 38521 在前台跑着（polling 模式，`OPS_HEARTBEAT_INTERVAL=60` 测试加速）。

### 合并策略（暂未决，留给收尾时再讨论）

- **选项 A**：B.3 + B.4 全部跑完后，把 `ops-watcher-step-b-hotfix` 合回
  `ops-watcher-step-b`，再合 main
- **选项 B**：B.3 / B.4 继续在 hotfix 分支推，最后整条合 main
  （hotfix 分支演化成事实上的 step-b 终稿）

用户偏好的"追加不重写"叙事更适合选项 B——历史 commit 不动，反映"hotfix
分支自然演化成 step-b 终稿"的事实。但这是收尾决策，不在 B.3 / B.4 范围内。

**下窗口接手时不要主动合并 / rebase**，先确认用户意图。

### 分支命名为什么留着 "-hotfix" 后缀

不改名是有意的：

- 改名（rename branch）= 强行重写历史叙事（"它从来都是 step-b 的一部分"）
- 不改名 = 保留事实（"这是为修一个生产 bug 临时开的分支，最后承担了远超原始范围的工作"）
- 选项 B 合并时，git history 会原样保留 `ops-watcher-step-b-hotfix` 这个分支名
  作为提交注解的一部分，对 5 年后回看的人是有价值的考古证据

**下窗口若想"清理一下"改名，先确认。**

### 远端 SHA 和本地 SHA 的小注

`gateway.connections.autonomous-agents.kiro.dev` 这条 git 远端在 push 时会
**重签提交**（保留所有内容和提交消息，但 SHA 改变）。所以：

- 本地（agent sandbox）和 GitHub 上看到的 SHA 不完全一致
- 上面提交链的 SHA 是 **GitHub 远端**值（用户走 raw.githubusercontent.com / 网页看到的就是这一份）
- 这是 gateway 工作模式的副作用，不是 bug，**不要试图 rebase 对齐**

---

## 一句话现状（历史快照，已被上方指针覆盖）

Watcher 静态判定内核已生产实测通过：proposal 提交 → 14 项静态检查 → 写权威结果 + 单行路标 + 审计流。**还没接 Telegram，还没改 compose，还没让 agent 容器真正能用 ops-propose。**

---

## 给下个窗口的第一句话（历史快照，已被上方指针覆盖）

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

### 前置事实（下窗口拉 hotfix 之前必读）

B.2 沙箱稿（5ce4c9b，分支 `ops-watcher-step-b`）首次生产实测时，
用户**手动把 `.ops-watcher.env` 里的代理端口从 1086 改为 1082**
（修了 SR 端口飘移）然后重启旧 watcher 才收到 started。所以生产机
当前 env 内容是：

```
HTTPS_PROXY=http://127.0.0.1:1082
```

**端口已是新值，但变量名仍是旧的 `HTTPS_PROXY`**。下面 SOP 里的
`sed -i '' 's|^HTTPS_PROXY=|TELEGRAM_PROXY_URL=|'` 只替换变量名，
端口和值原样保留，所以 SOP 仍然正确。下窗口拿到这个 env 直接跑 SOP
即可，不要再额外改端口。

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

## Checkpoint：B.2 hotfix 沙箱完成；生产仍未实测（2026-05-17）

> **重要更正**：先前在此处写过"生产实测通过"+ "hotfix 三件事一次落地全过"
> 是错误叙述，已纠正。事实如下。

### 真实状态

- B.2 hotfix（5d4d6b4）**只在沙箱完成代码**；hotfix 代码本身**尚未在生产
  宿主机上跑过**
- 生产机当晚收到 `started` 通知是另一条路径触发的：用户**手动把
  `.ops-watcher.env` 的代理端口从 1086 改为 1082**（修了 SR 端口飘移），
  **重启的仍是 B.2 沙箱稿（5ce4c9b 上的 `ops-watcher-step-b` 旧 watcher）**，
  那一份代码用的是全局 `HTTPS_PROXY` 路径
- 由此能确认的只有两件事：
  1. 端口飘移（1086 → 1082）确实是 started 不出的根因
  2. 旧 watcher（B.2 沙箱稿 + `HTTPS_PROXY` 路径）在端口正确时工作正常
- **不能确认**的：hotfix 三件事（`TELEGRAM_PROXY_URL` 专用变量 /
  `LAST_TELEGRAM_HTTP_CODE` 诊断 / `check_heartbeat`）在生产机上是否如设计工作
- 生产机 `.ops-watcher.env` 当前内容是 `HTTPS_PROXY=http://127.0.0.1:1082`
  （旧变量名 + 新端口），不是 `TELEGRAM_PROXY_URL=...`

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
不带 http_code = 把所有失败模式合并成一个，浪费定位时间。hotfix 代码已写
（5d4d6b4），但还没在生产机上跑过——见上方更正段。

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
└── ops-watcher-step-b               ← Step A + A.1 + B.0 + B.1 + B.2 沙箱稿
    │                                  生产宿主机当前实际跑的就是这一份代码
    │                                  （5ce4c9b，env 是 HTTPS_PROXY=...:1082）
    └── ops-watcher-step-b-hotfix    ← B.2 hotfix 沙箱完成，未生产实测
        commit d1a1210 — docs: branch topology + B.3 checklist + cutover SOP
        commit 5d4d6b4 — TELEGRAM_PROXY_URL + http_code 诊断 + heartbeat
        commit 5ce4c9b — feat(B.2): Telegram one-way summary notifications
```

**生产宿主机当前运行的代码 = `ops-watcher-step-b` 分支 5ce4c9b（B.2 沙箱稿）**。
config: `~/ai_sandbox/.ops-watcher.env` 当前是 `HTTPS_PROXY=http://127.0.0.1:1082`。

下窗口的第一件事是按本文件下方的 **Cutover SOP** 把 hotfix 真正搬到生产机
（拉代码 → sed 改 env 变量名 → 重启 watcher），实测通过后再做 B.3。

### 给下个窗口的入口指令

> "继续 ops-watcher 项目的 Step B.2 hotfix cutover + B.3。读
> `OPS-WATCHER-DESIGN.md` 与 `HANDOFF-OPS-WATCHER.md`，**先按 Cutover SOP
> 把 hotfix 搬到生产机并实测过 started 一次**，再实施 B.3 完整生产实测 SOP。
> 当前生产分支：`ops-watcher-step-b`（沙箱稿，B.2 hotfix 尚未在生产机跑过）。
> hotfix 代码在 `ops-watcher-step-b-hotfix` 分支等待搬迁。已知事实：端口飘移
> 1086→1082 是 started 不出的根因，沙箱稿 + 1082 端口下 started 工作。
> hotfix 三件事（专用代理变量 / http_code 诊断 / heartbeat）尚未在生产实证。"

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



---

## 下窗口必跑：Cutover SOP（拉 hotfix → 改 env → 重启）

> 本节是把上方"Checkpoint：B.2 hotfix（2026-05-17）"段里的"用户操作（生产机最小动作）"
> 提到末段独立成节，方便下窗口直接落地。SOP 与那一段保持完全一致。

### 前置事实（必读）

生产机 `.ops-watcher.env` 当前内容是：

```
HTTPS_PROXY=http://127.0.0.1:1082
```

**端口已是新值（1082，不是过期的 1086），但变量名仍是旧的 `HTTPS_PROXY`**。
这是因为 B.2 沙箱稿首次实测时用户当晚只手动改了端口、没换变量名，重启的还是
旧 watcher。下面的 `sed` 命令只替换变量名，端口和值原样保留——不需要再额外
改端口。

### Cutover 三步

```bash
SANDBOX=/Users/caimin/ai_sandbox
BASE=https://raw.githubusercontent.com/nydydc474g-art/kiro-projiects/ops-watcher-step-b-hotfix

# 1. 拉 hotfix 代码（脚本 + env 模板）
curl -fsSL "$BASE/scripts/ops/ops-watcher.sh" -o "$SANDBOX/scripts/ops/ops-watcher.sh"
curl -fsSL "$BASE/scripts/ops/.ops-watcher.env.example" -o "$SANDBOX/scripts/ops/.ops-watcher.env.example"
chmod +x "$SANDBOX/scripts/ops/ops-watcher.sh"

# 2. 改 .ops-watcher.env：把 HTTPS_PROXY=http://127.0.0.1:1082 改成
#    TELEGRAM_PROXY_URL=http://127.0.0.1:1082（端口和值不动，只换变量名）
sed -i '' 's|^HTTPS_PROXY=|TELEGRAM_PROXY_URL=|' "$SANDBOX/.ops-watcher.env"
chmod 600 "$SANDBOX/.ops-watcher.env"
cat "$SANDBOX/.ops-watcher.env"   # 确认是 TELEGRAM_PROXY_URL=http://127.0.0.1:1082

# 3. Ctrl-C 现在跑着的旧 watcher（B.2 沙箱稿），重启
bash "$SANDBOX/scripts/ops/ops-watcher.sh"
```

### 期望结果

- 手机收到：`ℹ️ ops-watcher started (snapshot=...)`
- `tail -3 ~/ai_sandbox/ops_spool/events.jsonl | jq -c .` 出现：
  - `lvl=info` `msg="telegram sent"` `kind=lifecycle` `event=started` `http_code=200`

如果 http_code != 200：见上方"Checkpoint：B.2 hotfix 沙箱完成；生产仍未实测"
段的"排查回血记录"诊断分层（000 / 401 / 400 / 429）。

### 完成后再做

cutover 实测通过后，按上方"### B.3 完整测试清单（下窗口要做）"逐项验证：
lifecycle 4 档边沿 → proposal 4 档（status × risk matrix）→ heartbeat（用
`OPS_HEARTBEAT_INTERVAL=60` 加速）→ 失败路径（`.notified.txt` 不被污染）。

B.3 全部通过后，再开 B.4（launchd plist 自启），把 fswatch tick miss /
launchd race / kill -9 silent gap 三条已知约束在 plist 设计里兜住。




---

## Checkpoint：B.2 hotfix 生产实证 + line 573 修复（2026-05-17）

> 追加日志，不改前文。本段把 cutover 当晚发现并修掉的一个崩溃 + 三件套实证记下来。

### 一句话

cutover 第一次启动 watcher 几秒内崩溃；找到 hotfix 引入的 ls glob 空匹配在 `set -eo pipefail` 下杀脚本的根因；改用 `find -maxdepth 1 -type f -name '*.json'` 修复；改后 hotfix 三件事 + lifecycle 3/4 档全部实证通过。

### 崩溃现场（B.2 hotfix 5d4d6b4 引入的 bug）

**症状**：cutover 后 `bash ops-watcher.sh` 启动后 5-10 秒内退出，`ps` 看不到进程，没有任何错误信息。

**复现条件**：`ops-requests/` 目录为空（fresh watcher 的稳态）。

**根因**：`scripts/ops/ops-watcher.sh` line 573（hotfix 5d4d6b4 新加的 `check_heartbeat` 内）：

```bash
queue=$(ls "$REQUESTS_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
```

- 空目录时 `ls *.json` exit 1（macOS 默认行为）
- `2>/dev/null` 只压 stderr，不改 exit code
- `set -o pipefail` 让管道继承非零 exit
- `set -e` 在赋值 RHS 失败上动手 → 杀脚本

`+ queue=0` 在 `bash -x` trace 里出现，因为 wc 在空输入下输出 0；但赋值之后 set -e 才触发。这是 learnings 里 "macOS bash 3.2 + grep 零匹配 = exit 1 = 经典坑" 的近亲，只是这次 hit point 是 ls。

**probe 实验钉死假设**：

```
empty ops-requests/  → watcher dies after 'queue=0' (两次 trace 完全一致)
echo '{}' > __probe.json
ALIVE                 → trace 走完: queue=1 → last_proposal=__probe → msg=... →
                                    send_telegram_raw → http_code=200 → write_event
```

二值翻转，物理实验级别的对照证据。

### 修法

```diff
- queue=$(ls "$REQUESTS_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
+ queue=$(find "$REQUESTS_DIR" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | wc -l | tr -d ' ')
```

commit `3c0a60c` 一行修复 + bash -n 通过。

### 设计层面的教训（值得保留为原则）

第一直觉的 fallback `... || echo "0"` **正确性更低**：

- 空匹配时 `wc -l` 已经输出了一行 `0`，再追加 fallback 的 `0` → `queue=$'0\n0'`
- 后续 `printf "queue=%s"` 渲染成两行 0
- jq `--arg q "$queue"` 拿到带换行的字符串

`find` 的契约和 `ls` 不同：**找不到匹配安静返回 exit 0 + stdout 空**，wc 拿到空输入输出 0，整条管道天然干净。

**原则**：工具语义和需求不对齐时，**换工具**比"包 fallback 兜底"更稳。fallback 链本身会引入"成功路径污染"这种隐性 bug，是 N+1 个修复带 N+2 个新坑的来源。

副作用是诊断能力变差一点（find 把"目录失败"和"目录空"合并成同一个 stdout 空），但这是单独的问题——应该用启动自检 `[ -d "$REQUESTS_DIR" ] || die ...` 解决，不该塞到队列计数那一行里。一行职责单一原则。

### 已实证清单（line 573 修复后，连续 5+ 个 tick 稳定）

| 维度 | 证据 |
|---|---|
| watcher 主循环不崩 | `ps` 一直能看到进程；连续 5+ heartbeat tick 没退出 |
| `TELEGRAM_PROXY_URL` 专用代理变量 | started + heartbeat 全部 `http_code=200`，curl 走的是 `--proxy` 显式参数 |
| `LAST_TELEGRAM_HTTP_CODE` 成功路径 | events.jsonl 每条 lifecycle/heartbeat 都带 `http_code` 字段 |
| `LAST_TELEGRAM_HTTP_CODE` 失败路径 | 12:11:03 一条意外的 `heartbeat send failed http_code:000`（用户当时切了 SR），完美演示了诊断价值——000 = 连不通代理 |
| `check_heartbeat` 端到端心跳 | 60s 间隔下连续 5 次 heartbeat 发到手机；`watcher + 代理 + telegram` 三件事都活着的端到端证明 |
| heartbeat 失败不阻断主流程 | 12:11:03 失败后下一次 12:11:39 仍然正常发出 disabled 通知，主循环未受影响 |
| `.last-heartbeat` 失败也推进 | 12:11:03 失败后没有 polling 2s 一次刷 error 洪流 |

### Lifecycle 4 档：3/4 已实证

| 档 | 触发 | 实测时间 | http_code | 状态 |
|---|---|---|---|---|
| started | `bash ops-watcher.sh` 启动 | 12:05:54 | 200 | ✅ |
| disabled | `touch .ops-watcher.disabled` | 12:11:39 | 200 | ✅ |
| resumed | `rm .ops-watcher.disabled` | 12:11:42 | 200 | ✅ |
| stopped | Ctrl-C / SIGTERM | — | — | 留到 B.3 末尾测 |

**首次启动 prev="" 不发 resumed** 这条设计内的边界也间接实证：12:05:54 那次 started 之后**没有**额外的 resumed 出现，符合 `check_lifecycle_edge` 的"prev 是 disabled 才发 resumed"逻辑。

`.lifecycle-state` 文件最终内容 `enabled`，绕一圈回到原点，state 机干净。

### 三条 hardening 约束的部分实证

| 约束 | 实证情况 |
|---|---|
| 1. `.notified.txt` 只存 proposal 三元组 | 部分实证 — lifecycle 全部走完没污染 `.notified.txt`（heartbeat 有 5+ 次也没进表）；proposal 部分留待 B.3 |
| 2. disabled/resumed 边沿检测 | ✅ 12:11:39 + 12:11:42 各一条；polling 模式 2s tick 没有重复发 |
| 3. `.notified.txt` 只在 HTTP 200 之后追加 | 部分实证 — heartbeat 12:11:03 失败时没向 `.notified.txt` 写任何东西（heartbeat 本来就不进表，但行为正确）；proposal 失败路径留待 B.3 |

### 已知现场状态（继续 B.3 前必读）

`ops-results/` 内有 9 个 B.1 时代的真 proposal 残留，其中：

- `20260517-084006-28b44c` 仍是 `accepted_for_review LOW`，**仍占位** `proxy/allowed_domains.txt`
- 其他 8 个都已闭合（superseded / blocked / conflict）

按 effective_status 投影规则，只有 084006 仍占位。下一步 B.3 LOW 档测试需要决定怎么处理这条占位（路径白名单的"典型 LOW"就是改 `proxy/allowed_domains.txt`）。

读这条 manifest 后确认它本身就是 B.1 烟雾弹（`reason: B.1 smoke test (supersedes old accepted)`），不是真业务意图。下一步 B.3 LOW 测试**用新 proposal 显式 supersede 它**，一举两得：

- 顺手清掉 B.1 唯一遗留的幽灵占位
- LOW happy path 走最 canonical 的白名单加域名路径
- 同时实证 hotfix 后的 `supersedes` 仍能正确释放占位（B.1 hotfix v2 effective_status 抽象的第二轮生产实证）

### 修复后 watcher 仍是前台跑着的（写本段时）

```
caimin@... 38521 ... bash /Users/caimin/ai_sandbox/scripts/ops/ops-watcher.sh
```

下一步直接进 B.3 proposal 4 档不需要重启 watcher，直接 submit 即可。

### B.3 / B.4 待办（缩窄一档）

- B.3 proposal 4 档（status × risk matrix）—— 即将做
  - LOW：白名单加域名 + supersedes 084006
  - MEDIUM：notifier/notifier.py 改文案 或 proxy/squid.conf 改 ACL
  - HIGH：docker-compose.yml 加新服务
  - BLOCK：试图改 claude_config 路径下任意文件（被路径白名单拒）
- B.3 失败路径（断网/假端口 → LOW proposal → http_code=000 + `.notified.txt` 不污染）
- B.3 lifecycle stopped（Ctrl-C）
- B.4 launchd plist 开机自启




---

## Checkpoint：B.3 proposal 3/4 档实证（2026-05-17）

> 追加日志，不改前文。LOW / MEDIUM / HIGH 三档生产实证 + status × risk matrix
> 三格闭合。BLOCK 一格留给下窗口。

### 一句话

通过 helper 容器内 `ops-propose` 流程，依次提交 LOW / MEDIUM / HIGH proposal，watcher 全部正确分类、正确推送通知、正确写幂等表；HIGH 路径同时实证三层闸门（baseline invariants → global rules → preflight compose_config）穿透 + 真分类。

### 三档生产证据

```
LOW    20260517-122027-ea3b87   proxy/allowed_domains.txt + supersedes 20260517-084006-28b44c
       preflight: compose_config=not_run, dockerfile_lint=not_run
       附带证据：旧 084006 长出 .superseded.json sibling，effective_status 投影闭合
                superseded sibling 静默不进 .notified.txt
                B.1 hotfix v2 设计意图（effective_status 抽象）二轮实证

MEDIUM 20260517-122337-7f1f91   proxy/squid.conf no-op marker comment
       preflight: compose_config=not_run, dockerfile_lint=not_run
       Telegram: 🟡 + apply 简便命令 + diff 选项

HIGH   20260517-123059-9048d1   docker-compose.yml: squid 服务加 healthcheck 段
       preflight: compose_config=ok ★ 真跑了，dockerfile_lint=not_run
       Telegram: 🔴 + "HIGH RISK — REVIEW CAREFULLY" + 强制 --high 标志
```

### HIGH 这一档的特别意义（设计层面）

这条 HIGH proposal **没被 BLOCK** 也**没 preflight_failed**，是穿过整条管道每一个真闸门后才被分类到 HIGH 的：

| 闸门 | 状态 | 证据 |
|---|---|---|
| `check_baseline_invariants` | 通过 | 候选 compose 没改 agent 的 read_only / cap_drop / security_opt / user / 必需挂载 |
| `check_global_rules` | 通过 | 没命中 privileged / docker.sock / cap_add / ports / host net|ipc|pid|userns |
| `isolated_preflight` | 通过 | preflight.compose_config.status=`ok` —— `docker compose config` 真跑了一遍 |
| `classify_risk` | 命中 HIGH | 因为 `has_compose=1` |

LOW 和 MEDIUM 这两档在 isolated_preflight 这一段是 `not_run`（路径白名单内但不涉及 docker-compose.yml / Dockerfile，preflight 直接跳过）。HIGH 这条**真的去跑了 docker compose config**，是 HIGH 路径独有的物理证据。

不是 "它被 classify_risk 函数判定成 HIGH 这么简单"，而是 "它穿过 baseline 守门 + 全局规则扫描 + compose 预演，仍被接受，再被分级"。这是一次完整的端到端集成测试。

### 状态 × risk matrix 闭合情况

| status × risk | 推送 | 实证 |
|---|---|---|
| accepted_for_review × LOW | ✅ | 122027 ✓ |
| accepted_for_review × MEDIUM | ✅ | 122337 ✓ |
| accepted_for_review × HIGH | ✅ | 9048d1 ✓ |
| blocked × BLOCK | ✅ | 留待下窗口 |
| superseded sibling | 静默 | 084006 ✓（间接实证） |

矩阵 5 格中 4 格已闭合。BLOCK 一格是最后一块拼图。

### `.notified.txt` 状态（B.3 实证中三档累积）

```
20260517-122027-ea3b87:accepted_for_review:LOW
20260517-122337-7f1f91:accepted_for_review:MEDIUM
20260517-123059-9048d1:accepted_for_review:HIGH
```

三行干净对应三档，每条 proposal 一行。两个 hardening 约束实证：
- 三元组 `<id>:<status>:<risk>` 是幂等表唯一格式（lifecycle / heartbeat / superseded sibling 全部不进表）
- 仅 HTTP 200 后才追加（events.jsonl 三条 `telegram sent` 全部 http_code=200）

### Telegram 文案分层验证

四档 emoji + 文案分层都对：

| risk | emoji | 关键文案 | apply 命令 |
|---|---|---|---|
| LOW | ✅ | 普通摘要 | `apply: ops <short>` |
| MEDIUM | 🟡 | 普通摘要 + diff 选项 | `apply: ops <short>` + `diff: ops-diff <short>` |
| HIGH | 🔴 | "HIGH RISK — REVIEW CAREFULLY" | `review: ops-diff <short>` + `apply (must use --high): ops-apply --high <short>` |
| BLOCK | 🚨 | 待 | 待（设计上：`audit: ops-spool view <short>` + 不提供 apply 命令） |

HIGH 文案的心理摩擦做出来了——没有简便 `ops <id>`，必须用更长的 `ops-apply --high <id>`。MEDIUM 和 HIGH 的视觉区别（🟡 vs 🔴 + 加强警示语）对手机阅读体验是关键。

### 顺手钉死的几件事

1. **B.1 烟雾弹清理**：084006 这条 B.1 时代留下的"幽灵占位"通过 122027 的 supersede 顺手清掉。effective_status 投影机制在 B.1 hotfix v2 的两轮实证全部通过（一次是 supersedes target 合法性、一次是 conflict 占位检测）。
2. **PROPOSAL_PATH_ALLOWED 路径白名单实测**：MEDIUM 用 `proxy/squid.conf`，HIGH 用 `docker-compose.yml`，两条都在白名单内，watcher 都接受。
3. **classify_risk 规则实测**：
   - `proxy/allowed_domains.txt` → LOW
   - `proxy/squid.conf` → MEDIUM
   - `docker-compose.yml` → HIGH
   分级规则与 watcher 代码 line 1180-1220 的 `classify_risk` 函数完全一致。

### BLOCK 档预设计（下窗口做）

BLOCK 档语义跟前三档不同：前三档是"agent 提了合法变更"，BLOCK 是"agent 试图触碰绝对不变量"。

两条触发路径：
- 路径 1：BLOCK paths（早闸门，第 3 个 check）— 路径白名单外，如 `claude_config/hooks/guard.sh`
- 路径 2：global rules（晚闸门，compose 改动后）— 如加 `privileged: true`

按 B.3 测试目标只需测一条。**推荐路径 1**（更简单、不碰 YAML）。

**关键挑战**：helper 前端 `ops-propose add` 在 `claude_config/...` 路径上会**直接拒绝**（PROPOSAL_PATH_ALLOWED 白名单）。这是设计意图（前端防脏 + 后端纵深冗余）。

所以 B.3 BLOCK 测试需要**直接在宿主机手写 manifest + request**，绕过 helper 前端，让 watcher 真处理一个 BLOCK 路径的 proposal。这恰好测的是设计文档里"watcher 不信任 helper"那条原则——如果 helper 有 bug / 被绕过 / 有人手写攻击，watcher 后端是否还能拦住。

详细操作命令在本次会话的对话历史中（chat agent 已给过 jq -n 拼 manifest 的完整脚本，不再重抄）。下窗口直接读会话尾部"BLOCK 档预设计"段即可。

预期：

```
status=blocked
risk_level=BLOCK
reason="changes path 'claude_config/hooks/guard.sh' touches BLOCK invariant ..."
events.jsonl: "BLOCK path detected" + "telegram sent kind=proposal status=blocked risk=BLOCK http_code=200"
.notified.txt 新增: <id>:blocked:BLOCK
手机收到 🚨 通知（"BLOCKED · agent attempted invariant touch"）
```

### 还没做（B.3 / B.4）

- B.3 proposal 4 档的最后一格：BLOCK（待下窗口）
- B.3 失败路径主动测试（关 SR / 假端口 → LOW proposal → events.jsonl http_code=000 + `.notified.txt` 不污染）
- B.3 lifecycle stopped（Ctrl-C；watcher 当前仍前台跑着，PID 38521）
- B.4 launchd plist 开机自启 + heartbeat 端到端覆盖 fswatch tick miss 局限

### 现场状态（写本段时）

- watcher 仍前台 polling 跑着，PID 38521
- 累计已发送：started ×1 / disabled ×1 / resumed ×1 / heartbeat 多条 / proposal accepted ×3 / heartbeat send failed ×1（用户切 SR 那次，已恢复）
- `.notified.txt` 三行（见上）
- `ops-results/` 累计 11 份 result（B.1 时代 9 个老的 + B.3 新增 LOW/MEDIUM/HIGH 三个）
- `effective_status` 全场视角：除 122027 / 122337 / 9048d1 三个 accepted_for_review 占位外，其他全部已闭合

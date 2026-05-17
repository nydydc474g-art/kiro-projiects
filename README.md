# kiro-projiects

> **生产分支**: `ops-watcher-step-b-hotfix` （main 落后，不是生产代码）

## 项目概述

macOS Mac mini 上运行的 AI agent 沙箱环境，通过 Docker 容器隔离 + 宿主机 ops-watcher 监控实现安全自治。

## 分支地图（主链条）

```
main                                    仓库初始态，远远落后
  └── ops-watcher-step-b-hotfix  ★     当前生产分支（Step A → B.3 全部在此）
```

其他分支是演化过程中的历史快照，保留作考古证据：
- `ops-watcher` — Phase 1 ~ Step A.1
- `ops-watcher-step-b` — B.2 沙箱稿
- `ops-watcher-step-b-hotfix-auth-result-invariant` — B.3 split-brain 修复期间的工作分支

## 核心架构

```
┌─────────────────────────────────────────────────┐
│  宿主机 (macOS)                                  │
│                                                  │
│  ops-watcher.sh ──→ 静态审查 proposal            │
│       │              14 道闸门 → accept/block     │
│       │              Telegram 4 档通知            │
│       ▼                                          │
│  ops_spool/       ← 审计流 (events.jsonl)        │
│  ops-results/     ← 权威裁决 (id.json)           │
│  snapshot/        ← 配置基线 (watcher 产物)       │
│                                                  │
├──────────────────────────────────────────────────┤
│  Docker Compose (6 services)                     │
│  agent / squid / litellm / collector /           │
│  notifier / cliproxyapi                          │
│                                                  │
│  agent: read_only, cap_drop ALL,                 │
│         no-new-privileges, pids_limit 256        │
│         唯一可写: agent_workspace/ (:rw)          │
│         snapshot: :ro 挂载                        │
└─────────────────────────────────────────────────┘
```

## 关键文档

| 文件 | 用途 |
|------|------|
| `OPS-WATCHER-DESIGN.md` | 完整设计文档（v1→v2 演进 + 各 Phase checkpoint） |
| `HANDOFF-OPS-WATCHER.md` | 交接文档（追加式，含所有 checkpoint + 教训） |
| `scripts/ops/README.md` | 状态流图 + 命名规则 + 验证步骤 |
| `DOCKER-DEVELOPMENT-LOG.md` | 端到端开发日志 |
| `DOCKER-USAGE-MANUAL.md` | Docker 环境使用手册 |

## 当前进度（2026-05-17）

**Step B 核心能力面已完成：**
- ✅ 闸门链 14 道静态检查
- ✅ 通知矩阵 4/4（LOW/MEDIUM/HIGH/BLOCK）
- ✅ Lifecycle 4/4（started/disabled/resumed/stopped）
- ✅ Authoritative Result Invariant（守序契约）
- ✅ Heartbeat 端到端存活信号

**收口面待完成：**
- [ ] B.3 失败路径测试（证明通知失败也守约）
- [ ] B.4 launchd 常驻运行设计

**后续 Phase：**
- Phase 4: apply-proposal（从"审"到"改变现实"）
- Phase 5+: 自动化验证 + agent 自主触发

## 安全审计状态

| 层级 | 状态 |
|------|------|
| 第一层：容器内逃逸 | ✅ 全部通过 |
| 第二层：宿主机暴露面 + Docker daemon | ✅ 18 PASS / 21 WARN(接受) / 0 FAIL |
| Ops-watcher 不变量 | ✅ baseline invariant + BLOCK path + 守序契约 |

Zero-Trust local AI sandbox: Claude Code agent + Squid egress proxy + LiteLLM
+ audit collector + Telegram notifier + ops-watcher.

## Repository layout (Dockerfile identity guide)

```
kiro-projiects/
├── Dockerfile                ← AGENT image     (node:20-slim + claude-code)
├── docker-compose.yml
│
├── notifier/
│   ├── Dockerfile            ← NOTIFIER image  (python + telegram)
│   └── notifier.py
│
├── collector/
│   ├── Dockerfile            ← COLLECTOR image (python + audit ingest)
│   └── collector.py
│
├── proxy/
│   ├── squid.conf
│   └── allowed_domains.txt
│
├── config/
│   └── litellm_config.yaml
│
└── scripts/
    ├── search-helper.py      ← copied into agent image at /usr/local/bin/search-helper
    └── ops/                  ← ops-watcher (host-side proposal review pipeline)
        ├── init-snapshot.sh
        ├── ops-helper.sh
        ├── ops-watcher.sh
        ├── ops-baseline.json
        ├── MIGRATION-SOP.md  ← B.1 snapshot relocation playbook
        └── README.md
```

Each Dockerfile carries a banner comment naming the service it builds, so
agents (and humans) cannot confuse them when grepping the tree.

## Host-side runtime layout

The repository is the build source. At runtime the production host adds two
peer directories that are not git-tracked here:

```
~/ai_sandbox/                      (production host root)
├── kiro-projiects/                ← this repo
├── snapshot/                      ← watcher product (B.1+); read-only mount source for agent
└── agent_workspace/               ← agent rw mount source; independent git repo
```

Agent container view is unchanged across this layout: `/app/workspace`
(rw, from `agent_workspace/`) with `/app/workspace/.snapshot` (ro, from
`snapshot/`) nested inside it.

## docker-compose service → Dockerfile mapping

| Service     | build.context | Dockerfile path        |
|-------------|---------------|------------------------|
| agent       | `.`           | `./Dockerfile`         |
| notifier    | `./notifier`  | `./notifier/Dockerfile`|
| collector   | `./collector` | `./collector/Dockerfile`|
| squid       | (image)       | `ubuntu/squid` upstream|
| litellm     | (image)       | `ghcr.io/berriai/litellm:main-latest` |
| cliproxyapi | (image)       | `eceasy/cli-proxy-api:latest` |

## Ops-watcher

Host-side static review of agent-submitted change proposals.
See `scripts/ops/README.md` and `OPS-WATCHER-DESIGN.md`.

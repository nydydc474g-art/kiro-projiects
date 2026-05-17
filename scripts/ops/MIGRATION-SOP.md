# MIGRATION SOP — snapshot 物理位置从 agent_workspace/.snapshot 迁出到项目根

> 适用范围：从 B.0 之前的部署形态升级到 B.1。
> 一次性操作，迁完后此文档保留作历史档案 + 紧急回退说明。

## 目标形态

```
迁移前                                          迁移后
───────────────────────────────────────────────────────────────────────
~/ai_sandbox/                                   ~/ai_sandbox/
├── agent_workspace/                            ├── snapshot/                  ← 新位置（watcher 产物）
│   ├── .snapshot/      ← snapshot 在这         │   ├── versions/<id>/
│   │   ├── versions/<id>/                      │   ├── current -> versions/<id>
│   │   ├── current -> versions/<id>            │   ├── .snapshot-id
│   │   ├── .snapshot-id                        │   └── .snapshot-hash
│   │   └── .snapshot-hash                      │
│   ├── ops-proposals/                          ├── agent_workspace/          ← 不动（仍 rw）
│   ├── ops-requests/                           │   ├── ops-proposals/
│   └── ops-results/                            │   ├── ops-requests/
                                                │   └── ops-results/

容器内挂载                                       容器内挂载
- ./agent_workspace:/app/workspace:rw           - ./agent_workspace:/app/workspace:rw
                                                - ./snapshot:/app/workspace/.snapshot:ro
```

容器内 agent 视角不变：仍是 `/app/workspace/.snapshot/...`。

## 选择 Plan C 的理由

不选 A（清空 pending → init 新位置）：粗暴，丢上下文。
不选 B（直接 init 让旧 proposal stale）：把"目录搬家"和"事实版本前进"混作一个动作。
选 C：**先把现有 snapshot 原样 mv**，保留 versions/current/symlink/.snapshot-id/.snapshot-hash 全部不变，
mv 后用三铆钉对账校验"身份没变"，挂载 ro 触摸测试通过，smoke test 用旧 snapshot id 跑一次 proposal 通过，
最后才决定是否 refresh 进入新世代。

把"目录搬家"和"事实版本前进"拆成两个独立动作 → 事后 events.jsonl 可还原叙事。

---

## 操作前提

- 你已经把 git 上 `ops-watcher-step-b` 分支的代码同步到了生产机
  （compose、Dockerfile、init-snapshot.sh、ops-watcher.sh、ops-helper.sh、ops-baseline.json 都是新版本）
- 确认 watcher **没在主循环跑**（迁移期间不要让它处理新请求）
- 一个干净 shell（bash 5+ 或 macOS 系统 bash 3.2 都可）

---

## Step 0 — 抓现场指纹（事后审计用）

```bash
cd ~/ai_sandbox

# Docker 后端（写进 events.jsonl 用）
docker info 2>&1 | grep -iE 'storage driver|firewall backend|server version'
docker version --format '{{.Server.Version}}'

# 旧位置当前身份
OLD_SNAPSHOT=~/ai_sandbox/agent_workspace/.snapshot
OLD_ID=$(cat "$OLD_SNAPSHOT/.snapshot-id")
OLD_HASH=$(cat "$OLD_SNAPSHOT/.snapshot-hash")
OLD_CURRENT=$(readlink "$OLD_SNAPSHOT/current")

echo "OLD_ID=$OLD_ID"
echo "OLD_HASH=$OLD_HASH"
echo "OLD_CURRENT=$OLD_CURRENT"

# pending 数（若非零，需先决定如何处理）
ls "$OLD_SNAPSHOT/../ops-proposals/"*/manifest.json 2>/dev/null | wc -l
ls "$OLD_SNAPSHOT/../ops-requests/"*.json 2>/dev/null | wc -l
```

Pending 非零的处理选择：
- **优先**：先 `bash scripts/ops/ops-watcher.sh --process-all` 排空，再迁移
- 强制迁移：旧 proposal 在新世代上仍能正确判 stale（现行 base_snapshot_id 在新位置依然有效，因为 Plan C 保留了 id）

---

## Step 1 — mv（保留身份）

```bash
cd ~/ai_sandbox

# 物理整体搬迁，保留所有内部 symlink / metadata / versions/ 子目录
mv agent_workspace/.snapshot snapshot
```

注意：
- 这是**整目录 rename**（同一文件系统），inode 不变，相对 symlink `current → versions/<id>` **仍然有效**（相对路径解析在新父目录下还是同样指向 versions/<id>）
- `.snapshot-id` / `.snapshot-hash` 顶层指针文件随之搬走，未被改写

---

## Step 2 — 身份对账三铆钉

```bash
NEW_SNAPSHOT=~/ai_sandbox/snapshot

NEW_ID=$(cat "$NEW_SNAPSHOT/.snapshot-id")
NEW_HASH=$(cat "$NEW_SNAPSHOT/.snapshot-hash")
NEW_CURRENT=$(readlink "$NEW_SNAPSHOT/current")

if [ "$OLD_ID" = "$NEW_ID" ] \
   && [ "$OLD_HASH" = "$NEW_HASH" ] \
   && [ "$OLD_CURRENT" = "$NEW_CURRENT" ]; then
  echo "OK: identity preserved across mv"
  echo "    id      = $NEW_ID"
  echo "    hash    = $NEW_HASH"
  echo "    current = $NEW_CURRENT"
else
  echo "FATAL: identity drift across migration"
  echo "  OLD: id=$OLD_ID hash=$OLD_HASH current=$OLD_CURRENT"
  echo "  NEW: id=$NEW_ID hash=$NEW_HASH current=$NEW_CURRENT"
  echo "  → mv 旧位置回去：mv snapshot agent_workspace/.snapshot"
  exit 1
fi

# 还要确认 current 指向的目录里 inner metadata 也相符（双向校验）
INNER_ID=$(cat "$NEW_SNAPSHOT/current/.snapshot-id")
INNER_HASH=$(cat "$NEW_SNAPSHOT/current/.snapshot-hash")
[ "$INNER_ID" = "$NEW_ID" ] && [ "$INNER_HASH" = "$NEW_HASH" ] \
  && echo "OK: bidirectional check (top vs versions/<id> inner) passes" \
  || { echo "FATAL: inner metadata drift"; exit 1; }
```

预期：两段都打印 OK。任何一处 FATAL 都要立刻回退（`mv snapshot agent_workspace/.snapshot`）然后定位。

---

## Step 3 — 重启 agent 容器，让新挂载生效

```bash
docker compose up -d agent
```

注意：compose 文件这次也变了（agent.volumes 多了一行），所以即使 agent 已经在跑，
`up -d` 会因为 volumes 配置变化重建容器。

---

## Step 4 — 只读触摸测试（嵌套 :ro 的实测验证）

这是 B 方案最关键的一次实测——嵌套 :ro 在 macOS Docker Desktop 上是否真的生效。

```bash
docker exec agent ls -la /app/workspace/.snapshot/.snapshot-id
docker exec agent cat /app/workspace/.snapshot/.snapshot-id
# 期望：能读到，输出 = $NEW_ID

docker exec agent touch /app/workspace/.snapshot/x 2>&1
# 期望：touch: cannot touch '/app/workspace/.snapshot/x': Read-only file system

docker exec agent rm /app/workspace/.snapshot/.snapshot-id 2>&1
# 期望：rm: cannot remove '/app/workspace/.snapshot/.snapshot-id': Read-only file system

docker exec agent sh -c 'echo x > /app/workspace/.snapshot/.snapshot-id' 2>&1
# 期望：sh: 1: cannot create /app/workspace/.snapshot/.snapshot-id: Read-only file system
```

如果 4 条都符合预期 → **方案 B 在你的 Docker Desktop 上实测成立**，继续。
任何一条返回成功（即可写）→ **立刻切 fallback 方案 B'**（见文末），不要继续。

---

## Step 5 — Smoke test（用旧 snapshot id 跑一次 proposal）

这一步**故意**在 refresh 之前跑一次 proposal——证明"迁移本身"独立于"事实版本前进"。
如果这步出问题，是路径相关；不是 hash 漂移、不是 watcher 状态机重入、不是新内容缺什么。

```bash
docker exec agent ops-propose new "smoke test post-migration"
# 期望：返回 proposal id，类似 20260517-XXXXXX-abc123
# 进 proposal 目录写一个无害候选文件，complete 流程，submit
```

完整流程参考 `scripts/ops/README.md` 的"验证步骤"段。
关键：watcher 处理这次 proposal 时**不应该判 stale**（因为 OLD_ID = NEW_ID）。
如果判 stale，说明 Plan C 的"保留身份"承诺被打破，需要立刻定位。

---

## Step 6 — Refresh（独立动作，独立时点）

到这一步，"目录搬家"已经被证明不影响系统行为。
现在才是"决定让事实版本前进"的时点：

```bash
bash scripts/ops/init-snapshot.sh
```

之后 `cat ~/ai_sandbox/snapshot/.snapshot-id` 应显示新的 timestamp id，
旧 OLD_ID 仍保留在 versions/ 下（B.1 暂不 prune）。

注意：refresh 之后所有 base_snapshot_id = OLD_ID 的 pending proposal **正常会判 stale**——
这是预期行为，agent 应以新 snapshot 重做。

---

## Step 7 — Cleanup

```bash
# 防御：以后谁误把 init-snapshot 的 SNAPSHOT_DIR 写回旧位置时，
# 至少 agent_workspace 的 git 不会显示一堆未跟踪
echo ".snapshot/" >> ~/ai_sandbox/agent_workspace/.gitignore

# 启动 watcher 主循环
bash scripts/ops/ops-watcher.sh
# 或：launchctl load ~/Library/LaunchAgents/com.caimin.ops-watcher.plist  (B.4 后)
```

---

## 紧急回退（任意 Step 失败）

```bash
# 回到 B.0 时的形态
docker compose stop agent
mv ~/ai_sandbox/snapshot ~/ai_sandbox/agent_workspace/.snapshot

# 回滚 compose 改动：删掉 agent.volumes 里 ./snapshot 这行
# 回滚 baseline 改动：删掉 agent_volumes_required 里 ./snapshot:/app/workspace/.snapshot:ro 这行
# 然后：
docker compose up -d agent
```

回退后 watcher / helper / Dockerfile 的改动**不需要回滚**——它们都向后兼容（脚本默认值改成新位置，但 OPS_SNAPSHOT_DIR / OPS_SNAPSHOT 环境变量可指向旧位置；agent Dockerfile 多了一个命令但旧 .snapshot 挂载它能正常工作）。

---

## Fallback 方案 B'（仅当 Step 4 ro 触摸测试失败时启用）

嵌套 :ro 在你的 Docker Desktop 上不生效 → 容器内 .snapshot 路径必须独立。
改动只有两处：

1. `docker-compose.yml`：
   ```yaml
   - ./snapshot:/app/snapshot:ro      # 改为非嵌套
   ```

2. `ops-helper.sh` 顶层默认值：
   ```bash
   SNAPSHOT="${OPS_SNAPSHOT:-/app/snapshot}"   # 容器内默认改 /app/snapshot
   ```

3. `ops-baseline.json` agent_volumes_required 同步改成 `./snapshot:/app/snapshot:ro`

4. 文档同步（OPS-WATCHER-DESIGN.md / scripts/ops/README.md / 本文档）

`init-snapshot.sh` / `ops-watcher.sh` 不动（它们是宿主机进程，看的是 `~/ai_sandbox/snapshot`）。
agent 容器内心智模型变了——但只有一行 default 值改动，仍然在 escape hatch 之内。

---

## 完成标记

迁移成功后，把以下信息追加到 `HANDOFF-OPS-WATCHER.md` 末尾的"B.1 完成"checkpoint：

```
- 迁移日期：YYYY-MM-DD
- Docker server version：X.Y.Z
- Storage driver：overlayfs / vfs / ...
- Firewall backend：iptables / nftables
- 嵌套 :ro 是否实测成立：是 / 否（若否，使用 B' fallback）
- OLD_ID / NEW_ID（应相等）：__________
- Smoke test proposal id：__________
- Refresh 后新 snapshot id：__________
```

留给将来 Docker Desktop 升级出问题时定位用。

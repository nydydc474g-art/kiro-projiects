# Ops Watcher 脚本目录

> 实施进度：**Phase 1.2 完成（proposal 协议骨架硬化 + 8 项实测发现修复）**

## 文件清单

| 文件 | 阶段 | 作用 |
|------|------|------|
| `init-snapshot.sh` | Phase 1.2 ✅ | 宿主机生成/刷新 `.snapshot/`，versions/current 结构，7 步定序 |
| `ops-helper.sh` | Phase 1.2 ✅ | agent 容器内 proposal 助手 |
| `verifications/` | Phase 5 ⏳ | 命名检查项目录（待补） |
| `ops-watcher.sh` | Phase 2 ⏳ | watcher 主循环（待补） |
| `apply-proposal.sh` | Phase 4 ⏳ | apply/rollback 脚本（待补） |
| `ops-baseline.json` | Phase 2 ⏳ | compose 安全字段基线（待补） |

## 核心概念

### SNAPSHOT_INCLUDED vs PROPOSAL_PATH_ALLOWED

| 维度 | 含义 |
|------|------|
| **SNAPSHOT_INCLUDED** | agent 通过 `.snapshot/current/` 可读的"生产现状" |
| **PROPOSAL_PATH_ALLOWED** | manifest.changes[].path 允许的白名单 |

**两者不重叠的部分 = "只读知情，不可提案改动"**。

例：`claude_config/` 在 SNAPSHOT_INCLUDED（agent 看得到当前防线）但不在 PROPOSAL_PATH_ALLOWED（无法提案改动），helper 的 `add` 直接拒绝（前端防脏），watcher 仍保留 BLOCK 检测（后端不信任前端，纵深冗余）。

### .snapshot/ 目录结构（Phase 1.2）

```
.snapshot/                          ← 稳定挂载点（compose bind mount 不动）
  versions/
    <snapshot-id-1>/
      .snapshot-id
      .snapshot-hash
      docker-compose.yml
      ...
    <snapshot-id-2>/
      ...
  current -> versions/<id>          ← 相对 symlink（整目录搬走仍自洽）
  .snapshot-id                       ← 顶层指针，agent helper 直接读
  .snapshot-hash                     ← 顶层指针
```

设计要点：
- bind mount 绑定 `.snapshot/` 根目录的 inode，永不替换
- refresh 时只切换 `current` symlink + 顶层 metadata 文件
- `current` 用相对路径，整 `.snapshot/` 复制/搬走仍自洽
- 顶层 `.snapshot-id` 等价于 `cat current/.snapshot-id`，方便快速读取
- watcher 双向校验：顶层值 == versions/current 内值，不一致 → WARN（识别外部篡改）

### Refresh 7 步定序

```
1. 构建 versions/<new-id>.staging/
2. 写入 .snapshot-id / .snapshot-hash 到 staging 内
3. mv staging → versions/<new-id>           (原子)
4. ln -sfn "versions/<new-id>" current.new  (相对路径)
5. mv current.new current                    (原子切换)
6. 顶层 metadata 原子写：
   - 写 .snapshot-id.new + mv → .snapshot-id
   - 写 .snapshot-hash.new + mv → .snapshot-hash
7. 双向校验，不一致输出 WARN（不回滚，让下次校验抓住）
```

第 6 步失败时，第 7 步会输出 WARN——**这是设计意图**，把不一致暴露出来，不静默掩盖。

### versions/ 保留策略

- Phase 1.2：**不自动 prune**（避免一期 bug）
- Phase 2+：watcher 根据保留窗口清理（默认保留最近 N 个）

## Phase 1.2 已落实的安全细节

### Manifest 完整性
- jq -n 生成初始 manifest（无引号注入）
- 原子更新：mktemp 在 proposal 目录内 + mv + trap 清理
- add 去重 by path
- add 计算并写入 sha256（铆钉 manifest 描述与候选文件）
- **add 拒绝 symlink + realpath 必须仍在 proposal 目录内**（Phase 1.2 新增）
- validate 检测 sha256 漂移（add 后又改文件会被发现）
- validate 顺手清理陈旧 `.manifest.*`

### Submit 严格校验
- `jq empty` 验合法 JSON
- `base_snapshot_id != "unknown"`
- **`base_snapshot_hash` 必填非空**（Phase 1.2 新增）
- `reason` 非空
- `expected_effect` 非空
- `affected_services` 非空且元素均在白名单
- **`verification` 非空**（Phase 1.2 新增）
- `changes` 非空，每个 path 在白名单内且文件存在
- **全部 changes 都是 no-op vs snapshot 时拒绝**（Phase 1.2 新增）

### 路径白名单（Phase 1.2 收窄）

只允许以下具体文件：
- `docker-compose.yml`
- `Dockerfile`
- `proxy/squid.conf`
- `proxy/allowed_domains.txt`
- `collector/collector.py`
- `collector/Dockerfile`
- `notifier/notifier.py`
- `notifier/Dockerfile`
- `config/litellm_config.yaml`
- `scripts/ops/verifications/<name>.sh`

新增文件（如 `collector/new_helper.py`）一期不允许。Phase 2 风险分级会把"add new code file"自动升 MEDIUM/HIGH 作为扩展点。

### Snapshot 强化
- versions/current 相对 symlink 结构
- 7 步原子定序
- 双向校验输出
- `.snapshot-hash`：内容哈希（排除 .snapshot-id 自身）
  - id 变 + hash 不变 = 无变更重刷
  - id 不变 + hash 变 = 外部篡改告警
  - id 变 + hash 变 = 正常变更
- rsync fallback 到 cp + find（macOS 默认有 rsync，sandbox 兼容）
- **proposal id 含 6 位真随机 hex 后缀**（Phase 1.2 修了 SIGPIPE bug）
- 严格白名单：永远不含 .env / .git / auths / *.log / __pycache__

### 命令体验
- 独立 `validate` 命令（与 submit 解耦，便于反复迭代）
- `clean` 命令（仅清理 24h 前的纯空白 draft，不动半成品）
- usage 列出所有命令含 set-effect / validate / clean

### Result 不可变性（Phase 4 watcher 落地时实现）
- 首次 result 写入即闭合，永不修改
- 后续状态走 sibling：`<id>.rollback.json` / `<id>.healthcheck-failed.json` 等

## 验证步骤

### 宿主机：生成首个 snapshot

```bash
cd ~/ai_sandbox
bash scripts/ops/init-snapshot.sh
ls -la agent_workspace/.snapshot/
cat agent_workspace/.snapshot/.snapshot-id
cat agent_workspace/.snapshot/.snapshot-hash
readlink agent_workspace/.snapshot/current
ls agent_workspace/.snapshot/versions/
```

预期：

```
drwx... versions
lrwx... current -> versions/20260517T...
-rw-... .snapshot-id
-rw-... .snapshot-hash

20260517T...
<64 hex>
versions/20260517T...
20260517T...
```

### 敏感性检查

```bash
[ ! -f agent_workspace/.snapshot/current/.env ] && echo "OK"
[ ! -d agent_workspace/.snapshot/current/.git ] && echo "OK"
[ ! -d agent_workspace/.snapshot/current/audit_spool ] && echo "OK"
[ ! -d agent_workspace/.snapshot/current/cliproxyapi ] && echo "OK"
find agent_workspace/.snapshot -name '*.log' -o -name 'auths'   # 应为空
```

### 测试 helper 完整流程

需要 `WORKSPACE` 指向有 `.snapshot/` 的目录：

```bash
export WORKSPACE=/tmp/ops-test
mkdir -p $WORKSPACE
cp -r ~/ai_sandbox/agent_workspace/.snapshot $WORKSPACE/

# 完整流程
ID=$(bash ~/ai_sandbox/scripts/ops/ops-helper.sh new "test add tavily")
mkdir -p $WORKSPACE/ops-proposals/$ID/proxy
cp $WORKSPACE/.snapshot/current/proxy/allowed_domains.txt $WORKSPACE/ops-proposals/$ID/proxy/
echo "api.tavily.com" >> $WORKSPACE/ops-proposals/$ID/proxy/allowed_domains.txt

bash ~/ai_sandbox/scripts/ops/ops-helper.sh add $ID proxy/allowed_domains.txt
bash ~/ai_sandbox/scripts/ops/ops-helper.sh set-effect $ID "agent reaches tavily"
bash ~/ai_sandbox/scripts/ops/ops-helper.sh set-affected $ID squid
bash ~/ai_sandbox/scripts/ops/ops-helper.sh set-verification $ID squid_denies_example_org
bash ~/ai_sandbox/scripts/ops/ops-helper.sh validate $ID
bash ~/ai_sandbox/scripts/ops/ops-helper.sh submit $ID

rm -rf $WORKSPACE
```

### 负向测试（同一个 proposal，依次试）

```bash
export WORKSPACE=/tmp/ops-neg
mkdir -p $WORKSPACE
cp -r ~/ai_sandbox/agent_workspace/.snapshot $WORKSPACE/
ID=$(bash ~/ai_sandbox/scripts/ops/ops-helper.sh new "neg test")

# 1. claude_config 路径被拒
mkdir -p $WORKSPACE/ops-proposals/$ID/claude_config/hooks
echo "evil" > $WORKSPACE/ops-proposals/$ID/claude_config/hooks/guard.sh
bash ~/ai_sandbox/scripts/ops/ops-helper.sh add $ID claude_config/hooks/guard.sh
# Expected: ERROR ... NOT in PROPOSAL_PATH_ALLOWED

# 2. symlink 被拒
mkdir -p $WORKSPACE/ops-proposals/$ID/proxy
ln -sf /etc/passwd $WORKSPACE/ops-proposals/$ID/proxy/allowed_domains.txt
bash ~/ai_sandbox/scripts/ops/ops-helper.sh add $ID proxy/allowed_domains.txt
# Expected: ERROR ... is a symlink

# 3. 新文件名被拒（白名单收窄）
mkdir -p $WORKSPACE/ops-proposals/$ID/collector
echo "" > $WORKSPACE/ops-proposals/$ID/collector/random_helper.py
bash ~/ai_sandbox/scripts/ops/ops-helper.sh add $ID collector/random_helper.py
# Expected: ERROR ... NOT in PROPOSAL_PATH_ALLOWED

# 4. submit 缺 verification
rm -f $WORKSPACE/ops-proposals/$ID/proxy/allowed_domains.txt
echo "api.test" > $WORKSPACE/ops-proposals/$ID/proxy/allowed_domains.txt
bash ~/ai_sandbox/scripts/ops/ops-helper.sh add $ID proxy/allowed_domains.txt
bash ~/ai_sandbox/scripts/ops/ops-helper.sh set-effect $ID "test"
bash ~/ai_sandbox/scripts/ops/ops-helper.sh set-affected $ID squid
bash ~/ai_sandbox/scripts/ops/ops-helper.sh submit $ID
# Expected: FAIL: verification is empty

rm -rf $WORKSPACE
```

## 设计参考

详见仓库根目录 `OPS-WATCHER-DESIGN.md`：
- v1 → v2 演进史
- Phase 1.1 实测 checkpoint
- Phase 1.2 实施细节（本文档对应章节）

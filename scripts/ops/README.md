# Ops Watcher 脚本目录

> 实施进度：**Phase 1.1 完成（proposal 协议骨架硬化）**

## 文件清单

| 文件 | 阶段 | 作用 |
|------|------|------|
| `init-snapshot.sh` | Phase 1.1 ✅ | 宿主机生成/刷新 `.snapshot/` 只读快照（含 .snapshot-id + .snapshot-hash） |
| `ops-helper.sh` | Phase 1.1 ✅ | agent 容器内 proposal 助手（new/add/set-*/validate/submit/result/list/clean） |
| `verifications/` | Phase 5 ⏳ | 命名检查项目录（待补） |
| `ops-watcher.sh` | Phase 2 ⏳ | watcher 主循环（待补） |
| `apply-proposal.sh` | Phase 4 ⏳ | apply/rollback 脚本（待补） |
| `ops-baseline.json` | Phase 2 ⏳ | compose 安全字段基线（待补） |

## 关键概念：SNAPSHOT_INCLUDED vs PROPOSAL_PATH_ALLOWED

这是整套系统的核心概念区分：

| 维度 | 含义 |
|------|------|
| **SNAPSHOT_INCLUDED** | agent 通过 `.snapshot/` 可读的"生产现状" |
| **PROPOSAL_PATH_ALLOWED** | manifest.changes[].path 允许的白名单 |

**两者不重叠的部分 = "只读知情，不可提案改动"**。

例如 `claude_config/`：
- ✅ 在 SNAPSHOT_INCLUDED：agent 能看到当前 guard.sh / audit.sh / settings.json，理解防线现状
- ❌ 不在 PROPOSAL_PATH_ALLOWED：agent 无法提案改动这些文件
- helper 的 `add` 命令直接拒绝（前端防脏）
- watcher 仍保留 BLOCK 检测（后端不信任前端，纵深冗余）

`SNAPSHOT_INCLUDED` 在 `init-snapshot.sh` 的 `INCLUDE_PATHS`。
`PROPOSAL_PATH_ALLOWED` 在 `ops-helper.sh` 的 `PATH_ALLOW_REGEX`。

## Phase 1.1 已落实的安全细节

### Manifest 完整性
- jq -n 生成初始 manifest（无引号注入）
- 原子更新：mktemp 在 proposal 目录内 + mv + trap 清理
- add 去重 by path
- add 计算并写入 sha256（铆钉 manifest 描述与候选文件）
- validate 检测 sha256 漂移（add 后又改文件会被发现）
- validate 顺手清理陈旧 `.manifest.*`

### Submit 严格校验
- `jq empty` 验合法 JSON
- `base_snapshot_id != "unknown"`
- `reason` 非空
- `expected_effect` 非空
- `affected_services` 非空且元素均在白名单
- `changes` 非空，每个 path 在白名单内且文件存在

### 命令体验
- 独立 `validate` 命令（与 submit 解耦，便于反复迭代）
- `clean` 命令（仅清理 24h 前的纯空白 draft，不动半成品）
- usage 列出所有命令，含 set-effect / validate / clean

### Snapshot 强化
- 原子刷新：mktemp 临时目录 + mv 替换
- `.snapshot-id`：UTC 时间戳
- `.snapshot-hash`：内容 sha256（防同秒重刷/手工改动）
- 严格白名单：永远不含 .env / .git / auths / *.log / __pycache__

### Result 不可变性（Phase 4 watcher 落地）
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
```

**预期**：

```
docker-compose.yml  Dockerfile  proxy/  collector/  notifier/  config/  claude_config/  scripts/  .snapshot-id  .snapshot-hash
20260517T143015Z
<64 hex chars>
```

**敏感性检查**：

```bash
ls agent_workspace/.snapshot/.env       # 应该: No such file
ls agent_workspace/.snapshot/.git       # 应该: No such file
ls agent_workspace/.snapshot/audit_spool 2>/dev/null   # 应该: No such file or directory
find agent_workspace/.snapshot -name 'auths' -o -name '*.log' 2>/dev/null   # 应该: 空
```

### agent 内：练习 proposal 流程（dry run）

注意：Phase 1.1 完成后，需要 compose 中加挂载（Phase 2 任务）才能让 agent 真正读到 .snapshot。
此处可以先用宿主机或临时容器手动测试 ops-helper.sh 的逻辑。

```bash
# 模拟环境（在 sandbox 容器外测试）
export WORKSPACE=/tmp/ops-test
mkdir -p $WORKSPACE/.snapshot
echo "20260517T143015Z" > $WORKSPACE/.snapshot/.snapshot-id

# 测试流程
ID=$(bash scripts/ops/ops-helper.sh new "test reason")
echo "Created: $ID"

# 创建一个候选文件
mkdir -p $WORKSPACE/ops-proposals/$ID/proxy
echo ".example.com" > $WORKSPACE/ops-proposals/$ID/proxy/allowed_domains.txt

bash scripts/ops/ops-helper.sh add $ID proxy/allowed_domains.txt
bash scripts/ops/ops-helper.sh set-effect $ID "agent can reach example.com"
bash scripts/ops/ops-helper.sh set-affected $ID squid
bash scripts/ops/ops-helper.sh set-verification $ID squid_denies_example_org

# Validate
bash scripts/ops/ops-helper.sh validate $ID

# Submit
bash scripts/ops/ops-helper.sh submit $ID

# 查看 manifest
bash scripts/ops/ops-helper.sh manifest $ID

# Clean up
rm -rf $WORKSPACE
```

### 负向测试

```bash
# 1. helper 拒绝写入 claude_config
mkdir -p $WORKSPACE/ops-proposals/test-block/claude_config/hooks
echo "evil" > $WORKSPACE/ops-proposals/test-block/claude_config/hooks/guard.sh
bash scripts/ops/ops-helper.sh new "block test" >/dev/null
# 此处 add 应该失败，提示路径不在 PROPOSAL_PATH_ALLOWED

# 2. submit 拒绝缺字段
bash scripts/ops/ops-helper.sh new "field test"  # 不补 expected_effect/affected_services/changes
# submit 应该报多个 FAIL

# 3. submit 拒绝 unknown snapshot
# 删除 .snapshot/.snapshot-id 后 new 出来的 proposal，submit 应失败

# 4. sha256 漂移检测
# add 后修改文件，validate 应该报 WARN
```

## 设计参考

详见仓库根目录 `OPS-WATCHER-DESIGN.md` v2 终稿与 Phase 1 checkpoint。

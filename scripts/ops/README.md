# Ops Watcher 脚本目录

> 实施进度：Phase 1 完成（proposal 协议骨架）

## 文件清单

| 文件 | 阶段 | 作用 |
|------|------|------|
| `init-snapshot.sh` | Phase 1 | 初始化/刷新 `.snapshot/` 只读快照（宿主机执行） |
| `ops-helper.sh` | Phase 1 | agent 容器内 proposal 助手（容器内执行） |
| `verifications/` | Phase 5 | 命名检查项目录（待补） |
| `ops-watcher.sh` | Phase 2 | watcher 主循环（待补） |
| `apply-proposal.sh` | Phase 4 | apply/rollback 脚本（待补） |
| `ops-baseline.json` | Phase 2 | compose 安全字段基线（待补） |

## Phase 1 验证步骤

### 宿主机：生成首个 snapshot

```bash
cd ~/ai_sandbox
bash scripts/ops/init-snapshot.sh
ls agent_workspace/.snapshot/
cat agent_workspace/.snapshot/.snapshot-id
```

预期：

```
docker-compose.yml  Dockerfile  proxy/  collector/  notifier/  config/  claude_config/  .snapshot-id
20260517T143015Z
```

注意 `.snapshot/` 内**不应包含** `.env`, `audit_spool`, `.git`, `cliproxyapi/auths`。

### compose 挂载（需后续 Phase 1 任务）

agent 服务需新增挂载：

```yaml
volumes:
  - ./agent_workspace/.snapshot:/app/workspace/.snapshot:ro
```

Phase 1 暂不修改 compose，等 Phase 2 watcher 写好后一起改。

### agent 内：练习 proposal 流程（dry run）

```bash
docker exec -it agent bash

# 在容器内
ID=$(ops-propose new "test proposal")
echo "Created: $ID"

# 模拟修改一个文件
cat > /app/workspace/ops-proposals/$ID/proxy/allowed_domains.txt <<'EOF'
# (假设这是新版本)
.example.com
EOF

ops-propose add $ID proxy/allowed_domains.txt
ops-propose set-affected $ID squid
ops-propose set-effect $ID "agent can reach example.com"
ops-propose manifest $ID
ops-propose submit $ID
ops-propose list
```

注：Phase 1 没有 watcher，submit 后请求会留在 ops-requests/，无人处理。Phase 2 完成后才会真正进入审批流。

## 设计参考

详见 `OPS-WATCHER-DESIGN.md` v2 终稿。

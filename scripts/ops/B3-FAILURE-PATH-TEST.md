# B.3 失败路径测试 SOP

> **目的**：验证"发不出去时不伪装成已发"——通知失败后 `.notified.txt` 不被污染，
> 且 watcher 恢复正常网络后的 polling tick 不会补发已处理的 proposal。

## 前置条件

- watcher 在前台 polling 跑着（如已停，先 `bash scripts/ops/ops-watcher.sh` 重启）
- `.ops-watcher.env` 当前 `TELEGRAM_PROXY_URL=http://127.0.0.1:1082`，SR 在 1082 端口
- 至少已完成 B.3 BLOCK 档测试（`.notified.txt` 至少有 4 行）

## 测试设计原理

```
                              finalize_proposal()
                                    │
                    ┌───────────────┴───────────────┐
                    │                               │
              write_result()                  notify_proposal()
              consume_request()                     │
              archive_proposal()            send_telegram_raw()
                    │                         return 1 (http_code=000)
                    │                               │
                    │                       write_event ERROR
                    │                       .notified.txt 不写
                    ▼                               ▼
            request 已从队列移除            通知状态 = 未发送
```

验证的两条不变量：

1. **「发不出不伪装」**：send_telegram_raw 返回 1 → notify_proposal 不追加 .notified.txt
2. **「恢复后不补发」**：request 已被 consume_request 移到 .processed/ → 主循环
   list_pending_requests 再也扫不到 → 即使 .notified.txt 没有这条记录，也不会触发重发

## 操作步骤（宿主机，新终端）

### Phase 1：制造网络故障

```bash
setopt interactive_comments 2>/dev/null || true

SANDBOX=/Users/caimin/ai_sandbox
ENV_FILE="$SANDBOX/.ops-watcher.env"

# 记录当前 .notified.txt 行数（断网前快照）
echo "=== BEFORE: .notified.txt ==="
wc -l "$SANDBOX/ops_spool/.notified.txt"
cat "$SANDBOX/ops_spool/.notified.txt"

# 把代理端口改成一个不存在的端口（模拟 SR 关闭）
# 注意：不用真关 SR（会影响宿主机其他流量），改端口足够精确
sed -i '' 's|^TELEGRAM_PROXY_URL=.*|TELEGRAM_PROXY_URL=http://127.0.0.1:19999|' "$ENV_FILE"
cat "$ENV_FILE"
echo "--- proxy port changed to 19999 (dead port) ---"
```

**关键**：改 env 文件后**不用重启 watcher**。但 watcher 的 `load_telegram_env`
只在启动时读一次 env 文件。所以需要**重启 watcher 让它读到假端口**。

```bash
# 在 watcher 前台终端按 Ctrl-C 停掉当前 watcher
# 然后重启（它会读到假端口 19999）
bash "$SANDBOX/scripts/ops/ops-watcher.sh"
```

等 watcher 启动后验证第一个信号——started 通知应该失败：

```bash
# 另一个终端看 events
tail -5 "$SANDBOX/ops_spool/events.jsonl" | jq -c '{msg, extra}'
# 期望看到: {"msg":"telegram send failed","extra":{"kind":"lifecycle","event":"started","http_code":"000"}}
```

### Phase 2：触发一个 path BLOCK proposal（断网状态下）

```bash
SANDBOX=/Users/caimin/ai_sandbox

# 生成 proposal id
NOW=$(date -u +"%Y%m%d-%H%M%S")
RAND=$(LC_ALL=C od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
FAIL_ID="${NOW}-${RAND}"
echo "FAIL TEST ID: $FAIL_ID"

# 构造 BLOCK proposal（path 落在 claude_config/ → 被 check_block_paths 拦）
PROPOSAL_DIR="$SANDBOX/agent_workspace/ops-proposals/$FAIL_ID"
mkdir -p "$PROPOSAL_DIR/claude_config/hooks"
echo "# fail-path test (should never apply)" > "$PROPOSAL_DIR/claude_config/hooks/guard.sh"

SHA=$(shasum -a 256 "$PROPOSAL_DIR/claude_config/hooks/guard.sh" | awk '{print $1}')
SNAP_ID=$(cat "$SANDBOX/snapshot/.snapshot-id")
SNAP_HASH=$(cat "$SANDBOX/snapshot/.snapshot-hash")

jq -n \
  --arg id "$FAIL_ID" \
  --arg sid "$SNAP_ID" \
  --arg shash "$SNAP_HASH" \
  --arg sha "$SHA" \
  '{
    proposal_id: $id,
    base_snapshot_id: $sid,
    base_snapshot_hash: $shash,
    supersedes: null,
    reason: "B.3 failure-path test: telegram offline simulation",
    expected_effect: "should be BLOCKED + notification should FAIL",
    affected_services: ["agent"],
    rebuild_strategy: "minimal",
    changes: [{
      path: "claude_config/hooks/guard.sh",
      type: "modify",
      summary: "fail-path smoke",
      sha256: $sha
    }],
    verification: ["smoke_test_marker"]
  }' > "$PROPOSAL_DIR/manifest.json"

# 投 request（最后写）
NOW_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq -n --arg id "$FAIL_ID" --arg ts "$NOW_TS" \
  '{proposal_id: $id, submitted_at: $ts}' \
  > "$SANDBOX/agent_workspace/ops-requests/${FAIL_ID}.json"

echo "submitted: $FAIL_ID — wait 5s for watcher tick..."
sleep 5
```

### Phase 3：验证（断网状态下的不变量）

```bash
SANDBOX=/Users/caimin/ai_sandbox

echo "=== 1. result file（应该存在且 status=blocked）==="
jq '{id:.proposal_id, status, risk_level, reason}' \
  "$SANDBOX/agent_workspace/ops-results/${FAIL_ID}.json"

echo ""
echo "=== 2. events.jsonl 末尾（应该有 http_code=000）==="
tail -10 "$SANDBOX/ops_spool/events.jsonl" | jq -c '{msg, extra}' | grep -i "$FAIL_ID" || true
# 期望看到:
#   {"msg":"BLOCK path detected: ...","extra":{}}
#   {"msg":"telegram send failed","extra":{"kind":"proposal","status":"blocked","risk":"BLOCK","http_code":"000"}}

echo ""
echo "=== 3. .notified.txt（不应出现 FAIL_ID）==="
cat "$SANDBOX/ops_spool/.notified.txt"
grep "$FAIL_ID" "$SANDBOX/ops_spool/.notified.txt" && echo "!!! BUG: notified.txt polluted !!!" || echo "OK: not polluted"

echo ""
echo "=== 4. request 已被消费（应在 .processed/ 里）==="
ls "$SANDBOX/agent_workspace/ops-requests/.processed/${FAIL_ID}.json" 2>/dev/null && echo "OK: consumed" || echo "!!! BUG: request not consumed !!!"
```

**预期结果**：

| 检查项 | 预期 |
|--------|------|
| result status | `blocked` |
| result risk_level | `BLOCK` |
| events.jsonl http_code | `000` |
| `.notified.txt` 含 FAIL_ID | **否** |
| request 在 `.processed/` | **是** |

### Phase 4：恢复网络 + 验证不补发

```bash
SANDBOX=/Users/caimin/ai_sandbox
ENV_FILE="$SANDBOX/.ops-watcher.env"

# 恢复真实代理端口
sed -i '' 's|^TELEGRAM_PROXY_URL=.*|TELEGRAM_PROXY_URL=http://127.0.0.1:1082|' "$ENV_FILE"
cat "$ENV_FILE"
echo "--- proxy port restored to 1082 ---"

# 重启 watcher（读到正确端口）
# Ctrl-C 当前的 watcher，然后：
bash "$SANDBOX/scripts/ops/ops-watcher.sh"
```

等 5-10 秒（覆盖 2-3 个 polling tick）：

```bash
# 验证 started 通知成功（网络恢复的证明）
tail -3 "$SANDBOX/ops_spool/events.jsonl" | jq -c '{msg, extra}' | grep started
# 期望: http_code=200

# 核心验证：.notified.txt 仍然没有 FAIL_ID
grep "$FAIL_ID" "$SANDBOX/ops_spool/.notified.txt" && echo "!!! BUG: phantom re-send !!!" || echo "OK: no re-send (request already consumed)"

# 额外验证：没有新的 telegram send 关于 FAIL_ID
grep "$FAIL_ID" "$SANDBOX/ops_spool/events.jsonl" | grep "telegram sent" && echo "!!! BUG !!!" || echo "OK: no re-notification"
```

**预期结果**：

| 检查项 | 预期 |
|--------|------|
| started 通知 http_code=200 | **是**（网络恢复证明） |
| `.notified.txt` 含 FAIL_ID | **否**（不补发） |
| events.jsonl 有 FAIL_ID + "telegram sent" | **否** |

## 完成后贴回

```
1. FAIL_ID 是什么
2. Phase 3 的 5 项检查结果
3. Phase 4 恢复后 started 是否 200
4. Phase 4 grep FAIL_ID 结果（应为空）
```

## 设计意图总结

**为什么不补发是正确的**：

这不是"丢消息"——这是设计决策。proposal 已经被正确处理（result 写入 +
request 消费 + proposal 归档），唯一缺失的是 Telegram 通知。但：

1. `result file` 存在且正确 → 任何审计/查询都能找到裁决
2. `events.jsonl` 记录了 `telegram send failed` + `http_code=000` → 可事后审计通知丢失
3. 如果需要"补发"语义，应该由外部 reconciler（Phase 5+）定期扫描
   `.notified.txt` vs `ops-results/` 的差集来实现，**不应该让 watcher 主循环重试**

重试会带来的问题：
- 无限重试 → 代理长时间离线时 watcher 把 request 堆在队列里不消费 → 雪崩
- request 不消费 → watcher 对新 proposal 的 conflict 判定被幽灵 pending 污染
- 主循环从"扫一次即决"退化为"带状态的重试机器" → 复杂度爆炸

当前设计是正确的最简形态。

#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
PENDING_DIR="$ROOT_DIR/agent_workspace/inbox/pending"
INVALID_DIR="$ROOT_DIR/agent_workspace/inbox/invalid"
OUTPUT_DIR="$ROOT_DIR/agent_workspace/output"
STATE_DIR="$ROOT_DIR/agent_workspace/state"
STATUS_FILE="$STATE_DIR/agent-status.json"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

EXECUTE=0
if [ "$#" -eq 2 ] && [ "$1" = "--execute" ]; then
  EXECUTE=1
  TASK_ID="$2"
elif [ "$#" -eq 1 ]; then
  TASK_ID="$1"
else
  echo "用法：$0 [--execute] <task_id>" >&2
  exit 2
fi

if [ -z "${GATEWAY_HMAC_KEY:-}" ]; then
  echo "拒绝：GATEWAY_HMAC_KEY 未设置" >&2
  exit 2
fi

case "$TASK_ID" in
  *[!A-Za-z0-9._-]* | .* | */* | "")
    echo "拒绝：非法 task_id" >&2
    exit 2
    ;;
esac

TASK_FILE="$PENDING_DIR/$TASK_ID.json"
INVALID_FILE="$INVALID_DIR/$TASK_ID.json"
OUTPUT_FILE="$OUTPUT_DIR/$TASK_ID.md"

if [ ! -f "$TASK_FILE" ]; then
  echo "拒绝：任务文件不存在：$TASK_FILE" >&2
  exit 2
fi

write_status() {
  local status="$1"
  local message="$2"
  local output_file="${3:-}"
  mkdir -p "$STATE_DIR"
  STATUS="$status" MESSAGE="$message" OUTPUT_FILE="$output_file" TASK_ID="$TASK_ID" STATUS_FILE="$STATUS_FILE" python3 - <<'PY'
import json
import os
from datetime import datetime, timezone

status_file = os.environ["STATUS_FILE"]
payload = {
    "status": os.environ["STATUS"],
    "task_id": os.environ["TASK_ID"],
    "message": os.environ["MESSAGE"],
    "output_file": os.environ.get("OUTPUT_FILE") or None,
    "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
tmp = f"{status_file}.{os.getpid()}.tmp"
with open(tmp, "w") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp, status_file)
PY
}

export TASK_FILE GATEWAY_HMAC_KEY
TASK_JSON="$(python3 - <<'PY'
import hashlib
import hmac
import json
import os
import sys

path = os.environ["TASK_FILE"]
key = os.environ["GATEWAY_HMAC_KEY"]

try:
    with open(path, "r") as f:
        task = json.load(f)
except Exception as exc:
    print(f"拒绝：任务 JSON 解析失败：{exc}", file=sys.stderr)
    sys.exit(1)

required = ["task_id", "created_at", "chat_id", "prompt", "sig"]
missing = [name for name in required if not task.get(name)]
if missing:
    print("拒绝：任务字段缺失：" + ", ".join(missing), file=sys.stderr)
    sys.exit(1)

message = "\n".join([
    str(task["task_id"]),
    str(task["created_at"]),
    str(task["chat_id"]),
    str(task["prompt"]),
]).encode("utf-8")
expected = hmac.new(key.encode("utf-8"), message, hashlib.sha256).hexdigest()

if not hmac.compare_digest(expected, str(task["sig"])):
    print("拒绝：HMAC 签名无效", file=sys.stderr)
    sys.exit(1)

print(json.dumps(task, ensure_ascii=False, indent=2))
PY
)" || {
  mkdir -p "$INVALID_DIR"
  mv "$TASK_FILE" "$INVALID_FILE"
  echo "已标记为 invalid：$INVALID_FILE" >&2
  exit 1
}

if [ "$EXECUTE" -eq 0 ]; then
  printf '%s\n' "$TASK_JSON"
  exit 0
fi

PROMPT="$(TASK_JSON="$TASK_JSON" python3 - <<'PY'
import json
import os
print(json.loads(os.environ["TASK_JSON"])["prompt"])
PY
)"

mkdir -p "$OUTPUT_DIR"
write_status "running" "任务执行中" "$OUTPUT_FILE"

TMP_OUTPUT="$OUTPUT_FILE.tmp"
CC_STATUS=0
set +e
docker exec agent /usr/local/bin/cc -p "$PROMPT" >"$TMP_OUTPUT" 2>&1
CC_STATUS=$?
set -e

if [ -f "$TMP_OUTPUT" ]; then
  mv "$TMP_OUTPUT" "$OUTPUT_FILE"
else
  printf 'cc 未生成输出文件\n' >"$OUTPUT_FILE"
fi

if [ "${CC_STATUS:-1}" -eq 0 ]; then
  write_status "done" "任务完成" "$OUTPUT_FILE"
  echo "任务完成：$OUTPUT_FILE"
  exit 0
fi

ERROR_MESSAGE="cc 执行失败，exit_code=${CC_STATUS:-unknown}"
write_status "error" "$ERROR_MESSAGE" "$OUTPUT_FILE"
echo "${ERROR_MESSAGE}，输出已写入：$OUTPUT_FILE" >&2
exit "${CC_STATUS:-1}"

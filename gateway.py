#!/usr/bin/env python3
import hashlib
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests

BASE_DIR = Path(__file__).resolve().parents[1]
ENV_FILE = BASE_DIR / ".env"
STATE_DIR = BASE_DIR / "state"
GATEWAY_STATE_FILE = STATE_DIR / "gateway-state.json"
AGENT_STATUS_FILE = BASE_DIR / "agent_workspace" / "state" / "agent-status.json"
AUDIT_FILE = BASE_DIR / "audit_spool" / "audit-collector.jsonl"
FALLBACK_AUDIT_FILE = Path("/var/log/audit/audit-collector.jsonl")
POLL_TIMEOUT = 30
POLL_INTERVAL = 1
BUSY_WINDOW_SECONDS = 180


def load_dotenv(path):
    if not path.exists():
        return
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


def require_env(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"{name} not set")
    return value


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_json(path):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return None
    except json.JSONDecodeError as exc:
        return {"error": f"invalid json: {exc}"}


def atomic_write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    payload = json.dumps(data, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    with tmp_path.open("w") as f:
        f.write(payload)
        f.flush()
        os.fsync(f.fileno())
    tmp_path.replace(path)


def load_gateway_state():
    state = read_json(GATEWAY_STATE_FILE)
    if isinstance(state, dict):
        return state
    return {"last_update_id": 0}


def save_gateway_state(state):
    atomic_write_json(GATEWAY_STATE_FILE, state)


def telegram_request(method, token, payload):
    url = f"https://api.telegram.org/bot{token}/{method}"
    response = requests.post(url, json=payload, timeout=POLL_TIMEOUT + 10)
    response.raise_for_status()
    body = response.json()
    if not body.get("ok"):
        raise RuntimeError(f"Telegram API error: {body}")
    return body


def send_message(token, chat_id, text):
    telegram_request(
        "sendMessage",
        token,
        {
            "chat_id": chat_id,
            "text": text[:3900],
            "disable_web_page_preview": True,
        },
    )


def compact_audit_record(rec):
    tool_input = rec.get("tool_input", {})
    if isinstance(tool_input, dict):
        command = tool_input.get("command") or tool_input.get("cmd") or json.dumps(tool_input, ensure_ascii=False)
    else:
        command = str(tool_input)
    command = command.replace("\n", " ")[:300]
    return "\n".join(
        [
            "最新审计摘要：",
            f"time: {rec.get('timestamp', '?')}",
            f"event: {rec.get('event', '?')}",
            f"tool: {rec.get('tool_name', '?')}",
            f"risk: {rec.get('risk_level', '?')}",
            f"exit_code: {rec.get('exit_code', '?')}",
            f"blocked_by: {rec.get('blocked_by', 'none')}",
            f"command: {command}",
        ]
    )


def latest_audit_record():
    path = AUDIT_FILE if AUDIT_FILE.exists() else FALLBACK_AUDIT_FILE
    try:
        last = ""
        with path.open("r") as f:
            for line in f:
                if line.strip():
                    last = line.strip()
        if not last:
            return None, f"{path} 暂无审计记录。"
        try:
            return json.loads(last), None
        except json.JSONDecodeError:
            return None, "最新审计记录不是合法 JSON。"
    except FileNotFoundError:
        return None, f"审计日志不存在：{path}"
    except OSError as exc:
        return None, f"读取审计日志失败：{exc}"


def parse_timestamp(value):
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None


def format_status():
    rec, error = latest_audit_record()
    if error:
        return f"agent 状态：unknown\n原因：{error}"

    last_ts = parse_timestamp(rec.get("timestamp"))
    if last_ts is None:
        return "agent 状态：unknown\n原因：最新审计记录缺少可解析时间"

    age = max(0, int((datetime.now(timezone.utc) - last_ts).total_seconds()))
    state = "busy" if age <= BUSY_WINDOW_SECONDS else "idle"
    tool = rec.get("tool_name", "?")
    return "\n".join(
        [
            f"agent 状态：{state}",
            f"最近活动：{age}s 前",
            f"最近工具：{tool}",
            "说明：按最近审计活动推断；Telegram 仅提供只读状态，实际操作请用 SSH。",
        ]
    )


def latest_audit_line():
    rec, error = latest_audit_record()
    if error:
        return error
    return compact_audit_record(rec)


def handle_message(token, allowed_chat_id, message):
    chat = message.get("chat", {})
    chat_id = str(chat.get("id", ""))
    if chat_id != allowed_chat_id:
        return

    text = (message.get("text") or "").strip()
    if not text:
        return

    if text == "/status":
        send_message(token, chat_id, format_status())
        return

    if text == "/latest":
        send_message(token, chat_id, latest_audit_line())
        return

    send_message(token, chat_id, "支持命令：/status、/latest\n说明：Telegram 仅提供只读状态；实际操作请使用 SSH。")


def main():
    load_dotenv(ENV_FILE)
    token = require_env("TELEGRAM_BOT_TOKEN")
    allowed_chat_id = require_env("TELEGRAM_CHAT_ID")
    state = load_gateway_state()
    print("gateway started", flush=True)

    while True:
        try:
            offset = int(state.get("last_update_id", 0)) + 1
            body = telegram_request(
                "getUpdates",
                token,
                {"offset": offset, "timeout": POLL_TIMEOUT, "allowed_updates": ["message"]},
            )
            for update in body.get("result", []):
                update_id = int(update.get("update_id", 0))
                if update_id <= int(state.get("last_update_id", 0)):
                    continue
                message = update.get("message")
                if message:
                    handle_message(token, allowed_chat_id, message)
                state["last_update_id"] = update_id
                state["updated_at"] = utc_now()
                save_gateway_state(state)
        except KeyboardInterrupt:
            print("gateway stopped", flush=True)
            return
        except Exception as exc:
            print(f"gateway error: {exc}", file=sys.stderr, flush=True)
            time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
审计日志 Collector — TCP server (newline-delimited JSON)

- 监听 sandbox_net 内部 TCP :5140
- 接收 Agent hook 发来的单行 JSON (newline framing)
- Rate limit: 50 msg/s, 超限丢弃并窗口汇总告警
- 写入 /var/log/audit/audit-collector.jsonl
"""

import fcntl
import json
import os
import socket
import threading
import time
from collections import deque

# --- Config ---
LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 5140
AUDIT_DIR = "/var/log/audit"
AUDIT_FILE = os.path.join(AUDIT_DIR, "audit-collector.jsonl")
MAX_MSG_PER_SEC = 50
MAX_LINE_BYTES = 65536
CONN_TIMEOUT = 2
BACKLOG = 10
HEARTBEAT_INTERVAL = int(os.environ.get("HEARTBEAT_INTERVAL", "300"))

# --- Rate limiter ---
rate_window = deque()
rate_lock = threading.Lock()
rate_alert_dropped = 0
rate_alert_last = 0.0
rate_alert_lock = threading.Lock()


def check_rate() -> bool:
    now = time.monotonic()
    with rate_lock:
        while rate_window and rate_window[0] < now - 1.0:
            rate_window.popleft()
        if len(rate_window) >= MAX_MSG_PER_SEC:
            return False
        rate_window.append(now)
        return True


def maybe_alert_rate_limit():
    """窗口汇总告警：每 1 秒最多写一条 RATE_LIMIT"""
    global rate_alert_dropped, rate_alert_last
    now = time.monotonic()
    with rate_alert_lock:
        rate_alert_dropped += 1
        if now - rate_alert_last >= 1.0:
            count = rate_alert_dropped
            rate_alert_dropped = 0
            rate_alert_last = now
            alert = json.dumps(
                {
                    "schema_version": "1.0",
                    "audit_source": "collector",
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "event": "RATE_LIMIT",
                    "risk_level": "medium",
                    "blocked_by": "rate_limiter",
                    "dropped_count": count,
                }
            )
            write_line(alert)


# --- File writer ---
# write_lock 保证线程安全；flock 是额外的进程级保险（防多实例）
write_lock = threading.Lock()


def write_line(line: str):
    with write_lock:
        with open(AUDIT_FILE, "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            f.write(line + "\n")
            f.flush()
            os.fsync(f.fileno())


def heartbeat_event() -> str:
    return json.dumps(
        {
            "schema_version": "1.0",
            "audit_source": "collector",
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "event": "HEARTBEAT",
            "risk_level": "none",
            "blocked_by": "",
        },
        separators=(",", ":"),
    )


def heartbeat_loop():
    while True:
        write_line(heartbeat_event())
        time.sleep(HEARTBEAT_INTERVAL)


def handle_client(conn: socket.socket, addr):
    try:
        conn.settimeout(CONN_TIMEOUT)
        data = b""
        while True:
            try:
                chunk = conn.recv(4096)
            except socket.timeout:
                return
            if not chunk:
                break
            data += chunk
            if len(data) > MAX_LINE_BYTES:
                return
            if b"\n" in data:
                break
        if data:
            # 只取第一条完整行，避免多行粘连误判
            line_bytes, _, _ = data.partition(b"\n")
            line = line_bytes.decode("utf-8").strip()
            if not line:
                return
            try:
                json.loads(line)
            except json.JSONDecodeError:
                return

            if not check_rate():
                maybe_alert_rate_limit()
                return

            write_line(line)
    except Exception:
        pass
    finally:
        conn.close()


def main():
    os.makedirs(AUDIT_DIR, exist_ok=True)
    write_line(
        json.dumps(
            {
                "schema_version": "1.0",
                "audit_source": "collector",
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "event": "COLLECTOR_START",
                "risk_level": "none",
            }
        )
    )
    threading.Thread(target=heartbeat_loop, daemon=True).start()

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((LISTEN_HOST, LISTEN_PORT))
    server.listen(BACKLOG)
    print(f"Collector listening on {LISTEN_HOST}:{LISTEN_PORT}", flush=True)

    while True:
        try:
            conn, addr = server.accept()
        except OSError:
            time.sleep(0.1)
            continue
        t = threading.Thread(target=handle_client, args=(conn, addr), daemon=True)
        t.start()


if __name__ == "__main__":
    main()

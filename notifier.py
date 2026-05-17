import json
import logging
import os
import sys
import time
import traceback
from datetime import datetime, timezone

import requests

AUDIT_FILE = "/var/log/audit/audit-collector.jsonl"
TELEGRAM_API = "https://api.telegram.org/bot{token}/sendMessage"
IDLE_TIMEOUT = 120
RETRY_INTERVAL = 5
POLL_INTERVAL = 0.5
TELEGRAM_PROXIES = {"https": "http://squid:3128"}
ALERT_COMMAND_LIMIT = 220
SUMMARY_COMMAND_LIMIT = 140
INCIDENT_WINDOW_SECONDS = 300

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
log = logging.getLogger("notifier")


def get_env(name):
    val = os.environ.get(name, "").strip()
    if not val:
        log.error("%s not set", name)
        sys.exit(1)
    return val


def send_telegram(text, token, chat_id):
    url = TELEGRAM_API.format(token=token)
    try:
        r = requests.post(
            url,
            json={"chat_id": chat_id, "text": text, "parse_mode": "HTML"},
            proxies=TELEGRAM_PROXIES,
            timeout=15,
        )
        r.raise_for_status()
        log.info("Telegram sent: %s", text[:80])
    except requests.exceptions.RequestException as e:
        log.warning("Telegram send failed: %s", e)


def _html_escape(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def shorten(text, limit):
    text = str(text).replace("\n", " ").strip()
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "…"


def extract_command(tool_input, limit=ALERT_COMMAND_LIMIT):
    if isinstance(tool_input, dict):
        cmd = tool_input.get("command") or tool_input.get("cmd") or json.dumps(tool_input)
        return _html_escape(shorten(cmd, limit))
    if isinstance(tool_input, str):
        return _html_escape(shorten(tool_input, limit))
    return _html_escape(shorten(tool_input, limit))


def summarize_tool_input(rec, limit=SUMMARY_COMMAND_LIMIT):
    tool_name = rec.get("tool_name", "?")
    tool_input = rec.get("tool_input", {})
    if not isinstance(tool_input, dict):
        return extract_command(tool_input, limit)

    if tool_name == "Bash":
        value = tool_input.get("description") or tool_input.get("command") or "Bash"
    elif tool_name in ("Agent", "WebFetch"):
        value = tool_input.get("description") or tool_name
    elif tool_name in ("Read", "Edit", "Write"):
        value = tool_input.get("file_path") or tool_name
    else:
        value = (
            tool_input.get("description")
            or tool_input.get("file_path")
            or tool_input.get("pattern")
            or tool_name
        )
    return _html_escape(shorten(value, limit))


def action_guidance(rec):
    blocked_by = rec.get("blocked_by", "")
    hints = {
        "credential_directory_access": (
            "检测到凭据路径访问模式",
            "若非你主动测试，建议查看最近审计上下文",
            "tail -n 40 audit_spool/audit-collector.jsonl",
        ),
        "destructive_git_operation": (
            "检测到破坏性 Git 模式",
            "若不是预期测试，建议确认任务上下文",
            "tail -n 40 audit_spool/audit-collector.jsonl",
        ),
        "blocked_remote_code_execution_or_install": (
            "检测到远程执行或直接安装模式",
            "若不是预期测试，建议确认命令来源",
            "tail -n 40 audit_spool/audit-collector.jsonl",
        ),
        "network_scan": (
            "检测到网络扫描模式",
            "建议现在查看最近审计上下文",
            "tail -n 40 audit_spool/audit-collector.jsonl",
        ),
    }
    return hints.get(
        blocked_by,
        (
            "检测到高风险模式",
            "若不是预期行为，建议查看最近审计上下文",
            "tail -n 40 audit_spool/audit-collector.jsonl",
        ),
    )


def incident_key(rec):
    return "{}:{}:{}".format(
        rec.get("blocked_by", ""),
        rec.get("tool_name", ""),
        rec.get("test_context", ""),
    )


def is_blocked(rec):
    return bool(rec.get("blocked_by")) and rec.get("event") == "PRE"


def classify_event(rec, repeated_count=1):
    blocked_by = rec.get("blocked_by", "")
    test_context = rec.get("test_context", "")

    if test_context:
        return "TEST"
    if blocked_by in ("credential_directory_access", "network_scan") and repeated_count >= 3:
        return "ACTIONABLE"
    if blocked_by in (
        "destructive_git_operation",
        "blocked_remote_code_execution_or_install",
        "credential_directory_access",
        "network_scan",
    ):
        return "RESOLVED"
    if rec.get("risk_level") in ("medium", "high"):
        return "INFO"
    return "INFO"


def build_resolved_alert(rec):
    summary, action, ssh_hint = action_guidance(rec)
    return (
        "✅ 高风险已处理\n"
        "发生了什么：{}\n"
        "当前状态：已拦截\n"
        "你需要处理吗：通常不需要\n"
        "建议动作：SSH 后先执行 <code>{}</code>\n"
        "详情：{} | {} | {}\n"
        "时间：{}".format(
            summary,
            ssh_hint,
            rec.get("risk_level", "?"),
            rec.get("tool_name", "?"),
            extract_command(rec.get("tool_input", {})),
            rec.get("timestamp", "?"),
        )
    )


def build_actionable_alert(rec, count):
    summary, _action, ssh_hint = action_guidance(rec)
    return (
        "🔴 需要判断：连续高风险尝试\n"
        "发生了什么：{}\n"
        "当前状态：5 分钟内已拦截 {} 次\n"
        "你需要处理吗：建议现在查看\n"
        "建议动作：SSH 后先执行 <code>{}</code>\n"
        "详情：{} | {} | {}\n"
        "时间：{}".format(
            summary,
            count,
            ssh_hint,
            rec.get("risk_level", "?"),
            rec.get("tool_name", "?"),
            extract_command(rec.get("tool_input", {})),
            rec.get("timestamp", "?"),
        )
    )


def build_test_summary(test_events):
    return (
        "✅ 测试活动已收口\n"
        "状态：{} 个预期事件已聚合\n"
        "你需要处理吗：不需要".format(test_events)
    )


def build_summary(active_elapsed, idle_elapsed, last_cmd, tool_calls, audit_events, errors, high_events, medium_events, actionable_sent):
    if actionable_sent:
        return (
            "🟡 会话已收口\n"
            "状态：本轮高风险事件已另行提醒\n"
            "你需要处理吗：若已看过上一条提醒，可不重复处理\n"
            "摘要：{} 次工具调用，{} 个错误，活跃 {}s，空闲 {}s 后收口".format(
                max(tool_calls, 0),
                errors,
                active_elapsed,
                idle_elapsed,
            )
        )
    if high_events:
        return (
            "🟡 会话已收口，建议复核\n"
            "状态：本轮出现 {} 个 high、{} 个 medium\n"
            "你需要处理吗：请结合已收到的提醒判断\n"
            "摘要：{} 次工具调用，{} 个错误，活跃 {}s，空闲 {}s 后收口".format(
                high_events,
                medium_events,
                max(tool_calls, 0),
                errors,
                active_elapsed,
                idle_elapsed,
            )
        )
    return (
        "✅ 会话已收口\n"
        "状态：正常结束\n"
        "你需要处理吗：不需要\n"
        "摘要：{} 次工具调用，{} 个错误，活跃 {}s，空闲 {}s 后收口".format(
            max(tool_calls, 0),
            errors,
            active_elapsed,
            idle_elapsed,
        )
    )


def build_completion(summary, tail_summary, active_elapsed, tool_calls, audit_events, errors, high_events, medium_events, actionable_sent):
    if actionable_sent:
        return (
            "🟡 任务完成\n"
            "状态：本轮高风险事件已另行提醒\n"
            "你需要处理吗：若已看过上一条提醒，可不重复处理\n"
            "摘要：{}；{} 次工具调用，{} 个错误，活跃 {}s".format(
                _html_escape(shorten(tail_summary or summary, 30)),
                max(tool_calls, 0),
                errors,
                active_elapsed,
            )
        )
    if high_events:
        return (
            "🟡 任务完成，建议复核\n"
            "状态：本轮出现 {} 个 high、{} 个 medium\n"
            "你需要处理吗：请结合已收到的提醒判断\n"
            "摘要：{}；{} 次工具调用，{} 个错误，活跃 {}s".format(
                high_events,
                medium_events,
                _html_escape(shorten(tail_summary or summary, 30)),
                max(tool_calls, 0),
                errors,
                active_elapsed,
            )
        )
    return (
        "✅ 任务完成\n"
        "状态：正常结束\n"
        "你需要处理吗：不需要\n"
        "摘要：{}；{} 次工具调用，{} 个错误，活跃 {}s".format(
            _html_escape(shorten(tail_summary or summary, 30)),
            max(tool_calls, 0),
            errors,
            active_elapsed,
        )
    )


def wait_for_file():
    while not os.path.isfile(AUDIT_FILE):
        log.warning("audit-collector.jsonl not found, retrying in %ds", RETRY_INTERVAL)
        time.sleep(RETRY_INTERVAL)


def main():
    token = get_env("TELEGRAM_BOT_TOKEN")
    chat_id = get_env("TELEGRAM_CHAT_ID")

    log.info("Waiting for audit file...")
    wait_for_file()
    log.info("Audit file found, seeking to end")

    audit_events = 0
    tool_calls = 0
    total_errors = 0
    medium_events = 0
    high_events = 0
    test_events = 0
    incidents = {}
    actionable_sent = False
    last_command = ""
    first_event_time = None
    last_event_time = None
    idle_start = None

    with open(AUDIT_FILE, "r") as f:
        f.seek(0, os.SEEK_END)
        log.info("Notifier ready, watching for events...")

        while True:
            line = f.readline()
            if line:
                line = line.strip()
                if line:
                    try:
                        rec = json.loads(line)
                    except json.JSONDecodeError:
                        log.warning("Skipping malformed JSON: %s", line[:120])
                        continue

                    risk_level = rec.get("risk_level", "none")
                    exit_code = rec.get("exit_code", 0)

                    audit_events += 1
                    if rec.get("event") == "PRE" and rec.get("tool_name") not in ("Stop", ""):
                        tool_calls += 1
                    cmd = summarize_tool_input(rec, SUMMARY_COMMAND_LIMIT)
                    if cmd:
                        last_command = cmd
                    if exit_code not in (0, None, "null", ""):
                        total_errors += 1
                    if risk_level == "medium":
                        medium_events += 1
                    elif risk_level == "high":
                        high_events += 1
                    if rec.get("test_context"):
                        test_events += 1

                    if first_event_time is None:
                        first_event_time = time.time()
                    last_event_time = idle_start = time.time()

                    if is_blocked(rec):
                        key = incident_key(rec)
                        now = time.time()
                        current = incidents.get(key)
                        if current and now - current["last_seen"] <= INCIDENT_WINDOW_SECONDS:
                            current["count"] += 1
                            current["last_seen"] = now
                            current["last_rec"] = rec
                        else:
                            current = {
                                "count": 1,
                                "last_seen": now,
                                "last_rec": rec,
                                "resolved_notified": False,
                                "actionable_notified": False,
                            }
                            incidents[key] = current

                        message_class = classify_event(rec, current["count"])
                        if message_class == "RESOLVED" and rec.get("risk_level") == "high" and current["count"] == 1:
                            send_telegram(build_resolved_alert(rec), token, chat_id)
                            current["resolved_notified"] = True
                        elif message_class == "ACTIONABLE" and not current["actionable_notified"]:
                            send_telegram(build_actionable_alert(rec, current["count"]), token, chat_id)
                            current["actionable_notified"] = True
                            actionable_sent = True

                    if rec.get("event") == "TASK_FINISHED":
                        active_elapsed = int(last_event_time - first_event_time) if first_event_time and last_event_time else 0
                        if tool_calls > 0:
                            text = build_completion(
                                rec.get("summary", "Claude Code 已结束本轮回复"),
                                rec.get("tail_summary", ""),
                                active_elapsed,
                                tool_calls,
                                audit_events,
                                total_errors,
                                high_events,
                                medium_events,
                                actionable_sent,
                            )
                            send_telegram(text, token, chat_id)
                        if test_events:
                            send_telegram(build_test_summary(test_events), token, chat_id)
                        audit_events = 0
                        tool_calls = 0
                        total_errors = 0
                        medium_events = 0
                        high_events = 0
                        test_events = 0
                        last_command = ""
                        first_event_time = None
                        last_event_time = None
                        idle_start = None
                        incidents = {}
                        actionable_sent = False

                continue

            # No new line — check idle summary
            if idle_start is not None and time.time() - idle_start >= IDLE_TIMEOUT:
                active_elapsed = int(last_event_time - first_event_time) if first_event_time and last_event_time else 0
                idle_elapsed = int(time.time() - last_event_time) if last_event_time else 0
                text = build_summary(
                    active_elapsed,
                    idle_elapsed,
                    last_command,
                    tool_calls,
                    audit_events,
                    total_errors,
                    high_events,
                    medium_events,
                    actionable_sent,
                )
                send_telegram(text, token, chat_id)
                audit_events = 0
                tool_calls = 0
                total_errors = 0
                medium_events = 0
                high_events = 0
                test_events = 0
                last_command = ""
                first_event_time = None
                idle_start = None
                incidents = {}
                actionable_sent = False

            time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        log.error("Fatal: %s", traceback.format_exc())
        sys.exit(1)

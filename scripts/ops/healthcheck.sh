#!/bin/bash
# Host-side health check for the Docker sandbox control plane.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
AUDIT_FILE="${ROOT_DIR}/audit_spool/audit-collector.jsonl"
HEARTBEAT_STALE_SECONDS="${HEARTBEAT_STALE_SECONDS:-600}"
LOG_WINDOW="${LOG_WINDOW:-10m}"
REQUIRED_SERVICES=(squid litellm collector notifier cliproxyapi agent)

cd "$ROOT_DIR"

ok_count=0
warn_count=0
fail_count=0

ok() {
  ok_count=$((ok_count + 1))
  printf 'OK   %s\n' "$1"
}

warn() {
  warn_count=$((warn_count + 1))
  printf 'WARN %s\n' "$1"
}

fail() {
  fail_count=$((fail_count + 1))
  printf 'FAIL %s\n' "$1"
}

if running_services="$(docker compose ps --services --filter status=running 2>/dev/null)"; then
  for service in "${REQUIRED_SERVICES[@]}"; do
    if printf '%s\n' "$running_services" | grep -qx "$service"; then
      ok "service ${service} is running"
    else
      fail "service ${service} is not running"
    fi
  done
else
  fail "docker compose status unavailable"
fi

if [[ -r "$AUDIT_FILE" ]]; then
  ok "audit log is readable"
else
  fail "audit log is missing or unreadable: ${AUDIT_FILE}"
fi

latest_heartbeat=""
if [[ -r "$AUDIT_FILE" ]]; then
  latest_heartbeat="$(
    jq -r 'select(.event=="HEARTBEAT" and .audit_source=="collector") | .timestamp' "$AUDIT_FILE" 2>/dev/null \
      | tail -n 1
  )"
fi

if [[ -n "$latest_heartbeat" ]]; then
  heartbeat_age="$(
    python3 - "$latest_heartbeat" <<'PY'
from datetime import datetime, timezone
import sys

ts = sys.argv[1]
dt = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
print(int((datetime.now(timezone.utc) - dt).total_seconds()))
PY
  )"
  if (( heartbeat_age <= HEARTBEAT_STALE_SECONDS )); then
    ok "collector heartbeat fresh (${heartbeat_age}s old)"
  else
    fail "collector heartbeat stale (${heartbeat_age}s old; threshold ${HEARTBEAT_STALE_SECONDS}s)"
  fi
else
  fail "collector heartbeat missing"
fi

notifier_failures="$(
  docker compose logs --since="$LOG_WINDOW" notifier 2>/dev/null \
    | grep -c 'Telegram send failed' || true
)"
if (( notifier_failures > 0 )); then
  warn "notifier had ${notifier_failures} Telegram send failure(s) in the last ${LOG_WINDOW}"
else
  ok "no notifier send failures in the last ${LOG_WINDOW}"
fi

collector_errors="$(
  docker compose logs --since="$LOG_WINDOW" collector 2>/dev/null \
    | grep -Eic 'traceback|fatal|error' || true
)"
if (( collector_errors > 0 )); then
  warn "collector logged ${collector_errors} possible error line(s) in the last ${LOG_WINDOW}"
else
  ok "no collector error lines in the last ${LOG_WINDOW}"
fi

printf '\nSummary: %d ok, %d warn, %d fail\n' "$ok_count" "$warn_count" "$fail_count"

if (( fail_count > 0 )); then
  exit 2
fi

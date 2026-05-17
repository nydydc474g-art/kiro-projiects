# =============================================================================
# NOTIFIER Dockerfile
#
# This builds the *notifier* container image — Telegram push service that
# tails audit_spool/ and notifies the operator on policy events.
#
# Identity:
#   - Base:    python:3.11-slim
#   - Deps:    requests
#   - User:    runtime UID/GID injected via build-args (HOST_UID/HOST_GID)
#
# DO NOT confuse this with:
#   - ../Dockerfile           (root: agent image, node:20-slim + claude-code)
#   - ../collector/Dockerfile (collector service)
#
# Used by docker-compose.yml service:  notifier  (build.context: ./notifier)
# =============================================================================

FROM python:3.11-slim

ARG HOST_UID=501
ARG HOST_GID=20

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir requests

RUN getent group ${HOST_GID} >/dev/null 2>&1 || \
    groupadd -g ${HOST_GID} notifier && \
    id -u ${HOST_UID} >/dev/null 2>&1 || \
    useradd -u ${HOST_UID} -g ${HOST_GID} -s /sbin/nologin -M notifier

WORKDIR /app

COPY notifier.py /app/notifier.py

RUN chown -R ${HOST_UID}:${HOST_GID} /app && \
    chmod 755 /app/notifier.py

USER ${HOST_UID}:${HOST_GID}

CMD ["python3", "/app/notifier.py"]

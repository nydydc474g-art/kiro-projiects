# =============================================================================
# COLLECTOR Dockerfile
#
# This builds the *collector* container image — audit log aggregator that
# ingests guard.sh / audit.sh hook events into audit_spool/.
#
# Identity:
#   - Base:    python:3.11-slim
#   - Deps:    (stdlib only, no pip installs)
#   - User:    runtime UID/GID injected via build-args (HOST_UID/HOST_GID)
#
# DO NOT confuse this with:
#   - ../Dockerfile         (root: agent image, node:20-slim + claude-code)
#   - ../notifier/Dockerfile (notifier service)
#
# Used by docker-compose.yml service:  collector  (build.context: ./collector)
# =============================================================================

FROM python:3.11-slim

ARG HOST_UID=501
ARG HOST_GID=20

RUN mkdir -p /app && \
    (getent group ${HOST_GID} >/dev/null || groupadd -g ${HOST_GID} collector) && \
    (id -u ${HOST_UID} >/dev/null 2>&1 || useradd -m -u ${HOST_UID} -g ${HOST_GID} collector)

COPY collector.py /app/collector.py
RUN chown -R ${HOST_UID}:${HOST_GID} /app

USER ${HOST_UID}:${HOST_GID}
WORKDIR /app

CMD ["python3", "/app/collector.py"]

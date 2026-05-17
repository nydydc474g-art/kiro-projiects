# =============================================================================
# AGENT Dockerfile (root-level)
#
# This builds the *agent* container image — the Claude Code workspace where the
# coding agent runs sandboxed.
#
# Identity:
#   - Base:    node:20-slim
#   - Tools:   claude-code (npm), python venv (markitdown/pandas/...), jq, ripgrep
#   - User:    developer (UID/GID 1000:1000)
#
# DO NOT confuse this with:
#   - notifier/Dockerfile  (python-based Telegram notifier service)
#   - collector/Dockerfile (python-based audit collector service)
#
# Used by docker-compose.yml service:  agent  (build.context: .)
# =============================================================================

FROM node:20-slim

ARG DEBUG_TOOLS=0
ARG CLAUDE_VERSION=latest
ARG HOST_UID=1000
ARG HOST_GID=1000

# 1. 基础系统依赖
RUN apt-get update && apt-get install -y \
    ca-certificates \
    python3 \
    python3-pip \
    python3-venv \
    libreoffice-writer \
    libreoffice-calc \
    libreoffice-impress \
    git \
    jq \
    ripgrep \
    shellcheck \
    --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# 2. 可选调试工具（构建时传入 --build-arg DEBUG_TOOLS=1）
RUN if [ "$DEBUG_TOOLS" = "1" ]; then \
    apt-get update && apt-get install -y \
    curl \
    wget \
    strace \
    lsof \
    procps \
    --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*; \
    fi

# 3. 安装 Claude Code
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_VERSION}

# 4. 验证安装，并创建 cc 短命令
RUN claude --version && \
    ln -sf /usr/local/bin/claude /usr/local/bin/cc

# 5. 创建非 root 用户
RUN userdel -r node 2>/dev/null || true && \
    groupdel node 2>/dev/null || true && \
    groupadd -g ${HOST_GID} developer && \
    useradd -m -u ${HOST_UID} -g ${HOST_GID} developer

# 6. 预建目录
RUN mkdir -p /app/.claude \
             /app/workspace \
             /home/developer/.cache \
             /home/developer/.config \
             /home/developer/.local/state && \
    echo '{}' > /home/developer/.claude.json && \
    chown -R developer:developer /home/developer /app

# 7. 创建隔离 venv 并安装 Python 工具库
ENV VENV_PATH=/opt/venv
RUN python3 -m venv "$VENV_PATH" && \
    "$VENV_PATH/bin/pip" install --no-cache-dir \
    markitdown \
    python-docx \
    openpyxl \
    pandas \
    pymupdf \
    extract-msg && \
    ln -sf "$VENV_PATH/bin/markitdown" /usr/local/bin/markitdown

# 8. 将 venv 加入 PATH（所有用户生效）
ENV PATH="$VENV_PATH/bin:$PATH"

# 9. 安装只读搜索 helper
COPY scripts/search-helper.py /usr/local/bin/search-helper
RUN chmod 0755 /usr/local/bin/search-helper

# 10. 工作目录
WORKDIR /app

# 11. 切换到非 root 用户
USER developer

ENTRYPOINT []
CMD ["/bin/bash", "-c", "mkdir -p ~/.cache ~/.config ~/.local/state ~/.claude && cp -r /app/.claude/. ~/.claude/ && echo '{}' > ~/.claude.json && exec /bin/bash"]

#!/bin/bash
set -u

EVENT="${1:-PRE}"

INPUT_JSON=$(cat 2>/dev/null || true)
if [ -z "$INPUT_JSON" ] || ! echo "$INPUT_JSON" | jq empty 2>/dev/null; then
  INPUT_JSON="{}"
fi

cmd_input=$(echo "$INPUT_JSON" | jq -r '.tool_input.command // ""' 2>/dev/null || true)
cmd_flat=$(printf '%s' "$cmd_input" | tr '\n\r' '  ')

block() {
  local reason="$1"
  echo "BLOCKED: $reason" >&2
  exit 2
}

if echo "$cmd_flat" | grep -qiE 'git[[:space:]]+config.*hooksPath|git[[:space:]]+-c[[:space:]].*hooksPath|git[[:space:]]+commit.*--no-verify|git[[:space:]]+commit.*[[:space:]]-n([[:space:]]|$)|GIT_CONFIG_NOSYSTEM'; then
  block "git hook bypass attempt"
fi

if echo "$cmd_flat" | grep -qiE 'git[[:space:]]+reset[[:space:]].*--hard|git[[:space:]]+clean[[:space:]].*-[A-Za-z]*f[A-Za-z]*[dx]?|git[[:space:]]+restore([[:space:]][^;&|]*)?[[:space:]]+(\.|:/)([[:space:];&|]|$)|git[[:space:]]+checkout([[:space:]][^;&|]*)?[[:space:]]+--[[:space:]]+(\.|:/)([[:space:];&|]|$)|git[[:space:]]+branch[[:space:]]+-D\b|git[[:space:]]+rebase\b|git[[:space:]]+push[[:space:]].*(--force|-f)([[:space:]]|$)'; then
  block "destructive git operation"
fi

if echo "$cmd_flat" | grep -qiE '\brm[[:space:]]+-rf\b|\bdd[[:space:]]+if=|\bmkfs\b|\bshutdown\b|\breboot\b'; then
  block "destructive command pattern"
fi

if echo "$cmd_flat" | grep -qiE '\b(curl|wget)[^;&|]*[|][[:space:]]*(sh|bash)\b|\b(sh|bash)[[:space:]]+<\(|\b(curl|wget)[[:space:]][^;&|]*((-|--)(o|O|output)[=[:space:]]|>)[^;&|]*([;&]|&&)[[:space:]]*(chmod[[:space:]]+\+x[[:space:]]+[^;&|]*([;&]|&&)[[:space:]]*)?(\./|sh[[:space:]]+|bash[[:space:]]+)'; then
  block "remote shell execution pattern"
fi

if echo "$cmd_flat" | grep -qiE 'python3?[[:space:]].*urllib.*(request|urlopen).*exec|python3?[[:space:]].*subprocess.*check_output'; then
  block "python remote execution pattern"
fi

if echo "$cmd_flat" | grep -qiE '(^|[;&|[:space:]])(npx|pnpm[[:space:]]+dlx|yarn[[:space:]]+dlx|bunx)\b'; then
  block "remote package execution pattern"
fi

if echo "$cmd_flat" | grep -qiE '(^|[;&|[:space:]])(npm[[:space:]]+install([[:space:]]+[^;&|]*)?[[:space:]]+(-g|--global)([[:space:]]|$)|yarn[[:space:]]+global[[:space:]]+add\b|pnpm[[:space:]]+add([[:space:]]+[^;&|]*)?[[:space:]]+-g([[:space:]]|$)|pip3?[[:space:]]+install([[:space:]]+[^;&|]*)?[[:space:]]+--user([[:space:]]|$)|python3?[[:space:]]+-m[[:space:]]+pip[[:space:]]+install([[:space:]]+[^;&|]*)?[[:space:]]+--user([[:space:]]|$)|pipx[[:space:]]+install\b)'; then
  block "global package installation pattern"
fi

if echo "$cmd_flat" | grep -qiE '(^|[;&|[:space:]])((pip3?|python3?[[:space:]]+-m[[:space:]]+pip)[[:space:]]+install[^;&|]*(git\+https?://|https?://)|(npm|pnpm|yarn)[[:space:]]+(install|add)[^;&|]*(git\+https?://|https?://|github:))'; then
  block "direct remote package installation pattern"
fi

if echo "$cmd_flat" | grep -qiE 'git[[:space:]]+clone[^;&|]*([;&]|&&)[[:space:]]*(cd[[:space:]]+[^;&|]+[;&][[:space:]]*)?(sh[[:space:]]+|bash[[:space:]]+|\.\/[^[:space:];&|]*|make[[:space:]]+install\b|npm[[:space:]]+run\b|python3?[[:space:]]+setup\.py\b)'; then
  block "clone then execute pattern"
fi

if echo "$cmd_flat" | grep -qiE '(^|[;&|[:space:]])(nmap|masscan)\b|\bnc[[:space:]][^;&|]*-[A-Za-z]*z|for[[:space:]]+[^;&|]*in[[:space:]][^;&|]*(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)'; then
  block "network scan pattern"
fi

# 阻断任何 Bash 命令访问凭据文件（realpath 防软链接）
CRED_FILE="$HOME/.gemini/oauth_creds.json"
if echo "$cmd_flat" | grep -qiE '(^|[[:space:]])[^;|&]*(oauth_creds|\.env|secret|token|credential)'; then
  for arg in $(echo "$cmd_input" | tr ' ' '
' | grep -i 'creds\|\.gemini'); do
    if [ -e "$arg" ]; then
      resolved=$(realpath "$arg" 2>/dev/null || echo "")
      if [ "$resolved" = "$CRED_FILE" ]; then
        block "credential file access attempt"
      fi
    fi
  done
fi

# 目录级兜底：任何命令访问 .gemini/ 路径都阻断
if echo "$cmd_flat" | grep -qiE '(^|[[:space:]])[^;|&]*\.gemini/[^;|&]*'; then
  block "credential directory access attempt"
fi

# 宽兜底：任何删除语义命令针对 .git 目录（防 rm -r -f / find -delete / shred 等变体绕过）
if echo "$cmd_flat" | grep -qiE '(rm|shred|unlink)[^;&|]*(\.git)(/|[[:space:];&|]|$)'; then
  block "destructive workspace framework pattern"
fi
if echo "$cmd_flat" | grep -qiE 'find[[:space:]][^;&|]*(\.git)(/|[[:space:]])[^;&|]*(-delete|-exec[[:space:]]+rm)'; then
  block "destructive workspace framework pattern"
fi

if echo "$cmd_flat" | grep -qiE '\brm[[:space:]]+-[A-Za-z]*r[A-Za-z]*[[:space:]]+([^;&|]*[[:space:]])*([^[:space:];&|]*/)?(\.git|inbox|output|scratch|exports)(/|[[:space:];&|]|$)'; then
  block "destructive workspace framework pattern"
fi

exit 0

#!/usr/bin/env bash
# login.sh — OAuth login helper for CLIProxyAPI with automatic
# callback-port selection (macOS / Linux).
#
#   ~/.claudex/login.sh antigravity
#   ~/.claudex/login.sh codex
#   ~/.claudex/login.sh codex-device   # device flow, needs no callback port
#   ~/.claudex/login.sh opencode       # prompt for the API key, verify, append to your rc file
#
# Tests whether the provider default callback port can be bound on
# 127.0.0.1 and falls back to a free port via -oauth-callback-port.
# Afterwards it restarts the proxy service so it picks up the new
# credentials.
set -euo pipefail

PROVIDER="${1:-}"
CONFIG="${CLAUDEX_PROXY_CONFIG:-${HOME}/.claudex/proxy/config.yaml}"
EXE="${CLAUDEX_PROXY_EXE:-}"

usage() { echo "usage: login.sh <antigravity|codex|codex-device|opencode|<provider>[-login]> [--no-browser]" >&2; exit 2; }
[ -n "$PROVIDER" ] || usage
command -v python3 >/dev/null 2>&1 || { echo "login.sh: needs 'python3' on PATH" >&2; exit 1; }

# Normalise: "antigravity" -> "-antigravity-login".
key="$(printf '%s' "$PROVIDER" | tr '[:upper:]' '[:lower:]' | sed 's/^-*//')"
device_flow=""
if [ "$key" = "codex-device" ] || [ "$key" = "codex-device-login" ]; then
  flag="-codex-device-login"; device_flow="yes"
elif [ "${key%-login}" != "$key" ]; then
  flag="-$key"
else
  flag="-$key-login"
fi

# OpenCode Go uses an API key, not OAuth: prompt (hidden), verify it
# against /models, then persist to the rc file for future shells.
if [ "$key" = "opencode" ] || [ "$key" = "opencode-login" ]; then
  base="${CLAUDEOP_BASE_URL:-https://opencode.ai/zen/go/v1}"
  base="${base%/}"
  while true; do
    printf 'OpenCode Go API key (empty aborts): '
    IFS= read -r -s apikey; printf '\n'
    [ -n "$apikey" ] || { echo "login.sh: cancelled."; exit 0; }
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H "Authorization: Bearer $apikey" "$base/models" 2>/dev/null || true)"
    if [ "$code" = "200" ]; then
      n="$(curl -s --max-time 20 -H "Authorization: Bearer $apikey" "$base/models" 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("data", [])))' 2>/dev/null || echo '?')"
      echo "login.sh: key verified ($n models in catalogue)."
      break
    fi
    echo "login.sh: verification failed (HTTP $code)." >&2
    printf 'Save it anyway? [y/N] '
    IFS= read -r yn
    case "$yn" in y|Y) break ;; *) continue ;; esac
  done
  case "${SHELL:-}" in *bash*) rc="${HOME}/.bashrc" ;; *) rc="${HOME}/.zshrc" ;; esac
  [ -f "$rc" ] || touch "$rc"
  cp "$rc" "$rc.bak.$(date +%Y%m%d-%H%M%S)"
  if grep -q '^export CLAUDEOP_API_KEY=' "$rc" 2>/dev/null; then
    # Replace the existing line; keep a backup (made above).
    python3 - "$rc" "$apikey" <<'PYEOF'
import sys
rc_path, key = sys.argv[1], sys.argv[2]
with open(rc_path) as f:
    lines = f.readlines()
with open(rc_path, "w") as f:
    for ln in lines:
        f.write("export CLAUDEOP_API_KEY='%s'\n" % key.replace("'", "'\\''") if ln.startswith("export CLAUDEOP_API_KEY=") else ln)
PYEOF
  else
    printf "export CLAUDEOP_API_KEY='%s'\n" "${apikey//\'/\'\\\'\'}" >> "$rc"
  fi
  export CLAUDEOP_API_KEY="$apikey"
  echo "login.sh: saved CLAUDEOP_API_KEY to $rc (backup made) and this shell; verify with: claudeop --models"
  echo "login.sh: WARNING — the key is stored in plaintext; do not share it or commit it."
  exit 0
fi

if [ -z "$EXE" ]; then
  if command -v cli-proxy-api >/dev/null 2>&1; then EXE="cli-proxy-api";
  elif command -v cliproxyapi >/dev/null 2>&1; then EXE="cliproxyapi";
  else EXE="${HOME}/.claudex/bin/cli-proxy-api"; fi
fi
[ -x "$EXE" ] || { echo "login.sh: binary not found: $EXE" >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "login.sh: config not found: $CONFIG (run install.sh --with-proxy first)" >&2; exit 1; }

port_free() { python3 -c "import socket; s = socket.socket(); s.bind(('127.0.0.1', $1))" 2>/dev/null; }
find_free_port() {
  for p in 52121 51900 49000 48080 45821 45455; do
    if port_free "$p"; then echo "$p"; return 0; fi
  done
  python3 -c "import socket; s = socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1])"
}

extra=()
if [ -z "$device_flow" ]; then
  short="${key%-login}"
  default=""
  case "$short" in
    antigravity) default="51121" ;;
    codex) default="1455" ;;
  esac
  if [ -n "$default" ] && port_free "$default"; then
    port="$default"
  else
    port="$(find_free_port)"
  fi
  echo "login.sh: using OAuth callback port $port"
  extra+=(-oauth-callback-port "$port")
fi
for a in "$@"; do
  case "$a" in --no-browser) extra+=(--no-browser) ;; esac
done

# NB: plain "${extra[@]}" breaks on empty arrays with bash < 4.4 (macOS
# ships 3.2) under `set -u`, so branch explicitly.
if [ "${#extra[@]}" -gt 0 ]; then
  "$EXE" -config "$CONFIG" "$flag" "${extra[@]}"
else
  "$EXE" -config "$CONFIG" "$flag"
fi

if command -v systemctl >/dev/null 2>&1; then
  if systemctl --user list-unit-files 2>/dev/null | grep -q '^claudex-proxy\.service'; then
    systemctl --user restart claudex-proxy.service
    echo "login.sh: restarted claudex-proxy.service; verify with: claudex --models / claudemini --models"
    exit 0
  elif systemctl --user list-unit-files 2>/dev/null | grep -q '^cli-proxy-api\.service'; then
    systemctl --user restart cli-proxy-api.service
    echo "login.sh: restarted cli-proxy-api.service; verify with: claudex --models / claudemini --models"
    exit 0
  fi
fi
echo "login.sh: restart the proxy by hand so it picks up the new credentials (see README step 4)."

#!/usr/bin/env bash
# login.sh — OAuth login helper for CLIProxyAPI with automatic
# callback-port selection (macOS / Linux).
#
#   ~/.claudex/login.sh antigravity
#   ~/.claudex/login.sh codex
#   ~/.claudex/login.sh codex-device   # device flow, needs no callback port
#
# Tests whether the provider default callback port can be bound on
# 127.0.0.1 and falls back to a free port via -oauth-callback-port.
# Afterwards it restarts the proxy service so it picks up the new
# credentials.
set -euo pipefail

PROVIDER="${1:-}"
CONFIG="${CLAUDEX_PROXY_CONFIG:-${HOME}/.claudex/proxy/config.yaml}"
EXE="${CLAUDEX_PROXY_EXE:-}"

usage() { echo "usage: login.sh <antigravity|codex|codex-device|<provider>[-login]> [--no-browser]" >&2; exit 2; }
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

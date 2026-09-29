#!/usr/bin/env bash
# install.sh — one-step setup for the claudex route wrappers (macOS / Linux).
#
#   ./install.sh                            install all four routes into ~/.claudex
#   ./install.sh --routes claudex,clauden   install only these routes
#   ./install.sh --dir ~/my-wrappers        install somewhere else
#   ./install.sh --rc ~/.bashrc             write source lines to this file instead
#   ./install.sh --no-rc                    copy files only, do not touch any rc file
#   ./install.sh --from <path-or-url>       copy from here instead of this repo checkout
#   ./install.sh --with-proxy               also install CLIProxyAPI (binary +
#                                           localhost-only config + autostart)
#   ./install.sh --uninstall                remove the managed block from the rc file
#   ./install.sh --uninstall --remove-files also delete the installed route files
#
# The rc file gets one clearly-marked block; re-running the installer replaces
# that block instead of appending, so it is safe to run twice. A timestamped
# backup (<rc>.bak.YYYYMMDD-HHMMSS) is made before every modification.

set -euo pipefail

REPO_URL="https://github.com/jason79461385/claudex.git"
ALL_ROUTES="claudex claudemini claudeop clauden"
MARK_BEGIN="# >>> claudex-routes (managed by claudex install.sh; do not edit manually) >>>"
MARK_END="# <<< claudex-routes <<<"

ROUTES="__all__"
DEST="${HOME}/.claudex"
RC="__auto__"
FROM=""
NO_RC=""
WITH_PROXY=""
UNINSTALL=""
REMOVE_FILES=""

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --routes)    ROUTES="${2:-}"; shift 2 ;;
    --routes=*)  ROUTES="${1#--routes=}"; shift ;;
    --dir)       DEST="${2:-}"; shift 2 ;;
    --dir=*)     DEST="${1#--dir=}"; shift ;;
    --rc)        RC="${2:-}"; shift 2 ;;
    --rc=*)      RC="${1#--rc=}"; shift ;;
    --from)      FROM="${2:-}"; shift 2 ;;
    --from=*)    FROM="${1#--from=}"; shift ;;
    --no-rc)     NO_RC="yes"; shift ;;
    --with-proxy) WITH_PROXY="yes"; shift ;;
    --uninstall) UNINSTALL="yes"; shift ;;
    --remove-files) REMOVE_FILES="yes"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "install.sh: unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

# Tilde expansion for --dir/--rc (the shell does not expand them inside "$2").
case "$DEST" in "~"|"~"/*) DEST="${HOME}${DEST#\~}" ;; esac
case "$RC" in "~"|"~"/*) RC="${HOME}${RC#\~}" ;; esac

if [ "$ROUTES" = "__all__" ]; then
  ROUTES="$ALL_ROUTES"
else
  # Normalise "a,b,c" to "a b c" and validate.
  ROUTES="$(printf '%s' "$ROUTES" | tr ',' ' ')"
  for r in $ROUTES; do
    case " $ALL_ROUTES " in
      *" $r "*) ;;
      *) echo "install.sh: unknown route: $r (choose from: $ALL_ROUTES)" >&2; exit 2 ;;
    esac
  done
  [ -n "$ROUTES" ] || { echo "install.sh: --routes needs at least one route" >&2; exit 2; }
fi

if [ "$RC" = "__auto__" ]; then
  case "${SHELL:-}" in
    *bash*) RC="${HOME}/.bashrc" ;;
    *)      RC="${HOME}/.zshrc" ;;  # macOS default; also the fallback for unknown shells
  esac
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "install.sh: needs '$1' on PATH — $2" >&2; exit 1
  }
}
need_cmd python3 "install it first (the wrappers need it too)"
if [ -z "$UNINSTALL" ]; then
  need_cmd curl "install it first"
fi

# Locate the repo content: explicit --from, this checkout, or a fresh clone.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SRC=""
if [ -n "$FROM" ]; then
  case "$FROM" in
    http*|git@*) SRC="__clone__" ;;
    *) SRC="$FROM" ;;
  esac
elif [ -f "${SCRIPT_DIR}/claudex/claudex.sh" ]; then
  SRC="$SCRIPT_DIR"
else
  SRC="__clone__"
fi

TMPDIR_CLONE=""
# NB: must always exit 0 — under `set -e` a failing EXIT trap would
# override the script's real exit code.
cleanup() { [ -n "$TMPDIR_CLONE" ] && rm -rf "$TMPDIR_CLONE"; true; }
trap cleanup EXIT INT TERM

if [ "$SRC" = "__clone__" ]; then
  need_cmd git "install it first, or run install.sh from inside the repo"
  URL="${FROM:-$REPO_URL}"
  TMPDIR_CLONE="$(mktemp -d "${TMPDIR:-/tmp}/claudex-install.XXXXXX")"
  echo "install.sh: cloning ${URL} ..."
  git clone --depth 1 "$URL" "${TMPDIR_CLONE}/claudex" >&2
  SRC="${TMPDIR_CLONE}/claudex"
fi

for r in $ROUTES; do
  [ -f "${SRC}/${r}/${r}.sh" ] || {
    echo "install.sh: '${SRC}' does not look like the claudex repo (missing ${r}/${r}.sh)" >&2
    exit 1
  }
done

# Portable display path: prefer $HOME/... so the rc block survives home moves.
disp_path() {
  case "$1" in
    "${HOME}"/*) printf '$HOME/%s' "${1#${HOME}/}" ;;
    *) printf '%s' "$1" ;;
  esac
}
DEST_DISP="$(disp_path "$DEST")"

write_block() {
  # $1 = rc file, $2 = block content.
  python3 - "$1" "$MARK_BEGIN" "$MARK_END" "$2" <<'PYEOF'
import sys
rc_path, mark_begin, mark_end, raw_block = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
block = raw_block.rstrip("\n") + "\n"
try:
    with open(rc_path) as f:
        text = f.read()
except FileNotFoundError:
    text = ""
if mark_begin in text and mark_end in text:
    before, _, rest = text.partition(mark_begin)
    _, _, after = rest.partition(mark_end)
    # Drop the single newline that used to terminate the old end marker.
    if after.startswith("\n"):
        after = after[1:]
    text = before + block + after
else:
    if text and not text.endswith("\n"):
        text += "\n"
    if text:
        text += "\n"
    text += block
with open(rc_path, "w") as f:
    f.write(text)
PYEOF
}

remove_block() {
  python3 - "$1" "$MARK_BEGIN" "$MARK_END" <<'PYEOF'
import sys
rc_path, mark_begin, mark_end = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(rc_path) as f:
        text = f.read()
except FileNotFoundError:
    text = None
if text is not None and mark_begin in text and mark_end in text:
    before, _, rest = text.partition(mark_begin)
    _, _, after = rest.partition(mark_end)
    if after.startswith("\n"):
        after = after[1:]
    # Collapse neighbouring blank lines left behind.
    before = before.rstrip("\n") + "\n" if before.strip() else ""
    after = after.lstrip("\n")
    with open(rc_path, "w") as f:
        f.write(before + after)
PYEOF
}

backup_rc() {
  local stamp bak
  stamp="$(date +%Y%m%d-%H%M%S)"
  bak="${1}.bak.${stamp}"
  if [ -f "$1" ]; then
    cp "$1" "$bak"
  else
    : > "$1"
    bak="$1 (created new)"
  fi
  printf '%s' "$bak"
}

# ---------------------------------------------------------------------------
# CLIProxyAPI (opt-in via --with-proxy): binary + localhost-only config +
# autostart, so `claudex` / `claudemini` work out of the box.
#
# Never overwrites an existing config; never touches a proxy that already
# answers on the probe port. Test hooks: CLIPROXY_VERSION pins the
# release tag (default: latest from the GitHub API), CLIPROXY_RELEASE_BASE
# overrides the download base, PROXY_PORT overrides the port (wrappers default
# to 8317 — keep them in sync via CLAUDEX_BASE_URL if you change this).
# ---------------------------------------------------------------------------

PROXY_PORT="${PROXY_PORT:-8317}"
PROXY_KEY="sk-dummy"
PROXY_MANAGED_DIR="${HOME}/.local/share/claudex-proxy"
PROXY_OK=""
PROXY_RESTART_HINT=""

proxy_probe() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://127.0.0.1:${PROXY_PORT}/v1/models" 2>/dev/null || true)"
  case "$code" in
    200|401) return 0 ;;
    *) return 1 ;;
  esac
}

# Poll until the proxy answers (first launch can be slow); $1 = max seconds.
proxy_wait_alive() {
  local i=0 max="${1:-30}"
  while [ "$i" -lt "$max" ]; do
    proxy_probe && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

proxy_latest_tag() {
  if [ -n "${CLIPROXY_VERSION:-}" ]; then
    printf '%s' "$CLIPROXY_VERSION"
    return
  fi
  curl -fsSL --max-time 20 \
    https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest 2>/dev/null |
    python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("tag_name", ""))
except Exception:
    print("")'
}

# Download the release tarball for this OS/arch into $1; echo the binary path.
proxy_download() {
  local dest="$1" os arch tag ver asset base url tmp tgz
  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    *) echo "install.sh: --with-proxy supports macOS and Linux, not $(uname -s)" >&2; return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64) arch="amd64" ;;
    arm64|aarch64) arch="aarch64" ;;  # NB: upstream names it aarch64, not arm64
    *) echo "install.sh: --with-proxy: unsupported CPU: $(uname -m)" >&2; return 1 ;;
  esac
  tag="$(proxy_latest_tag)"
  if [ -z "$tag" ]; then
    echo "install.sh: could not find the latest CLIProxyAPI release." >&2
    echo "            Check your network, or pin one: CLIPROXY_VERSION=v8.0.4 $0 --with-proxy ..." >&2
    return 1
  fi
  ver="${tag#v}"
  asset="CLIProxyAPI_${ver}_${os}_${arch}.tar.gz"
  base="${CLIPROXY_RELEASE_BASE:-https://github.com/router-for-me/CLIProxyAPI/releases/download}"
  url="${base}/${tag}/${asset}"
  mkdir -p "$dest"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cliproxy-dl.XXXXXX")"
  tgz="${tmp}/pkg.tgz"
  echo "install.sh: downloading ${asset} ..." >&2
  if ! curl -fsSL --retry 2 --max-time 600 -o "$tgz" "$url"; then
    echo "install.sh: download failed: ${url}" >&2
    rm -rf "$tmp"
    return 1
  fi
  if ! tar -xzf "$tgz" -C "$tmp" cli-proxy-api 2>/dev/null; then
    echo "install.sh: archive has no cli-proxy-api binary: ${url}" >&2
    rm -rf "$tmp"
    return 1
  fi
  mv "${tmp}/cli-proxy-api" "${dest}/cli-proxy-api"
  chmod +x "${dest}/cli-proxy-api"
  rm -rf "$tmp"
  printf '%s' "${dest}/cli-proxy-api"
}

# Create a minimal localhost-only config, but only if none exists.
proxy_write_config() {
  mkdir -p "$(dirname -- "$1")"
  cat > "$1" <<EOF
# Created by claudex install.sh --with-proxy. Safe to edit by hand;
# the installer only creates this file, it never overwrites it.
host: "127.0.0.1"
port: ${PROXY_PORT}
api-keys:
  - "${PROXY_KEY}"
EOF
  echo "install.sh: wrote minimal localhost-only config to $1"
}

# Warn-only check that an existing config matches the wrapper defaults.
proxy_check_config() {
  local conf="$1" problems=""
  grep -qE '^[[:space:]]*host:[[:space:]]*"127\.0\.0\.1"' "$conf" \
    || problems="${problems}  - host is not 127.0.0.1 (must not bind all interfaces)\n"
  grep -qE "^[[:space:]]*port:[[:space:]]*${PROXY_PORT}([[:space:]]|\$)" "$conf" \
    || problems="${problems}  - port is not ${PROXY_PORT}\n"
  if grep -qE '^[[:space:]]*api-keys:' "$conf" && \
     grep -A4 -E '^[[:space:]]*api-keys:' "$conf" | grep -qE '^[[:space:]]*-[[:space:]]*[^[:space:]#]'; then
    :
  else
    problems="${problems}  - api-keys section is missing or empty\n"
  fi
  if [ -n "$problems" ]; then
    printf 'install.sh: WARNING — %s does not match the wrapper defaults:\n%b' "$conf" "$problems" >&2
    printf '            Fix it by hand (see README step 2), then restart the service.\n' >&2
    return 1
  fi
  echo "install.sh: existing config $1 looks good"
  return 0
}

proxy_launchd_enable() {
  # $1 = binary, $2 = config. macOS without Homebrew.
  local bin="$1" conf="$2" plist uid
  plist="${HOME}/Library/LaunchAgents/com.claudex.cliproxyapi.plist"
  uid="$(id -u)"
  mkdir -p "${HOME}/Library/LaunchAgents"
  [ -f "$plist" ] && cp "$plist" "${plist}.bak.$(date +%Y%m%d-%H%M%S)"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.claudex.cliproxyapi</string>
  <key>ProgramArguments</key>
  <array>
    <string>${bin}</string>
    <string>-config</string>
    <string>${conf}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${PROXY_MANAGED_DIR}/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${PROXY_MANAGED_DIR}/stderr.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/${uid}/com.claudex.cliproxyapi" 2>/dev/null || true
  launchctl bootstrap "gui/${uid}" "$plist" || return 1
  echo "install.sh: launchd service loaded (starts at login, kept alive)"
  PROXY_RESTART_HINT="launchctl kickstart -k gui/$(id -u)/com.claudex.cliproxyapi"
}

proxy_setup_darwin() {
  local conf bin
  if command -v brew >/dev/null 2>&1; then
    if command -v cliproxyapi >/dev/null 2>&1; then
      echo "install.sh: cliproxyapi already installed (brew)"
    else
      echo "install.sh: brew install cliproxyapi ..."
      brew install cliproxyapi || return 1
    fi
    conf="$(brew --prefix)/etc/cliproxyapi.conf"
    if [ -f "$conf" ]; then
      proxy_check_config "$conf" || true
    else
      proxy_write_config "$conf"
    fi
    echo "install.sh: brew services start cliproxyapi (autostart at login) ..."
    brew services start cliproxyapi || return 1
    PROXY_RESTART_HINT="brew services restart cliproxyapi"
  else
    echo "install.sh: no Homebrew — managed install into ${PROXY_MANAGED_DIR}"
    bin="$(proxy_download "$PROXY_MANAGED_DIR")" || return 1
    conf="${PROXY_MANAGED_DIR}/config.yaml"
    if [ -f "$conf" ]; then
      proxy_check_config "$conf" || true
    else
      proxy_write_config "$conf"
    fi
    proxy_launchd_enable "$bin" "$conf" || return 1
  fi
}

proxy_setup_linux() {
  local bin="" conf unit
  if command -v cliproxyapi >/dev/null 2>&1; then
    bin="cliproxyapi"
  elif command -v cli-proxy-api >/dev/null 2>&1; then
    bin="cli-proxy-api"
  elif [ -x "${HOME}/cliproxyapi/cli-proxy-api" ]; then
    bin="${HOME}/cliproxyapi/cli-proxy-api"
  fi
  if [ -n "$bin" ]; then
    echo "install.sh: reusing existing CLIProxyAPI binary: ${bin}"
    echo "install.sh: make sure its config binds 127.0.0.1:8317 with your api key (README step 2)"
    if [ -f "${HOME}/.config/systemd/user/cliproxyapi.service" ] && command -v systemctl >/dev/null 2>&1; then
      echo "install.sh: enabling existing cliproxyapi.service ..."
      systemctl --user daemon-reload
      systemctl --user enable --now cliproxyapi.service || return 1
      PROXY_RESTART_HINT="systemctl --user restart cliproxyapi.service"
    elif command -v systemctl >/dev/null 2>&1; then
      echo "install.sh: no cliproxyapi.service unit found — enable autostart per your installer's docs (README step 3)"
    else
      echo "install.sh: no systemctl here — start '${bin}' yourself or add it to your session autostart"
    fi
  else
    echo "install.sh: managed install into ${PROXY_MANAGED_DIR}"
    bin="$(proxy_download "$PROXY_MANAGED_DIR")" || return 1
    conf="${PROXY_MANAGED_DIR}/config.yaml"
    if [ -f "$conf" ]; then
      proxy_check_config "$conf" || true
    else
      proxy_write_config "$conf"
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
      echo "install.sh: no systemctl on this system — run in the foreground instead:" >&2
      echo "            ${bin} -config ${conf}" >&2
      return 1
    fi
    unit="${HOME}/.config/systemd/user/claudex-proxy.service"
    mkdir -p "${HOME}/.config/systemd/user"
    [ -f "$unit" ] && cp "$unit" "${unit}.bak.$(date +%Y%m%d-%H%M%S)"
    cat > "$unit" <<EOF
[Unit]
Description=CLIProxyAPI (managed by claudex installer)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${bin} -config ${conf}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now claudex-proxy.service || return 1
    echo "install.sh: claudex-proxy.service enabled (starts at login;"
    echo "            for boot without login also run: sudo loginctl enable-linger $(id -un))"
    PROXY_RESTART_HINT="systemctl --user restart claudex-proxy.service"
  fi
}

proxy_setup() {
  echo "install.sh: setting up CLIProxyAPI (binary + localhost-only config + autostart) ..."
  if proxy_probe; then
    echo "install.sh: CLIProxyAPI already answering on 127.0.0.1:${PROXY_PORT} — leaving it alone"
    PROXY_OK="yes"
    return 0
  fi
  case "$(uname -s)" in
    Darwin) proxy_setup_darwin ;;
    Linux)  proxy_setup_linux ;;
    *) echo "install.sh: --with-proxy supports macOS and Linux, not $(uname -s)" >&2; return 1 ;;
  esac || return 1
  if proxy_wait_alive 30; then
    echo "install.sh: CLIProxyAPI is answering on 127.0.0.1:${PROXY_PORT}"
    PROXY_OK="yes"
  else
    echo "install.sh: WARNING — the service started but 127.0.0.1:${PROXY_PORT} is still not answering." >&2
    echo "            Check the service logs, then re-run with --with-proxy. Continuing anyway." >&2
  fi
}

if [ -n "$UNINSTALL" ]; then
  if [ -z "$NO_RC" ]; then
    if [ -f "$RC" ] && grep -qF "$MARK_BEGIN" "$RC" 2>/dev/null; then
      bak="$(backup_rc "$RC")"
      remove_block "$RC"
      echo "install.sh: removed the managed block from ${RC} (backup: ${bak})"
    else
      echo "install.sh: no managed block found in ${RC}; nothing to remove"
    fi
  fi
  if [ -n "$REMOVE_FILES" ]; then
    for r in $ALL_ROUTES; do
      # Never gut the repo checkout itself when uninstalling from inside it.
      if [ -e "${DEST}/${r}" ] && [ "${SRC}/${r}" -ef "${DEST}/${r}" ]; then
        echo "install.sh: keeping ${DEST}/${r} (it is the repo checkout itself)"
      elif [ -d "${DEST}/${r}" ]; then
        rm -rf "${DEST}/${r}" && echo "install.sh: removed ${DEST}/${r}"
      fi
    done
    rmdir "$DEST" 2>/dev/null && echo "install.sh: removed empty ${DEST}" || true
  else
    echo "install.sh: route files left in place (add --remove-files to delete them)"
  fi
  echo "install.sh: CLIProxyAPI itself (if installed) was left alone — see README for proxy removal."
  echo "install.sh: done — restart your shell (or edit ${RC}) to finish."
  exit 0
fi

echo "install.sh: installing routes [$ROUTES] into ${DEST} ..."
mkdir -p "$DEST"
for r in $ROUTES; do
  # When installing into the repo checkout itself (the default: clone to
  # ~/.claudex, run its install.sh), source and destination are the same
  # folders — do NOT delete-then-copy, just leave them in place.
  if [ -e "${DEST}/${r}" ] && [ "${SRC}/${r}" -ef "${DEST}/${r}" ]; then
    echo "  ${r}/ already in place"
  else
    rm -rf "${DEST}/${r}"
    cp -R "${SRC}/${r}" "${DEST}/${r}"
    echo "  copied ${r}/"
  fi
done

# Syntax-check what we installed.
for r in $ROUTES; do
  bash -n "${DEST}/${r}/${r}.sh"
done
echo "install.sh: shell syntax OK"

if [ -z "$NO_RC" ]; then
  block="$(
    printf '%s\n' "$MARK_BEGIN"
    for r in $ROUTES; do
      printf 'source "%s/%s/%s.sh"\n' "$DEST_DISP" "$r" "$r"
    done
    printf '%s\n' "$MARK_END"
  )"
  bak="$(backup_rc "$RC")"
  write_block "$RC" "$block"
  echo "install.sh: updated ${RC} (backup: ${bak})"
fi

# Verify the installed wrappers actually load.
verify_sh="bash"
for r in $ROUTES; do
  if ! "$verify_sh" -c "source \"${DEST}/${r}/${r}.sh\" && type $r >/dev/null"; then
    echo "install.sh: WARNING — '${r}' did not load; check ${DEST}/${r}/${r}.sh" >&2
  fi
done
if command -v zsh >/dev/null 2>&1; then
  for r in $ROUTES; do
    zsh -c "source \"${DEST}/${r}/${r}.sh\" && typeset -f $r >/dev/null" || \
      echo "install.sh: WARNING — '${r}' did not load under zsh" >&2
  done
fi
echo "install.sh: wrappers load OK"

if [ -n "$WITH_PROXY" ]; then
  proxy_setup || true
fi

if [ -n "$WITH_PROXY" ] && [ -n "$PROXY_OK" ]; then
  login_bin="cliproxyapi"
  if ! command -v "$login_bin" >/dev/null 2>&1; then
    if [ -x "${PROXY_MANAGED_DIR}/cli-proxy-api" ]; then
      login_bin="${PROXY_MANAGED_DIR}/cli-proxy-api"
    else
      login_bin="cli-proxy-api"
    fi
  fi
  cat <<EOF
install.sh: done (wrappers + CLIProxyAPI).
  Next steps:
  1. Restart your shell (or run: source ${RC})
  2. Log in once per route you use (OAuth opens a browser):
       ${login_bin} -codex-login          # GPT route (claudex)
       ${login_bin} -antigravity-login    # Gemini route (claudemini)
       # OpenCode Go key  ->  export CLAUDEOP_API_KEY=...   (claudeop)
       # VLLM server      ->  vllm serve ...                (clauden)
  3. Restart the proxy so it picks up the new credentials:
       ${PROXY_RESTART_HINT:-# see README step 4 for the restart command}
  4. Verify:  claudex --models  |  claudemini --models  |  claudeop --models  |  clauden --models
EOF
else
  cat <<EOF
install.sh: done.
  Next steps:
  1. Restart your shell (or run: source ${RC})
  2. Log in to whatever your routes need (each needed once):
       cliproxyapi -codex-login          # GPT route (claudex)
       cliproxyapi -antigravity-login    # Gemini route (claudemini)
       # OpenCode Go key  ->  export CLAUDEOP_API_KEY=...   (claudeop)
       # VLLM server      ->  vllm serve ...                (clauden)
     then restart the proxy service so it picks up the credentials.
  3. Verify:  claudex --models  |  claudemini --models  |  claudeop --models  |  clauden --models
EOF
fi

if [ -n "$WITH_PROXY" ] && [ -z "$PROXY_OK" ]; then
  echo "install.sh: wrappers are installed, but the proxy is not answering — fix it, then re-run with --with-proxy." >&2
  exit 1
fi

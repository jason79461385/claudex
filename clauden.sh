# clauden.sh — run Claude Code against your self-hosted VLLM server.
#
# VLLM speaks OpenAI Chat Completions, not Anthropic Messages, so every
# session goes through the bundled localhost bridge (clauden_bridge.py),
# which translates Claude Code's Messages requests to Chat Completions.
# The bridge is localhost-only and pins the upstream request to the
# selected VLLM model.
#
# Install:  source /path/to/clauden.sh   (from ~/.zshrc or ~/.bashrc)
# Works in zsh and bash.
#
# Environment knobs (all optional):
#   CLAUDEN_BASE_URL        VLLM address, with or without trailing /v1
#                           (default http://127.0.0.1:8000)
#   CLAUDEN_API_KEY         VLLM api key; empty means no auth header is sent
#   CLAUDEN_MODEL           pin the primary model; empty means newest catalogue entry
#   CLAUDEN_FALLBACK_MODEL  used when the catalogue cannot be fetched
#                           (default: same as CLAUDEN_MODEL)
#   CLAUDEN_EXCLUDE         regex of model ids to ignore during auto-selection
#   CLAUDEN_MAX_CONTEXT_TOKENS known context window; unset preserves Claude Code's default
#   CLAUDEN_TOOL_SEARCH     true|false (default true)
#   CLAUDEN_BRIDGE_SCRIPT   path to clauden_bridge.py (default: next to this file)
#   CLAUDEN_BRIDGE_PORT     localhost bridge port (default 0 = choose a free port)
#   CLAUDEN_FRONTEND_MODEL  known Claude Code model used as the local protocol label
#   CLAUDEN_DEBUG           1 prints bridge-side errors without request data
#
# NOTE: subagents share the session bridge, so they always use the same
# VLLM model as the primary session. The served model needs tool-calling
# support for Claude Code's tools to work (e.g. served with
# --enable-auto-tool-choice --tool-call-parser). Reasoning traces
# (reasoning_content) are dropped; the final answer is kept.

: "${CLAUDEN_BASE_URL:=http://127.0.0.1:8000}"
: "${CLAUDEN_API_KEY:=}"
: "${CLAUDEN_MODEL:=}"
: "${CLAUDEN_FALLBACK_MODEL:=${CLAUDEN_MODEL:-}}"
: "${CLAUDEN_EXCLUDE:=image|audio|tts|whisper|transcribe|embed|embedding|moderation|realtime|review|search}"
: "${CLAUDEN_MAX_CONTEXT_TOKENS:=${CLAUDE_CODE_MAX_CONTEXT_TOKENS:-}}"
: "${CLAUDEN_TOOL_SEARCH:=true}"
: "${CLAUDEN_BRIDGE_PORT:=0}"

if [ -n "${BASH_SOURCE[0]:-}" ]; then
  __CLAUDEN_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
elif [ -n "${ZSH_VERSION:-}" ]; then
  __CLAUDEN_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${(%):-%x}")" && pwd)
else
  __CLAUDEN_SCRIPT_DIR=$(pwd)
fi

# Every model VLLM serves, newest first.
# Output is "<id>\t<YYYY-MM-DD>\t<ok|skip>", where "skip" marks ids matching
# CLAUDEN_EXCLUDE (embedding/non-chat endpoints that cannot drive a session).
# Models released the same day sort alphabetically, so the choice stays
# deterministic instead of depending on API ordering.
__clauden_models() {
  curl -sf --max-time 5 -H "Authorization: Bearer ${CLAUDEN_API_KEY}" \
       "${CLAUDEN_BASE_URL%/}/v1/models" 2>/dev/null |
  CLAUDEN_EXCLUDE="$CLAUDEN_EXCLUDE" python3 -c '
import datetime, json, os, re, sys
try:
    rows = json.load(sys.stdin).get("data", [])
except Exception:
    sys.exit(1)
skip = re.compile(os.environ["CLAUDEN_EXCLUDE"], re.I)
rows = [m for m in rows if m.get("id")]
rows.sort(key=lambda m: (-int(m.get("created") or 0), m["id"]))
for m in rows:
    created = int(m.get("created") or 0)
    day = datetime.date.fromtimestamp(created).isoformat() if created else "(no date)"
    print(m["id"] + "\t" + day + "\t" + ("skip" if skip.search(m["id"]) else "ok"))
'
}

# The model that would be used right now: newest usable catalogue entry.
__clauden_pick() {
  local id
  id=$(__clauden_models | awk -F'\t' '$3=="ok"{print $1; exit}')
  printf '%s\n' "${id:-$CLAUDEN_FALLBACK_MODEL}"
}

__clauden_start_bridge() {
  local model="$1" script tmp pid port i
  script="${CLAUDEN_BRIDGE_SCRIPT:-${__CLAUDEN_SCRIPT_DIR}/clauden_bridge.py}"
  if [ ! -f "$script" ]; then
    echo "clauden: bridge script not found: $script" >&2
    echo "         keep clauden.sh and clauden_bridge.py together" >&2
    return 1
  fi

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/clauden-bridge.XXXXXX") || return 1
  CLAUDEN_API_KEY="$CLAUDEN_API_KEY" \
  CLAUDEN_BASE_URL="$CLAUDEN_BASE_URL" \
  CLAUDEN_DEBUG="${CLAUDEN_DEBUG:-}" \
  python3 "$script" --model "$model" --base-url "$CLAUDEN_BASE_URL" \
    --port "$CLAUDEN_BRIDGE_PORT" >"$tmp/port" 2>"$tmp/log" &
  pid=$!

  port=""
  i=0
  while [ "$i" -lt 50 ]; do
    if [ -s "$tmp/port" ]; then
      port=$(awk -F= '/^PORT=/{print $2; exit}' "$tmp/port")
      [ -n "$port" ] && break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "clauden: local bridge failed to start" >&2
      [ -s "$tmp/log" ] && cat "$tmp/log" >&2
      rm -rf "$tmp"
      return 1
    fi
    sleep 0.1
    i=$((i + 1))
  done

  if [ -z "$port" ]; then
    echo "clauden: local bridge did not announce a port" >&2
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ -s "$tmp/log" ] && cat "$tmp/log" >&2
    rm -rf "$tmp"
    return 1
  fi

  __CLAUDEN_BRIDGE_PID="$pid"
  __CLAUDEN_BRIDGE_PORT_ACTIVE="$port"
  __CLAUDEN_BRIDGE_TMP="$tmp"
}

__clauden_stop_bridge() {
  if [ -n "${__CLAUDEN_BRIDGE_PID:-}" ]; then
    kill "$__CLAUDEN_BRIDGE_PID" 2>/dev/null || true
    wait "$__CLAUDEN_BRIDGE_PID" 2>/dev/null || true
  fi
  [ -n "${__CLAUDEN_BRIDGE_TMP:-}" ] && rm -rf "$__CLAUDEN_BRIDGE_TMP"
  unset __CLAUDEN_BRIDGE_PID __CLAUDEN_BRIDGE_PORT_ACTIVE __CLAUDEN_BRIDGE_TMP
}

clauden() {
  local model="" list a prev="" id day kind showall="" frontend_model rewrite_prev
  local -a child_args

  case "$1" in
    --models|--list-models) ;;
    --models-all) showall="yes" ;;
  esac

  if [ -n "$showall" ] || [ "$1" = "--models" ] || [ "$1" = "--list-models" ]; then
    list=$(__clauden_models)
    if [ -z "$list" ]; then
      echo "clauden: cannot reach VLLM at ${CLAUDEN_BASE_URL}" >&2
      echo "         check CLAUDEN_BASE_URL and that 'vllm serve' is running" >&2
      return 1
    fi
    model="${CLAUDEN_MODEL:-$(__clauden_pick)}"
    [ -n "$model" ] || model="$CLAUDEN_FALLBACK_MODEL"
    printf '%s\n' "$list" | while IFS="$(printf '\t')" read -r id day kind; do
      if [ "$kind" = "skip" ]; then
        [ -n "$showall" ] && printf '  %-24s %s   (not a chat model, skipped)\n' "$id" "$day"
      elif [ "$id" = "$model" ]; then
        printf '  %-24s %s   <- clauden uses this (local Chat Completions bridge)\n' "$id" "$day"
      else
        printf '  %-24s %s   (local Chat Completions bridge)\n' "$id" "$day"
      fi
    done
    return 0
  fi

  # An explicit --model / -m / --model= from the caller always wins.
  for a in "$@"; do
    case "$prev" in --model|-m) model="$a" ;; esac
    case "$a" in --model=*) model="${a#--model=}" ;; esac
    prev="$a"
  done

  if [ -z "$model" ]; then
    model="${CLAUDEN_MODEL:-$(__clauden_pick)}"
    if [ -z "$model" ]; then
      echo "clauden: no model selected and VLLM is unreachable" >&2
      echo "         set CLAUDEN_MODEL or check CLAUDEN_BASE_URL" >&2
      return 1
    fi
    set -- --model "$model" "$@"
  fi

  __clauden_start_bridge "$model" || return

  # Claude Code validates --model against its own catalog before sending a
  # request. Use a known local label, while the bridge pins the upstream
  # request to the selected VLLM model.
  frontend_model="${CLAUDEN_FRONTEND_MODEL:-claude-sonnet-5}"
  child_args=()
  rewrite_prev=""
  for a in "$@"; do
    if [ -n "$rewrite_prev" ]; then
      child_args+=("$frontend_model")
      rewrite_prev=""
      continue
    fi
    case "$a" in
      --model|-m)
        child_args+=("$a")
        rewrite_prev="$a"
        ;;
      --model=*) child_args+=("--model=${frontend_model}") ;;
      *) child_args+=("$a") ;;
    esac
  done

  # Claude Code talks to the localhost bridge; the bridge forwards the real
  # VLLM key upstream. The dummy local key is never sent to VLLM.
  ANTHROPIC_BASE_URL="http://127.0.0.1:${__CLAUDEN_BRIDGE_PORT_ACTIVE}" \
  ANTHROPIC_API_KEY= \
  ANTHROPIC_AUTH_TOKEN="clauden-local-bridge" \
  CLAUDE_CODE_SUBAGENT_MODEL="$frontend_model" \
  CLAUDE_CODE_MAX_CONTEXT_TOKENS="$CLAUDEN_MAX_CONTEXT_TOKENS" \
  CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1 \
  CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1 \
  CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3 \
  ENABLE_TOOL_SEARCH="$CLAUDEN_TOOL_SEARCH" \
  command claude "${child_args[@]}"
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "${CLAUDEN_DEBUG:-}" = "1" ] && [ -s "${__CLAUDEN_BRIDGE_TMP:-}/log" ]; then
    printf '%s\n' 'clauden: bridge diagnostics (no request data):' >&2
    cat "${__CLAUDEN_BRIDGE_TMP}/log" >&2
  fi
  __clauden_stop_bridge
  return "$rc"
}

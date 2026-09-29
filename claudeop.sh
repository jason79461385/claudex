# claudeop.sh — run Claude Code against OpenCode Go.
#
# Claude models use Zen's Anthropic Messages endpoint directly. Non-Claude chat
# models, including DeepSeek V4, use the bundled localhost bridge to translate
# Claude Code's Messages requests to OpenCode's Chat Completions endpoint.
#
# Install:  source /path/to/claudeop.sh   (from ~/.zshrc or ~/.bashrc)
# Works in zsh and bash.
#
# Environment knobs (all optional except CLAUDEOP_API_KEY):
#   CLAUDEOP_BASE_URL        API address (default https://opencode.ai/zen/go/v1)
#   CLAUDEOP_API_KEY         OpenCode Go API key
#   CLAUDEOP_MODEL           pin the primary model; empty means newest catalogue entry
#   CLAUDEOP_FALLBACK_MODEL  used when the catalogue cannot be fetched
#   CLAUDEOP_EXCLUDE         regex of model ids to ignore during auto-selection
#   CLAUDEOP_SUBAGENT_MODEL  model for spawned agents (default: same as primary)
#   CLAUDEOP_MAX_CONTEXT_TOKENS known context window; unset preserves Claude Code's default
#   CLAUDEOP_TOOL_SEARCH     true|false (default false; enable only if route forwards tool_reference)
#   CLAUDEOP_BRIDGE_SCRIPT   path to claudeop_bridge.py (default: next to this file)
#   CLAUDEOP_BRIDGE_PORT     localhost bridge port (default 0 = choose a free port)
#   CLAUDEOP_FRONTEND_MODEL  known Claude Code model used as the local protocol label
#   CLAUDEOP_DEBUG            1 prints bridge-side errors without request data

: "${CLAUDEOP_BASE_URL:=https://opencode.ai/zen/go/v1}"
: "${CLAUDEOP_API_KEY:=}"
: "${CLAUDEOP_MODEL:=}"
: "${CLAUDEOP_FALLBACK_MODEL:=deepseek-v4-pro}"
: "${CLAUDEOP_EXCLUDE:=image|audio|tts|whisper|transcribe|embed|embedding|moderation|realtime|review|search}"
: "${CLAUDEOP_SUBAGENT_MODEL:=}"
: "${CLAUDEOP_MAX_CONTEXT_TOKENS:=${CLAUDE_CODE_MAX_CONTEXT_TOKENS:-}}"
: "${CLAUDEOP_TOOL_SEARCH:=false}"
: "${CLAUDEOP_BRIDGE_PORT:=0}"

if [ -n "${BASH_SOURCE[0]:-}" ]; then
  __CLAUDEOP_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
elif [ -n "${ZSH_VERSION:-}" ]; then
  __CLAUDEOP_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${(%):-%x}")" && pwd)
else
  __CLAUDEOP_SCRIPT_DIR=$(pwd)
fi

__claudeop_require_key() {
  if [ -z "$CLAUDEOP_API_KEY" ]; then
    echo "claudeop: set CLAUDEOP_API_KEY to your OpenCode Go API key" >&2
    return 2
  fi
}

# Claude Code appends /v1/messages itself. OpenCode's catalogue and Chat
# Completions URLs retain the /v1 suffix, while the Anthropic base does not.
__claudeop_anthropic_base_url() {
  local base="${CLAUDEOP_BASE_URL%/}"
  case "$base" in
    */v1) printf '%s' "${base%/v1}" ;;
    *) printf '%s' "$base" ;;
  esac
}

# Output is "<id>\t<date>\t<direct|chat>\t<ok|skip>", newest first.
# The Go catalogue contains multiple protocols; the bridge currently supports
# the Chat Completions route for non-Claude models, which covers DeepSeek V4.
__claudeop_models() {
  __claudeop_require_key || return
  curl -sf --max-time 10 \
       -H "Authorization: Bearer ${CLAUDEOP_API_KEY}" \
       -H "User-Agent: claudeop/1.0" \
       -H "x-opencode-session: claudeop-model-list" \
       "${CLAUDEOP_BASE_URL}/models" 2>/dev/null |
  CLAUDEOP_EXCLUDE="$CLAUDEOP_EXCLUDE" python3 -c '
import datetime
import json
import os
import re
import sys

try:
    rows = json.load(sys.stdin).get("data", [])
except Exception:
    sys.exit(1)

exclude = os.environ.get("CLAUDEOP_EXCLUDE", "").strip()
skip = re.compile(exclude, re.I) if exclude else None
rows = [row for row in rows if row.get("id")]


def created_value(row):
    value = row.get("created") or 0
    try:
        stamp = int(value)
    except (TypeError, ValueError):
        stamp = 0
    # Be tolerant of millisecond timestamps from OpenAI-compatible catalogues.
    return stamp // 1000 if stamp > 10_000_000_000 else stamp


def version(model):
    match = re.search(r"(?<!\d)(\d+)(?:[.-](\d+))?", model)
    return (int(match.group(1)), int(match.group(2) or 0)) if match else (-1, -1)


rows.sort(key=lambda row: (
    -created_value(row),
    -version(row["id"])[0],
    -version(row["id"])[1],
    row["id"],
))
for row in rows:
    model = row["id"]
    created = created_value(row)
    if created:
        try:
            day = datetime.datetime.fromtimestamp(
                created, datetime.timezone.utc
            ).date().isoformat()
        except (OverflowError, OSError, ValueError):
            day = "(invalid date)"
    else:
        day = "(no date)"
    kind = "direct" if model.startswith("claude-") else "chat"
    status = "skip" if skip and skip.search(model) else "ok"
    print(f"{model}\t{day}\t{kind}\t{status}")
'
}

# The model that would be used right now: newest usable catalogue entry.
__claudeop_pick() {
  local id
  id=$(__claudeop_models | awk -F'\t' '$4=="ok"{print $1; exit}')
  printf '%s\n' "${id:-$CLAUDEOP_FALLBACK_MODEL}"
}

__claudeop_start_bridge() {
  local model="$1" script tmp pid port i
  script="${CLAUDEOP_BRIDGE_SCRIPT:-${__CLAUDEOP_SCRIPT_DIR}/claudeop_bridge.py}"
  if [ ! -f "$script" ]; then
    echo "claudeop: bridge script not found: $script" >&2
    echo "         keep claudeop.sh and claudeop_bridge.py together" >&2
    return 1
  fi

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/claudeop-bridge.XXXXXX") || return 1
  CLAUDEOP_API_KEY="$CLAUDEOP_API_KEY" \
  CLAUDEOP_BASE_URL="$CLAUDEOP_BASE_URL" \
  CLAUDEOP_DEBUG="${CLAUDEOP_DEBUG:-}" \
  python3 "$script" --model "$model" --base-url "$CLAUDEOP_BASE_URL" \
    --port "$CLAUDEOP_BRIDGE_PORT" >"$tmp/port" 2>"$tmp/log" &
  pid=$!

  port=""
  i=0
  while [ "$i" -lt 50 ]; do
    if [ -s "$tmp/port" ]; then
      port=$(awk -F= '/^PORT=/{print $2; exit}' "$tmp/port")
      [ -n "$port" ] && break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "claudeop: local bridge failed to start" >&2
      [ -s "$tmp/log" ] && cat "$tmp/log" >&2
      rm -rf "$tmp"
      return 1
    fi
    sleep 0.1
    i=$((i + 1))
  done

  if [ -z "$port" ]; then
    echo "claudeop: local bridge did not announce a port" >&2
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ -s "$tmp/log" ] && cat "$tmp/log" >&2
    rm -rf "$tmp"
    return 1
  fi

  __CLAUDEOP_BRIDGE_PID="$pid"
  __CLAUDEOP_BRIDGE_PORT_ACTIVE="$port"
  __CLAUDEOP_BRIDGE_TMP="$tmp"
}

__claudeop_stop_bridge() {
  if [ -n "${__CLAUDEOP_BRIDGE_PID:-}" ]; then
    kill "$__CLAUDEOP_BRIDGE_PID" 2>/dev/null || true
    wait "$__CLAUDEOP_BRIDGE_PID" 2>/dev/null || true
  fi
  [ -n "${__CLAUDEOP_BRIDGE_TMP:-}" ] && rm -rf "$__CLAUDEOP_BRIDGE_TMP"
  unset __CLAUDEOP_BRIDGE_PID __CLAUDEOP_BRIDGE_PORT_ACTIVE __CLAUDEOP_BRIDGE_TMP
}

claudeop() {
  local model="" list a prev="" id day kind model_status showall="" sub bridge="" frontend_model rewrite_prev
  local -a child_args

  case "$1" in
    --models|--list-models) ;;
    --models-all) showall="yes" ;;
  esac

  if [ -n "$showall" ] || [ "$1" = "--models" ] || [ "$1" = "--list-models" ]; then
    __claudeop_require_key || return
    list=$(__claudeop_models)
    if [ -z "$list" ]; then
      echo "claudeop: cannot reach OpenCode Go or the API key was rejected" >&2
      echo "         check CLAUDEOP_BASE_URL, CLAUDEOP_API_KEY, and your network connection" >&2
      return 1
    fi
    model="${CLAUDEOP_MODEL:-$(printf '%s\n' "$list" | awk -F'\t' '$4=="ok"{print $1; exit}')}"
    [ -n "$model" ] || model="$CLAUDEOP_FALLBACK_MODEL"
    if ! printf '%s\n' "$list" | awk -F'\t' '$4=="ok"{found=1} END{exit !found}'; then
      echo "claudeop: the catalogue contains no model allowed by CLAUDEOP_EXCLUDE" >&2
      showall="yes"
    fi
    printf '%s\n' "$list" | while IFS="$(printf '\t')" read -r id day kind model_status; do
      if [ "$model_status" = "skip" ]; then
        [ -n "$showall" ] && printf '  %-28s %s   (excluded by CLAUDEOP_EXCLUDE)\n' "$id" "$day"
      elif [ "$kind" = "direct" ]; then
        if [ "$id" = "$model" ]; then
          printf '  %-28s %s   <- claudeop uses this (Anthropic Messages)\n' "$id" "$day"
        else
          printf '  %-28s %s\n' "$id" "$day"
        fi
      elif [ "$id" = "$model" ]; then
        printf '  %-28s %s   <- claudeop uses this (local Chat Completions bridge)\n' "$id" "$day"
      else
        printf '  %-28s %s   (local Chat Completions bridge)\n' "$id" "$day"
      fi
    done
    return 0
  fi

  for a in "$@"; do
    case "$prev" in --model|-m) model="$a" ;; esac
    case "$a" in --model=*) model="${a#--model=}" ;; esac
    prev="$a"
  done

  __claudeop_require_key || return

  if [ -z "$model" ]; then
    model="${CLAUDEOP_MODEL:-$(__claudeop_pick)}"
    set -- --model "$model" "$@"
  fi

  sub="${CLAUDEOP_SUBAGENT_MODEL:-$model}"
  case "$model" in
    claude-*) ;;
    *) bridge="yes" ;;
  esac

  if [ -n "$bridge" ]; then
    __claudeop_start_bridge "$model" || return

    # Claude Code validates --model against its own catalog before sending a
    # request. Use a known local label, while the bridge pins the upstream
    # request to the selected OpenCode model.
    frontend_model="${CLAUDEOP_FRONTEND_MODEL:-claude-sonnet-5}"
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
    # OpenCode key upstream. The dummy local key is never sent to OpenCode.
    ANTHROPIC_BASE_URL="http://127.0.0.1:${__CLAUDEOP_BRIDGE_PORT_ACTIVE}" \
    ANTHROPIC_API_KEY= \
    ANTHROPIC_AUTH_TOKEN="claudeop-local-bridge" \
    CLAUDE_CODE_SUBAGENT_MODEL="$frontend_model" \
    CLAUDE_CODE_MAX_CONTEXT_TOKENS="$CLAUDEOP_MAX_CONTEXT_TOKENS" \
    CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1 \
    CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1 \
    CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3 \
    ENABLE_TOOL_SEARCH="$CLAUDEOP_TOOL_SEARCH" \
    command claude "${child_args[@]}"
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "${CLAUDEOP_DEBUG:-}" = "1" ] && [ -s "${__CLAUDEOP_BRIDGE_TMP:-}/log" ]; then
      printf '%s\n' 'claudeop: bridge diagnostics (no request data):' >&2
      cat "${__CLAUDEOP_BRIDGE_TMP}/log" >&2
    fi
    __claudeop_stop_bridge
    return "$rc"
  fi

  # Direct Claude route: Go's OpenAI-compatible API uses Bearer auth. Use
  # AUTH_TOKEN so Claude Code sends the Go key as Authorization: Bearer.
  ANTHROPIC_BASE_URL="$(__claudeop_anthropic_base_url)" \
  ANTHROPIC_API_KEY= \
  ANTHROPIC_AUTH_TOKEN="$CLAUDEOP_API_KEY" \
  CLAUDE_CODE_SUBAGENT_MODEL="$sub" \
  CLAUDE_CODE_MAX_CONTEXT_TOKENS="$CLAUDEOP_MAX_CONTEXT_TOKENS" \
  CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1 \
  CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3 \
  ENABLE_TOOL_SEARCH="$CLAUDEOP_TOOL_SEARCH" \
  command claude "$@"
}

# claudex.sh — run Claude Code against a GPT model served by a local CLIProxyAPI.
#
# Install:  source /path/to/claudex/claudex/claudex.sh   (from ~/.zshrc or ~/.bashrc)
# Works in zsh and bash.
#
# Environment knobs (all optional):
#   CLAUDEX_BASE_URL        proxy address           (default http://127.0.0.1:8317)
#   CLAUDEX_API_KEY         proxy api key           (default sk-dummy)
#   CLAUDEX_MODEL           pin the primary model, skips auto-detection
#   CLAUDEX_INCLUDE         regex a model id MUST match to be usable (default gpt|codex)
#   CLAUDEX_SUBAGENT_MODEL  model for spawned agents (default gpt-6-luna)
#   CLAUDEX_MAX_CONTEXT_TOKENS known context window; unset preserves Claude Code's default
#   CLAUDEX_FALLBACK_MODEL  used when the proxy is unreachable (default gpt-6-luna)
#   CLAUDEX_EXCLUDE         regex of model ids to ignore
#   CLAUDEX_TOOL_SEARCH     true|false              (default true)

: "${CLAUDEX_BASE_URL:=http://127.0.0.1:8317}"
: "${CLAUDEX_API_KEY:=sk-dummy}"
: "${CLAUDEX_SUBAGENT_MODEL:=gpt-6-luna}"
: "${CLAUDEX_MAX_CONTEXT_TOKENS:=${CLAUDE_CODE_MAX_CONTEXT_TOKENS:-}}"
: "${CLAUDEX_FALLBACK_MODEL:=gpt-6-luna}"
: "${CLAUDEX_EXCLUDE:=image|audio|tts|whisper|transcribe|embed|moderation|realtime|review|search}"
# The positive filter is what keeps this route on GPT: the same proxy serves
# gpt-* and gemini-* together, so "newest usable id" is not enough.
: "${CLAUDEX_INCLUDE:=gpt|codex}"
: "${CLAUDEX_TOOL_SEARCH:=true}"

# Every GPT model the proxy serves, newest first.
# Output is "<id>\t<YYYY-MM-DD>\t<ok|skip>", where "skip" marks ids that either
# fail CLAUDEX_INCLUDE (not a GPT) or match CLAUDEX_EXCLUDE (image/audio/review
# endpoints that cannot drive a session).
# Models released the same day sort alphabetically, so the choice stays
# deterministic instead of depending on API ordering.
__claudex_models() {
  curl -sf --max-time 5 -H "Authorization: Bearer ${CLAUDEX_API_KEY}" \
       "${CLAUDEX_BASE_URL}/v1/models" 2>/dev/null |
  CLAUDEX_INCLUDE="$CLAUDEX_INCLUDE" CLAUDEX_EXCLUDE="$CLAUDEX_EXCLUDE" python3 -c '
import datetime, json, os, re, sys
try:
    rows = json.load(sys.stdin).get("data", [])
except Exception:
    sys.exit(1)
keep = re.compile(os.environ["CLAUDEX_INCLUDE"], re.I)
skip = re.compile(os.environ["CLAUDEX_EXCLUDE"], re.I)
rows = [m for m in rows if m.get("id")]
rows.sort(key=lambda m: (-int(m.get("created") or 0), m["id"]))
for m in rows:
    day = datetime.date.fromtimestamp(int(m.get("created") or 0)).isoformat()
    usable = keep.search(m["id"]) and not skip.search(m["id"])
    print(m["id"] + "\t" + day + "\t" + ("ok" if usable else "skip"))
'
}

# The model that would be used right now: newest usable one.
__claudex_pick() {
  local id
  id=$(__claudex_models | awk -F'\t' '$3=="ok"{print $1; exit}')
  printf '%s\n' "${id:-$CLAUDEX_FALLBACK_MODEL}"
}

claudex() {
  local model="" list a prev="" id day kind showall=""

  case "$1" in
    --models|--list-models) showall="" ;;
    --models-all)           showall="yes" ;;
  esac

  if [ -n "$showall" ] || [ "$1" = "--models" ] || [ "$1" = "--list-models" ]; then
    list=$(__claudex_models)
    if [ -z "$list" ]; then
      echo "claudex: cannot reach CLIProxyAPI at ${CLAUDEX_BASE_URL}" >&2
      echo "         macOS: brew services restart cliproxyapi" >&2
      echo "         Linux: systemctl --user restart cli-proxy-api" >&2
      return 1
    fi
    model="${CLAUDEX_MODEL:-$(__claudex_pick)}"
    if ! printf '%s\n' "$list" | awk -F'\t' '$3=="ok"{found=1} END{exit !found}'; then
      echo "claudex: the proxy serves no GPT model." >&2
      echo "         Add a Codex credential, then restart the service:" >&2
      echo "           cliproxyapi -codex-login" >&2
      echo "         Listing everything it DOES serve:" >&2
      showall="yes"
    fi
    printf '%s\n' "$list" | while IFS="$(printf '\t')" read -r id day kind; do
      if [ "$kind" = "skip" ]; then
        [ -n "$showall" ] && printf '  %-24s %s   (not a usable GPT chat model, skipped)\n' "$id" "$day"
      elif [ "$id" = "$model" ]; then
        printf '  %-24s %s   <- claudex uses this\n' "$id" "$day"
      else
        printf '  %-24s %s\n' "$id" "$day"
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

  if [ -n "$model" ]; then
    ANTHROPIC_BASE_URL="$CLAUDEX_BASE_URL" \
    ANTHROPIC_API_KEY= \
    ANTHROPIC_AUTH_TOKEN="$CLAUDEX_API_KEY" \
    CLAUDE_CODE_SUBAGENT_MODEL="$CLAUDEX_SUBAGENT_MODEL" \
    CLAUDE_CODE_SUBAGENT_MODEL_FORCE= \
    CLAUDE_CODE_MAX_CONTEXT_TOKENS="$CLAUDEX_MAX_CONTEXT_TOKENS" \
    CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT= \
    CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1 \
    CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3 \
    ENABLE_TOOL_SEARCH="$CLAUDEX_TOOL_SEARCH" \
    command claude "$@"
  else
    model="${CLAUDEX_MODEL:-$(__claudex_pick)}"
    ANTHROPIC_BASE_URL="$CLAUDEX_BASE_URL" \
    ANTHROPIC_API_KEY= \
    ANTHROPIC_AUTH_TOKEN="$CLAUDEX_API_KEY" \
    CLAUDE_CODE_SUBAGENT_MODEL="$CLAUDEX_SUBAGENT_MODEL" \
    CLAUDE_CODE_SUBAGENT_MODEL_FORCE= \
    CLAUDE_CODE_MAX_CONTEXT_TOKENS="$CLAUDEX_MAX_CONTEXT_TOKENS" \
    CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT= \
    CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1 \
    CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3 \
    ENABLE_TOOL_SEARCH="$CLAUDEX_TOOL_SEARCH" \
    command claude --model "$model" "$@"
  fi
}

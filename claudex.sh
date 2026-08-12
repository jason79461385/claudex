# claudex.sh — run Claude Code against a GPT model served by a local CLIProxyAPI.
#
# Install:  source /path/to/claudex.sh   (from ~/.zshrc or ~/.bashrc)
# Works in zsh and bash.
#
# Environment knobs (all optional):
#   CLAUDEX_BASE_URL        proxy address           (default http://127.0.0.1:8317)
#   CLAUDEX_API_KEY         proxy api key           (default sk-dummy)
#   CLAUDEX_MODEL           pin a model, skips auto-detection
#   CLAUDEX_FALLBACK_MODEL  used when the proxy is unreachable (default gpt-5.6-sol)
#   CLAUDEX_EXCLUDE         regex of model ids to ignore
#   CLAUDEX_TOOL_SEARCH     true|false              (default true)

: "${CLAUDEX_BASE_URL:=http://127.0.0.1:8317}"
: "${CLAUDEX_API_KEY:=sk-dummy}"
: "${CLAUDEX_FALLBACK_MODEL:=gpt-5.6-sol}"
: "${CLAUDEX_EXCLUDE:=image|audio|tts|whisper|transcribe|embed|moderation|realtime|review|search}"
: "${CLAUDEX_TOOL_SEARCH:=true}"

# Chat-capable models the proxy currently serves, newest first.
# Output is "<id>\t<YYYY-MM-DD>". Models released the same day sort alphabetically,
# so the choice stays deterministic instead of depending on API ordering.
__claudex_models() {
  curl -sf --max-time 5 -H "Authorization: Bearer ${CLAUDEX_API_KEY}" \
       "${CLAUDEX_BASE_URL}/v1/models" 2>/dev/null |
  CLAUDEX_EXCLUDE="$CLAUDEX_EXCLUDE" python3 -c '
import datetime, json, os, re, sys
try:
    rows = json.load(sys.stdin).get("data", [])
except Exception:
    sys.exit(1)
skip = re.compile(os.environ["CLAUDEX_EXCLUDE"], re.I)
rows = [m for m in rows if m.get("id") and not skip.search(m["id"])]
rows.sort(key=lambda m: (-int(m.get("created") or 0), m["id"]))
for m in rows:
    day = datetime.date.fromtimestamp(int(m.get("created") or 0)).isoformat()
    print(m["id"] + "\t" + day)
'
}

# The model that would be used right now.
__claudex_pick() {
  local id
  id=$(__claudex_models | head -1 | cut -f1)
  printf '%s\n' "${id:-$CLAUDEX_FALLBACK_MODEL}"
}

claudex() {
  local model="" list a prev="" id day

  if [ "$1" = "--models" ] || [ "$1" = "--list-models" ]; then
    list=$(__claudex_models)
    if [ -z "$list" ]; then
      echo "claudex: cannot reach CLIProxyAPI at ${CLAUDEX_BASE_URL}" >&2
      echo "         macOS: brew services restart cliproxyapi" >&2
      echo "         Linux: systemctl --user restart cli-proxy-api" >&2
      return 1
    fi
    model="${CLAUDEX_MODEL:-$(printf '%s\n' "$list" | head -1 | cut -f1)}"
    printf '%s\n' "$list" | while IFS="$(printf '\t')" read -r id day; do
      if [ "$id" = "$model" ]; then
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
    ANTHROPIC_AUTH_TOKEN="$CLAUDEX_API_KEY" \
    CLAUDE_CODE_SUBAGENT_MODEL="$model" \
    CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1 \
    CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3 \
    ENABLE_TOOL_SEARCH="$CLAUDEX_TOOL_SEARCH" \
    command claude "$@"
  else
    model="${CLAUDEX_MODEL:-$(__claudex_pick)}"
    ANTHROPIC_BASE_URL="$CLAUDEX_BASE_URL" \
    ANTHROPIC_AUTH_TOKEN="$CLAUDEX_API_KEY" \
    CLAUDE_CODE_SUBAGENT_MODEL="$model" \
    CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1 \
    CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3 \
    ENABLE_TOOL_SEARCH="$CLAUDEX_TOOL_SEARCH" \
    command claude --model "$model" "$@"
  fi
}

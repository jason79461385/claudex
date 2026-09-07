# claudemini.sh — run Claude Code against a GEMINI model served by a local CLIProxyAPI.
#
# Sibling of claudex.sh. Same proxy, same port; the only real difference is that
# this one filters the catalogue DOWN TO Gemini, because one CLIProxyAPI instance
# serves GPT and Gemini side by side and "newest model" would otherwise pick a GPT.
#
# Install:  source /path/to/claudemini.sh   (from ~/.zshrc or ~/.bashrc)
# Works in zsh and bash.
#
# Environment knobs (all optional):
#   CLAUDEMINI_BASE_URL        proxy address          (default http://127.0.0.1:8317)
#   CLAUDEMINI_API_KEY         proxy api key          (default sk-dummy)
#   CLAUDEMINI_MODEL           pin the primary model, skips auto-detection
#   CLAUDEMINI_SUBAGENT_MODEL  model for spawned agents (default: same as primary)
#   CLAUDEMINI_SUBAGENT_FORCE  1 makes the line above beat per-agent model
#                              overrides (default 1)
#   CLAUDEMINI_MAX_CONTEXT_TOKENS  context window     (default 1000000)
#   CLAUDEMINI_FALLBACK_MODEL  used when the proxy is unreachable
#   CLAUDEMINI_INCLUDE         regex a model id MUST match to be usable
#   CLAUDEMINI_EXCLUDE         regex of model ids to ignore
#   CLAUDEMINI_TOOL_SEARCH     true|false             (default true)
#   CLAUDEMINI_DISALLOW        tools withheld from the request (default Artifact)
#
# Why Artifact is withheld by default
# -----------------------------------
# Its `query.where` parameter is a tuple schema written with JSON Schema 2020-12
# `prefixItems`:
#     "where": {"type":"array","items":{"type":"array","prefixItems":[...]}}
# Gemini's function-calling validator knows only `items`, so the inner array
# looks like an array with no element type and the whole request 400s with
#     function_declarations[N].parameters.properties[query]
#       .properties[where].items.items: missing field
# before a single token is generated. Measured: --disallowedTools removes the
# declaration from the outgoing payload (not just the permission to run it), so
# withholding this one tool is enough. Drop the knob to "" once Gemini accepts
# prefixItems or the tool's schema changes.

: "${CLAUDEMINI_BASE_URL:=http://127.0.0.1:8317}"
: "${CLAUDEMINI_API_KEY:=sk-dummy}"
: "${CLAUDEMINI_SUBAGENT_MODEL:=}"
: "${CLAUDEMINI_SUBAGENT_FORCE:=1}"
: "${CLAUDEMINI_MAX_CONTEXT_TOKENS:=1000000}"
: "${CLAUDEMINI_FALLBACK_MODEL:=gemini-3.1-pro-preview}"
# The positive filter is what makes this script different from claudex: the same
# proxy serves gpt-* and gemini-* together, so "newest usable id" is not enough.
: "${CLAUDEMINI_INCLUDE:=gemini|antigravity}"
: "${CLAUDEMINI_EXCLUDE:=image|audio|tts|whisper|transcribe|embed|moderation|realtime|review|search}"
: "${CLAUDEMINI_TOOL_SEARCH:=true}"
: "${CLAUDEMINI_DISALLOW:=Artifact}"

# Every model the proxy serves, newest first.
# Output is "<id>\t<YYYY-MM-DD>\t<ok|skip>". "skip" marks ids that either fail
# CLAUDEMINI_INCLUDE (not a Gemini) or match CLAUDEMINI_EXCLUDE (not a chat model).
# Models released the same day sort alphabetically, so the choice stays
# deterministic instead of depending on API ordering.
__claudemini_models() {
  curl -sf --max-time 5 -H "Authorization: Bearer ${CLAUDEMINI_API_KEY}" \
       "${CLAUDEMINI_BASE_URL}/v1/models" 2>/dev/null |
  CLAUDEMINI_INCLUDE="$CLAUDEMINI_INCLUDE" CLAUDEMINI_EXCLUDE="$CLAUDEMINI_EXCLUDE" python3 -c '
import datetime, json, os, re, sys
try:
    rows = json.load(sys.stdin).get("data", [])
except Exception:
    sys.exit(1)
keep = re.compile(os.environ["CLAUDEMINI_INCLUDE"], re.I)
skip = re.compile(os.environ["CLAUDEMINI_EXCLUDE"], re.I)
rows = [m for m in rows if m.get("id")]

def version(mid):
    # The Antigravity catalogue reports created=0 for every Gemini, so sorting by
    # date degrades to alphabetical and "newest" picks gemini-3-flash over
    # gemini-3.8-flash-high. Rank on the version number in the id instead, and
    # put ids that carry no version (e.g. gemini-pro-agent) last rather than
    # guessing where they belong.
    m = re.search(r"(\d+)(?:\.(\d+))?", mid)
    return (int(m.group(1)), int(m.group(2) or 0)) if m else (-1, -1)

rows.sort(key=lambda m: (-int(m.get("created") or 0),
                         tuple(-v for v in version(m["id"])),
                         m["id"]))
for m in rows:
    created = int(m.get("created") or 0)
    day = datetime.date.fromtimestamp(created).isoformat() if created else "(no date)"
    usable = keep.search(m["id"]) and not skip.search(m["id"])
    print(m["id"] + "\t" + day + "\t" + ("ok" if usable else "skip"))
'
}

# The model that would be used right now: newest usable one.
__claudemini_pick() {
  local id
  id=$(__claudemini_models | awk -F'\t' '$3=="ok"{print $1; exit}')
  printf '%s\n' "${id:-$CLAUDEMINI_FALLBACK_MODEL}"
}

claudemini() {
  local model="" list a prev="" id day kind showall="" sub

  case "$1" in
    --models|--list-models) showall="" ;;
    --models-all)           showall="yes" ;;
  esac

  if [ -n "$showall" ] || [ "$1" = "--models" ] || [ "$1" = "--list-models" ]; then
    list=$(__claudemini_models)
    if [ -z "$list" ]; then
      echo "claudemini: cannot reach CLIProxyAPI at ${CLAUDEMINI_BASE_URL}" >&2
      echo "            macOS: brew services restart cliproxyapi" >&2
      echo "            Linux: systemctl --user restart cli-proxy-api" >&2
      return 1
    fi
    model="${CLAUDEMINI_MODEL:-$(__claudemini_pick)}"
    if ! printf '%s\n' "$list" | awk -F'\t' '$3=="ok"{found=1} END{exit !found}'; then
      echo "claudemini: the proxy serves no Gemini model." >&2
      echo "            Add a credential, then restart the service:" >&2
      echo "              cliproxyapi -antigravity-login     # OAuth, gives Gemini 3.x Pro" >&2
      echo "              # or put a key under gemini-api-key: in the proxy config" >&2
      echo "            Listing everything it DOES serve:" >&2
      # Without this, the list below prints nothing at all — every id the proxy
      # has is a "skip" here, and a bare --models hides skips.
      showall="yes"
    fi
    printf '%s\n' "$list" | while IFS="$(printf '\t')" read -r id day kind; do
      if [ "$kind" = "skip" ]; then
        [ -n "$showall" ] && printf '  %-28s %s   (not a usable Gemini chat model, skipped)\n' "$id" "$day"
      elif [ "$id" = "$model" ]; then
        printf '  %-28s %s   <- claudemini uses this\n' "$id" "$day"
      else
        printf '  %-28s %s\n' "$id" "$day"
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
    model="${CLAUDEMINI_MODEL:-$(__claudemini_pick)}"
    set -- --model "$model" "$@"
  fi

  # Subagents default to the SAME model as the session, so "everything is Gemini
  # on a 1M window" holds without naming the id twice.
  sub="${CLAUDEMINI_SUBAGENT_MODEL:-$model}"

  # See the header: Artifact's prefixItems tuple schema 400s the whole request.
  if [ -n "$CLAUDEMINI_DISALLOW" ]; then
    set -- --disallowedTools "$CLAUDEMINI_DISALLOW" "$@"
  fi

  # CLAUDE_CODE_MAX_CONTEXT_TOKENS is process-wide: subagents run inside this same
  # CLI process, so one value covers the main session and every spawned agent.
  # There is no separate subagent-context knob in the CLI.
  ANTHROPIC_BASE_URL="$CLAUDEMINI_BASE_URL" \
  ANTHROPIC_AUTH_TOKEN="$CLAUDEMINI_API_KEY" \
  CLAUDE_CODE_SUBAGENT_MODEL="$sub" \
  CLAUDE_CODE_SUBAGENT_MODEL_FORCE="$CLAUDEMINI_SUBAGENT_FORCE" \
  CLAUDE_CODE_MAX_CONTEXT_TOKENS="$CLAUDEMINI_MAX_CONTEXT_TOKENS" \
  CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1 \
  CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3 \
  ENABLE_TOOL_SEARCH="$CLAUDEMINI_TOOL_SEARCH" \
  command claude "$@"
}

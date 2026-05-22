#!/usr/bin/env bash
# Sandbox validation harness: emit every runtime's config from representative
# agent.json fixtures and confirm each is well-formed and matches that runtime's
# expected shape — and that no secret ever leaks into emitted output.
#
#   bash tests/sandbox/validate.sh            # builds + validates
#   bash tests/sandbox/validate.sh /path/to/mc
#
# Uses jq (JSON) and python3 (YAML) for real parsing. Real-runtime schema
# validators (openclaw zod, ax Go loader, …) can be plugged into validate_*().
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MC="${1:-$REPO/zig-out/bin/mc}"
FIX="$REPO/tests/sandbox/fixtures"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

[ -x "$MC" ] || { echo "building mc…"; ( cd "$REPO" && zig build ) || exit 1; }
command -v jq      >/dev/null || { echo "jq required"; exit 2; }
command -v python3 >/dev/null || { echo "python3 required"; exit 2; }

SBX="$(mktemp -d /tmp/mc-sandbox-XXXX)"; trap 'rm -rf "$SBX"' EXIT
( cd "$SBX" && "$MC" init --name sandbox >/dev/null )

install_agent() { # <fixture-file> -> agent name (from .name)
  local f="$1" name; name="$(jq -r .name "$f")"
  mkdir -p "$SBX/agents/$name"
  cp "$f" "$SBX/agents/$name/agent.json"
  printf '# %s\n\nYou are %s.\n' "$name" "$name" > "$SBX/agents/$name/prompt.md"
  echo "$name"
}
emit() { ( cd "$SBX" && "$MC" agent emit "$1" --target "$2" 2>/dev/null ); }   # name target -> stdout
jq_has() { echo "$1" | jq -e "$2" >/dev/null 2>&1; }                            # json filter
yaml_ok() { printf '%s' "$1" | python3 -c 'import yaml,sys; yaml.safe_load(sys.stdin)' >/dev/null 2>&1; }
yaml_get() { printf '%s' "$1" | python3 -c "import yaml,sys; d=yaml.safe_load(sys.stdin); print(eval(\"d$2\"))" 2>/dev/null; }
no_secret() { ! grep -qE 'sk-[A-Za-z0-9_-]{12,}|AKIA[0-9A-Z]{16}|-----BEGIN' <<<"$1"; }

# A target-shaped check: <label> <json|yaml|md> <output> <test-expr...>
check() {
  local label="$1" fmt="$2" out="$3"; shift 3
  [ -n "$out" ] || { bad "$label: empty output"; return; }
  no_secret "$out" || { bad "$label: SECRET LEAKED in output"; return; }
  case "$fmt" in
    json) jq_has "$out" "." >/dev/null 2>&1 || { bad "$label: invalid JSON"; return; } ;;
    yaml) yaml_ok "$out" || { bad "$label: invalid YAML"; return; } ;;
    md)   [[ "$out" == ---* ]] || { bad "$label: not a frontmatter doc"; return; } ;;
  esac
  ok "$label"
}

echo "=== fixture: full.json (all 6 targets) ==="
N="$(install_agent "$FIX/full.json")"
M="$(emit "$N" managed)";  check "managed: well-formed"  json "$M"
jq_has "$M" '.name=="reviewer" and (.model|type)=="object" and (.tools|length)>=1' && ok "managed: name+model{id,speed}+tools" || bad "managed: shape"
C="$(emit "$N" claude)";   check "claude: subagent md"   md   "$C"
grep -q '^name: reviewer$' <<<"$C" && grep -q '^model: opus$' <<<"$C" && ok "claude: frontmatter name+model alias" || bad "claude: frontmatter"
O="$(emit "$N" openclaw)"; check "openclaw: well-formed" json "$O"
jq_has "$O" '.id=="reviewer" and .thinkingDefault=="high"' && ok "openclaw: id+thinkingDefault" || bad "openclaw: shape"
H="$(emit "$N" hermes)";   check "hermes: well-formed"   yaml "$H"
[ "$(yaml_get "$H" "['model']['default']")" = "claude-opus-4-7" ] && ok "hermes: model.default" || bad "hermes: model.default"
G="$(emit "$N" google)";   check "google: well-formed"   yaml "$G"
[ "$(yaml_get "$G" "['planner']['gemini']['model']")" = "claude-opus-4-7" ] && ok "google: planner.gemini.model" || bad "google: planner"
P="$(emit "$N" pi)";       check "pi: well-formed"       json "$P"
jq_has "$P" '.providers.anthropic.models[0].id=="claude-opus-4-7"' && ok "pi: providers.<p>.models[0].id" || bad "pi: shape"

echo "=== fixture: pi-local.json (pi pinned config; --out without key) ==="
N="$(install_agent "$FIX/pi-local.json")"
P="$(emit "$N" pi)"; check "pi-local: well-formed" json "$P"
jq_has "$P" '.providers["local-llm"].baseUrl=="https://ai.starflinger.eu" and .providers["local-llm"].models[0].id=="minimax-m2.7" and (.providers["local-llm"].apiKey==null)' \
  && ok "pi-local: exact provider+model, no key in stdout" || bad "pi-local: shape"
OUT="$SBX/out-pi"; ( cd "$SBX" && env -u LITELLM_KEY "$MC" agent emit "$N" --target pi --out "$OUT" >/dev/null 2>&1 )
[ -f "$OUT/.pi/agent/models.json" ] && [ -f "$OUT/.pi/agent/settings.json" ] && ok "pi-local --out: materialized .pi/agent/{models,settings}.json" || bad "pi-local --out: files"
jq -e '.defaultProvider=="local-llm" and .defaultModel=="minimax-m2.7"' "$OUT/.pi/agent/settings.json" >/dev/null 2>&1 && ok "pi-local --out: settings pins defaults" || bad "pi-local --out: settings"
no_secret "$(cat "$OUT/.pi/agent/models.json")" && ! grep -q apiKey "$OUT/.pi/agent/models.json" && ok "pi-local --out: no key baked (env unset)" || bad "pi-local --out: key handling"

echo "=== fixture: ax-gemini.json (google AX) ==="
N="$(install_agent "$FIX/ax-gemini.json")"
G="$(emit "$N" google)"; check "ax: well-formed" yaml "$G"
[ "$(yaml_get "$G" "['planner']['gemini']['model']")" = "gemini-3.5-flash" ] && ok "ax: gemini model" || bad "ax: model"
[ "$(yaml_get "$G" "['registry']['remote_agents'][0]['id']")" = "weather" ] && ok "ax: registry entry id" || bad "ax: registry"

echo
echo "validated: $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]

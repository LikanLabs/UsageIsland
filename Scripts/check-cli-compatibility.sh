#!/bin/bash
# Early warning: checks that a Codex CLI and a Claude Code CLI still offer
# what Usage Island reads, without signing in to either one.
#
#   Scripts/check-cli-compatibility.sh <codex> <claude> [<claude files>]
#
# Codex describes its own protocol, so its generated schema is checked field
# by field. Claude Code publishes no schema: its flags are checked from
# --help, and the names of the fields the app reads are looked for inside the
# program itself (<claude files>: a file or directory, by default the
# resolved <claude>). A name that is gone means the answer changed shape.
# Exits 1 listing everything that is missing.
set -uo pipefail

codex="${1:?path to the codex executable}"
claude="${2:?path to the claude executable}"
claude_files="${3:-$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$claude")}"
failures=0
fail() {
    printf 'MISSING: %s\n' "$1"
    failures=$((failures + 1))
}

printf 'Codex: %s\n' "$("$codex" --version 2>/dev/null || echo unknown)"
schema="$(mktemp -d)"
trap 'rm -rf "$schema"' EXIT
if "$codex" app-server generate-json-schema --out "$schema" >/dev/null 2>&1; then
    if ! python3 - "$schema" <<'PY'
import json, os, sys

root = sys.argv[1]
missing = []

def load(name):
    try:
        with open(os.path.join(root, name)) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        missing.append("schema file " + name)
        return {}

def need(schema, where, definition, names):
    node = schema if definition is None else schema.get("definitions", {}).get(definition, {})
    properties = node.get("properties", {})
    for name in names:
        if name not in properties:
            missing.append("%s: %s.%s" % (where, definition or "response", name))

limits = load("v2/GetAccountRateLimitsResponse.json")
need(limits, "rate limits", None, ["rateLimits", "rateLimitsByLimitId", "rateLimitResetCredits"])
need(limits, "rate limits", "RateLimitSnapshot",
     ["primary", "secondary", "limitName", "planType", "rateLimitReachedType"])
need(limits, "rate limits", "RateLimitWindow", ["usedPercent", "windowDurationMins", "resetsAt"])
need(limits, "rate limits", "RateLimitResetCreditsSummary", ["availableCount", "credits"])
need(limits, "rate limits", "RateLimitResetCredit", ["expiresAt", "status"])

account = load("v2/GetAccountResponse.json")
need(account, "account", None, ["account", "requiresOpenaiAuth"])
if '"chatgpt"' not in json.dumps(account) or '"planType"' not in json.dumps(account):
    missing.append("account: ChatGPT account with planType")

requests = json.dumps(load("ClientRequest.json"))
for method in ["initialize", "account/read", "account/rateLimits/read"]:
    if '"%s"' % method not in requests:
        missing.append("request " + method)
if '"initialized"' not in json.dumps(load("ClientNotification.json")):
    missing.append("notification initialized")

for item in missing:
    print("MISSING: Codex " + item)
sys.exit(1 if missing else 0)
PY
    then failures=$((failures + 1)); fi
else
    fail "Codex could not generate its schema (codex app-server generate-json-schema)"
fi

printf 'Claude Code: %s\n' "$("$claude" --version 2>/dev/null || echo unknown)"
help="$("$claude" --help 2>/dev/null)"
for flag in --restricted --strict-mcp-config --no-session-persistence --tools \
    --input-format --output-format --verbose --print; do
    grep -q -- "$flag" <<<"$help" || fail "Claude Code flag $flag"
done
"$claude" auth status --help 2>/dev/null | grep -q -- '--json' || fail "Claude Code: auth status --json"
for name in get_usage skip_behaviors rate_limits_available rate_limits resets_at \
    weekly_all weekly_scoped display_name loggedIn loginExpiresAt; do
    LC_ALL=C grep -r -a -q -F -- "$name" "$claude_files" || fail "Claude Code field $name"
done

if [[ "$failures" -gt 0 ]]; then
    printf '\n%d check(s) failed: a CLI no longer offers something Usage Island reads.\n' "$failures"
    exit 1
fi
printf 'Both CLIs still offer everything Usage Island reads.\n'

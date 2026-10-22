#!/usr/bin/env bash
# Runs the action's "Export secrets" step against a murk 0.14+ vault, the way
# a fresh CI runner would: no trust pin, trust only from trusted-signers or
# from a grant key file's own "# murk-trusted-signer:" lines.
#
# Needs murk 0.14 or later on PATH and ruby (to read the step from action.yml).
# Keys are generated per run in a temporary directory and never committed.
set -euo pipefail

ACTION_YML="$(cd "$(dirname "$0")/.." && pwd)/action.yml"
WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/murk-action-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

FAILED=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

murk --version

# The step's script, exactly as the action runs it.
ruby -ryaml -e '
  step = YAML.load_file(ARGV[0])["runs"]["steps"].find { |s| s["id"] == "export" }
  print step["run"]
' "$ACTION_YML" > "$WORK/export.sh"

# Create a key in its own HOME and print its MURK_KEY.
new_key() {
  local home="$WORK/$1-home" dir="$WORK/$1"
  mkdir -p "$home" "$dir"
  (cd "$dir" && echo "$1" | HOME="$home" murk init --vault "$1.murk" >/dev/null 2>&1)
  cat "$(sed -n "s/^export MURK_KEY_FILE='\\(.*\\)'/\\1/p" "$dir/.env")"
}

# The signer's trusted-signers entry, as `murk trust --print-key` prints it.
entry_for() {
  (cd "$WORK" && HOME="$WORK/$1-home" MURK_KEY="$2" murk trust --print-key 2>/dev/null)
}

AUTHOR_KEY=$(new_key author)
OTHER_KEY=$(new_key other)
VAULT="$WORK/author/author.murk"
AUTHOR_ENTRY=$(entry_for author "$AUTHOR_KEY") || { echo "murk on PATH has no 'trust --print-key': this test needs murk 0.14 or later"; exit 2; }
OTHER_ENTRY=$(entry_for other "$OTHER_KEY")
echo "hello_world" | HOME="$WORK/author-home" MURK_KEY="$AUTHOR_KEY" murk add GREETING --vault "$VAULT" >/dev/null 2>&1
echo "not_granted" | HOME="$WORK/author-home" MURK_KEY="$AUTHOR_KEY" murk add OTHER --vault "$VAULT" >/dev/null 2>&1

# A whole grant key file: "# murk-..." lines above the key line.
GRANT_FILE=$(cd "$WORK" && HOME="$WORK/author-home" MURK_KEY="$AUTHOR_KEY" \
  murk agent grant --name ci --only GREETING --ttl 1h --out - --vault "$VAULT" 2>/dev/null)
GRANT_LINE=$(grep '^AGE-SECRET-KEY-1' <<<"$GRANT_FILE")

# Run the export step on a fresh runner (empty HOME). Sets RC, OUT, GH_ENV.
run_export() {
  local name=$1 signers=$2 key=${3:-$AUTHOR_KEY} runner="$WORK/runner-$1"
  mkdir -p "$runner/home" "$runner/tmp"
  GH_ENV="$runner/github_env"
  : > "$GH_ENV"
  : > "$runner/github_output"
  set +e
  OUT=$(env -u MURK_TRUSTED_SIGNERS -u MURK_KEY_FILE \
    HOME="$runner/home" RUNNER_TEMP="$runner/tmp" \
    GITHUB_ENV="$GH_ENV" GITHUB_OUTPUT="$runner/github_output" \
    MURK_KEY="$key" INPUT_VAULT="$VAULT" INPUT_TAGS="" \
    INPUT_TRUSTED_SIGNERS="$signers" \
    bash "$WORK/export.sh" 2>&1)
  RC=$?
  set -e
  echo "--- $name (exit $RC)"
  echo "$OUT"
}

run_export unset ""
if [ "$RC" -ne 0 ] && grep -q '^::error::.*Set the trusted-signers input' <<<"$OUT"; then
  pass "input unset: refused with a trusted-signers hint"
else
  fail "input unset: expected a refusal naming trusted-signers"
fi

run_export wrong "$OTHER_ENTRY"
if [ "$RC" -ne 0 ] && grep -q '^::error::.*does not match trusted-signers' <<<"$OUT" \
  && ! grep -q '^GREETING<<' "$GH_ENV"; then
  pass "wrong signer: refused"
else
  fail "wrong signer: expected a refusal"
fi

run_export trusted "$OTHER_ENTRY
$AUTHOR_ENTRY"
if [ "$RC" -eq 0 ] && grep -qx 'hello_world' "$GH_ENV"; then
  pass "trusted signer: secrets loaded"
else
  fail "trusted signer: expected GREETING in GITHUB_ENV"
fi

run_export grant-file "" "$GRANT_FILE"
if [ "$RC" -eq 0 ] && grep -qx 'hello_world' "$GH_ENV" && ! grep -q '^OTHER<<' "$GH_ENV"; then
  pass "grant key file: its own signers suffice, only granted secrets loaded"
else
  fail "grant key file: expected only GREETING in GITHUB_ENV"
fi
if grep -F "$GRANT_LINE" <<<"$OUT" | grep -qv '^::add-mask::'; then
  fail "grant key file: the secret line reached the log unmasked"
else
  pass "grant key file: the secret line is only ever masked"
fi

run_export grant-crlf "" "${GRANT_FILE//$'\n'/$'\r\n'}"$'\r'
if [ "$RC" -eq 0 ] && grep -qx 'hello_world' "$GH_ENV"; then
  pass "grant key file with CRLF line endings: loaded"
else
  fail "grant key file with CRLF line endings: expected GREETING in GITHUB_ENV"
fi

run_export grant-bare "" "$GRANT_LINE"
if [ "$RC" -ne 0 ] && grep -q '^::error::.*Paste the whole key file' <<<"$OUT"; then
  pass "bare grant key line without trusted-signers: refused with a hint"
else
  fail "bare grant key line without trusted-signers: expected a refusal"
fi

# shellcheck disable=SC2001
run_export grant-expired "" "$(sed 's/^# murk-grant-expires: .*/# murk-grant-expires: 2020-01-01T00:00:00Z/' <<<"$GRANT_FILE")"
if [ "$RC" -ne 0 ] && grep -q "key file's expiry" <<<"$OUT" && ! grep -q '^GREETING<<' "$GH_ENV"; then
  pass "grant key file past its own expiry: refused"
else
  fail "grant key file past its own expiry: expected a refusal"
fi

run_export not-a-key "" "# murk-grant-id: ci
not-a-key"
if [ "$RC" -ne 0 ] && grep -q '^::error::murk-key must be' <<<"$OUT" && ! grep -q 'not-a-key' <<<"$OUT"; then
  pass "malformed key: refused without echoing it"
else
  fail "malformed key: expected a refusal that does not echo the input"
fi

exit "$FAILED"

#!/bin/sh
# Offline checks for the guardrails plugin scripts, using a fake CLI. Run: sh tests/guardrails_scripts_test.sh

set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
scripts="${root}/plugins/guardrails/scripts"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

check() {
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected [$3], got [$2]"
    failures=$((failures + 1))
  fi
}

export HOME="${work}/home"
state="${HOME}/.konvu/guardrails"
project="${work}/project"
mkdir -p "${state}/bin/v9.9.9" "${state}/profiles/repo_1" "${state}/logs" "$project"
git -C "$project" init -q
project="$(git -C "$project" rev-parse --show-toplevel)"
export CLAUDE_PROJECT_DIR="$project"

fake="${state}/bin/v9.9.9/guardrails"
cat >"$fake" <<'EOF'
#!/bin/sh
echo "$* SECPROFILE_DIR=${SECPROFILE_DIR-<unset>} ROOT=${CLAUDE_PROJECT_DIR:-}" >>"$HOME/calls"
echo "$1 $2 ENFORCE=${SECPROFILE_ENFORCE-<unset>} BLOCK=${SECPROFILE_BLOCK_LINES-<unset>} UNATTENDED=${SECPROFILE_UNATTENDED-<unset>}" >>"$HOME/envs"
if [ "$1" = auth ] || [ "$1" = sync ]; then
  echo "${GUARDRAILS_PLUGIN_VERSION-<unset>}" >>"$HOME/plugin_versions"
fi
case "${FAKE_MODE:-ok}" in
  ok) echo '{"hookSpecificOutput":{}}' ;;
  off) [ "$1" = hook ] && [ "${3:-}" = --synced ] && exit 0
       echo '{"hookSpecificOutput":{}}' ;;
  block) echo "blocked" >&2; exit 2 ;;
  crash) exit 101 ;;
  slow) sleep 3 ;;
  slowflush) if [ "$1" = flush ]; then sleep 3; touch "$HOME/slow-flush-complete"; fi ;;
  usage) printf 'guardrails \342\200\224 security profile enforcement for coding agents\n\n  guardrails hook <session-start|pre-edit>\n' >&2; exit 2 ;;
  quoted) printf '[secprofile] Before finishing, resolve these:\n  - x\n  guardrails hook <y.py: hit\n' >&2; exit 2 ;;
  noauth) [ "$1" = auth ] && exit 3 ;;
  refused) [ "$1" = auth ] && exit 4 ;;
  authtransient) [ "$1" = auth ] && exit 5 ;;
  syncfail) [ "$1" = sync ] && exit 5 ;;
  recover) [ "$1" = sync ] && rm -f "$HOME/.konvu/guardrails/auth-quarantine" ;;
esac
exit 0
EOF
chmod 0755 "$fake"
# A CLI from before `hook <mode> --synced`, which the plugin gates on the project's checkout.
legacy="${state}/bin/v0.6.31/guardrails"
mkdir -p "${legacy%/guardrails}"
cp "$fake" "$legacy"

# A prefix assignment before a function call persists in POSIX sh, so modes are set and reset here.
with_mode() {
  FAKE_MODE="$1"
  export FAKE_MODE
  shift
  "$@"
  rc=$?
  FAKE_MODE=ok
  return "$rc"
}

wrap() {
  out="$(echo '{}' | sh "${scripts}/guardrails.sh" "$@" 2>/dev/null)"
  status=$?
}

in_project() {
  CLAUDE_PROJECT_DIR="$1"
  shift
  "$@"
  CLAUDE_PROJECT_DIR="$project"
}

# Writes repos.json as the CLI's serde_json pretty printer does: checkout key $1 (given
# JSON-encoded) maps to a remote whose repository_id is the JSON value $2.
write_index() {
  cat >"${state}/repos.json" <<JSON
{
  "remotes": {
    "https://github.com/acme/app": {
      "repository_id": $2,
      "resolved_at": 1759600000
    },
    "https://github.com/acme/other": {
      "repository_id": "repo_x",
      "resolved_at": 1759600000
    }
  },
  "roots": {
    "/elsewhere": "https://github.com/acme/other",
    "$1": "https://github.com/acme/app"
  }
}
JSON
}

wrap hook pre-edit
check "no CLI installed fails open" "${status}:${out}" "0:"

echo v0.6.31 >"${state}/bin/current"
wrap hook pre-edit
check "an older CLI without repos.json fails open" "${status}:${out}" "0:"

write_index "${project}2" '"repo_1"'
wrap hook pre-edit
check "a recorded root that only starts with the checkout path is not used" "${status}:${out}" "0:"

# The escaped targets exist, so only the validators keep them from being used.
mkdir -p "${state}/escaped/v0.6.31" "${state}/v0.6.31"
cp "$fake" "${state}/v0.6.31/guardrails"
cp "$fake" "${state}/escaped/v0.6.31/guardrails"
write_index "$project" '"../escaped"'
wrap hook pre-edit
check "path traversal repository id is refused" "${status}:${out}" "0:"

write_index "$project" null
wrap hook pre-edit
check "a remote Konvu does not know fails open" "${status}:${out}" "0:"

write_index "$project" '"repo_missing"'
wrap hook pre-edit
check "missing profile fails open" "${status}:${out}" "0:"

write_index "$project" '"repo_1"'
rm -f "${HOME}/calls"
printf 'off\n' >"${state}/steering-state"
for mode in prompt-submit pre-command pre-edit post-edit; do
  wrap hook "$mode"
  check "off suppresses old CLI $mode" "${status}:${out}" "0:"
done
wrap stop
check "off suppresses old CLI final sweep" "${status}:${out}" "0:"
sleep 1
check "off never invokes the old CLI or starts Stop flush" "$(cat "${HOME}/calls" 2>/dev/null)" ""
touch "${state}/logs/.run.old"
touch -t 200001010000 "${state}/logs/.run.old"
wrap stop
sleep 1
check "off does not launch a cleanup worker" "$([ -f "${state}/logs/.run.old" ] && echo kept || echo removed)" "kept"
rm -f "${state}/logs/.run.old"
sh "${scripts}/worker.sh" flush
check "off skips a direct flush" "$(cat "${HOME}/calls" 2>/dev/null)" ""
printf 'off\nextra\n' >"${state}/steering-state"
wrap hook pre-edit
check "malformed steering state defaults on" "${status}:${out}" '0:{"hookSpecificOutput":{}}'
printf 'on\n' >"${state}/steering-state"
rm -f "${HOME}/calls"
printf 'off\n' >"${state}/auth-quarantine"
for mode in prompt-submit pre-command pre-edit post-edit; do
  wrap hook "$mode"
  check "quarantine suppresses old CLI $mode" "${status}:${out}" "0:"
done
wrap stop
check "quarantine suppresses old CLI final sweep" "${status}:${out}" "0:"
sleep 1
sh "${scripts}/worker.sh" flush
check "quarantine skips Stop and direct flush" "$(cat "${HOME}/calls" 2>/dev/null)" ""
printf 'broken\n' >"${state}/auth-quarantine"
wrap hook pre-edit
check "a malformed quarantine marker still suppresses hooks" "${status}:${out}" "0:"
rm -f "${state}/auth-quarantine"
ln -s "${work}/missing-quarantine-target" "${state}/auth-quarantine"
wrap hook pre-edit
check "a dangling quarantine marker still suppresses hooks" "${status}:${out}" "0:"
rm -f "${state}/auth-quarantine"
printf '1\n' >"${state}/authorization-expires-at"
wrap hook pre-edit
check "expired lease suppresses old CLI hooks" "${status}:${out}" "0:"
sh "${scripts}/worker.sh" flush
check "expired lease suppresses old CLI flush" "$(cat "${HOME}/calls" 2>/dev/null)" ""
printf 'broken\n' >"${state}/authorization-expires-at"
wrap hook pre-edit
check "malformed lease suppresses old CLI hooks" "${status}:${out}" "0:"
rm -f "${state}/authorization-expires-at"
mkdir "${state}/authorization-expires-at"
wrap hook pre-edit
check "unreadable lease suppresses old CLI hooks" "${status}:${out}" "0:"
rmdir "${state}/authorization-expires-at"
printf '%s\n' "$(($(date +%s) + 600))" >"${state}/authorization-expires-at"
wrap hook pre-edit
check "hook output passes through" "${status}:${out}" '0:{"hookSpecificOutput":{}}'
rm -f "${state}/authorization-expires-at"
check "the CLI gets the checkout root to find its synced profile" "$(cat "${HOME}/calls")" "hook pre-edit SECPROFILE_DIR=<unset> ROOT=${project}"

# A SECPROFILE_DIR left in the environment would win over the synced profile inside the CLI.
rm -f "${HOME}/calls"
SECPROFILE_DIR="${work}/stale"
export SECPROFILE_DIR
wrap hook pre-edit
unset SECPROFILE_DIR
check "an inherited SECPROFILE_DIR does not reach the CLI" "$(cat "${HOME}/calls")" "hook pre-edit SECPROFILE_DIR=<unset> ROOT=${project}"

# Claude Code started in a subdirectory, through a symlink: still the checkout sync recorded.
mkdir -p "${project}/src"
ln -s "${project}/src" "${work}/link"
rm -f "${HOME}/calls"
in_project "${work}/link" wrap hook pre-edit
check "a symlinked subdirectory hands the CLI its checkout root" "$(cat "${HOME}/calls")" "hook pre-edit SECPROFILE_DIR=<unset> ROOT=${project}"

# A checkout path that JSON has to escape.
odd="${work}/we\"ird\\dir"
mkdir -p "$odd"
git -C "$odd" init -q
odd="$(cd "$odd" && pwd -P)"
write_index "$(printf '%s' "$odd" | sed 's/\\/\\\\/g; s/"/\\"/g')" '"repo_1"'
rm -f "${HOME}/calls"
in_project "$odd" wrap hook pre-edit
check "a checkout path with a quote and a backslash is matched" "$(cat "${HOME}/calls" 2>/dev/null)" "hook pre-edit SECPROFILE_DIR=<unset> ROOT=${odd}"
write_index "$project" '"repo_1"'

# From here on the CLI finds each file's repository itself.
echo v9.9.9 >"${state}/bin/current"
rm -f "${HOME}/calls"
wrap hook pre-edit
check "a current CLI is asked to answer only synced repositories" "$(cat "${HOME}/calls")" "hook pre-edit --synced SECPROFILE_DIR=<unset> ROOT=${project}"

with_mode off wrap hook pre-edit
check "an off CLI suppresses a synced hook" "${status}:${out}" "0:"
wrap hook pre-edit
check "a re-enabled CLI resumes the synced hook" "${status}:${out}" '0:{"hookSpecificOutput":{}}'

# A session opened anywhere: no checkout, no repos.json entry for it.
nowhere="${work}/nowhere"
mkdir -p "$nowhere"
rm -f "${HOME}/calls"
in_project "$nowhere" wrap hook post-edit
check "a session outside any checkout still runs the CLI" "$(cat "${HOME}/calls" 2>/dev/null)" "hook post-edit --synced SECPROFILE_DIR=<unset> ROOT=${nowhere}"
rm -f "${state}/repos.json" "${HOME}/calls"
SECPROFILE_DIR="${work}/stale"
export SECPROFILE_DIR
wrap hook pre-edit
unset SECPROFILE_DIR
check "the CLI needs no repos.json entry for the project, nor an inherited SECPROFILE_DIR" "$(cat "${HOME}/calls" 2>/dev/null)" "hook pre-edit --synced SECPROFILE_DIR=<unset> ROOT=${project}"
write_index "$project" '"repo_1"'

mv "${state}/profiles" "${work}/profiles.saved"
mkdir -p "${state}/profiles/.repo_1.gen-1" "${state}/profiles/bad id"
rm -f "${HOME}/calls"
wrap hook pre-edit
check "without any synced profile the CLI is not run" "${status}:${out}:$(cat "${HOME}/calls" 2>/dev/null)" "0::"
wrap session-end
check "session-end still reaches the CLI after the profiles went" "$(grep -c '^hook session-end --synced' "${HOME}/calls" 2>/dev/null)" "1"
rm -rf "${state:?}/profiles"
mv "${work}/profiles.saved" "${state}/profiles"

# Refusals travel as JSON on stdout; an exit code never holds Claude Code.
with_mode block wrap hook pre-edit
check "CLI exit 2 fails open" "$status" "0"
reason="$(echo '{}' | with_mode block sh "${scripts}/guardrails.sh" hook pre-edit 2>&1 >/dev/null)"
check "the CLI's stderr never reaches Claude Code" "$reason" ""

with_mode crash wrap hook post-edit
check "CLI crash fails open" "$status" "0"

with_mode usage wrap hook post-edit
check "CLI without this hook mode fails open" "$status" "0"

rm -f "${HOME}/calls" "${HOME}/envs"
SECPROFILE_BLOCK_LINES=1 SECPROFILE_UNATTENDED=1
export SECPROFILE_BLOCK_LINES SECPROFILE_UNATTENDED
for mode in prompt-submit pre-edit post-edit; do
  wrap hook "$mode"
done
unset SECPROFILE_BLOCK_LINES SECPROFILE_UNATTENDED
check "every hook runs enforced, with the measured thresholds" "$(tr '\n' ',' <"${HOME}/envs")" "hook prompt-submit ENFORCE=1 BLOCK=<unset> UNATTENDED=<unset>,hook pre-edit ENFORCE=1 BLOCK=<unset> UNATTENDED=<unset>,hook post-edit ENFORCE=1 BLOCK=<unset> UNATTENDED=<unset>,"

rm -f "${HOME}/calls"
wrap hook pre-command
check "the command hook is not run" "${status}:${out}:$(cat "${HOME}/calls" 2>/dev/null)" "0::"
wrap hook final-sweep
check "the final sweep is not run as a hook either" "${status}:${out}:$(cat "${HOME}/calls" 2>/dev/null)" "0::"

wrap session-end
check "session-end runs through the CLI" "${status}:${out}:$(grep '^hook session-end' "${HOME}/calls" 2>/dev/null)" "0:{\"hookSpecificOutput\":{}}:hook session-end --synced SECPROFILE_DIR=<unset> ROOT=${project}"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '^flush' "${HOME}/calls" 2>/dev/null && break
  sleep 1
done
check "session-end sends the queued events in the background" "$(grep -c '^flush' "${HOME}/calls")" "1"

rm -f "${HOME}/calls"
wrap compact
check "a compaction resets the session through the CLI's compact mode" "$(grep '^hook' "${HOME}/calls" 2>/dev/null)" "hook compact --synced SECPROFILE_DIR=<unset> ROOT=${project}"
mkdir -p "${state}/bin/v0.6.38"
cp "$fake" "${state}/bin/v0.6.38/guardrails"
echo v0.6.38 >"${state}/bin/current"
rm -f "${HOME}/calls"
wrap compact
check "a CLI from before compact resets through session-end, which still deleted the state" "$(grep '^hook' "${HOME}/calls" 2>/dev/null)" "hook session-end --synced SECPROFILE_DIR=<unset> ROOT=${project}"
: >"${HOME}/calls"
wrap session-end
check "ending with an older fallback keeps its refuse-once marks" "$(grep -c '^hook session-end' "${HOME}/calls" 2>/dev/null || true)" "0"
for _ in 1 2 3 4 5; do
  grep -q '^flush' "${HOME}/calls" 2>/dev/null && break
  sleep 1
done
echo v9.9.9 >"${state}/bin/current"
rm -rf "${state:?}/bin/v0.6.38"

wrap hook not-a-mode
check "unknown hook mode is ignored" "${status}:${out}" "0:"

echo "../v9.9.9" >"${state}/bin/current"
wrap hook pre-edit
check "a current version that is not a tag is refused" "${status}:${out}" "0:"
echo "v9.9.9/../../escaped/v9.9.9" >"${state}/bin/current"
wrap hook pre-edit
check "a current version that walks out of bin/ is refused" "${status}:${out}" "0:"
echo v9.9.9 >"${state}/bin/current"

rm -f "${HOME}/calls"
with_mode block wrap stop
check "stop never blocks and says nothing" "${status}:${out}" "0:"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '^flush' "${HOME}/calls" 2>/dev/null && break
  sleep 1
done
check "stop only starts flush in the background, never the final sweep" "$(tr '\n' ',' <"${HOME}/calls" | cut -d' ' -f1)" "flush"

started="$(date +%s)"
# Claude Code reads hook output through pipes, so the detached flush must not hold them open.
with_mode slowflush sh "${scripts}/guardrails.sh" stop </dev/null 2>&1 | cat >/dev/null
check "stop does not wait for a slow flush" "$(($(date +%s) - started < 3))" "1"
# Wait for the slow worker itself, without depending on process-list access.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "${HOME}/slow-flush-complete" ] && break
  sleep 1
done

check "the slow flush completed" "$([ -f "${HOME}/slow-flush-complete" ] && echo yes)" "yes"

# The CLI serializes flushes on its own flush.lock file: the plugin neither collides with it nor
# skips because of it, and removes a stale flush.lock directory plugin 0.0.2 left behind.
rm -f "${HOME}/calls"
: >"${state}/flush.lock"
sh "${scripts}/worker.sh" flush
check "a flush runs beside the CLI's own lock file" "$(grep -c '^flush' "${HOME}/calls")" "1"
rm -f "${state}/flush.lock" "${HOME}/calls"
mkdir "${state}/flush.lock"
echo 999999 >"${state}/flush.lock/pid"
sh "${scripts}/worker.sh" flush
check "a stale flush lock directory from an older plugin is removed" "$([ -d "${state}/flush.lock" ] && echo kept || echo removed):$(grep -c '^flush' "${HOME}/calls")" "removed:1"

# SessionStart returns at once and leaves the work to the detached worker (no install: the lock is held).
mkdir "${state}/install.lock"
echo "$$" >"${state}/install.lock/pid"
rm -f "${HOME}/calls"
started="$(date +%s)"
echo '{}' | with_mode slow sh "${scripts}/session_start.sh" 2>&1 | cat >/dev/null
check "SessionStart does not wait for its background work" "$(($(date +%s) - started < 3))" "1"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '^sync' "${HOME}/calls" 2>/dev/null && break
  sleep 1
done
check "the background work still runs auth and forces sync" "$(cut -d' ' -f1-2 "${HOME}/calls" | tr '\n' ',')" "auth ensure,sync --force,"
check "auth and sync receive the plugin version" "$(sort -u "${HOME}/plugin_versions")" "$(awk -F '"' '$2 == "version" { print $4; exit }' "${root}/plugins/guardrails/.claude-plugin/plugin.json")"

# A compaction resets the session's refuse-once state; a fresh start or a resume does not.
for source in startup resume compact; do
  rm -f "${HOME}/calls"
  printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"%s"}' "$source" | sh "${scripts}/session_start.sh"
  grep -q '^sync' "${HOME}/calls" 2>/dev/null || sleep 2
  check "SessionStart from $source resets the session only after a compaction" "$(grep -c '^hook compact --synced' "${HOME}/calls"):$(grep -c '^hook session-end' "${HOME}/calls")" "$([ "$source" = compact ] && echo 1 || echo 0):0"
done
rm -rf "${state:?}/install.lock"

pinned="$(awk '$1 == "version" { print $2 }' "${root}/plugins/guardrails/pins.txt")"
mkdir -p "${state}/bin/${pinned}"
sed 's/^echo "\$\*/echo "pinned $*/' "$fake" >"${state}/bin/${pinned}/guardrails"
chmod 0755 "${state}/bin/${pinned}/guardrails"
rm -f "${HOME}/calls"
wrap hook pre-edit
check "the plugin's own pinned CLI is preferred over current" "$(grep -c '^pinned hook pre-edit' "${HOME}/calls")" "1"
rm -rf "${state:?}/bin/${pinned:?}"

# A fresh machine whose install is running in another session: wait for its CLI, then auth and sync.
mv "${state}/bin/v9.9.9" "${work}/v9.9.9.saved"
mkdir -p "${state}/install.lock"
echo "$$" >"${state}/install.lock/pid"
rm -f "${HOME}/calls"
(sleep 3; mv "${work}/v9.9.9.saved" "${state}/bin/v9.9.9") &
sh "${scripts}/worker.sh" session-start
wait
check "a session waits for another session's install, then syncs" "$(cut -d' ' -f1-2 "${HOME}/calls" 2>/dev/null | tr '\n' ',')" "auth ensure,sync --force,"
rm -rf "${state:?}/install.lock"

# A fresh machine waiting on an install whose session dies: reclaim its lock, do not wait 6 minutes.
# A fake uname stops the install before any download.
mkdir -p "${work}/fakebin"
printf '#!/bin/sh\necho Plan9\n' >"${work}/fakebin/uname"
chmod 0755 "${work}/fakebin/uname"
mv "${state}/bin/v9.9.9" "${work}/v9.9.9.saved"
sleep 3 &
holder=$!
mkdir -p "${state}/install.lock"
echo "$holder" >"${state}/install.lock/pid"
: >"${state}/logs/plugin.log"
started="$(date +%s)"
PATH="${work}/fakebin:${PATH}" sh "${scripts}/worker.sh" session-start
check "a lock left by an installer that died is reclaimed" "$(($(date +%s) - started < 15)):$(grep -c 'install: unsupported platform Plan9-Plan9\|session-start: no verified CLI' "${state}/logs/plugin.log")" "1:2"
check "the reclaimed install lock is released" "$([ -e "${state}/install.lock" ] && echo held || echo free)" "free"
mv "${work}/v9.9.9.saved" "${state}/bin/v9.9.9"

# From here on this test process holds the install lock, so no session-start downloads anything.
mkdir "${state}/install.lock"
echo "$$" >"${state}/install.lock/pid"
rm -f "${HOME}/calls"
with_mode noauth sh "${scripts}/worker.sh" session-start
check "sync still runs when auth ensure fails" "$(cut -d' ' -f1-2 "${HOME}/calls" | tr '\n' ',')" "auth ensure,sync --force,"

printf 'off\n' >"${state}/steering-state"
rm -f "${HOME}/calls"
sh "${scripts}/worker.sh" session-start
check "off still runs auth and forced sync" "$(cut -d' ' -f1-2 "${HOME}/calls" | tr '\n' ',')" "auth ensure,sync --force,"
printf 'on\n' >"${state}/steering-state"

printf 'off\n' >"${state}/auth-quarantine"
for mode in noauth refused; do
  rm -f "${HOME}/calls"
  with_mode "$mode" sh "${scripts}/worker.sh" session-start
  check "quarantined $mode skips duplicate sync" "$(cut -d' ' -f1-2 "${HOME}/calls" | tr '\n' ',')" "auth ensure,"
done
check "skipped sync is logged privately" "$(grep -c 'sync: skipped while authorization is paused' "${state}/logs/plugin.log")" "2"
rm -f "${HOME}/calls"
with_mode authtransient sh "${scripts}/worker.sh" session-start
check "transient auth failure still tries sync" "$(cut -d' ' -f1-2 "${HOME}/calls" | tr '\n' ',')" "auth ensure,sync --force,"
rm -f "${HOME}/calls"
started="$(date +%s)"
diagnostic="$(sh "${scripts}/session_start.sh" 2>"${work}/session-start-stderr")"
check "quarantine without a recorded cause gives a visible startup message" "$diagnostic" '{"systemMessage":"Konvu Guardrails is paused: checking this computer'"'"'s access in the background."}'
check "quarantine notice does not rely on stderr" "$(cat "${work}/session-start-stderr")" ""
check "quarantine does not delay SessionStart" "$(($(date +%s) - started < 3))" "1"
check "quarantine notice is limited to once per day" "$(sh "${scripts}/session_start.sh" 2>"${work}/session-start-stderr")" ""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "${HOME}/calls" ] && [ "$(grep -c '^sync --force' "${HOME}/calls")" -ge 2 ] && break
  sleep 1
done
check "quarantine still runs auth and sync in the background" "$(grep -c '^auth ensure' "${HOME}/calls"):$(grep -c '^sync --force' "${HOME}/calls")" "2:2"
rm -f "${HOME}/calls"
with_mode syncfail sh "${scripts}/worker.sh" session-start
wrap hook pre-edit
check "failed recovery keeps quarantine" "${status}:${out}:$(test -e "${state}/auth-quarantine" && echo kept)" "0::kept"
with_mode recover sh "${scripts}/worker.sh" session-start
wrap hook pre-edit
check "complete recovery resumes hooks" "${status}:${out}:$(test -e "${state}/auth-quarantine" && echo kept || echo cleared)" '0:{"hookSpecificOutput":{}}:cleared'

# Each cause the CLI records with the pause gets its own notice, still once per UTC day.
notice() {
  rm -rf "${state:?}/notice-days"
  printf 'off\n.auth-quarantine.generation-1\n%s\n' "$1" >"${state}/auth-quarantine"
  sh "${scripts}/session_start.sh" </dev/null 2>/dev/null
}
check "a revoked computer is named" "$(notice computer_revoked)" '{"systemMessage":"Konvu Guardrails is off: your Konvu admin revoked this computer."}'
check "a removed integration is named" "$(notice integration_removed)" '{"systemMessage":"Konvu Guardrails is off: this computer'"'"'s Konvu integration was removed. Ask your admin for the new install snippet."}'
check "a missing deployment key is named" "$(notice deployment_key_missing)" '{"systemMessage":"Konvu Guardrails is off: KONVU_DEPLOYMENT_KEY is not set."}'
for word in credential_revoked credential_expired deployment_key_invalid enrollment_limit access_refused; do
  check "the $word notice is specific" "$(notice "$word" | grep -c 'is off: ')" "1"
done
check "an unknown word never reaches the message" "$(notice 'x","injected":"1')" '{"systemMessage":"Konvu Guardrails is paused: checking this computer'"'"'s access in the background."}'
check "the cause's notice is still once per day" "$(sh "${scripts}/session_start.sh" </dev/null 2>/dev/null)" ""
mkdir -p "${state}/notice-days/20200101"
touch -t 202001010000 "${state}/notice-days/20200101"
rm -rf "${state}/notice-days/$(date -u +%Y%m%d)"
sh "${scripts}/session_start.sh" </dev/null >/dev/null 2>&1
check "old notice days are pruned" "$([ -d "${state}/notice-days/20200101" ] && echo kept || echo pruned)" "pruned"
rm -f "${state}/auth-quarantine"
printf 'off\n' >"${state}/steering-state"
rm -rf "${state:?}/notice-days"
check "steering turned off by the company stays silent" "$(sh "${scripts}/session_start.sh" </dev/null 2>/dev/null)" ""
printf 'on\n' >"${state}/steering-state"
# Today's notice was already given above.
mkdir -p "${state}/notice-days/$(date -u +%Y%m%d)"
sleep 2

printf '1\n' >"${state}/authorization-expires-at"
rm -f "${HOME}/calls"
diagnostic="$(sh "${scripts}/session_start.sh" 2>"${work}/session-start-stderr")"
check "expired lease does not repeat today's notice" "$diagnostic" ""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '^sync --force' "${HOME}/calls" 2>/dev/null && break
  sleep 1
done
rm -f "${state}/authorization-expires-at"

rm -f "${HOME}/calls"
in_project "${work}/gone" sh "${scripts}/worker.sh" session-start
check "sync runs even when the project directory is gone" "$(cut -d' ' -f1 "${HOME}/calls" | tr '\n' ',')" "auth,sync,"

rm -f "${HOME}/calls"
sh "${scripts}/worker.sh" session-start
check "auth and sync still run while another session holds the install lock" "$(cut -d' ' -f1-2 "${HOME}/calls" | tr '\n' ',')" "auth ensure,sync --force,"
rm -rf "${state}/install.lock"

script_dir="$scripts"
# shellcheck source=../plugins/guardrails/scripts/lib.sh
. "${scripts}/lib.sh"
with_mode usage run_cli 5 "$fake" sync
check "CLI without the subcommand is detected" "$RUN_STATUS" "unsupported"
with_mode block run_cli 5 "$fake" sync
check "a real exit 2 is not mistaken for a missing subcommand" "$RUN_STATUS" "2"

mkdir "${work}/lock"
echo 999999 >"${work}/lock/pid"
acquire_lock "${work}/lock"
check "a lock held by a dead process is reclaimed" "$(cat "${work}/lock/pid")" "$$"
acquire_lock "${work}/lock"
check "a live lock is not taken twice" "$?" "1"
release_lock "${work}/lock"
check "the owner releases its lock" "$([ -e "${work}/lock" ] && echo held || echo free)" "free"

mkdir -p "${work}/rosetta"
cat >"${work}/rosetta/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo Darwin ;; -m) echo x86_64 ;; esac
EOF
cat >"${work}/rosetta/sysctl" <<'EOF'
#!/bin/sh
echo "${FAKE_TRANSLATED:-0}"
EOF
chmod 0755 "${work}/rosetta/uname" "${work}/rosetta/sysctl"
check "an Intel Mac gets the x86_64 build" "$(PATH="${work}/rosetta:${PATH}" platform_triple)" "x86_64-apple-darwin"
check "Rosetta 2 gets the native Apple silicon build" "$(FAKE_TRANSLATED=1 PATH="${work}/rosetta:${PATH}" platform_triple)" "aarch64-apple-darwin"

check "only a CLI from the compact release on is asked to compact" "$(for v in v0.6.38 v0.6.39 v0.10.0 bogus; do resets_on_compact "${state}/bin/${v}/guardrails" && printf '%s,' "$v"; done)" "v0.6.39,v0.10.0,"
check "only a CLI from the session-end release on is asked to end a session" "$(for v in v0.6.34 v0.6.35 v0.10.0 bogus; do ends_sessions "${state}/bin/${v}/guardrails" && printf '%s,' "$v"; done)" "v0.6.35,v0.10.0,"
check "only a CLI from the per-file release on is run with --synced" "$(for v in v0.6.32 v0.6.33 v0.10.0 v1.0.0 bogus; do finds_repository_per_file "${state}/bin/${v}/guardrails" && printf '%s,' "$v"; done)" "v0.6.33,v0.10.0,v1.0.0,"
check "release tags compare numerically" "$(version_lt v0.6.9 v0.6.29 && echo lt):$(version_lt v0.6.29 v0.6.9 || echo ge):$(version_lt v1.0.0 v1.0.0 || echo eq)" "lt:ge:eq"

# Install bookkeeping, on a copy of the plugin whose pins.txt pins the fake CLI for this machine.
triple="$(platform_triple)"
cp -R "${root}/plugins/guardrails" "${work}/plugin"
printf 'version v2.0.0\n%s %s %s\n' "$triple" "$(printf '0%.0s' $(seq 64))" "$(sha256_of "$fake")" >"${work}/plugin/pins.txt"
cp "$fake" "${work}/fake"
bin="${state}/bin"
rm -rf "${state:?}/install.lock" "${bin:?}"/v*
mkdir -p "${bin}/v1.0.0" "${bin}/v2.0.0" "${bin}/v3.0.0"
cp "${work}/fake" "${bin}/v2.0.0/guardrails"
cp "${work}/fake" "${bin}/v3.0.0/guardrails"
touch -t 202001010000 "${bin}/v1.0.0" "${bin}/v3.0.0"
echo v3.0.0 >"${bin}/current"
sh "${work}/plugin/scripts/worker.sh" session-start
check "a session on an older pin keeps the newer current" "$(cat "${bin}/current")" "v3.0.0"
check "prune removes an old version below the pin, never a newer one" "$(cd "$bin" && echo v*)" "v2.0.0 v3.0.0"

rm -f "${bin}/v3.0.0/guardrails"
sh "${work}/plugin/scripts/worker.sh" session-start
check "current moves off a version whose binary is gone" "$(cat "${bin}/current")" "v2.0.0"

chmod 0644 "${bin}/v2.0.0/guardrails"
sh "${work}/plugin/scripts/worker.sh" session-start
check "a binary matching its pin is kept, and made executable" "$([ -x "${bin}/v2.0.0/guardrails" ] && echo kept)" "kept"

# Bytes that fail the pin are removed even when the re-download fails (a fake curl, no network).
mkdir -p "${work}/nocurl"
printf '#!/bin/sh\nexit 22\n' >"${work}/nocurl/curl"
chmod 0755 "${work}/nocurl/curl"
echo tampered >>"${bin}/v2.0.0/guardrails"
PATH="${work}/nocurl:${PATH}" sh "${work}/plugin/scripts/worker.sh" session-start
check "a binary failing its pin is removed" "$([ -e "${bin}/v2.0.0/guardrails" ] && echo present || echo removed)" "removed"
check "the removal and the failed download are logged" "$(grep -c 'removed v2.0.0 binary that failed its checksum\|download of v2.0.0 failed' "${state}/logs/plugin.log")" "2"

# The wiring itself: the enforce arm's events, no Bash hook, no final sweep.
hooks="${root}/plugins/guardrails/hooks/hooks.json"
check "no hook runs the command check or the final sweep" "$(grep -c '"pre-command"\|"final-sweep"\|"Bash"' "$hooks")" "0"
check "edits and notebook edits are matched before and after the tool" "$(grep -c '"matcher": "Write|Edit|MultiEdit|NotebookEdit"' "$hooks")" "2"
# shellcheck disable=SC2016 # ${CLAUDE_PLUGIN_ROOT} is literal text in hooks.json
check "SessionEnd ends the session through guardrails.sh" "$(tr -d ' \n' <"$hooks" | grep -c '"SessionEnd":\[{"hooks":\[{"type":"command","command":"sh","args":\["${CLAUDE_PLUGIN_ROOT}/scripts/guardrails.sh","session-end"\]')" "1"

[ "$failures" -eq 0 ] || exit 1

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
echo "$* SECPROFILE_DIR=${SECPROFILE_DIR:-}" >>"$HOME/calls"
case "${FAKE_MODE:-ok}" in
  ok) echo '{"hookSpecificOutput":{}}' ;;
  block) echo "blocked" >&2; exit 2 ;;
  crash) exit 101 ;;
  slow) sleep 3 ;;
  slowflush) [ "$1" = flush ] && sleep 3 ;;
  usage) printf 'guardrails \342\200\224 security profile enforcement for coding agents\n\n  guardrails hook <session-start|pre-edit>\n' >&2; exit 2 ;;
  quoted) printf '[secprofile] Before finishing, resolve these:\n  - x\n  guardrails hook <y.py: hit\n' >&2; exit 2 ;;
  noauth) [ "$1" = auth ] && exit 3 ;;
esac
exit 0
EOF
chmod 0755 "$fake"

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

echo v9.9.9 >"${state}/bin/current"
wrap hook pre-edit
check "no repos.json fails open" "${status}:${out}" "0:"

write_index "${project}2" '"repo_1"'
wrap hook pre-edit
check "a recorded root that only starts with the checkout path is not used" "${status}:${out}" "0:"

# The escaped targets exist, so only the validators keep them from being used.
mkdir -p "${state}/escaped/v9.9.9" "${state}/v9.9.9"
cp "$fake" "${state}/v9.9.9/guardrails"
cp "$fake" "${state}/escaped/v9.9.9/guardrails"
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
wrap hook pre-edit
check "hook output passes through" "${status}:${out}" '0:{"hookSpecificOutput":{}}'
check "SECPROFILE_DIR points at the repository profile" "$(cat "${HOME}/calls")" "hook pre-edit SECPROFILE_DIR=${state}/profiles/repo_1"

# Claude Code started in a subdirectory, through a symlink: still the checkout sync recorded.
mkdir -p "${project}/src"
ln -s "${project}/src" "${work}/link"
rm -f "${HOME}/calls"
in_project "${work}/link" wrap hook pre-edit
check "a symlinked subdirectory finds its checkout's profile" "$(cat "${HOME}/calls")" "hook pre-edit SECPROFILE_DIR=${state}/profiles/repo_1"

# A checkout path that JSON has to escape.
odd="${work}/we\"ird\\dir"
mkdir -p "$odd"
git -C "$odd" init -q
odd="$(cd "$odd" && pwd -P)"
write_index "$(printf '%s' "$odd" | sed 's/\\/\\\\/g; s/"/\\"/g')" '"repo_1"'
rm -f "${HOME}/calls"
in_project "$odd" wrap hook pre-edit
check "a checkout path with a quote and a backslash is matched" "$(cat "${HOME}/calls" 2>/dev/null)" "hook pre-edit SECPROFILE_DIR=${state}/profiles/repo_1"
write_index "$project" '"repo_1"'

with_mode block wrap hook pre-command
check "CLI exit 2 still blocks" "$status" "2"
reason="$(echo '{}' | with_mode block sh "${scripts}/guardrails.sh" hook pre-command 2>&1 >/dev/null)"
check "a block keeps the CLI's reason on stderr" "$reason" "blocked"

with_mode crash wrap hook post-edit
check "CLI crash fails open" "$status" "0"

with_mode usage wrap hook pre-command
check "CLI without this hook mode fails open instead of blocking" "$status" "0"

reason="$(echo '{}' | with_mode quoted sh "${scripts}/guardrails.sh" stop 2>&1 >/dev/null)"
status=$?
check "a block quoting a usage-like file path still blocks, reason intact" "${status}:$(printf '%s' "$reason" | wc -l | tr -d ' ')" "2:2"

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
wrap stop
check "stop runs the final sweep" "${status}:${out}" '0:{"hookSpecificOutput":{}}'
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '^flush' "${HOME}/calls" 2>/dev/null && break
  sleep 1
done
check "stop starts flush in the background" "$(grep -c '^flush' "${HOME}/calls")" "1"

started="$(date +%s)"
# Claude Code reads hook output through pipes, so the detached flush must not hold them open.
with_mode slowflush sh "${scripts}/guardrails.sh" stop </dev/null 2>&1 | cat >/dev/null
check "stop does not wait for a slow flush" "$(($(date +%s) - started < 3))" "1"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(grep -c 'flush: ' "${state}/logs/plugin.log")" -ge 2 ] && break
  sleep 1
done

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
check "the background work still runs auth and sync" "$(cut -d' ' -f1-2 "${HOME}/calls" | tr '\n' ',')" "auth ensure,sync SECPROFILE_DIR=,"
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
check "a session waits for another session's install, then syncs" "$(cut -d' ' -f1-2 "${HOME}/calls" 2>/dev/null | tr '\n' ',')" "auth ensure,sync SECPROFILE_DIR=,"
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
check "sync still runs when auth ensure fails" "$(cut -d' ' -f1-2 "${HOME}/calls" | tr '\n' ',')" "auth ensure,sync SECPROFILE_DIR=,"

rm -f "${HOME}/calls"
sh "${scripts}/worker.sh" session-start
check "auth and sync still run while another session holds the install lock" "$(cut -d' ' -f1-2 "${HOME}/calls" | tr '\n' ',')" "auth ensure,sync SECPROFILE_DIR=,"
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

[ "$failures" -eq 0 ] || exit 1

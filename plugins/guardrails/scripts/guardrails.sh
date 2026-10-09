#!/bin/sh
# Runs one guardrails CLI hook for Claude Code: `guardrails.sh hook <mode>`, `guardrails.sh
# session-end`, `guardrails.sh compact` or `guardrails.sh stop`. SessionStart itself does not come
# here: it starts worker.sh and, after a compaction, runs `compact` (see session_start.sh).
# Always exits 0. Refusals reach Claude Code as the CLI's own JSON on stdout, never as an exit
# code, so a missing CLI, platform or synced profile, a crash or a timeout all fail open.

script_dir="$(cd "$(dirname "$0")" && pwd)" || exit 0
# shellcheck source=lib.sh
. "${script_dir}/lib.sh"
if [ "${1:-}" != compact ] && { auth_quarantined || steering_disabled || authorization_unusable; }; then
  exit 0
fi

case "$1" in
  hook) mode="$2" ;;
  session-end)
    # The session's refuse-once state stays for `claude --resume`; queued events are sent now.
    nohup sh "${script_dir}/worker.sh" flush >/dev/null 2>&1 </dev/null &
    mode=session-end
    ;;
  compact) mode=compact ;;
  stop)
    # Stop only sends the queued trigger events, detached so it never delays or holds the turn.
    # No final sweep: it would block the turn, and on a turn with nothing to say it would wipe the
    # session's refuse-once state.
    nohup sh "${script_dir}/worker.sh" flush >/dev/null 2>&1 </dev/null &
    exit 0
    ;;
  *) exit 0 ;;
esac
case "$mode" in
  prompt-submit | pre-edit | post-edit | session-end | compact) ;;
  *) exit 0 ;;
esac
binary="$(plugin_binary)" || exit 0
flag=""
root="${CLAUDE_PROJECT_DIR:-}"
if [ "$mode" = compact ]; then
  # Legacy session-end is safe only when a compaction explicitly requests a reset.
  if resets_on_compact "$binary"; then
    :
  elif ends_sessions "$binary"; then
    mode=session-end
  else
    exit 0
  fi
  flag=--synced
elif [ "$mode" = session-end ]; then
  # Older CLIs erase refuse-once marks here, breaking resume.
  resets_on_compact "$binary" || exit 0
  flag=--synced
elif ! any_profile_synced; then
  exit 0
elif finds_repository_per_file "$binary"; then
  # The CLI finds each file's repository from the file itself and answers only synced ones.
  flag=--synced
elif root="$(checkout_root "${CLAUDE_PROJECT_DIR:-$PWD}")" &&
  repository_id="$(repository_id_for "$root")" &&
  [ -d "${GUARDRAILS_PROFILES_DIR}/${repository_id}" ]; then
  # An older CLI loads the profile of the checkout it is given, found here through repos.json.
  :
else
  exit 0
fi

trap 'exit 0' HUP INT TERM
# The benchmark's enforce arm: refuse the first edit per file per session that carries guidance.
# An inherited SECPROFILE_DIR would win over the synced profiles, and the other variables would
# change the thresholds the arm was measured with. stdout (the hook's JSON) goes to Claude Code.
(
  unset SECPROFILE_DIR SECPROFILE_WARN_LINES SECPROFILE_WARN_FILES SECPROFILE_BLOCK_LINES \
    SECPROFILE_BLOCK_FILES SECPROFILE_UNATTENDED SECPROFILE_CANARY
  export SECPROFILE_ENFORCE=1 CLAUDE_PROJECT_DIR="$root"
  exec "$binary" hook "$mode" ${flag:+"$flag"} 2>/dev/null
)
exit 0

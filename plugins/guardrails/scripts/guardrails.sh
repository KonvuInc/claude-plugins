#!/bin/sh
# Runs one guardrails CLI hook for Claude Code: `guardrails.sh hook <mode>` or `guardrails.sh stop`.
# SessionStart does not come here: it only starts worker.sh (see session_start.sh).
# Fails open: exits 0 when the CLI, the platform or this repository's profile is missing, and
# passes through only the CLI's own exit 2, which is how it asks Claude Code to block.

script_dir="$(cd "$(dirname "$0")" && pwd)" || exit 0
# shellcheck source=lib.sh
. "${script_dir}/lib.sh"

case "$1" in
  hook) mode="$2" ;;
  stop) mode=final-sweep ;;
  *) exit 0 ;;
esac
case "$mode" in
  prompt-submit | pre-command | pre-edit | post-edit | final-sweep) ;;
  *) exit 0 ;;
esac

status=0
if binary="$(plugin_binary)" && repository_id="$(repository_id_for "${CLAUDE_PROJECT_DIR:-$PWD}")"; then
  profile="${GUARDRAILS_PROFILES_DIR}/${repository_id}"
  if [ -d "$profile" ]; then
    trap 'exit 0' HUP INT TERM
    # stdout (the hook's JSON) goes straight to Claude Code on fd 3; stderr is kept in memory,
    # needing no temp file, and shown only on a block.
    exec 3>&1
    errors="$(SECPROFILE_DIR="$profile" "$binary" hook "$mode" 2>&1 1>&3 3>&-)"
    rc=$?
    exec 3>&-
    # A CLI too old for this hook mode exits 2 with its usage text: fail open, do not block.
    if [ "$rc" -eq 2 ] && ! printf '%s\n' "$errors" | is_usage_output; then
      status=2
      printf '%s\n' "$errors" >&2
    fi
  fi
fi

# Stop sends the queued trigger events after the final sweep, detached so it never delays the turn.
if [ "$1" = stop ]; then
  nohup sh "${script_dir}/worker.sh" flush >/dev/null 2>&1 </dev/null &
fi
exit "$status"

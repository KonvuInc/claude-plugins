#!/bin/sh
# SessionStart hook. Returns at once: the CLI install, `auth ensure` and `sync --force` run detached.
# After a compaction the earlier guidance may be gone from the context, so the session's
# refuse-once state is reset first, as at the end of a session.

script_dir="$(cd "$(dirname "$0")" && pwd)" || exit 0
payload="$(cat)"
if printf '%s' "$payload" | grep -q '"source" *: *"compact"'; then
  printf '%s' "$payload" | sh "${script_dir}/guardrails.sh" session-end >/dev/null 2>&1
fi
# shellcheck source=lib.sh
. "${script_dir}/lib.sh"
if auth_quarantined || authorization_unusable; then
  notice_day="$(date -u +%Y%m%d 2>/dev/null)"
  notice_dir="${GUARDRAILS_HOME}/notice-days"
  if [ -n "$notice_day" ] && (umask 077; mkdir -p "$notice_dir" && mkdir "${notice_dir}/${notice_day}" 2>/dev/null); then
    printf '%s\n' 'Konvu Guardrails paused; checking workstation access in the background.' >&2
  fi
fi
nohup sh "${script_dir}/worker.sh" session-start >/dev/null 2>&1 </dev/null &
exit 0

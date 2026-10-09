#!/bin/sh
# SessionStart hook. Returns at once: the CLI install, `auth ensure` and `sync --force` run detached.
# After a compaction the earlier guidance may be gone from the context, so the session's
# refuse-once state is reset first. A resume keeps it: Claude Code keeps the session id.

script_dir="$(cd "$(dirname "$0")" && pwd)" || exit 0
payload="$(cat)"
if printf '%s' "$payload" | grep -q '"source" *: *"compact"'; then
  printf '%s' "$payload" | sh "${script_dir}/guardrails.sh" compact >/dev/null 2>&1
fi
# shellcheck source=lib.sh
. "${script_dir}/lib.sh"
# systemMessage reaches the person; hook stderr usually does not.
if auth_quarantined || authorization_unusable; then
  notice_day="$(date -u +%Y%m%d 2>/dev/null)"
  notice_dir="${GUARDRAILS_HOME}/notice-days"
  if [ -n "$notice_day" ] && (umask 077; mkdir -p "$notice_dir" && mkdir "${notice_dir}/${notice_day}" 2>/dev/null); then
    printf '{"systemMessage":"%s"}\n' "$(auth_notice)"
    find "$notice_dir" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rmdir {} + 2>/dev/null
  fi
fi
nohup sh "${script_dir}/worker.sh" session-start >/dev/null 2>&1 </dev/null &
exit 0

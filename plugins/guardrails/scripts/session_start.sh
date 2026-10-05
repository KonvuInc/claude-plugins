#!/bin/sh
# SessionStart hook. Returns at once: the CLI install, `auth ensure` and `sync` run detached.

script_dir="$(cd "$(dirname "$0")" && pwd)" || exit 0
nohup sh "${script_dir}/worker.sh" session-start >/dev/null 2>&1 </dev/null &
exit 0

#!/bin/sh
# Background work for the guardrails plugin, always started detached with nohup.
#   worker.sh session-start   install the pinned CLI, then `guardrails auth ensure` and `guardrails sync`
#   worker.sh flush           `guardrails flush`, sending queued trigger events
# Every step logs one status line to ~/.konvu/guardrails/logs/plugin.log and never logs CLI output.

script_dir="$(cd "$(dirname "$0")" && pwd)" || exit 0
# shellcheck source=lib.sh
. "${script_dir}/lib.sh"

umask 077
mkdir -p "$GUARDRAILS_BIN_DIR" "$GUARDRAILS_PROFILES_DIR" "$GUARDRAILS_LOG_DIR" 2>/dev/null || exit 0
# Temp files left by a run killed mid-way (shutdown, logout); live runs are far younger than this.
find "$GUARDRAILS_LOG_DIR" -maxdepth 1 -name '.run.*' -mmin +60 -exec rm -f {} + 2>/dev/null
find "$GUARDRAILS_BIN_DIR" -maxdepth 1 \( -name '.stage.*' -o -name 'current.*' \) -mmin +60 -exec rm -rf {} + 2>/dev/null
find "$GUARDRAILS_HOME" -maxdepth 1 -name '*.lock.stale.*' -mmin +60 -exec rm -rf {} + 2>/dev/null

# Installs the pinned CLI unless bin/<pinned>/guardrails already matches its pinned checksum.
# `current` moves to the new version only after both checksums pass, so the old one keeps working.
ensure_cli() {
  triple="$(platform_triple)" || { log_line "install: unsupported platform $(uname -s)-$(uname -m)"; return 1; }
  pinned="$(pinned_version)" || { log_line "install: invalid pinned version"; return 1; }
  archive_sha="$(awk -v t="$triple" '$1 == t { print $2 }' "$GUARDRAILS_PINS")"
  binary_sha="$(awk -v t="$triple" '$1 == t { print $3 }' "$GUARDRAILS_PINS")"
  if [ -z "$archive_sha" ] || [ -z "$binary_sha" ]; then
    log_line "install: no pinned checksum for $triple"
    return 1
  fi
  if ! sha256_of "$GUARDRAILS_PINS" >/dev/null; then
    log_line "install: no sha256 tool"
    return 1
  fi

  dest="${GUARDRAILS_BIN_DIR}/${pinned}"
  if [ -x "${dest}/guardrails" ] && [ "$(sha256_of "${dest}/guardrails")" = "$binary_sha" ]; then
    set_current "$pinned" && prune_versions
    return 0
  fi
  stage="$(mktemp -d "${GUARDRAILS_BIN_DIR}/.stage.XXXXXX")" || return 1
  # Bytes that fail the pin are not left for hooks to run, even if the re-download below fails.
  # They are moved aside and checked there, so a verified binary another session renamed into
  # place a moment ago is put back, never deleted.
  if [ -e "${dest}/guardrails" ]; then
    if ! mv -f "${dest}/guardrails" "${stage}/rejected" 2>/dev/null; then
      log_line "install: ${pinned} binary fails its checksum and could not be removed"
    elif [ "$(sha256_of "${stage}/rejected")" != "$binary_sha" ]; then
      log_line "install: removed ${pinned} binary that failed its checksum"
    elif chmod 0755 "${stage}/rejected" && mv -f "${stage}/rejected" "${dest}/guardrails"; then
      rm -rf "$stage"
      set_current "$pinned" && prune_versions
      return 0
    fi
  fi
  if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
    install_failed "curl or tar missing"
    return 1
  fi

  archive="guardrails-cli-${triple}.tar.xz"
  member="./guardrails-cli-${triple}/guardrails"
  if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --connect-timeout 10 --max-time 300 \
    -o "${stage}/${archive}" "${GUARDRAILS_DOWNLOAD_BASE}/${pinned}/${archive}"; then
    install_failed "download of ${pinned} failed"
  elif [ "$(sha256_of "${stage}/${archive}")" != "$archive_sha" ]; then
    install_failed "archive checksum mismatch for ${pinned} ${triple}, refused"
  elif ! tar -xf "${stage}/${archive}" -C "$stage" "$member" 2>/dev/null; then
    install_failed "could not extract ${archive} (Linux needs xz installed)"
  elif [ "$(sha256_of "${stage}/${member}")" != "$binary_sha" ]; then
    install_failed "binary checksum mismatch for ${pinned} ${triple}, refused"
  # Same filesystem as the destination, so the rename is atomic for concurrent hook readers.
  elif ! chmod 0755 "${stage}/${member}" || ! mkdir -p "$dest" || ! mv -f "${stage}/${member}" "${dest}/guardrails"; then
    install_failed "could not install ${pinned}"
  else
    rm -rf "$stage"
    set_current "$pinned" || return 1
    prune_versions
    log_line "install: ${pinned} ${triple} ok"
    return 0
  fi
  return 1
}

install_failed() {
  log_line "install: $1"
  rm -rf "$stage"
}

# `current` names the newest verified version: the fallback for a session whose own pin is not
# installed yet. A session on an older plugin never moves it back.
set_current() {
  now="$(cat "$GUARDRAILS_CURRENT" 2>/dev/null)"
  if valid_version "$now" && [ -x "${GUARDRAILS_BIN_DIR}/${now}/guardrails" ] && ! version_lt "$now" "$1"; then
    return 0
  fi
  printf '%s\n' "$1" >"${GUARDRAILS_CURRENT}.$$" && mv -f "${GUARDRAILS_CURRENT}.$$" "$GUARDRAILS_CURRENT" && return 0
  rm -f "${GUARDRAILS_CURRENT}.$$"
  log_line "install: could not switch current to $1"
  return 1
}

# Removes versions older than this plugin's pin that are not current and were installed over a
# day ago. A newer version belongs to a newer plugin that may be running in another session, so
# it is never removed here.
prune_versions() {
  in_use="$(cat "$GUARDRAILS_CURRENT" 2>/dev/null)"
  find "$GUARDRAILS_BIN_DIR" -mindepth 1 -maxdepth 1 -type d -name 'v*' -mmin +1440 2>/dev/null |
    while IFS= read -r old; do
      old_version="${old##*/}"
      valid_version "$old_version" && [ "$old_version" != "$in_use" ] && version_lt "$old_version" "$pinned" &&
        rm -rf "$old"
    done
}

session_start() {
  # Only the install is serialized across sessions; auth and sync below must run for every project.
  install_lock="${GUARDRAILS_HOME}/install.lock"
  waited=0
  # A session that has a verified CLI uses it meanwhile; one that has none (a fresh machine) waits
  # for the other install, retrying the lock so a lock left by a killed session is reclaimed.
  until acquire_lock "$install_lock"; do
    if plugin_binary >/dev/null || [ "$waited" -ge 360 ]; then
      log_line "install: skipped, another session is installing"
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done
  if [ "$(cat "${install_lock}/pid" 2>/dev/null)" = "$$" ]; then
    trap 'release_lock "$install_lock"; rm -f "${output:-}"' EXIT
    trap 'exit 1' HUP INT TERM
    ensure_cli
    release_lock "$install_lock"
  fi
  trap 'rm -f "${output:-}"' EXIT
  trap 'exit 1' HUP INT TERM

  binary="$(plugin_binary)" || { log_line "session-start: no verified CLI, skipped auth and sync"; return 0; }
  # The CLI serializes enrollment itself and writes its caches atomically, so parallel runs are safe.
  run_cli 60 "$binary" auth ensure
  log_line "auth ensure: ${RUN_STATUS}"
  # sync runs whatever auth returned: without a usable credential it exits at once, and a failed
  # rotation must not stop a still-valid credential from refreshing the rules.
  # sync downloads every repository's rules wherever it runs; from the project it fetches that
  # one first, and an older server that lists nothing syncs only the project's checkout.
  cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || cd "$HOME" 2>/dev/null || cd /
  run_cli 60 "$binary" sync
  log_line "sync: ${RUN_STATUS}"
}

flush() {
  # The CLI serializes flushes on its own `flush.lock` file, so no lock is taken here. Plugin
  # 0.0.2 took a directory of that name, which the CLI cannot open; remove one it left behind.
  legacy="${GUARDRAILS_HOME}/flush.lock"
  if [ -d "$legacy" ] && lock_is_stale "$legacy"; then
    rm -rf "$legacy"
  fi
  trap 'rm -f "${output:-}"' EXIT
  trap 'exit 1' HUP INT TERM

  binary="$(plugin_binary)" || return 0
  run_cli 60 "$binary" flush
  log_line "flush: ${RUN_STATUS}"
}

case "$1" in
  session-start) session_start ;;
  flush) flush ;;
esac
exit 0

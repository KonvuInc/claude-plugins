# Shared paths and helpers for the guardrails plugin scripts. Sourced, never executed.
# shellcheck shell=sh disable=SC2034

GUARDRAILS_HOME="${HOME}/.konvu/guardrails"
GUARDRAILS_BIN_DIR="${GUARDRAILS_HOME}/bin"
GUARDRAILS_CURRENT="${GUARDRAILS_BIN_DIR}/current"
GUARDRAILS_PROFILES_DIR="${GUARDRAILS_HOME}/profiles"
GUARDRAILS_REPOS_INDEX="${GUARDRAILS_HOME}/repos.json"
GUARDRAILS_LOG_DIR="${GUARDRAILS_HOME}/logs"
GUARDRAILS_LOG="${GUARDRAILS_LOG_DIR}/plugin.log"
GUARDRAILS_DOWNLOAD_BASE="https://dneaqnz3vqe4a.cloudfront.net/guardrails"
# Callers set script_dir to this file's directory before sourcing it.
GUARDRAILS_PINS="${script_dir:?}/../pins.txt"

# A release tag is a single path component: v, digits and dots only.
valid_version() {
  case "$1" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!v0-9.]*) return 1 ;;
  esac
  return 0
}

# A repository id is a single path component: 1 to 64 letters, digits, '-' and '_', as the CLI
# itself requires.
valid_repository_id() {
  case "$1" in
    "" | *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

# True when release tag $1 is older than release tag $2 (both already passed valid_version).
version_lt() {
  awk -v a="${1#v}" -v b="${2#v}" 'BEGIN {
    split(a, x, "."); split(b, y, ".")
    for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
    exit 1
  }'
}

# Prints the release tag this plugin version pins, or fails.
pinned_version() {
  version="$(awk '$1 == "version" { print $2 }' "$GUARDRAILS_PINS" 2>/dev/null)"
  valid_version "$version" || return 1
  printf '%s\n' "$version"
}

# Prints the CLI to run: this plugin's own pinned version once installed, else the last version
# that passed its checksums (`current`), so an upgrade keeps the old CLI until the new one verifies.
# Binaries are only ever placed in bin/<version>/ after verification.
plugin_binary() {
  for version in "$(pinned_version)" "$(cat "$GUARDRAILS_CURRENT" 2>/dev/null)"; do
    valid_version "$version" || continue
    binary="${GUARDRAILS_BIN_DIR}/${version}/guardrails"
    if [ -f "$binary" ] && [ -x "$binary" ]; then
      printf '%s\n' "$binary"
      return 0
    fi
  done
  return 1
}

# Prints the repository id that `guardrails sync` recorded for this checkout, or fails.
# repos.json is the CLI's index, written atomically by serde_json's pretty printer:
#   {"remotes": {"<remote>": {"repository_id": "<id>" | null, ...}}, "roots": {"<checkout>": "<remote>"}}
# Keys are matched whole, still JSON-encoded, never by substring. Any other layout fails open.
repository_id_for() {
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null </dev/null)" || return 1
  # sync records the canonical path. git already resolves symlinks; pwd -P keeps the key equal to
  # the CLI's canonicalize() even where it does not.
  top="$(cd "$top" 2>/dev/null && pwd -P)" || return 1
  [ -n "$top" ] && [ -f "$GUARDRAILS_REPOS_INDEX" ] || return 1
  # serde_json escapes only '"', '\' and control characters. Trailing newlines are trimmed here as
  # in the CLI's own sync, so both name the same checkout; any other control character fails open.
  case "$top" in
    *[[:cntrl:]]*) return 1 ;;
  esac
  key="$(printf '%s\n' "$top" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  id="$(KEY="$key" awk '
    BEGIN { root = "    \"" ENVIRON["KEY"] "\": \"" }
    /^  "remotes": [{]/ { section = "remotes"; next }
    /^  "roots": [{]/ { section = "roots"; next }
    /^  [}]/ { section = ""; next }
    section == "roots" && index($0, root) == 1 {
      remote = substr($0, length(root) + 1)
      sub(/,$/, "", remote)
      if (sub(/"$/, "", remote) != 1) remote = ""
      next
    }
    section == "remotes" && /^    "/ {
      current = substr($0, 6)
      if (sub(/": [{]$/, "", current) != 1) current = ""
      next
    }
    section == "remotes" && current != "" && /^      "repository_id": "/ {
      value = $0
      sub(/^      "repository_id": "/, "", value)
      if (sub(/",?$/, "", value) == 1) ids[current] = value
    }
    END { if (remote != "" && (remote in ids)) print ids[remote] }
  ' "$GUARDRAILS_REPOS_INDEX" 2>/dev/null)"
  valid_repository_id "$id" || return 1
  printf '%s\n' "$id"
}

# Prints the release target triple for this machine, or fails on an unsupported platform.
platform_triple() {
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) echo aarch64-apple-darwin ;;
    # Under Rosetta 2 uname says x86_64; take the native build so every session agrees on one.
    Darwin-x86_64)
      if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ]; then
        echo aarch64-apple-darwin
      else
        echo x86_64-apple-darwin
      fi
      ;;
    Linux-x86_64 | Linux-amd64) linux_gnu_triple x86_64-unknown-linux-gnu ;;
    Linux-aarch64 | Linux-arm64) linux_gnu_triple aarch64-unknown-linux-gnu ;;
    *) return 1 ;;
  esac
}

# The pinned Linux builds link glibc, so a musl system is unsupported rather than broken.
linux_gnu_triple() {
  for loader in /lib/ld-musl-*; do
    [ -e "$loader" ] && return 1
  done
  echo "$1"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sum="$(sha256sum "$1" 2>/dev/null | awk '{ print $1 }')"
  elif command -v shasum >/dev/null 2>&1; then
    sum="$(shasum -a 256 "$1" 2>/dev/null | awk '{ print $1 }')"
  else
    return 1
  fi
  [ -n "$sum" ] || return 1
  printf '%s\n' "$sum"
}

log_line() {
  mkdir -p "$GUARDRAILS_LOG_DIR" 2>/dev/null || return 0
  # Keep one rotated copy so the log never grows without bound.
  if [ -f "$GUARDRAILS_LOG" ] && [ "$(wc -c <"$GUARDRAILS_LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
    mv -f "$GUARDRAILS_LOG" "${GUARDRAILS_LOG}.1" 2>/dev/null
  fi
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$GUARDRAILS_LOG" 2>/dev/null
  return 0
}

# Takes a mkdir lock, reclaiming it when its holder is gone. The lock only avoids duplicate work:
# every step behind it is safe to run twice, so two sessions reclaiming the same stale lock at
# once (both can end up holding it) is harmless.
acquire_lock() {
  lock="$1"
  if ! mkdir "$lock" 2>/dev/null; then
    lock_is_stale "$lock" || return 1
    moved="${lock}.stale.$$"
    mv "$lock" "$moved" 2>/dev/null || return 1
    rm -rf "$moved"
    mkdir "$lock" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" >"$lock/pid" || { rmdir "$lock" 2>/dev/null; return 1; }
  return 0
}

# Stale: its pid is dead, it has no pid a minute after creation (holder killed right after
# mkdir), or it is older than 30 minutes (pid reuse).
lock_is_stale() {
  [ -n "$(find "$1" -maxdepth 0 -mmin +30 2>/dev/null)" ] && return 0
  holder="$(cat "$1/pid" 2>/dev/null)"
  case "$holder" in
    "" | *[!0-9]*) [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ] ;;
    *) ! kill -0 "$holder" 2>/dev/null ;;
  esac
}

# Releases the lock only while this process still owns it.
release_lock() {
  [ "$(cat "$1/pid" 2>/dev/null)" = "$$" ] || return 0
  rm -rf "$1"
  return 0
}

# True when stdin is the CLI's usage text, which it prints with exit 2 for an unknown subcommand
# or hook mode. That exit 2 is a version mismatch, never a decision to block.
# Only the first line is compared: the usage banner is fixed, while a real block starts with
# "[secprofile]" and can quote file paths that contain anything, newlines included.
is_usage_output() {
  IFS= read -r first || [ -n "$first" ] || return 1
  case "$first" in
    "guardrails "*" security profile enforcement for coding agents") return 0 ;;
  esac
  return 1
}

# Runs `<binary> <args...>` with a hard timeout and sets RUN_STATUS to its exit code, or to
# "unsupported" when the CLI answers with its usage text because it lacks the subcommand.
# Output goes to a private temp file, read only for the usage check and then deleted (worker.sh
# sweeps any file a killed run leaves behind), so a credential the CLI prints never reaches the log.
run_cli() {
  seconds="$1"
  shift
  output="$(mktemp "${GUARDRAILS_LOG_DIR}/.run.XXXXXX")" || { RUN_STATUS=1; return 0; }
  "$@" >"$output" 2>&1 </dev/null &
  child=$!
  (sleep "$seconds"; kill "$child" 2>/dev/null) >/dev/null 2>&1 &
  watchdog=$!
  wait "$child"
  RUN_STATUS=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  if [ "$RUN_STATUS" -eq 2 ] && is_usage_output <"$output"; then
    RUN_STATUS=unsupported
  fi
  rm -f "$output"
  return 0
}

# Konvu Claude Code plugins

Public Claude Code plugin marketplace published by [Konvu](https://konvu.com). The marketplace is named `konvu`.

| Plugin | What it does |
| --- | --- |
| [`guardrails`](plugins/guardrails) | Brings your repository's Konvu Guardrails security rules into Claude Code, before code is written. |

## guardrails

The plugin is a thin set of hook scripts. All matching runs in the `guardrails` CLI on the developer's laptop. Rules and credentials come from the Konvu API, never from this repository.

### Install

The plugin needs three things on each laptop:

- the `konvu` marketplace registered in Claude Code,
- the `guardrails@konvu` plugin enabled,
- `KONVU_DEPLOYMENT_KEY`, your organization's deployment key from Konvu, in Claude Code's environment. The CLI uses it once, to enroll the laptop.

For a whole organization, set all three in Claude Code [managed settings](https://code.claude.com/docs/en/settings):

```json
{
  "extraKnownMarketplaces": {
    "konvu": {
      "source": { "source": "github", "repo": "KonvuInc/claude-plugins" },
      "autoUpdate": true
    }
  },
  "enabledPlugins": { "guardrails@konvu": true },
  "env": { "KONVU_DEPLOYMENT_KEY": "<your deployment key>" }
}
```

`autoUpdate` lets each laptop pick up a new plugin release on its own; without it, laptops update when someone runs `claude plugin update guardrails@konvu`. To hold every laptop on one release, add `"ref": "guardrails--v0.0.1"` to `source` (see [Versioning](#versioning)).

For a single laptop:

```sh
claude plugin marketplace add KonvuInc/claude-plugins
claude plugin install guardrails@konvu
```

and set `KONVU_DEPLOYMENT_KEY` in the environment Claude Code starts from, or under `env` in `~/.claude/settings.json`. Auto-update is off for a marketplace added this way: turn it on under **Marketplaces** in `/plugin`, or run `claude plugin update guardrails@konvu` to take a new release.

Developers do nothing else. On their next Claude Code session the plugin installs the CLI, which enrolls the laptop (see the note on the pinned release below).

Claude Code passes settings `env` to every process it starts, including the model's Bash tool, so the deployment key is readable on every laptop that has it. The CLI uses it only to enroll, and revoking it in Konvu stops further enrollments.

### What runs when

| Claude Code event | What the plugin does | Timeout |
| --- | --- | --- |
| `SessionStart` | Returns at once and starts a background job: install the pinned `guardrails` CLI if needed, then `guardrails auth ensure` and `guardrails sync --force` (the rules of every repository of your company, the project's own first). | 5 s |
| `UserPromptSubmit` | `guardrails hook prompt-submit` | 5 s |
| `PreToolUse` on `Write`, `Edit`, `MultiEdit`, `NotebookEdit` | `guardrails hook pre-edit`: the first edit of a file per session that the rules have advice for is refused once with that advice; resubmitting it, or any later edit of that file, goes through with the advice in context. | 5 s |
| `PostToolUse` on `Write`, `Edit`, `MultiEdit`, `NotebookEdit` | `guardrails hook post-edit` | 5 s |
| `Stop` | `guardrails flush` in the background, to send queued trigger events. Never blocks the turn. | 5 s |
| `SessionEnd` | `guardrails hook session-end`: deletes the session's refuse-once state. | 5 s |

This is the enforce arm the Konvu benchmark measured: hooks run with `SECPROFILE_ENFORCE=1`, and the `SECPROFILE_*` threshold variables of the developer's environment are not passed on. The plugin runs no Bash hook (no package check, no commit `ask`) and no final sweep at `Stop`. Refuse-once state lasts the whole session, across turns; it is reset when Claude Code compacts the conversation (`SessionStart` with `source` `compact`), since the earlier advice may no longer be in context, and deleted at `SessionEnd`. A CLI older than `v0.6.35` has no `session-end`, so the plugin does not call it; its state stays in the temporary directory until the system clears it. A repository that commits its own `.secprofile/policy.json` with `"managed": true` is not enforced, by its own choice. `NotebookEdit` needs `v0.6.35` or newer; an older CLI lets it through silently, and reports every rule that matched an edit rather than the ones its message named. A governed edit is also refused every time while the uncommitted diff of the repository's classified files reaches 2000 lines or 30 files; synced rules classify no files yet, so this does not fire today.

Every hook except `SessionStart` goes through `scripts/guardrails.sh`, which runs the cached CLI by absolute path as `guardrails hook <mode> --synced` once `guardrails sync` has downloaded at least one repository's rules. The plugin does not decide which repository a session is in; the CLI decides it for every event, because sessions are rarely opened at a checkout root and one session often edits several repositories. A `SECPROFILE_DIR` in the environment is not passed on, since it would replace the synced rules. The plugin fails open: when the CLI, the platform, every synced profile or the network is missing, the hook exits 0 and Claude Code carries on. Every hook exits 0: a refusal reaches Claude Code as the CLI's JSON answer on stdout, never as an exit code, and the CLI's stderr is discarded. A CLI older than `v0.6.33` (only ever the `bin/current` fallback while the pinned one installs) is run as before: only when the checkout containing `CLAUDE_PROJECT_DIR` has a profile in `repos.json`, and with that checkout's root.

When company agent steering is off, workstation authentication is quarantined, or a saved authorization lease is invalid or expired, the plugin skips every non-start hook, including session-end and flush. `SessionStart` still checks authentication and refreshes the company setting. The CLI clears queued events and cached rules when authorization is quarantined; a quarantined or expired workstation gets a short startup notice at most once per UTC day without exposing credentials or CLI output.

### How the repository is determined

`guardrails sync` downloads the rules of every repository of your company that Konvu has mapped, not only the one Claude Code was started in, and indexes them by git remote URL. For each event the CLI then finds the repository from the event itself:

- **An edit** (`Write`, `Edit`, `MultiEdit`, and the files of a Codex `apply_patch`): the file being written, absolute or relative to the event's working directory. The file may not exist yet; its nearest existing directory is used.
- **A command or a prompt**: the event's working directory, else the project directory.

From there, `git rev-parse --show-toplevel` gives the checkout, and the checkout's `origin` remote names the repository. That is why the answer does not depend on how the code got there:

- **Branches and worktrees.** Every branch, and every linked worktree (`git worktree add`), of one repository shares its remote, so they share its rules. Paths in the rules are taken relative to the checkout the file is in.
- **Forks.** When `origin` is not a repository Konvu knows, the `upstream` remote is tried, so a fork of a company repository gets that repository's rules.
- **Remote spellings.** `git@github.com:Org/Repo.git`, `ssh://git@github.com/Org/Repo`, `https://user@github.com/org/repo/` and the like are one repository: credentials, `.git`, a trailing `/` and letter case are ignored. An ssh remote is matched under the host ssh really connects to: the first `HostName` from `~/.ssh/config` that applies, wildcards and `Include`d files followed. When a `Match` block or a wildcard `Include` could change it, the checkout gets no guardrails rather than a guess.
- **Submodules** are their own checkout, with their own remote.
- **Nothing to match.** A file outside any git checkout, a checkout with no `origin` or `upstream` Konvu knows, or a repository whose rules have not synced yet gets no guardrails: the hook exits 0 silently and records nothing. While steering is active and authorized, edits to the CLI's own files (`~/.konvu/guardrails/`) and to Codex's are still refused everywhere.

Events recorded for `guardrails flush` carry the repository found this way and the file's path relative to that checkout.

### CLI install

The background job downloads `guardrails-cli-<target>.tar.xz` for the pinned release from `https://dneaqnz3vqe4a.cloudfront.net/guardrails/<tag>/`. It checks the archive and the extracted `guardrails` binary against the sha256 values in [`plugins/guardrails/pins.txt`](plugins/guardrails/pins.txt) and refuses anything else. The binary is installed with an atomic rename, and `bin/current` moves to the new version only after both checks pass. Hooks run the plugin's own pinned version once it is installed, else the version `bin/current` names (the newest verified one), so the previous version keeps working until the new one verifies. Each session start checks the installed binary against the pin and removes one that fails. Versions older than the plugin's pin that are not current are removed a day after their install; a newer version, which a newer plugin may be running in another session, is never removed. An install lock keeps parallel sessions from downloading at the same time (every install step is also safe to run twice). A session that finds another one installing keeps using its verified CLI if it has one; on a fresh machine it waits up to 6 minutes for that install, and takes over a lock left by a killed session. Every session then runs `auth ensure` and `sync --force`, from its project directory when that still exists, else from the home directory. Forced sync refreshes the company setting at each session start. A quarantined workstation skips sync after `auth ensure` definitively reports no credential or refused access; transient auth failures still allow sync to try a surviving credential.

The pinned release is listed in [`pins.txt`](plugins/guardrails/pins.txt). `v0.6.31` was the first with `guardrails auth ensure`, `guardrails sync` and `guardrails flush` talking to Core's workstation lane. Against an older CLI the plugin detects a missing subcommand, skips it and logs it as `unsupported`, so the hooks stay silent rather than fail.

### What is stored where

| Location | Content |
| --- | --- |
| macOS Keychain, service `com.konvu.guardrails.workstation` | The workstation credential, written by `guardrails auth ensure`. On Linux it is `~/.konvu/guardrails/credentials.json` (mode 600). The deployment key is used only to enroll. |
| `~/.konvu/guardrails/bin/<version>/guardrails` | The verified CLI. `bin/current` names the version in use. |
| `~/.konvu/guardrails/profiles/<repository_id>/` | The synced rules for one repository. |
| `~/.konvu/guardrails/repos.json` | Written by `guardrails sync`: each repository's git remote URL, normalized, and its Konvu repository id. |
| `~/.konvu/guardrails/steering-state` | Last company agent-steering setting, written atomically after a complete sync. |
| `~/.konvu/guardrails/auth-quarantine` | Exists while workstation authentication is paused; cleared only after a complete authorized sync. |
| `~/.konvu/guardrails/authorization-expires-at` | Last authorized lease deadline as a Unix timestamp; an expired or unreadable lease pauses hooks and flush. |
| `~/.konvu/guardrails/queue.jsonl` | Trigger events waiting for `guardrails flush`. |
| `~/.konvu/guardrails/logs/plugin.log` | One status line per background step. CLI output is never logged: it goes to a private temp file that is deleted after the run, or swept an hour later if the run was killed. |
| `~/.konvu/guardrails/*.lock`, `auth-operation.json` | Short-lived locks, and an enrollment or rotation request kept until it completes so a retry reuses it. |

No file content ever leaves the laptop. Rules are downloaded and matched locally. The CLI sends Konvu only the repository's git remote, with any credentials in it stripped (to find its rules), and trigger events: which rule fired, when, in which repository and session, for which tool and hook, the decision, the edited file's path relative to the checkout, the rule's CWE and the control observations it came from, and a fingerprint of the synced rules. Never the code being written.

### Supported platforms

macOS (Apple silicon and Intel) and Linux with glibc (x86_64 and arm64), with Claude Code 2.1.139 or later (the hooks use exec form, which runs them without a shell). On Linux with musl the plugin does nothing. Under Rosetta 2 the native Apple silicon build is used. A home directory shared by machines of different CPU architectures (for example over NFS) is not supported. Windows is not supported: the hooks run `sh`, so without Git Bash on `PATH` every hook reports an error, and the plugin should not be enabled there. The scripts need `sh`, `curl`, `tar`, `cmp` and `sha256sum` or `shasum`, plus `xz` on Linux to unpack the archive (macOS `tar` reads it natively).

### Uninstall

1. Remove `guardrails@konvu`, the `konvu` marketplace and `KONVU_DEPLOYMENT_KEY` from your managed settings. On a single laptop, run `claude plugin uninstall guardrails@konvu` and `claude plugin marketplace remove konvu`, then remove `KONVU_DEPLOYMENT_KEY` from wherever you set it.
2. On each laptop, optionally remove the local state:

```sh
rm -rf ~/.konvu/guardrails
security delete-generic-password -s com.konvu.guardrails.workstation   # macOS only
```

## Versioning

Each plugin is versioned on its own, by the `version` in its `plugins/<name>/.claude-plugin/plugin.json` (semantic versioning; guardrails starts at `0.0.1`). Marketplace entries in `.claude-plugin/marketplace.json` carry no version, so `plugin.json` is the only source.

- **Releasing a plugin.** Claude Code updates an installed plugin only when its version changes, so a plugin is released by raising its own version; the other plugins are untouched. Every change to `plugins/<name>/` or to its marketplace entry raises that plugin's version in the same pull request. CI fails a pull request that changes a plugin without raising its version, and checks every push to `main` again, which catches two pull requests merged with the same new version (branch protection that requires branches to be up to date prevents that case).
- **Tagging.** After the merge, tag the merge commit `<name>--v<version>`, for example `guardrails--v0.0.1`, by running `claude plugin tag --push` in `plugins/<name>/`. This is Claude Code's own convention for plugin release tags: the name prefix keeps each plugin's history separate in one repository, and other plugins' dependency version ranges resolve against these tags.
- **Marketplace refs.** A marketplace added without a ref follows `main`: with auto-update on, laptops take each plugin release after it merges; without it, when someone runs `claude plugin update`. A `ref` on the marketplace source (or `#<ref>` on `claude plugin marketplace add`) pins the whole catalog to that commit. Pinning to `guardrails--v0.0.1` therefore holds guardrails at 0.0.1 and every other plugin at whatever version it had in that commit.

## Development

```sh
sh tests/guardrails_scripts_test.sh
shellcheck -x -P SCRIPTDIR -s sh plugins/guardrails/scripts/*.sh tests/*.sh
claude plugin validate --strict . && claude plugin validate --strict plugins/guardrails
```

To add a plugin, create `plugins/<name>/` with its own `.claude-plugin/plugin.json` (start at `0.0.1`) and add an entry with `"source": "./plugins/<name>"` and the same `name` to `.claude-plugin/marketplace.json`.

## License

[MIT](LICENSE)

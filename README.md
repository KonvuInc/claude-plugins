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
| `SessionStart` | Returns at once and starts a background job: install the pinned `guardrails` CLI if needed, then `guardrails auth ensure` and `guardrails sync`. | 5 s |
| `UserPromptSubmit` | `guardrails hook prompt-submit` | 5 s |
| `PreToolUse` on `Write`, `Edit`, `MultiEdit` | `guardrails hook pre-edit`: adds the matching rule's advice to the context, or denies the edit for a blocking rule. | 5 s |
| `PreToolUse` on `Bash` | `guardrails hook pre-command` | 5 s |
| `PostToolUse` on `Write`, `Edit`, `MultiEdit` | `guardrails hook post-edit` | 5 s |
| `Stop` | `guardrails hook final-sweep`, then `guardrails flush` in the background to send queued trigger events. | 10 s |

Every hook except `SessionStart` goes through `scripts/guardrails.sh`, which runs the cached CLI by absolute path with `SECPROFILE_DIR` set to the synced profile of the repository Claude Code was started in (`CLAUDE_PROJECT_DIR`), found through the `repos.json` index that `guardrails sync` writes. Files edited in another repository from that session get the starting repository's rules. The plugin fails open: when the CLI, the platform, the profile or the network is missing, the hook exits 0 and Claude Code carries on. Without a synced profile for the repository the CLI is not run at all. Only the CLI's own exit code 2 (its way of asking Claude Code to block) is passed through. An exit 2 that comes with the CLI's usage text means the CLI is too old for that hook, and fails open too.

### CLI install

The background job downloads `guardrails-cli-<target>.tar.xz` for the pinned release from `https://dneaqnz3vqe4a.cloudfront.net/guardrails/<tag>/`. It checks the archive and the extracted `guardrails` binary against the sha256 values in [`plugins/guardrails/pins.txt`](plugins/guardrails/pins.txt) and refuses anything else. The binary is installed with an atomic rename, and `bin/current` moves to the new version only after both checks pass. Hooks run the plugin's own pinned version once it is installed, else the version `bin/current` names (the newest verified one), so the previous version keeps working until the new one verifies. Each session start checks the installed binary against the pin and removes one that fails. Versions older than the plugin's pin that are not current are removed a day after their install; a newer version, which a newer plugin may be running in another session, is never removed. An install lock keeps parallel sessions from downloading at the same time (every install step is also safe to run twice). A session that finds another one installing keeps using its verified CLI if it has one; on a fresh machine it waits up to 6 minutes for that install, and takes over a lock left by a killed session. Every session then runs `auth ensure` and `sync` for its own project. `sync` runs even when `auth ensure` fails, so a failed rotation never stops a still-valid credential from refreshing the rules.

The pinned release is `v0.6.29`, the latest published one. It does not have `guardrails auth ensure`, `guardrails sync` or `guardrails flush` yet. The plugin detects a missing subcommand, skips it and logs it as `unsupported`, so with this pin the CLI is installed but no profile is synced and the hooks stay silent. The pin moves to the first guardrails release that ships those three commands.

### What is stored where

| Location | Content |
| --- | --- |
| macOS Keychain, service `com.konvu.guardrails.workstation` | The workstation credential, written by `guardrails auth ensure`. On Linux it is `~/.konvu/guardrails/credentials.json` (mode 600). The deployment key is used only to enroll. |
| `~/.konvu/guardrails/bin/<version>/guardrails` | The verified CLI. `bin/current` names the version in use. |
| `~/.konvu/guardrails/profiles/<repository_id>/` | The synced rules for one repository. |
| `~/.konvu/guardrails/repos.json` | Written by `guardrails sync`: each checkout's git remote, and the repository id Konvu resolved it to. |
| `~/.konvu/guardrails/queue.jsonl` | Trigger events waiting for `guardrails flush`. |
| `~/.konvu/guardrails/logs/plugin.log` | One status line per background step. CLI output is never logged: it goes to a private temp file that is deleted after the run, or swept an hour later if the run was killed. |
| `~/.konvu/guardrails/*.lock`, `auth-operation.json` | Short-lived locks, and an enrollment or rotation request kept until it completes so a retry reuses it. |

No file content ever leaves the laptop. Rules are downloaded and matched locally. The CLI sends Konvu only the repository's git remote, with any credentials in it stripped (to find its rules), and trigger events: which rule fired, when, in which repository and session, for which tool, the decision, and the edited file's path relative to the checkout. Never the code being written.

### Supported platforms

macOS (Apple silicon and Intel) and Linux with glibc (x86_64 and arm64), with Claude Code 2.1.139 or later (the hooks use exec form, which runs them without a shell). On Linux with musl the plugin does nothing. Under Rosetta 2 the native Apple silicon build is used. A home directory shared by machines of different CPU architectures (for example over NFS) is not supported. Windows is not supported: the hooks run `sh`, so without Git Bash on `PATH` every hook reports an error, and the plugin should not be enabled there. The scripts need `sh`, `curl`, `tar` and `sha256sum` or `shasum`, plus `xz` on Linux to unpack the archive (macOS `tar` reads it natively).

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

# pearls-ptui

`pearls-ptui` is a lightweight terminal UI for the Pearls issue tracker, built with Bash, `fzf`, and `jq`.

It wraps common `prl` workflows (browse ready/open issues, inspect details, create, update, and run status-gated automation scripts) into a keyboard-driven interface.

## Features

- Repository picker for multi-repo workflows
- Ready queue and open issue views
- Interactive issue detail screen
- In-place update workflow for:
  - Title
  - Priority
  - Status
  - Add/remove labels
  - Description editing via `$EDITOR`
- New issue creation with editor-backed description
- Configurable per-issue actions (`[Run] ...`) filtered by issue status
- Script execution logs with failure-aware viewing

## Requirements

Install these commands and make sure they are on `PATH`:

- `prl`
- `jq`
- `fzf`
- `bash`
- `less` (for JSON/log viewing)

Optional (if using bundled automation scripts):

- `git`
- `opencode`

## Installation

Clone this repository:

```bash
git clone <your-repo-url> pearls-tui
cd pearls-tui
```

Make the main script executable:

```bash
chmod +x ptui.sh
```

(Optional) put it on your PATH:

```bash
ln -s "$PWD/ptui.sh" /usr/local/bin/ptui
```

## Quick Start

Run from a Pearls-enabled repo (or any repo you plan to add to config):

```bash
./ptui.sh
```

On first run, it creates:

- Config dir: `${XDG_CONFIG_HOME:-$HOME/.config}/ptui`
- Config file: `${XDG_CONFIG_HOME:-$HOME/.config}/ptui/config.json`

Default config includes:

- One repo: the current directory (`$PWD` at first launch)
- One sample script action named `Spawn Agent`

## Configuration

Configuration file path:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/ptui/config.json
```

Schema:

- `repos`: array of absolute repo paths
- `scripts`: array of script descriptors
  - `name`: menu label
  - `target_status`: one of a specific status (`open`, `in_progress`, `blocked`, `deferred`, `closed`) or `any`
  - `command`: shell command to execute

Example:

```json
{
  "repos": [
    "/Users/me/src/project-a",
    "/Users/me/src/project-b"
  ],
  "scripts": [
    {
      "name": "Start Agent",
      "target_status": "open",
      "command": "/Users/me/src/pearls-tui/scripts/spawn-agent.sh"
    },
    {
      "name": "Reopen in Triage",
      "target_status": "blocked",
      "command": "prl update \"$PEARL_ID\" --status open"
    },
    {
      "name": "Echo Context",
      "target_status": "any",
      "command": "echo Repo=$REPO_PATH Pearl=$PEARL_ID"
    }
  ]
}
```

## Runtime Environment for Scripts

When you run a configured action from the issue screen, `ptui` exports:

- `REPO_PATH`: currently selected repository path
- `PEARL_ID`: selected issue ID

Scripts run from `REPO_PATH`.

Output behavior:

- stdout/stderr are streamed live to terminal
- output is also captured to a temp log file
- on failure, the log is opened automatically
- after execution, you can choose to view the full log

## Main Menu Flow

1. `Ready Queue`: shows unblocked issues from `prl ready --json`
2. `All Open`: shows open issues from `prl list --status open --json`
3. `Create New Pearl`: prompts title/priority/labels + editor description
4. `Change Repo`: re-open repository picker
5. `Exit`

Issue action menu includes:

- `[Update Pearl]`
- `[View JSON]`
- `[Run] <Script Name>` for matching script rules
- `[Back]`

## Bundled Scripts

Repository includes:

- `scripts/spawn-agent.sh`
- `scripts/remove-worktree.sh`
- `scripts/cc-run.sh`

These are examples and may require local adaptation before production use.

### Notes

- Ensure your config `command` points to real script paths on your machine.
- If you use shell paths with `~`, prefer `$HOME` in script variables to avoid literal-tilde path bugs in quoted strings.
- `scripts/cc-run.sh` currently expects OpenCode CLI and session semantics; review before relying on it for critical workflows.

## Troubleshooting

### `Error: '<cmd>' is not installed or not in PATH.`

Install the missing command (`prl`, `jq`, or `fzf`) and re-run.

### No repos shown

Check `config.json` has at least one valid path in `repos`.

### Script appears in menu but fails immediately

- Confirm executable bit: `chmod +x /path/to/script.sh`
- Confirm command path in config is valid
- Confirm script works standalone
- Check failure log path shown after run

### `mktemp` / log file errors while running scripts

Use the current `ptui.sh` from this repository (contains a hardened temp-log creation path and fallback).

### `prl` commands fail

Run the same command manually (for example, `prl list --status open --json`) inside the selected repo to confirm Pearls is initialized and healthy.

## Security Considerations

Configured `scripts[].command` values are executed via `eval`.

Treat `config.json` as trusted input only:

- Do not run `ptui` with untrusted config files.
- Avoid injecting user-controlled strings into `command` fields.

## Development

Useful checks:

```bash
bash -n ptui.sh
shellcheck ptui.sh scripts/*.sh
```

If you submit changes, include before/after behavior notes for:

- issue creation/update paths
- script execution and logging paths
- config compatibility

## License

MIT

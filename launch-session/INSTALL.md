# Installing launch-session

## Prerequisites

- **A supported terminal — auto-detected** (run your Claude Code session *inside* one):
  - **tmux** (`$TMUX`) — `tmux` CLI. **Cross-platform** (macOS/Linux/BSD/WSL).
  - **cmux** (`$CMUX_SURFACE_ID`) — `cmux` CLI. macOS.
  - **iTerm2** (macOS, `$TERM_PROGRAM=iTerm.app`) — AppleScript via `osascript`.
  - **Ghostty** (macOS, `$TERM_PROGRAM=ghostty`) — AppleScript via `osascript`.
  - Inside none, the skill only prints a manual command.
- **Claude Code** with cross-session messaging (`ListAgents` / `SendMessage`) — stock, target-independent.
- **bash** + coreutils (`grep`, `sed`, `awk`) + `openssl`. No Python/Node. iTerm2/Ghostty are macOS-only (AppleScript); tmux is fully portable.
- **macOS Automation permission** — the first iTerm2/Ghostty launch triggers a one-time "allow … to control iTerm2/Ghostty?" system prompt you must Allow (System Settings → Privacy & Security → Automation).

## Setup

1. Place the skill directory where Claude Code discovers skills:

   ```
   ~/.claude/skills/launch-session/
     SKILL.md
     launch.sh     # the driver — must be executable: chmod +x launch.sh
     README.md
     INSTALL.md
   ```

   Ensure `launch.sh` is executable (`chmod +x ~/.claude/skills/launch-session/launch.sh`). `SKILL.md` calls it by that path.

2. (Optional) Create a config file to set defaults — mode, name prefix, split direction:

   ```sh
   mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/launch-session"
   cat > "${XDG_CONFIG_HOME:-$HOME/.config}/launch-session/config" <<'EOF'
   LAUNCH_SESSION_MODE=tab
   LAUNCH_SESSION_PREFIX=
   LAUNCH_SESSION_SPLIT_DIR=down
   EOF
   ```

   All settings have working defaults, so this file is not required.

3. (Optional) To mute launched children's cmux turn-done desktop notifications, install a companion cmux notification hook that matches a child's surface UUID against the registry and suppresses turn-complete banners unless the row's `cmuxnotify` column is `1` (set per launch with `--cmuxnotify`). This hook is external to the skill and not required — see the README's Notifications section.

## Verify

1. Confirm the driver detects your terminal:

   ```sh
   ~/.claude/skills/launch-session/launch.sh detect   # → tmux | cmux | iterm2 | ghostty | none
   ```

2. Confirm the skill is discoverable — in Claude Code, `/launch-session` should resolve, or the agent should offer it when you ask to "launch it in a new tab."

3. Smoke test: draft a trivial prompt and launch it. The launcher reports a session name (e.g. `mytask-a3f9c1`) and confirms two-way messaging is ready. Close it afterward with `launch.sh close --name <name>`. On iTerm2/Ghostty, the first launch pops the macOS Automation prompt — Allow it.

No build step is needed — `launch.sh` is a bash script driving each terminal's native CLI or AppleScript.

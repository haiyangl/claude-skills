# Installing launch-session

## Prerequisites

- **cmux** — the terminal multiplexer this skill drives. You must run your Claude Code session *inside* a cmux surface; the skill reads `$CMUX_SURFACE_ID` and calls the `cmux` CLI for placement and teardown. Outside cmux the skill only prints a manual command.
- **Claude Code** with cross-session messaging (`ListAgents` / `SendMessage`) — stock. This is what makes launched sessions addressable by name.
- A **POSIX shell** with coreutils (`grep`, `sed`, `awk`, `openssl`). No Python, Node, or other runtime required.

## Setup

1. Place the skill directory where Claude Code discovers skills:

   ```
   ~/.claude/skills/launch-session/
     SKILL.md
     README.md
     INSTALL.md
   ```

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

## Verify

1. Confirm cmux is on `PATH` and you are inside a surface:

   ```sh
   cmux version && echo "surface: ${CMUX_SURFACE_ID:?not in a cmux surface}"
   ```

2. Confirm the skill is discoverable — in Claude Code, `/launch-session` should resolve, or the agent should offer it when you ask to "launch it in a new tab."

3. Smoke test: draft a trivial prompt and launch it. The launcher should report a session name (e.g. `mytask-a3f9c1`) and confirm two-way messaging is ready. Close it afterward via the skill's teardown.

No build or dependency-install step is needed — the skill is plain Markdown driving the `cmux` CLI.

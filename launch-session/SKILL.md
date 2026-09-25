---
name: launch-session
description: Use when you have a prompt for a fresh Claude Code session and want to actually START it, not just print it for copy-paste — "launch it in a new tab", "start that session", "spawn a session for this", "kick it off", "/launch-session". Follows drafting a dispatch/implementation prompt.
---

# Launch Session

## Overview

Start a fresh `claude` session in a new tab (or pane) of your terminal — **cmux, tmux, iTerm2, or Ghostty, auto-detected** — seeded with a prompt drafted in this session, and wired for **two-way messaging**: you can `SendMessage` to it by name, and it can report back to you. Turns a drafted-but-unrun prompt into a live, addressable session with no copy-paste.

All the placement/seed/teardown logic lives in a driver script, **`launch.sh`** (shipped beside this file). The skill just writes the prompt to a file and calls `launch.sh place`; teardown is `launch.sh close`. The two-way messaging layer is Claude Code's and works the same on every target.

## Prerequisites

- **A supported terminal — auto-detected in this precedence:**
  - **tmux** — `$TMUX` set (cross-platform: macOS/Linux/BSD/WSL)
  - **cmux** — `$CMUX_SURFACE_ID` set (macOS)
  - **iTerm2** — macOS + `$TERM_PROGRAM=iTerm.app` (driven via AppleScript)
  - **Ghostty** — macOS + `$TERM_PROGRAM=ghostty` (driven via AppleScript)
  - Multiplexers win over the host terminal (they run *inside* it), and **cmux itself reports `TERM_PROGRAM=ghostty`**, so the cmux check must precede the Ghostty check. Inside none of these, the skill prints a manual command.
- **Claude Code cross-session messaging** — `ListAgents` / `SendMessage`, stock. This is what makes the launched session addressable by name; it is target-independent.
- **bash** + coreutils, and `openssl` (for the random name tail). The two AppleScript targets are macOS-only; the tmux target is fully cross-platform.

## Modes

Where the launched session is placed. Selection precedence: **per-call `--mode`** > **`$LAUNCH_SESSION_MODE`** > config file > default **`tab`**.

| mode | placement |
|------|-----------|
| `tab` (default) | a new tab (cmux/iTerm2/Ghostty) or a new window (tmux) beside the launcher |
| `pane` | a split sharing a container the launches stack into — cmux bottom pane / tmux `launch-session` window (both keyed per workspace/session, auto-collapsing on last close) / iTerm2 + Ghostty split of the launcher's current tab |

`pane` split direction defaults to `down`. **Naming:** the child's handle (its `SendMessage`/`ListAgents` name) is `<prefix>-<slug>-<rand>`, or `<slug>-<rand>` when the prefix is empty.

## Configuring

Resolved **per-call arg > environment variable > config file > built-in default**:

| setting | env var / config key | per-call | default |
|---------|----------------------|----------|---------|
| mode | `LAUNCH_SESSION_MODE` | `--mode` | `tab` |
| name prefix | `LAUNCH_SESSION_PREFIX` | `--prefix` | *(empty)* |
| split direction | `LAUNCH_SESSION_SPLIT_DIR` | `--dir` | `down` |

Config file (shell-agnostic): `${XDG_CONFIG_HOME:-$HOME/.config}/launch-session/config` (plain `KEY=value` lines), sourced by `launch.sh` on every launch.

## Notifications

**cmux only** — tmux/iTerm2/Ghostty have no desktop-notification system this skill touches, so `--cmuxnotify` is a no-op there.

Under cmux, launched children are **quiet by default**: their turn-done desktop banner / sound / unread ring are suppressed by the `mute-launched-children` cmux notification hook (`~/.config/cmux/hooks/mute-launched-children.sh`), which matches the child's surface UUID against the registry. A child still notifies when it **needs input or permission**. Pass **`--cmuxnotify`** to keep a launch loud (writes `cmuxnotify=1` in its registry row). This is about cmux desktop notifications only — NOT launcher↔child SendMessage, which is unaffected.

## When to use

You have a prompt ready — just drafted via `draft-impl-prompt`, or written inline this turn — and want it running now. NOT for doing the work yourself in this session; this only dispatches.

## Steps

1. **Write the prompt to a file** at `/tmp/launch-session/<slug>.txt` — a short slug (ticket id or task name); `mkdir -p` the directory first. Write the prompt CONTENT only — no dashed rules, no commentary; `launch.sh` appends the coordination footer. **Use this literal `/tmp/…` path, NOT `$TMPDIR`** — the Write tool cannot expand `$TMPDIR`, and on macOS `$TMPDIR` is `/var/folders/…/T/`, not `/tmp`; the `--file` below must resolve to this exact file.

2. **Get your own session name.** Call `ListAgents`; the first line reads `This session is <MAIN> [ref]`. That `<MAIN>` is the address the child reports back to — pass it as `--launcher`.

3. **Place the child.** Call the driver — it detects the target, generates the name, appends the footer, opens the tab/pane, seeds `claude -n <name> "$(cat <file>)"`, and records the child. It prints `NAME=…`, `TARGET=…`, `MODE=…`, `ID=…`.

   ```bash
   ~/.claude/skills/launch-session/launch.sh place \
     --slug "<slug>" \
     --file "/tmp/launch-session/<slug>.txt" \
     --launcher "<MAIN>" \
     --mode tab            # or pane; omit for config/default. optional: --prefix P  --dir down|up|left|right  --cmuxnotify
   ```

   If it prints `not inside a supported terminal …`, run the printed manual `claude "$(cat …)"` yourself and stop.

4. **Verify + report.** After ~10s, call `ListAgents` and confirm the printed `NAME` is a peer (registration lags 5–20s). **Headline your report with `NAME`** — it is the `SendMessage` handle. Also state the launcher, the target+mode, and that two-way messaging is ready. Do not switch to it.

   Example: `Launched **ls-task-a3f9c1** (tmux, tab; message it with SendMessage to:"ls-task-a3f9c1"; it reports back to <MAIN>).`

## Talking to the launched session

- **You → child:** `SendMessage({to: "<NAME>", message: "…"})` — lands as a user turn in the child's conversation.
- **Child → you:** the child `SendMessage`s to `<LAUNCHER>`; the reply arrives here as a `<cross-session-message>` whose `from-name="<NAME>"` — that wakes this session and tells you which child replied.

Both directions address sessions by **claude session name** — not a terminal handle, and no id discovery is needed (the script generated the name).

## Closing a launched session

**This is agent-side** — closing a launched tab is `launch.sh close`, run via Bash. Do NOT tell the user to close it themselves. When the child reports done, or the user says "close the tab(s)" / "close that session" / "stop it", run the script — it looks up the registry row(s), dispatches on `target`, and kills the tab/pane/window **and** the claude inside it in one step.

- **One child, by name:**
  ```bash
  ~/.claude/skills/launch-session/launch.sh close --name "<NAME>"
  ```
- **All children YOU launched** (e.g. the user says "close the tabs") — pass your own launcher name (`<MAIN>` from `ListAgents`):
  ```bash
  ~/.claude/skills/launch-session/launch.sh close --launcher "<MAIN>"
  ```

In `pane` mode the shared container auto-collapses once its last child closes. The registry stores a **stable** id (cmux surface UUID / tmux `@window`·`%pane` id / iTerm2 session id / Ghostty tab·terminal id) — never a live index — so a later close always finds the right target.

## Notes

- **The logic is in `launch.sh`** — a bash script with `detect` / `place` / `close` subcommands and one driver per target (`cmux`/`tmux`/`iterm2`/`ghostty`). To add a target or change placement, edit the script, not this doc. Registry (TSV): `name, mode, teardown_id, container_id, slug, launcher, ts, cmuxnotify, target` under `${XDG_STATE_HOME:-$HOME/.local/state}/launch-session/sessions.tsv`; rows written before the `target` column read as `cmux`.
- **Focus:** all four targets place the child **unfocused** — the launcher keeps focus. cmux/tmux open the child in the background natively; iTerm2 and Ghostty are driven by AppleScript (which selects the new tab), so their drivers re-select the launcher tab afterward. The launched tab stays visible in the tab bar.
- **macOS Automation permission (TCC):** the first iTerm2/Ghostty launch triggers a one-time "allow … to control iTerm2/Ghostty?" prompt the user must Allow, or the AppleScript fails.
- **Seeding is race-free per target:** cmux `send` queues until the PTY is ready; tmux `send-keys`; iTerm2 `write text`; Ghostty surface-config `initial input`. All arrange for the child shell — not the launcher — to expand `$(cat FILE)`.
- `-n "$NAME"` sets the claude session's display name (the messaging handle) on every target. Under cmux it also labels the tab and suppresses `workspaceAutoNaming`; under tmux/iTerm2/Ghostty the tab keeps its default name (the handle is still `$NAME`).
- One tab/pane = one fresh session. Launch several for parallel handoffs; in `pane` mode they stack in the one shared container.

## Common mistakes

- Wrapping the drafted content in dashed rules or commentary — write the raw prompt only; `launch.sh` adds the ONE coordination footer.
- Writing the step-1 prompt to a path that differs from `--file` — e.g. literal `/tmp` vs `$TMPDIR` (macOS `$TMPDIR` = `/var/folders/…/T/`). They diverge and the child launches with the footer but NO task; the script's `[ -s file ]` guard catches an empty file but not a wrong path.
- Closing by a live ref instead of by name — always `launch.sh close --name <NAME>`; the script resolves the stored stable id.
- Assuming Ghostty support means the skill is macOS-only — the **tmux** driver is fully cross-platform; only the cmux/iTerm2/Ghostty drivers are macOS.

# launch-session

> A Claude Code skill that hands a drafted prompt to a fresh, addressable `claude` session — no copy-paste, with two-way messaging between the two.

## Why

Picture this: you have a coding agent open, and you've just drafted a prompt for a *second* piece of work — a parallel implementation, a review, a spike. Today, handing it off is clumsy. You copy the prompt into a new terminal, launch `claude` by hand, and lose the thread between the two sessions. And once the second one is running, you have no clean way to talk to it — no name to address it by, no way for it to tell you when it's done.

`launch-session` closes that gap. From inside one Claude Code session (the **launcher**), it starts a fresh `claude` session seeded with your drafted prompt — no copy-paste — and wires up **two-way messaging**: the launcher can message the child by name, and the child can report back. The launcher keeps coordinating while the child works.

That gives you a real coordination hierarchy:

```
launcher ─┬─ launched session A ─┬─ subagent
          │                      └─ subagent
          ├─ launched session B ─── subagent
          └─ launched session C
```

One session hands out work to several fresh sessions, each of which can fan out to its own subagents — and every launched session stays addressable from the top. It turns a single agent into the coordinator of a small fleet.

## What it does

- Writes your prompt to a file and seeds a new `claude` session with it — no manual paste.
- Names the child deterministically so it's addressable immediately (no post-launch id discovery).
- Appends a short coordination footer telling the child who launched it and how to reply.
- Records the child in a small registry so you can tear it down later by a stable handle.
- Places the child according to a **mode** — a new tab/window, or a shared pane/window that launches stack into — in whichever terminal you're in (**cmux, tmux, iTerm2, or Ghostty — auto-detected**).

## Requirements

- **A supported terminal — auto-detected** (precedence top→bottom):
  - **tmux** — `$TMUX` set. Cross-platform (macOS/Linux/BSD/WSL) — the one fully portable target.
  - **cmux** — https://www.cmux.dev/ (`brew install --cask cmux`), `$CMUX_SURFACE_ID` set. macOS.
  - **iTerm2** — macOS, `$TERM_PROGRAM=iTerm.app`. Driven via AppleScript.
  - **Ghostty** — macOS, `$TERM_PROGRAM=ghostty`. Driven via AppleScript.
  - Multiplexers win over the host terminal (they run inside it); cmux reports `TERM_PROGRAM=ghostty`, so cmux is checked before Ghostty. Inside none, the skill prints a manual command.
- **Claude Code** with cross-session messaging (`ListAgents` / `SendMessage`) — stock, and target-independent.
- **bash** + coreutils + `openssl`. The two AppleScript targets are macOS-only; the tmux target is fully cross-platform. On macOS, iTerm2/Ghostty need a one-time **Automation permission** (a system prompt you Allow on first use).

## Install

Drop the skill directory where your agent looks for skills, e.g.:

```
~/.claude/skills/launch-session/
  SKILL.md      # how the agent uses it
  launch.sh     # the driver (detect / place / close; one function per target)
  README.md
  INSTALL.md
```

The agent picks it up by its `SKILL.md` frontmatter; invoke it with `/launch-session` or by asking to "launch it in a new tab" / "start that session". `SKILL.md` calls `launch.sh` — keep them together.

## Usage

1. Draft (or have the agent draft) the prompt for the work you want handed off.
2. Say **"launch it"** — or `/launch-session` — optionally with a mode:

   ```
   /launch-session --mode=pane
   ```

3. The launcher reports the child's name. Message it any time:

   > SendMessage to `"task-a3f9c1"`: "how's the migration going?"

   The child reports back to the launcher on its own when it finishes or gets blocked.

4. When it's done — or you say **"close the tabs"** — the launcher tears it down: `launch.sh close --name <name>` for one, or `--launcher <MAIN>` for all of them.

## Modes

Where the launched session is placed. Default is `tab`.

| mode | placement |
|------|-----------|
| `tab` | a new tab (cmux/iTerm2/Ghostty) or window (tmux) beside the launcher |
| `pane` | a split into a shared container: cmux bottom pane · tmux `launch-session` window (both keyed per workspace/session, auto-collapsing on last close) · iTerm2/Ghostty split of the launcher's current tab |

`pane` splits downward by default; change with the `SPLIT_DIR` setting (`down`/`up`/`left`/`right`).

## Configuration

Three settings, each resolved **per-call argument > environment variable > config file > built-in default**:

| setting | env var / config key | default |
|---------|----------------------|---------|
| mode | `LAUNCH_SESSION_MODE` | `tab` |
| name prefix | `LAUNCH_SESSION_PREFIX` | *(empty)* |
| pane split direction | `LAUNCH_SESSION_SPLIT_DIR` | `down` |

**Config file (recommended — shell-agnostic):** `${XDG_CONFIG_HOME:-$HOME/.config}/launch-session/config`, sourced on every launch:

```sh
# ~/.config/launch-session/config
LAUNCH_SESSION_MODE=pane
LAUNCH_SESSION_PREFIX=worker
```

**Environment variable:** must be exported where a *non-interactive* shell sees it — `~/.zshenv` for zsh (not `~/.zshrc`/`~/.zsh.d`), a `$BASH_ENV` file for bash. An env var overrides the config file. Prefer the config file to avoid this gotcha.

**Per-call:** `--mode=` / `--prefix=` / `--cmuxnotify` on the invocation, overriding everything for that one launch.

## Notifications (optional)

Launched children can have their **cmux turn-done desktop notification** (banner / sound / unread ring) muted, so a fleet of workers doesn't flood you with pings — while a child that **needs input** still notifies. This is opt-in via a companion cmux notification hook (not part of the skill itself): the hook matches a child's surface UUID against the registry and reads its `cmuxnotify` column (`0` = quiet, `1` = loud). Pass **`--cmuxnotify`** on a launch to mark that child loud (`cmuxnotify=1` in its registry row); with no such hook installed the flag is a harmless no-op. This affects only cmux desktop notifications — launcher↔child messaging is unaffected either way.

## Session names

The child's name — its messaging handle and tab label — is:

```
<prefix>-<slug>-<rand>     # e.g. worker-eng1234-a3f9c1
<slug>-<rand>              # when prefix is empty (default), e.g. eng1234-a3f9c1
```

`<slug>` is a short task label you (or the agent) pick; `<rand>` is a random tail so parallel launches of the same task never collide. Set a prefix to group a batch of launches under a common label.

## Talking to a launched session

- **You → child:** `SendMessage` to the child's name; it lands as a user turn in the child's conversation.
- **Child → you:** the child `SendMessage`s the launcher; the reply wakes the launcher and carries the child's name so you know which one replied.

Both directions address sessions by **name** — no multiplexer handles, no id discovery.

## Closing a launched session

Closing is **agent-side** — it's `launch.sh close`, run by the launcher; you don't close launched tabs by hand.

- **One child:** `launch.sh close --name <NAME>`
- **All children a launcher spawned** (e.g. you tell it "close the tabs"): `launch.sh close --launcher <MAIN>`, where `<MAIN>` is the launcher's own session name.

Either form looks up the registry row(s) and dispatches on each child's `target` (cmux `close-surface` / tmux `kill-pane`·`kill-window` / iTerm2 close session / Ghostty close tab·terminal), killing the tab/pane/window and the `claude` inside it in one step. It closes by a **stable** stored id, never a live index. In `pane` mode the shared container collapses automatically once its last child closes.

## Limitations

- **Needs cmux, tmux, iTerm2, or Ghostty.** Placement/teardown are terminal operations; inside none of them the skill prints a manual command. Only the **tmux** driver is cross-platform — cmux/iTerm2/Ghostty are macOS.
- **AppleScript targets need Automation permission.** iTerm2/Ghostty are driven with AppleScript, so macOS shows a one-time "allow … to control iTerm2/Ghostty?" prompt on first use.
- **Desktop-notification muting is cmux-only** (`--cmuxnotify`); the other targets have no such notifications.
- **No headless mode.** A `claude --bg` background session registers as a peer but does not reliably wake to process follow-up messages while idle, so it can't hold the two-way loop this skill depends on. Launched sessions are real interactive sessions in a tab or pane.
- **Launches are unfocused.** On every target the launcher keeps focus; the child opens as a **background tab** you can switch to. On **Ghostty**, make the tab bar visible so background tabs aren't easy to miss — `macos-titlebar-style = native` and `window-show-tab-bar = always` in `~/.config/ghostty/config` (the default `tabs` titlebar style crams tabs into a thin, cut-off strip).
- **State is local.** The files below live on the launching machine only.

## Files & state

| path | what | lifetime |
|------|------|----------|
| `${XDG_STATE_HOME:-$HOME/.local/state}/launch-session/sessions.tsv` | registry — one tab-separated row per launched session (`name`, `mode`, `teardown_id`, `container_id`, `slug`, `launcher`, `timestamp`, `cmuxnotify`, `target`); `launch.sh close` looks a child up by name and dispatches on `target`. `teardown_id` is the stable close handle (cmux surface UUID / tmux `@window`·`%pane` / iTerm2 session id / Ghostty tab·terminal id) | durable |
| `${XDG_STATE_HOME:-$HOME/.local/state}/launch-session/pane-<workspace-uuid>` (cmux) / `tmux-win-<session-id>` (tmux) | the shared `pane` container id for that cmux workspace / tmux session, so repeated `pane` launches reuse the same container | durable (per workspace/session) |
| `${TMPDIR:-/tmp}/launch-session/<slug>.txt` | the seeded prompt (content + coordination footer) handed to the child | ephemeral |

The state directory is safe to delete when no launched sessions are live — it's rebuilt on the next launch. Deleting it while sessions are running just means you lose the stored handles for teardown (close those tabs/panes by hand).

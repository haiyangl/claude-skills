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
- Places the child according to a **mode** — a new tab, or a shared bottom pane that many launches stack into.

## Requirements

- **cmux** — the terminal multiplexer this skill drives: https://www.cmux.dev/ (install: `brew install --cask cmux`). You must be running inside a cmux surface (`$CMUX_SURFACE_ID` set). Outside cmux the skill degrades to printing a command for you to run manually.
- **Claude Code** with cross-session messaging (`ListAgents` / `SendMessage`) — stock. This is what makes launched sessions addressable by name.
- A POSIX shell with coreutils (`grep`, `sed`, `awk`). No Python required.

## Install

Drop the skill directory where your agent looks for skills, e.g.:

```
~/.claude/skills/launch-session/
  SKILL.md
  README.md
```

The agent picks it up by its `SKILL.md` frontmatter; invoke it with `/launch-session` or by asking to "launch it in a new tab" / "start that session".

## Usage

1. Draft (or have the agent draft) the prompt for the work you want handed off.
2. Say **"launch it"** — or `/launch-session` — optionally with a mode:

   ```
   /launch-session --mode=pane
   ```

3. The launcher reports the child's name. Message it any time:

   > SendMessage to `"task-a3f9c1"`: "how's the migration going?"

   The child reports back to the launcher on its own when it finishes or gets blocked.

## Modes

Where the launched session is placed. Default is `tab`.

| mode | placement | good for |
|------|-----------|----------|
| `tab` | a new terminal **tab** beside the launcher | one-off handoffs; watching a child in its own tab |
| `pane` | a **shared bottom pane** — the first launch creates it, later ones add tabs **inside the same pane** | fan-out: many children kept together, out of the main tab strip |

`pane` splits downward by default; change with the `SPLIT_DIR` setting (`down`/`up`/`left`/`right`). The pane auto-collapses once its last child is closed.

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

**Per-call:** `--mode=` / `--prefix=` on the invocation, overriding everything for that one launch.

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

Both directions address sessions by **name** — no cmux handles, no id discovery.

## Closing a launched session

Close it by the stable handle stored in the registry; that kills the cmux surface and the `claude` inside it in one step. In `pane` mode the shared pane collapses automatically once its last child closes. (The skill's "Closing a launched session" section has the exact command.)

## Limitations

- **cmux-only.** The placement and teardown are cmux operations. Outside cmux the skill just prints a manual command.
- **No headless mode.** A `claude --bg` background session registers as a peer but does not reliably wake to process follow-up messages while idle, so it can't hold the two-way loop this skill depends on. Launched sessions are real interactive sessions in a tab or pane.
- **State is local.** The files below live on the launching machine only.

## Files & state

| path | what | lifetime |
|------|------|----------|
| `${XDG_STATE_HOME:-$HOME/.local/state}/launch-session/sessions.tsv` | registry — one tab-separated row per launched session (`name`, `mode`, `surface_uuid`, `pane_uuid`, `slug`, `launcher`, `timestamp`); teardown looks up a session's surface handle here by name | durable |
| `${XDG_STATE_HOME:-$HOME/.local/state}/launch-session/pane-<workspace-uuid>` | one file per cmux workspace holding that workspace's shared bottom-pane UUID, so repeated `pane` launches reuse the same pane | durable (per workspace) |
| `${TMPDIR:-/tmp}/launch-session/<slug>.txt` | the seeded prompt (content + coordination footer) handed to the child | ephemeral |

The state directory is safe to delete when no launched sessions are live — it's rebuilt on the next launch. Deleting it while sessions are running just means you lose the stored handles for teardown (close those tabs/panes by hand).

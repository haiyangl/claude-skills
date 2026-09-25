---
name: launch-session
description: Use when you have a prompt for a fresh Claude Code session and want to actually START it, not just print it for copy-paste — "launch it in a new tab", "start that session", "spawn a session for this", "kick it off", "/launch-session". Follows drafting a dispatch/implementation prompt.
---

# Launch Session

## Overview

Start a fresh `claude` session in cmux, seeded with a prompt drafted in this session, and wired for **two-way messaging**: you can `SendMessage` to it by name, and it can report back to you. Turns a drafted-but-unrun prompt into a live, addressable session with no copy-paste.

The child is placed according to a **mode** (see below); everything else — seeding the prompt, the coordination footer, registration, teardown — is identical across modes.

## Prerequisites

- **cmux** — the terminal multiplexer this skill drives (`cmux` on `$PATH`, and `$CMUX_SURFACE_ID` set, i.e. you are running inside a cmux surface). Outside cmux the skill degrades to printing a manual command.
- **Claude Code cross-session messaging** — `ListAgents` / `SendMessage`, stock in Claude Code. This is what makes the launched session addressable by name.
- POSIX shell + coreutils (`grep`, `sed`, `awk`, `comm`). No Python required.

## Modes

Where the launched session lives. Selection precedence: **per-call argument** (e.g. `/launch-session --mode=pane`) > **`$LAUNCH_SESSION_MODE`** env var > default **`tab`**.

| mode | placement | good for |
|------|-----------|----------|
| `tab` (default) | a new terminal **tab** beside the launcher | one-off handoffs; watching a child in its own tab |
| `pane` | a **shared bottom pane** — the first `pane` launch creates the pane, every later one adds a tab **inside that same pane** | fan-out: many children kept together, out of the main tab strip |

`pane` split direction defaults to `down` (bottom).

**Naming.** The child's session name (its `SendMessage`/`ListAgents` handle and tab label) is `<prefix>-<slug>-<rand>`, or just `<slug>-<rand>` when the prefix is empty (the default). Set a prefix to group launches under a common label. Keep it short and identifier-safe — it becomes the address you message.

## Configuring

Three settings, each resolved **per-call argument > environment variable > config file > built-in default**:

| setting | env var | config key | default |
|---------|---------|-----------|---------|
| mode | `LAUNCH_SESSION_MODE` | `LAUNCH_SESSION_MODE` | `tab` |
| name prefix | `LAUNCH_SESSION_PREFIX` | `LAUNCH_SESSION_PREFIX` | *(empty)* |
| pane split direction | `LAUNCH_SESSION_SPLIT_DIR` | `LAUNCH_SESSION_SPLIT_DIR` | `down` |

- **Config file (recommended, shell-agnostic):** `${XDG_CONFIG_HOME:-$HOME/.config}/launch-session/config` (override the path with `$LAUNCH_SESSION_CONFIG`). It is `.`-sourced by the skill on every launch, so it works regardless of your shell. Plain shell assignments:

  ```sh
  # ~/.config/launch-session/config
  LAUNCH_SESSION_MODE=pane
  LAUNCH_SESSION_PREFIX=worker
  LAUNCH_SESSION_SPLIT_DIR=down
  ```

- **Environment variable:** must be visible to the skill's **non-interactive** shell — for zsh that means `~/.zshenv` (NOT `~/.zshrc`/`~/.zsh.d`, which are interactive-only and never reach the tool shell); for bash, a file referenced by `$BASH_ENV`. An env var overrides the config file. Prefer the config file to avoid this shell-specific gotcha.

- **Per-call argument:** e.g. `/launch-session --mode=pane --prefix=worker` — the agent sets `MODE=`/`PREFIX=` for that one launch, overriding everything.

## Notifications

Launched children are **quiet by default**: their turn-done desktop banner / sound / unread ring are suppressed by the `mute-launched-children` cmux notification hook (`~/.config/cmux/hooks/mute-launched-children.sh`), which matches the child's surface UUID against the registry. A child still notifies when it **needs input or permission** — only turn-complete is muted.

Pass **`--cmuxnotify`** to keep a specific launch loud: the agent sets `CMUXNOTIFY=1` for that launch (a per-call flag, no env/config form), which writes `cmuxnotify=1` in the child's registry row; the hook then leaves that child's cmux notifications untouched. The name is deliberate — this is about **cmux desktop notifications** (banner/sound/unread ring), NOT launcher↔child SendMessage, which is unaffected either way. Older rows without the column, and launches without `--cmuxnotify`, read as `cmuxnotify=0` → quiet. With the hook absent, nothing is muted and `--cmuxnotify` is simply a no-op marker.

## When to use

You have a prompt ready — just drafted via `draft-impl-prompt`, or written inline this turn — and want it running now. NOT for doing the work yourself in this session; this only dispatches.

## Steps

1. **Write the prompt to a file** at `/tmp/launch-session/<slug>.txt` — a short slug (ticket id or task name), `mkdir -p` the directory first. Write the prompt CONTENT only — no dashed rules, no commentary. The coordination footer (step 4) is appended separately. **Use this literal `/tmp/…` path, NOT `$TMPDIR`** — the Write tool cannot expand `$TMPDIR`, and on macOS `$TMPDIR` is `/var/folders/…/T/`, not `/tmp`; if this write and the step-4 `$FILE` resolve differently, the child launches with the footer ONLY and no task. Step 4 reads this exact path.
2. **Gate on cmux.** If `$CMUX_SURFACE_ID` is unset, you are not in cmux — print `claude "$(cat <file>)"` for the user to run manually, and stop.
3. **Get your own session name.** Call `ListAgents`; the first line reads `This session is <MAIN> [ref]`. That `<MAIN>` is the address the child reports back to — you will substitute it as `LAUNCHER` below.
4. **Resolve the mode, place the child, and seed it.** The block below is mode-aware: `tab` opens a tab beside you; `pane` reuses this workspace's bottom pane (creating it on first use). Both paths end by capturing the child's **stable surface UUID** for teardown and typing `claude -n <NAME>` into the new surface.

```bash
# --- config ---
FILE="/tmp/launch-session/<slug>.txt"           # MUST match the step-1 write path exactly (literal /tmp, not $TMPDIR)
SLUG="<slug>"
LAUNCHER="<MAIN>"                                # from ListAgents (step 3)

# --- resolve config: per-call arg > env var > config file > built-in default ---
# capture env-provided values FIRST so an exported var beats the config file
_e_MODE="${LAUNCH_SESSION_MODE:-}"; _e_PREFIX="${LAUNCH_SESSION_PREFIX:-}"; _e_DIR="${LAUNCH_SESSION_SPLIT_DIR:-}"
CFG="${LAUNCH_SESSION_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/launch-session/config}"
[ -f "$CFG" ] && . "$CFG"                        # may set LAUNCH_SESSION_MODE / _PREFIX / _SPLIT_DIR
MODE="${_e_MODE:-${LAUNCH_SESSION_MODE:-tab}}"    # if the caller passed --mode=<m> this turn, set MODE=<m> AFTER this block (a per-call arg wins over all)
PREFIX="${_e_PREFIX:-${LAUNCH_SESSION_PREFIX:-}}"    # default empty -> no prefix
DIR="${_e_DIR:-${LAUNCH_SESSION_SPLIT_DIR:-down}}"   # pane split direction
CMUXNOTIFY=0    # default QUIET: the mute-launched-children cmux hook mutes this child's turn-done cmux banners. If the caller passed --cmuxnotify this turn, set CMUXNOTIFY=1 AFTER this block so the registry marks the child loud.

NAME="${PREFIX:+$PREFIX-}$SLUG-$(openssl rand -hex 3)"   # <prefix>-<slug>-<rand>, or just <slug>-<rand> when prefix is empty; the rand tail is collision-safe; this is the SendMessage handle

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/launch-session"; mkdir -p "$STATE_DIR"
REG="$STATE_DIR/sessions.tsv"                    # durable registry: name,mode,surface_uuid,pane_uuid,slug,launcher,ts,cmuxnotify
PANE_STATE="$STATE_DIR/pane-$CMUX_WORKSPACE_ID"  # this workspace's shared bottom-pane UUID

# guard: the step-1 prompt write MUST have landed at this exact $FILE. If it is empty or
# missing (e.g. it went to a different dir), fail LOUD instead of launching a child with the
# footer only and no task.
[ -s "$FILE" ] || { echo "prompt file empty/missing: $FILE — step-1 write did not land here"; exit 1; }

# append a coordination footer so the child knows who launched it and how to reply
cat >> "$FILE" <<EOF

---
[coordination] You are Claude session "$NAME", launched by session "$LAUNCHER" on this machine.
When you finish, or if you get blocked, call the SendMessage tool with to:"$LAUNCHER" and include
your own name "$NAME" in the message so the launcher can correlate you.
EOF

PANE=""
case "$MODE" in
  pane)
    # reuse this workspace's bottom pane if it is still alive, else create it
    [ -f "$PANE_STATE" ] && PANE=$(cat "$PANE_STATE")
    if [ -n "$PANE" ] && cmux list-panes --id-format both | grep -qiF "$PANE"; then
      NEW=$(cmux --id-format both new-surface --pane "$PANE" --type terminal --focus false 2>&1)
    else
      BEFORE=$(cmux list-panes --id-format both | grep -oiE '[0-9A-Fa-f-]{36}')
      NEW=$(cmux --id-format both new-split "$DIR" --surface "$CMUX_SURFACE_ID" --focus false 2>&1)
      AFTER=$(cmux list-panes --id-format both | grep -oiE '[0-9A-Fa-f-]{36}')
      PANE=$(grep -vxiFf <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | head -1)  # AFTER minus BEFORE = the new pane
      [ -n "$PANE" ] || { echo "pane discovery failed: $NEW"; exit 1; }
      printf '%s\n' "$PANE" > "$PANE_STATE"
    fi
    SHORT="surface:$(printf '%s' "$NEW" | sed -nE 's/.*surface:([0-9]+).*/\1/p')"
    UUID=$(printf '%s' "$NEW" | sed -nE 's/.*surface:[0-9]+ \(([0-9A-Fa-f-]{36})\).*/\1/p')
    ;;
  *)  # tab (default)
    NEW=$(cmux tab-action --tab "$CMUX_SURFACE_ID" --action new-terminal-right --focus false --id-format both 2>&1)
    SHORT="surface:$(printf '%s' "$NEW" | sed -nE 's/.*created=tab:([0-9]+).*/\1/p')"
    UUID=$(printf '%s' "$NEW" | sed -nE 's/.*created=tab:[0-9]+ \(([0-9A-Fa-f-]{36})\).*/\1/p')
    ;;
esac
[ -n "$UUID" ] || { echo "placement failed ($MODE): $NEW"; exit 1; }  # bad surface -> don't seed or register a junk row

# single-quote so THIS shell doesn't expand $(cat); the NEW shell reads the file and runs claude -n
cmux send --surface "$SHORT" 'claude -n '"$NAME"' "$(cat '"$FILE"')"\n'

# record name -> stable UUID (+ mode/pane) so a later teardown finds THIS surface even after indices renumber
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$NAME" "$MODE" "$UUID" "$PANE" "$SLUG" "$LAUNCHER" "$(date +%s)" "$CMUXNOTIFY" >> "$REG"
echo "launched $NAME (mode $MODE, surface $UUID)"
```

5. **Verify + report.** After ~10s, call `ListAgents` and confirm `$NAME` is a peer (registration lags launch by 5–20s). Then **output the launched session name (`$NAME`) as the headline of your report** — it is the handle the user (or you) address with `SendMessage`. Also state the launcher name (`$LAUNCHER`), the mode, and that two-way messaging is ready. Do not switch to it.

   Example report: `Launched session **ls-task-a3f9c1** in a bottom pane (message it with SendMessage to:"ls-task-a3f9c1"; it reports back to <MAIN>).`

## Talking to the launched session

- **You → child:** `SendMessage({to: "<NAME>", message: "…"})` — lands as a user turn in the child's conversation.
- **Child → you:** the child `SendMessage`s to `<LAUNCHER>`; the reply arrives here as a `<cross-session-message>` whose `from-name="<NAME>"` — that wakes this session, and the name lets you correlate which child replied.

Both directions are the SendMessage tool, addressed by **claude session name** — not a cmux handle, and no id discovery is needed (you generated the name).

## Closing a launched session

When the child reports done — or you otherwise want to stop it — close its surface. `close-surface` kills the cmux surface **and** the interactive claude in one step:

```bash
UUID=$(awk -F'\t' -v n="<NAME>" '$1==n {u=$3} END {print u}' \
  "${XDG_STATE_HOME:-$HOME/.local/state}/launch-session/sessions.tsv")
cmux close-surface --surface "$UUID"
```

Always close by the stored **UUID**, never a `surface:N` short ref — indices renumber as surfaces open and close, so a stale short ref closes the wrong one. In `pane` mode the shared bottom pane **auto-collapses** once its last child surface is closed; no separate pane teardown is needed.

## Notes

- `--focus false` keeps you in the current session (default). Use `--focus true` to jump to the new surface and watch it start.
- UUID recovery is uniform: `cmux --id-format both <cmd>` prints the created surface's UUID. `tab-action` reports it as `created=tab:N (UUID)`; `new-split`/`new-surface` as `OK surface:N (UUID) …`. The parse in the block handles both.
- `pane` mode keys its shared container on `$CMUX_WORKSPACE_ID` (this session's workspace) — NOT `cmux current-workspace`, which returns the *focused* workspace and can differ. Each workspace gets its own bottom pane.
- `-n "$NAME"` sets the claude session's display name; it sticks for interactive sessions, so `ListAgents`/`SendMessage` address it by that name. cmux treats an explicit `-n` name as user-chosen, so the tab shows `$NAME` and cmux's `workspaceAutoNaming` will NOT summarize it. Do not add a `cmux rename-tab` call — redundant with `-n`, and it suppresses any future auto-naming.
- Reading the prompt from a file inside the new shell sidesteps quoting a multi-line prompt; the trailing `\n` in `send` is Enter, so `claude` runs immediately.
- One surface = one fresh session. Launch several for parallel handoffs — each gets its own random `$NAME` and its own registry line. In `pane` mode they stack as tabs inside the one bottom pane.
- The prompt file lives in `/tmp/launch-session/` (ephemeral); the registry and pane state live under `${XDG_STATE_HOME:-$HOME/.local/state}/launch-session/` (durable — the shared-pane UUID must survive across launches within a session). The prompt path is a literal `/tmp` on purpose: the step-1 Write and the step-4 `$FILE` must resolve to the SAME file, and the Write tool cannot expand `$TMPDIR`.

## Common mistakes

- Wrapping the user's drafted content in dashed rules or commentary — write the raw prompt only; the coordination footer is the ONE appended block, added by step 4.
- Double-quoting the `send` string, letting THIS shell expand `$(cat …)` — single-quote it so the NEW shell does the read.
- Storing or closing by the `surface:N` short ref instead of the UUID — it renumbers and will close the wrong surface later.
- Forgetting the cmux gate — outside cmux, placement fails silently and nothing launches.
- Writing the step-1 prompt to a path that differs from the step-4 `$FILE` — e.g. step 1 to literal `/tmp` while `$FILE` uses `$TMPDIR` (macOS `$TMPDIR` = `/var/folders/…/T/`, not `/tmp`). They diverge, `cat >> "$FILE"` creates a fresh footer-only file, and the child launches with the coordination footer but NO task. Both must be the literal `/tmp/launch-session/<slug>.txt`; the step-4 `[ -s "$FILE" ]` guard catches a miss.
- Adding a `cmux rename-tab` call — redundant with `-n` and it suppresses future auto-naming.
- In `pane` mode, keying the container on `current-workspace` instead of `$CMUX_WORKSPACE_ID` — you'll target the focused workspace, not yours.

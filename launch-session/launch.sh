#!/usr/bin/env bash
# launch-session driver.
#
# Detects the terminal target the launcher is running in, then places a fresh
# `claude` child (a new tab, or a pane), seeds it with a drafted prompt, records
# it in a durable registry, and tears it down by name later.
#
# Targets (auto-detected, precedence top→bottom):
#   tmux    — $TMUX set                     (cross-platform: macOS/Linux/BSD/WSL)
#   cmux    — $CMUX_SURFACE_ID set          (macOS)
#   iterm2  — macOS + $TERM_PROGRAM=iTerm.app (AppleScript)
#   ghostty — macOS + $TERM_PROGRAM=ghostty   (AppleScript)
# Multiplexers win over the host terminal: they run *inside* it, and cmux itself
# reports TERM_PROGRAM=ghostty, so the cmux check must precede the ghostty check.
#
# Subcommands:
#   launch.sh detect
#   launch.sh place --slug S --file F --launcher L [--mode tab|pane]
#                   [--prefix P] [--dir down|up|left|right] [--cmuxnotify]
#   launch.sh close --name N
#
# Registry (TSV): name, mode, teardown_id, container_id, slug, launcher, ts, cmuxnotify, target
set -u

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/launch-session"
REG="$STATE_DIR/sessions.tsv"

die() { echo "launch-session: $*" >&2; exit 1; }

# ─────────────────────────────── detection ───────────────────────────────────
detect_target() {
  if [ -n "${TMUX:-}" ]; then echo tmux; return; fi
  if [ -n "${CMUX_SURFACE_ID:-}" ]; then echo cmux; return; fi
  if [ "$(uname)" = Darwin ] && command -v osascript >/dev/null 2>&1; then
    case "${TERM_PROGRAM:-}" in
      iTerm.app) echo iterm2; return ;;
      ghostty)   echo ghostty; return ;;
    esac
  fi
  echo none
}

# ─────────────────────────────── cmux driver ─────────────────────────────────
# echoes: <teardown_id>\t<container_id>   (seeds the child as a side effect)
place_cmux() {
  local mode=$1 name=$2 file=$3 dir=$4
  local pane_state="$STATE_DIR/pane-${CMUX_WORKSPACE_ID:-default}"
  local new short tid container=""
  if [ "$mode" = pane ]; then
    [ -f "$pane_state" ] && container=$(cat "$pane_state")
    if [ -n "$container" ] && cmux list-panes --id-format both | grep -qiF "$container"; then
      new=$(cmux --id-format both new-surface --pane "$container" --type terminal --focus false 2>&1)
    else
      local before after
      before=$(cmux list-panes --id-format both | grep -oiE '[0-9A-Fa-f-]{36}')
      new=$(cmux --id-format both new-split "$dir" --surface "$CMUX_SURFACE_ID" --focus false 2>&1)
      after=$(cmux list-panes --id-format both | grep -oiE '[0-9A-Fa-f-]{36}')
      container=$(grep -vxiFf <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1)
      [ -n "$container" ] || die "cmux pane discovery failed: $new"
      printf '%s\n' "$container" > "$pane_state"
    fi
    short="surface:$(printf '%s' "$new" | sed -nE 's/.*surface:([0-9]+).*/\1/p')"
    tid=$(printf '%s' "$new" | sed -nE 's/.*surface:[0-9]+ \(([0-9A-Fa-f-]{36})\).*/\1/p')
  else
    new=$(cmux tab-action --tab "$CMUX_SURFACE_ID" --action new-terminal-right --focus false --id-format both 2>&1)
    short="surface:$(printf '%s' "$new" | sed -nE 's/.*created=tab:([0-9]+).*/\1/p')"
    tid=$(printf '%s' "$new" | sed -nE 's/.*created=tab:[0-9]+ \(([0-9A-Fa-f-]{36})\).*/\1/p')
  fi
  [ -n "$tid" ] || die "cmux placement failed: $new"
  # single-quote so THIS shell doesn't expand $(cat); the child shell reads the file.
  # silence cmux send's "OK ... queued" stdout so it doesn't pollute this function's output.
  cmux send --surface "$short" 'claude -n '"$name"' "$(cat '"$file"')"\n' >/dev/null
  printf '%s\t%s\n' "$tid" "$container"
}
close_cmux() { cmux close-surface --surface "$1"; }

# ─────────────────────────────── tmux driver ─────────────────────────────────
place_tmux() {
  local mode=$1 name=$2 file=$3 dir=$4
  local saxis sbefore target container="" tid
  case "$dir" in
    up)   saxis=-v; sbefore=-b ;;
    left) saxis=-h; sbefore=-b ;;
    right) saxis=-h; sbefore= ;;
    *)    saxis=-v; sbefore= ;;   # down (default)
  esac
  if [ "$mode" = pane ]; then
    local sess wstate
    sess=$(tmux display -p '#{session_id}')
    wstate="$STATE_DIR/tmux-win-$sess"
    if [ -f "$wstate" ] && tmux list-windows -F '#{window_id}' | grep -qx "$(cat "$wstate")"; then
      container=$(cat "$wstate")
      target=$(tmux split-window -t "$container" $saxis $sbefore -d -P -F '#{pane_id}')
    else
      read -r container target < <(tmux new-window -d -n launch-session -P -F '#{window_id} #{pane_id}')
      printf '%s\n' "$container" > "$wstate"
    fi
    tid=$target
  else
    read -r container target < <(tmux new-window -d -P -F '#{window_id} #{pane_id}')
    tid=$container; container=""
  fi
  [ -n "$tid" ] && [ -n "$target" ] || die "tmux placement failed"
  tmux send-keys -t "$target" 'claude -n '"$name"' "$(cat '"$file"')"' Enter
  printf '%s\t%s\n' "$tid" "$container"
}
close_tmux() {  # $1=teardown_id, $2=mode
  case "$2" in
    pane) tmux kill-pane   -t "$1" ;;   # shared window auto-collapses on its last pane
    *)    tmux kill-window -t "$1" ;;
  esac
}

# ────────────────────────────── iTerm2 driver ────────────────────────────────
# tab mode: a new tab in the current window; pane mode: a vertical split of the
# current session. Focus is restored to the launcher's tab afterward.
place_iterm2() {
  local mode=$1 name=$2 file=$3 _dir=$4
  local sid
  sid=$(osascript - "$name" "$file" "$mode" <<'OSA'
on run argv
  set theName to item 1 of argv
  set theFile to item 2 of argv
  set theMode to item 3 of argv
  set cmd to "claude -n " & theName & " \"$(cat " & theFile & ")\""
  tell application "iTerm"
    set w to current window
    set launcherTab to current tab of w
    if theMode is "pane" then
      tell current session of launcherTab
        set s to (split vertically with default profile)
      end tell
    else
      tell w
        set newTab to (create tab with default profile)
      end tell
      set s to current session of newTab
    end if
    tell s to write text cmd
    set sid to id of s
    select launcherTab
  end tell
  return sid
end run
OSA
) || die "iterm2 AppleScript failed (Automation permission not granted?)"
  [ -n "$sid" ] || die "iterm2 placement returned no session id"
  printf '%s\t%s\n' "$sid" ""
}
close_iterm2() {  # $1=session id
  osascript - "$1" <<'OSA'
on run argv
  set sid to item 1 of argv
  tell application "iTerm"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (id of s) is sid then
            close s
            return
          end if
        end repeat
      end repeat
    end repeat
  end tell
end run
OSA
}

# ────────────────────────────── Ghostty driver ───────────────────────────────
# tab mode: a new tab in the front window; pane mode: a split of the focused
# terminal. `initial input` seeds the shell after launch (race-free). Focus is
# restored to the launcher's tab afterward.
place_ghostty() {
  local mode=$1 name=$2 file=$3 dir=$4
  local tid
  tid=$(osascript - "$name" "$file" "$mode" "$dir" <<'OSA'
on run argv
  set theName to item 1 of argv
  set theFile to item 2 of argv
  set theMode to item 3 of argv
  set theDir to item 4 of argv
  set cmd to "claude -n " & theName & " \"$(cat " & theFile & ")\""
  tell application "Ghostty"
    set w to front window
    set launcherTab to selected tab of w
    set cfg to new surface configuration
    set initial input of cfg to cmd & return
    set wait after command of cfg to true
    if theMode is "pane" then
      set srcTerm to focused terminal of launcherTab
      if theDir is "up" then
        set newTerm to (split srcTerm direction up with configuration cfg)
      else if theDir is "left" then
        set newTerm to (split srcTerm direction left with configuration cfg)
      else if theDir is "right" then
        set newTerm to (split srcTerm direction right with configuration cfg)
      else
        set newTerm to (split srcTerm direction down with configuration cfg)
      end if
      set tid to id of newTerm
    else
      set newTab to (new tab in w with configuration cfg)
      set tid to id of newTab
    end if
    -- keep focus on the launcher: `new tab`/`split` selects the child, so re-select the
    -- launcher tab. The child stays visible as a background tab in the (native) tab bar.
    select tab launcherTab
  end tell
  return tid
end run
OSA
) || die "ghostty AppleScript failed (Automation permission not granted?)"
  [ -n "$tid" ] || die "ghostty placement returned no id"
  printf '%s\t%s\n' "$tid" ""
}
close_ghostty() {  # $1=id, $2=mode
  osascript - "$1" "$2" <<'OSA'
on run argv
  set theId to item 1 of argv
  set theMode to item 2 of argv
  tell application "Ghostty"
    if theMode is "pane" then
      repeat with w in windows
        repeat with tb in tabs of w
          repeat with tm in terminals of tb
            if (id of tm) is theId then
              close tm
              return
            end if
          end repeat
        end repeat
      end repeat
    else
      repeat with w in windows
        repeat with tb in tabs of w
          if (id of tb) is theId then
            close tab tb
            return
          end if
        end repeat
      end repeat
    end if
  end tell
end run
OSA
}

# ──────────────────────────────── place cmd ──────────────────────────────────
cmd_place() {
  local slug="" file="" launcher="" mode="" prefix="" dir="" cmuxnotify=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) slug=$2; shift 2 ;;
      --file) file=$2; shift 2 ;;
      --launcher) launcher=$2; shift 2 ;;
      --mode) mode=$2; shift 2 ;;
      --prefix) prefix=$2; shift 2 ;;
      --dir) dir=$2; shift 2 ;;
      --cmuxnotify) cmuxnotify=1; shift ;;
      *) die "unknown place arg: $1" ;;
    esac
  done
  [ -n "$slug" ] && [ -n "$file" ] && [ -n "$launcher" ] || die "place needs --slug --file --launcher"
  [ -s "$file" ] || die "prompt file empty/missing: $file"

  # resolve config: per-call arg > env var > config file > default
  local cfg _mode _prefix _dir
  cfg="${LAUNCH_SESSION_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/launch-session/config}"
  _mode="${LAUNCH_SESSION_MODE:-}"; _prefix="${LAUNCH_SESSION_PREFIX:-}"; _dir="${LAUNCH_SESSION_SPLIT_DIR:-}"
  # shellcheck disable=SC1090
  [ -f "$cfg" ] && . "$cfg"
  mode="${mode:-${_mode:-${LAUNCH_SESSION_MODE:-tab}}}"
  prefix="${prefix:-${_prefix:-${LAUNCH_SESSION_PREFIX:-}}}"
  dir="${dir:-${_dir:-${LAUNCH_SESSION_SPLIT_DIR:-down}}}"

  local target; target=$(detect_target)
  [ "$target" != none ] || die "not inside a supported terminal (tmux/cmux/iterm2/ghostty) — run manually: claude \"\$(cat $file)\""

  local name; name="${prefix:+$prefix-}$slug-$(openssl rand -hex 3)"

  # append the coordination footer so the child can report back
  cat >> "$file" <<EOF

---
[coordination] You are Claude session "$name", launched by session "$launcher" on this machine.
When you finish, or if you get blocked, call the SendMessage tool with to:"$launcher" and include
your own name "$name" in the message so the launcher can correlate you.
EOF

  mkdir -p "$STATE_DIR"
  local out tid container
  out=$(place_"$target" "$mode" "$name" "$file" "$dir") || exit 1
  tid=${out%%$'\t'*}; container=${out#*$'\t'}
  [ -n "$tid" ] || die "$target placement produced no teardown id"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$mode" "$tid" "$container" "$slug" "$launcher" "$(date +%s)" "$cmuxnotify" "$target" >> "$REG"

  printf 'NAME=%s\nTARGET=%s\nMODE=%s\nID=%s\n' "$name" "$target" "$mode" "$tid"
}

# ──────────────────────────────── close cmd ──────────────────────────────────
close_by_name() {  # $1=name; returns nonzero if not found / close failed
  local name=$1
  local row; row=$(awk -F'\t' -v n="$name" '$1==n{r=$0} END{print r}' "$REG")
  [ -n "$row" ] || { echo "no launched session named '$name'" >&2; return 1; }
  local mode tid target
  mode=$(printf '%s' "$row" | cut -f2)
  tid=$(printf '%s' "$row" | cut -f3)
  target=$(printf '%s' "$row" | cut -f9)
  target="${target:-cmux}"   # rows written before the target column
  case "$target" in
    cmux)    close_cmux "$tid" ;;
    tmux)    close_tmux "$tid" "$mode" ;;
    iterm2)  close_iterm2 "$tid" ;;
    ghostty) close_ghostty "$tid" "$mode" ;;
    *) echo "unknown target '$target' for '$name'" >&2; return 1 ;;
  esac
  echo "closed $name ($target $mode, id $tid)"
}

cmd_close() {
  local name="" launcher=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name=$2; shift 2 ;;
      --launcher) launcher=$2; shift 2 ;;   # close ALL children of this launcher ("close the tabs")
      *) die "unknown close arg: $1" ;;
    esac
  done
  [ -f "$REG" ] || die "no registry at $REG"
  if [ -n "$name" ]; then
    close_by_name "$name"
  elif [ -n "$launcher" ]; then
    local names; names=$(awk -F'\t' -v l="$launcher" '$6==l{print $1}' "$REG")
    [ -n "$names" ] || { echo "no launched children for launcher '$launcher'"; return 0; }
    while IFS= read -r n; do close_by_name "$n" || true; done <<< "$names"
  else
    die "close needs --name <N> or --launcher <L>"
  fi
}

# ─────────────────────────────────── main ────────────────────────────────────
case "${1:-}" in
  detect) detect_target ;;
  place)  shift; cmd_place "$@" ;;
  close)  shift; cmd_close "$@" ;;
  *) die "usage: launch.sh detect | place --slug S --file F --launcher L [--mode] [--prefix] [--dir] [--cmuxnotify] | close (--name N | --launcher L)" ;;
esac

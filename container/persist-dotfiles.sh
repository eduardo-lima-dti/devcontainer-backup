#!/usr/bin/env sh
#
# Keeps dotfiles across dev container rebuilds: moves each one into a folder on
# a persistent volume once, then symlinks it back into $HOME.
#
# Usage: persist-dotfiles.sh [-d DIR] [-g NAME=PATHS]... [-s] [ENTRY...]
#
#   ENTRY          <path relative to $HOME>:<dir|file>, e.g. .aws:dir .gitconfig:file
#                  (default: the DEFAULT_ENTRIES list below)
#   -d DIR         persistent folder (default: $PERSIST_DIR, else /workspaces/.persist,
#                  the volume a VS Code "Clone Repository in Container Volume" mounts)
#   -g NAME=PATHS  leave PATHS (comma-separated, relative to $HOME) alone while a
#                  process named NAME runs, because it holds them open. Repeatable;
#                  the first -g replaces the default, -g '' disables it.
#                  (default: claude=.claude,.claude.json)
#   -s             status only, change nothing
#
# Safe to re-run. When DIR already has an entry (a rebuilt container), whatever
# the new container created at that path is moved to <path>.pre-persist.<time>,
# never deleted. Linux only (reads /proc). POSIX sh.
set -eu

DEFAULT_ENTRIES=".claude:dir .claude.json:file .zsh_history:file .gitconfig:file
.config/gh:dir .npmrc:file .aws:dir .ssh:dir"
PERSIST="${PERSIST_DIR:-/workspaces/.persist}"
GUARDS="claude=.claude,.claude.json"
guards_set=false
STATUS_ONLY=false

usage() { sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; }

while getopts d:g:sh opt; do
  case "$opt" in
    d) PERSIST="$OPTARG" ;;
    g)
      if [ "$guards_set" = false ]; then GUARDS=""; guards_set=true; fi
      [ -n "$OPTARG" ] && GUARDS="$GUARDS $OPTARG"
      ;;
    s) STATUS_ONLY=true ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
ENTRIES="${*:-$DEFAULT_ENTRIES}"

say() { printf '[persist-dotfiles] %s\n' "$1"; }

NL='
'

# True when a process named NAME is running: argv[0] is NAME (a binary), or
# argv[1] is (a script run by its interpreter, e.g. `node /usr/local/bin/NAME`).
running() {
  for cmdline in /proc/[0-9]*/cmdline; do
    pid="${cmdline#/proc/}"; pid="${pid%/cmdline}"
    [ "$pid" = "$$" ] && continue
    args="$(tr '\0' '\n' <"$cmdline" 2>/dev/null | head -n2)" || continue
    a0="${args%%"$NL"*}" a1=""
    case "$args" in *"$NL"*) a1="${args#*"$NL"}" ;; esac
    [ "${a0##*/}" = "$1" ] || [ "${a1##*/}" = "$1" ] && return 0
  done
  return 1
}

# Prints the name of the guard process holding REL, if it is running.
held_by() {
  for guard in $GUARDS; do
    name="${guard%%=*}"
    case ",${guard#*=}," in
      *",$1,"*) running "$name" && { printf '%s' "$name"; return 0; } ;;
    esac
  done
  return 1
}

status() {
  rel="$1" target="$2" backing="$3"
  if [ -L "$target" ]; then
    link="$(readlink "$target")"
    if [ "$link" = "$backing" ]; then say "linked       ~/$rel"
    else say "OTHER LINK   ~/$rel -> $link (left alone)"; fi
  elif [ -e "$backing" ]; then say "NOT LINKED   ~/$rel (saved copy exists in $PERSIST)"
  elif [ -e "$target" ]; then say "NOT SAVED    ~/$rel"
  else say "absent       ~/$rel"
  fi
}

persist() {
  rel="$1" kind="$2" target="$3" backing="$4"
  [ -L "$target" ] && return 0
  if holder="$(held_by "$rel")"; then
    say "skipped      ~/$rel: '$holder' is running. Close it and re-run."
    return 0
  fi
  if [ -e "$backing" ]; then
    if [ -e "$target" ]; then
      aside="$target.pre-persist.$(date +%Y%m%d-%H%M%S)"
      mv "$target" "$aside"
      say "moved aside  ~/$rel -> $aside (the saved copy wins)"
    fi
  elif [ -e "$target" ]; then
    cp -a "$target" "$backing"
    rm -rf "$target"
  elif [ "$kind" = dir ]; then
    mkdir -p "$backing"
  else
    : >"$backing"
  fi
  mkdir -p "$(dirname "$target")"
  ln -s "$backing" "$target"
  say "linked       ~/$rel -> $backing"
}

[ "$STATUS_ONLY" = true ] || mkdir -p "$PERSIST"
for entry in $ENTRIES; do
  rel="${entry%%:*}" kind="${entry##*:}"
  case "$kind" in
    dir | file) ;;
    *) say "bad entry '$entry': expected <path>:<dir|file>"; exit 2 ;;
  esac
  target="$HOME/$rel"
  backing="$PERSIST/$(printf '%s' "$rel" | sed 's|/|__|g')"
  if [ "$STATUS_ONLY" = true ]; then status "$rel" "$target" "$backing"
  else persist "$rel" "$kind" "$target" "$backing"; fi
done
[ -d "$PERSIST/.ssh" ] && chmod 700 "$PERSIST/.ssh"
exit 0

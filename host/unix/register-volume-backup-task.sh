#!/usr/bin/env sh
#
# Schedules backup-docker-volume.sh to run roughly every -e HOURS via cron,
# or removes that schedule with -u. Installs one hourly cron entry that
# calls run-scheduled-backup.sh, which only actually backs up once HOURS
# have elapsed - so a tick missed while the machine was off or asleep is
# caught the next time cron wakes up. Runs as the current user, no root
# needed. Expects backup-docker-volume.sh and run-scheduled-backup.sh in the
# same folder as this script. Re-running with the same -n NAME replaces the
# existing entry, so it is also how you change the settings.
#
# -v VOLUME and -p PATH are always required; -d DESTINATION is required too
# unless -u is set. Omit any of them (or run with no arguments at all) and a
# setup wizard prompts for whatever is missing, listing existing Docker
# volumes to pick from when Docker is reachable, then shows a summary to
# confirm before it installs (or removes) the cron entry.
#
# On macOS, cron needs Full Disk Access before its jobs actually run:
# System Settings > Privacy & Security > Full Disk Access, add /usr/sbin/cron
# (or run `which cron` to confirm its path first).
#
# Usage: register-volume-backup-task.sh [-v VOLUME] [-p PATH] [-d DEST]
#                                        [-n NAME] [-e HOURS] [-k KEEP]
#                                        [-i IMAGE] [-u]
#
#   -v VOLUME  Docker volume name
#   -p PATH    Folder inside the volume, relative to its root
#   -d DEST    Where archives and backup.log are written
#              (default: ~/docker-volume-backups/<volume>)
#   -n NAME    Identifier for this task (default: derived from -v/-p)
#   -e HOURS   Backup interval in hours, 1-168 (default: 2)
#   -k KEEP    Number of archives to keep (default: 36)
#   -i IMAGE   Image used to run tar (default: alpine:3)
#   -u         Remove the cron entry instead of installing it
#
# Examples:
#   register-volume-backup-task.sh -v my-volume -p .persist
#   register-volume-backup-task.sh -v my-volume -p .persist -u
#   register-volume-backup-task.sh
#   # Prompts for whatever is needed.
set -eu

PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

VOLUME="" REL_PATH="" DESTINATION="" NAME="" HOURS=2 KEEP=36 IMAGE="alpine:3" UNREGISTER=false

usage() { sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; }

while getopts v:p:d:n:e:k:i:uh opt; do
  case "$opt" in
    v) VOLUME="$OPTARG" ;;
    p) REL_PATH="$OPTARG" ;;
    d) DESTINATION="$OPTARG" ;;
    n) NAME="$OPTARG" ;;
    e) HOURS="$OPTARG" ;;
    k) KEEP="$OPTARG" ;;
    i) IMAGE="$OPTARG" ;;
    u) UNREGISTER=true ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

# --- wizard helpers (prompt on stderr, return the answer on stdout) ---

read_required() {
  _prompt="$1"; _help="${2:-}"
  [ -n "$_help" ] && printf '%s\n' "$_help" >&2
  _value=""
  while [ -z "$_value" ]; do
    printf '%s: ' "$_prompt" >&2
    IFS= read -r _value
  done
  printf '%s\n' "$_value"
}

read_with_default() {
  _prompt="$1"; _default="${2:-}"
  if [ -n "$_default" ]; then printf '%s [%s]: ' "$_prompt" "$_default" >&2
  else printf '%s: ' "$_prompt" >&2
  fi
  IFS= read -r _value
  if [ -n "$_value" ]; then printf '%s\n' "$_value"; else printf '%s\n' "$_default"; fi
}

read_int_with_default() {
  _prompt="$1"; _default="$2"; _min="$3"; _max="$4"
  while true; do
    printf '%s [%s]: ' "$_prompt" "$_default" >&2
    IFS= read -r _raw
    if [ -z "$_raw" ]; then printf '%s\n' "$_default"; return 0; fi
    case "$_raw" in
      *[!0-9]*) ;;
      *) if [ "$_raw" -ge "$_min" ] && [ "$_raw" -le "$_max" ]; then printf '%s\n' "$_raw"; return 0; fi ;;
    esac
    printf 'Enter a whole number between %s and %s.\n' "$_min" "$_max" >&2
  done
}

# --- wizard: fill in whatever required value is missing ---

WIZARD=false
if [ -z "$VOLUME" ] || [ -z "$REL_PATH" ] || { [ "$UNREGISTER" = false ] && [ -z "$DESTINATION" ]; }; then
  WIZARD=true
fi

if [ "$WIZARD" = true ]; then
  printf '\n=== Docker volume backup - setup wizard ===\n' >&2
  printf 'A required parameter was missing; answer the prompts below (Enter accepts the default in [brackets]).\n\n' >&2
fi

if [ -z "$VOLUME" ]; then
  vol_list=""
  if command -v docker >/dev/null 2>&1; then
    vol_list="$(docker volume ls --format '{{.Name}}' 2>/dev/null || true)"
  fi
  if [ -n "$vol_list" ]; then
    echo "Existing Docker volumes:" >&2
    oldIFS="$IFS"; IFS='
'
    set -- $vol_list
    IFS="$oldIFS"
    count=$#
    i=0
    for vol in "$@"; do
      i=$((i + 1))
      printf '  [%d] %s\n' "$i" "$vol" >&2
    done
    selection="$(read_required "Volume name (or number from the list above)")"
    case "$selection" in
      *[!0-9]*) VOLUME="$selection" ;;
      *)
        if [ "$selection" -ge 1 ] && [ "$selection" -le "$count" ]; then
          eval "VOLUME=\"\${$selection}\""
        else
          VOLUME="$selection"
        fi
        ;;
    esac
    set --
  else
    VOLUME="$(read_required "Docker volume name" "Docker wasn't reachable, or has no volumes - type the volume name to use.")"
  fi
fi

if [ -z "$REL_PATH" ]; then
  REL_PATH="$(read_required "Folder inside the volume" "Relative to the volume's root, e.g. .persist")"
fi

if [ "$WIZARD" = true ] && [ "$UNREGISTER" = false ]; then
  HOURS="$(read_int_with_default "Backup interval, in hours" "$HOURS" 1 168)"
  KEEP="$(read_int_with_default "Number of archives to keep" "$KEEP" 1 10000)"
  DESTINATION="$(read_with_default "Backup destination folder on this machine (blank = script default)" "$DESTINATION")"
fi

# --- validate, now that every value is in hand ---

REL_PATH="$(printf '%s' "$REL_PATH" | sed 's|^/*||; s|/*$||')"
[ -n "$REL_PATH" ] || { echo "-p must be a folder inside the volume" >&2; exit 2; }
case "/$REL_PATH/" in
  */../*) echo "-p must be a folder inside the volume, without '..': '$REL_PATH'" >&2; exit 2 ;;
esac
case "$VOLUME$REL_PATH$DESTINATION" in
  *\"*) echo "Volume, path, and destination must not contain double quotes." >&2; exit 2 ;;
esac

[ -n "$NAME" ] || NAME="docker-volume-backup-$VOLUME-$(printf '%s' "$REL_PATH" | tr '/' '-')"
NAME="$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9._-' '-')"

if [ "$WIZARD" = true ]; then
  printf '\nName        : %s\n' "$NAME" >&2
  printf 'Volume      : %s\n' "$VOLUME" >&2
  printf 'Path        : %s\n' "$REL_PATH" >&2
  if [ "$UNREGISTER" = false ]; then
    printf 'Every       : %sh\n' "$HOURS" >&2
    printf 'Keep        : %s archives\n' "$KEEP" >&2
    if [ -n "$DESTINATION" ]; then printf 'Destination : %s\n' "$DESTINATION" >&2
    else printf 'Destination : (script default)\n' >&2
    fi
  fi
  if [ "$UNREGISTER" = true ]; then printf 'Action      : Unregister\n' >&2
  else printf 'Action      : Register\n' >&2
  fi
  printf '\nProceed? [Y/n]: ' >&2
  IFS= read -r confirm
  case "$confirm" in
    [Nn]*) echo "Cancelled." >&2; exit 0 ;;
  esac
fi

# --- install or remove the cron entry ---

marker="# docker-volume-backup:$NAME"
current="$(crontab -l 2>/dev/null || true)"
if [ -n "$current" ]; then
  filtered="$(printf '%s\n' "$current" | grep -v -F "$marker" || true)"
else
  filtered=""
fi

if [ "$UNREGISTER" = true ]; then
  if [ "$filtered" = "$current" ]; then
    echo "No entry named '$NAME' found."
  else
    if [ -n "$filtered" ]; then printf '%s\n' "$filtered" | crontab -
    else crontab -r 2>/dev/null || true
    fi
    echo "Removed task '$NAME'."
  fi
  exit 0
fi

[ -n "$DESTINATION" ] || DESTINATION="$HOME/docker-volume-backups/$VOLUME"
mkdir -p "$DESTINATION"

line="0 * * * * \"$HERE/run-scheduled-backup.sh\" -v \"$VOLUME\" -p \"$REL_PATH\" -d \"$DESTINATION\" -k \"$KEEP\" -i \"$IMAGE\" -e \"$HOURS\" >>\"$DESTINATION/cron.log\" 2>&1 $marker"

{
  [ -n "$filtered" ] && printf '%s\n' "$filtered"
  printf '%s\n' "$line"
} | crontab -

echo "Registered '$NAME': every ${HOURS}h, keeping $KEEP archives."
echo "Run it now with: \"$HERE/backup-docker-volume.sh\" -v \"$VOLUME\" -p \"$REL_PATH\" -d \"$DESTINATION\" -k \"$KEEP\" -i \"$IMAGE\""

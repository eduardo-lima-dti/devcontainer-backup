#!/usr/bin/env sh
#
# Runs backup-docker-volume.sh only once -e HOURS have actually elapsed
# since the last attempt, tracked in a small state file next to the
# backups. cron has no native "every N hours" for N > 23, so
# register-volume-backup-task.sh installs an hourly cron line that calls
# this script instead of the backup script directly; this is what turns
# that hourly tick into a once-per-HOURS backup. A tick missed while the
# machine was off or asleep is caught the next time cron wakes up.
#
# Skips without updating the state file when Docker itself isn't reachable
# yet, so a sleeping Docker Desktop doesn't cost you the rest of a
# multi-hour (or multi-day) window - it tries again on the next hourly tick
# instead. Expects backup-docker-volume.sh in the same folder as this
# script. Safe to run by hand.
#
# Usage: run-scheduled-backup.sh -v VOLUME -p PATH [-d DESTINATION]
#                                 [-k KEEP] [-i IMAGE] [-e HOURS]
#
#   -v VOLUME       Docker volume name
#   -p PATH         Folder inside the volume, relative to its root
#   -d DESTINATION  Where archives and backup.log are written
#                   (default: ~/docker-volume-backups/<volume>)
#   -k KEEP         Number of archives to keep (default: 36)
#   -i IMAGE        Image used to run tar (default: alpine:3)
#   -e HOURS        Minimum hours between backups (default: 2)
set -eu

PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

VOLUME="" REL_PATH="" DESTINATION="" KEEP=36 IMAGE="alpine:3" HOURS=2

usage() { sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; }

while getopts v:p:d:k:i:e:h opt; do
  case "$opt" in
    v) VOLUME="$OPTARG" ;;
    p) REL_PATH="$OPTARG" ;;
    d) DESTINATION="$OPTARG" ;;
    k) KEEP="$OPTARG" ;;
    i) IMAGE="$OPTARG" ;;
    e) HOURS="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[ -n "$VOLUME" ] || { echo "-v (volume) is required" >&2; usage >&2; exit 2; }
[ -n "$REL_PATH" ] || { echo "-p (path) is required" >&2; usage >&2; exit 2; }
case "$HOURS" in
  ''|*[!0-9]*) echo "-e must be a whole number of hours: '$HOURS'" >&2; exit 2 ;;
esac

[ -n "$DESTINATION" ] || DESTINATION="$HOME/docker-volume-backups/$VOLUME"
mkdir -p "$DESTINATION"

prefix="$(printf '%s' "$REL_PATH" | sed 's|^/*||; s|/*$||' | awk -F/ '{print $NF}' | sed 's/^\.*//')"
[ -n "$prefix" ] || prefix="backup"
state="$DESTINATION/.last-run-$prefix"

now="$(date +%s)"
last=0
if [ -f "$state" ]; then
  last="$(cat "$state" 2>/dev/null || echo 0)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
fi

due=$((HOURS * 3600))
if [ $((now - last)) -lt "$due" ]; then
  exit 0
fi

# Cheap pre-check: if Docker isn't up yet, don't reset the timer - try
# again next hour instead of waiting out a whole interval once it is.
docker info >/dev/null 2>&1 || exit 0

set +e
"$HERE/backup-docker-volume.sh" -v "$VOLUME" -p "$REL_PATH" -d "$DESTINATION" -k "$KEEP" -i "$IMAGE"
rc=$?
set -e
date +%s >"$state"
exit "$rc"

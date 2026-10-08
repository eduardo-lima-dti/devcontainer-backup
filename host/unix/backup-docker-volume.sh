#!/usr/bin/env sh
#
# Backs up one folder of a Docker volume to a dated .tgz on this machine.
#
# Mounts the volume read-only in a throwaway container, archives -p PATH,
# reads the archive back to check it, and keeps the newest -k archives.
# Works while the volume is in use. Skips quietly when Docker is not
# running. Every run is appended to backup.log in the destination.
#
# Usage: backup-docker-volume.sh -v VOLUME -p PATH [-d DESTINATION]
#                                 [-k KEEP] [-i IMAGE]
#
#   -v VOLUME       Docker volume name
#   -p PATH         Folder inside the volume, relative to its root
#   -d DESTINATION  Where archives and backup.log are written
#                   (default: ~/docker-volume-backups/<volume>)
#   -k KEEP         Number of archives to keep (default: 36)
#   -i IMAGE        Image used to run tar (default: alpine:3)
#
# Restore an archive (overwrites matching files in the volume):
#   docker run --rm -v "<volume>:/w" -v "<destination>:/b" alpine \
#     tar xzf /b/<archive> -C /w
#
# Example: backup-docker-volume.sh -v my-volume -p .persist
set -eu

PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"

VOLUME="" REL_PATH="" DESTINATION="" KEEP=36 IMAGE="alpine:3"

usage() { sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'; }

while getopts v:p:d:k:i:h opt; do
  case "$opt" in
    v) VOLUME="$OPTARG" ;;
    p) REL_PATH="$OPTARG" ;;
    d) DESTINATION="$OPTARG" ;;
    k) KEEP="$OPTARG" ;;
    i) IMAGE="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[ -n "$VOLUME" ] || { echo "-v (volume) is required" >&2; usage >&2; exit 2; }
[ -n "$REL_PATH" ] || { echo "-p (path) is required" >&2; usage >&2; exit 2; }
case "$KEEP" in
  ''|*[!0-9]*) echo "-k must be a positive whole number: '$KEEP'" >&2; exit 2 ;;
esac
[ "$KEEP" -ge 1 ] || { echo "-k must be at least 1" >&2; exit 2; }

REL_PATH="$(printf '%s' "$REL_PATH" | sed 's|^/*||; s|/*$||')"
[ -n "$REL_PATH" ] || { echo "-p must be a folder inside the volume: '$REL_PATH'" >&2; exit 2; }
case "/$REL_PATH/" in
  */../*) echo "-p must be a folder inside the volume, without '..': '$REL_PATH'" >&2; exit 2 ;;
esac
case "$REL_PATH" in
  *"'"*) echo "-p must not contain quotes: '$REL_PATH'" >&2; exit 2 ;;
esac

prefix="$(printf '%s' "$REL_PATH" | awk -F/ '{print $NF}' | sed 's/^\.*//')"
[ -n "$prefix" ] || prefix="backup"

[ -n "$DESTINATION" ] || DESTINATION="$HOME/docker-volume-backups/$VOLUME"
mkdir -p "$DESTINATION"
log="$DESTINATION/backup.log"
write_log() { printf '%s [%s/%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$VOLUME" "$REL_PATH" "$1" >>"$log"; }

if ! docker info >/dev/null 2>&1; then
  write_log "Docker is not running, skipped."
  exit 0
fi
if ! docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  write_log "Volume not found, skipped."
  exit 1
fi

name="$prefix-$(date '+%Y%m%d-%H%M%S').tgz"
file="$DESTINATION/$name"
if ! docker run --rm -v "$VOLUME:/w:ro" -v "$DESTINATION:/b" "$IMAGE" \
     sh -c "tar czf '/b/$name' -C /w '$REL_PATH' && tar tzf '/b/$name' >/dev/null"; then
  rm -f -- "$file"
  write_log "Backup failed."
  exit 1
fi
size_mb="$(awk -v b="$(wc -c <"$file")" 'BEGIN { printf "%.1f", b / 1048576 }')"
write_log "Created $name (${size_mb} MB)."

# Prune archives beyond -k, oldest first. The timestamp in the filename
# sorts correctly as plain text, so no need to inspect mtimes.
# shellcheck disable=SC2012
ls -1 "$DESTINATION" 2>/dev/null |
  grep -E "^${prefix}-[0-9]{8}-[0-9]{6}\.tgz\$" |
  sort -r |
  awk -v keep="$KEEP" 'NR > keep' |
  while IFS= read -r old; do
    rm -f -- "$DESTINATION/$old"
    write_log "Removed old $old."
  done || true

exit 0

# devcontainer-backup

Tools for keeping dev container state safe across rebuilds — and off the container entirely.

VS Code dev containers are disposable by design: rebuild one and anything that isn't in the repo or a mounted volume is gone. That's fine for the workspace itself, but painful for dotfiles like `.gitconfig`, `.ssh`, `.aws`, or tool state like `.claude` — things you don't want to reconfigure every rebuild, and don't want to bake into the image either.

This repo has two complementary pieces:

1. **[`container/persist-dotfiles.sh`](container/persist-dotfiles.sh)** — runs *inside* the dev container. Moves chosen dotfiles onto a persistent volume (e.g. the one VS Code's "Clone Repository in Container Volume" mounts at `/workspaces/.persist`) and replaces them with symlinks, so they survive rebuilds.
2. **[`host/windows/`](host/windows/)** or **[`host/unix/`](host/unix/)** — runs on the *host machine* (Windows, or Linux/macOS). Periodically archives a folder of that Docker volume to a dated `.tgz` on your machine, as a safety net in case the volume itself is ever lost or corrupted.

Together: dotfiles persist across container rebuilds via the volume, and the volume itself gets backed up to disk. Both host implementations are functionally equivalent — pick the one matching your host OS.

## How it fits together

```
┌─────────────────────────┐        ┌──────────────────────────────┐
│   Dev Container (Linux) │        │   Host (Windows or Unix)      │
│                          │        │                                │
│  ~/.gitconfig  ──symlink─┼───┐    │  Register-VolumeBackupTask.ps1│
│  ~/.ssh        ──symlink─┼─┐ │    │  or register-volume-backup-   │
│  ~/.claude     ──symlink─┼┐│ │    │  task.sh (every N hours)      │
│                          ││ │ │    │           │                    │
│  persist-dotfiles.sh     ││ │ │    │           ▼                    │
└──────────────────────────┘│ │ │    │  Backup-DockerVolume.ps1 or   │
                             ▼ ▼ ▼    │  backup-docker-volume.sh      │
              /workspaces/.persist   │    tars a folder from the     │
              (Docker volume) ───────┼──► volume → dated .tgz,       │
                                      │    pruning old archives       │
                                      └──────────────────────────────┘
```

## `container/persist-dotfiles.sh`

POSIX `sh` script, Linux only (reads `/proc`). Run it inside the dev container.

For each entry, it moves the real file/directory into the persistent folder (first run only) and leaves a symlink at the original path. On later runs — including after a rebuild — it just re-links to what's already there. It's safe to re-run; it never deletes anything. If the destination path already has unexpected content (e.g. the image recreated it), that content is moved aside to `<path>.pre-persist.<timestamp>` rather than overwritten.

```sh
# Default entries, from the persistent volume mounted at /workspaces/.persist
./persist-dotfiles.sh

# Custom directory and entries
./persist-dotfiles.sh -d /some/other/volume .gitconfig:file .ssh:dir

# Check status without changing anything
./persist-dotfiles.sh -s
```

**Options:**

| Flag | Meaning |
|---|---|
| `-d DIR` | Persistent folder to use (default: `$PERSIST_DIR`, else `/workspaces/.persist`) |
| `-g NAME=PATHS` | Skip paths (comma-separated) while a process named `NAME` is running, since it holds them open. Repeatable; default is `claude=.claude,.claude.json`. Pass `-g ''` to disable. |
| `-s` | Status only — report what's linked/unlinked without changing anything |

**Default entries persisted:** `.claude`, `.claude.json`, `.zsh_history`, `.gitconfig`, `.config/gh`, `.npmrc`, `.aws`, `.ssh`.

## `host/windows/Backup-DockerVolume.ps1`

Backs up one folder from inside a Docker volume to a dated `.tgz` archive on the host. Mounts the volume read-only in a throwaway `alpine` container, archives the folder, verifies the archive, and prunes old archives beyond `-Keep`. Logs every run to `backup.log` in the destination. Works while the volume is in active use; skips quietly (exit 0) if Docker isn't running.

```powershell
.\Backup-DockerVolume.ps1 -Volume my-volume -Path .persist
```

**Parameters:**

| Parameter | Required | Default | Meaning |
|---|---|---|---|
| `-Volume` | Yes | — | Docker volume name |
| `-Path` | Yes | — | Folder inside the volume, relative to its root |
| `-Destination` | No | `%USERPROFILE%\docker-volume-backups\<Volume>` | Where archives and the log are written |
| `-Keep` | No | `36` | Number of most recent archives to retain |
| `-Image` | No | `alpine:3` | Image used to run `tar` |

**Restoring** an archive (overwrites matching files in the volume):

```bash
docker run --rm -v "<volume>:/w" -v "<destination>:/b" alpine tar xzf /b/<archive> -C /w
```

## `host/windows/Register-VolumeBackupTask.ps1`

Schedules `Backup-DockerVolume.ps1` to run automatically every `-IntervalHours` via Windows Task Scheduler, as the current user (no admin rights needed). A run missed while the PC was off runs once it's back on. Expects `Backup-DockerVolume.ps1` in the same folder.

`-Volume` and `-Path` are always required; `-Destination` is required too unless `-Unregister` is set. You don't have to know them up front: omit any of them (or run the script with no arguments at all) and a setup wizard prompts for whatever is missing — listing existing Docker volumes to pick from when Docker is reachable — then shows a summary to confirm before it registers (or unregisters) the task.

```powershell
# Register (or update) the task
.\Register-VolumeBackupTask.ps1 -Volume my-volume -Path .persist -IntervalHours 2 -Keep 36

# Remove it
.\Register-VolumeBackupTask.ps1 -Volume my-volume -Path .persist -Unregister

# Or just run it with no arguments and answer the prompts
.\Register-VolumeBackupTask.ps1
```

Re-running with the same `-TaskName` replaces the existing task — that's also how you change its settings. If `-TaskName` is omitted, it's derived from `-Volume` and `-Path`.

**Parameters:**

| Parameter | Required | Default | Meaning |
|---|---|---|---|
| `-Volume` | Yes | — | Docker volume name, forwarded to the backup script. Prompted for (with a pick-list) if omitted |
| `-Path` | Yes | — | Folder inside the volume, forwarded to the backup script. Prompted for if omitted |
| `-TaskName` | No | derived from `-Volume`/`-Path` | Scheduled task name |
| `-IntervalHours` | No | `2` | How often to run (1–168) |
| `-Keep` | No | `36` | Archives to retain, forwarded to the backup script |
| `-Destination` | Yes, unless `-Unregister` | backup script's default | Forwarded to the backup script. Prompted for if omitted (blank answer keeps the backup script's own default) |
| `-Unregister` | No | — | Remove the task instead of creating it |

## `host/unix/backup-docker-volume.sh`

The Linux/macOS equivalent of `Backup-DockerVolume.ps1`, same behavior: mounts the volume read-only in a throwaway `alpine` container, archives the folder, verifies the archive, prunes old archives beyond `-k`, and appends every run to `backup.log` in the destination. Skips quietly (exit 0) if Docker isn't running.

```sh
./backup-docker-volume.sh -v my-volume -p .persist
```

**Options:**

| Flag | Required | Default | Meaning |
|---|---|---|---|
| `-v VOLUME` | Yes | — | Docker volume name |
| `-p PATH` | Yes | — | Folder inside the volume, relative to its root |
| `-d DESTINATION` | No | `~/docker-volume-backups/<volume>` | Where archives and the log are written |
| `-k KEEP` | No | `36` | Number of most recent archives to retain |
| `-i IMAGE` | No | `alpine:3` | Image used to run `tar` |

**Restoring** an archive (overwrites matching files in the volume):

```sh
docker run --rm -v "<volume>:/w" -v "<destination>:/b" alpine tar xzf /b/<archive> -C /w
```

## `host/unix/register-volume-backup-task.sh`

The Linux/macOS equivalent of `Register-VolumeBackupTask.ps1`. Windows Task Scheduler natively supports repeating a trigger every `N` hours; `cron` doesn't (its hour field only goes up to 23). To get the same "every `-e` hours, including spans longer than a day" behavior, this installs a single **hourly** cron entry that calls a small wrapper, **[`run-scheduled-backup.sh`](host/unix/run-scheduled-backup.sh)** — which checks a timestamp file and only actually invokes `backup-docker-volume.sh` once `-e` hours have really passed. A tick missed while the machine was off or asleep is caught on the next hourly wake-up, same as the Windows version. (`run-scheduled-backup.sh` isn't meant to be run by hand — it's the glue cron calls — but it's safe to do so.)

`-v` and `-p` are always required; `-d` is required too unless `-u` is set. Omit any of them (or run with no arguments at all) and the same kind of setup wizard as the Windows version prompts for whatever is missing — listing existing Docker volumes to pick from when Docker is reachable — then shows a summary to confirm before it installs (or removes) the cron entry.

```sh
# Register (or update) the task
./register-volume-backup-task.sh -v my-volume -p .persist -e 2 -k 36

# Remove it
./register-volume-backup-task.sh -v my-volume -p .persist -u

# Or just run it with no arguments and answer the prompts
./register-volume-backup-task.sh
```

Re-running with the same `-n NAME` replaces the existing cron entry — that's also how you change its settings. If `-n` is omitted, it's derived from `-v` and `-p`.

**Options:**

| Flag | Required | Default | Meaning |
|---|---|---|---|
| `-v VOLUME` | Yes | — | Docker volume name. Prompted for (with a pick-list) if omitted |
| `-p PATH` | Yes | — | Folder inside the volume, relative to its root. Prompted for if omitted |
| `-n NAME` | No | derived from `-v`/`-p` | Identifier for this task, used to find/replace/remove its cron entry |
| `-e HOURS` | No | `2` | How often to run (1–168) |
| `-k KEEP` | No | `36` | Archives to retain, forwarded to the backup script |
| `-d DEST` | Yes, unless `-u` | backup script's default | Forwarded to the backup script. Prompted for if omitted (blank answer keeps the backup script's own default) |
| `-i IMAGE` | No | `alpine:3` | Image used to run `tar`, forwarded to the backup script |
| `-u` | No | — | Remove the cron entry instead of installing it |

**macOS note:** cron needs explicit permission before its jobs will actually run — add `/usr/sbin/cron` (confirm the path with `which cron`) under **System Settings → Privacy & Security → Full Disk Access**. This is a one-time system setting you'll need to grant yourself; the script can't do it for you.

## Typical setup

1. Use VS Code's "Clone Repository in Container Volume" (or otherwise mount a named Docker volume at `/workspaces/.persist`) so dotfiles survive rebuilds.
2. Inside the container, run `container/persist-dotfiles.sh` once (and again after any rebuild, or add it to your devcontainer's `postStartCommand`).
3. On the host, run `Register-VolumeBackupTask.ps1` (Windows) or `register-volume-backup-task.sh` (Linux/macOS) once, pointing it at that same volume, to keep periodic `.tgz` backups on disk as a fallback.

## Requirements

- **Container side:** POSIX `sh`, a Linux container with `/proc` (standard in dev containers).
- **Windows host:** PowerShell and Docker Desktop (or another local Docker engine) for `Backup-DockerVolume.ps1`; Windows Task Scheduler for `Register-VolumeBackupTask.ps1`.
- **Linux/macOS host:** POSIX `sh`, `cron`, and Docker for the scripts in `host/unix/`.

# devcontainer-backup

Tools for keeping dev container state safe across rebuilds — and off the container entirely.

VS Code dev containers are disposable by design: rebuild one and anything that isn't in the repo or a mounted volume is gone. That's fine for the workspace itself, but painful for dotfiles like `.gitconfig`, `.ssh`, `.aws`, or tool state like `.claude` — things you don't want to reconfigure every rebuild, and don't want to bake into the image either.

This repo has two complementary pieces:

1. **[`container/persist-dotfiles.sh`](container/persist-dotfiles.sh)** — runs *inside* the dev container. Moves chosen dotfiles onto a persistent volume (e.g. the one VS Code's "Clone Repository in Container Volume" mounts at `/workspaces/.persist`) and replaces them with symlinks, so they survive rebuilds.
2. **[`host/windows/`](host/windows/)** — runs on the *Windows host*. Periodically archives a folder of that Docker volume to a dated `.tgz` on your machine, as a safety net in case the volume itself is ever lost or corrupted.

Together: dotfiles persist across container rebuilds via the volume, and the volume itself gets backed up to disk.

## How it fits together

```
┌─────────────────────────┐        ┌──────────────────────────────┐
│   Dev Container (Linux) │        │   Windows Host                │
│                          │        │                                │
│  ~/.gitconfig  ──symlink─┼───┐    │  Register-VolumeBackupTask.ps1│
│  ~/.ssh        ──symlink─┼─┐ │    │    (Scheduled Task, every N h)│
│  ~/.claude     ──symlink─┼┐│ │    │           │                    │
│                          ││ │ │    │           ▼                    │
│  persist-dotfiles.sh     ││ │ │    │  Backup-DockerVolume.ps1      │
└──────────────────────────┘│ │ │    │    tars a folder from the     │
                             ▼ ▼ ▼    │    volume → dated .tgz        │
              /workspaces/.persist   │    on the host, pruning old   │
              (Docker volume) ───────┼──► archives beyond -Keep      │
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

## Typical setup

1. Use VS Code's "Clone Repository in Container Volume" (or otherwise mount a named Docker volume at `/workspaces/.persist`) so dotfiles survive rebuilds.
2. Inside the container, run `container/persist-dotfiles.sh` once (and again after any rebuild, or add it to your devcontainer's `postStartCommand`).
3. On the Windows host, run `Register-VolumeBackupTask.ps1` once, pointing `-Volume`/`-Path` at that same volume, to keep periodic `.tgz` backups on disk as a fallback.

## Requirements

- **Container side:** POSIX `sh`, a Linux container with `/proc` (standard in dev containers).
- **Host side:** Windows with PowerShell and Docker Desktop (or another local Docker engine) for `Backup-DockerVolume.ps1`; Windows Task Scheduler for `Register-VolumeBackupTask.ps1`.

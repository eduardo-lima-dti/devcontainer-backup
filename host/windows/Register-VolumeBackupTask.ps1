<#
.SYNOPSIS
  Schedules Backup-DockerVolume.ps1 to run every -IntervalHours while you are
  logged in, or removes that schedule with -Unregister.

.DESCRIPTION
  Expects Backup-DockerVolume.ps1 in the same folder as this script. Runs as
  the current user, without admin rights. A run missed while the PC was off
  starts once it is back on. Re-running with the same -TaskName replaces the
  task, so it is also how you change the settings.

  -Volume and -Path are always required; -Destination is required too unless
  -Unregister is set. Omit any of them (or run the script with no arguments
  at all) and a setup wizard prompts for whatever is missing, listing
  existing Docker volumes to pick from when Docker is reachable, then shows a
  summary to confirm before it registers (or unregisters) the task.

.EXAMPLE
  .\Register-VolumeBackupTask.ps1 -Volume my-volume -Path .persist
.EXAMPLE
  .\Register-VolumeBackupTask.ps1 -Volume my-volume -Path .persist -Unregister
.EXAMPLE
  .\Register-VolumeBackupTask.ps1
  # Prompts for whatever is needed.
#>
param(
  [string]$Volume,
  [string]$Path,
  [string]$TaskName,
  [ValidateRange(1, 168)] [int]$IntervalHours = 2,
  [ValidateRange(1, 10000)] [int]$Keep = 36,
  [string]$Destination,
  [switch]$Unregister
)

function Read-Required {
  param([string]$Prompt, [string]$Help)
  if ($Help) { Write-Host $Help -ForegroundColor DarkGray }
  do { $value = Read-Host $Prompt } while (-not $value)
  return $value
}

function Read-WithDefault {
  param([string]$Prompt, [string]$Default, [string]$Help)
  if ($Help) { Write-Host $Help -ForegroundColor DarkGray }
  $suffix = if ($Default) { " [$Default]" } else { "" }
  $value = Read-Host "$Prompt$suffix"
  if (-not $value) { return $Default }
  return $value
}

function Read-IntWithDefault {
  param([string]$Prompt, [int]$Default, [int]$Min, [int]$Max)
  while ($true) {
    $raw = Read-Host "$Prompt [$Default]"
    if (-not $raw) { return $Default }
    if ($raw -match '^\d+$' -and [int]$raw -ge $Min -and [int]$raw -le $Max) { return [int]$raw }
    Write-Host "Enter a whole number between $Min and $Max." -ForegroundColor Yellow
  }
}

$wizard = -not $Volume -or -not $Path -or (-not $Unregister -and -not $Destination)
if ($wizard) {
  Write-Host ""
  Write-Host "=== Docker volume backup - setup wizard ===" -ForegroundColor Cyan
  Write-Host "A required parameter was missing; answer the prompts below (Enter accepts the default in [brackets])." -ForegroundColor Cyan
  Write-Host ""
}

if (-not $Volume) {
  $volumes = @()
  try { $volumes = @(docker volume ls --format '{{.Name}}' 2>$null) } catch {}
  if ($volumes.Count -gt 0) {
    Write-Host "Existing Docker volumes:"
    for ($i = 0; $i -lt $volumes.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $volumes[$i]) }
    $selection = Read-Required -Prompt "Volume name (or number from the list above)"
    if ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $volumes.Count) {
      $Volume = $volumes[[int]$selection - 1]
    } else {
      $Volume = $selection
    }
  } else {
    $Volume = Read-Required -Prompt "Docker volume name" -Help "Docker wasn't reachable, or has no volumes - type the volume name to use."
  }
}

if (-not $Path) {
  $Path = Read-Required -Prompt "Folder inside the volume" -Help "Relative to the volume's root, e.g. .persist"
}

if ($wizard -and -not $Unregister) {
  $IntervalHours = Read-IntWithDefault -Prompt "Backup interval, in hours" -Default $IntervalHours -Min 1 -Max 168
  $Keep = Read-IntWithDefault -Prompt "Number of archives to keep" -Default $Keep -Min 1 -Max 10000
  $Destination = Read-WithDefault -Prompt "Backup destination folder on this PC (blank = script default)" -Default $Destination
}

if (-not $TaskName) {
  $TaskName = "Docker volume backup - $Volume - $($Path.Trim('/', '\'))" -replace '[\\/:*?"<>|]', '-'
}

if ($wizard) {
  Write-Host ""
  Write-Host "Task name   : $TaskName"
  Write-Host "Volume      : $Volume"
  Write-Host "Path        : $Path"
  if (-not $Unregister) {
    Write-Host "Every       : $IntervalHours h"
    Write-Host "Keep        : $Keep archives"
    Write-Host "Destination : $(if ($Destination) { $Destination } else { '(script default)' })"
  }
  Write-Host "Action      : $(if ($Unregister) { 'Unregister' } else { 'Register' })"
  Write-Host ""
  $confirm = Read-Host "Proceed? [Y/n]"
  if ($confirm -match '^(n|no)$') { Write-Host "Cancelled."; exit 0 }
}

if ($Unregister) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  Write-Host "Removed task '$TaskName'."
  exit 0
}

$backup = Join-Path $PSScriptRoot 'Backup-DockerVolume.ps1'
if (-not (Test-Path -LiteralPath $backup)) { throw "Not found: $backup" }

$arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass " +
  "-File `"$backup`" -Volume `"$Volume`" -Path `"$Path`" -Keep $Keep"
if ($Destination) { $arguments += " -Destination `"$Destination`"" }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Hours $IntervalHours)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Settings $settings -Force `
  -Description "Backs up '$Path' of Docker volume '$Volume' every $IntervalHours h, keeping $Keep archives." |
  Out-Null
Write-Host "Registered '$TaskName': every $IntervalHours h, keeping $Keep archives."
Write-Host "Run it now with: Start-ScheduledTask -TaskName '$TaskName'"

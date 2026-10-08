<#
.SYNOPSIS
  Schedules Backup-DockerVolume.ps1 to run every -IntervalHours while you are
  logged in, or removes that schedule with -Unregister.

.DESCRIPTION
  Expects Backup-DockerVolume.ps1 in the same folder as this script. Runs as
  the current user, without admin rights. A run missed while the PC was off
  starts once it is back on. Re-running with the same -TaskName replaces the
  task, so it is also how you change the settings.

.EXAMPLE
  .\Register-VolumeBackupTask.ps1 -Volume my-volume -Path .persist
.EXAMPLE
  .\Register-VolumeBackupTask.ps1 -Volume my-volume -Path .persist -Unregister
#>
param(
  [Parameter(Mandatory = $true)] [string]$Volume,
  [Parameter(Mandatory = $true)] [string]$Path,
  [string]$TaskName,
  [ValidateRange(1, 168)] [int]$IntervalHours = 2,
  [ValidateRange(1, 10000)] [int]$Keep = 36,
  [string]$Destination,
  [switch]$Unregister
)

if (-not $TaskName) {
  $TaskName = "Docker volume backup - $Volume - $($Path.Trim('/', '\'))" -replace '[\\/:*?"<>|]', '-'
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

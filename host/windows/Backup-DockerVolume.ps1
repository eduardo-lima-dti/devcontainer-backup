<#
.SYNOPSIS
  Backs up one folder of a Docker volume to a dated .tgz on this machine.

.DESCRIPTION
  Mounts the volume read-only in a throwaway container, archives -Path, reads
  the archive back to check it, and keeps the newest -Keep archives. Works
  while the volume is in use. Skips quietly when Docker is not running. Every
  run is logged to backup.log in -Destination.

  Restore an archive (overwrites matching files in the volume):
    docker run --rm -v "<volume>:/w" -v "<destination>:/b" alpine tar xzf /b/<archive> -C /w

.EXAMPLE
  .\Backup-DockerVolume.ps1 -Volume my-volume -Path .persist
#>
param(
  [Parameter(Mandatory = $true)] [string]$Volume,
  # Folder inside the volume, relative to its root.
  [Parameter(Mandatory = $true)] [string]$Path,
  [string]$Destination = (Join-Path $env:USERPROFILE "docker-volume-backups\$Volume"),
  [ValidateRange(1, 10000)] [int]$Keep = 36,
  [string]$Image = 'alpine:3'
)

$Path = $Path.Trim('/', '\')
if (-not $Path -or $Path -match '(^|[\\/])\.\.([\\/]|$)' -or $Path.Contains("'")) {
  throw "-Path must be a folder inside the volume, without '..' or quotes: '$Path'"
}
$Path = $Path -replace '\\', '/'
$prefix = (($Path -split '/')[-1]).TrimStart('.')
if (-not $prefix) { $prefix = 'backup' }

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$log = Join-Path $Destination 'backup.log'
function Write-Log([string]$Message) {
  Add-Content -Path $log -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Volume/$Path] $Message"
}

docker info *> $null
if ($LASTEXITCODE -ne 0) { Write-Log 'Docker is not running, skipped.'; exit 0 }
docker volume inspect $Volume *> $null
if ($LASTEXITCODE -ne 0) { Write-Log 'Volume not found, skipped.'; exit 1 }

$name = "$prefix-$(Get-Date -Format 'yyyyMMdd-HHmmss').tgz"
$file = Join-Path $Destination $name
docker run --rm -v "${Volume}:/w:ro" -v "${Destination}:/b" $Image `
  sh -c "tar czf '/b/$name' -C /w '$Path' && tar tzf '/b/$name' > /dev/null"
if ($LASTEXITCODE -ne 0) {
  Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
  Write-Log "Backup failed (docker exit $LASTEXITCODE)."
  exit 1
}
Write-Log "Created $name ($([math]::Round((Get-Item -LiteralPath $file).Length / 1MB, 1)) MB)."

Get-ChildItem -LiteralPath $Destination -Filter "$prefix-*.tgz" |
  Sort-Object Name -Descending |
  Select-Object -Skip $Keep |
  ForEach-Object { Remove-Item -LiteralPath $_.FullName; Write-Log "Removed old $($_.Name)." }
exit 0

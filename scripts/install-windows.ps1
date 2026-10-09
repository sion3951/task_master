#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string] $SourceDirectory = $PSScriptRoot,
    [switch] $Remove
)
$ErrorActionPreference = 'Stop'
$destination = Join-Path $env:ProgramFiles 'task_master'

if ($Remove) {
    # Persistence belongs to the account that enabled it; stop that task from the
    # ordinary user session before uninstalling shared binaries.
    & (Join-Path $PSScriptRoot 'install-sensors.ps1') -Remove
    Remove-Item -LiteralPath (Join-Path $env:ProgramData 'Microsoft/Windows/Start Menu/Programs/task_master.lnk') -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
    return
}
$source = (Resolve-Path -LiteralPath $SourceDirectory).Path
foreach ($required in @('task_master.exe', 'task_master-collector.exe', 'sensors/task_master.Sensors.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $required))) { throw "Incomplete Windows package: missing $required" }
}
New-Item -ItemType Directory -Force -Path $destination | Out-Null
# The sensor service runs privileged, so protect its parent before staging files.
& icacls.exe $destination '/inheritance:r' '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Could not protect the task_master installation directory.' }
Copy-Item (Join-Path $source 'task_master.exe'), (Join-Path $source 'task_master-collector.exe'), (Join-Path $source 'README.md') -Destination $destination -Force
if (Test-Path -LiteralPath (Join-Path $source 'licenses')) { Copy-Item (Join-Path $source 'licenses') -Destination $destination -Recurse -Force }
& (Join-Path $PSScriptRoot 'install-sensors.ps1') -SourceDirectory (Join-Path $source 'sensors')
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path $env:ProgramData 'Microsoft/Windows/Start Menu/Programs/task_master.lnk'))
$shortcut.TargetPath = Join-Path $destination 'task_master.exe'
$shortcut.WorkingDirectory = $destination
$shortcut.Save()
Write-Host 'task_master installed. Launch it normally from the Start menu; the desktop does not need administrator rights.'

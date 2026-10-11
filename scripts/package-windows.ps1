#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string] $Architecture = 'x64',
    [string] $SourceDirectory,
    [string] $OutputDirectory = 'build/packages',
    [string] $Version,
    [string] $InnoSetupCompiler,
    [switch] $CheckCompilerOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path $PSScriptRoot -Parent

if (-not $InnoSetupCompiler) {
    $command = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($command) { $InnoSetupCompiler = $command.Source }
    else {
        foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
            if ($root) {
                $candidate = Join-Path $root 'Inno Setup 6/ISCC.exe'
                if (Test-Path -LiteralPath $candidate) { $InnoSetupCompiler = $candidate; break }
            }
        }
    }
}
if (-not $InnoSetupCompiler -or -not (Test-Path -LiteralPath $InnoSetupCompiler)) {
    throw 'Install Inno Setup 6.3 or newer, add ISCC.exe to PATH, or pass -InnoSetupCompiler. A full Windows build requires the setup compiler.'
}
$compiler = (Resolve-Path -LiteralPath $InnoSetupCompiler).Path
if ($CheckCompilerOnly) { return }

Push-Location $repository
try {
    if (-not $Version) { $Version = (Get-Content 'VERSION' -Raw).Trim() }
    if ($Version -notmatch '^[0-9][0-9A-Za-z.+~\-]*$') { throw 'Invalid package version.' }
    if (-not $SourceDirectory) { $SourceDirectory = if ($Architecture -eq 'x64') { 'build/windows' } else { 'build/windows-arm64' } }
    $source = (Resolve-Path -LiteralPath $SourceDirectory).Path
    foreach ($required in @('task_master.exe', 'task_master-collector.exe', 'sensors/task_master.Sensors.exe',
        'install-windows.ps1', 'install-sensors.ps1', 'README.md', 'licenses/FONT-LICENSE.txt', 'licenses/GLFW.txt')) {
        $path = Join-Path $source $required
        if (-not (Test-Path -LiteralPath $path) -or (Get-Item -LiteralPath $path).Length -eq 0) {
            throw "Incomplete Windows package: missing or empty $required"
        }
    }
    # Reject an accidentally mixed package before producing a labelled installer.
    $expectedMachine = if ($Architecture -eq 'arm64') { 0xaa64 } else { 0x8664 }
    foreach ($name in @('task_master.exe', 'task_master-collector.exe', 'sensors/task_master.Sensors.exe')) {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $source $name))
        if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { throw "Invalid Windows executable: $name" }
        $offset = [BitConverter]::ToInt32($bytes, 60)
        if ($offset -lt 64 -or $offset -gt $bytes.Length - 24 -or [BitConverter]::ToUInt32($bytes, $offset) -ne 0x4550 -or [BitConverter]::ToUInt16($bytes, $offset + 4) -ne $expectedMachine) {
            throw "Executable architecture does not match $Architecture package: $name"
        }
    }
    # Only Intel/AMD hosts use PawnIO; ARM64 setup skips the unsupported driver.
    if ($Architecture -eq 'x64') {
        & (Join-Path $PSScriptRoot 'install-sensors.ps1') -SourceDirectory (Join-Path $source 'sensors') -PrepareDriverOnly
    }
    $output = [IO.Path]::GetFullPath($OutputDirectory)
    New-Item -ItemType Directory -Force -Path $output | Out-Null
    $setup = Join-Path $output "task_master-$Version-windows-$Architecture-setup.exe"
    & $compiler '/Qp' "/DPayloadDirectory=$source" "/DPackageVersion=$Version" "/DPackageArchitecture=$Architecture" "/O$output" 'packaging/windows/task_master.iss'
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE" }
    if (-not (Test-Path -LiteralPath $setup) -or (Get-Item -LiteralPath $setup).Length -eq 0) {
        throw "Inno Setup did not produce $setup"
    }
    Write-Host "Windows installer ready: $setup"
} finally {
    Pop-Location
}

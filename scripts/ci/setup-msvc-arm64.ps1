#Requires -Version 5.1
# Add the ARM64 cross tools to the hosted runner's existing Visual Studio.
$ErrorActionPreference = 'Stop'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$component = 'Microsoft.VisualStudio.Component.VC.Tools.ARM64'
$installed = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 $component -property installationPath
if ($installed) { return }
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $visualStudio) { throw 'Visual Studio C++ x64 tools were not found.' }
$installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/setup.exe'
$arguments = 'modify --installPath "' + $visualStudio + '" --add ' + $component + ' --quiet --norestart'
$process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
if ($process.ExitCode -notin @(0, 3010)) { throw "ARM64 tool installation failed: $($process.ExitCode)" }
$installed = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 $component -property installationPath
if (-not $installed) { throw 'ARM64 C++ tools are still unavailable after installation.' }

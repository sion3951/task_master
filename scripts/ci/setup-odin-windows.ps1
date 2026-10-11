#Requires -Version 5.1
[CmdletBinding()]
param([string] $OutputDirectory = 'build/toolchains/odin-windows-arm64')
# Windows releases use the pinned Odin source plus the reviewed ARM64 patch.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$revision = '84bc3fc2100b0f7880a3af37f71bccdcda41c6f9'

function Invoke-Checked([string] $Command, [string[]] $Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE" }
}

Push-Location $repository
try {
    $directory = [IO.Path]::GetFullPath($OutputDirectory)
    if (Test-Path -LiteralPath $directory) {
        throw "Toolchain directory already exists: $OutputDirectory. Use a fresh -OutputDirectory to rebuild."
    }
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    Invoke-Checked 'git' @('-C', $directory, 'init', '--quiet')
    Invoke-Checked 'git' @('-C', $directory, 'lfs', 'install', '--local')
    Invoke-Checked 'git' @('-C', $directory, 'fetch', '--depth=1', 'https://github.com/odin-lang/Odin.git', $revision)
    Invoke-Checked 'git' @('-C', $directory, 'checkout', '--detach', 'FETCH_HEAD')
    Invoke-Checked 'git' @('-C', $directory, 'lfs', 'pull')
    Invoke-Checked 'git' @('-C', $directory, 'apply', (Join-Path $repository 'scripts/toolchains/odin-windows-arm64.patch'))
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath
    if (-not $visualStudio) { throw 'Install Visual Studio C++ x64 and ARM64 build tools and the Windows 11 SDK.' }
    $devcmd = Join-Path $visualStudio 'Common7/Tools/VsDevCmd.bat'
    Push-Location $directory
    try {
        # Keep the compiler host x64; it emits both x64 and native ARM64 code.
        $batch = @(
            '@echo off',
            ('call "{0}" -arch=amd64 -host_arch=amd64' -f $devcmd),
            'if errorlevel 1 exit /b 1',
            'call build.bat release',
            'if errorlevel 1 exit /b 1',
            ('call "{0}" -arch=arm64 -host_arch=amd64' -f $devcmd),
            'if errorlevel 1 exit /b 1',
            'pushd vendor\stb\src',
            'if not exist ..\lib\arm64 mkdir ..\lib\arm64',
            'cl /nologo /MT /TC /O2 /MP /c stb_image.c stb_image_write.c stb_image_resize.c',
            'if errorlevel 1 exit /b 1'
        )
        foreach ($name in @('stb_image', 'stb_image_write', 'stb_image_resize')) {
            $batch += "lib /nologo $name.obj /out:..\lib\arm64\$name.lib"
            $batch += 'if errorlevel 1 exit /b 1'
        }
        $batch += @('del *.obj', 'popd', 'exit /b 0')
        $batch | Set-Content 'build-task-master-toolchain.cmd' -Encoding ascii
        try { Invoke-Checked 'cmd.exe' @('/d', '/c', 'build-task-master-toolchain.cmd') }
        finally { Remove-Item 'build-task-master-toolchain.cmd' -ErrorAction SilentlyContinue }
        Invoke-Checked '.\odin.exe' @('version')
    } finally { Pop-Location }
    if ($env:GITHUB_PATH) { $directory | Out-File $env:GITHUB_PATH -Append -Encoding utf8 }
    $env:PATH = $directory + ';' + $env:PATH
} finally { Pop-Location }

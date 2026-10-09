#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $Odin = 'odin',
    [string] $Glslc = 'glslc',
    [string] $VcpkgRoot = $env:VCPKG_ROOT,
    [string] $FreeTypeLibrary,
    [string] $LinuxCollectorDirectory = 'build/collectors',
    [string] $MacCollectorDirectory = 'build/collectors',
    [string] $OutputDirectory = 'build/windows',
    [string] $InstallerOutputDirectory = 'build/packages',
    [string] $Version,
    [string] $InnoSetupCompiler,
    [switch] $CollectorOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path $PSScriptRoot -Parent

function Invoke-Checked([string] $Command, [string[]] $Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE" }
}

Push-Location $repository
try {
    if (-not $CollectorOnly) {
        & (Join-Path $PSScriptRoot 'package-windows.ps1') -InnoSetupCompiler $InnoSetupCompiler -CheckCompilerOnly
    }
    $output = [IO.Path]::GetFullPath($OutputDirectory)
    New-Item -ItemType Directory -Force -Path $output, 'build/collector-src' | Out-Null
    Get-ChildItem 'build/collector-src/*.odin' | Remove-Item
    Copy-Item 'telemetry*.odin', 'remote_protocol.odin', 'collector/*.odin' -Destination 'build/collector-src'
    $collector = Join-Path $output 'task_master-collector.exe'
    Invoke-Checked $Odin @('build', 'build/collector-src', "-out:$collector", '-o:speed', '-vet', '-define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536')
    Invoke-Checked 'dotnet' @('publish', 'sensors/windows/task_master.Sensors.csproj', '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true', '-p:RestoreLockedMode=true', '-o', (Join-Path $output 'sensors'))
    $sensorArchive = [IO.Path]::GetFullPath('build/task_master-windows-sensors.zip')
    Compress-Archive -Path (Join-Path $output 'sensors/*') -DestinationPath $sensorArchive -Force
    if ($CollectorOnly) { return }

    # Require real Linux payloads for the complete desktop. Windows collector-only
    # builds are independent, allowing each OS to publish its own release inputs.
    $linux = [IO.Path]::GetFullPath($LinuxCollectorDirectory)
    $linuxAmd64 = Join-Path $linux 'task_master-collector-linux-amd64'
    $linuxArm64 = Join-Path $linux 'task_master-collector-linux-arm64'
    foreach ($payload in @($linuxAmd64, $linuxArm64)) {
        if (-not (Test-Path -LiteralPath $payload) -or (Get-Item -LiteralPath $payload).Length -eq 0) {
            throw "Missing Linux payload $payload. Run scripts/build-collectors.sh on Linux x64 and ARM64 and place both outputs in $LinuxCollectorDirectory."
        }
        $bytes = [IO.File]::ReadAllBytes($payload)
        if ($bytes.Length -lt 20 -or $bytes[0] -ne 0x7f -or $bytes[1] -ne 0x45 -or $bytes[2] -ne 0x4c -or $bytes[3] -ne 0x46) {
            throw "Collector payload is not an ELF executable: $payload"
        }
        $machine = [BitConverter]::ToUInt16($bytes, 18)
        $expected = if ($payload -eq $linuxAmd64) { 62 } else { 183 }
        if ($machine -ne $expected) { throw "Collector architecture does not match its filename: $payload" }
    }

    # Keep macOS remotes available from Windows release packages too.
    $mac = [IO.Path]::GetFullPath($MacCollectorDirectory)
    $macAmd64 = Join-Path $mac 'task_master-collector-darwin-amd64'
    $macArm64 = Join-Path $mac 'task_master-collector-darwin-arm64'
    foreach ($payload in @($macAmd64, $macArm64)) {
        if (-not (Test-Path -LiteralPath $payload) -or (Get-Item -LiteralPath $payload).Length -eq 0) {
            throw "Missing macOS payload $payload. Build both collectors on macOS and place them in $MacCollectorDirectory."
        }
        $bytes = [IO.File]::ReadAllBytes($payload)
        if ($bytes.Length -lt 32 -or [BitConverter]::ToUInt32($bytes, 0) -ne 0xfeedfacf) {
            throw "Collector payload is not a 64-bit Mach-O executable: $payload"
        }
        $cpu = [BitConverter]::ToUInt32($bytes, 4)
        $expected = if ($payload -eq $macAmd64) { 0x01000007 } else { 0x0100000c }
        if ($cpu -ne $expected -or [BitConverter]::ToUInt32($bytes, 12) -ne 2) {
            throw "macOS collector architecture or executable type does not match its filename: $payload"
        }
    }

    $needShaderCompiler = $Glslc -eq 'glslc' -and -not (Get-Command $Glslc -ErrorAction SilentlyContinue)
    if (-not $FreeTypeLibrary -or $needShaderCompiler) {
        if (-not $VcpkgRoot) { throw 'Set VCPKG_ROOT, or supply both -FreeTypeLibrary and an available -Glslc shader compiler.' }
        $vcpkg = Join-Path $VcpkgRoot 'vcpkg.exe'
        Invoke-Checked $vcpkg @('install', '--triplet=x64-windows-static', '--host-triplet=x64-windows-static', '--x-manifest-root=scripts/windows', '--x-install-root=build/vcpkg-installed')
        if (-not $FreeTypeLibrary) { $FreeTypeLibrary = 'build/vcpkg-installed/x64-windows-static/lib/freetype.lib' }
        if ($needShaderCompiler) { $Glslc = [IO.Path]::GetFullPath('build/vcpkg-installed/x64-windows-static/tools/shaderc/glslc.exe') }
    }
    $freeType = [IO.Path]::GetFullPath($FreeTypeLibrary)
    if (-not (Test-Path -LiteralPath $freeType)) { throw "FreeType library not found: $freeType" }
    Invoke-Checked $Glslc @('shaders/ui.vert', '-o', 'shaders/ui.vert.spv')
    Invoke-Checked $Glslc @('shaders/ui.frag', '-o', 'shaders/ui.frag.spv')

    # Odin currently targets Windows x64. Windows 11 ARM64 executes this payload
    # through x64 emulation; Linux ARM64 always uses its native Linux collector.
    $defines = @(
        "-define:TASK_MASTER_WINDOWS_SENSORS=$($sensorArchive.Replace('\','/'))",
        "-define:TASK_MASTER_COLLECTOR_LINUX_AMD64=$($linuxAmd64.Replace('\','/'))",
        "-define:TASK_MASTER_COLLECTOR_LINUX_ARM64=$($linuxArm64.Replace('\','/'))",
        "-define:TASK_MASTER_COLLECTOR_DARWIN_AMD64=$($macAmd64.Replace('\','/'))",
        "-define:TASK_MASTER_COLLECTOR_DARWIN_ARM64=$($macArm64.Replace('\','/'))",
        "-define:TASK_MASTER_COLLECTOR_WINDOWS_AMD64=$($collector.Replace('\','/'))",
        "-define:TASK_MASTER_COLLECTOR_WINDOWS_ARM64=$($collector.Replace('\','/'))",
        "-define:FREETYPE_LIBRARY=$($freeType.Replace('\','/'))"
    )
    Invoke-Checked $Odin (@('build', '.', "-out:$(Join-Path $output 'task_master.exe')", '-o:speed', '-no-bounds-check', '-vet', '-subsystem:windows', '-define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536') + $defines)
    Copy-Item 'scripts/install-windows.ps1', 'scripts/install-sensors.ps1', 'README.md' -Destination $output
    New-Item -ItemType Directory -Force -Path (Join-Path $output 'licenses') | Out-Null
    Copy-Item 'assets/FONT-LICENSE.txt' -Destination (Join-Path $output 'licenses')
    $odinRoot = (& $Odin root).Trim()
    Copy-Item (Join-Path $odinRoot 'vendor/glfw/LICENSE.txt') -Destination (Join-Path $output 'licenses/GLFW.txt')
    $freeTypeLicense = 'build/vcpkg-installed/x64-windows-static/share/freetype/copyright'
    if (Test-Path $freeTypeLicense) { Copy-Item $freeTypeLicense -Destination (Join-Path $output 'licenses/FreeType.txt') }
    else { Write-Warning 'Include the FreeType license with packages built from a custom static library.' }
    & (Join-Path $PSScriptRoot 'package-windows.ps1') -SourceDirectory $output `
        -OutputDirectory $InstallerOutputDirectory -Version $Version -InnoSetupCompiler $InnoSetupCompiler
} finally {
    Pop-Location
}

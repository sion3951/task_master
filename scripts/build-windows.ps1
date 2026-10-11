#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string] $Architecture = 'x64',
    [string] $Odin = 'odin',
    [string] $Glslc = 'glslc',
    [string] $VcpkgRoot = $env:VCPKG_ROOT,
    [string] $FreeTypeLibrary,
    [string] $GlfwLibrary,
    # Retained for existing callers; native packages do not import remote helpers.
    [string] $LinuxCollectorDirectory = 'build/collectors',
    [string] $MacCollectorDirectory = 'build/collectors',
    [string] $OutputDirectory,
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
    if (-not $Version) { $Version = $env:PACKAGE_VERSION }
    if (-not $Version) { $Version = (Get-Content 'VERSION' -Raw).Trim() }
    if (-not $CollectorOnly) {
        & (Join-Path $PSScriptRoot 'package-windows.ps1') -InnoSetupCompiler $InnoSetupCompiler -CheckCompilerOnly
    }
    if (-not $OutputDirectory) { $OutputDirectory = if ($Architecture -eq 'x64') { 'build/windows' } else { 'build/windows-arm64' } }
    $targetArch = if ($Architecture -eq 'x64') { 'amd64' } else { 'arm64' }
    $triplet = "$Architecture-windows-static"
    $output = [IO.Path]::GetFullPath($OutputDirectory)
    New-Item -ItemType Directory -Force -Path $output, 'build/collector-src' | Out-Null
    Get-ChildItem 'build/collector-src/*.odin' | Remove-Item
    Copy-Item 'telemetry*.odin', 'remote_protocol.odin', 'collector/*.odin' -Destination 'build/collector-src'
    # Desktop builds only need their own architecture. Collector-only release
    # builds export both architectures for signed, on-demand remote downloads.
    $collectorArchitectures = if ($CollectorOnly) { @('amd64', 'arm64') } else { @($targetArch) }
    New-Item -ItemType Directory -Force -Path 'build/collectors' | Out-Null
    foreach ($arch in $collectorArchitectures) {
        $payload = [IO.Path]::GetFullPath("build/collectors/task_master-collector-windows-$arch.exe")
        Invoke-Checked $Odin @('build', 'build/collector-src', "-target:windows_$arch", "-out:$payload", '-o:speed', '-vet', "-define:TASK_MASTER_VERSION=$Version", '-define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536')
        Move-Item -Force $payload ([IO.Path]::GetFullPath("build/collectors/task_master-collector-windows-$arch"))
    }
    $sensorRoot = [IO.Path]::GetFullPath('build/windows-sensors')
    if (Test-Path $sensorRoot) { Remove-Item $sensorRoot -Recurse -Force }
    $sensorArchitectures = if ($CollectorOnly) { @('x64', 'arm64') } else { @($Architecture) }
    if ($CollectorOnly) { Add-Type -AssemblyName System.IO.Compression.FileSystem }
    foreach ($arch in $sensorArchitectures) {
        $sensorPayload = Join-Path $sensorRoot $arch
        Invoke-Checked 'dotnet' @('publish', 'sensors/windows/task_master.Sensors.csproj', '-c', 'Release', '-r', "win-$arch", '--self-contained', 'true', '-p:RestoreLockedMode=true', '-o', $sensorPayload)
        # PawnIO serves Intel/AMD hardware; native ARM64 setup skips this driver.
        if ($arch -eq 'x64') {
            & (Join-Path $PSScriptRoot 'install-sensors.ps1') -SourceDirectory $sensorPayload -PrepareDriverOnly
        }
        if ($CollectorOnly) {
            $payloadArch = if ($arch -eq 'x64') { 'amd64' } else { 'arm64' }
            $sensorArchive = [IO.Path]::GetFullPath("build/collectors/task_master-windows-sensors-$payloadArch.zip")
            if (Test-Path -LiteralPath $sensorArchive) { Remove-Item -LiteralPath $sensorArchive }
            # Each ZIP has one native runtime at its root; only x64 includes PawnIO.
            [IO.Compression.ZipFile]::CreateFromDirectory($sensorPayload, $sensorArchive)
        }
    }
    if ($CollectorOnly) { return }
    $collector = Join-Path $output 'task_master-collector.exe'
    Copy-Item "build/collectors/task_master-collector-windows-$targetArch" $collector
    $sensors = Join-Path $output 'sensors'
    if (Test-Path $sensors) { Remove-Item $sensors -Recurse -Force }
    Copy-Item (Join-Path $sensorRoot $Architecture) $sensors -Recurse

    $needShaderCompiler = $Glslc -eq 'glslc' -and -not (Get-Command $Glslc -ErrorAction SilentlyContinue)
    if (-not $FreeTypeLibrary -or $needShaderCompiler) {
        if (-not $VcpkgRoot) { throw 'Set VCPKG_ROOT, or supply both -FreeTypeLibrary and an available -Glslc shader compiler.' }
        $vcpkg = Join-Path $VcpkgRoot 'vcpkg.exe'
        # Hosted runners can carry a shallow registry older than our pinned baseline.
        $manifest = Get-Content 'scripts/windows/vcpkg.json' -Raw | ConvertFrom-Json
        Invoke-Checked 'git' @('-C', $VcpkgRoot, 'fetch', '--depth=1', 'https://github.com/microsoft/vcpkg.git', $manifest.'builtin-baseline')
        Invoke-Checked $vcpkg @('install', "--vcpkg-root=$VcpkgRoot", "--triplet=$triplet", '--host-triplet=x64-windows-static', '--x-manifest-root=scripts/windows', '--x-install-root=build/vcpkg-installed')
        if (-not $FreeTypeLibrary) { $FreeTypeLibrary = "build/vcpkg-installed/$triplet/lib/freetype.lib" }
        if ($needShaderCompiler) { $Glslc = [IO.Path]::GetFullPath('build/vcpkg-installed/x64-windows-static/tools/shaderc/glslc.exe') }
    }
    $freeType = [IO.Path]::GetFullPath($FreeTypeLibrary)
    if (-not (Test-Path -LiteralPath $freeType)) { throw "FreeType library not found: $freeType" }
    Invoke-Checked $Glslc @('shaders/ui.vert', '-o', 'shaders/ui.vert.spv')
    Invoke-Checked $Glslc @('shaders/ui.frag', '-o', 'shaders/ui.frag.spv')

    if ($Architecture -eq 'arm64' -and -not $GlfwLibrary) {
        $glfwSource = 'build/glfw-source'
        $glfwBuild = "build/glfw-$Architecture"
        if (-not (Test-Path "$glfwSource/.git")) {
            New-Item -ItemType Directory -Force -Path $glfwSource | Out-Null
            Invoke-Checked 'git' @('-C', $glfwSource, 'init', '--quiet')
            Invoke-Checked 'git' @('-C', $glfwSource, 'fetch', '--depth=1', 'https://github.com/glfw/glfw.git', '7b6aead9fb88b3623e3b3725ebb42670cbe4c579')
            Invoke-Checked 'git' @('-C', $glfwSource, 'checkout', '--detach', 'FETCH_HEAD')
        }
        Invoke-Checked 'cmake' @('-S', $glfwSource, '-B', $glfwBuild, '-A', 'ARM64', '-DBUILD_SHARED_LIBS=OFF', '-DCMAKE_POLICY_DEFAULT_CMP0091=NEW', '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded', '-DGLFW_BUILD_DOCS=OFF', '-DGLFW_BUILD_EXAMPLES=OFF', '-DGLFW_BUILD_TESTS=OFF')
        Invoke-Checked 'cmake' @('--build', $glfwBuild, '--config', 'Release', '--parallel', [string][Environment]::ProcessorCount)
        $GlfwLibrary = "$glfwBuild/src/Release/glfw3.lib"
    }
    $nativeCollector = ([IO.Path]::GetFullPath("build/collectors/task_master-collector-windows-$targetArch")).Replace('\','/')
    $defines = @(
        "-define:TASK_MASTER_VERSION=$Version",
        "-define:TASK_MASTER_COLLECTOR_WINDOWS_$($targetArch.ToUpperInvariant())=$nativeCollector",
        "-collection:task_master_freetype=$((Split-Path $freeType -Parent).Replace('\','/'))",
        "-define:FREETYPE_LIBRARY=task_master_freetype:$(Split-Path $freeType -Leaf)"
    )
    if ($GlfwLibrary) {
        $glfw = (Resolve-Path -LiteralPath $GlfwLibrary).Path
        $defines += @("-collection:task_master_glfw=$((Split-Path $glfw -Parent).Replace('\','/'))", "-define:GLFW_LIBRARY=task_master_glfw:$(Split-Path $glfw -Leaf)")
    }
    Invoke-Checked $Odin (@('build', '.', "-target:windows_$targetArch", "-out:$(Join-Path $output 'task_master.exe')", '-o:speed', '-no-bounds-check', '-vet', '-subsystem:windows', '-resource:packaging/windows/task_master.rc', '-define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536') + $defines)
    Copy-Item 'scripts/install-windows.ps1', 'scripts/install-sensors.ps1', 'README.md' -Destination $output
    New-Item -ItemType Directory -Force -Path (Join-Path $output 'licenses') | Out-Null
    Copy-Item 'assets/FONT-LICENSE.txt' -Destination (Join-Path $output 'licenses')
    $odinRoot = (& $Odin root).Trim()
    Copy-Item (Join-Path $odinRoot 'vendor/glfw/LICENSE.txt') -Destination (Join-Path $output 'licenses/GLFW.txt')
    $freeTypeLicense = "build/vcpkg-installed/$triplet/share/freetype/copyright"
    if (Test-Path $freeTypeLicense) { Copy-Item $freeTypeLicense -Destination (Join-Path $output 'licenses/FreeType.txt') }
    else { Write-Warning 'Include the FreeType license with packages built from a custom static library.' }
    & (Join-Path $PSScriptRoot 'package-windows.ps1') -SourceDirectory $output `
        -OutputDirectory $InstallerOutputDirectory -Version $Version -Architecture $Architecture -InnoSetupCompiler $InnoSetupCompiler
} finally {
    Pop-Location
}

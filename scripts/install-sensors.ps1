#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $SourceDirectory = $(if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'sensors')) {
        Join-Path $PSScriptRoot 'sensors'
    } else { Join-Path $PSScriptRoot '../build/windows/sensors' }),
    [switch] $PrepareDriverOnly,
    [switch] $Remove,
    [switch] $RemoveDriver
)
$ErrorActionPreference = 'Stop'
$serviceName = 'task_master_sensors'
$destinationRoot = Join-Path $env:ProgramFiles 'task_master'
$destination = Join-Path $destinationRoot 'Sensors'
$driverVersion = [version]'2.2.0'
$driverUrl = 'https://github.com/namazso/PawnIO.Setup/releases/download/2.2.0/PawnIO_setup.exe'
$driverHash = '1F519A22E47187F70A1379A48CA604981C4FCF694F4E65B734AAA74A9FBA3032'

function Invoke-Sc([string[]] $Arguments) {
    & sc.exe @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Service command failed with exit code $LASTEXITCODE" }
}

function Stop-Sensors {
    $existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($existing -and $existing.Status -ne 'Stopped') {
        # Issue the request directly so the bounded wait is the only polling wait.
        $existing.Stop()
        $existing.WaitForStatus('Stopped', [timespan]::FromSeconds(30))
    }
}

function Get-PawnIoVersion {
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PawnIO',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\PawnIO')) {
        $item = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($item -and $item.DisplayVersion) { return [version]$item.DisplayVersion }
    }
    return $null
}

function Invoke-PinnedDriverInstaller([string[]] $Operations, [switch] $PrepareOnly) {
    $installer = Join-Path $SourceDirectory 'PawnIO_setup.exe'
    $temporary = $null
    try {
        if (-not (Test-Path -LiteralPath $installer)) {
            $temporary = Join-Path ([IO.Path]::GetTempPath()) ('task_master-pawnio-' + [guid]::NewGuid() + '.exe')
            $installer = $temporary
            Write-Host 'Downloading the pinned PawnIO driver installer...'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            # PowerShell 5.1's per-chunk progress rendering slows large downloads.
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -UseBasicParsing -Uri $driverUrl -OutFile $installer
        }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $installer).Hash -ne $driverHash) {
            throw 'The PawnIO installer does not match the pinned official release.'
        }
        if ((Get-AuthenticodeSignature -LiteralPath $installer).Status -ne 'Valid') {
            throw 'The official PawnIO installer signature could not be verified.'
        }
        if ($PrepareOnly) {
            if ($temporary) { Copy-Item -LiteralPath $installer -Destination (Join-Path $SourceDirectory 'PawnIO_setup.exe') }
            Write-Host 'Verified PawnIO installer ready for offline packaging.'
            return
        }
        # Upgrades reuse the same verified executable for uninstall and install.
        foreach ($operation in $Operations) {
            $elapsed = [Diagnostics.Stopwatch]::StartNew()
            Write-Host "PawnIO $operation..."
            # Omit -unrestricted: only the officially signed edition is installed.
            $process = Start-Process -FilePath $installer -ArgumentList @($operation, '-silent') -Wait -PassThru
            if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
                throw "PawnIO $operation failed with exit code $($process.ExitCode)"
            }
            if ($process.ExitCode -eq 3010) { Write-Host 'Restart Windows to finish the driver installation.' }
            Write-Host ('PawnIO {0} finished in {1:N1}s.' -f $operation, $elapsed.Elapsed.TotalSeconds)
        }
    } finally {
        if ($temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Assert-OrdinaryDirectory([string] $Path) {
    if ((Test-Path -LiteralPath $Path) -and
        ((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing a junction or symbolic link at $Path"
    }
}

function Protect-SensorDirectory([string] $Path) {
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($entry in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($entry[0])
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $entry[1],
            'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

if ($PrepareDriverOnly) {
    if ($Remove -or $RemoveDriver) { throw '-PrepareDriverOnly cannot be combined with removal.' }
    $SourceDirectory = (Resolve-Path -LiteralPath $SourceDirectory).Path
    Invoke-PinnedDriverInstaller -PrepareOnly
    return
}
$administrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $administrator) { throw 'Run sensor installation/removal from Administrator PowerShell.' }
if (-not [Environment]::Is64BitOperatingSystem -or [Environment]::OSVersion.Version.Build -lt 22000) {
    throw 'The sensor service requires 64-bit Windows 11 or later.'
}
if ($RemoveDriver -and -not $Remove) { throw '-RemoveDriver requires -Remove.' }
Assert-OrdinaryDirectory $destinationRoot
Assert-OrdinaryDirectory $destination

if ($Remove) {
    Stop-Sensors
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) { Invoke-Sc -Arguments @('delete', $serviceName) }
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
    if ($RemoveDriver) { Invoke-PinnedDriverInstaller -Operations @('-uninstall') }
    Write-Host 'task_master sensor service removed.'
    exit 0
}

# Read the machine architecture directly; avoid starting WMI just for this.
# The process architecture can be AMD64 under Windows ARM64 emulation.
$nativeArchitecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Machine')
$nativeArm64 = if ($nativeArchitecture) { $nativeArchitecture -eq 'ARM64' } else {
    @(Get-CimInstance -ClassName Win32_Processor)[0].Architecture -eq 12
}
$source = (Resolve-Path -LiteralPath $SourceDirectory).Path
$architecture = if ($nativeArm64) { 'arm64' } else { 'x64' }
# Remote archives carry both native runtimes; desktop installers carry one.
$nativeSource = Join-Path $source $architecture
if (Test-Path -LiteralPath $nativeSource) { $source = $nativeSource }
if (-not (Test-Path -LiteralPath (Join-Path $source 'task_master.Sensors.exe'))) {
    throw "Build the self-contained $architecture sensor helper before installation: $SourceDirectory"
}
if ($nativeArm64) {
    # LibreHardwareMonitor/PawnIO supports Intel/AMD package sensors. The native
    # ARM64 helper reports that hardware limitation; Windows counters stay active.
    Write-Host 'Windows ARM64: hardware CPU package sensors are unavailable; native Windows counters remain enabled.'
} else {
    $installed = Get-PawnIoVersion
    if (-not $installed) {
        Invoke-PinnedDriverInstaller -Operations @('-install')
    } elseif ($installed -lt $driverVersion) {
        # The official installer requires an uninstall before upgrading.
        Stop-Sensors
        Invoke-PinnedDriverInstaller -Operations @('-uninstall', '-install')
    }
    if ((Get-PawnIoVersion) -lt $driverVersion) { throw 'PawnIO 2.2 or newer was not installed successfully.' }
}

New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
Protect-SensorDirectory $destinationRoot
$staging = Join-Path $destinationRoot ('Sensors.new.' + [guid]::NewGuid())
$backup = Join-Path $destinationRoot ('Sensors.old.' + [guid]::NewGuid())
try {
    New-Item -ItemType Directory -Path $staging | Out-Null
    Protect-SensorDirectory $staging
    $elapsed = [Diagnostics.Stopwatch]::StartNew()
    $copyThreads = [Math]::Min(32, [Math]::Max(8, [Environment]::ProcessorCount))
    Write-Host "Staging the sensor runtime with $copyThreads copy workers..."
    # Copy data, attributes and timestamps only; inherit the protected staging ACL.
    # Bound retries instead of robocopy's default million 30-second retries.
    & robocopy.exe $source $staging /E /COPY:DAT /DCOPY:DAT "/MT:$copyThreads" /R:2 /W:1 /NP /NFL /NDL /NJH /NJS /XF PawnIO_setup.exe | Out-Host
    if ($LASTEXITCODE -ge 8) { throw "Could not stage the sensor runtime: robocopy exit code $LASTEXITCODE" }
    Write-Host ('Sensor runtime staged in {0:N1}s.' -f $elapsed.Elapsed.TotalSeconds)
    $elapsed.Restart()
    Write-Host 'Updating the sensor service...'
    Stop-Sensors
    if (Test-Path -LiteralPath $destination) { Move-Item -LiteralPath $destination -Destination $backup }
    Move-Item -LiteralPath $staging -Destination $destination
    $binary = '"' + (Join-Path $destination 'task_master.Sensors.exe') + '" --service'
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        # Use a structured API for the quoted executable path. Windows
        # PowerShell's native argument quoting can lose embedded quotes in sc.
        $configuration = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
        if ($configuration.ImagePath -ne $binary -or $configuration.Start -ne 2 -or $configuration.ObjectName -ne 'LocalSystem') {
            $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'"
            $result = Invoke-CimMethod -InputObject $service -MethodName Change -Arguments @{
                PathName = $binary; StartMode = 'Automatic'; StartName = 'LocalSystem'
            }
            if ($result.ReturnValue -ne 0) { throw "Service update failed: $($result.ReturnValue)" }
        }
    } else {
        New-Service -Name $serviceName -BinaryPathName $binary -StartupType Automatic `
            -DisplayName 'task_master read-only hardware sensors' | Out-Null
    }
    Invoke-Sc -Arguments @('description', $serviceName, 'Reads CPU power and clocks; local clients receive read-only snapshots.')
    Invoke-Sc -Arguments @('failure', $serviceName, 'reset=', '86400', 'actions=', 'restart/5000/restart/30000/restart/60000')
    Start-Service -Name $serviceName
    (Get-Service -Name $serviceName).WaitForStatus('Running', [timespan]::FromSeconds(30))
    Write-Host ('Sensor service ready in {0:N1}s.' -f $elapsed.Elapsed.TotalSeconds)
    if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
} catch {
    Stop-Sensors
    if (Test-Path -LiteralPath $backup) {
        if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
        Move-Item -LiteralPath $backup -Destination $destination
        Start-Service -Name $serviceName -ErrorAction SilentlyContinue
    }
    throw
} finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}
Write-Host 'task_master sensor service installed. The desktop and background collector run without elevation.'

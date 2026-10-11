param([Parameter(Mandatory=$true)][int] $ExpectedProtocol)
$ErrorActionPreference = 'Stop'
$administrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $administrator) { throw 'This SSH account needs an administrator token to install the collector and sensor service. Use an administrator SSH account, then retry Setup / fix.' }
$destination = Join-Path $env:ProgramFiles 'task_master'
if ((Test-Path -LiteralPath $destination) -and ((Get-Item -LiteralPath $destination).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Refusing a symbolic link or junction at the install directory.' }
New-Item -ItemType Directory -Path $destination -Force | Out-Null
& icacls.exe $destination /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX'
if ($LASTEXITCODE -ne 0) { throw 'Could not protect the collector directory.' }
$temporary = Join-Path $destination ('collector-' + [guid]::NewGuid() + '.exe')
try {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'collector.exe') -Destination $temporary
    $target = Join-Path $destination 'task_master-collector.exe'
    # Loaded Windows executables cannot be overwritten. Retire only sessions
    # running this exact installed collector; their SSH clients reconnect.
    Get-CimInstance -ClassName Win32_Process -Filter "Name='task_master-collector.exe'" |
        Where-Object { $_.ExecutablePath -eq $target } |
        ForEach-Object {
            $stopped = Invoke-CimMethod -InputObject $_ -MethodName Terminate
            if ($stopped.ReturnValue -ne 0) { throw "Could not stop installed collector PID $($_.ProcessId)." }
        }
    Move-Item -LiteralPath $temporary -Destination $target -Force
} finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'sensors.zip')) {
    # Extract through .NET directly instead of PowerShell work for every DLL.
    # A fresh directory supports retries without overwrite or stale-file issues.
    $sensors = Join-Path $PSScriptRoot ('sensors-' + [guid]::NewGuid())
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $PSScriptRoot 'sensors.zip'), $sensors)
        & (Join-Path $PSScriptRoot 'install-sensors.ps1') -SourceDirectory $sensors
    } finally {
        if (Test-Path -LiteralPath $sensors) { Remove-Item -LiteralPath $sensors -Recurse -Force }
    }
} elseif (-not (Get-Service -Name task_master_sensors -ErrorAction SilentlyContinue)) {
    throw 'Collector installed, but this development build has no Windows sensor payload. Use a complete release build and retry to install power/clock sensors.'
}
$actualProtocol = & $target --protocol-version
if ($LASTEXITCODE -ne 0 -or [string]$actualProtocol -ne [string]$ExpectedProtocol) { throw "Installed collector protocol $actualProtocol does not match $ExpectedProtocol. Retry with a matching release build." }
Write-Host "Durable collector protocol $actualProtocol verified. Fresh telemetry will confirm sensor access."

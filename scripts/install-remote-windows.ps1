$ErrorActionPreference = 'Stop'
$administrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $administrator) { throw 'This SSH account needs an administrator token to install the collector and sensor service. Use an administrator SSH account, then retry Install / fix.' }
$destination = Join-Path $env:ProgramFiles 'task_master'
if ((Test-Path -LiteralPath $destination) -and ((Get-Item -LiteralPath $destination).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Refusing a symbolic link or junction at the install directory.' }
New-Item -ItemType Directory -Path $destination -Force | Out-Null
& icacls.exe $destination /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX'
if ($LASTEXITCODE -ne 0) { throw 'Could not protect the collector directory.' }
$temporary = Join-Path $destination ('collector-' + [guid]::NewGuid() + '.exe')
try {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'collector') -Destination $temporary
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
    Expand-Archive -LiteralPath (Join-Path $PSScriptRoot 'sensors.zip') -DestinationPath (Join-Path $PSScriptRoot 'sensors') -Force
    & (Join-Path $PSScriptRoot 'install-sensors.ps1') -SourceDirectory (Join-Path $PSScriptRoot 'sensors')
} elseif (-not (Get-Service -Name task_master_sensors -ErrorAction SilentlyContinue)) {
    throw 'Collector installed, but this development build has no Windows sensor payload. Use a complete release build and retry to install power/clock sensors.'
}
Write-Host 'task_master collector and sensor service ready.'

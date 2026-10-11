$ErrorActionPreference = 'Stop'
$stage = @STAGE@
$sshHost = @HOST@
$port = @PORT@
$installRequested = @INSTALL@
$protocol = @PROTOCOL@
$step = 'Starting'
function Show-Progress([string] $Message) {
    $script:step = $Message
    [IO.File]::WriteAllText((Join-Path $stage 'progress'), $Message)
    Write-Host "`n$Message"
}
$windowsProbe = @WINDOWS_PROBE@
$windowsInstall = @WINDOWS_INSTALL@
$windowsCleanup = @WINDOWS_CLEANUP@
$remoteStage = $null
$remoteWindows = $false
$options = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=8')
function Invoke-Ssh([string[]] $Arguments, [switch] $Interactive) {
    $argumentsWithPort = $options
    if ($Interactive) { $argumentsWithPort = @('-o', 'BatchMode=no', '-o', 'StrictHostKeyChecking=ask', '-o', 'ConnectTimeout=8') }
    if ($port -gt 0) { $argumentsWithPort += @('-p', [string]$port) }
    & ssh.exe @argumentsWithPort @Arguments
    if ($LASTEXITCODE -ne 0) { throw "SSH failed with exit code $LASTEXITCODE" }
}
function Send-Files([string[]] $Arguments) {
    $argumentsWithPort = @('-q') + $options
    if ($port -gt 0) { $argumentsWithPort += @('-P', [string]$port) }
    & scp.exe @argumentsWithPort @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Transfer failed with exit code $LASTEXITCODE" }
}
$result = 1
try {
    if (-not $installRequested) {
        Write-Host "Opening passwordless SSH to $sshHost. Exit the shell to return to task_master."
        Invoke-Ssh -Arguments @('-t', '--', $sshHost)
    } else {
        Write-Host "Guided setup for $sshHost. This installs a durable collector and hardware sensor access."
        Write-Host 'Ordinary reconnections reuse the installed collector without administrator prompts.'
        Show-Progress 'Step 1/6: SSH connection and host trust'
        try { Invoke-Ssh -Arguments @('--', $sshHost, 'exit') }
        catch {
            Write-Host 'Check the SSH error above. For a new host, verify its displayed fingerprint before accepting it.'
            Write-Host 'The following connection can ask for host trust or your account password.'
            Invoke-Ssh -Arguments @('--', $sshHost, 'exit') -Interactive
        }
        Show-Progress 'Step 2/6: Passwordless authentication for automatic reconnection'
        try { Invoke-Ssh -Arguments @('--', $sshHost, 'exit') }
        catch { throw 'SSH works interactively, but unattended authentication needs a key or agent. Add this PC to your SSH configuration, load its key into your SSH agent, then retry Setup / fix.' }
        Show-Progress 'Step 3/6: Operating system and architecture'
        $probeOptions = $options
        if ($port -gt 0) { $probeOptions += @('-p', [string]$port) }
        try { $platform = @(& ssh.exe @probeOptions -- $sshHost 'uname -s; uname -m' 2>$null) }
        catch { $platform = @() }
        if ($LASTEXITCODE -ne 0 -or $platform.Count -ne 2 -or $platform[0] -notin @('Linux', 'Darwin')) {
            $platform = @(Invoke-Ssh -Arguments @('--', $sshHost, $windowsProbe))
            if ($platform.Count -ne 1 -or $platform[0] -notlike 'task_master-windows-*') { throw 'Unsupported remote operating system.' }
            $system = 'windows'; $remoteWindows = $true
            $architecture = $platform[0].Substring('task_master-windows-'.Length)
        } else { $system = $platform[0].ToLowerInvariant(); $architecture = $platform[1] }
        switch ($architecture) {
            { $_ -in @('x86_64', 'amd64', 'AMD64', 'X64') } { $architecture = 'amd64' }
            { $_ -in @('aarch64', 'arm64', 'ARM64') } { $architecture = 'arm64' }
            'riscv64' { $architecture = 'riscv64' }
            default { throw "Unsupported architecture: $architecture" }
        }
        $payload = Join-Path $stage "collector-$system-$architecture"
        if (-not (Test-Path -LiteralPath $payload)) { throw "This build has no $system $architecture collector. Use a complete release build." }
        Write-Host "Detected $system $architecture; bundled collector uses protocol $protocol."
        Show-Progress 'Step 4/6: Transfer and collector compatibility'
        $scpHost = $sshHost
        if ($scpHost.Contains(':') -and -not $scpHost.Contains('[')) {
            $split = $scpHost.LastIndexOf('@')
            if ($split -ge 0) { $scpHost = $scpHost.Substring(0, $split+1) + '[' + $scpHost.Substring($split+1) + ']' }
            else { $scpHost = '[' + $scpHost + ']' }
        }
        if ($remoteWindows) {
            $remoteStage = (Invoke-Ssh -Arguments @('--', $sshHost, @WINDOWS_STAGE@)).Trim()
            Send-Files -Arguments @($payload, "${scpHost}:$remoteStage/collector.exe")
            Send-Files -Arguments @((Join-Path $stage 'install-remote-windows.ps1'), (Join-Path $stage 'install-sensors.ps1'), "${scpHost}:$remoteStage/")
            if (Test-Path -LiteralPath (Join-Path $stage 'sensors.zip')) { Send-Files -Arguments @((Join-Path $stage 'sensors.zip'), "${scpHost}:$remoteStage/") }
            Invoke-Ssh -Arguments @('--', $sshHost, @WINDOWS_VALIDATE@)
            Show-Progress 'Step 5/6: Durable collector and sensor permissions (administrator access)'
            Invoke-Ssh -Arguments @('-t', '--', $sshHost, $windowsInstall)
        } else {
            $remoteStage = (Invoke-Ssh -Arguments @('--', $sshHost, 'umask 077; mktemp -d /tmp/task_master-install-XXXXXXXX')).Trim()
            if ($remoteStage -cnotmatch '^/tmp/task_master-install-[A-Za-z0-9]{8}$') { $remoteStage=$null; throw 'Unexpected remote staging path.' }
            Send-Files -Arguments @($payload, "${scpHost}:$remoteStage/collector")
            Send-Files -Arguments @((Join-Path $stage 'install-remote-unix.sh'), (Join-Path $stage 'install-system.sh'), (Join-Path $stage 'task_master-sensors.sh'), (Join-Path $stage 'sensors.plist'), "${scpHost}:$remoteStage/")
            $validate = 'chmod 700 ''' + $remoteStage + '/collector''; actual=$( ''' + $remoteStage + '/collector'' --protocol-version ); [ "$actual" = ''' + $protocol + ''' ] || { echo ''Collector protocol mismatch. Use a complete matching release build.'' >&2; exit 1; }'
            Invoke-Ssh -Arguments @('--', $sshHost, $validate)
            Show-Progress 'Step 5/6: Durable collector and sensor permissions (administrator access)'
            $command = 'if [ "$(id -u)" -eq 0 ]; then sh ''' + $remoteStage + '/install-remote-unix.sh'' ' + $protocol + '; else sudo sh ''' + $remoteStage + '/install-remote-unix.sh'' ' + $protocol + '; fi'
            Invoke-Ssh -Arguments @('-t', '--', $sshHost, $command)
        }
    }
    if ($installRequested) { Show-Progress 'Step 6/6: Reconnect and verify fresh telemetry in task_master' }
    else { Write-Host 'SSH session finished.' }
    $result = 0
} catch {
    Write-Host "Setup failed during ${step}: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if ($remoteStage) {
        try {
            if ($remoteWindows) { Invoke-Ssh -Arguments @('--', $sshHost, $windowsCleanup) | Out-Null }
            else { Invoke-Ssh -Arguments @('--', $sshHost, "rm -rf '$remoteStage'") | Out-Null }
        } catch { Write-Host 'Remote staging cleanup failed. Reconnect and remove the temporary installation directory.' }
    }
    Get-ChildItem -LiteralPath $stage -File | Where-Object { $_.Name -ne 'progress' } | Remove-Item -Force
    [IO.File]::WriteAllText((Join-Path $stage 'result.pending'), [string]$result)
    Move-Item -LiteralPath (Join-Path $stage 'result.pending') -Destination (Join-Path $stage 'result') -Force
    try { Read-Host 'Press Enter to close this terminal' | Out-Null } finally {
        for ($attempt = 0; $attempt -lt 3 -and -not (Test-Path -LiteralPath (Join-Path $stage 'acknowledged')); $attempt++) { Start-Sleep -Seconds 1 }
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
exit $result

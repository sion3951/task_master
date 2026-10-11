param(
    [Parameter(Mandatory)][string]$Package,
    [Parameter(Mandatory)][string]$Stage,
    [Parameter(Mandatory)][int]$ParentPid,
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$Sha256,
    [Parameter(Mandatory)][long]$Size
)
$ErrorActionPreference = 'Stop'
$result = Join-Path (Split-Path -Parent $Stage) 'install-result.txt'
$log = Join-Path $Stage 'install.log'
$lastLog = Join-Path (Split-Path -Parent $Stage) 'last-install.log'
$installerLog = Join-Path $Stage 'setup.log'
$lastSetupLog = Join-Path (Split-Path -Parent $Stage) 'last-setup.log'
$status = 'error'
$message = 'The update installer did not finish.'
$parentExited = $false
$packageLock = $null
$updateMutex = $null
$mutexOwned = $false
function Copy-BoundedLog([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source)) { return }
    $stream = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $length = [int][Math]::Min($stream.Length, 262144)
        [void]$stream.Seek(-$length, [IO.SeekOrigin]::End)
        $bytes = [byte[]]::new($length)
        $read = 0
        while ($read -lt $length) {
            $count = $stream.Read($bytes, $read, $length - $read)
            if ($count -eq 0) { break }
            $read += $count
        }
        [IO.File]::WriteAllBytes($Destination, $bytes)
    } finally { $stream.Dispose() }
}
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run task_master as your normal account to update and relaunch safely.'
    }
    $sid = $identity.User.Value
    $parent = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
    if ($parent -and -not $parent.WaitForExit(120000)) { throw 'task_master did not close; the previous installation was retained.' }
    $parentExited = $true
    # Acquire after desktop shutdown so lock conflicts still relaunch the app.
    $updateMutex = [Threading.Mutex]::new($false, "Local\task_master.Update.$sid")
    try { $mutexOwned = $updateMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $mutexOwned = $true }
    if (-not $mutexOwned) { throw 'Another task_master update is already installing.' }
    $file = Get-Item -LiteralPath $Package
    $packageLock = [IO.File]::Open($Package, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $packageLock.Length -ne $Size -or
        (Get-FileHash -InputStream $packageLock -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Sha256) {
        throw 'Downloaded package changed after verification; the previous installation was retained.'
    }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TaskMasterUpdateNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr OpenEvent(uint access, bool inherit, string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr OpenMutex(uint access, bool inherit, string name);
    [DllImport("kernel32.dll")] public static extern bool SetEvent(IntPtr handle);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
}
'@
    # Preserve scheduled-task enablement. The ordinary desktop refreshes its
    # stable background copy and restarts the collector after the update.
    $stop = [TaskMasterUpdateNative]::OpenEvent(2, $false, "Global\task_master.Persistence.Stop.$sid")
    if ($stop -eq [IntPtr]::Zero -and [Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 2) { throw 'Could not inspect background persistence shutdown signal.' }
    if ($stop -ne [IntPtr]::Zero) {
        try { if (-not [TaskMasterUpdateNative]::SetEvent($stop)) { throw 'Could not request background persistence shutdown.' } }
        finally { [void][TaskMasterUpdateNative]::CloseHandle($stop) }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(35)
    # The existing mutex marks lifetime; it is never acquired by the collector.
    # Wait for the named object to disappear rather than acquire ownership.
    while ($true) {
        $mutex = [TaskMasterUpdateNative]::OpenMutex(0x100000, $false, "Global\task_master.Persistence.Running.$sid")
        if ($mutex -eq [IntPtr]::Zero) {
            if ([Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 2) { throw 'Could not inspect background persistence lifetime.' }
            break
        }
        [void][TaskMasterUpdateNative]::CloseHandle($mutex)
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Background persistence did not stop cleanly.' }
        Start-Sleep -Milliseconds 50
    }
    # PowerShell stays unprivileged. Elevate only Inno Setup; relaunch afterward
    # comes from this original-user process, never from the elevated installer.
    # UAC may use a different administrator account. Grant that account's group
    # read access to this public installer only, plus write access to its log;
    # the user's update cache and preferences keep their protected private ACLs.
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    foreach ($path in @($Stage, $Package)) {
        $acl = Get-Acl -LiteralPath $path
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($administrators,
            [Security.AccessControl.FileSystemRights]::ReadAndExecute,
            [Security.AccessControl.AccessControlType]::Allow))
        Set-Acl -LiteralPath $path -AclObject $acl
    }
    [IO.File]::WriteAllText($installerLog, '')
    $acl = Get-Acl -LiteralPath $installerLog
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($administrators,
        [Security.AccessControl.FileSystemRights]::Modify,
        [Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $installerLog -AclObject $acl
    $arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /LOG="' + $installerLog + '"'
    $installer = Start-Process -FilePath $Package -Verb RunAs -ArgumentList $arguments -Wait -PassThru
    if ($installer.ExitCode -ne 0) { throw "The installer failed with exit code $($installer.ExitCode). See $lastSetupLog." }
    $status = 'success'
    $message = 'task_master was updated successfully.'
} catch {
    $message = $_.Exception.Message
    $message | Out-File -LiteralPath $log -Encoding utf8 -Append
} finally {
    if ($packageLock) { $packageLock.Dispose() }
    if (Test-Path -LiteralPath $log) { Copy-BoundedLog $log $lastLog }
    else { [IO.File]::WriteAllText($lastLog, $message, [Text.UTF8Encoding]::new($false)) }
    if (Test-Path -LiteralPath $installerLog) { Copy-BoundedLog $installerLog $lastSetupLog }
    # Use BOM-free UTF-8 because the Odin result reader matches the first line.
    [IO.File]::WriteAllText($result + '.tmp', "$status`n$message`nInstallation log: $lastLog`nInstaller log: $lastSetupLog`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath ($result + '.tmp') -Destination $result -Force
    if ($parentExited) {
        try { Start-Process -FilePath $Executable -WorkingDirectory (Split-Path -Parent $Executable) }
        catch { $_.Exception.Message | Out-File -LiteralPath $lastLog -Encoding utf8 -Append }
    }
    Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
    if ($mutexOwned) { $updateMutex.ReleaseMutex() }
    if ($updateMutex) { $updateMutex.Dispose() }
}

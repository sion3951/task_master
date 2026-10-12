#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [Uri] $Url,
    [Parameter(Mandatory = $true)] [string] $Destination,
    [Parameter(Mandatory = $true)] [long] $Limit
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Runs in a hidden, cancellable job owned by the desktop updater. Use the
# inbox .NET client instead of depending on curl.exe or PowerShell aliases.
$response = $null
$inputStream = $null
$outputStream = $null
$success = $false
try {
    if ($Limit -le 0) { throw 'Invalid download size limit.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $elapsed = [Diagnostics.Stopwatch]::StartNew()
    for ($redirects = 0; ; $redirects++) {
        if (-not $Url.IsAbsoluteUri -or $Url.Scheme -ne 'https') { throw 'Only HTTPS downloads are allowed.' }
        if ($elapsed.Elapsed.TotalSeconds -ge 300) { throw 'Download timed out.' }
        $request = [Net.HttpWebRequest]::Create($Url)
        $request.AllowAutoRedirect = $false
        $request.Timeout = 10000
        $request.ReadWriteTimeout = 30000
        $request.UserAgent = 'task_master-updater'
        $response = $request.GetResponse()
        $status = [int] $response.StatusCode
        if ($status -in @(301, 302, 303, 307, 308)) {
            if ($redirects -ge 4) { throw 'Too many download redirects.' }
            $location = $response.Headers['Location']
            if (-not $location) { throw 'Missing download redirect location.' }
            $Url = [Uri]::new($Url, $location)
            $response.Close()
            $response = $null
            continue
        }
        if ($status -ne 200) { throw "Unexpected HTTP status $status." }
        if ($response.ContentLength -gt $Limit) { throw 'Download exceeds its size limit.' }
        break
    }
    $inputStream = $response.GetResponseStream()
    $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $buffer = New-Object byte[] 65536
    $total = [long] 0
    $speedBytes = [long] 0
    $speedWindow = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if ($elapsed.Elapsed.TotalSeconds -ge 300) { throw 'Download timed out.' }
        $count = $inputStream.Read($buffer, 0, $buffer.Length)
        if ($count -eq 0) { break }
        $total += $count
        if ($total -gt $Limit) { throw 'Download exceeds its size limit.' }
        $outputStream.Write($buffer, 0, $count)
        if ($speedWindow.Elapsed.TotalSeconds -ge 30) {
            if (($total - $speedBytes) / $speedWindow.Elapsed.TotalSeconds -lt 1024) { throw 'Download stalled.' }
            $speedBytes = $total
            $speedWindow.Restart()
        }
    }
    if ($response.ContentLength -ge 0 -and $total -ne $response.ContentLength) { throw 'Download was incomplete.' }
    $success = $true
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
} finally {
    if ($null -ne $outputStream) { $outputStream.Dispose() }
    if ($null -ne $inputStream) { $inputStream.Dispose() }
    if ($null -ne $response) { $response.Close() }
    if (-not $success) { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue }
}
if (-not $success) { exit 1 }
exit 0

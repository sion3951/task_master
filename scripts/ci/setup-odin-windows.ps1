#Requires -Version 5.1
# Same checksum-pinned compiler as the Linux/macOS release builds.
$ErrorActionPreference = 'Stop'
$directory = Join-Path $PWD 'build/toolchains/odin'
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$archive = Join-Path $directory 'compiler.zip'
Invoke-WebRequest 'https://github.com/odin-lang/Odin/releases/download/dev-2026-10/odin-windows-amd64-dev-2026-10.zip' -OutFile $archive
if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'b6b2e426a8b6f147b74ec7e18bef8df27cf40fe16193159df7ca09a0cc0c2011') {
  throw 'Odin compiler checksum mismatch.'
}
Expand-Archive $archive -DestinationPath $directory
Remove-Item $archive
$compiler = @(Get-ChildItem $directory -Filter odin.exe -Recurse)
if ($compiler.Count -ne 1) { throw 'Expected one Odin compiler executable.' }
if ($env:GITHUB_PATH) { $compiler[0].DirectoryName | Out-File $env:GITHUB_PATH -Append -Encoding utf8 }
$env:PATH = $compiler[0].DirectoryName + ';' + $env:PATH

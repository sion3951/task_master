package main

import "core:encoding/base64"
import "core:fmt"
import "core:strings"

// Release builds supply each payload independently of the desktop's OS/CPU.
// Native development builds remain usable without cross-compilers installed.
when ODIN_OS==.Linux&&ODIN_ARCH==.amd64 {
    REMOTE_COLLECTOR_LINUX_AMD64 :: #load(#config(TASK_MASTER_COLLECTOR_LINUX_AMD64,"build/task_master-collector"))
} else {
    REMOTE_COLLECTOR_LINUX_AMD64 :: #load(#config(TASK_MASTER_COLLECTOR_LINUX_AMD64,"assets/empty.bin"))
}
when ODIN_OS==.Linux&&ODIN_ARCH==.arm64 {
    REMOTE_COLLECTOR_LINUX_ARM64 :: #load(#config(TASK_MASTER_COLLECTOR_LINUX_ARM64,"build/task_master-collector"))
} else {
    REMOTE_COLLECTOR_LINUX_ARM64 :: #load(#config(TASK_MASTER_COLLECTOR_LINUX_ARM64,"assets/empty.bin"))
}
REMOTE_COLLECTOR_WINDOWS_AMD64 :: #load(#config(TASK_MASTER_COLLECTOR_WINDOWS_AMD64,"assets/empty.bin"))
REMOTE_COLLECTOR_WINDOWS_ARM64 :: #load(#config(TASK_MASTER_COLLECTOR_WINDOWS_ARM64,"assets/empty.bin"))

when ODIN_OS==.Linux&&ODIN_ARCH==.riscv64 {
    REMOTE_COLLECTOR_LINUX_RISCV64 :: #load(#config(TASK_MASTER_COLLECTOR_LINUX_RISCV64,"build/task_master-collector"))
} else {
    REMOTE_COLLECTOR_LINUX_RISCV64 :: #load(#config(TASK_MASTER_COLLECTOR_LINUX_RISCV64,"assets/empty.bin"))
}
when ODIN_OS==.Darwin&&ODIN_ARCH==.amd64 {
    REMOTE_COLLECTOR_DARWIN_AMD64 :: #load(#config(TASK_MASTER_COLLECTOR_DARWIN_AMD64,"build/task_master-collector"))
} else {
    REMOTE_COLLECTOR_DARWIN_AMD64 :: #load(#config(TASK_MASTER_COLLECTOR_DARWIN_AMD64,"assets/empty.bin"))
}
when ODIN_OS==.Darwin&&ODIN_ARCH==.arm64 {
    REMOTE_COLLECTOR_DARWIN_ARM64 :: #load(#config(TASK_MASTER_COLLECTOR_DARWIN_ARM64,"build/task_master-collector"))
} else {
    REMOTE_COLLECTOR_DARWIN_ARM64 :: #load(#config(TASK_MASTER_COLLECTOR_DARWIN_ARM64,"assets/empty.bin"))
}
remote_payload_darwin_amd64:=REMOTE_COLLECTOR_DARWIN_AMD64
remote_payload_darwin_arm64:=REMOTE_COLLECTOR_DARWIN_ARM64
remote_payload_linux_riscv64:=REMOTE_COLLECTOR_LINUX_RISCV64
remote_payload_linux_amd64:=REMOTE_COLLECTOR_LINUX_AMD64
remote_payload_linux_arm64:=REMOTE_COLLECTOR_LINUX_ARM64
remote_payload_windows_amd64:=REMOTE_COLLECTOR_WINDOWS_AMD64
remote_payload_windows_arm64:=REMOTE_COLLECTOR_WINDOWS_ARM64

Remote_Platform :: enum {Unknown,Linux,Windows,Darwin}

remote_collector_payload :: proc(platform:Remote_Platform,architecture:string)->[]u8 {
    #partial switch platform {
    case .Linux:
        switch architecture {
        case "x86_64","amd64":return remote_payload_linux_amd64
        case "aarch64","arm64":return remote_payload_linux_arm64
        case "riscv64":return remote_payload_linux_riscv64
        }
    case .Darwin:
        switch architecture {
        case "x86_64","amd64":return remote_payload_darwin_amd64
        case "aarch64","arm64":return remote_payload_darwin_arm64
        }
    case .Windows:
        switch architecture {
        case "AMD64","amd64","X64":return remote_payload_windows_amd64
        case "ARM64","arm64","Arm64":return remote_payload_windows_arm64
        }
    }
    return nil
}

remote_powershell_command :: proc(script:string)->string {
    // OpenSSH may launch cmd.exe or PowerShell. EncodedCommand is independent
    // of either shell's quoting and preserves Unicode user/custom paths.
    utf16:=make([dynamic]u8,0,len(script)*2,context.temp_allocator)
    for ch in script {
        if ch<=0xffff {append(&utf16,u8(ch&255),u8((ch>>8)&255))}
        else {
            code:=u32(ch)-0x10000
            high,low:=u16(0xd800|(code>>10)),u16(0xdc00|(code&1023))
            append(&utf16,u8(high&255),u8(high>>8),u8(low&255),u8(low>>8))
        }
    }
    encoded:=base64.encode(utf16[:],allocator=context.temp_allocator)
    return fmt.aprintf("powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand %s",encoded)
}

remote_windows_collector_command :: proc(collector:string)->string {
    escaped,_:=strings.replace_all(collector,"'","''",context.temp_allocator)
    return remote_powershell_command(fmt.tprintf(`$ErrorActionPreference='Stop'; $path='%s'; if ($path.StartsWith('~/') -or $path.StartsWith('~\')) {$path=Join-Path $HOME $path.Substring(2)}; $process=Start-Process -FilePath $path -NoNewWindow -Wait -PassThru; exit $process.ExitCode`,escaped))
}

remote_collector_bootstrap_command :: proc(platform:Remote_Platform,architecture:string,binary_bytes:int,arguments:string="")->string {
    command:string
    if platform==.Windows {
        command=`$ErrorActionPreference='Stop'
$inputStream=[Console]::OpenStandardInput()
$remaining=[Int64]@TASK_MASTER_BYTES@
$buffer=New-Object byte[] 65536
$installed=$null
$useInstalled=$false
foreach ($candidate in @((Join-Path $env:ProgramFiles 'task_master\task_master-collector.exe'),(Join-Path $env:LOCALAPPDATA 'task_master\task_master-collector.exe'))) {
    if ((Test-Path -LiteralPath $candidate) -and ((& $candidate --protocol-version 2>$null) -eq '@TASK_MASTER_PROTOCOL@')) {
        $installed=$candidate;$useInstalled=$true;break
    }
}
$directory=$null
$output=$null
try {
    if (-not $useInstalled) {
        if ($remaining -le 0) {throw 'No compatible installed collector or embedded payload is available. Use Install / fix with a complete release build.'}
        $directory=Join-Path ([IO.Path]::GetTempPath()) ('task_master-'+[Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($directory) > $null
        # A session executable must never inherit writable access for other users.
        $acl=New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true,$false)
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule=New-Object System.Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $directory -AclObject $acl
        $installed=Join-Path $directory 'collector.exe'
        $output=[IO.File]::Open($installed,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    }
    while ($remaining -gt 0) {
        $count=$inputStream.Read($buffer,0,[Math]::Min($buffer.Length,$remaining))
        if ($count -le 0) {throw 'task_master collector transfer was interrupted.'}
        if ($output) {$output.Write($buffer,0,$count)}
        $remaining-=$count
    }
    if ($output) {$output.Dispose();$output=$null}
    # Native processes inherit the same unbuffered stdin handle after the exact
    # transfer. EOF continues to terminate the collector on SSH disconnect.
    $process=Start-Process -FilePath $installed -NoNewWindow -Wait -PassThru
    exit $process.ExitCode
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
} finally {
    if ($output) {$output.Dispose()}
    if ($directory) {Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue}
}
`
    } else {
        command=`set -eu
if [ "$(uname -s)" != '@TASK_MASTER_OS@' ] || [ "$(uname -m)" != '@TASK_MASTER_ARCH@' ]; then
    echo 'task_master collector does not match the remote OS or architecture.' >&2
    exit 1
fi
@TASK_MASTER_RECEIVER_INIT@
installed=
@TASK_MASTER_INSTALLED@
if [ -n "$installed" ]; then
    received=$(@TASK_MASTER_RECEIVE@ | wc -c)
    if [ "$received" -ne @TASK_MASTER_BYTES@ ]; then
        echo 'task_master collector transfer was interrupted.' >&2
        exit 1
    fi
    exec "$installed" @TASK_MASTER_ARGUMENTS@
fi
if [ @TASK_MASTER_BYTES@ -eq 0 ]; then
    echo 'No compatible installed collector or embedded payload is available.' >&2
    exit 1
fi
umask 077
base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
directory=$(mktemp -d "$base/task_master-XXXXXX")
trap 'rm -rf "$directory"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
@TASK_MASTER_RECEIVE@ > "$directory/collector"
if [ "$(wc -c < "$directory/collector")" -ne @TASK_MASTER_BYTES@ ]; then
    echo 'task_master collector transfer was interrupted.' >&2
    exit 1
fi
chmod 700 "$directory/collector"
"$directory/collector" @TASK_MASTER_ARGUMENTS@
`
    }
    // Darwin supports both system and user app installs. Shell-quoted paths
    // allow names containing spaces without changing custom collector behavior.
    installed_candidates:=`for candidate in /usr/libexec/task_master/collector /usr/local/libexec/task_master/collector "$HOME/.local/bin/task_master-collector"; do
    if [ -x "$candidate" ] && [ "$("$candidate" --protocol-version 2>/dev/null)" = '@TASK_MASTER_PROTOCOL@' ]; then
        installed=$candidate; break
    fi
done`
    if platform==.Darwin {
        installed_candidates=`for candidate in '/Applications/task_master.app/Contents/MacOS/task_master-collector' "$HOME/Applications/task_master.app/Contents/MacOS/task_master-collector" '/Applications/task_master.app/Contents/Helpers/task_master-collector' "$HOME/Applications/task_master.app/Contents/Helpers/task_master-collector" /usr/local/libexec/task_master/collector "$HOME/.local/bin/task_master-collector"; do
    if [ -x "$candidate" ] && [ "$("$candidate" --protocol-version 2>/dev/null)" = '@TASK_MASTER_PROTOCOL@' ]; then
        installed=$candidate; break
    fi
done`
    }
    receiver_init:=""
    receive:="head -c @TASK_MASTER_BYTES@"
    if platform==.Darwin {
        // Apple's head uses buffered fread and may consume the following PID
        // list/control command. Raw dd fullblock reads preserve the boundary.
        // Probe its option without consuming the SSH input; old releases retain
        // a correct byte-wise fallback rather than dropping a process action.
        receiver_init=`task_master_fullblock=0
if dd iflag=fullblock count=0 </dev/null >/dev/null 2>&1; then task_master_fullblock=1; fi
task_master_receive() {
    if [ @TASK_MASTER_BYTES@ -eq 0 ]; then return; fi
    if [ "$task_master_fullblock" -eq 1 ]; then
        blocks=$((@TASK_MASTER_BYTES@ / 65536))
        tail=$((@TASK_MASTER_BYTES@ % 65536))
        if [ "$blocks" -gt 0 ]; then dd iflag=fullblock bs=65536 count="$blocks" 2>/dev/null; fi
        if [ "$tail" -gt 0 ]; then dd iflag=fullblock bs="$tail" count=1 2>/dev/null; fi
    else
        dd bs=1 obs=65536 count=@TASK_MASTER_BYTES@ 2>/dev/null
    fi
}`
        receive="task_master_receive"
    }
    command,_=strings.replace_all(command,"@TASK_MASTER_RECEIVER_INIT@",receiver_init,context.temp_allocator)
    command,_=strings.replace_all(command,"@TASK_MASTER_RECEIVE@",receive,context.temp_allocator)
    command,_=strings.replace_all(command,"@TASK_MASTER_INSTALLED@",installed_candidates,context.temp_allocator)
    command,_=strings.replace_all(command,"@TASK_MASTER_OS@","Darwin" if platform==.Darwin else "Linux",context.temp_allocator)
    command,_=strings.replace_all(command,"@TASK_MASTER_ARGUMENTS@",arguments,context.temp_allocator)
    command,_=strings.replace_all(command,"@TASK_MASTER_ARCH@",architecture,context.temp_allocator)
    command,_=strings.replace_all(command,"@TASK_MASTER_BYTES@",fmt.tprintf("%d",binary_bytes),context.temp_allocator)
    command,_=strings.replace_all(command,"@TASK_MASTER_PROTOCOL@",fmt.tprintf("%d",REMOTE_PROTOCOL_VERSION),context.temp_allocator)
    if platform==.Windows {return remote_powershell_command(command)}
    return strings.clone(command)
}

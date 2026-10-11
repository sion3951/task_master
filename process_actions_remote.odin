package main

import "core:fmt"
import "core:strings"

process_kill_windows_command :: proc()->string {
    script:=`$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class task_masterKill {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetProcessTimes(IntPtr handle, out long created, out long exited, out long kernel, out long user);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr handle, uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
}
'@
$failed=$false
while ($null -ne ($line=[Console]::In.ReadLine())) {
    $parts=$line.Split(' ')
    $handle=[IntPtr]::Zero
    try {
    [uint32]$targetPid=$parts[0]
    [long]$expected=$parts[1]
    if ($targetPid -eq 0 -or $expected -eq 0) {throw 'Process identity is unavailable.'}
    $handle=[task_masterKill]::OpenProcess(0x1001,$false,$targetPid)
    if ($handle -eq [IntPtr]::Zero) {throw 'Could not open PID; it may be protected or have exited.'}
    [long]$created=0; [long]$exited=0; [long]$kernel=0; [long]$user=0
    if (-not [task_masterKill]::GetProcessTimes($handle,[ref]$created,[ref]$exited,[ref]$kernel,[ref]$user)) {throw 'Could not check process identity.'}
    if ($created -ne $expected) {throw 'PID exited or changed; select its current row.'}
    if (-not [task_masterKill]::TerminateProcess($handle,1)) {throw 'Could not kill the selected PID; access was denied or it exited.'}
    } catch {
        [Console]::Error.WriteLine(('PID {0}: {1}' -f $parts[0],$_.Exception.Message))
        $failed=$true
    } finally {if ($handle -ne [IntPtr]::Zero) {[void][task_masterKill]::CloseHandle($handle)}}
}
if ($failed) {exit 1}
`
    return remote_powershell_command(script)
}

// The binary precedes the PID list on stdin, keeping the SSH command short even
// for a large collector or process group. Bootstrap consumes exactly its bytes.
process_kill_darwin_command :: proc(architecture:string,action:^Process_Kill_Action)->(command:string,binary:[]u8,error:string) {
    collector:=action.collector
    if collector!=""&&collector!=DEFAULT_COLLECTOR {
        custom:=remote_collector_command(collector)
        defer delete(custom)
        return fmt.aprintf("%s --kill-pids",custom),nil,""
    }
    binary=remote_collector_payload(.Darwin,architecture)
    if len(binary)==0 {
        probe:=Remote_Connection{host=action.host,port=action.port}
        probe_command:=remote_collector_bootstrap_command(.Darwin,architecture,0,"--protocol-version")
        installed,diagnostic,ok:=remote_query(&probe,probe_command)
        delete(probe_command)
        defer {delete(installed);delete(diagnostic)}
        if !ok||installed!=fmt.tprintf("%d",REMOTE_PROTOCOL_VERSION) {
            if remote_ssh_access_failure(diagnostic) {return "",nil,strings.clone(diagnostic,context.temp_allocator)}
            payload,fetch_error:=remote_helper_collector(.Darwin,architecture,&action.stop)
            if fetch_error!="" {return "",nil,fetch_error}
            defer delete(payload)
            // Process actions build their outgoing stream in the worker's
            // temporary arena; keep the fetched bytes in that same lifetime.
            binary=make([]u8,len(payload),context.temp_allocator)
            copy(binary,payload)
        }
    }
    command=remote_collector_bootstrap_command(.Darwin,architecture,len(binary),"--kill-pids")
    return
}

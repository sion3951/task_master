package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "core:path/filepath"

REMOTE_WINDOWS_SENSORS :: #load(#config(TASK_MASTER_WINDOWS_SENSORS,"assets/empty.bin"))

Machine_Terminal_Job :: struct {
    process: os.Process,
    started: bool,
    directory, host: string,
    port: u16,
    install, reported: bool,
}

machine_shell_quote :: proc(value:string)->string {
    escaped,_:=strings.replace_all(value,"'","'\"'\"'",context.temp_allocator)
    return fmt.tprintf("'%s'",escaped)
}
machine_powershell_quote :: proc(value:string)->string {
    escaped,_:=strings.replace_all(value,"'","''",context.temp_allocator)
    return fmt.tprintf("'%s'",escaped)
}
machine_terminal_busy :: proc(a:^App,m:^Machine)->bool {
    for job in a.machine_terminal_jobs {
        if job.install&&!job.reported&&job.host==string(m.host[:m.host_len])&&job.port==m.port {return true}
    }
    return false
}
machine_terminal_open :: proc(a:^App,m:^Machine,install:bool=false) {
    if install&&machine_terminal_busy(a,m) {return}
    directory,error:=os.make_directory_temp("","task_master-setup-*",context.allocator)
    if error!=nil {machine_error_set(a,fmt.tprintf("Could not prepare terminal: %v",error));return}
    success:=false
    defer {if !success {_=os.remove_all(directory);delete(directory)}}
    if os.chmod(directory,{.Read_User,.Write_User,.Execute_User})!=nil||!platform_private_path(directory,true) {machine_error_set(a,"Could not protect installation staging directory.");return}
    files:=[]struct{name:string,data:[]u8}{
        {"install-system.sh",#load("scripts/install-system.sh")},
        {"install-remote-unix.sh",#load("scripts/install-remote-unix.sh")},
        {"task_master-sensors.sh",#load("sensors/macos/task_master-sensors.sh")},
        {"sensors.plist",#load("sensors/macos/sensors.plist")},
        {"install-remote-windows.ps1",#load("scripts/install-remote-windows.ps1")},
        {"install-sensors.ps1",#load("scripts/install-sensors.ps1")},
        {"sensors.zip",REMOTE_WINDOWS_SENSORS},
        {"collector-linux-amd64",remote_payload_linux_amd64},
        {"collector-linux-arm64",remote_payload_linux_arm64},
        {"collector-linux-riscv64",remote_payload_linux_riscv64},
        {"collector-darwin-amd64",remote_payload_darwin_amd64},
        {"collector-darwin-arm64",remote_payload_darwin_arm64},
        {"collector-windows-amd64",remote_payload_windows_amd64},
        {"collector-windows-arm64",remote_payload_windows_arm64},
    }
    if install {
        for file in files {
            if len(file.data)==0 {continue}
            if os.write_entire_file(fmt.tprintf("%s/%s",directory,file.name),file.data,{.Read_User,.Write_User})!=nil {machine_error_set(a,"Could not stage installation files.");return}
        }
    }
    name:=filepath.base(directory)
    remote_stage:=fmt.tprintf("$path=Join-Path $HOME '%s'; New-Item -ItemType Directory -Path $path -ErrorAction Stop > $null; $acl=New-Object System.Security.AccessControl.DirectorySecurity; $acl.SetAccessRuleProtection($true,$false); $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User; $rule=New-Object System.Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'); $acl.AddAccessRule($rule); Set-Acl -LiteralPath $path -AclObject $acl -ErrorAction Stop; [Console]::WriteLine($path.Replace('\\','/'))",name)
    remote_install:=fmt.tprintf("$path=Join-Path $HOME '%s'; & (Join-Path $path 'install-remote-windows.ps1'); if (-not $?) {exit 1}",name)
    remote_cleanup:=fmt.tprintf("Remove-Item -LiteralPath (Join-Path $HOME '%s') -Recurse -Force -ErrorAction Stop",name)
    windows_probe:=remote_powershell_command(`if ([Environment]::OSVersion.Platform -ne 'Win32NT') {exit 1}; $arch=$env:PROCESSOR_ARCHITEW6432; if (-not $arch) {$arch=$env:PROCESSOR_ARCHITECTURE}; [Console]::WriteLine('task_master-windows-'+$arch)`)
    windows_stage:=remote_powershell_command(remote_stage)
    windows_install:=remote_powershell_command(remote_install)
    windows_cleanup:=remote_powershell_command(remote_cleanup)
    defer {delete(windows_probe);delete(windows_stage);delete(windows_install);delete(windows_cleanup)}
    script:string
    when ODIN_OS==.Windows {script=string(#load("scripts/remote-setup.ps1"))}
    else {script=string(#load("scripts/remote-setup.sh"))}
    quote:=machine_shell_quote
    when ODIN_OS==.Windows {quote=machine_powershell_quote}
    replacements:=[][2]string{
        {"@STAGE@",quote(directory)}, {"@HOST@",quote(string(m.host[:m.host_len]))},
        {"@PORT@",fmt.tprintf("%d",m.port)},
        {"@WINDOWS_PROBE@",quote(windows_probe)}, {"@WINDOWS_STAGE@",quote(windows_stage)},
        {"@WINDOWS_INSTALL@",quote(windows_install)}, {"@WINDOWS_CLEANUP@",quote(windows_cleanup)},
    }
    for replacement in replacements {script,_=strings.replace_all(script,replacement[0],replacement[1],context.temp_allocator)}
    install_literal:="true" if install else "false"
    when ODIN_OS==.Windows {install_literal="$true" if install else "$false"}
    script,_=strings.replace_all(script,"@INSTALL@",install_literal,context.temp_allocator)
    extension:="sh"
    when ODIN_OS==.Windows {extension="ps1"}
    script_path:=fmt.tprintf("%s/launch.%s",directory,extension)
    if os.write_entire_file(script_path,transmute([]u8)script,{.Read_User,.Write_User})!=nil {machine_error_set(a,"Could not write terminal launcher.");return}
    sync.mutex_lock(&remote_spawn_mutex)
    process,launch_error:=machine_platform_terminal(script_path)
    sync.mutex_unlock(&remote_spawn_mutex)
    if launch_error!=nil {machine_error_set(a,fmt.tprintf("Could not open a terminal: %v. Install a terminal application and retry.",launch_error));return}
    append(&a.machine_terminal_jobs,Machine_Terminal_Job{process=process,started=true,directory=directory,host=strings.clone(string(m.host[:m.host_len])),port=m.port,install=install})
    success=true
    if install {m.setup_failed=false}
    machine_error_set(a,"Terminal opened. Complete setup there; task_master will reconnect afterwards." if install else "SSH terminal opened.")
}
machine_terminal_poll :: proc(a:^App) {
    for i:=len(a.machine_terminal_jobs)-1;i>=0;i-=1 {
        job:=&a.machine_terminal_jobs[i]
        state:os.Process_State
        wait_error:os.Error
        if job.started {
            state,wait_error=os.process_wait(job.process,0)
            if wait_error!=.Timeout {job.started=false}
        }
        result,error:=os.read_entire_file(fmt.tprintf("%s/result",job.directory),context.temp_allocator)
        if !job.reported&&error==nil {
            job.reported=true
            if strings.trim_space(string(result))=="0" {
                if job.install {machine_setup_reconnect(a,job.host,job.port)}
                else {machine_error_set(a,"SSH terminal session finished.")}
            } else {machine_error_set(a,"Setup failed. Read the terminal output, then retry Install / fix.")}
        }
        _,stat_error:=os.stat(job.directory,context.temp_allocator)
        if !job.reported&&stat_error!=nil {
            job.reported=true
            // Closing the terminal can remove its result before the GUI reads
            // it. Reconnect and verify instead of guessing installation success.
            if job.install {machine_setup_reconnect(a,job.host,job.port)}
            else {machine_error_set(a,"SSH terminal closed.")}
        }
        if !job.started&&(stat_error!=nil||(wait_error==nil&&state.exit_code!=0)) {
            if !job.reported&&state.exit_code!=0 {machine_error_set(a,"Terminal closed before setup finished. Retry Install / fix.")}
            _=os.remove_all(job.directory)
            delete(job.directory);delete(job.host)
            ordered_remove(&a.machine_terminal_jobs,i)
            a.dirty=true
        }
    }
    machine_setup_poll(a)
}
machine_setup_reconnect :: proc(a:^App,host:string,port:u16) {
    index:=machine_find(a,host,port)
    if index<0 {machine_error_set(a,"Machine was removed before setup could be verified.");return}
    m:=a.machines[index]
    m.setup_verifying=true;m.setup_failed=false
    m.setup_started=time.tick_now();m.setup_check_after=m.setup_started
    if m.connection!=nil {remote_connection_destroy(m.connection);m.connection=nil}
    machine_connect(a,m)
    if a.persistence_enabled&&m.persistent {persistence_reconnect(a)}
    machine_error_set(a,"Installer finished. Reconnecting and checking fresh telemetry...")
}
machine_setup_poll :: proc(a:^App) {
    for m in a.machines {
        if !m.setup_verifying {continue}
        waiting:=a.persistence_enabled&&m.persistent&&(a.persistence_reconnect_pending||a.persistence_change!=nil)
        fresh:=time.tick_since(m.received)<time.tick_since(m.setup_check_after)
        if !waiting&&fresh&&!machine_stale(a,m)&&m.status==.Live {
            m.setup_verifying=false
            if m.state!=nil&&m.state.metrics.cpu_power_permission_denied {
                m.setup_failed=true
                machine_error_set(a,fmt.tprintf("%s: telemetry connected, but power access is still denied.",string(m.name[:m.name_len])))
            } else {machine_error_set(a,fmt.tprintf("Verified: %s is receiving telemetry.",string(m.name[:m.name_len])))}
            a.dirty=true
        } else if time.tick_since(m.setup_started)>45*time.Second {
            m.setup_verifying=false;m.setup_failed=true
            machine_error_set(a,fmt.tprintf("%s: setup did not restore telemetry. %s",string(m.name[:m.name_len]),machine_status_message(m)))
        }
    }
}
machine_terminal_destroy :: proc(a:^App) {
    // User-opened terminals own their scripts and clean staging when they close.
    for job in a.machine_terminal_jobs {
        if job.started {machine_platform_terminal_release(job.process)}
        delete(job.directory);delete(job.host)
    }
    delete(a.machine_terminal_jobs)
}

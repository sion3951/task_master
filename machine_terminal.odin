package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "core:path/filepath"

Machine_Terminal_Job :: struct {
    process: os.Process,
    started: bool,
    directory, host: string,
    port: u16,
    install, reported: bool,
    progress: [256]u8, progress_len: int,
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
machine_terminal_progress :: proc(a:^App,m:^Machine)->string {
    for &job in a.machine_terminal_jobs {
        if job.install&&!job.reported&&job.host==string(m.host[:m.host_len])&&job.port==m.port {
            if job.progress_len>0 {return string(job.progress[:job.progress_len])}
            return "Step 1/6: Open setup terminal"
        }
    }
    return "Setup terminal open"
}
machine_terminal_failed :: proc(a:^App,job:^Machine_Terminal_Job,message:string) {
    index:=machine_find(a,job.host,job.port)
    if job.install&&index>=0 {
        m:=a.machines[index]
        m.setup_verifying=false;m.setup_failed=true
        m.setup_message_len=copy(m.setup_message[:],message)
        m.message_len=copy(m.message[:],message)
    }
    machine_error_set(a,message)
    a.dirty=true
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
    remote_install:=fmt.tprintf("$ErrorActionPreference='Stop'; $path=Join-Path $HOME '%s'; & (Join-Path $path 'install-remote-windows.ps1') -ExpectedProtocol %d; if (-not $?) {exit 1}",name,REMOTE_PROTOCOL_VERSION)
    remote_cleanup:=fmt.tprintf("Remove-Item -LiteralPath (Join-Path $HOME '%s') -Recurse -Force -ErrorAction Stop",name)
    windows_probe:=remote_powershell_command(`if ([Environment]::OSVersion.Platform -ne 'Win32NT') {exit 1}; $arch=$env:PROCESSOR_ARCHITEW6432; if (-not $arch) {$arch=$env:PROCESSOR_ARCHITECTURE}; [Console]::WriteLine('task_master-windows-'+$arch)`)
    windows_stage:=remote_powershell_command(remote_stage)
    windows_install:=remote_powershell_command(remote_install)
    windows_cleanup:=remote_powershell_command(remote_cleanup)
    windows_validate:=remote_powershell_command(fmt.tprintf("$ErrorActionPreference='Stop'; $path=Join-Path (Join-Path $HOME '%s') 'collector.exe'; $actual=& $path --protocol-version; if ($LASTEXITCODE -ne 0 -or [string]$actual -ne '%d') {throw 'Collector protocol mismatch. Use a complete matching release build.'}",name,REMOTE_PROTOCOL_VERSION))
    defer {delete(windows_probe);delete(windows_stage);delete(windows_install);delete(windows_cleanup);delete(windows_validate)}
    script:string
    when ODIN_OS==.Windows {script=string(#load("scripts/remote-setup.ps1"))}
    else {script=string(#load("scripts/remote-setup.sh"))}
    quote:=machine_shell_quote
    when ODIN_OS==.Windows {quote=machine_powershell_quote}
    executable,executable_error:=os.get_executable_path(context.temp_allocator)
    if executable_error!=nil {machine_error_set(a,"Could not locate task_master for remote helper preparation.");return}
    replacements:=[][2]string{
        {"@STAGE@",quote(directory)}, {"@HOST@",quote(string(m.host[:m.host_len]))},
        {"@HELPER@",quote(executable)},
        {"@PORT@",fmt.tprintf("%d",m.port)}, {"@PROTOCOL@",fmt.tprintf("%d",REMOTE_PROTOCOL_VERSION)},
        {"@WINDOWS_PROBE@",quote(windows_probe)}, {"@WINDOWS_STAGE@",quote(windows_stage)},
        {"@WINDOWS_INSTALL@",quote(windows_install)}, {"@WINDOWS_VALIDATE@",quote(windows_validate)}, {"@WINDOWS_CLEANUP@",quote(windows_cleanup)},
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
    if install {m.setup_failed=false;m.setup_verifying=false;m.setup_message_len=0}
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
        if !job.reported {
            progress,error:=os.read_entire_file(fmt.tprintf("%s/progress",job.directory),context.temp_allocator)
            if error==nil {
                value:=strings.trim_space(string(progress))
                if value!=string(job.progress[:job.progress_len]) {
                    job.progress_len=copy(job.progress[:],value)
                    a.dirty=true
                }
            }
        }
        result,error:=os.read_entire_file(fmt.tprintf("%s/result",job.directory),context.temp_allocator)
        if !job.reported&&error==nil {
            job.reported=true
            _=os.write_entire_file(fmt.tprintf("%s/acknowledged",job.directory),[]u8{1},{.Read_User,.Write_User})
            if strings.trim_space(string(result))=="0" {
                if job.install {machine_setup_reconnect(a,job.host,job.port)}
                else {machine_error_set(a,"SSH terminal session finished.")}
            } else {machine_terminal_failed(a,job,fmt.tprintf("%s failed. Read the terminal output, then retry Setup / fix.",string(job.progress[:job.progress_len])))}
        }
        _,stat_error:=os.stat(job.directory,context.temp_allocator)
        if !job.reported&&stat_error!=nil {
            job.reported=true
            // A missing result is not an installation success. The terminal
            // normally waits for our acknowledgement before removing staging.
            if job.install {machine_terminal_failed(a,job,"Setup terminal closed without a completion result. Retry Setup / fix.")}
            else {machine_error_set(a,"SSH terminal closed.")}
        }
        if !job.started&&(stat_error!=nil||(wait_error==nil&&state.exit_code!=0)) {
            if !job.reported&&state.exit_code!=0 {machine_terminal_failed(a,job,fmt.tprintf("Setup terminal exited with code %d before completion. Retry Setup / fix.",state.exit_code))}
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
    m.setup_verifying=true;m.setup_failed=false;m.setup_message_len=0
    m.setup_previous_session=m.state.metrics.remote_session_id if m.state!=nil else 0
    a.dirty=true
    m.setup_started=time.tick_now();m.setup_check_after=m.setup_started
    if m.connection!=nil {remote_connection_destroy(m.connection);m.connection=nil}
    machine_connect(a,m)
    if a.persistence_enabled&&m.persistent&&!persistence_request_retry(m) {
        m.setup_verifying=false;m.setup_failed=true
        message:="Installation finished, but the monitoring service could not receive the retry request. Retry the connection."
        m.setup_message_len=copy(m.setup_message[:],message)
        machine_error_set(a,message)
        return
    }
    machine_error_set(a,"Installer finished. Reconnecting and checking fresh telemetry...")
}
machine_setup_poll :: proc(a:^App) {
    for m in a.machines {
        if !m.setup_verifying {continue}
        waiting:=a.persistence_enabled&&m.persistent&&(a.persistence_reconnect_pending||a.persistence_change!=nil)
        fresh:=time.tick_since(m.received)<time.tick_since(m.setup_check_after)
        // The persistence worker can publish another sample from the previous
        // session before consuming its retry request. Verify the new session.
        fresh=fresh&&m.state!=nil&&m.state.metrics.remote_session_id!=0&&m.state.metrics.remote_session_id!=m.setup_previous_session
        if !waiting&&fresh&&!machine_stale(a,m)&&m.status==.Live {
            m.setup_verifying=false
            if m.state!=nil&&string(m.state.metrics.remote_mode[:m.state.metrics.remote_mode_len])=="temporary" {
                m.setup_failed=true
                machine_error_set(a,fmt.tprintf("%s: fresh telemetry is available, but the durable collector was not selected. Check collector compatibility, then retry Setup / fix.",string(m.name[:m.name_len])))
            } else if m.state!=nil&&m.state.metrics.cpu_power_permission_denied {
                m.setup_failed=true
                machine_error_set(a,fmt.tprintf("%s: telemetry connected, but power access is still denied.",string(m.name[:m.name_len])))
            } else {machine_error_set(a,fmt.tprintf("Verified: %s is receiving telemetry.",string(m.name[:m.name_len])))}
            a.dirty=true
        } else if time.tick_since(m.setup_started)>45*time.Second {
            m.setup_verifying=false;m.setup_failed=true
            machine_error_set(a,fmt.tprintf("%s: setup did not restore telemetry. %s",string(m.name[:m.name_len]),machine_status_message(m)))
        }
        if m.setup_failed {m.setup_message_len=copy(m.setup_message[:],string(a.machine_error[:a.machine_error_len]))}
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

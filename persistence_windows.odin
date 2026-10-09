#+build windows
package main

import "core:encoding/base64"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"
import "core:time"

foreign import persistence_kernel32 "system:kernel32.lib"
foreign import persistence_advapi32 "system:advapi32.lib"
@(default_calling_convention="system")
foreign persistence_kernel32 {
    @(link_name="OpenEventW")
    persistence_OpenEventW :: proc(access:win32.DWORD,inherit:win32.BOOL,name:win32.LPCWSTR)->win32.HANDLE ---
    @(link_name="CreateMutexW")
    persistence_CreateMutexW :: proc(attributes:^win32.SECURITY_ATTRIBUTES,owner:win32.BOOL,name:win32.LPCWSTR)->win32.HANDLE ---
    @(link_name="OpenMutexW")
    persistence_OpenMutexW :: proc(access:win32.DWORD,inherit:win32.BOOL,name:win32.LPCWSTR)->win32.HANDLE ---
}
@(default_calling_convention="system")
foreign persistence_advapi32 {
    @(link_name="ConvertSidToStringSidW")
    persistence_ConvertSidToStringSidW :: proc(sid:rawptr,text:^win32.LPWSTR)->win32.BOOL ---
    @(link_name="ConvertStringSecurityDescriptorToSecurityDescriptorW")
    persistence_ConvertStringSecurityDescriptorToSecurityDescriptorW :: proc(text:win32.LPCWSTR,revision:win32.DWORD,descriptor:^rawptr,size:^win32.DWORD)->win32.BOOL ---
    @(link_name="SetFileSecurityW")
    persistence_SetFileSecurityW :: proc(path:win32.LPCWSTR,information:win32.DWORD,descriptor:rawptr)->win32.BOOL ---
}

// Scope task ownership, files and control objects to the actual Windows account,
// including domain users and Unicode names. No administrative token is requested.
persistence_windows_sid :: proc()->string {
    token:win32.HANDLE
    if !win32.OpenProcessToken(win32.GetCurrentProcess(),win32.TOKEN_QUERY,&token) {return ""}
    defer win32.CloseHandle(token)
    size:win32.DWORD
    _=win32.GetTokenInformation(token,.TokenUser,nil,0,&size)
    if size==0 {return ""}
    buffer:=make([]u8,int(size),context.temp_allocator)
    if !win32.GetTokenInformation(token,.TokenUser,raw_data(buffer),size,&size) {return ""}
    user:=(^win32.TOKEN_USER)(raw_data(buffer))
    sid:win32.LPWSTR
    if !persistence_ConvertSidToStringSidW(user.User.Sid,&sid) {return ""}
    defer win32.LocalFree(sid)
    return win32.wstring_to_utf8(win32.wstring(sid)) or_else ""
}
persistence_windows_security :: proc(directory:bool=false)->rawptr {
    sid:=persistence_windows_sid()
    if sid=="" {return nil}
    inherit:="OICI" if directory else ""
    sddl:=fmt.tprintf("D:P(A;%s;FA;;;SY)(A;%s;FA;;;%s)",inherit,inherit,sid)
    descriptor:rawptr
    if !persistence_ConvertStringSecurityDescriptorToSecurityDescriptorW(win32.utf8_to_wstring(sddl),1,&descriptor,nil) {return nil}
    return descriptor
}
platform_private_path :: proc(path:string,directory:bool)->bool {
    descriptor:=persistence_windows_security(directory)
    if descriptor==nil {return false}
    defer win32.LocalFree(descriptor)
    // Protected DACL: only this user and SYSTEM, with inherited private child
    // permissions on directories. os.Permissions alone has no Windows ACL effect.
    return bool(persistence_SetFileSecurityW(win32.utf8_to_wstring(path),0x80000004,descriptor))
}
platform_atomic_replace :: proc(source,destination:string)->bool {
    source_w:=win32.utf8_to_wstring(source)
    destination_w:=win32.utf8_to_wstring(destination)
    // A Windows stat/antivirus handle can briefly deny renaming. Readers use
    // FILE_SHARE_DELETE; bounded retries cover short third-party/stat handles.
    for _ in 0..<8 {
        if win32.MoveFileExW(source_w,destination_w,win32.MOVEFILE_REPLACE_EXISTING|win32.MOVEFILE_WRITE_THROUGH) {return true}
        error:=win32.GetLastError()
        if error!=win32.ERROR_SHARING_VIOLATION&&error!=win32.ERROR_ACCESS_DENIED {return false}
        time.sleep(10*time.Millisecond)
    }
    return false
}
persistence_platform_cache_open :: proc(path:string)->(^os.File,os.Error) {
    handle:=win32.CreateFileW(win32.utf8_to_wstring(path),win32.GENERIC_READ,win32.FILE_SHARE_READ|win32.FILE_SHARE_WRITE|win32.FILE_SHARE_DELETE,nil,win32.OPEN_EXISTING,win32.FILE_ATTRIBUTE_NORMAL,nil)
    if handle==win32.INVALID_HANDLE {return nil,os.Platform_Error(win32.GetLastError())}
    file:=os.new_file(uintptr(handle),path)
    if file==nil {win32.CloseHandle(handle);return nil,.Invalid_File}
    return file,nil
}
persistence_windows_object_name :: proc(kind:string)->string {return fmt.tprintf("Global\\task_master.Persistence.%s.%s",kind,persistence_windows_sid())}
persistence_windows_task_name :: proc()->string {return fmt.tprintf("task_master-Persistence-%s",persistence_windows_sid())}
persistence_windows_ps_quote :: proc(value:string)->string {
    escaped,_:=strings.replace_all(value,"'","''",context.temp_allocator)
    return fmt.tprintf("'%s'",escaped)
}
persistence_windows_xml_quote :: proc(value:string)->string {
    builder:=strings.builder_make(context.temp_allocator)
    for c in value {
        switch c {
        case '&':strings.write_string(&builder,"&amp;")
        case '<':strings.write_string(&builder,"&lt;")
        case '>':strings.write_string(&builder,"&gt;")
        case '"':strings.write_string(&builder,"&quot;")
        case '\'':strings.write_string(&builder,"&apos;")
        case:strings.write_rune(&builder,c)
        }
    }
    return strings.to_string(builder)
}

// PowerShell is an inbox Windows component. Invoke it without a console and
// capture output in a temporary file so diagnostics cannot block on a pipe.
persistence_windows_command :: proc(command:string)->(success:bool,output:string) {
    capture,error:=os.create_temp_file("","task_master-scheduler-*")
    if error!=nil {return false,fmt.tprintf("Could not capture Task Scheduler output: %v",error)}
    capture_path:=strings.clone(os.name(capture),context.temp_allocator)
    defer {_=os.close(capture);_=os.remove(capture_path)}
    if !platform_private_path(capture_path,false) {return false,"Could not protect Task Scheduler diagnostic output."}
    handle:=win32.HANDLE(os.fd(capture))
    _=win32.SetHandleInformation(handle,win32.HANDLE_FLAG_INHERIT,win32.HANDLE_FLAG_INHERIT)
    script:=fmt.tprintf("$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.UTF8Encoding]::new(); try { %s } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }",command)
    wide:=win32.utf8_to_utf16(script)
    encoded:=base64.encode(mem.slice_to_bytes(wide))
    defer delete(encoded)
    system_root:=os.get_env("SystemRoot",context.temp_allocator)
    if system_root=="" {return false,"Could not locate Windows PowerShell."}
    executable:=fmt.tprintf("%s/System32/WindowsPowerShell/v1.0/powershell.exe",system_root)
    line:=win32.utf8_to_wstring(fmt.tprintf("\"%s\" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand %s",executable,encoded))
    info:win32.PROCESS_INFORMATION
    startup:=win32.STARTUPINFOW{cb=size_of(win32.STARTUPINFOW),dwFlags=win32.STARTF_USESTDHANDLES,hStdOutput=handle,hStdError=handle}
    sync.mutex_lock(&remote_spawn_mutex)
    started:=win32.CreateProcessW(nil,line,nil,nil,true,win32.CREATE_NO_WINDOW|win32.CREATE_UNICODE_ENVIRONMENT,nil,nil,&startup,&info)
    sync.mutex_unlock(&remote_spawn_mutex)
    if !started {return false,fmt.tprintf("Could not run Task Scheduler command: Windows error %d",win32.GetLastError())}
    win32.CloseHandle(info.hThread)
    defer win32.CloseHandle(info.hProcess)
    wait:=win32.WaitForSingleObject(info.hProcess,25000)
    if wait!=win32.WAIT_OBJECT_0 {
        _=win32.TerminateProcess(info.hProcess,1)
        _=win32.WaitForSingleObject(info.hProcess,2000)
        return false,"Task Scheduler command did not finish."
    }
    code:win32.DWORD
    _=win32.GetExitCodeProcess(info.hProcess,&code)
    _,_=os.seek(capture,0,.Start)
    buffer:=make([]u8,4096,context.temp_allocator)
    count,_:=os.read(capture,buffer)
    return code==0,strings.trim_space(string(buffer[:count]))
}

persistence_init :: proc(a:^App) {
    persistence_local_captured=false
    a.persistence_last_poll=-1e9
    if persistence_windows_sid()=="" {persistence_error_set(a,"Could not identify the Windows account for persistence.");return}
    ok,output:=persistence_windows_command(fmt.tprintf("$t=Get-ScheduledTask -TaskName %s -ErrorAction SilentlyContinue; if ($t -and $t.Settings.Enabled) { Write-Output 'enabled' }",persistence_windows_ps_quote(persistence_windows_task_name())))
    a.persistence_enabled=ok&&strings.trim_space(output)=="enabled"
    if !ok {persistence_error_set(a,output)}
}

// The executable is versioned by contents. Windows cannot overwrite a running
// image; stop gracefully before replacing it, then restart the same user task.
persistence_install_unit :: proc(a:^App)->(success,updated:bool) {
    executable,executable_error:=os.get_executable_path(context.temp_allocator)
    data_directory,data_error:=os.user_data_dir(context.temp_allocator)
    if executable_error!=nil||data_error!=nil {persistence_error_set(a,"Could not locate the executable or user data directory.");return}
    directory:=fmt.tprintf("%s/task_master/persistence",data_directory)
    stable:=fmt.tprintf("%s/task_master.exe",directory)
    binary,binary_error:=os.read_entire_file(executable,context.temp_allocator)
    if binary_error!=nil {persistence_error_set(a,"Could not read the background executable.");return}
    installed,installed_error:=os.read_entire_file(stable,context.temp_allocator)
    binary_changed:=installed_error!=nil||string(binary)!=string(installed)
    xml:=fmt.tprintf(`<?xml version="1.0" encoding="UTF-8"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
 <RegistrationInfo><Description>task_master background device telemetry</Description></RegistrationInfo>
 <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>%s</UserId></LogonTrigger></Triggers>
 <Principals><Principal id="User"><UserId>%s</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
 <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><AllowHardTerminate>false</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable><RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>true</Hidden><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><RestartOnFailure><Interval>PT1M</Interval><Count>999</Count></RestartOnFailure></Settings>
 <Actions Context="User"><Exec><Command>%s</Command><Arguments>--persistence-service</Arguments><WorkingDirectory>%s</WorkingDirectory></Exec></Actions>
</Task>`,persistence_windows_sid(),persistence_windows_sid(),persistence_windows_xml_quote(stable),persistence_windows_xml_quote(directory))
    xml_path:=fmt.tprintf("%s/task.xml",directory)
    previous,previous_error:=os.read_entire_file(xml_path,context.temp_allocator)
    task_changed:=previous_error!=nil||string(previous)!=xml
    if !binary_changed&&!task_changed {return true,false}
    if !persistence_windows_stop(a) {return}
    if binary_changed&&!persistence_atomic_write(stable,binary,{.Read_User,.Write_User,.Execute_User}) {persistence_error_set(a,"Could not install the background executable in the user data directory.");return}
    // Runtime DLLs and sensor/helper resources travel with the stable service.
    slash:=max(strings.last_index_byte(executable,'/'),strings.last_index_byte(executable,'\\'))
    if slash>=0 {
        source_directory:=executable[:slash]
        files,read_error:=os.read_all_directory_by_path(source_directory,context.temp_allocator)
        if read_error==nil {
            for file in files {
                if file.type!=.Regular||!(strings.has_suffix(strings.to_lower(file.name,context.temp_allocator),".dll")||strings.has_prefix(file.name,"task_master-sensors")) {continue}
                data,dependency_error:=os.read_entire_file(fmt.tprintf("%s/%s",source_directory,file.name),context.temp_allocator)
                if dependency_error!=nil||!persistence_atomic_write(fmt.tprintf("%s/%s",directory,file.name),data) {persistence_error_set(a,"Could not copy a background runtime dependency.");return}
            }
        }
    }
    if !persistence_atomic_write(xml_path,transmute([]u8)xml) {persistence_error_set(a,"Could not save the Windows persistence task.");return}
    output:string
    success,output=persistence_windows_command(fmt.tprintf("Register-ScheduledTask -TaskName %s -Xml ([IO.File]::ReadAllText(%s)) -Force | Out-Null",persistence_windows_ps_quote(persistence_windows_task_name()),persistence_windows_ps_quote(xml_path)))
    if !success {persistence_error_set(a,fmt.tprintf("Could not register the user persistence task: %s",output));return}
    updated=true
    return
}

persistence_windows_stop :: proc(a:^App)->bool {
    event:=persistence_OpenEventW(0x0002,false,win32.utf8_to_wstring(persistence_windows_object_name("Stop")))
    if event!=nil {_=win32.SetEvent(event);win32.CloseHandle(event)}
    // The mutex lives until all sampler/SSH teardown has completed.
    started:=time.tick_now()
    for time.tick_since(started)<20*time.Second {
        mutex:=persistence_OpenMutexW(0x00100000,false,win32.utf8_to_wstring(persistence_windows_object_name("Running")))
        if mutex==nil {return true}
        win32.CloseHandle(mutex)
        time.sleep(50*time.Millisecond)
    }
    persistence_error_set(a,"The persistence collector did not stop cleanly. Its executable has been retained.")
    return false
}
persistence_windows_running :: proc()->bool {
    event:=persistence_OpenEventW(0x00100000,false,win32.utf8_to_wstring(persistence_windows_object_name("Stop")))
    if event==nil {return false}
    defer win32.CloseHandle(event)
    return win32.WaitForSingleObject(event,0)==win32.WAIT_TIMEOUT
}
persistence_service_set :: proc(a:^App,enable:bool,refresh_only:bool=false,force_restart:bool=false)->bool {
    task:=persistence_windows_ps_quote(persistence_windows_task_name())
    if !enable {
        ok,output:=persistence_windows_command(fmt.tprintf("$t=Get-ScheduledTask -TaskName %s -ErrorAction SilentlyContinue; if ($t) { Disable-ScheduledTask -InputObject $t | Out-Null }",task))
        if !ok {persistence_error_set(a,fmt.tprintf("Could not disable persistence: %s",output));return false}
        if !persistence_windows_stop(a) {return false}
        a.persistence_enabled=false;a.persistence_error_len=0
        return true
    }
    installed,updated:=persistence_install_unit(a)
    if !installed {return false}
    if refresh_only&&!updated&&!force_restart&&persistence_windows_running() {return true}
    if (updated||force_restart)&&!persistence_windows_stop(a) {return false}
    ok,output:=persistence_windows_command(fmt.tprintf("Enable-ScheduledTask -TaskName %s | Out-Null; Start-ScheduledTask -TaskName %s",task,task))
    if !ok {persistence_error_set(a,fmt.tprintf("Could not start persistence: %s",output));return false}
    started:=time.tick_now()
    for !persistence_windows_running()&&time.tick_since(started)<8*time.Second {time.sleep(50*time.Millisecond)}
    if !persistence_windows_running() {persistence_error_set(a,"Windows registered the task but its collector did not start.");return false}
    a.persistence_enabled=true;a.persistence_error_len=0
    return true
}

persistence_windows_event:win32.HANDLE
persistence_windows_mutex:win32.HANDLE
persistence_windows_console_stop :: proc "system" (control:win32.DWORD)->win32.BOOL {
    if control<=2||control==5||control==6 {
        if persistence_windows_event!=nil {_=win32.SetEvent(persistence_windows_event)}
        return true
    }
    return false
}
persistence_platform_service_init :: proc()->bool {
    descriptor:=persistence_windows_security()
    if descriptor==nil {return false}
    defer win32.LocalFree(descriptor)
    attributes:=win32.SECURITY_ATTRIBUTES{nLength=size_of(win32.SECURITY_ATTRIBUTES),lpSecurityDescriptor=descriptor}
    persistence_windows_mutex=persistence_CreateMutexW(&attributes,false,win32.utf8_to_wstring(persistence_windows_object_name("Running")))
    if persistence_windows_mutex==nil {return false}
    if win32.GetLastError()==win32.ERROR_ALREADY_EXISTS {win32.CloseHandle(persistence_windows_mutex);persistence_windows_mutex=nil;return false}
    persistence_windows_event=win32.CreateEventW(&attributes,true,false,win32.utf8_to_wstring(persistence_windows_object_name("Stop")))
    if persistence_windows_event==nil {win32.CloseHandle(persistence_windows_mutex);persistence_windows_mutex=nil;return false}
    _=win32.ResetEvent(persistence_windows_event)
    _=win32.SetConsoleCtrlHandler(persistence_windows_console_stop,true)
    return true
}
persistence_platform_service_stop_requested :: proc()->bool {return win32.WaitForSingleObject(persistence_windows_event,0)!=win32.WAIT_TIMEOUT}
persistence_platform_service_destroy :: proc() {
    _=win32.SetConsoleCtrlHandler(persistence_windows_console_stop,false)
    if persistence_windows_event!=nil {win32.CloseHandle(persistence_windows_event);persistence_windows_event=nil}
    if persistence_windows_mutex!=nil {win32.CloseHandle(persistence_windows_mutex);persistence_windows_mutex=nil}
}

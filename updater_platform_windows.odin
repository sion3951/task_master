#+build windows
package main

import "core:encoding/base64"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"

updater_platform_target :: proc()->(Update_Target,string) {
    executable,error:=os.get_executable_path(context.temp_allocator)
    if error!=nil {return {},fmt.tprintf("Could not locate this installation: %v",error)}
    program_files:=os.get_env("ProgramW6432",context.temp_allocator)
    if program_files=="" {program_files=os.get_env("ProgramFiles",context.temp_allocator)}
    path,_:=strings.replace_all(executable,"\\","/",context.temp_allocator)
    directory,_:=strings.replace_all(program_files,"\\","/",context.temp_allocator)
    if directory==""||strings.to_lower(path,context.temp_allocator)!=strings.to_lower(fmt.tprintf("%s/task_master/task_master.exe",directory),context.temp_allocator) {
        return {},"Install the Windows release setup to enable automatic updates. Development builds are updated manually."
    }
    arch := "arm64" when ODIN_ARCH == .arm64 else "amd64"
    return Update_Target{os="windows",arch=arch,kind="windows",executable=executable},""
}

updater_platform_install :: proc(target:^Update_Target,package_path,stage:string,parent_pid:i32)->(bool,string) {
    token:win32.HANDLE
    if !win32.OpenProcessToken(win32.GetCurrentProcess(),win32.TOKEN_QUERY,&token) {return false,"Could not inspect the updater account."}
    elevation:u32
    returned:win32.DWORD
    inspected:=win32.GetTokenInformation(token,.TokenElevation,&elevation,size_of(elevation),&returned)
    win32.CloseHandle(token)
    if !inspected {return false,"Could not inspect the updater account."}
    if elevation!=0 {return false,"Run task_master as your normal account to install updates and relaunch safely."}
    helper:=fmt.tprintf("%s/update-install.ps1",stage)
    error:=os.write_entire_file(helper,#load("scripts/update-install-windows.ps1"),{.Read_User,.Write_User})
    if error!=nil {return false,fmt.tprintf("Could not stage the update helper: %v",error)}
    if !platform_private_path(helper,false) {return false,"Could not protect the update helper."}
    system_root:=os.get_env("SystemRoot",context.temp_allocator)
    if system_root=="" {return false,"Could not locate Windows PowerShell."}
    script:=fmt.tprintf("& %s -Package %s -Stage %s -ParentPid %d -Executable %s -Sha256 %s -Size %d",persistence_windows_ps_quote(helper),persistence_windows_ps_quote(package_path),persistence_windows_ps_quote(stage),parent_pid,persistence_windows_ps_quote(target.executable),persistence_windows_ps_quote(target.sha256),target.size)
    wide:=win32.utf8_to_utf16(script)
    encoded:=base64.encode(mem.slice_to_bytes(wide))
    defer delete(encoded)
    executable:=fmt.tprintf("%s/System32/WindowsPowerShell/v1.0/powershell.exe",system_root)
    line:=win32.utf8_to_wstring(fmt.tprintf("\"%s\" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand %s",executable,encoded))
    startup:=win32.STARTUPINFOW{cb=size_of(win32.STARTUPINFOW)}
    info:win32.PROCESS_INFORMATION
    sync.mutex_lock(&remote_spawn_mutex)
    started:=win32.CreateProcessW(nil,line,nil,nil,false,win32.CREATE_NO_WINDOW|win32.CREATE_UNICODE_ENVIRONMENT,nil,nil,&startup,&info)
    sync.mutex_unlock(&remote_spawn_mutex)
    if !started {return false,fmt.tprintf("Could not start the update installer: Windows error %d",win32.GetLastError())}
    win32.CloseHandle(info.hThread)
    win32.CloseHandle(info.hProcess)
    return true,""
}

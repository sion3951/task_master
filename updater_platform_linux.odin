#+build linux
package main

import "core:fmt"
import "core:os"
import "core:sync"
import "core:sys/posix"

updater_platform_target :: proc()->(Update_Target,string) {
    executable,error:=os.get_executable_path(context.temp_allocator)
    if error!=nil {return {},fmt.tprintf("Could not locate this installation: %v",error)}
    architecture:=""
    when ODIN_ARCH==.amd64 {architecture="amd64"} else when ODIN_ARCH==.arm64 {architecture="arm64"}
    if architecture=="" {return {},"Automatic updates support Linux x64 and ARM64."}
    target:=Update_Target{os="linux",arch=architecture,executable=executable}
    if executable=="/usr/bin/task_master" {target.kind="deb";return target,""}
    if executable=="/opt/task_master/usr/bin/task_master" {target.kind="appimage";return target,""}
    appdir:=os.get_env("APPDIR",context.temp_allocator)
    appimage:=os.get_env("APPIMAGE",context.temp_allocator)
    // APPIMAGE can belong to a parent editor. Only trust our own mounted runtime.
    if appdir!=""&&appimage!=""&&executable==fmt.tprintf("%s/usr/bin/task_master",appdir)&&os.is_file(appimage) {
        target.kind="appimage";target.portable_path=appimage;return target,""
    }
    return {},"This is a development or manual installation. Install the release .deb or AppImage to enable automatic updates."
}

updater_platform_install :: proc(target:^Update_Target,package_path,stage:string,parent_pid:i32)->(bool,string) {
    if posix.getuid()==0 {return false,"Run task_master as your normal account to install updates and relaunch safely."}
    helper:=fmt.tprintf("%s/update-install.sh",stage)
    error:=os.write_entire_file(helper,#load("scripts/update-install-unix.sh"),{.Read_User,.Write_User})
    if error!=nil {return false,fmt.tprintf("Could not stage the update helper: %v",error)}
    if !platform_private_path(helper,false) {return false,"Could not protect the update helper."}
    log,log_error:=os.open(fmt.tprintf("%s/install.log",stage),{.Write,.Create,.Trunc},{.Read_User,.Write_User})
    if log_error!=nil {return false,fmt.tprintf("Could not open the installation log: %v",log_error)}
    defer os.close(log)
    sync.mutex_lock(&remote_spawn_mutex)
    process,start_error:=os.process_start({command=[]string{"/bin/sh",helper,target.os,target.kind,package_path,stage,fmt.tprintf("%d",parent_pid),target.executable,target.portable_path,target.sha256,fmt.tprintf("%d",target.size)},stdout=log,stderr=log})
    sync.mutex_unlock(&remote_spawn_mutex)
    if start_error!=nil {return false,fmt.tprintf("Could not start the update installer: %v",start_error)}
    machine_platform_terminal_release(process)
    return true,""
}

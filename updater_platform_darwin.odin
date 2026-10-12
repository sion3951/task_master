#+build darwin
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
    // A Rosetta launch must still select the package for the physical Mac: the
    // existing package's preinstall checks the native hardware architecture.
    hardware_arm64:i32
    hardware_size:=uintptr(size_of(hardware_arm64))
    if darwin_sysctlbyname("hw.optional.arm64",&hardware_arm64,&hardware_size,nil,0)==0&&hardware_arm64==1 {architecture="arm64"}
    if architecture=="" {return {},"Automatic updates support Intel and Apple Silicon Macs."}
    if executable!="/Applications/task_master.app/Contents/MacOS/task_master" {
        return {},"Install the release package in Applications to enable automatic updates. Development builds are updated manually."
    }
    return Update_Target{os="darwin",arch=architecture,kind="macos",executable=executable},""
}

updater_platform_install :: proc(target:^Update_Target,package_path,stage:string,parent_pid:i32)->(bool,string) {
    if posix.getuid()==0 {return false,"Run task_master as your normal account to install updates and relaunch safely."}
    helper,error:=updater_installed_launcher(target)
    if error!="" {return false,error}
    log,log_error:=os.open(fmt.tprintf("%s/install.log",stage),{.Write,.Create,.Trunc},{.Read_User,.Write_User})
    if log_error!=nil {return false,fmt.tprintf("Could not open the installation log: %v",log_error)}
    defer os.close(log)
    sync.mutex_lock(&remote_spawn_mutex)
    _,start_error:=os.process_start({command=[]string{"/bin/sh",helper,target.os,target.kind,package_path,stage,fmt.tprintf("%d",parent_pid),target.executable,target.portable_path,target.sha256,fmt.tprintf("%d",target.size)},stdout=log,stderr=log,env=updater_install_environment()})
    sync.mutex_unlock(&remote_spawn_mutex)
    if start_error!=nil {return false,fmt.tprintf("Could not start the update installer: %v",start_error)}
    return true,""
}

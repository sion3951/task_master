#+build linux, darwin
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

// A protected leaf inside a user-owned parent is replaceable. Check every
// ancestor, using lstat so a symlink cannot redirect the trusted code path.
updater_protected_file :: proc(path:string)->bool {
    if path==""||path[0]!='/' {return false}
    current:=path
    leaf:=true
    for {
        info:posix.stat_t
        if posix.lstat(strings.clone_to_cstring(current,context.temp_allocator),&info)!=nil||
            info.st_uid!=0||(info.st_mode&posix.mode_t{.IWGRP,.IWOTH})!={} {return false}
        when ODIN_OS==.Darwin {if !updater_darwin_protected_acl(current) {return false}}
        if leaf {
            if !posix.S_ISREG(info.st_mode) {return false}
        } else if !posix.S_ISDIR(info.st_mode) {return false}
        if current=="/" {return true}
        current=filepath.dir(current);leaf=false
    }
}

updater_installed_launcher :: proc(target:^Update_Target)->(string,string) {
    directory:="/usr/libexec/task_master"
    when ODIN_OS==.Darwin {directory="/Library/PrivilegedHelperTools/task_master"}
    else {if target.kind=="appimage" {directory="/usr/local/libexec/task_master"}}
    launcher:=fmt.tprintf("%s/update-install.sh",directory)
    helper:=fmt.tprintf("%s/update-helper",directory)
    if !updater_protected_file(launcher)||!updater_protected_file(helper) {
        return "","The protected update helper is missing or has unsafe permissions. Reinstall the release package to enable secure updates."
    }
    return launcher,""
}

updater_install_environment :: proc()->[]string {
    variables:=make([dynamic]string,0,16,context.temp_allocator)
    append(&variables,"PATH=/usr/bin:/bin:/usr/sbin:/sbin")
    for key in ([]string{"HOME","USER","LOGNAME","DISPLAY","WAYLAND_DISPLAY","XDG_RUNTIME_DIR",
        "DBUS_SESSION_BUS_ADDRESS","XAUTHORITY","XDG_CONFIG_HOME","LANG","LC_ALL","TERM"}) {
        value:=os.get_env(key,context.temp_allocator)
        if value!="" {append(&variables,fmt.tprintf("%s=%s",key,value))}
    }
    return variables[:]
}

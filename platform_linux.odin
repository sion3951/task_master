package main

import "core:fmt"
import "core:sys/posix"

platform_process_init :: proc() { _=posix.signal(.SIGPIPE,auto_cast posix.SIG_IGN) }
platform_clock_text :: proc(second:i64)->string {
    seconds:=posix.time_t(second)
    local:posix.tm
    if posix.localtime_r(&seconds,&local)!=nil {return fmt.tprintf("%02d:%02d:%02d",local.tm_hour,local.tm_min,local.tm_sec)}
    return "--:--:--"
}
platform_power_install_hint :: proc()->string {return "Power access: install the .deb, run AppImage --install-power-access, or make install. Remote hosts: make install-remote HOST=<alias>."}

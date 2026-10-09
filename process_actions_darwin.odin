package main

import "core:fmt"
import "core:sys/posix"

process_kill_local :: proc(action:^Process_Kill_Action)->bool {
    node:=action.node
    if metrics_darwin_process_identity(node.pid)!=node.start {
        process_kill_error(action,fmt.tprintf("PID %d exited or changed; select its current row.",node.pid))
        return false
    }
    if posix.kill(posix.pid_t(node.pid),.SIGKILL)!=nil {
        process_kill_error(action,fmt.tprintf("Could not kill PID %d: %v",node.pid,posix.errno()))
        return false
    }
    return true
}

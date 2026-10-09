package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

process_kill_local :: proc(action:^Process_Kill_Action)->bool {
    node:=action.node
    handle,open_error:=linux.pidfd_open(linux.Pid(node.pid),{})
    if open_error!=nil {
        process_kill_error(action,fmt.tprintf("Could not open PID %d: %v",node.pid,open_error))
        return false
    }
    defer linux.close(linux.Fd(handle))
    path_buffer:[64]u8
    path:=fmt.bprintf(path_buffer[:],"/proc/%d/stat",node.pid)
    file,read_error:=os.open(path)
    if read_error!=nil {
        process_kill_error(action,fmt.tprintf("Could not check PID %d: %v",node.pid,read_error))
        return false
    }
    buffer:[4096]u8
    count,stat_error:=os.read(file,buffer[:])
    os.close(file)
    if stat_error!=nil {
        process_kill_error(action,fmt.tprintf("Could not check PID %d: %v",node.pid,stat_error))
        return false
    }
    stat:=string(buffer[:count])
    close:=strings.last_index_byte(stat,')')
    fields:[24]string
    if close<0||close+2>=len(stat)||telemetry_fields(stat[close+2:],fields[:])<20||telemetry_uint(fields[19])!=node.start {
        process_kill_error(action,fmt.tprintf("PID %d exited or changed; select its current row.",node.pid))
        return false
    }
    // Hold the original process handle across verification and signaling. A
    // reused numeric PID can never receive this signal.
    result:=linux.syscall(linux.SYS_pidfd_send_signal,handle,i32(linux.Signal.SIGKILL),uintptr(0),u32(0))
    if result<0 {
        process_kill_error(action,fmt.tprintf("Could not kill PID %d: %v",node.pid,linux.Errno(-result)))
        return false
    }
    return true
}


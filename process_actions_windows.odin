package main

import "core:fmt"
import win32 "core:sys/windows"

process_kill_local :: proc(action:^Process_Kill_Action)->bool {
    node:=action.node
    handle:=win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION|win32.PROCESS_TERMINATE,false,u32(node.pid))
    if handle==nil {process_kill_error(action,fmt.tprintf("Could not open PID %d: Windows error %d",node.pid,win32.GetLastError()));return false}
    defer win32.CloseHandle(handle)
    created,exited,kernel,user:win32.FILETIME
    if !win32.GetProcessTimes(handle,&created,&exited,&kernel,&user) {
        process_kill_error(action,fmt.tprintf("Could not check PID %d: Windows error %d",node.pid,win32.GetLastError()));return false
    }
    identity:=u64(created.dwLowDateTime)|(u64(created.dwHighDateTime)<<32)
    if identity!=node.start {process_kill_error(action,fmt.tprintf("PID %d exited or changed; select its current row.",node.pid));return false}
    // Verify and terminate through the same handle, preventing PID-reuse races.
    if !win32.TerminateProcess(handle,1) {
        process_kill_error(action,fmt.tprintf("Could not kill PID %d: Windows error %d",node.pid,win32.GetLastError()));return false
    }
    return true
}

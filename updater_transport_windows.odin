#+build windows
package main

import "core:os"
import win "core:sys/windows"

updater_windows_fetch_start :: proc(args:[]string)->(os.Process,uintptr,os.Error) {
    // The shared launcher quotes argument arrays using Windows CRT rules and
    // starts without a console. A job keeps shutdown cancellation bounded.
    nul,err:=os.open("NUL",{.Read,.Write})
    if err!=nil {return {},0,err}
    defer os.close(nul)
    return remote_ssh_process_start(args,nul,nul,nul)
}
updater_windows_fetch_close :: proc(handle:uintptr) {
    if handle!=0 {win.CloseHandle(win.HANDLE(handle))}
}

#+build windows
package main

import "core:encoding/base64"
import "core:fmt"
import "core:mem"
import "core:os"
import win "core:sys/windows"

updater_windows_fetch_start :: proc(url,path:string,limit:i64)->(os.Process,uintptr,os.Error) {
    system_root:=os.get_env("SystemRoot",context.temp_allocator)
    if system_root=="" {return {},0,os.Platform_Error(win.ERROR_FILE_NOT_FOUND)}
    // Use the inbox Windows PowerShell/.NET HTTPS client, independent of curl
    // and PATH. Encode both the embedded helper and its quoted arguments.
    script:=fmt.tprintf("& {\n%s\n} -Url %s -Destination %s -Limit %d",
        string(#load("scripts/update-download-windows.ps1")),
        persistence_windows_ps_quote(url),persistence_windows_ps_quote(path),limit)
    wide:=win.utf8_to_utf16(script,context.temp_allocator)
    encoded:=base64.encode(mem.slice_to_bytes(wide))
    defer delete(encoded)
    args:=[]string{fmt.tprintf("%s/System32/WindowsPowerShell/v1.0/powershell.exe",system_root),
        "-NoLogo","-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-EncodedCommand",string(encoded)}
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

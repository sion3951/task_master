package main

import "core:fmt"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"

platform_process_init :: proc() {
    // A GUI subsystem executable opens no console for ordinary launches. Attach
    // for CLI diagnostics without replacing redirected output/pipeline handles.
    cli:=false
    for arg in os.args[1:] {if arg=="--stats"||arg=="--help"||arg=="--smoke"||arg=="--startup-profile"||strings.has_prefix(arg,"--persistence=")||strings.has_prefix(arg,"--capture=") {cli=true}}
    if !cli {return}
    output,errors:=win32.GetStdHandle(win32.STD_OUTPUT_HANDLE),win32.GetStdHandle(win32.STD_ERROR_HANDLE)
    output_valid:=output!=nil&&output!=win32.INVALID_HANDLE_VALUE&&win32.GetFileType(output)!=0
    errors_valid:=errors!=nil&&errors!=win32.INVALID_HANDLE_VALUE&&win32.GetFileType(errors)!=0
    if !win32.AttachConsole(~u32(0)) {return}
    if !output_valid {os.stdout=os.new_file(uintptr(win32.GetStdHandle(win32.STD_OUTPUT_HANDLE)),"<stdout>")}
    if !errors_valid {os.stderr=os.new_file(uintptr(win32.GetStdHandle(win32.STD_ERROR_HANDLE)),"<stderr>")}
}
platform_clock_text :: proc(second:i64)->string {
    // Convert the requested UTC sample to local time using Windows timezone rules.
    ticks:=u64(second+11644473600)*10000000
    utc:=win32.FILETIME{dwLowDateTime=u32(ticks),dwHighDateTime=u32(ticks>>32)}
    utc_calendar,calendar:win32.SYSTEMTIME
    if win32.FileTimeToSystemTime(&utc,&utc_calendar)&&win32.SystemTimeToTzSpecificLocalTime(nil,&utc_calendar,&calendar) {
        return fmt.tprintf("%02d:%02d:%02d",calendar.hour,calendar.minute,calendar.second)
    }
    return "--:--:--"
}
platform_power_install_hint :: proc()->string {return "Run scripts/install-sensors.ps1 as Administrator once to install the CPU sensor service; task_master itself runs as your normal user."}

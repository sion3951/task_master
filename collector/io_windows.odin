package main

import "core:os"
import win32 "core:sys/windows"
import "core:time"

collector_platform_init :: proc() {}
collector_write :: proc(data:[]u8)->bool {
    remaining:=data
    for len(remaining)>0 {
        count,err:=os.write(os.stdout,remaining)
        if err!=nil||count<=0 {return false}
        remaining=remaining[count:]
    }
    newline:=[1]u8{'\n'}
    count,err:=os.write(os.stdout,newline[:])
    return err==nil&&count==1
}
collector_wait :: proc(last_sample:time.Tick,interval:^f64,control:^Collector_Control)->bool {
    input:=win32.GetStdHandle(win32.STD_INPUT_HANDLE)
    // SSH owns stdin. Poll its pipe in bounded intervals so disconnection exits
    // the collector promptly, even without a console or Windows signals.
    for {
        available:u32
        if !win32.PeekNamedPipe(input,nil,0,nil,&available,nil) {return false}
        if available>0 {
            commands:[256]u8
            read:u32
            if !win32.ReadFile(input,&commands[0],min(available,u32(len(commands))),&read,nil)||read==0 {return false}
            collector_control_read(control,commands[:int(read)],interval)
        }
        remaining:=interval^-time.duration_seconds(time.tick_since(last_sample))
        if remaining<=0 {return true}
        time.sleep(min(20*time.Millisecond,time.Duration(remaining*f64(time.Second))))
    }
}

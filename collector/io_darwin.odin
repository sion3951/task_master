package main

import "core:sys/posix"
import "core:time"

collector_platform_init :: proc() {_=posix.signal(.SIGPIPE,auto_cast posix.SIG_IGN)}
collector_write :: proc(data:[]u8)->bool {
    newline:=[1]u8{'\n'}
    for part in ([2][]u8{data,newline[:]}) {
        sent:=0
        for sent<len(part) {
            n:=posix.write(1,raw_data(part[sent:]),uint(len(part))-uint(sent))
            if n<0&&posix.errno()==.EINTR {continue}
            if n<=0 {return false}
            sent+=int(n)
        }
    }
    return true
}
collector_wait :: proc(last_sample:time.Tick,interval:^f64,control:^Collector_Control)->bool {
    input:=[1]posix.pollfd{{fd=0,events={.IN}}}
    for {
        elapsed:=time.duration_seconds(time.tick_since(last_sample))
        remaining:=max(0,int((interval^-elapsed)*1000)+1)
        ready:=posix.poll(raw_data(input[:]),1,i32(remaining))
        if ready<0&&posix.errno()==.EINTR {continue}
        if ready<0 {return false}
        if ready==0 {return true}
        if .HUP in input[0].revents||.ERR in input[0].revents||.NVAL in input[0].revents {return false}
        if .IN in input[0].revents {
            commands:[256]u8
            n:=posix.read(0,raw_data(commands[:]),uint(len(commands)))
            if n<0&&posix.errno()==.EINTR {continue}
            if n<=0 {return false}
            collector_control_read(control,commands[:int(n)],interval)
        }
    }
}

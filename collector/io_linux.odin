package main

import "core:sys/linux"
import "core:sys/posix"
import "core:time"

collector_write :: proc(data: []u8) -> bool {
    newline := [1]u8{'\n'}
    vectors := [2]linux.IO_Vec{{base = raw_data(data), len = uint(len(data))}, {base = raw_data(newline[:]), len = 1}}
    first := 0
    // Send the JSON frame and its delimiter together; still handle short pipe writes.
    for first < len(vectors) {
        n, err := linux.writev(1, vectors[first:])
        if err == .EINTR { continue }
        if err != nil || n <= 0 { return false }
        consumed := uint(n)
        for first < len(vectors) && consumed >= vectors[first].len {
            consumed -= vectors[first].len
            first += 1
        }
        if first < len(vectors) {
            vectors[first].base = &vectors[first].base[consumed]
            vectors[first].len -= consumed
        }
    }
    return true
}

collector_platform_init :: proc() {_=posix.signal(.SIGPIPE,auto_cast posix.SIG_IGN)}
collector_wait :: proc(last_sample:time.Tick,interval:^f64,control:^Collector_Control)->bool {
    input := [1]linux.Poll_Fd{{fd = 0, events = {.IN}}}
    for {
        elapsed := time.duration_seconds(time.tick_since(last_sample))
        remaining := max(0, int((interval^-elapsed)*1000)+1)
        ready, err := linux.poll(input[:], i32(remaining))
        if err == .EINTR { continue }
        if err != nil { return false }
        if ready == 0 { return true }
        if .HUP in input[0].revents || .ERR in input[0].revents || .NVAL in input[0].revents { return false }
        if .IN in input[0].revents {
            commands: [256]u8
            count, read_err := linux.read(0, commands[:])
            if read_err == .EINTR { continue }
            if count <= 0 || read_err != nil { return false }
            collector_control_read(control,commands[:int(count)],interval)
        }
    }
}

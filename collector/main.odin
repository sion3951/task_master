package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// Telemetry shares the desktop startup timing hook, without any UI dependency.
startup_stage :: proc(t: time.Tick, name: string) -> time.Tick { return time.tick_now() }

Collector_Control :: struct {buffer:[128]u8, used:int, overflow:bool}

// Commands may arrive across pipe reads. A bounded line buffer rejects malformed
// input without allowing a control stream to grow collector memory.
collector_control_read :: proc(control:^Collector_Control,data:[]u8,interval:^f64) {
    for ch in data {
        if ch=='\n' {
            line:=strings.trim_space(string(control.buffer[:control.used]))
            if !control.overflow&&strings.has_prefix(line,"interval ") {
                value,ok:=strconv.parse_f64(strings.trim_space(line[len("interval "):]))
                if ok&&value>=0.1&&value<=10 {interval^=value}
            }
            control.used=0;control.overflow=false
        } else if control.used<len(control.buffer) {control.buffer[control.used]=ch;control.used+=1}
        else {control.overflow=true}
    }
}

main :: proc() {
    once := false
    stats := false
    for arg in os.args[1:] {
        if arg == "--once" { once = true }
        else if arg == "--protocol-version" { fmt.println(REMOTE_PROTOCOL_VERSION); return }
        else if arg == "--power-fds" {
            when ODIN_OS==.Linux {
                if !metrics_send_cpu_power_fds() {os.exit(1)}
            } else {fmt.eprintln("Descriptor handoff is only used on Linux.");os.exit(2)}
            return
        }
        else if arg == "--kill-pids" {
            when ODIN_OS==.Darwin {
                collector_platform_init()
                if !collector_kill_pids() {os.exit(1)}
            } else {fmt.eprintln("--kill-pids is used by the macOS identity-checked SSH backend.");os.exit(2)}
            return
        }
        else if arg == "--stats" { stats = true }
        else { fmt.eprintln("Usage: task_master-collector [--once | --stats | --protocol-version | --kill-pids]"); os.exit(2) }
    }
    collector_platform_init()
    m := new(Metrics)
    defer free(m)
    session_started:=time.tick_now()
    m.remote_session_id=u64(time.to_unix_nanoseconds(time.now()))~u64(os.get_pid())
    if m.remote_session_id==0 {m.remote_session_id=1}
    m.remote_collector_version_len=copy(m.remote_collector_version[:],#config(TASK_MASTER_VERSION,"dev"))
    m.remote_architecture_len=copy(m.remote_architecture[:],"amd64" if ODIN_ARCH==.amd64 else "arm64" if ODIN_ARCH==.arm64 else "riscv64" if ODIN_ARCH==.riscv64 else "unknown")
    mode,mode_ok:=os.lookup_env("TASK_MASTER_COLLECTOR_MODE",context.temp_allocator)
    if !mode_ok||mode!="installed"&&mode!="temporary" {mode="custom"}
    m.remote_mode_len=copy(m.remote_mode[:],mode)
    metrics_init_cpu(m)
    metrics_init_devices(m)
    defer metrics_destroy(m)
    if stats || once {
        time.sleep(time.Second)
        metrics_sample(m, time.duration_seconds(time.tick_since(m._sample_started)))
        if stats {
            fmt.printf("%s | %s | package power %s (%v)\n", m.hostname, m.cpu_model,
                fmt.tprintf("%.1f W", m.cpu_power_watts) if m.cpu_power_available else metrics_cpu_power_status(m), m.cpu_power_source)
            if !m.cpu_power_available {
                fmt.printf("CPU power: %s\n", string(m.cpu_power_error[:m.cpu_power_error_len]))
                os.exit(1)
            }
            return
        }
    }
    last_sample := time.tick_now()
    interval:f64=1
    control:Collector_Control
    m.remote_source_seconds=time.duration_seconds(time.tick_since(session_started))
    for {
        m.remote_sequence+=1
        data, ok := remote_encode(m)
        if !ok {return}
        written:=collector_write(data)
        delete(data)
        if !written {return}
        mem.free_all(context.temp_allocator)
        if once { return }
        // SSH keeps stdin open for the lifetime of the connection. poll wakes
        // immediately on disconnect, instead of leaving a sampler on the host.
        if !collector_wait(last_sample,&interval,&control) {return}
        now := time.tick_now()
        m.remote_sample_interval=time.duration_seconds(time.tick_since(last_sample))
        metrics_sample(m, m.remote_sample_interval)
        m.remote_source_seconds=time.duration_seconds(time.tick_diff(session_started,now))
        last_sample = now
        mem.free_all(context.temp_allocator)
    }
}

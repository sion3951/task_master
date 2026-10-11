package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Connection_Status :: enum { Connecting, Live, Disconnected, Saved, Setup_Required }
Remote_Sample_Break :: enum { None, Session, Dropped }


Remote_Connection :: struct {
    mutex: sync.Mutex,
    samples: [32]^Metrics,
    sample_times: [32]time.Tick,
    sample_breaks: [32]Remote_Sample_Break,
    sample_start, sample_count: int,
    recycled: [dynamic]^Metrics,
    interval: f64,
    status: Connection_Status,
    message: [512]u8,
    message_len: int,
    received: time.Tick,
    host, collector: string,
    port: u16,
    platform: Remote_Platform,
    architecture: [32]u8,
    architecture_len:int,
    worker: ^thread.Thread,
    stop: bool, // Accessed atomically; the worker owns all process/pipe handles.
    retry_requested: bool, // Atomic wake request; only the worker restarts SSH.
    invalidate_platform: bool,
    collector_mode: [16]u8,
    collector_mode_len: int,
}

// os.process_start changes descriptor inheritance; serialize each complete spawn.
remote_spawn_mutex: sync.Mutex

remote_connection_create :: proc(host, collector: string, port:u16=0, interval:f64=1) -> ^Remote_Connection {
    c := new(Remote_Connection)
    c.host = strings.clone(host)
    c.port=port
    c.collector = strings.clone(collector)
    if c.collector == "" {
        delete(c.collector)
        c.collector = strings.clone("~/.local/bin/task_master-collector")
    }
    c.interval = clamp(interval,0.1,10)
    c.status = .Connecting
    c.message_len = copy(c.message[:], "Connecting")
    c.worker = thread.create_and_start_with_poly_data(c, remote_connection_worker, name="SSH telemetry")
    if c.worker == nil {
        c.status = .Disconnected
        c.message_len = copy(c.message[:], "Unable to start SSH worker")
    }
    return c
}

remote_connection_destroy :: proc(c: ^Remote_Connection) {
    if c == nil { return }
    sync.atomic_store(&c.stop, true)
    if c.worker != nil {
        thread.join(c.worker)
        thread.destroy(c.worker)
    }
    for i in 0..<c.sample_count {
        snapshot:=c.samples[(c.sample_start+i)%len(c.samples)]
        metrics_destroy(snapshot);free(snapshot)
    }
    for snapshot in c.recycled {metrics_destroy(snapshot);free(snapshot)}
    delete(c.recycled)
    delete(c.host)
    delete(c.collector)
    free(c)
}

// The SSH worker owns stdin; GUI changes coalesce here instead of spawning
// connections or writing concurrently with a collector upload.
remote_connection_set_interval :: proc(c:^Remote_Connection,interval:f64) {
    if c==nil {return}
    sync.mutex_lock(&c.mutex)
    c.interval=clamp(interval,0.1,10)
    sync.mutex_unlock(&c.mutex)
}

remote_connection_retry :: proc(c:^Remote_Connection) {
    if c==nil {return}
    sync.atomic_store(&c.retry_requested,true)
    app_wake()
}

remote_connection_details :: proc(c:^Remote_Connection)->string {
    if c==nil {return "Waiting for connection"}
    sync.mutex_lock(&c.mutex)
    defer sync.mutex_unlock(&c.mutex)
    return strings.clone(string(c.message[:c.message_len]),context.temp_allocator)
}

// Actionable SSH failures never enter a retry loop that cannot fix them.
remote_failure_status :: proc(message:string)->Connection_Status {
    text:=strings.to_lower(message,context.temp_allocator)
    for hint in ([]string{"permission denied", "authentication failed", "host key verification failed", "remote host identification has changed", "no matching host key type", "no matching key exchange method", "offending", "no compatible installed collector", "unsupported or invalid telemetry", "collector does not match", "collector platform changed", "not found", "no such file", "not recognized", "cannot find", "command execution", "requires correction"}) {
        if strings.contains(text,hint) {return .Setup_Required}
    }
    for hint in ([]string{"release does not support", "no valid exact release version", "exact release has no published helper", "remote helper metadata signature", "signed remote helper manifest", "signed remote helper asset metadata", "remote helper checksum verification failed", "remote helper cache bytes did not match"}) {
        if strings.contains(text,hint) {return .Setup_Required}
    }
    return .Disconnected
}

remote_ssh_access_failure :: proc(message:string)->bool {
    text:=strings.to_lower(message,context.temp_allocator)
    for hint in ([]string{"permission denied (", "authentication failed", "host key verification failed", "remote host identification has changed", "no matching host key type", "no matching key exchange method"}) {
        if strings.contains(text,hint) {return true}
    }
    return false
}

remote_connection_failed :: proc(c:^Remote_Connection,message:string) {
    status:=remote_failure_status(message)
    text:=strings.to_lower(message,context.temp_allocator)
    explanation:string
    if strings.contains(text,"host key")||strings.contains(text,"remote host identification has changed")||strings.contains(text,"offending") {
        explanation="SSH host trust needs review; use Setup / fix to verify a new key; review changed keys in your SSH settings"
    } else if strings.contains(text,"permission denied")||strings.contains(text,"authentication failed") {
        explanation="SSH authentication needs a key or agent; use Setup / fix to configure access"
    } else if status==.Setup_Required {
        explanation="Collector setup requires correction; use Setup / fix, then Retry now"
    }
    if strings.contains(text,"collector does not match")||strings.contains(text,"collector platform changed") {
        sync.mutex_lock(&c.mutex)
        c.invalidate_platform=true
        sync.mutex_unlock(&c.mutex)
        explanation="Remote platform changed; Retry now will detect the OS and architecture again"
    }
    detail:=fmt.tprintf("%s. %s",explanation,message) if explanation!="" else message
    remote_connection_status(c,status,detail)
}

remote_live_message :: proc(m:^Metrics)->string {
    mode:=string(m.remote_mode[:m.remote_mode_len])
    label:="Installed collector" if mode=="installed" else "Temporary collector; use Setup / fix to keep it installed" if mode=="temporary" else "Custom collector"
    if m.cpu_power_permission_denied {return fmt.tprintf("%s; CPU power permission denied; other monitoring continues",label)}
    return fmt.tprintf("%s %s; fresh telemetry received",label,string(m.remote_collector_version[:m.remote_collector_version_len]))
}

// Drain every sample with its source time mapped to the desktop clock. Recycling buffers
// avoids allocations in normal operation while covering short GUI stalls.
remote_connection_take :: proc(c:^Remote_Connection,destination:^Metrics)->(ok:bool,received:time.Tick,sample_break:Remote_Sample_Break) {
    if c==nil {return false,{},.None}
    sync.mutex_lock(&c.mutex)
    defer sync.mutex_unlock(&c.mutex)
    if c.sample_count==0 {return false,{},.None}
    index:=c.sample_start
    snapshot:=c.samples[index]
    received=c.sample_times[index]
    sample_break=c.sample_breaks[index]
    metrics_display_copy(destination,snapshot)
    c.samples[index]=nil
    c.sample_start=(index+1)%len(c.samples)
    c.sample_count-=1
    append(&c.recycled,snapshot)
    return true,received,sample_break
}

remote_connection_status :: proc(c: ^Remote_Connection, status: Connection_Status, message: string) {
    sync.mutex_lock(&c.mutex)
    c.status = status
    c.message_len = copy(c.message[:], message)
    sync.mutex_unlock(&c.mutex)
    app_wake()
}

// Quote one shell word. Only a literal ~/ prefix expands on the remote host.
remote_collector_command :: proc(collector: string) -> string {
    b := strings.builder_make()
    defer strings.builder_destroy(&b)
    strings.write_string(&b, "exec ")
    path := collector
    if strings.has_prefix(path, "~/") {
        strings.write_string(&b, "\"$HOME\"")
        path = path[1:]
    }
    strings.write_byte(&b, '\'')
    for character in path {
        if character == '\'' { strings.write_string(&b, "'\"'\"'") }
        else { strings.write_rune(&b, character) }
    }
    strings.write_byte(&b, '\'')
    return strings.clone(strings.to_string(b))
}

Remote_SSH :: struct {
    process: os.Process,
    job: uintptr, // Windows job owns SSH descendants; zero on Linux.
    input, output, errors: ^os.File,
    started: bool,
}

remote_ssh_start :: proc(host, command: string, port:u16=0, auth_probe:bool=false) -> (s: Remote_SSH, err: os.Error) {
    sync.mutex_lock(&remote_spawn_mutex)
    defer sync.mutex_unlock(&remote_spawn_mutex)
    input_read, input_write, input_error := os.pipe()
    if input_error != nil { return s, input_error }
    output_read, output_write, output_error := os.pipe()
    if output_error != nil {
        os.close(input_read); os.close(input_write)
        return s, output_error
    }
    error_read, error_write, error_error := os.pipe()
    if error_error != nil {
        os.close(input_read); os.close(input_write)
        os.close(output_read); os.close(output_write)
        return s, error_error
    }
    args := []string {
        "ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
        "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5",
        "-o", "ServerAliveCountMax=2", "-o", "ControlMaster=no", "-o", "ControlPath=none",
    }
    command_args:=make([dynamic]string,0,len(args)+5,context.temp_allocator)
    append(&command_args,..args)
    if auth_probe {
        // OpenSSH takes the first value for an option: replace the existing one.
        for &arg in command_args {if arg=="ConnectTimeout=8" {arg="ConnectTimeout=3"}}
        append(&command_args,"-o","ConnectionAttempts=1","-o","NumberOfPasswordPrompts=0")
    }
    if port>0 {append(&command_args,"-p",fmt.tprintf("%d",port))}
    append(&command_args,"--",host,command)
    s={input=input_write,output=output_read,errors=error_read}
    prepare_error:=remote_ssh_prepare_parent_pipes(&s)
    if prepare_error!=nil {
        os.close(input_read);os.close(input_write);os.close(output_read);os.close(output_write);os.close(error_read);os.close(error_write)
        return {},prepare_error
    }
    process, job, start_error := remote_ssh_process_start(command_args[:],input_read,output_write,error_write)
    os.close(input_read); os.close(output_write); os.close(error_write)
    if start_error != nil {
        os.close(input_write); os.close(output_read); os.close(error_read)
        return s, start_error
    }
    s = {process=process, job=job, input=input_write, output=output_read, errors=error_read, started=true}
    return s, nil
}

remote_ssh_close :: proc(s: ^Remote_SSH) {
    // A successful zero-time wait may already have closed SSH's process handle.
    // Its job still needs closing to terminate any surviving proxy descendants.
    defer remote_ssh_platform_close(s)
    // Closing stdin also tells the remote collector to exit before SSH is stopped.
    if s.input != nil { os.close(s.input); s.input=nil }
    if s.output != nil { os.close(s.output); s.output=nil }
    if s.errors != nil { os.close(s.errors); s.errors=nil }
    if !s.started { return }
    _, err := os.process_wait(s.process, 300*time.Millisecond)
    if err == .Timeout {
        _ = os.process_terminate(s.process)
        _, err = os.process_wait(s.process, 300*time.Millisecond)
    }
    if err == .Timeout {
        _ = os.process_kill(s.process)
        _, err = os.process_wait(s.process, 2*time.Second)
    }
    s.started = false
}

remote_error_append :: proc(buffer: []u8, used: ^int, data: []u8) {
    if len(data) >= len(buffer) {
        used^ = copy(buffer, data[len(data)-len(buffer):])
        return
    }
    overflow := max(0, used^+len(data)-len(buffer))
    if overflow > 0 {
        copy(buffer, buffer[overflow:used^])
        used^ -= overflow
    }
    used^ += copy(buffer[used^:], data)
}

remote_connection_session :: proc(c: ^Remote_Connection, command: string, frame: ^[dynamic]u8, scratch: ^^Metrics, binary:[]u8=nil, negotiated_bootstrap:bool=false, needs_helper:^bool=nil) -> (live: bool) {
    s, err := remote_ssh_start(c.host, command,c.port)
    if err != nil {
        remote_connection_status(c, .Disconnected, fmt.tprintf("Unable to start SSH: %v", err))
        return false
    }
    defer remote_ssh_close(&s)
    clear(frame)
    read_buffer: [65536]u8
    error_buffer: [2048]u8
    error_used := 0
    failure := "SSH connection closed"
    stderr_open := true
    primed := false
    bootstrap:=negotiated_bootstrap
    mode_selected:=!bootstrap
    source_anchor:time.Tick
    source_start,last_source:f64
    session_id,last_sequence:u64
    sent_interval:f64
    control:[64]u8
    control_len,control_offset:int
    control_interval:f64
    when ODIN_OS==.Linux||ODIN_OS==.Darwin {
        transferred:=0
        transfer_failed:=false
    }
    started := time.tick_now()
    last_frame:=started
    if remote_ssh_prepare_transfer(&s)!=nil {remote_connection_status(c,.Disconnected,"Unable to prepare remote collector input");return false}
    when ODIN_OS==.Windows {
        upload:=Remote_Upload{file=s.input,binary=binary}
        defer remote_upload_close(&upload)
    }
    session_loop: for !sync.atomic_load(&c.stop) {
        if sync.atomic_load(&c.retry_requested) {return live}
        if !live && time.tick_since(started)>20*time.Second {
            failure="Remote collector did not start within 20 seconds"
            break
        }
        sync.mutex_lock(&c.mutex)
        heartbeat_interval:=c.interval
        sync.mutex_unlock(&c.mutex)
        if live&&time.duration_seconds(time.tick_since(last_frame))>max(15,3*heartbeat_interval+5) {failure="Telemetry stopped arriving; reconnecting through SSH";break}
        transfer_ready:=!bootstrap
        when ODIN_OS==.Linux||ODIN_OS==.Darwin {transfer_ready=!bootstrap||mode_selected&&transferred==len(binary)}
        else when ODIN_OS==.Windows {transfer_ready=!bootstrap||mode_selected&&sync.atomic_load(&upload.done)}
        if transfer_ready&&control_len==0 {
            sync.mutex_lock(&c.mutex)
            requested:=c.interval
            sync.mutex_unlock(&c.mutex)
            if requested!=sent_interval {
                control_interval=requested
                control_len=copy(control[:],fmt.tprintf("interval %.6f\n",requested))
                control_offset=0
            }
        }
        write_open:=false
        when ODIN_OS==.Linux||ODIN_OS==.Darwin {write_open=(bootstrap&&mode_selected&&!transfer_failed&&transferred<len(binary))||control_len>0}
        ready,poll_error:=remote_ssh_poll(&s,true,stderr_open,write_open,100)
        if poll_error!=nil {failure="Unable to read SSH connection";break}
        // Drain diagnostics first, so an SSH exit carries its actual reason.
        if ready[1] {
            n,eof,read_error:=remote_pipe_read(s.errors,read_buffer[:])
            if n>0 {remote_error_append(error_buffer[:],&error_used,read_buffer[:n])}
            if eof||read_error!=nil {stderr_open=false}
        }
        when ODIN_OS==.Linux||ODIN_OS==.Darwin {
            if ready[2] {
                if !transfer_ready {
                    remaining:=binary[transferred:]
                    n,write_error:=remote_pipe_write(s.input,remaining[:min(len(remaining),65536)])
                    if n>0 {transferred+=int(n)}
                    if write_error!=nil {transfer_failed=true;failure="Unable to transfer the temporary remote collector";break}
                } else if control_len>0 {
                    n,write_error:=remote_pipe_write(s.input,control[control_offset:control_len])
                    if write_error!=nil {failure="Unable to change remote polling interval";break}
                    control_offset+=n
                    if control_offset==control_len {sent_interval=control_interval;control_len=0}
                }
            }
        } else when ODIN_OS==.Windows {
            if bootstrap&&sync.atomic_load(&upload.failed) {failure="Unable to transfer the temporary remote collector";break}
            if transfer_ready&&control_len>0 {
                n,write_error:=os.write(s.input,control[control_offset:control_len])
                if write_error!=nil||n<=0 {failure="Unable to change remote polling interval";break}
                control_offset+=n
                if control_offset==control_len {sent_interval=control_interval;control_len=0}
            }
        }
        if !ready[0] {continue}
        n,eof,read_error:=remote_pipe_read(s.output,read_buffer[:])
        if eof||read_error!=nil {break}
        if n==0 {continue}
        remaining := read_buffer[:n]
        for len(remaining) > 0 {
            if sync.atomic_load(&c.stop) { break session_loop }
            newline := strings.index_byte(string(remaining), '\n')
            segment_len := len(remaining) if newline < 0 else newline
            if len(frame^)+segment_len > REMOTE_MAX_FRAME_BYTES {
                failure = "Remote telemetry frame exceeds 16 MiB"
                error_used = 0
                break session_loop
            }
            // Copy contiguous input once; retain capacity across samples and
            // reconnects without reserving the maximum frame for every host.
            append(frame, ..remaining[:segment_len])
            if newline < 0 { break }
            remaining = remaining[newline+1:]
            if len(frame^) == 0 { continue }
            if bootstrap&&!mode_selected&&strings.has_prefix(string(frame^[:]),"task_master-mode ") {
                mode:=strings.trim_space(string(frame^[:])[len("task_master-mode "):])
                if mode!="installed"&&mode!="temporary" {failure="Unsupported or invalid telemetry collector mode";break session_loop}
                mode_selected=true
                sync.mutex_lock(&c.mutex)
                c.collector_mode_len=copy(c.collector_mode[:],mode)
                sync.mutex_unlock(&c.mutex)
                remote_connection_status(c,.Connecting,"Starting installed collector; verifying identity and telemetry" if mode=="installed" else "Transferring temporary collector; use Setup / fix for durable setup")
                when ODIN_OS==.Linux||ODIN_OS==.Darwin {
                    if mode=="installed" {transferred=len(binary)}
                } else when ODIN_OS==.Windows {
                    if mode=="installed"||len(binary)==0 {sync.atomic_store(&upload.done,true)}
                    else {
                        upload.worker=thread.create_and_start_with_poly_data(&upload,remote_upload_worker,name="SSH collector upload")
                        if upload.worker==nil {failure="Unable to start the remote collector transfer";break session_loop}
                    }
                }
                clear(frame)
                continue
            }
            valid := remote_decode(frame^[:], scratch^, require_controls=true)
            free_all(context.temp_allocator)
            if !valid {
                failure = fmt.tprintf("Unsupported or invalid telemetry (expected protocol version %d)", REMOTE_PROTOCOL_VERSION)
                error_used = 0
                break session_loop
            }
            sample:=scratch^
            last_frame=time.tick_now()
            platform:Remote_Platform=.Windows if sample.platform=="windows" else .Darwin if sample.platform=="darwin" else .Linux
            architecture:=string(sample.remote_architecture[:sample.remote_architecture_len])
            sync.mutex_lock(&c.mutex)
            mismatch:=c.platform!=platform||remote_architecture_name(string(c.architecture[:c.architecture_len]))!=remote_architecture_name(architecture)
            if mismatch {c.invalidate_platform=true}
            sync.mutex_unlock(&c.mutex)
            if mismatch {failure="Collector platform changed; retry to detect its OS and architecture again";error_used=0;break session_loop}
            arrived:=time.tick_now()
            if !primed {
                // The collector's initial frame establishes counter baselines;
                // CPU/process/I/O rates have not measured an interval yet.
                // Handle this here so installed collectors benefit as well.
                primed=true
                session_id=sample.remote_session_id;last_sequence=sample.remote_sequence
                source_start=sample.remote_source_seconds;last_source=source_start
                source_anchor=arrived
                clear(frame)
                continue
            }
            if sample.remote_session_id!=session_id||sample.remote_sequence<=last_sequence||sample.remote_source_seconds<last_source {
                failure="Unsupported or invalid telemetry session or sequence; install the matching collector"
                error_used=0
                break session_loop
            }
            source_time:=time.tick_add(source_anchor,time.Duration((sample.remote_source_seconds-source_start)*f64(time.Second)))
            // Monotonic source time keeps buffered frames from looking fresh or
            // being plotted at their burst arrival time. A better observed
            // transport offset also corrects source/desktop clock drift.
            ahead:=time.tick_diff(arrived,source_time)
            if ahead>0 {source_anchor=time.tick_add(source_anchor,-ahead);source_time=arrived}
            sample_break:=Remote_Sample_Break.None if live else .Session
            sync.mutex_lock(&c.mutex)
            expected_interval:=c.interval
            sync.mutex_unlock(&c.mutex)
            if live&&(sample.remote_sequence!=last_sequence+1||sample.remote_source_seconds-last_source>max(3,2*expected_interval+1)) {sample_break=.Dropped}
            last_sequence=sample.remote_sequence;last_source=sample.remote_source_seconds
            sync.mutex_lock(&c.mutex)
            next:^Metrics
            if c.sample_count==len(c.samples) {
                // Keep the latest telemetry if rendering stalls for several
                // seconds; normal 10 Hz sampling is drained every GUI frame.
                next=c.samples[c.sample_start]
                c.sample_start=(c.sample_start+1)%len(c.samples)
                c.sample_count-=1
                c.sample_breaks[c.sample_start]=.Dropped
            } else if len(c.recycled)>0 {
                next=pop(&c.recycled)
            } else {next=new(Metrics)}
            index:=(c.sample_start+c.sample_count)%len(c.samples)
            c.samples[index]=scratch^
            c.sample_times[index]=source_time
            c.sample_breaks[index]=sample_break
            c.sample_count+=1
            scratch^=next
            c.status = .Live
            c.message_len = copy(c.message[:],remote_live_message(sample))
            c.received = source_time
            sync.mutex_unlock(&c.mutex)
            app_wake()
            live = true
            clear(frame)
        }
    }
    if !sync.atomic_load(&c.stop) {
        diagnostic := strings.trim_space(string(error_buffer[:error_used]))
        if len(diagnostic) > 0 { failure=diagnostic }
        else if len(frame^) > 0 && failure == "SSH connection closed" { failure="Remote collector stopped during a telemetry frame" }
        if needs_helper!=nil&&!live&&strings.contains(failure,"No compatible installed collector or embedded payload") {
            needs_helper^=true
            return false
        }
        remote_connection_failed(c, failure)
    }
    return live
}

remote_connection_worker :: proc(c: ^Remote_Connection) {
    bootstrap:=c.collector==DEFAULT_COLLECTOR
    frame := make([dynamic]u8, 0, 65536)
    defer delete(frame)
    scratch := new(Metrics)
    defer {metrics_destroy(scratch);free(scratch)}
    delay := 1
    for !sync.atomic_load(&c.stop) {
        sync.atomic_store(&c.retry_requested,false)
        remote_connection_status(c, .Connecting, "Connecting through SSH; checking access")
        was_live:=false
        sync.mutex_lock(&c.mutex)
        if c.invalidate_platform {c.platform=.Unknown;c.architecture_len=0;c.invalidate_platform=false}
        platform:=c.platform
        architecture:=strings.clone(string(c.architecture[:c.architecture_len]),context.temp_allocator)
        sync.mutex_unlock(&c.mutex)
        detected:=platform!=.Unknown
        if !detected {platform,architecture,detected=remote_detect_platform(c)}
        if detected {
            sync.mutex_lock(&c.mutex)
            c.platform=platform
            c.architecture_len=copy(c.architecture[:],architecture)
            sync.mutex_unlock(&c.mutex)
            binary:[]u8
            command:string
            if bootstrap {
                binary=remote_collector_payload(platform,architecture)
                // An installed matching collector also works in a development
                // build with no embedded payload for this remote architecture.
                command=remote_collector_bootstrap_command(platform,architecture,len(binary),telemetry=true)
            } else if platform==.Windows {command=remote_windows_collector_command(c.collector)}
            else {command=remote_collector_command(c.collector)}
            if command!="" {
                // First let the remote use a compatible installed collector.
                // A missing foreign payload must not introduce an Internet
                // requirement for already-installed or offline remote hosts.
                needs_helper:=false
                was_live=remote_connection_session(c,command,&frame,&scratch,binary,negotiated_bootstrap=bootstrap,needs_helper=&needs_helper if bootstrap&&len(binary)==0 else nil)
                delete(command)
                if needs_helper&&!sync.atomic_load(&c.stop)&&!sync.atomic_load(&c.retry_requested) {
                    sync.mutex_lock(&c.mutex)
                    architecture=strings.clone(string(c.architecture[:c.architecture_len]),context.temp_allocator)
                    sync.mutex_unlock(&c.mutex)
                    remote_connection_status(c,.Connecting,"Downloading and verifying the matching remote collector")
                    error:string
                    binary,error=remote_helper_collector(platform,architecture,&c.stop)
                    if error!="" {remote_connection_failed(c,error)}
                    else {
                        command=remote_collector_bootstrap_command(platform,architecture,len(binary),telemetry=true)
                        if command!="" {was_live=remote_connection_session(c,command,&frame,&scratch,binary,negotiated_bootstrap=true);delete(command)}
                        delete(binary)
                    }
                }
            }
        }
        free_all(context.temp_allocator)
        if sync.atomic_load(&c.stop) { break }
        if was_live { delay=1 }
        started := time.tick_now()
        for !sync.atomic_load(&c.stop)&&!sync.atomic_load(&c.retry_requested) {
            sync.mutex_lock(&c.mutex)
            needs_setup:=c.status==.Setup_Required
            sync.mutex_unlock(&c.mutex)
            if !needs_setup&&time.tick_since(started)>=time.Duration(delay)*time.Second {break}
            time.sleep(100*time.Millisecond)
        }
        delay = min(delay*2, 30)
    }
}

remote_connection_platform :: proc(c:^Remote_Connection)->Remote_Platform {
    if c==nil {return .Unknown}
    sync.mutex_lock(&c.mutex)
    platform:=c.platform
    sync.mutex_unlock(&c.mutex)
    return platform
}

remote_query :: proc(c:^Remote_Connection,command:string)->(output,diagnostic:string,success:bool) {
    s,err:=remote_ssh_start(c.host,command,c.port,auth_probe=true)
    if err!=nil {return "",fmt.aprintf("Unable to start SSH: %v",err),false}
    defer remote_ssh_close(&s)
    os.close(s.input);s.input=nil
    buffer:[4096]u8
    scratch:[1024]u8
    errors:[2048]u8
    error_used:=0
    used:=0
    stdout_open,stderr_open,reaped,passed:=true,true,false,false
    started:=time.tick_now()
    for !sync.atomic_load(&c.stop)&&!sync.atomic_load(&c.retry_requested)&&time.tick_since(started)<10*time.Second {
        if reaped&&!stdout_open&&!stderr_open {
            return strings.clone(strings.trim_space(string(buffer[:used]))),strings.clone(strings.trim_space(string(errors[:error_used]))),passed
        }
        ready,poll_error:=remote_ssh_poll(&s,stdout_open,stderr_open,false,100)
        if poll_error!=nil {return "",fmt.aprintf("Unable to read SSH: %v",poll_error),false}
        for i in 0..<2 {
            if !ready[i] {continue}
            file:=s.output if i==0 else s.errors
            count,eof,read_error:=remote_pipe_read(file,scratch[:])
            if read_error!=nil {return "",fmt.aprintf("Unable to read SSH: %v",read_error),false}
            if i==0&&count>0 {
                if used+count>len(buffer) {return "",strings.clone("SSH platform query produced too much output"),false}
                used+=copy(buffer[used:],scratch[:count])
            }
            if i==1&&count>0 {remote_error_append(errors[:],&error_used,scratch[:count])}
            if eof {if i==0 {stdout_open=false} else {stderr_open=false}}
        }
        if !reaped {
            state,wait_error:=os.process_wait(s.process,0)
            if wait_error!=.Timeout {
                s.started=false;reaped=true
                passed=wait_error==nil&&state.exited&&state.exit_code==0
                if wait_error!=nil {return "",fmt.aprintf("Unable to wait for SSH: %v",wait_error),false}
            }
        }
    }
    return "",strings.clone("SSH retry requested" if sync.atomic_load(&c.retry_requested) else "SSH platform query timed out"),false
}

remote_detect_platform :: proc(c:^Remote_Connection)->(platform:Remote_Platform,architecture:string,success:bool) {
    // Encoded PowerShell works with both cmd.exe and PowerShell SSH shells.
    // POSIX hosts' missing powershell.exe is a bounded probe, never a shell mutation.
    windows_command:=remote_powershell_command(`if ([Environment]::OSVersion.Platform -ne 'Win32NT') {exit 1}; $arch=$env:PROCESSOR_ARCHITEW6432; if (-not $arch) {$arch=$env:PROCESSOR_ARCHITECTURE}; [Console]::WriteLine('task_master-windows-'+$arch)`)
    windows,windows_diagnostic,windows_ok:=remote_query(c,windows_command)
    delete(windows_command)
    defer delete(windows)
    defer delete(windows_diagnostic)
    if windows_ok&&strings.has_prefix(windows,"task_master-windows-") {
        return .Windows,strings.clone(windows[len("task_master-windows-"):],context.temp_allocator),true
    }
    if remote_ssh_access_failure(windows_diagnostic) {remote_connection_failed(c,windows_diagnostic);return .Unknown,"",false}
    if sync.atomic_load(&c.stop)||sync.atomic_load(&c.retry_requested) {return .Unknown,"",false}
    unix,unix_diagnostic,unix_ok:=remote_query(c,"uname -s; uname -m")
    defer delete(unix)
    defer delete(unix_diagnostic)
    if unix_ok&&strings.has_prefix(unix,"Linux\n") {return .Linux,strings.clone(strings.trim_space(unix[6:]),context.temp_allocator),true}
    if unix_ok&&strings.has_prefix(unix,"Darwin\n") {return .Darwin,strings.clone(strings.trim_space(unix[7:]),context.temp_allocator),true}
    failure:="Unable to identify a supported remote OS; SSH must allow command execution on Linux, macOS or Windows 11+."
    if unix_diagnostic!="" {failure=unix_diagnostic}
    remote_connection_failed(c,failure)
    return .Unknown,"",false
}

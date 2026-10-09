package main

import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/info"
import "core:thread"
import "core:time"

SSH_Login_Candidate :: struct {
    host, name, collector: string,
    port: u16,
    rank: int,
    complete, passed, delivered: bool,
    persistent, automatic, select_after: bool,
}

SSH_Login_Discovery :: struct {
    mutex: sync.Mutex,
    candidates: []SSH_Login_Candidate,
    workers: []^thread.Thread,
    next_candidate, completed: int,
    stop: bool, // Accessed atomically, including while a child process is running.
}

SSH_LOGIN_MARKER :: "task_master-login-ok\n"
SSH_LOGIN_COMMAND :: "echo task_master-login-ok"
SSH_LOGIN_MAX_OUTPUT :: 4096
SSH_LOGIN_TIMEOUT :: 8*time.Second

// Discovery is finite: workers probe each candidate once and then exit.
// All candidate storage belongs to the discovery object, independent of UI buffers.
ssh_login_discovery_create :: proc(candidates: []SSH_Login_Candidate) -> ^SSH_Login_Discovery {
    d := new(SSH_Login_Discovery)
    d.candidates = make([]SSH_Login_Candidate, len(candidates))
    for candidate, i in candidates {
        d.candidates[i] = {
            host=strings.clone(candidate.host), name=strings.clone(candidate.name),
            collector=strings.clone(candidate.collector), port=candidate.port, rank=candidate.rank,
            persistent=candidate.persistent, automatic=candidate.automatic, select_after=candidate.select_after,
        }
    }
    _, logical, _ := info.cpu_core_count()
    count := min(len(candidates), min(max(logical, 1), 8))
    d.workers = make([]^thread.Thread, count)
    active := 0
    for &worker in d.workers {
        worker = thread.create_and_start_with_poly_data(d, ssh_login_discovery_worker, name="SSH login probe")
        if worker != nil { active += 1 }
    }
    if count > 0 && active == 0 {
        for &candidate in d.candidates { candidate.complete=true }
        d.next_candidate = len(d.candidates)
        d.completed = len(d.candidates)
    }
    return d
}

ssh_login_discovery_destroy :: proc(d: ^SSH_Login_Discovery) {
    if d == nil { return }
    sync.atomic_store(&d.stop, true)
    for worker in d.workers {
        if worker == nil { continue }
        thread.join(worker)
        thread.destroy(worker)
    }
    for candidate in d.candidates {
        delete(candidate.host)
        delete(candidate.name)
        delete(candidate.collector)
    }
    delete(d.workers)
    delete(d.candidates)
    free(d)
}

// A successful authentication must also execute our command. For example, an
// SSH key accepted by a Git-only service does not demonstrate machine access.
ssh_login_probe :: proc(d: ^SSH_Login_Discovery, candidate: SSH_Login_Candidate) -> bool {
    started := time.tick_now()
    s, err := remote_ssh_start(candidate.host, SSH_LOGIN_COMMAND, candidate.port, auth_probe=true)
    if err != nil { return false }
    defer remote_ssh_close(&s)
    // This command needs no input. EOF also prevents a remote wrapper awaiting input.
    os.close(s.input)
    s.input = nil
    output: [SSH_LOGIN_MAX_OUTPUT]u8
    scratch: [1024]u8
    used, observed := 0, 0
    stdout_open, stderr_open := true, true
    reaped, success := false, false
    for {
        if sync.atomic_load(&d.stop) { return false }
        remaining := SSH_LOGIN_TIMEOUT-time.tick_since(started)
        if remaining <= 0 { return false }
        if reaped && !stdout_open && !stderr_open {
            return success && strings.trim_space(string(output[:used])) == strings.trim_space(SSH_LOGIN_MARKER)
        }
        timeout:=int(min(100,max(0,remaining/time.Millisecond)))
        ready,poll_error:=remote_ssh_poll(&s,stdout_open,stderr_open,false,timeout)
        if poll_error!=nil {return false}
        for i in 0..<2 {
            if !ready[i] {continue}
            file:=s.output if i==0 else s.errors
            n,eof,read_error:=remote_pipe_read(file,scratch[:])
            if n>0 {
                observed+=n
                if observed>SSH_LOGIN_MAX_OUTPUT {return false}
                if i==0 {used+=copy(output[used:],scratch[:n])}
            }
            if read_error!=nil {return false}
            if eof {if i==0 {stdout_open=false} else {stderr_open=false}}
        }
        if !reaped {
            state, wait_error := os.process_wait(s.process, 0)
            if wait_error != .Timeout {
                // A completed wait closes the pidfd. Never wait/kill it again in cleanup.
                s.started = false
                reaped = true
                success = wait_error == nil && state.exited && state.exit_code == 0
                if wait_error != nil { return false }
            }
        }
    }
}

ssh_login_discovery_worker :: proc(d: ^SSH_Login_Discovery) {
    for !sync.atomic_load(&d.stop) {
        sync.mutex_lock(&d.mutex)
        if d.next_candidate >= len(d.candidates) || sync.atomic_load(&d.stop) {
            sync.mutex_unlock(&d.mutex)
            return
        }
        index := d.next_candidate
        d.next_candidate += 1
        candidate := d.candidates[index]
        sync.mutex_unlock(&d.mutex)
        passed := ssh_login_probe(d, candidate)
        free_all(context.temp_allocator)
        if sync.atomic_load(&d.stop) { return }
        sync.mutex_lock(&d.mutex)
        d.candidates[index].passed = passed
        d.candidates[index].complete = true
        d.completed += 1
        sync.mutex_unlock(&d.mutex)
        app_wake()
    }
}

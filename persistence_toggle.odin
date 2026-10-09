package main

import "core:sync"
import "core:thread"
import "core:time"
import glfw "vendor:glfw"

// A change owns only immutable command input and detached resources. It never
// accesses live App/Machine state from a worker.
Persistence_Change :: struct {
    desired, refresh, reconnect, cleanup, success, done: bool,
    io_session: f64,
    worker: ^thread.Thread,
    error: [512]u8,
    error_len: int,
    connections: [dynamic]^Remote_Connection,
    reader, live_reader: ^Persistence_Reader,
}

persistence_change_worker :: proc(change:^Persistence_Change) {
    if change.cleanup {
        for connection in change.connections {remote_connection_destroy(connection)}
        if change.reader!=nil {persistence_reader_destroy(change.reader)}
        if change.live_reader!=nil {persistence_reader_destroy(change.live_reader)}
    } else {
        scratch:=new(App)
        change.success=persistence_service_set(scratch,change.desired,refresh_only=change.refresh,force_restart=change.reconnect)
        change.io_session=scratch.persistence_io_session
        change.error=scratch.persistence_error;change.error_len=scratch.persistence_error_len
        free(scratch)
    }
    free_all(context.temp_allocator)
    sync.atomic_store(&change.done,true)
    app_wake()
}

persistence_change_start :: proc(a:^App,refresh:bool=false,reconnect:bool=false)->bool {
    if a.persistence_change!=nil {return false}
    change:=new(Persistence_Change)
    change.desired=true if refresh else !a.persistence_enabled
    change.refresh=refresh;change.reconnect=reconnect
    change.worker=thread.create_and_start_with_poly_data(change,persistence_change_worker,name="Persistence change")
    if change.worker==nil {
        free(change);persistence_error_set(a,"Could not start the persistence worker.");return false
    }
    a.persistence_change=change;a.persistence_error_len=0;a.dirty=true
    return true
}

// An install can finish while a startup runtime refresh is still running.
// Queue the reconnect so that successful installation cannot lose this request.
persistence_reconnect :: proc(a:^App) {
    a.persistence_reconnect_pending=true
    a.dirty=true
}

persistence_change_release :: proc(change:^Persistence_Change) {
    if change.worker!=nil {thread.join(change.worker);thread.destroy(change.worker)}
    delete(change.connections)
    free(change)
}

persistence_change_poll :: proc(a:^App) {
    change:=a.persistence_change
    if change==nil {
        if a.persistence_reconnect_pending {
            if !a.persistence_enabled {a.persistence_reconnect_pending=false}
            else if persistence_change_start(a,refresh=true,reconnect=true) {a.persistence_reconnect_pending=false}
        }
        return
    }
    if !sync.atomic_load(&change.done) {return}
    if change.worker!=nil {thread.join(change.worker);thread.destroy(change.worker);change.worker=nil}
    if change.cleanup||change.refresh||!change.success {
        if change.reconnect {
            for m in a.machines {
                if !m.setup_verifying {continue}
                if change.success {m.setup_check_after=time.tick_now()}
                else {m.setup_verifying=false;m.setup_failed=true;machine_error_set(a,string(change.error[:change.error_len]))}
            }
        }
        if !change.cleanup&&!change.success {persistence_error_set(a,string(change.error[:change.error_len]))}
        a.persistence_change=nil;persistence_change_release(change);a.dirty=true
        return
    }
    a.persistence_enabled=change.desired;a.persistence_error_len=0
    a.persistence_last_poll=-1e9
    if change.desired {
        a.persistence_io_session=change.io_session
        local:=a.local_machine.state
        if !persistence_local_captured {
            persistence_local_nvml=local.metrics.nvml_available
            persistence_local_gpu_count=local.metrics.gpu_count
            persistence_local_power_source=local.metrics.cpu_power_source
            persistence_local_captured=true
        }
        for m in a.machines[:] {
            m.state.io_summary=IO_Summary{started_at=change.io_session}
            if m!=a.local_machine&&!m.persistent {continue}
            if m.connection!=nil {
                sync.atomic_store(&m.connection.stop,true)
                append(&change.connections,m.connection);m.connection=nil
            }
            m.persistence_stamp=0
            m.persistence_live_stamp=0
        }
        persistence_reader_start(a)
    } else {
        change.reader=a.persistence_reader;a.persistence_reader=nil
        change.live_reader=a.persistence_live_reader;a.persistence_live_reader=nil
        local:=a.local_machine
        if persistence_local_captured {
            local.state.metrics.nvml_available=persistence_local_nvml
            local.state.metrics.gpu_count=persistence_local_gpu_count
            local.state.metrics.cpu_power_source=persistence_local_power_source
        }
        // Prime on the next sampling pass; keep the displayed history intact.
        persistence_local_needs_prime=true
        local.state.last_sample=glfw.GetTime()
        local.status=.Live;local.message_len=0;local.persistence_stamp=0;local.persistence_live_stamp=0
        persistence_local_captured=false
        for m in a.machines[:] {
            if m==local||!m.persistent {continue}
            m.persistence_stamp=0;m.persistence_live_stamp=0;machine_connect(a,m)
        }
    }
    a.dirty=true
    if len(change.connections)==0&&change.reader==nil&&change.live_reader==nil {
        a.persistence_change=nil;persistence_change_release(change)
        return
    }
    change.cleanup=true
    sync.atomic_store(&change.done,false)
    change.worker=thread.create_and_start_with_poly_data(change,persistence_change_worker,name="Persistence cleanup")
    if change.worker==nil {
        // Resource exhaustion: finish the already-authorized cleanup safely.
        persistence_change_worker(change)
    }
}

persistence_change_destroy :: proc(a:^App) {
    if a.persistence_change==nil {return}
    // Shutdown waits for authorized commands while GLFW and worker resources
    // are still alive; steady-state rendering never joins a running worker.
    persistence_change_release(a.persistence_change)
    a.persistence_change=nil
}

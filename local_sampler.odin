package main

import "core:sync"
import "core:thread"
import "core:time"

// Only the worker owns the hardware counters, process scratch storage and
// driver handles. The application receives display snapshots, as with SSH.
Local_Sampler :: struct {
    mutex: sync.Mutex,
    changed: sync.Cond,
    metrics: Metrics,
    samples: [32]^Metrics,
    sample_times: [32]time.Tick,
    sample_intervals: [32]f64,
    sample_breaks: [32]bool,
    sample_start, sample_count: int,
    recycled: [dynamic]^Metrics,
    interval: f64,
    enabled, paused, prime: bool,
    generation, revision: u64,
    worker: ^thread.Thread,
    stop: bool,
}

local_sampler_start :: proc(a:^App)->bool {
    local:=a.local_machine
    sampler:=new(Local_Sampler)
    sampler.worker=thread.create(local_sampler_entry,name="Local telemetry")
    if sampler.worker==nil {free(sampler);return false}
    sampler.worker.data=sampler
    sampler.interval=a.interval;sampler.enabled=true;sampler.paused=local.state.paused
    // Move ownership exactly once, then immediately restore display storage.
    source:=&local.state.metrics
    hostname_len,cpu_model_len:=len(source.hostname),len(source.cpu_model)
    sampler.metrics=source^
    sampler.metrics.hostname=string(sampler.metrics._hostname[:hostname_len])
    sampler.metrics.cpu_model=string(sampler.metrics._cpu_model[:cpu_model_len])
    source^={}
    metrics_display_copy(source,&sampler.metrics)
    local.local_sampler=sampler
    thread.start(sampler.worker)
    return true
}

local_sampler_clear_locked :: proc(sampler:^Local_Sampler) {
    for i in 0..<sampler.sample_count {
        index:=(sampler.sample_start+i)%len(sampler.samples)
        append(&sampler.recycled,sampler.samples[index]);sampler.samples[index]=nil
    }
    sampler.sample_start=0;sampler.sample_count=0
}

local_sampler_configure :: proc(sampler:^Local_Sampler,enabled,paused:bool,interval:f64) {
    if sampler==nil {return}
    sync.mutex_lock(&sampler.mutex)
    changed:=sampler.enabled!=enabled||sampler.paused!=paused||sampler.interval!=clamp(interval,0.1,10)
    if sampler.enabled!=enabled||sampler.paused!=paused {
        // Reject in-flight and buffered observations when authority or pause
        // changes; resuming starts a fresh rate baseline and leaves a gap.
        sampler.generation+=1
        local_sampler_clear_locked(sampler)
        if enabled&&!paused {sampler.prime=true}
    }
    sampler.enabled=enabled;sampler.paused=paused;sampler.interval=clamp(interval,0.1,10)
    if changed {sampler.revision+=1;sync.cond_signal(&sampler.changed)}
    sync.mutex_unlock(&sampler.mutex)
}

local_sampler_take :: proc(sampler:^Local_Sampler,destination:^Metrics)->(ok:bool,sampled:time.Tick,interval:f64,gap:bool) {
    if sampler==nil {return}
    if !sync.mutex_try_lock(&sampler.mutex) {return}
    if sampler.sample_count==0 {sync.mutex_unlock(&sampler.mutex);return}
    index:=sampler.sample_start
    snapshot:=sampler.samples[index]
    sampled=sampler.sample_times[index];interval=sampler.sample_intervals[index];gap=sampler.sample_breaks[index]
    sampler.samples[index]=nil
    sampler.sample_start=(index+1)%len(sampler.samples);sampler.sample_count-=1
    sync.mutex_unlock(&sampler.mutex)
    metrics_display_copy(destination,snapshot)
    sync.mutex_lock(&sampler.mutex)
    append(&sampler.recycled,snapshot)
    sync.mutex_unlock(&sampler.mutex)
    ok=true
    return
}

local_sampler_entry :: proc(worker:^thread.Thread) {
    local_sampler_worker(cast(^Local_Sampler)worker.data)
}

local_sampler_worker :: proc(sampler:^Local_Sampler) {
    defer metrics_destroy(&sampler.metrics)
    defer free_all(context.temp_allocator)
    m:=&sampler.metrics
    for !sync.atomic_load(&sampler.stop) {
        sync.mutex_lock(&sampler.mutex)
        enabled,paused,prime,interval,generation,revision:=sampler.enabled,sampler.paused,sampler.prime,sampler.interval,sampler.generation,sampler.revision
        sampler.prime=false
        sync.mutex_unlock(&sampler.mutex)
        if !enabled {
            if m._gpu_backends_active {metrics_suspend_devices(m)}
        } else if !paused {
            if prime||!m._gpu_backends_active {
                if !m._gpu_backends_active {metrics_init_devices(m)}
                else {metrics_sample(m,0)}
                // Baselines are private; only rate-bearing observations enter
                // history after the requested interval has elapsed.
            } else if time.duration_seconds(time.tick_since(m._sample_started))>=interval {
                metrics_sample(m,time.duration_seconds(time.tick_since(m._sample_started)))
                sync.mutex_lock(&sampler.mutex)
                snapshot:^Metrics
                if len(sampler.recycled)>0 {snapshot=pop(&sampler.recycled)}
                sync.mutex_unlock(&sampler.mutex)
                if snapshot==nil {snapshot=new(Metrics)}
                metrics_display_copy(snapshot,m)
                sync.mutex_lock(&sampler.mutex)
                if sampler.generation==generation&&sampler.enabled&&!sampler.paused&&!sync.atomic_load(&sampler.stop) {
                    if sampler.sample_count==len(sampler.samples) {
                        old:=sampler.samples[sampler.sample_start]
                        append(&sampler.recycled,old)
                        sampler.samples[sampler.sample_start]=nil
                        sampler.sample_start=(sampler.sample_start+1)%len(sampler.samples);sampler.sample_count-=1
                        sampler.sample_breaks[sampler.sample_start]=true
                    }
                    index:=(sampler.sample_start+sampler.sample_count)%len(sampler.samples)
                    sampler.samples[index]=snapshot;sampler.sample_times[index]=m._sample_started
                    sampler.sample_intervals[index]=interval;sampler.sample_breaks[index]=false
                    sampler.sample_count+=1
                    sync.mutex_unlock(&sampler.mutex)
                    app_wake()
                } else {
                    append(&sampler.recycled,snapshot)
                    sync.mutex_unlock(&sampler.mutex)
                }
            }
        }
        free_all(context.temp_allocator)
        sync.mutex_lock(&sampler.mutex)
        if sampler.revision==revision&&!sync.atomic_load(&sampler.stop) {
            if !enabled||paused {sync.cond_wait(&sampler.changed,&sampler.mutex)}
            else {
                remaining:=interval-time.duration_seconds(time.tick_since(m._sample_started))
                if remaining>0 {_=sync.cond_wait_with_timeout(&sampler.changed,&sampler.mutex,time.Duration(remaining*1e9))}
            }
        }
        sync.mutex_unlock(&sampler.mutex)
    }
}

local_sampler_stop :: proc(sampler:^Local_Sampler) {
    if sampler==nil||sampler.worker==nil {return}
    sync.mutex_lock(&sampler.mutex)
    sync.atomic_store(&sampler.stop,true)
    sync.cond_signal(&sampler.changed)
    sync.mutex_unlock(&sampler.mutex)
    thread.join(sampler.worker);thread.destroy(sampler.worker)
    sampler.worker=nil
}

local_sampler_destroy :: proc(sampler:^Local_Sampler) {
    if sampler==nil {return}
    local_sampler_stop(sampler)
    local_sampler_clear_locked(sampler)
    for snapshot in sampler.recycled {metrics_destroy(snapshot);free(snapshot)}
    delete(sampler.recycled)
    free(sampler)
}

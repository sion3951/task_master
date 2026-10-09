package main

import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

// The worker owns cache files and JSON allocations. The UI exchanges small
// identities and transfers ownership of completed buffers under a short lock.
Persistence_Read_Request :: struct {
    host: [256]u8,
    host_len: int,
    collector: [1024]u8,
    collector_len: int,
    port: u16,
    applied_stamp: f64,
    paused: bool,
}
Persistence_Read_Result :: struct {
    request: Persistence_Read_Request,
    metrics: ^Metrics,
    history: [4][dynamic]f32,
    cpu_history: [dynamic]CPU_Sample,
    history_count: int,
    io_summary: IO_Summary,
    written_at, sampled_at: f64,
    status: Connection_Status,
    message: [512]u8,
    message_len: int,
    valid, has_sample, payload_ready: bool,
}
Persistence_Read_Job :: struct {
    request: Persistence_Read_Request,
    written_at: f64,
    valid: bool,
    size: i64,
    modified: time.Time,
    file_exists, inspected, wanted: bool,
}
Persistence_Read_Observation :: struct {
    request: Persistence_Read_Request,
    written_at, sampled_at: f64,
    status: Connection_Status,
    message: [512]u8,
    message_len: int,
    valid, has_sample: bool,
}
Persistence_History_Scratch :: struct {
    history: [4][HISTORY_CAPACITY]f32,
    cpu_history: [HISTORY_CAPACITY]CPU_Sample,
}
Persistence_Reader :: struct {
    worker: ^thread.Thread,
    mutex: sync.Mutex,
    stop: bool,
    live: bool,
    poll_seconds: f64,
    requests: [dynamic]Persistence_Read_Request,
    requests_pending: bool,
    ready, spare: [dynamic]^Persistence_Read_Result,
    // GUI-owned scratch keeps merging history off the stack and out of locks.
    history_scratch: ^Persistence_History_Scratch,
    observations: [dynamic]Persistence_Read_Observation,
    last_submit: f64,
    started_at: f64,
}

persistence_read_identity_equal :: proc(a,b: Persistence_Read_Request)->bool {
    return a.port==b.port&&a.host_len==b.host_len&&a.collector_len==b.collector_len&&
        a.host==b.host&&a.collector==b.collector
}
persistence_read_identity_matches :: proc(request: Persistence_Read_Request,m:^Machine)->bool {
    return request.port==m.port&&request.host_len==m.host_len&&request.collector_len==m.collector_len&&
        request.host==m.host&&request.collector==m.collector
}
persistence_read_result_create :: proc()->^Persistence_Read_Result {
    result:=new(Persistence_Read_Result)
    result.metrics=new(Metrics)
    return result
}
persistence_read_result_destroy :: proc(result:^Persistence_Read_Result) {
    if result==nil {return}
    metrics_destroy(result.metrics)
    free(result.metrics)
    delete(result.cpu_history)
    for kind in 0..<4 {delete(result.history[kind])}
    free(result)
}

persistence_read_result_resize :: proc(result:^Persistence_Read_Result,count:int) {
    resize(&result.cpu_history,count)
    for kind in 0..<4 {resize(&result.history[kind],count)}
    result.history_count=count
}

persistence_reader_stamp :: proc(m:^Machine,live:bool)->f64 {return m.persistence_live_stamp if live else m.persistence_stamp}
persistence_reader_stamp_set :: proc(m:^Machine,live:bool,stamp:f64) {
    if live {m.persistence_live_stamp=stamp} else {m.persistence_stamp=stamp}
}
persistence_reader_submit :: proc(a:^App,now:f64,live:bool=false) {
    reader:=a.persistence_live_reader if live else a.persistence_reader
    period:=min(1,a.interval) if live else 1
    if reader==nil||now-reader.last_submit<period||!sync.mutex_try_lock(&reader.mutex) {return}
    reader.poll_seconds=period
    clear(&reader.requests)
    for m in a.machines[:] {
        if m!=a.local_machine&&!m.persistent {continue}
        request:=Persistence_Read_Request{host=m.host,host_len=m.host_len,collector=m.collector,
            collector_len=m.collector_len,port=m.port,applied_stamp=persistence_reader_stamp(m,live),
            paused=m.state!=nil&&m.state.paused}
        append(&reader.requests,request)
    }
    reader.requests_pending=true
    reader.last_submit=now
    sync.mutex_unlock(&reader.mutex)
}
persistence_reader_start :: proc(a:^App) {
    if persistence_headless||!a.persistence_enabled {return}
    if a.persistence_reader==nil&&a.persistence_live_reader==nil {persistence_local_handoff_start(a)}
    persistence_reader_start_mode(a,false)
    persistence_reader_start_mode(a,true)
}
persistence_reader_start_mode :: proc(a:^App,live:bool) {
    existing:=a.persistence_live_reader if live else a.persistence_reader
    if existing!=nil {return}
    reader:=new(Persistence_Reader)
    reader.live=live;reader.poll_seconds=min(1,a.interval) if live else 1
    reader.last_submit=-1e9
    reader.started_at=persistence_wall_time()
    reader.history_scratch=new(Persistence_History_Scratch)
    // Initial startup may already have restored a cache before the first draw.
    // Carry that heartbeat forward while the first asynchronous read starts.
    for m in a.machines[:] {
        stamp:=persistence_reader_stamp(m,live)
        if (m!=a.local_machine&&!m.persistent)||stamp<=0 {continue}
        request:=Persistence_Read_Request{host=m.host,host_len=m.host_len,collector=m.collector,
            collector_len=m.collector_len,port=m.port}
        append(&reader.observations,Persistence_Read_Observation{request=request,written_at=stamp,
            status=m.status,message=m.message,message_len=m.message_len,valid=true,has_sample=m.has_sample,
            sampled_at=persistence_wall_time()-time.duration_seconds(time.tick_since(m.received))})
    }
    if live {a.persistence_live_reader=reader} else {a.persistence_reader=reader}
    persistence_reader_submit(a,0,live)
    reader.worker=thread.create_and_start_with_poly_data(reader,persistence_reader_worker,name="Persistence live reader" if live else "Persistence cache reader")
    if reader.worker==nil {
        if live {a.persistence_live_reader=nil} else {a.persistence_reader=nil}
        persistence_reader_destroy(reader)
        persistence_error_set(a,"Could not start the persistence cache reader.")
    }
}
persistence_reader_destroy :: proc(reader:^Persistence_Reader) {
    if reader==nil {return}
    sync.atomic_store(&reader.stop,true)
    if reader.worker!=nil {thread.join(reader.worker);thread.destroy(reader.worker)}
    for result in reader.ready[:] {persistence_read_result_destroy(result)}
    for result in reader.spare[:] {persistence_read_result_destroy(result)}
    delete(reader.requests);delete(reader.ready);delete(reader.spare);delete(reader.observations)
    free(reader.history_scratch)
    free(reader)
}
persistence_reader_stop :: proc(a:^App) {
    reader:=a.persistence_reader
    live_reader:=a.persistence_live_reader
    a.persistence_reader=nil
    a.persistence_live_reader=nil
    persistence_reader_destroy(reader)
    persistence_reader_destroy(live_reader)
}

persistence_reader_result_take :: proc(reader:^Persistence_Reader,request:Persistence_Read_Request)->^Persistence_Read_Result {
    result:^Persistence_Read_Result
    // Reuse an unconsumed publication or an idle buffer. Worker jobs retain
    // only file metadata; each completed snapshot has a single owner.
    sync.mutex_lock(&reader.mutex)
    for pending,i in reader.ready[:] {
        if persistence_read_identity_equal(pending.request,request) {
            result=pending;ordered_remove(&reader.ready,i);break
        }
    }
    if result==nil&&len(reader.spare)>0 {result=pop(&reader.spare)}
    sync.mutex_unlock(&reader.mutex)
    if result==nil {result=persistence_read_result_create()}
    result.request=request
    result.valid=false;result.has_sample=false;result.payload_ready=false;result.history_count=0
    return result
}
persistence_reader_publish :: proc(reader:^Persistence_Reader,result:^Persistence_Read_Result) {
    sync.mutex_lock(&reader.mutex)
    append(&reader.ready,result)
    sync.mutex_unlock(&reader.mutex)
    if !sync.atomic_load(&reader.stop) {app_wake()}
}

persistence_reader_worker :: proc(reader:^Persistence_Reader) {
    jobs: [dynamic]^Persistence_Read_Job
    defer {
        for job in jobs[:] {free(job)}
        delete(jobs)
    }
    requests: [dynamic]Persistence_Read_Request
    defer delete(requests)
    last_scan:=time.tick_add(time.tick_now(),-time.Second)
    poll_seconds:f64=1
    for !sync.atomic_load(&reader.stop) {
        changed:=false
        sync.mutex_lock(&reader.mutex)
        poll_seconds=reader.poll_seconds
        if reader.requests_pending {
            requests,reader.requests=reader.requests,requests
            reader.requests_pending=false
            changed=true
        }
        sync.mutex_unlock(&reader.mutex)
        if changed {
            for job in jobs[:] {job.wanted=false}
            for request in requests[:] {
                found:^Persistence_Read_Job
                for job in jobs[:] {if persistence_read_identity_equal(job.request,request) {found=job;break}}
                if found==nil {found=new(Persistence_Read_Job);append(&jobs,found)}
                found.request=request;found.wanted=true
            }
            for i:=len(jobs)-1;i>=0;i-=1 {
                if jobs[i].wanted {continue}
                free(jobs[i]);ordered_remove(&jobs,i)
            }
            // One fleet-wide spare is sufficient: jobs need no retained
            // snapshots once the UI has consumed the latest publications.
            sync.mutex_lock(&reader.mutex)
            retired: [dynamic]^Persistence_Read_Result
            for len(reader.spare)>1 {append(&retired,pop(&reader.spare))}
            sync.mutex_unlock(&reader.mutex)
            for result in retired[:] {persistence_read_result_destroy(result)}
            delete(retired)
        }
        if changed||time.tick_since(last_scan)>=time.Duration(poll_seconds*1e9) {
            last_scan=time.tick_now()
            for job in jobs[:] {
                if sync.atomic_load(&reader.stop) {break}
                // A synthetic identity keeps the worker independent of App and
                // Machine pointers, including machines deleted by the user.
                machine:=Machine{host=job.request.host,host_len=job.request.host_len,
                    collector=job.request.collector,collector_len=job.request.collector_len,port=job.request.port}
                info,err:=os.stat(persistence_cache_path(&machine,reader.live),context.temp_allocator)
                limit:=i64(PERSISTENCE_MAX_LIVE_CACHE_BYTES if reader.live else PERSISTENCE_MAX_CACHE_BYTES)
                exists:=err==nil&&info.type==.Regular&&info.size>0&&info.size<=limit
                file_changed:=!job.inspected||exists!=job.file_exists||exists&&(info.size!=job.size||info.modification_time!=job.modified)
                job.inspected=true;job.file_exists=exists
                if exists {job.size=info.size;job.modified=info.modification_time}
                if file_changed||job.valid&&!job.request.paused&&job.request.applied_stamp!=job.written_at {
                    result:=persistence_reader_result_take(reader,job.request)
                    if exists {
                        cache,ok:=persistence_cache_read(&machine,reader.live)
                        if ok&&cache.snapshot=="" {metrics_destroy(result.metrics);result.metrics^={}}
                        if ok&&(cache.snapshot==""||remote_decode(transmute([]u8)cache.snapshot,result.metrics)) {
                            result.valid=true;result.has_sample=cache.snapshot!=""
                            result.written_at=cache.written_at;result.sampled_at=cache.sampled_at
                            result.io_summary=cache.io_summary
                            result.status=cache.status;result.message_len=copy(result.message[:],cache.message)
                            if !job.request.paused {
                                result.payload_ready=true
                                persistence_read_result_resize(result,len(cache.samples))
                                for sample,i in cache.samples {
                                    destination:=&result.cpu_history[i]
                                    destination^=CPU_Sample{generation=sample.generation,timestamp=sample.timestamp,polling_seconds=sample.polling_seconds,
                                        continuity_recorded=sample.continuity_recorded,gap_before=sample.gap_before,
                                        lower=sample.lower,upper=sample.upper,threads=sample.threads,
                                        power_watts=sample.power_watts,frequency_mhz=sample.frequency_mhz,
                                        power_available=sample.power_available,frequency_available=sample.frequency_available,
                                        memory_total=sample.memory_total,memory_used=sample.memory_used,memory_available=sample.memory_available,
                                        memory_free=sample.memory_free,memory_cached=sample.memory_cached,memory_buffers=sample.memory_buffers,
                                        memory_breakdown_available=sample.memory_breakdown_available,
                                        memory_free_available=sample.memory_free_available,memory_cached_available=sample.memory_cached_available,memory_buffers_available=sample.memory_buffers_available,
                                        swap_total=sample.swap_total,swap_used=sample.swap_used,disk_read=sample.disk_read,disk_write=sample.disk_write,
                                        network_rx=sample.network_rx,network_tx=sample.network_tx,
                                        ram_available=sample.ram_available,rates_ready=sample.rates_ready,network_rates_ready=sample.network_rates_ready}
                                    copy(destination.cores[:],sample.cores);copy(destination.logical[:],sample.logical)
                                    destination.gpu=gpu_cache_sample(sample,result.metrics,cache.snapshot!=""&&sample.timestamp==cache.sampled_at)
                                    for kind in 0..<4 {result.history[kind][i]=sample.overview[kind]}
                                }
                                if cache.snapshot!=""&&result.history_count>0 {
                                    latest:=&result.cpu_history[result.history_count-1]
                                    if latest.timestamp==cache.sampled_at {history_memory_sample(latest,result.metrics)}
                                }
                            }
                        }
                    }
                    job.valid=result.valid;job.written_at=result.written_at
                    if !result.payload_ready {
                        // Invalid and paused caches need only a status update;
                        // resume reloads a payload before advancing its stamp.
                        metrics_destroy(result.metrics)
                        delete(result.cpu_history);result.cpu_history={}
                        for kind in 0..<4 {delete(result.history[kind]);result.history[kind]={}}
                    }
                    persistence_reader_publish(reader,result)
                }
                mem.free_all(context.temp_allocator)
            }
        }
        time.sleep(10*time.Millisecond if reader.live else 50*time.Millisecond)
    }
}

persistence_reader_history_apply :: proc(reader:^Persistence_Reader,state:^Machine_State,result:^Persistence_Read_Result) {
    // Cache merges can enrich fields at an unchanged timestamp as well as add
    // samples; filtered display data must be rebuilt from that updated source.
    if state.graph_smoothing!=nil {state.graph_smoothing.initialized=false}
    pinned:f64=-1
    gpu_pinned:f64=-1
    if state.gpu_pinned_slot>=0&&state.gpu_pinned_slot<HISTORY_CAPACITY {gpu_pinned=state.cpu_history[state.gpu_pinned_slot].timestamp}
    memory_pinned:f64=-1
    if state.cpu_pinned_slot>=0&&state.cpu_pinned_slot<HISTORY_CAPACITY {pinned=state.cpu_history[state.cpu_pinned_slot].timestamp}
    if state.memory_pinned_slot>=0&&state.memory_pinned_slot<HISTORY_CAPACITY {memory_pinned=state.cpu_history[state.memory_pinned_slot].timestamp}
    scratch:=reader.history_scratch
    first:=(state.history_next-state.history_count+HISTORY_CAPACITY)%HISTORY_CAPACITY
    old_index,new_index,count:=0,0,0
    latest:f64=0
    if state.history_count>0 {latest=state.cpu_history[(state.history_next+HISTORY_CAPACITY-1)%HISTORY_CAPACITY].timestamp}
    if result.history_count>0 {latest=max(latest,result.cpu_history[result.history_count-1].timestamp)}
    for old_index<state.history_count||new_index<result.history_count {
        slot:=(first+old_index)%HISTORY_CAPACITY
        use_new:=new_index<result.history_count&&(old_index>=state.history_count||result.cpu_history[new_index].timestamp<=state.cpu_history[slot].timestamp)
        timestamp:=state.cpu_history[slot].timestamp
        matched_old_slot:=-1
        if use_new {
            timestamp=result.cpu_history[new_index].timestamp
            if old_index<state.history_count&&timestamp==state.cpu_history[slot].timestamp {matched_old_slot=slot;old_index+=1}
        }
        keep:=timestamp>=latest-HISTORY_SECONDS
        if !keep {
            next_old:=old_index
            next_new:=new_index
            if use_new {next_new+=1} else {next_old+=1}
            has_next:=false
            next_timestamp:=latest
            if next_old<state.history_count {
                next_slot:=(first+next_old)%HISTORY_CAPACITY
                next_timestamp=min(next_timestamp,state.cpu_history[next_slot].timestamp);has_next=true
            }
            if next_new<result.history_count {
                next_timestamp=min(next_timestamp,result.cpu_history[next_new].timestamp);has_next=true
            }
            keep=has_next&&next_timestamp>=latest-HISTORY_SECONDS
        }
        if keep {
            destination:=count%HISTORY_CAPACITY
            if use_new {
                scratch.cpu_history[destination]=result.cpu_history[new_index]
                // An older service republishes percent-only history. Keep
                // sensors recovered from its matching snapshot on earlier polls.
                if matched_old_slot>=0&&result.cpu_history[new_index].gpu.legacy&&
                    state.cpu_history[matched_old_slot].gpu.recorded&&!state.cpu_history[matched_old_slot].gpu.legacy {
                    scratch.cpu_history[destination].gpu=state.cpu_history[matched_old_slot].gpu
                }
                if matched_old_slot>=0 {
                    if !scratch.cpu_history[destination].continuity_recorded {
                        scratch.cpu_history[destination].continuity_recorded=state.cpu_history[matched_old_slot].continuity_recorded
                        scratch.cpu_history[destination].gap_before=state.cpu_history[matched_old_slot].gap_before
                    }
                    if scratch.cpu_history[destination].polling_seconds==0 {
                        scratch.cpu_history[destination].polling_seconds=state.cpu_history[matched_old_slot].polling_seconds
                    }
                    history_memory_copy(&scratch.cpu_history[destination],&state.cpu_history[matched_old_slot])
                }
                for kind in 0..<4 {scratch.history[kind][destination]=result.history[kind][new_index]}
            } else {
                scratch.cpu_history[destination]=state.cpu_history[slot]
                for kind in 0..<4 {scratch.history[kind][destination]=state.history[kind][slot]}
            }
            if !use_new&&timestamp==state.history_handoff_timestamp&&count>0 {
                previous:=&scratch.cpu_history[(count-1)%HISTORY_CAPACITY]
                current:=&scratch.cpu_history[destination]
                current.gap_before=!history_handoff_contiguous(previous.timestamp,current.timestamp,previous.polling_seconds,current.polling_seconds)
            }
            count+=1
        }
        if use_new {new_index+=1} else {old_index+=1}
    }
    state.history_count=min(count,HISTORY_CAPACITY)
    state.history_next=count%HISTORY_CAPACITY
    state.cpu_pinned_slot=-1
    state.gpu_pinned_slot=-1
    state.memory_pinned_slot=-1
    for offset in 0..<state.history_count {
        slot:=(state.history_next-state.history_count+HISTORY_CAPACITY+offset)%HISTORY_CAPACITY
        state.cpu_history[slot]=scratch.cpu_history[slot]
        for kind in 0..<4 {state.history[kind][slot]=scratch.history[kind][slot]}
        if state.cpu_history[slot].timestamp==pinned {state.cpu_pinned_slot=slot}
        if state.cpu_history[slot].timestamp==gpu_pinned {state.gpu_pinned_slot=slot}
        if state.cpu_history[slot].timestamp==memory_pinned {state.memory_pinned_slot=slot}
    }
}
persistence_reader_poll :: proc(a:^App,now:f64) {
    persistence_reader_poll_mode(a,now,false)
    persistence_reader_poll_mode(a,now,true)
}
persistence_reader_poll_mode :: proc(a:^App,now:f64,live:bool) {
    reader:=a.persistence_live_reader if live else a.persistence_reader
    if reader==nil||persistence_headless||!a.persistence_enabled {return}
    persistence_reader_submit(a,now,live)
    status_owner:=live||a.persistence_live_reader==nil
    ready: [dynamic]^Persistence_Read_Result
    if sync.mutex_try_lock(&reader.mutex) {
        ready,reader.ready=reader.ready,ready
        sync.mutex_unlock(&reader.mutex)
    }
    wall:=persistence_wall_time()
    for result in ready[:] {
        for m in a.machines[:] {
            if !persistence_read_identity_matches(result.request,m)||(m!=a.local_machine&&!m.persistent) {continue}
            if m.state==nil {machine_connect(a,m)}
            observation:=Persistence_Read_Observation{request=result.request,written_at=result.written_at,
                sampled_at=result.sampled_at,status=result.status,message=result.message,message_len=result.message_len,
                valid=result.valid,has_sample=result.has_sample}
            observed:=false
            for &previous in reader.observations[:] {
                if persistence_read_identity_equal(previous.request,result.request) {previous=observation;observed=true;break}
            }
            if !observed {append(&reader.observations,observation)}
            if m==a.local_machine&&!persistence_local_captured {
                persistence_local_nvml=m.state.metrics.nvml_available
                persistence_local_gpu_count=m.state.metrics.gpu_count
                persistence_local_power_source=m.state.metrics.cpu_power_source
                persistence_local_captured=true
            }
            if result.valid {
                if !m.state.paused&&result.payload_ready&&result.written_at!=persistence_reader_stamp(m,live) {
                    latest:f64=0
                    if m.state.history_count>0 {latest=m.state.cpu_history[(m.state.history_next+HISTORY_CAPACITY-1)%HISTORY_CAPACITY].timestamp}
                    if result.has_sample&&persistence_local_snapshot_ready(a,m,result)&&(result.sampled_at>=latest||!m.has_sample) {
                        metrics_display_copy(&m.state.metrics,result.metrics)
                        m.state.process_revision+=1
                        m.has_sample=true
                    }
                    persistence_reader_history_apply(reader,m.state,result)
                    io_summary_apply(m.state,result.io_summary)
                    persistence_reader_stamp_set(m,live,result.written_at)
                    a.dirty=true
                }
                if status_owner {
                    if m.status!=result.status||m.message_len!=result.message_len||m.message!=result.message {a.dirty=true}
                    m.status=result.status;m.message=result.message;m.message_len=result.message_len
                    m.received=time.tick_add(time.tick_now(),-time.Duration(max(0,wall-result.sampled_at)*1e9))
                }
            } else if status_owner&&wall-reader.started_at>=persistence_freshness_seconds(a) {
                message:="Persistence service cache is unavailable or stale."
                if m.status!=.Disconnected||string(m.message[:m.message_len])!=message {a.dirty=true}
                m.status=.Disconnected;m.message_len=copy(m.message[:],message)
                persistence_reader_stamp_set(m,live,0)
            }
            break
        }
    }
    if len(ready)>0 {
        sync.mutex_lock(&reader.mutex)
        append(&reader.spare,..ready[:])
        sync.mutex_unlock(&reader.mutex)
    }
    delete(ready)
    for i:=len(reader.observations)-1;i>=0;i-=1 {
        keep:=false
        for m in a.machines[:] {
            if (m==a.local_machine||m.persistent)&&persistence_read_identity_matches(reader.observations[i].request,m) {keep=true;break}
        }
        if !keep {ordered_remove(&reader.observations,i)}
    }
    // Live publications own availability and display timestamps. The larger
    // history reader can finish later without replacing a newer live status.
    if !status_owner {return}
    local_current:=false
    for observation in reader.observations[:] {
        if persistence_read_identity_matches(observation.request,a.local_machine) {
            local_current=observation.valid&&observation.has_sample&&observation.written_at<=wall+2&&wall-observation.written_at<=persistence_freshness_seconds(a)
            break
        }
    }
    // A freshly started service can publish its first sample after the toggle
    // completes. Keep the current graphs and status during that short handoff.
    if !local_current&&wall-reader.started_at<persistence_freshness_seconds(a) {return}
    for m in a.machines[:] {
        if m!=a.local_machine&&!m.persistent {continue}
        observed:^Persistence_Read_Observation
        for &observation in reader.observations[:] {
            if persistence_read_identity_matches(observation.request,m) {observed=&observation;break}
        }
        healthy:=local_current&&observed!=nil&&observed.valid&&observed.written_at<=wall+2
        if !healthy {
            message:="Persistence service cache is unavailable or stale."
            if m.status!=.Disconnected||string(m.message[:m.message_len])!=message {a.dirty=true}
            m.status=.Disconnected;m.message_len=copy(m.message[:],message)
        } else {
            if m.status!=observed.status||m.message_len!=observed.message_len||m.message!=observed.message {a.dirty=true}
            m.status=observed.status;m.message=observed.message;m.message_len=observed.message_len
            m.received=time.tick_add(time.tick_now(),-time.Duration(max(0,wall-observed.sampled_at)*1e9))
        }
    }
    if !local_current {
        message:="Persistence service is starting or unavailable; cached graphs are retained."
        if string(a.persistence_error[:a.persistence_error_len])!=message {persistence_error_set(a,message)}
    } else if a.persistence_error_len>0 {a.persistence_error_len=0;a.dirty=true}
}

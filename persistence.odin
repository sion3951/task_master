package main

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

PERSISTENCE_CACHE_VERSION :: 1
// Five minutes at 10 Hz, including 256 physical/logical CPU histories, can
// exceed 32 MiB. Keep reads bounded without rejecting a complete graph cache.
PERSISTENCE_MAX_CACHE_BYTES :: 256*1024*1024
PERSISTENCE_MAX_LIVE_CACHE_BYTES :: 64*1024*1024
PERSISTENCE_LIVE_SAMPLES :: 22

// Display snapshots use the same validated wire format as SSH. Private sampler
// counters, GPU handles and file descriptors never enter the cache.
Persistence_Sample :: struct {
    generation: u64,
    timestamp: f64,
    polling_seconds: f64,
    continuity_recorded, gap_before: bool,
    lower, upper, threads, power_watts, frequency_mhz: f32,
    power_available, frequency_available: bool,
    memory_total, memory_used, memory_available, swap_total, swap_used: u64,
    memory_free, memory_cached, memory_buffers: u64,
    memory_breakdown_available: bool,
    memory_free_available, memory_cached_available, memory_buffers_available: bool,
    disk_read, disk_write, network_rx, network_tx: f64,
    ram_available, rates_ready, network_rates_ready: bool,
    cores: []CPU_Core_Sample,
    logical: []f32,
    overview: [4]f32,
    gpu: GPU_Sample,
}
Persistence_Cache :: struct {
    version: int,
    host, collector: string,
    port: u16,
    written_at, sampled_at: f64,
    status: Connection_Status,
    message: string,
    // This Odin JSON version has no Raw_Message; a JSON string retains the
    // complete remote_encode frame without introducing a second wire schema.
    snapshot: string,
    samples: []Persistence_Sample,
}
Persistence_Publication :: struct {
    sampled_at: f64,
    status: Connection_Status,
    message: [512]u8,
    message_len: int,
    exists: bool,
}

persistence_wall_time :: proc()->f64 {return f64(time.to_unix_nanoseconds(time.now()))/1e9}
persistence_freshness_seconds :: proc(a:^App)->f64 {return max(3,2*a.interval+1)}
persistence_recent_start :: proc(samples:[]Persistence_Sample,cutoff:f64)->int {
    first:=0
    for first<len(samples)&&samples[first].timestamp<cutoff {first+=1}
    // Keep the point before the axis boundary only when newer data exists.
    if first>0&&first<len(samples) {first-=1}
    return first
}
persistence_error_set :: proc(a:^App,message:string) {
    a.persistence_error_len=copy(a.persistence_error[:],message)
    a.dirty=true
}
persistence_directory :: proc()->string {
    base,err:=os.user_cache_dir(context.temp_allocator)
    if err!=nil {return ""}
    return fmt.tprintf("%s/task_master/persistence",base)
}
persistence_cache_path :: proc(m:^Machine,live:bool=false)->string {
    directory:=persistence_directory()
    if directory=="" {return ""}
    hash:u64=14695981039346656037
    for byte in m.host[:m.host_len] {hash=(hash~u64(byte))*1099511628211}
    hash=(hash~u64(m.port))*1099511628211
    for byte in m.collector[:m.collector_len] {hash=(hash~u64(byte))*1099511628211}
    return fmt.tprintf("%s/%016x%s.json",directory,hash,".live" if live else "")
}
persistence_atomic_write :: proc(path:string,data:[]u8,permissions:os.Permissions={.Read_User,.Write_User})->bool {
    if path=="" {return false}
    slash:=strings.last_index_byte(path,'/')
    if slash<0 {return false}
    err:=os.mkdir_all(path[:slash],{.Read_User,.Write_User,.Execute_User})
    if err!=nil&&err!=.Exist {return false}
    if !platform_private_path(path[:slash],true) {return false}
    temporary:=fmt.tprintf("%s.tmp-%d",path,os.get_pid())
    if os.write_entire_file(temporary,data,permissions)!=nil {_=os.remove(temporary);return false}
    if !platform_private_path(temporary,false)||!platform_atomic_replace(temporary,path) {_=os.remove(temporary);return false}
    return true
}

// Stream the outer JSON through a small buffer. Building another complete
// escaped snapshot in a growing temporary builder doubles publication memory.
persistence_cache_atomic_write :: proc(path:string,cache:Persistence_Cache,live:bool=false)->bool {
    if path=="" {return false}
    slash:=strings.last_index_byte(path,'/')
    if slash<0 {return false}
    err:=os.mkdir_all(path[:slash],{.Read_User,.Write_User,.Execute_User})
    if err!=nil&&err!=.Exist {return false}
    if !platform_private_path(path[:slash],true) {return false}
    temporary:=fmt.tprintf("%s.tmp-%d",path,os.get_pid())
    file,open_error:=os.open(temporary,{.Write,.Create,.Trunc},{.Read_User,.Write_User})
    if open_error!=nil {return false}
    published:=false
    defer if !published {_=os.remove(temporary)}
    buffer: [16*1024]u8
    writer: bufio.Writer
    bufio.writer_init_with_buf(&writer,os.to_writer(file),buffer[:])
    options:=json.Marshal_Options{}
    marshal_error:=json.marshal_to_writer(bufio.writer_to_writer(&writer),cache,&options)
    flush_error:=bufio.writer_flush(&writer)
    size,size_error:=os.file_size(file)
    sync_error:=os.flush(file)
    close_error:=os.close(file)
    limit:=i64(PERSISTENCE_MAX_LIVE_CACHE_BYTES if live else PERSISTENCE_MAX_CACHE_BYTES)
    if marshal_error!=nil||flush_error!=nil||size_error!=nil||close_error!=nil||sync_error!=nil||size>limit {return false}
    if !platform_private_path(temporary,false)||!platform_atomic_replace(temporary,path) {return false}
    published=true
    return true
}

persistence_toggle :: proc(a:^App)->bool {
    if a.renderer.window==nil {return persistence_service_set(a,!a.persistence_enabled)}
    return persistence_change_start(a)
}

persistence_cache_read :: proc(m:^Machine,live:bool=false)->(cache:Persistence_Cache,ok:bool) {
    path:=persistence_cache_path(m,live)
    if path=="" {return}
    file,err:=persistence_platform_cache_open(path)
    if err!=nil {return}
    defer os.close(file)
    size,size_error:=os.file_size(file)
    limit:=i64(PERSISTENCE_MAX_LIVE_CACHE_BYTES if live else PERSISTENCE_MAX_CACHE_BYTES)
    if size_error!=nil||size<=0||size>limit {return}
    data:=make([]u8,int(size),context.temp_allocator)
    used:=0
    for used<len(data) {
        count,read_error:=os.read(file,data[used:])
        if read_error!=nil||count<=0 {return}
        used+=count
    }
    if json.unmarshal(data,&cache,allocator=context.temp_allocator)!=nil {return}
    if cache.version!=PERSISTENCE_CACHE_VERSION||cache.host!=string(m.host[:m.host_len])||cache.port!=m.port||
        cache.collector!=string(m.collector[:m.collector_len])||len(cache.samples)>HISTORY_CAPACITY||
        live&&len(cache.samples)>PERSISTENCE_LIVE_SAMPLES||
        len(cache.snapshot)>REMOTE_MAX_FRAME_BYTES||len(cache.message)>len(m.message)||
        !remote_nonnegative(cache.written_at)||!remote_nonnegative(cache.sampled_at)||
        int(cache.status)<0||int(cache.status)>int(Connection_Status.Saved) {return}
    previous:f64=0
    for s in cache.samples {
        if !remote_nonnegative(s.timestamp)||s.timestamp<previous||len(s.cores)>256||len(s.logical)>256||
            !remote_nonnegative(s.polling_seconds)||s.polling_seconds>10||
            !remote_nonnegative(s.lower)||!remote_nonnegative(s.upper)||s.lower>s.upper||s.upper>100||
            !remote_nonnegative(s.threads)||s.threads>100||!remote_nonnegative(s.frequency_mhz)||!remote_nonnegative(s.power_watts)||
            !remote_nonnegative(s.disk_read)||!remote_nonnegative(s.disk_write)||s.memory_used>s.memory_total||
            !remote_nonnegative(s.network_rx)||!remote_nonnegative(s.network_tx)||
            s.memory_available>s.memory_total||s.swap_used>s.swap_total {return}
        if s.memory_free>s.memory_total||s.memory_cached>s.memory_total||s.memory_buffers>s.memory_total {return}
        for x in s.logical {if !remote_nonnegative(x)||x>100 {return}}
        for x in s.overview {if !remote_nonnegative(x)||x>100 {return}}
        if !remote_nonnegative(s.gpu.utilization)||s.gpu.utilization>100||
            !remote_nonnegative(s.gpu.memory_percent)||s.gpu.memory_percent>100||
            !remote_nonnegative(s.gpu.power_watts)||!remote_nonnegative(s.gpu.frequency_mhz)||!remote_nonnegative(s.gpu.temperature)||
            !remote_nonnegative(s.gpu.power_max_watts)||s.gpu.power_max_available&&s.gpu.power_max_watts<=0||
            !remote_nonnegative(s.gpu.fan_percent)||s.gpu.fan_percent>100||s.gpu.memory_used>s.gpu.memory_total {return}
        for c in s.cores {if !remote_nonnegative(c.lower)||!remote_nonnegative(c.upper)||c.lower>c.upper||c.upper>100||!remote_nonnegative(c.frequency_mhz) {return}}
        previous=s.timestamp
    }
    ok=true
    return
}
persistence_cache_apply :: proc(a:^App,m:^Machine,cache:Persistence_Cache,restore_snapshot:bool=true)->bool {
    if restore_snapshot&&cache.snapshot!=""&&!remote_decode(transmute([]u8)cache.snapshot,&m.state.metrics) {return false}
    state:=m.state
    if restore_snapshot&&cache.snapshot!="" {state.process_revision+=1}
    pinned:f64=-1
    gpu_pinned:f64=-1
    if state.gpu_pinned_slot>=0&&state.gpu_pinned_slot<HISTORY_CAPACITY {gpu_pinned=state.cpu_history[state.gpu_pinned_slot].timestamp}
    state.gpu_pinned_slot=-1
    memory_pinned:f64=-1
    if state.cpu_pinned_slot>=0&&state.cpu_pinned_slot<HISTORY_CAPACITY {pinned=state.cpu_history[state.cpu_pinned_slot].timestamp}
    if state.memory_pinned_slot>=0&&state.memory_pinned_slot<HISTORY_CAPACITY {memory_pinned=state.cpu_history[state.memory_pinned_slot].timestamp}
    state.cpu_pinned_slot=-1
    state.memory_pinned_slot=-1
    mem.zero_item(&state.history)
    mem.zero_slice(state.cpu_history[:])
    for s,i in cache.samples {
        sample:=&state.cpu_history[i]
        sample^=CPU_Sample{generation=s.generation,timestamp=s.timestamp,polling_seconds=s.polling_seconds,lower=s.lower,upper=s.upper,
            continuity_recorded=s.continuity_recorded,gap_before=s.gap_before,
            threads=s.threads,power_watts=s.power_watts,frequency_mhz=s.frequency_mhz,
            power_available=s.power_available,frequency_available=s.frequency_available,
            memory_total=s.memory_total,memory_used=s.memory_used,memory_available=s.memory_available,
            memory_free=s.memory_free,memory_cached=s.memory_cached,memory_buffers=s.memory_buffers,
            memory_breakdown_available=s.memory_breakdown_available,
            memory_free_available=s.memory_free_available,memory_cached_available=s.memory_cached_available,memory_buffers_available=s.memory_buffers_available,
            swap_total=s.swap_total,swap_used=s.swap_used,disk_read=s.disk_read,disk_write=s.disk_write,
            network_rx=s.network_rx,network_tx=s.network_tx,
            ram_available=s.ram_available,rates_ready=s.rates_ready,network_rates_ready=s.network_rates_ready}
        copy(sample.cores[:],s.cores);copy(sample.logical[:],s.logical)
        sample.gpu=gpu_cache_sample(s,&state.metrics,restore_snapshot&&cache.snapshot!=""&&s.timestamp==cache.sampled_at)
        for kind in 0..<4 {state.history[kind][i]=s.overview[kind]}
        if s.timestamp==pinned {state.cpu_pinned_slot=i}
        if s.timestamp==gpu_pinned {state.gpu_pinned_slot=i}
        if s.timestamp==memory_pinned {state.memory_pinned_slot=i}
    }
    state.history_count=len(cache.samples);state.history_next=len(cache.samples)%HISTORY_CAPACITY
    if restore_snapshot&&cache.snapshot!=""&&state.history_count>0 {
        latest:=&state.cpu_history[state.history_count-1]
        if latest.timestamp==cache.sampled_at {history_memory_sample(latest,&state.metrics)}
    }
    m.has_sample=cache.snapshot!=""
    m.status=cache.status;m.message_len=copy(m.message[:],cache.message)
    m.received=time.tick_add(time.tick_now(),-time.Duration(max(0,persistence_wall_time()-cache.sampled_at)*1e9))
    m.persistence_stamp=cache.written_at
    a.dirty=true
    return true
}
persistence_local_captured:bool
persistence_local_needs_prime:bool
persistence_local_nvml:bool
persistence_local_gpu_count:int
persistence_local_power_source:CPU_Power_Source
persistence_poll :: proc(a:^App,now:f64) {
    if persistence_headless||!a.persistence_enabled||now-a.persistence_last_poll<0.5 {return}
    a.persistence_last_poll=now
    wall:=persistence_wall_time()
    local_current:=false
    for m in a.machines[:] {
        if m!=a.local_machine&&!m.persistent {continue}
        if m.state==nil {machine_connect(a,m)}
        cache,ok:=persistence_cache_read(m)
        healthy:=ok&&cache.written_at<=wall+2
        if m==a.local_machine {
            healthy=healthy&&wall-cache.written_at<=persistence_freshness_seconds(a)&&cache.snapshot!=""
            if !persistence_local_captured {
                persistence_local_nvml=m.state.metrics.nvml_available
                persistence_local_gpu_count=m.state.metrics.gpu_count
                persistence_local_power_source=m.state.metrics.cpu_power_source
                persistence_local_captured=true
            }
        } else {healthy=healthy&&local_current}
        if ok&&!m.state.paused&&cache.written_at!=m.persistence_stamp {
            if !persistence_cache_apply(a,m,cache) {healthy=false}
        }
        if m==a.local_machine {local_current=healthy}
        // Pause freezes display data, while service availability still updates.
        if !healthy {
            m.status=.Disconnected
            m.message_len=copy(m.message[:],"Persistence service cache is unavailable or stale.")
            a.dirty=true
        } else if m.state.paused {
            m.status=cache.status;m.message_len=copy(m.message[:],cache.message)
            m.received=time.tick_add(time.tick_now(),-time.Duration(max(0,wall-cache.sampled_at)*1e9))
        }
    }
    if !local_current {persistence_error_set(a,"Persistence service is starting or unavailable; cached graphs are retained.")}
    else if a.persistence_error_len>0 {a.persistence_error_len=0;a.dirty=true}
}

persistence_cache_write :: proc(a:^App,m:^Machine,live:bool=false)->bool {
    state:=m.state
    snapshot:string
    defer delete(snapshot)
    if m.has_sample {
        data,ok:=remote_encode(&state.metrics)
        if !ok {return false}
        snapshot=string(data)
    }
    samples:=make([]Persistence_Sample,state.history_count,context.temp_allocator)
    first:=(state.history_next-state.history_count+HISTORY_CAPACITY)%HISTORY_CAPACITY
    for &destination,i in samples {
        slot:=(first+i)%HISTORY_CAPACITY
        source:=&state.cpu_history[slot]
        core_count,logical_count:=len(source.cores),len(source.logical)
        for core_count>0&&source.cores[core_count-1]==(CPU_Core_Sample{}) {core_count-=1}
        for logical_count>0&&source.logical[logical_count-1]==0 {logical_count-=1}
        destination=Persistence_Sample{generation=source.generation,timestamp=source.timestamp,polling_seconds=source.polling_seconds,
            continuity_recorded=source.continuity_recorded,gap_before=source.gap_before,
            lower=source.lower,upper=source.upper,threads=source.threads,power_watts=source.power_watts,
            frequency_mhz=source.frequency_mhz,power_available=source.power_available,
            frequency_available=source.frequency_available,cores=source.cores[:core_count],logical=source.logical[:logical_count],
            memory_total=source.memory_total,memory_used=source.memory_used,memory_available=source.memory_available,
            memory_free=source.memory_free,memory_cached=source.memory_cached,memory_buffers=source.memory_buffers,
            memory_breakdown_available=source.memory_breakdown_available,
            memory_free_available=source.memory_free_available,memory_cached_available=source.memory_cached_available,memory_buffers_available=source.memory_buffers_available,
            swap_total=source.swap_total,swap_used=source.swap_used,disk_read=source.disk_read,disk_write=source.disk_write,
            network_rx=source.network_rx,network_tx=source.network_tx,
            ram_available=source.ram_available,rates_ready=source.rates_ready,network_rates_ready=source.network_rates_ready}
        for kind in 0..<4 {destination.overview[kind]=state.history[kind][slot]}
        destination.gpu=source.gpu
    }
    sampled_at:f64=0
    if len(samples)>0 {sampled_at=samples[len(samples)-1].timestamp}
    // Retain only the most recent graph window when restarting after downtime.
    cutoff:=persistence_wall_time()-(2 if live else HISTORY_SECONDS)
    first_recent:=persistence_recent_start(samples,cutoff)
    cache:=Persistence_Cache{version=PERSISTENCE_CACHE_VERSION,host=string(m.host[:m.host_len]),
        collector=string(m.collector[:m.collector_len]),port=m.port,written_at=persistence_wall_time(),
        sampled_at=sampled_at,status=m.status,message=string(m.message[:m.message_len]),snapshot=snapshot,samples=samples[first_recent:]}
    return persistence_cache_atomic_write(persistence_cache_path(m,live),cache,live)
}

// The daemon only reads machines.json. All discovery and configuration writes
// remain owned by the desktop process, so simultaneous use cannot lose edits.
persistence_config_reconcile :: proc(a:^App)->bool {
    if a.machine_config_path_len==0 {return false}
    data,err:=os.read_entire_file(string(a.machine_config_path[:a.machine_config_path_len]),context.temp_allocator)
    if err!=nil||string(data)==a.persistence_config_data {return false}
    records:[]Machine_Record
    if json.unmarshal(data,&records,allocator=context.temp_allocator)!=nil {return false}
    delete(a.persistence_config_data);a.persistence_config_data=strings.clone(string(data))
    // Retire probes for removed/changed records before accepting new results.
    if a.machine_login_discovery!=nil {ssh_login_discovery_destroy(a.machine_login_discovery);a.machine_login_discovery=nil}
    machines_candidates_clear(a)
    for r in a.machine_saved_records {delete(r.host);delete(r.name);delete(r.collector)}
    clear(&a.machine_saved_records)
    for r in records {
        if r.hidden||r.host=="" {continue}
        name:=r.name;collector:=r.collector
        if name=="" {name=r.host};if collector=="" {collector=DEFAULT_COLLECTOR}
        append(&a.machine_saved_records,Machine_Record{host=strings.clone(r.host),name=strings.clone(name),collector=strings.clone(collector),port=r.port,automatic=r.automatic})
    }
    for i:=len(a.machines)-1;i>0;i-=1 {
        m:=a.machines[i]
        keep:=false
        for r in records {
            collector:=r.collector;if collector=="" {collector=DEFAULT_COLLECTOR}
            if !r.hidden&&strings.equal_fold(r.host,string(m.host[:m.host_len]))&&r.port==m.port&&collector==string(m.collector[:m.collector_len]) {keep=true;break}
        }
        if !keep {_=os.remove(persistence_cache_path(m));_=os.remove(persistence_cache_path(m,true));machine_free(m);ordered_remove(&a.machines,i)}
    }
    a.machine_count=len(a.machines)
    for r in records {
        if r.hidden||r.host==""||machine_find(a,r.host,r.port)>=0 {continue}
        name:=r.name;collector:=r.collector
        if name=="" {name=r.host};if collector=="" {collector=DEFAULT_COLLECTOR}
        _=machine_add(a,r.host,name,collector,save=false,port=r.port,automatic=r.automatic)
    }
    a.machine=a.local_machine.state;a.active_machine=0
    return true
}
persistence_cache_prune :: proc(a:^App,active_publishers:bool=false) {
    directory:=persistence_directory()
    if directory=="" {return}
    files,err:=os.read_all_directory_by_path(directory,context.temp_allocator)
    if err!=nil {return}
    for file in files {
        path:=fmt.tprintf("%s/%s",directory,file.name)
        if !strings.has_suffix(file.name,".json")&&!strings.contains(file.name,".json.tmp-") {continue}
        keep:=false
        for m in a.machines[:] {
            full:=persistence_cache_path(m)
            live:=persistence_cache_path(m,true)
            if path==full||path==live||active_publishers&&
                (path==fmt.tprintf("%s.tmp-%d",full,os.get_pid())||path==fmt.tprintf("%s.tmp-%d",live,os.get_pid())) {
                keep=true;break
            }
        }
        if !keep {
            for r in a.machine_saved_records {
                pending:=Machine{port=r.port}
                pending.host_len=copy(pending.host[:],r.host);pending.collector_len=copy(pending.collector[:],r.collector)
                if path==persistence_cache_path(&pending)||path==persistence_cache_path(&pending,true) {keep=true;break}
            }
        }
        if !keep {_=os.remove(path)}
    }
}

persistence_service_main :: proc() {
    persistence_headless=true
    if !persistence_platform_service_init() {return}
    defer persistence_platform_service_destroy()
    a:=new(App)
    defer free(a)
    machines_init(a)
    defer machines_destroy(a)
    defer delete(a.persistence_config_data)
    defer delete(a.graph_settings_data)
    graph_settings_load(a)
    metrics_init_cpu(&a.local_machine.state.metrics)
    metrics_init_devices(&a.local_machine.state.metrics)
    defer metrics_destroy(&a.local_machine.state.metrics)
    _=persistence_config_reconcile(a)
    persistence_cache_prune(a)
    for m in a.machines[:] {
        cache,ok:=persistence_cache_read(m)
        if ok {
            cutoff:=persistence_wall_time()-HISTORY_SECONDS
            first_recent:=persistence_recent_start(cache.samples,cutoff)
            cache.samples=cache.samples[first_recent:]
            _=persistence_cache_apply(a,m,cache,restore_snapshot=m!=a.local_machine)
        }
        mem.free_all(context.temp_allocator)
    }
    local:=a.local_machine
    local.status=.Live;local.message_len=0;local.has_sample=true
    local.state.history_handoff_pending=true
    publisher:=persistence_publisher_start()
    if publisher==nil {fmt.eprintln("Could not start the persistence cache publisher.");return}
    defer persistence_publisher_destroy(publisher)
    live_publisher:=persistence_publisher_start(true)
    if live_publisher==nil {fmt.eprintln("Could not start the persistence live publisher.");return}
    defer persistence_publisher_destroy(live_publisher)
    publications:=make(map[^Machine]Persistence_Publication)
    defer delete(publications)
    live_publications:=make(map[^Machine]Persistence_Publication)
    defer delete(live_publications)
    started:=time.tick_now()
    // Keep the actual counter-baseline time when cache restoration took time.
    local.state.last_sample=-time.duration_seconds(time.tick_since(local.state.metrics._sample_started))
    last_config:f64=-1
    last_publication:f64=-1
    for !persistence_platform_service_stop_requested() {
        now:=time.duration_seconds(time.tick_since(started))
        graph_settings_poll(a)
        if now-last_config>=1 {
            if persistence_config_reconcile(a) {
                clear(&publications);clear(&live_publications)
                persistence_publisher_reconcile(publisher,a);persistence_publisher_reconcile(live_publisher,a);persistence_cache_prune(a,true)
            }
            last_config=now
        }
        machines_discovery_poll(a)
        machines_sample(a,now)
        for m in a.machines[:] {
            sampled_at:f64=0
            if m.state.history_count>0 {sampled_at=m.state.cpu_history[(m.state.history_next+HISTORY_CAPACITY-1)%HISTORY_CAPACITY].timestamp}
            previous:=live_publications[m]
            if previous.exists&&previous.sampled_at==sampled_at&&previous.status==m.status&&previous.message_len==m.message_len&&previous.message==m.message {continue}
            persistence_publisher_submit(live_publisher,m)
            live_publications[m]=Persistence_Publication{sampled_at=sampled_at,status=m.status,message=m.message,message_len=m.message_len,exists=true}
        }
        // Sampling keeps every observation; serialize at most once per second
        // rather than rewriting five minutes of history for every 100 ms poll.
        if now-last_publication>=1 {
            for m in a.machines[:] {
                sampled_at:f64=0
                if m.state.history_count>0 {sampled_at=m.state.cpu_history[(m.state.history_next+HISTORY_CAPACITY-1)%HISTORY_CAPACITY].timestamp}
                previous:=publications[m]
                if previous.exists&&previous.sampled_at==sampled_at&&previous.status==m.status&&previous.message_len==m.message_len&&previous.message==m.message {continue}
                persistence_publisher_submit(publisher,m)
                publications[m]=Persistence_Publication{sampled_at=sampled_at,status=m.status,message=m.message,message_len=m.message_len,exists=true}
            }
            last_publication=now
        }
        mem.free_all(context.temp_allocator)
        now=time.duration_seconds(time.tick_since(started))
        // Wake for the next sample, while checking shared settings promptly
        // even when the user selects a ten-second polling interval.
        wait:=max(0.001,min(0.1,local.state.last_sample+a.interval-now))
        time.sleep(time.Duration(wait*1e9))
    }
    // Include the last sub-second batch when the service stops normally.
    for m in a.machines[:] {
        persistence_publisher_submit(publisher,m)
        persistence_publisher_submit(live_publisher,m)
    }
}

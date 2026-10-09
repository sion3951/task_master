package main

import "core:dynlib"
import "core:sort"
import "core:strings"
import "core:time"

MAX_SYSTEM_PIDS :: 16384
MAX_GPU_PIDS :: 2048
Process_Metric :: struct {
    pid: i32,
    start: u64,
    name: [64]u8,
    name_len: int,
    cpu_percent: f32,
    memory_bytes, gpu_memory_bytes: u64,
    system_process, gpu_active: bool,
    gpu_memory_available: bool,
}

// RSS is summed per PID; memory shared by group members can be counted twice.
Process_Group :: struct {
    name: [64]u8,
    name_len: int,
    cpu_percent: f32,
    gpu_active: bool,
    gpu_memory_available: bool,
    memory_bytes, gpu_memory_bytes: u64,
    pid_head: int, // -1 terminates the linked PID list.
    pid_count: int,
    system_processes: int,
}
PID_Node :: struct { pid: i32, next: int, start: u64 }
PID_Group_Link :: struct { pid: i32, group: int, start: u64 }

GPU_Metric :: struct {
    name: [96]u8,
    name_len: int,
    utilization, temperature, power_watts, fan_percent, frequency_mhz, power_max_watts: f32,
    memory_total, memory_used: u64,
    utilization_available, temperature_available, power_available: bool,
    fan_available, memory_available, frequency_available, power_max_available: bool,
    unified_memory: bool, // Graphics allocations share system RAM, rather than dedicated VRAM.
}

CPU_Counters :: struct { total, idle: u64 }
CPU_Frequency_Source :: enum { None, Measured, Driver, Mixed }
CPU_Power_Source :: enum { None, Energy, Sensor, Perf }
CPU_Core_Metric :: struct {
    package_id, core_id: int,
    logical_ids: [16]int,
    logical_count: int,
    // Scheduler occupancy bounds, not an estimate of instruction throughput.
    busy_lower, busy_upper, frequency_mhz: f32,
    frequency_available: bool,
    frequency_source: CPU_Frequency_Source,
}
Process_History :: struct {
    pid: i32, ticks, start: u64, generation: u64, cpu_percent: f32,
    system_process: bool,
    role_generation: u64,
}
GPU_Process_Memory :: struct { pid: i32, memory: u64, available: bool }
NVML_Memory :: struct { total, free, used: u64 }
NVML_Utilization :: struct { gpu, memory: u32 }
NVML_Process :: struct { pid: u32, used_memory: u64, gpu_instance, compute_instance: u32 }
NVML_API :: struct {
    __handle: dynlib.Library,
    init: proc "c" () -> i32 `dynlib:"nvmlInit_v2"`,
    shutdown: proc "c" () -> i32 `dynlib:"nvmlShutdown"`,
    count: proc "c" (^u32) -> i32 `dynlib:"nvmlDeviceGetCount_v2"`,
    device: proc "c" (u32, ^rawptr) -> i32 `dynlib:"nvmlDeviceGetHandleByIndex_v2"`,
    name: proc "c" (rawptr, ^u8, u32) -> i32 `dynlib:"nvmlDeviceGetName"`,
    utilization: proc "c" (rawptr, ^NVML_Utilization) -> i32 `dynlib:"nvmlDeviceGetUtilizationRates"`,
    temperature: proc "c" (rawptr, u32, ^u32) -> i32 `dynlib:"nvmlDeviceGetTemperature"`,
    power: proc "c" (rawptr, ^u32) -> i32 `dynlib:"nvmlDeviceGetPowerUsage"`,
    power_limit_constraints: proc "c" (rawptr, ^u32, ^u32) -> i32 `dynlib:"nvmlDeviceGetPowerManagementLimitConstraints"`,
    clock: proc "c" (rawptr, u32, ^u32) -> i32 `dynlib:"nvmlDeviceGetClockInfo"`,
    memory: proc "c" (rawptr, ^NVML_Memory) -> i32 `dynlib:"nvmlDeviceGetMemoryInfo"`,
    fan: proc "c" (rawptr, ^u32) -> i32 `dynlib:"nvmlDeviceGetFanSpeed"`,
    compute_processes: proc "c" (rawptr, ^u32, ^NVML_Process) -> i32 `dynlib:"nvmlDeviceGetComputeRunningProcesses_v3"`,
    graphics_processes: proc "c" (rawptr, ^u32, ^NVML_Process) -> i32 `dynlib:"nvmlDeviceGetGraphicsRunningProcesses_v3"`,
}

Metrics :: struct {
    hostname, cpu_model: string,
    platform: string,
    cpu_percent: f32,
    cpu_count: int,
    cores: [256]f32,
    physical_cores: [256]CPU_Core_Metric,
    physical_core_count, cpu_online_count: int,
    cpu_topology_available: bool,
    cpu_topology_generation: u64,
    cpu_busy_lower, cpu_busy_upper, cpu_frequency_mhz, cpu_power_watts: f32,
    cpu_frequency_available, cpu_power_available: bool,
    cpu_frequency_source: CPU_Frequency_Source,
    cpu_power_source: CPU_Power_Source,
    cpu_power_error: [384]u8,
    cpu_power_error_len: int,
    cpu_power_permission_denied: bool,
    memory_total, memory_used, memory_available, swap_total, swap_used: u64,
    memory_free, memory_cached, memory_buffers: u64,
    memory_breakdown_available: bool,
    memory_free_available, memory_cached_available, memory_buffers_available: bool,
    network_rx, network_tx, disk_read, disk_write: f64,
    uptime: f64,
    load: [3]f64,
    processes: [12]Process_Group,
    process_count, total_processes: int,
    memory_processes, gpu_processes: [12]Process_Group,
    memory_process_count, gpu_process_count: int,
    // CPU and RAM groups share process_pids. GPU groups use gpu_process_pids.
    // Node pools and list heads remain valid until the next sample.
    process_pids: [dynamic]PID_Node,
    gpu_process_pids: [dynamic]PID_Node,
    total_process_groups, gpu_total_processes, gpu_total_groups: int,
    process_group_overflow: bool,
    gpus: [8]GPU_Metric,
    gpu_count: int,
    nvml_available, cpu_available, ram_available: bool,
    gpu_process_memory_shared: bool,
    rates_ready: bool,
    _hostname: [128]u8,
    _cpu_model: [192]u8,
    _groups: [dynamic]Process_Group,
    _gpu_groups: [dynamic]Process_Group,
    _group_pid_count: int,
    // Only machines sampled in this process need counters, scratch buffers and
    // driver handles. Remote/cache snapshots retain just the display storage.
    using _sampler: ^Metrics_Sampler,
}

Metrics_Sampler :: struct {
    _platform: rawptr,
    _scratch: [131072]u8,
    _cpu: [257]CPU_Counters,
    _cpu_online: [256]bool,
    _cpu_topology_ready: bool,
    _cpu_power_domains: [16]CPU_Power_Domain,
    _cpu_power_domain_count: int,
    _process_history: [dynamic]Process_History,
    _process_history_count: int,
    _group_table: [dynamic]i32,
    _pid_links: [dynamic]PID_Group_Link,
    _gpu_group_table: [dynamic]i32,
    _gpu_pid_links: [dynamic]PID_Group_Link,
    _generation: u64,
    _sample_started: time.Tick,
    _network_rx, _network_tx, _disk_read, _disk_write: u64,
    _ticks_per_second, _page_size: f64,
    _nvml: NVML_API,
    _nvml_initialized: bool,
    _gpu_devices: [8]rawptr,
}

metrics_cpu_power_status :: proc(m: ^Metrics) -> string {
    if m.cpu_power_available { return "Available" }
    if m.cpu_power_permission_denied { return "Permission denied" }
    if m.cpu_power_error_len > 0 { return string(m.cpu_power_error[:m.cpu_power_error_len]) }
    return "Sensor unavailable" if m.cpu_power_source == .None else "Waiting for sample"
}

telemetry_uint :: proc(s: string) -> u64 {
    value: u64
    for b in s {
        if b < '0' || b > '9' { break }
        value = value*10 + u64(b-'0')
    }
    return value
}

telemetry_fields :: proc(line: string, fields: []string) -> int {
    text := line
    n := 0
    for field in strings.fields_iterator(&text) {
        if n >= len(fields) { break }
        fields[n] = field
        n += 1
    }
    return n
}

telemetry_cstring_len :: proc(buf: []u8) -> int {
    for b, i in buf { if b == 0 { return i } }
    return len(buf)
}

metrics_init_devices :: proc(m: ^Metrics) {
    stage:=time.tick_now()
    m.nvml_available=false
    m.gpu_count=0
    m.gpus={}
    when ODIN_OS == .Darwin {
        metrics_darwin_init_devices(m)
        metrics_sample(m, 0)
        return
    }
    library := "libnvidia-ml.so.1"
    when ODIN_OS == .Windows { library = "nvml.dll" }
    _, loaded := dynlib.initialize_symbols(&m._nvml, library)
    if loaded && m._nvml.init != nil && m._nvml.count != nil && m._nvml.device != nil && m._nvml.init() == 0 {
        m.nvml_available = true
        m._nvml_initialized = true
        count: u32
        if m._nvml.count(&count) == 0 {
            for i in 0..<min(int(count), len(m.gpus)) {
                device: rawptr
                if m._nvml.device(u32(i), &device) != 0 { continue }
                slot := m.gpu_count
                m._gpu_devices[slot] = device
                g := &m.gpus[slot]
                if m._nvml.name != nil && m._nvml.name(device, &g.name[0], u32(len(g.name))) == 0 {
                    g.name_len = telemetry_cstring_len(g.name[:])
                } else { g.name_len = copy(g.name[:], "NVIDIA GPU") }
                // Board limits are device metadata; query once, not per frame.
                minimum,maximum: u32
                g.power_max_available=m._nvml.power_limit_constraints!=nil&&
                    m._nvml.power_limit_constraints(device,&minimum,&maximum)==0&&maximum>0&&maximum>=minimum
                if g.power_max_available {g.power_max_watts=f32(maximum)/1000}
                m.gpu_count += 1
            }
        }
    }
    stage=startup_stage(stage,"NVML initialization")
    metrics_sample(m, 0)
    stage=startup_stage(stage,"initial telemetry sample")
}

// Cached display readings do not need a second live telemetry driver. Keep
// CPU power descriptors/counters so returning to window sampling is immediate.
metrics_suspend_devices :: proc(m:^Metrics) {
    if m._sampler==nil {return}
    if m._nvml_initialized&&m._nvml.shutdown!=nil {_=m._nvml.shutdown()}
    if m._nvml.__handle!=nil {_=dynlib.unload_library(m._nvml.__handle)}
    m._nvml={}
    m._nvml_initialized=false
}

metrics_destroy :: proc(m: ^Metrics) {
    delete(m.process_pids);m.process_pids={}
    delete(m.gpu_process_pids);m.gpu_process_pids={}
    delete(m._groups);m._groups={}
    delete(m._gpu_groups);m._gpu_groups={}
    if m._sampler == nil { return }
    metrics_destroy_platform(m)
    metrics_suspend_devices(m)
    m.nvml_available = false
    delete(m._group_table);delete(m._pid_links)
    delete(m._gpu_group_table);delete(m._gpu_pid_links)
    delete(m._process_history)
    free(m._sampler)
    m._sampler = nil
}

// The exposed length is storage capacity; populated counts remain separate.
// Geometric growth avoids allocating every second while keeping small hosts small.
metrics_buffer_ensure :: proc(buffer: ^[dynamic]$T, needed: int) {
    if needed<=len(buffer^) {return}
    capacity:=max(16,len(buffer^))
    for capacity<needed {capacity*=2}
    resize(buffer,capacity)
}

metrics_groups_ensure :: proc(groups:^[dynamic]Process_Group,table:^[dynamic]i32,count,limit:int) {
    if count<len(groups^)&&len(table^)>=2*len(groups^)||count>=limit {return}
    metrics_buffer_ensure(groups,count+1)
    resize(table,2*len(groups^))
    for &slot in table^ {slot=0}
    for &group,index in groups^[:count] {
        slot:=int(telemetry_name_hash(string(group.name[:group.name_len]))&u64(len(table^)-1))
        for table^[slot]!=0 {slot=(slot+1)&(len(table^)-1)}
        table^[slot]=i32(index+1)
    }
}

telemetry_merge_frequency_source :: proc(a, b: CPU_Frequency_Source) -> CPU_Frequency_Source {
    if a == .None { return b }
    if b == .None || a == b { return a }
    return .Mixed
}

metrics_sample_cpu_cores :: proc(m: ^Metrics) {
    m.cpu_busy_lower, m.cpu_busy_upper, m.cpu_frequency_mhz = 0, 0, 0
    m.cpu_frequency_available = false
    m.cpu_frequency_source = .None
    frequency_sum, active_frequency_sum, active_weight: f64
    available_count := 0
    for i in 0..<m.physical_core_count {
        core := &m.physical_cores[i]
        core.busy_lower, core.busy_upper, core.frequency_mhz = 0, 0, 0
        core.frequency_available = false
        core.frequency_source = .None
        sum: f64
        count := 0
        for cpu in core.logical_ids[:core.logical_count] {
            core.busy_lower = max(core.busy_lower, m.cores[cpu])
            core.busy_upper += m.cores[cpu]
            frequency, source := telemetry_cpu_frequency(m, cpu)
            if source == .None { continue }
            sum += f64(frequency)
            count += 1
            core.frequency_source = telemetry_merge_frequency_source(core.frequency_source, source)
        }
        core.busy_upper = min(core.busy_upper, 100)
        m.cpu_busy_lower += core.busy_lower
        m.cpu_busy_upper += core.busy_upper
        if count > 0 {
            core.frequency_mhz = f32(sum/f64(count))
            core.frequency_available = true
            frequency_sum += f64(core.frequency_mhz)
            active_frequency_sum += f64(core.frequency_mhz)*f64(core.busy_lower)
            active_weight += f64(core.busy_lower)
            available_count += 1
            m.cpu_frequency_source = telemetry_merge_frequency_source(m.cpu_frequency_source, core.frequency_source)
        }
    }
    if m.physical_core_count > 0 {
        m.cpu_busy_lower /= f32(m.physical_core_count)
        m.cpu_busy_upper /= f32(m.physical_core_count)
    }
    if available_count > 0 {
        m.cpu_frequency_available = true
        if active_weight > 0 { m.cpu_frequency_mhz = f32(active_frequency_sum/active_weight) }
        else { m.cpu_frequency_mhz = f32(frequency_sum/f64(available_count)) }
    }
    when ODIN_OS == .Darwin {metrics_darwin_cpu_frequency_aggregate(m)}
}

telemetry_rate :: proc(current, previous: u64, elapsed: f64, ready: bool) -> f64 {
    if !ready || elapsed <= 0 || current < previous { return 0 }
    return f64(current-previous)/elapsed
}

metrics_process_history :: proc(m: ^Metrics, pid: i32, create:=true) -> ^Process_History {
    if !create&&len(m._process_history)==0 {return nil}
    if len(m._process_history)==0 {resize(&m._process_history,512)}
    if create&&m._process_history_count>=len(m._process_history)/2&&len(m._process_history)<2*MAX_SYSTEM_PIDS {
        // Discard exited PIDs before growing. Rehashing keeps every live PID's
        // previous interval, even while a burst of new processes expands storage.
        live:=0
        for old in m._process_history {if old.pid!=0&&old.generation+1>=m._generation {live+=1}}
        capacity:=len(m._process_history)
        if live>=capacity/2 {capacity=min(capacity*2,2*MAX_SYSTEM_PIDS)}
        replacement:=make([dynamic]Process_History,capacity)
        for old in m._process_history {
            if old.pid==0||old.generation+1<m._generation {continue}
            slot:=int((u32(old.pid)*2654435761)&u32(capacity-1))
            for replacement[slot].pid!=0 {slot=(slot+1)&(capacity-1)}
            replacement[slot]=old
        }
        delete(m._process_history)
        m._process_history=replacement
        m._process_history_count=live
    }
    start := (u32(pid)*2654435761) & u32(len(m._process_history)-1)
    available:^Process_History
    for probe in 0..<len(m._process_history) {
        slot := &m._process_history[(int(start)+probe) % len(m._process_history)]
        if slot.pid == pid {return slot}
        if available==nil&&(slot.pid==0||slot.generation+1<m._generation) {available=slot}
        if slot.pid==0 {break}
    }
    if !create {return nil}
    if available!=nil&&available.pid==0 {m._process_history_count+=1}
    return available
}

metrics_group_for_pid :: proc(m:^Metrics,pid:i32)->^Process_Group {
    // PID links are sorted during the system sample and keep original group indices.
    links:=m._pid_links[:m._group_pid_count]
    lo,hi:=0,len(links)
    for lo<hi {
        mid:=lo+(hi-lo)/2
        if links[mid].pid<pid {lo=mid+1} else {hi=mid}
    }
    if lo<len(links)&&links[lo].pid==pid {return &m._groups[links[lo].group]}
    return nil
}

metrics_insert_ranked :: proc(processes: []Process_Group, process_count: ^int, process: Process_Group, memory := false, gpu := false) {
    count := min(process_count^, len(processes)-1)
    position := 0
    for position < process_count^ {
        p := processes[position]
        if gpu {
            if process.gpu_memory_bytes > p.gpu_memory_bytes { break }
        } else if memory {
            if process.memory_bytes > p.memory_bytes { break }
        } else if process.cpu_percent > p.cpu_percent || (process.cpu_percent == p.cpu_percent && process.memory_bytes > p.memory_bytes) { break }
        position += 1
    }
    if position >= len(processes) { return }
    for i := count; i > position; i -= 1 { processes[i] = processes[i-1] }
    processes[position] = process
    process_count^ = min(process_count^+1, len(processes))
}

telemetry_name_hash :: proc(name: string) -> u64 {
    hash: u64 = 14695981039346656037
    for b in name { hash = (hash ~ u64(b))*1099511628211 }
    return hash
}

// The hash table is at most half full, so exact-name grouping takes expected O(PIDs).
metrics_find_group :: proc(groups: []Process_Group, table: []i32, count: ^int, name: string, create := true) -> int {
    if len(name) > len(Process_Group{}.name) { return -1 }
    slot := int(telemetry_name_hash(name) & u64(len(table)-1))
    for _ in 0..<len(table) {
        index := int(table[slot])-1
        if index < 0 {
            if !create || count^ >= len(groups) { return -1 }
            index = count^
            groups[index] = Process_Group{pid_head = -1}
            groups[index].name_len = copy(groups[index].name[:], name)
            table[slot] = i32(index+1)
            count^ += 1
            return index
        }
        if name == string(groups[index].name[:groups[index].name_len]) { return index }
        slot = (slot+1) & (len(table)-1)
    }
    return -1
}

metrics_add_group_process :: proc(groups: []Process_Group, table: []i32, group_count: ^int, links: []PID_Group_Link, pid_count: ^int, process: Process_Metric) -> bool {
    if pid_count^ >= len(links) { return false }
    name_buffer := process.name
    index := metrics_find_group(groups, table, group_count, string(name_buffer[:process.name_len]))
    if index < 0 { return false }
    group := &groups[index]
    group.cpu_percent += process.cpu_percent
    group.memory_bytes += process.memory_bytes
    if group.pid_count == 0 { group.gpu_memory_available = true }
    if process.gpu_active && !process.gpu_memory_available { group.gpu_memory_available = false }
    group.gpu_memory_bytes += process.gpu_memory_bytes
    if process.system_process {group.system_processes+=1}
    group.gpu_active=group.gpu_active||process.gpu_active
    group.pid_count += 1
    links[pid_count^] = PID_Group_Link{pid = process.pid, group = index, start = process.start}
    pid_count^ += 1
    return true
}

metrics_finalize_group_pids :: proc(groups: []Process_Group, links: []PID_Group_Link, nodes: []PID_Node) {
    sort.quick_sort_proc(links, proc(a, b: PID_Group_Link) -> int {
        if a.pid < b.pid { return -1 }
        if a.pid > b.pid { return 1 }
        return 0
    })
    // Building backwards after one global PID sort produces ascending group lists.
    for i := len(links)-1; i >= 0; i -= 1 {
        group := &groups[links[i].group]
        nodes[i] = PID_Node{pid = links[i].pid, next = group.pid_head, start = links[i].start}
        group.pid_head = i
    }
}

metrics_reduce_gpu_processes :: proc(processes: []GPU_Process_Memory, sum_memory: bool) -> int {
    sort.quick_sort_proc(processes, proc(a, b: GPU_Process_Memory) -> int {
        if a.pid < b.pid { return -1 }
        if a.pid > b.pid { return 1 }
        return 0
    })
    count := 0
    for process in processes {
        if count > 0 && processes[count-1].pid == process.pid {
            if sum_memory {
                processes[count-1].available = processes[count-1].available && process.available
                processes[count-1].memory += process.memory
            }
            else {
                processes[count-1].available = processes[count-1].available || process.available
                processes[count-1].memory = max(processes[count-1].memory, process.memory)
            }
        } else {
            processes[count] = process
            count += 1
        }
    }
    return count
}

metrics_sample_gpu :: proc(m: ^Metrics) {
    m.gpu_process_count = 0
    m.gpu_total_processes, m.gpu_total_groups = 0, 0
    for &slot in m._gpu_group_table {slot=0}
    when ODIN_OS != .Windows { if !m.nvml_available { return } }
    // Enough for both 128-entry NVML lists on each of the eight supported GPUs.
    all_processes: [2048]GPU_Process_Memory
    all_count := 0
    when ODIN_OS != .Darwin { api := &m._nvml; for i in 0..<m.gpu_count {
        g := &m.gpus[i]
        device := m._gpu_devices[i]
        utilization: NVML_Utilization
        g.utilization_available = api.utilization != nil && api.utilization(device, &utilization) == 0
        if g.utilization_available { g.utilization = f32(utilization.gpu) }
        value: u32
        g.temperature_available = api.temperature != nil && api.temperature(device, 0, &value) == 0
        if g.temperature_available { g.temperature = f32(value) }
        g.power_available = api.power != nil && api.power(device, &value) == 0
        if g.power_available { g.power_watts = f32(value)/1000 }
        // NVML_CLOCK_GRAPHICS = 0; the current graphics/core clock is in MHz.
        g.frequency_available = api.clock != nil && api.clock(device, 0, &value) == 0
        if g.frequency_available { g.frequency_mhz = f32(value) }
        g.fan_available = api.fan != nil && api.fan(device, &value) == 0
        if g.fan_available { g.fan_percent = f32(value) }
        memory: NVML_Memory
        g.memory_available = api.memory != nil && api.memory(device, &memory) == 0
        if g.memory_available { g.memory_total, g.memory_used = memory.total, memory.used }
        // Count a PID once per GPU: compute and graphics NVML lists may overlap.
        gpu_processes: [256]NVML_Process
        compute_count: u32 = 128
        if api.compute_processes == nil { compute_count = 0 } else {
            result := api.compute_processes(device, &compute_count, &gpu_processes[0])
            if result == 7 { m.process_group_overflow = true }
            if result != 0 { compute_count = 0 }
        }
        graphics_count: u32 = 128
        if api.graphics_processes == nil { graphics_count = 0 } else {
            result := api.graphics_processes(device, &graphics_count, &gpu_processes[128])
            if result == 7 { m.process_group_overflow = true }
            if result != 0 { graphics_count = 0 }
        }
        per_gpu: [256]GPU_Process_Memory
        per_gpu_count := 0
        for index in 0..<256 {
            if index < 128 && index >= int(min(compute_count, 128)) { continue }
            if index >= 128 && index-128 >= int(min(graphics_count, 128)) { continue }
            gp := gpu_processes[index]
            if gp.pid == 0 { continue }
            available := gp.used_memory != ~u64(0)
            if !available { gp.used_memory = 0 }
            per_gpu[per_gpu_count] = GPU_Process_Memory{pid = i32(gp.pid), memory = gp.used_memory, available = available}
            per_gpu_count += 1
        }
        per_gpu_count = metrics_reduce_gpu_processes(per_gpu[:per_gpu_count], sum_memory = false)
        for p in per_gpu[:per_gpu_count] {
            if all_count >= len(all_processes) { m.process_group_overflow = true; continue }
            all_processes[all_count] = p
            all_count += 1
        }
    }}
    when ODIN_OS == .Darwin { all_count = metrics_darwin_sample_gpus(m, all_processes[:]) }
    when ODIN_OS == .Windows {
        pdh_count := windows_gpu_processes(m, all_processes[:])
        if pdh_count >= 0 { all_count = pdh_count }
    }
    all_count = metrics_reduce_gpu_processes(all_processes[:all_count], sum_memory = true)
    m.gpu_total_processes = all_count
    gpu_pid_count := 0
    for gpu_process in all_processes[:all_count] {
        process := Process_Metric{pid = gpu_process.pid, gpu_memory_bytes = gpu_process.memory, gpu_active=true, gpu_memory_available=gpu_process.available}
        if group:=metrics_group_for_pid(m,process.pid);group!=nil {group.gpu_active=true}
        metrics_gpu_process_details(m, &process)
        metrics_groups_ensure(&m._gpu_groups,&m._gpu_group_table,m.gpu_total_groups,MAX_GPU_PIDS)
        metrics_buffer_ensure(&m._gpu_pid_links,min(gpu_pid_count+1,MAX_GPU_PIDS))
        if !metrics_add_group_process(m._gpu_groups[:], m._gpu_group_table[:], &m.gpu_total_groups, m._gpu_pid_links[:], &gpu_pid_count, process) {
            m.process_group_overflow = true
        }
    }
    metrics_buffer_ensure(&m.gpu_process_pids,gpu_pid_count)
    metrics_finalize_group_pids(m._gpu_groups[:m.gpu_total_groups], m._gpu_pid_links[:gpu_pid_count], m.gpu_process_pids[:])
    for index in 0..<m.gpu_total_groups {
        group := m._gpu_groups[index]
        metrics_insert_ranked(m.gpu_processes[:], &m.gpu_process_count, group, gpu = true)
        // Include group VRAM in CPU/RAM tables without broadening GPU group membership.
        for p in 0..<m.process_count {
            if string(m.processes[p].name[:m.processes[p].name_len]) == string(group.name[:group.name_len]) { m.processes[p].gpu_memory_bytes = group.gpu_memory_bytes; m.processes[p].gpu_memory_available = group.gpu_memory_available }
        }
        for p in 0..<m.memory_process_count {
            if string(m.memory_processes[p].name[:m.memory_processes[p].name_len]) == string(group.name[:group.name_len]) { m.memory_processes[p].gpu_memory_bytes = group.gpu_memory_bytes; m.memory_processes[p].gpu_memory_available = group.gpu_memory_available }
        }
    }
}


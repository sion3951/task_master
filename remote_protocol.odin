package main

import "core:encoding/json"
import "core:math"

REMOTE_PROTOCOL_VERSION :: 5
REMOTE_MAX_FRAME_BYTES :: 16*1024*1024

// A wire snapshot contains only display data. Local sampler counters, NVML
// handles, file descriptors and pointers must never cross the connection.
Remote_Snapshot :: struct {
    version: int,
    hostname, cpu_model: string,
    platform: string,
    cpu_percent: f32,
    cpu_count, cpu_online_count: int,
    cores: []f32,
    physical_cores: []CPU_Core_Metric,
    cpu_topology_available: bool,
    cpu_topology_generation: u64,
    cpu_busy_lower, cpu_busy_upper, cpu_frequency_mhz, cpu_power_watts: f32,
    cpu_frequency_available, cpu_power_available: bool,
    cpu_frequency_source: CPU_Frequency_Source,
    cpu_power_source: CPU_Power_Source,
    cpu_power_error: string,
    cpu_power_permission_denied: bool,
    memory_total, memory_used, memory_available, swap_total, swap_used: u64,
    memory_free, memory_cached, memory_buffers: u64,
    memory_breakdown_available: bool,
    memory_free_available, memory_cached_available, memory_buffers_available: bool,
    network_rx, network_tx, disk_read, disk_write: f64,
    uptime: f64,
    load: [3]f64,
    processes, memory_processes, gpu_processes: []Process_Group,
    groups, gpu_groups: []Process_Group,
    process_pids, gpu_process_pids: []PID_Node,
    total_processes, gpu_total_processes: int,
    process_group_overflow: bool,
    gpus: []GPU_Metric,
    nvml_available, cpu_available, ram_available, rates_ready: bool,
    gpu_process_memory_shared: bool,
}

// Private sampler counters, perf descriptors and NVML handles remain owned by
// their original Metrics. Only the validated display snapshot is copied.
metrics_display_copy :: proc(m,source:^Metrics) {
    if m==source {return}
    metrics_buffer_ensure(&m._groups,source.total_process_groups)
    metrics_buffer_ensure(&m._gpu_groups,source.gpu_total_groups)
    metrics_buffer_ensure(&m.process_pids,source._group_pid_count)
    m.hostname=string(m._hostname[:copy(m._hostname[:],source.hostname)])
    m.cpu_model=string(m._cpu_model[:copy(m._cpu_model[:],source.cpu_model)])
    m.platform=source.platform
    m.cpu_percent,m.cpu_count,m.cpu_online_count=source.cpu_percent,source.cpu_count,source.cpu_online_count
    m.cores=source.cores;m.physical_cores=source.physical_cores
    m.physical_core_count=source.physical_core_count
    m.cpu_topology_available,m.cpu_topology_generation=source.cpu_topology_available,source.cpu_topology_generation
    m.cpu_busy_lower,m.cpu_busy_upper=source.cpu_busy_lower,source.cpu_busy_upper
    m.cpu_frequency_mhz,m.cpu_power_watts=source.cpu_frequency_mhz,source.cpu_power_watts
    m.cpu_frequency_available,m.cpu_power_available=source.cpu_frequency_available,source.cpu_power_available
    m.cpu_frequency_source,m.cpu_power_source=source.cpu_frequency_source,source.cpu_power_source
    m.cpu_power_error=source.cpu_power_error;m.cpu_power_error_len=source.cpu_power_error_len
    m.cpu_power_permission_denied=source.cpu_power_permission_denied
    m.memory_total,m.memory_used,m.memory_available=source.memory_total,source.memory_used,source.memory_available
    m.memory_free,m.memory_cached,m.memory_buffers=source.memory_free,source.memory_cached,source.memory_buffers
    m.memory_breakdown_available=source.memory_breakdown_available
    m.memory_free_available,m.memory_cached_available,m.memory_buffers_available=source.memory_free_available,source.memory_cached_available,source.memory_buffers_available
    m.swap_total,m.swap_used=source.swap_total,source.swap_used
    m.network_rx,m.network_tx,m.disk_read,m.disk_write=source.network_rx,source.network_tx,source.disk_read,source.disk_write
    m.uptime,m.load=source.uptime,source.load
    copy(m.processes[:source.process_count],source.processes[:source.process_count]);m.process_count=source.process_count
    copy(m.memory_processes[:source.memory_process_count],source.memory_processes[:source.memory_process_count]);m.memory_process_count=source.memory_process_count
    copy(m.gpu_processes[:source.gpu_process_count],source.gpu_processes[:source.gpu_process_count]);m.gpu_process_count=source.gpu_process_count
    copy(m._groups[:source.total_process_groups],source._groups[:source.total_process_groups]);m.total_process_groups=source.total_process_groups
    copy(m._gpu_groups[:source.gpu_total_groups],source._gpu_groups[:source.gpu_total_groups]);m.gpu_total_groups=source.gpu_total_groups
    copy(m.process_pids[:source._group_pid_count],source.process_pids[:source._group_pid_count]);m._group_pid_count=source._group_pid_count
    gpu_pid_count:=0
    for group in source._gpu_groups[:source.gpu_total_groups] {gpu_pid_count+=group.pid_count}
    metrics_buffer_ensure(&m.gpu_process_pids,gpu_pid_count)
    copy(m.gpu_process_pids[:gpu_pid_count],source.gpu_process_pids[:gpu_pid_count])
    m.total_processes,m.gpu_total_processes=source.total_processes,source.gpu_total_processes
    m.process_group_overflow=source.process_group_overflow
    m.gpus=source.gpus;m.gpu_count=source.gpu_count
    m.gpu_process_memory_shared=source.gpu_process_memory_shared
    m.nvml_available,m.cpu_available,m.ram_available,m.rates_ready=source.nvml_available,source.cpu_available,source.ram_available,source.rates_ready
}
remote_encode :: proc(m: ^Metrics) -> ([]u8, bool) {
    gpu_pid_count := 0
    for group in m._gpu_groups[:m.gpu_total_groups] { gpu_pid_count += group.pid_count }
    s := Remote_Snapshot{
        version = REMOTE_PROTOCOL_VERSION,
        hostname = m.hostname, cpu_model = m.cpu_model, platform = m.platform,
        cpu_percent = m.cpu_percent, cpu_count = m.cpu_count,
        cpu_online_count = m.cpu_online_count, cores = m.cores[:m.cpu_count],
        physical_cores = m.physical_cores[:m.physical_core_count],
        cpu_topology_available = m.cpu_topology_available,
        cpu_topology_generation = m.cpu_topology_generation,
        cpu_busy_lower = m.cpu_busy_lower, cpu_busy_upper = m.cpu_busy_upper,
        cpu_frequency_mhz = m.cpu_frequency_mhz, cpu_power_watts = m.cpu_power_watts,
        cpu_frequency_available = m.cpu_frequency_available,
        cpu_power_available = m.cpu_power_available,
        cpu_frequency_source = m.cpu_frequency_source, cpu_power_source = m.cpu_power_source,
        cpu_power_error = string(m.cpu_power_error[:m.cpu_power_error_len]),
        cpu_power_permission_denied = m.cpu_power_permission_denied,
        memory_total = m.memory_total, memory_used = m.memory_used,
        memory_available = m.memory_available, swap_total = m.swap_total, swap_used = m.swap_used,
        memory_free=m.memory_free,memory_cached=m.memory_cached,memory_buffers=m.memory_buffers,
        memory_breakdown_available=m.memory_breakdown_available,
        memory_free_available=m.memory_free_available,memory_cached_available=m.memory_cached_available,memory_buffers_available=m.memory_buffers_available,
        network_rx = m.network_rx, network_tx = m.network_tx,
        disk_read = m.disk_read, disk_write = m.disk_write, uptime = m.uptime, load = m.load,
        processes = m.processes[:m.process_count], memory_processes = m.memory_processes[:m.memory_process_count],
        gpu_processes = m.gpu_processes[:m.gpu_process_count],
        groups = m._groups[:m.total_process_groups], gpu_groups = m._gpu_groups[:m.gpu_total_groups],
        process_pids = m.process_pids[:m._group_pid_count], gpu_process_pids = m.gpu_process_pids[:gpu_pid_count],
        total_processes = m.total_processes, gpu_total_processes = m.gpu_total_processes,
        process_group_overflow = m.process_group_overflow,
        gpus = m.gpus[:m.gpu_count], nvml_available = m.nvml_available, gpu_process_memory_shared=m.gpu_process_memory_shared,
        cpu_available = m.cpu_available, ram_available = m.ram_available, rates_ready = m.rates_ready,
    }
    // A resizable heap builder frees its previous storage when it grows;
    // an arena builder retains every superseded capacity until frame cleanup.
    data, err := json.marshal(s, allocator = context.allocator)
    if err!=nil||len(data)>REMOTE_MAX_FRAME_BYTES {delete(data);return nil,false}
    return data,true // The caller owns and releases the encoded frame.
}

remote_nonnegative :: proc(x: $T) -> bool {
    return x >= 0 && !math.is_nan(x) && !math.is_inf(x)
}

remote_valid_group_fields :: proc(g: Process_Group, node_count: int) -> bool {
    return g.name_len >= 0 && g.name_len <= len(g.name) && remote_nonnegative(g.cpu_percent) &&
        g.pid_count >= 0 && g.pid_count <= node_count && g.system_processes >= 0 && g.system_processes <= g.pid_count
}

remote_valid_group :: proc(g: Process_Group, nodes: []PID_Node) -> bool {
    if !remote_valid_group_fields(g, len(nodes)) { return false }
    cursor := g.pid_head
    for _ in 0..<g.pid_count {
        if cursor < 0 || cursor >= len(nodes) || nodes[cursor].pid <= 0 { return false }
        cursor = nodes[cursor].next
    }
    return cursor == -1
}

remote_valid_groups :: proc(groups: []Process_Group, nodes: []PID_Node) -> bool {
    seen := make([]bool, len(nodes), context.temp_allocator)
    count := 0
    for g in groups {
        if !remote_valid_group_fields(g, len(nodes)) { return false }
        cursor := g.pid_head
        for _ in 0..<g.pid_count {
            if cursor < 0 || cursor >= len(nodes) || nodes[cursor].pid <= 0 || seen[cursor] { return false }
            seen[cursor] = true
            count += 1
            cursor = nodes[cursor].next
        }
        if cursor != -1 { return false }
    }
    return count == len(nodes)
}

remote_decode :: proc(data: []u8, m: ^Metrics, require_controls:bool=false) -> bool {
    if len(data) == 0 || len(data) > REMOTE_MAX_FRAME_BYTES { return false }
    s: Remote_Snapshot
    if json.unmarshal(data, &s, allocator = context.temp_allocator) != nil { return false }
    if require_controls&&s.version!=REMOTE_PROTOCOL_VERSION {return false}
    if (s.version != REMOTE_PROTOCOL_VERSION && s.version != 4 && s.version != 3) || len(s.hostname) > len(m._hostname) || len(s.cpu_model) > len(m._cpu_model) ||
        len(s.cpu_power_error) > len(m.cpu_power_error) ||
        s.cpu_count < 0 || s.cpu_count > len(m.cores) || len(s.cores) != s.cpu_count ||
        s.cpu_online_count < 0 || s.cpu_online_count > s.cpu_count || len(s.physical_cores) > len(m.physical_cores) ||
        len(s.processes) > len(m.processes) || len(s.memory_processes) > len(m.memory_processes) ||
        len(s.gpu_processes) > len(m.gpu_processes) || len(s.groups) > MAX_SYSTEM_PIDS ||
        len(s.gpu_groups) > MAX_GPU_PIDS || len(s.process_pids) > MAX_SYSTEM_PIDS ||
        len(s.gpu_process_pids) > MAX_GPU_PIDS || len(s.gpus) > len(m.gpus) ||
        s.total_processes < len(s.process_pids) || s.gpu_total_processes < len(s.gpu_process_pids) { return false }
    if s.platform!=""&&s.platform!="linux"&&s.platform!="windows"&&s.platform!="darwin" {return false}
    if s.version==3 {
        s.memory_free_available,s.memory_cached_available,s.memory_buffers_available=s.memory_breakdown_available,s.memory_breakdown_available,s.memory_breakdown_available
        for &group in s.processes {group.gpu_memory_available=true}
        for &group in s.memory_processes {group.gpu_memory_available=true}
        for &group in s.gpu_processes {group.gpu_memory_available=true}
        for &group in s.groups {group.gpu_memory_available=true}
        for &group in s.gpu_groups {group.gpu_memory_available=true}
    }
    if !remote_nonnegative(s.cpu_percent) || s.cpu_percent > 100 ||
        !remote_nonnegative(s.cpu_busy_lower) || !remote_nonnegative(s.cpu_busy_upper) || s.cpu_busy_lower > s.cpu_busy_upper || s.cpu_busy_upper > 100 ||
        !remote_nonnegative(s.cpu_frequency_mhz) || !remote_nonnegative(s.cpu_power_watts) ||
        !remote_nonnegative(s.network_rx) || !remote_nonnegative(s.network_tx) ||
        !remote_nonnegative(s.disk_read) || !remote_nonnegative(s.disk_write) || !remote_nonnegative(s.uptime) ||
        s.memory_used > s.memory_total || s.memory_available > s.memory_total || s.swap_used > s.swap_total ||
        s.memory_free>s.memory_total||s.memory_cached>s.memory_total||s.memory_buffers>s.memory_total||
        int(s.cpu_frequency_source) < 0 || int(s.cpu_frequency_source) > int(CPU_Frequency_Source.Mixed) ||
        int(s.cpu_power_source) < 0 || int(s.cpu_power_source) > int(CPU_Power_Source.Perf) { return false }
    for x in s.load { if !remote_nonnegative(x) { return false } }
    for x in s.cores { if !remote_nonnegative(x) || x > 100 { return false } }
    for &core in s.physical_cores {
        if core.logical_count < 1 || core.logical_count > len(core.logical_ids) ||
            !remote_nonnegative(core.busy_lower) || !remote_nonnegative(core.busy_upper) || core.busy_lower > core.busy_upper || core.busy_upper > 100 ||
            !remote_nonnegative(core.frequency_mhz) || int(core.frequency_source) < 0 || int(core.frequency_source) > int(CPU_Frequency_Source.Mixed) { return false }
        for id in core.logical_ids[:core.logical_count] { if id < 0 || id >= s.cpu_count { return false } }
    }
    for gpu in s.gpus {
        if gpu.name_len < 0 || gpu.name_len > len(gpu.name) || (!gpu.unified_memory&&gpu.memory_used > gpu.memory_total) ||
            !remote_nonnegative(gpu.utilization) || gpu.utilization > 100 || !remote_nonnegative(gpu.temperature) ||
            !remote_nonnegative(gpu.power_watts) || !remote_nonnegative(gpu.frequency_mhz) ||
            !remote_nonnegative(gpu.power_max_watts) || gpu.power_max_available&&gpu.power_max_watts<=0 ||
            !remote_nonnegative(gpu.fan_percent) || gpu.fan_percent > 100 { return false }
    }
    if !remote_valid_groups(s.groups, s.process_pids) || !remote_valid_groups(s.gpu_groups, s.gpu_process_pids) { return false }
    for g in s.processes { if !remote_valid_group(g, s.process_pids) { return false } }
    for g in s.memory_processes { if !remote_valid_group(g, s.process_pids) { return false } }
    for g in s.gpu_processes { if !remote_valid_group(g, s.gpu_process_pids) { return false } }

    // Apply only after the whole snapshot has passed validation. Strings point
    // into Metrics storage so they outlive this frame's temporary JSON memory.
    metrics_buffer_ensure(&m._groups,len(s.groups))
    metrics_buffer_ensure(&m._gpu_groups,len(s.gpu_groups))
    metrics_buffer_ensure(&m.process_pids,len(s.process_pids))
    metrics_buffer_ensure(&m.gpu_process_pids,len(s.gpu_process_pids))
    m.hostname = string(m._hostname[:copy(m._hostname[:], s.hostname)])
    m.cpu_model = string(m._cpu_model[:copy(m._cpu_model[:], s.cpu_model)])
    // JSON strings belong to the frame's temporary allocator. Keep a static
    // platform name so copies and persistence publications survive its reset.
    switch s.platform {
    case "windows": m.platform="windows"
    case "darwin": m.platform="darwin"
    case "", "linux": m.platform="linux"
    }
    m.cpu_percent, m.cpu_count, m.cpu_online_count = s.cpu_percent, s.cpu_count, s.cpu_online_count
    m.cores = {}
    m.physical_cores = {}
    m.gpus = {}
    copy(m.cores[:], s.cores)
    copy(m.physical_cores[:], s.physical_cores)
    m.physical_core_count = len(s.physical_cores)
    m.cpu_topology_available, m.cpu_topology_generation = s.cpu_topology_available, s.cpu_topology_generation
    m.cpu_busy_lower, m.cpu_busy_upper = s.cpu_busy_lower, s.cpu_busy_upper
    m.cpu_frequency_mhz, m.cpu_power_watts = s.cpu_frequency_mhz, s.cpu_power_watts
    m.cpu_frequency_available, m.cpu_power_available = s.cpu_frequency_available, s.cpu_power_available
    m.cpu_frequency_source, m.cpu_power_source = s.cpu_frequency_source, s.cpu_power_source
    m.cpu_power_error_len = copy(m.cpu_power_error[:], s.cpu_power_error)
    m.cpu_power_permission_denied = s.cpu_power_permission_denied
    m.memory_total, m.memory_used, m.memory_available = s.memory_total, s.memory_used, s.memory_available
    m.memory_free,m.memory_cached,m.memory_buffers=s.memory_free,s.memory_cached,s.memory_buffers
    m.memory_breakdown_available=s.memory_breakdown_available
    m.memory_free_available,m.memory_cached_available,m.memory_buffers_available=s.memory_free_available,s.memory_cached_available,s.memory_buffers_available
    m.swap_total, m.swap_used = s.swap_total, s.swap_used
    m.network_rx, m.network_tx, m.disk_read, m.disk_write = s.network_rx, s.network_tx, s.disk_read, s.disk_write
    m.uptime, m.load = s.uptime, s.load
    copy(m.processes[:], s.processes); m.process_count = len(s.processes)
    copy(m.memory_processes[:], s.memory_processes); m.memory_process_count = len(s.memory_processes)
    copy(m.gpu_processes[:], s.gpu_processes); m.gpu_process_count = len(s.gpu_processes)
    copy(m._groups[:], s.groups); m.total_process_groups = len(s.groups)
    copy(m._gpu_groups[:], s.gpu_groups); m.gpu_total_groups = len(s.gpu_groups)
    copy(m.process_pids[:], s.process_pids); m._group_pid_count = len(s.process_pids)
    copy(m.gpu_process_pids[:], s.gpu_process_pids)
    m.total_processes, m.gpu_total_processes = s.total_processes, s.gpu_total_processes
    m.process_group_overflow = s.process_group_overflow
    copy(m.gpus[:], s.gpus); m.gpu_count = len(s.gpus)
    m.gpu_process_memory_shared=s.gpu_process_memory_shared
    m.nvml_available, m.cpu_available, m.ram_available, m.rates_ready = s.nvml_available, s.cpu_available, s.ram_available, s.rates_ready
    return true
}

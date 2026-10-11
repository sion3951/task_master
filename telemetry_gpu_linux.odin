#+build linux
package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"

// Native DRM telemetry needs no vendor SDK or privileged helper. Drivers expose
// different subsets of these read-only interfaces; absent values stay unavailable.
// fdinfo ABI: https://docs.kernel.org/gpu/drm-usage-stats.html
Linux_GPU_Path :: struct { bytes: [256]u8, count: int }
Linux_GPU_Engine :: struct {
    id, busy, cycles, total, maximum, capacity: u64,
    has_busy, has_cycles, has_total: bool,
}
Linux_GPU_Previous_Engine :: struct { id, value, total: u64, mode: u8 }
Linux_GPU_Client :: struct {
    id, generation: u64,
    device: int,
    last_pid: i32,
    engines: [16]Linux_GPU_Previous_Engine,
}
Linux_GPU_Device :: struct {
    slot: int,
    path, identity, drm, hwmon, devfreq: Linux_GPU_Path,
    intel, local_memory_seen: bool,
    // One device can have primary and render DRM nodes. Match both to one GPU.
    nodes: [4]Linux_GPU_Path,
    node_count: int,
    engine_ids: [32]u64,
    engine_percent: [32]f64,
    engine_count: int,
    engine_observed, rate_ready: bool,
    energy, energy_time: u64,
    energy_ready: bool,
}
Linux_GPU_Sampler :: struct {
    devices: [8]Linux_GPU_Device,
    count: int,
    clients: [8192]Linux_GPU_Client,
    generation: u64,
    previous_tick: time.Tick,
}
linux_gpu_path_set :: proc(path: ^Linux_GPU_Path, value: string) {
    path.count = copy(path.bytes[:], value)
}
linux_gpu_path :: proc(path: ^Linux_GPU_Path) -> string { return string(path.bytes[:path.count]) }
linux_gpu_hash :: proc(value: string) -> u64 {
    result: u64 = 14695981039346656037
    for byte in value { result = (result ~ u64(byte))*1099511628211 }
    return result if result != 0 else 1
}
linux_gpu_link :: proc(path: string, buffer: []u8, directory: linux.Fd = linux.AT_FDCWD) -> string {
    name: [256]u8
    if len(path) >= len(name) { return "" }
    copy(name[:], path)
    count, err := linux.readlinkat(directory, cstring(&name[0]), buffer)
    if err != nil || count <= 0 || count == len(buffer) { return "" }
    return string(buffer[:count])
}
linux_gpu_child_directory :: proc(parent: string, prefix: string, output: ^Linux_GPU_Path) {
    name: [256]u8
    if len(parent) >= len(name) { return }
    copy(name[:], parent)
    fd, err := linux.open(cstring(&name[0]), {.DIRECTORY, .CLOEXEC})
    if err != nil { return }
    defer linux.close(fd)
    buffer: [4096]u8
    for {
        count, read_error := linux.getdents(fd, buffer[:])
        if read_error != nil || count <= 0 { break }
        offset := 0
        for {
            entry, ok := linux.dirent_iterate_buf(buffer[:count], &offset)
            if !ok { break }
            child := linux.dirent_name(entry)
            if child == "." || child == ".." || !strings.has_prefix(child, prefix) { continue }
            path := fmt.bprintf(name[:], "%s/%s", parent, child)
            linux_gpu_path_set(output, path)
            return
        }
    }
}
linux_gpu_uint :: proc(base: ^Linux_GPU_Path, filename: string) -> (u64, bool) {
    if base.count == 0 { return 0, false }
    path_buffer: [256]u8
    value_buffer: [128]u8
    path := fmt.bprintf(path_buffer[:], "%s/%s", linux_gpu_path(base), filename)
    // Odin's prefix-aware parser accepts PCI IDs such as 0x8086 as well as
    // decimal sensor values. Do not force decimal for vendor/device discovery.
    return strconv.parse_u64(strings.trim_space(telemetry_read(path, value_buffer[:])))
}

metrics_linux_init_gpus :: proc(m: ^Metrics) {
    metrics_linux_destroy_gpus(m)
    fd, err := linux.open("/sys/class/drm", {.DIRECTORY, .CLOEXEC})
    if err != nil { return }
    defer linux.close(fd)
    sampler := new(Linux_GPU_Sampler)
    m._gpu_platform = sampler
    has_nvml := false
    for device in m._gpu_devices { if device != nil { has_nvml = true; break } }
    directory_buffer: [8192]u8
    for {
        count, read_error := linux.getdents(fd, directory_buffer[:])
        if read_error != nil || count <= 0 { break }
        offset := 0
        for {
            entry, ok := linux.dirent_iterate_buf(directory_buffer[:count], &offset)
            if !ok { break }
            node := linux.dirent_name(entry)
            prefix := "card" if strings.has_prefix(node, "card") else "renderD"
            if !strings.has_prefix(node, prefix) { continue }
            _, numeric := strconv.parse_u64(node[len(prefix):])
            if !numeric { continue } // Exclude connector entries, e.g. card0-HDMI-A-1.
            path_buffer, identity_buffer, driver_buffer: [256]u8
            path := fmt.bprintf(path_buffer[:], "/sys/class/drm/%s/device", node)
            identity := linux_gpu_link(path, identity_buffer[:])
            if identity == "" { continue }
            existing := -1
            for &device, index in sampler.devices[:sampler.count] {
                if string(device.identity.bytes[:device.identity.count]) == identity { existing = index; break }
            }
            if existing >= 0 {
                device := &sampler.devices[existing]
                if prefix == "card" {
                    path = fmt.bprintf(path_buffer[:], "/sys/class/drm/%s", node)
                    linux_gpu_path_set(&device.drm, path)
                }
                if device.node_count < len(device.nodes) {
                    linux_gpu_path_set(&device.nodes[device.node_count], node)
                    device.node_count += 1
                }
                continue
            }
            base: Linux_GPU_Path
            linux_gpu_path_set(&base, path)
            vendor, _ := linux_gpu_uint(&base, "vendor")
            path = fmt.bprintf(path_buffer[:], "%s/driver", linux_gpu_path(&base))
            driver := linux_gpu_link(path, driver_buffer[:])
            slash := strings.last_index_byte(driver, '/')
            if slash >= 0 { driver = driver[slash+1:] }
            if driver == "nvidia" { m._gpu_nvml_expected = true }
            if has_nvml && (vendor == 0x10de || driver == "nvidia") { continue }
            if m.gpu_count >= len(m.gpus) { m.process_group_overflow = true; continue }
            device := &sampler.devices[sampler.count]
            device.slot = m.gpu_count
            device.path = base
            device.intel = vendor == 0x8086 || driver == "i915" || driver == "xe"
            if prefix == "card" {
                path = fmt.bprintf(path_buffer[:], "/sys/class/drm/%s", node)
                linux_gpu_path_set(&device.drm, path)
            }
            linux_gpu_path_set(&device.identity, identity)
            linux_gpu_path_set(&device.nodes[0], node)
            device.node_count = 1
            g := &m.gpus[device.slot]
            vendor_name := "GPU"
            switch {
            case vendor == 0x1002 || driver == "amdgpu" || driver == "radeon": vendor_name = "AMD GPU"
            case vendor == 0x8086 || driver == "i915" || driver == "xe": vendor_name = "Intel GPU"
            case vendor == 0x10de || driver == "nouveau" || driver == "nvidia": vendor_name = "NVIDIA GPU"
            case driver == "msm": vendor_name = "Qualcomm Adreno GPU"
            case driver == "panfrost" || driver == "panthor" || driver == "lima": vendor_name = "ARM Mali GPU"
            case driver == "v3d" || driver == "vc4": vendor_name = "Broadcom GPU"
            case driver == "asahi": vendor_name = "Apple GPU"
            }
            value_buffer: [256]u8
            path = fmt.bprintf(path_buffer[:], "%s/product_name", linux_gpu_path(&base))
            product := strings.trim_space(telemetry_read(path, value_buffer[:]))
            if product != "" { g.name_len = copy(g.name[:], product) } else {
                pci_device, valid := linux_gpu_uint(&base, "device")
                label := fmt.bprintf(path_buffer[:], "%s (%s)", vendor_name, driver)
                if valid { label = fmt.bprintf(path_buffer[:], "%s %04x (%s)", vendor_name, pci_device, driver) }
                g.name_len = copy(g.name[:], label)
            }
            // Positive VRAM identifies dedicated memory; do not label discrete
            // Intel Arc as unified just because its driver is also used by iGPUs.
            vram, vram_ok := linux_gpu_uint(&base, "mem_info_vram_total")
            g.unified_memory = (!vram_ok || vram == 0) &&
                (driver == "msm" || driver == "panfrost" || driver == "panthor" || driver == "lima" || driver == "v3d" || driver == "vc4" || driver == "asahi")
            path = fmt.bprintf(path_buffer[:], "%s/hwmon", linux_gpu_path(&base))
            linux_gpu_child_directory(path, "hwmon", &device.hwmon)
            path = fmt.bprintf(path_buffer[:], "%s/devfreq", linux_gpu_path(&base))
            linux_gpu_child_directory(path, "", &device.devfreq)
            if device.devfreq.count == 0 {
                path = fmt.bprintf(path_buffer[:], "%s/gpu/devfreq", linux_gpu_path(&base))
                linux_gpu_child_directory(path, "", &device.devfreq)
            }
            sampler.count += 1
            m.gpu_count += 1
        }
    }
    // Qualcomm's DRM master can be the display controller while Adreno's
    // devfreq is registered by a separate GPU component. Resolve the class
    // entry only when a single integrated/platform GPU makes the match clear.
    platform_index, platform_count := -1, 0
    for &device, index in sampler.devices[:sampler.count] {
        if m.gpus[device.slot].unified_memory {
            platform_index, platform_count = index, platform_count+1
        }
    }
    if platform_count == 1 && sampler.devices[platform_index].devfreq.count == 0 {
        devfreq_fd, devfreq_error := linux.open("/sys/class/devfreq", {.DIRECTORY, .CLOEXEC})
        if devfreq_error == nil {
            buffer: [8192]u8
            candidate: Linux_GPU_Path
            candidate_count := 0
            for {
                count, read_error := linux.getdents(devfreq_fd, buffer[:])
                if read_error != nil || count <= 0 { break }
                offset := 0
                for {
                    entry, ok := linux.dirent_iterate_buf(buffer[:count], &offset)
                    if !ok { break }
                    name := linux.dirent_name(entry)
                    if !strings.contains(name, "gpu") && !strings.contains(name, "kgsl-3d") && !strings.contains(name, "adreno") { continue }
                    if strings.contains(name, "bus") { continue }
                    path_buffer: [256]u8
                    path := fmt.bprintf(path_buffer[:], "/sys/class/devfreq/%s", name)
                    linux_gpu_path_set(&candidate, path)
                    candidate_count += 1
                }
            }
            linux.close(devfreq_fd)
            if candidate_count == 1 { sampler.devices[platform_index].devfreq = candidate }
        }
    }
    if sampler.count == 0 { metrics_linux_destroy_gpus(m) }
    else { m.gpu_process_memory_shared = true } // fdinfo includes system allocations as well as VRAM.
}

linux_gpu_sample_sensors :: proc(device: ^Linux_GPU_Device, g: ^GPU_Metric, tick_ns: u64) {
    g.utilization_available, g.temperature_available, g.power_available = false, false, false
    g.frequency_available, g.memory_available, g.fan_available, g.power_max_available = false, false, false, false
    if value, ok := linux_gpu_uint(&device.path, "gpu_busy_percent"); ok {
        g.utilization, g.utilization_available = f32(min(value, 100)), true
    }
    total, total_ok := linux_gpu_uint(&device.path, "mem_info_vram_total")
    used, used_ok := linux_gpu_uint(&device.path, "mem_info_vram_used")
    if total_ok && used_ok && total > 0 && used <= total {
        g.memory_total, g.memory_used, g.memory_available = total, used, true
    }
    if value, ok := linux_gpu_uint(&device.hwmon, "temp1_input"); ok {
        g.temperature, g.temperature_available = f32(value)/1000, true
    }
    power, power_ok := linux_gpu_uint(&device.hwmon, "power1_average")
    if !power_ok { power, power_ok = linux_gpu_uint(&device.hwmon, "power1_input") }
    if power_ok { g.power_watts, g.power_available = f32(f64(power)/1e6), true }
    if value, ok := linux_gpu_uint(&device.hwmon, "power1_cap"); ok && value > 0 {
        g.power_max_watts, g.power_max_available = f32(f64(value)/1e6), true
    }
    // Intel hwmon commonly exposes cumulative microjoules instead of power.
    if energy, ok := linux_gpu_uint(&device.hwmon, "energy1_input"); ok {
        if !g.power_available && device.energy_ready && energy >= device.energy && tick_ns > device.energy_time {
            g.power_watts = f32(f64(energy-device.energy)*1000/f64(tick_ns-device.energy_time))
            g.power_available = true
        }
        device.energy, device.energy_time, device.energy_ready = energy, tick_ns, true
    } else { device.energy_ready = false }
    if value, ok := linux_gpu_uint(&device.hwmon, "freq1_input"); ok {
        g.frequency_mhz, g.frequency_available = f32(f64(value)/1e6), true
    }
    if !g.frequency_available {
        if value, ok := linux_gpu_uint(&device.devfreq, "cur_freq"); ok {
            g.frequency_mhz, g.frequency_available = f32(f64(value)/1e6), true
        }
    }
    if !g.frequency_available {
        frequency_files := [4]string{"gt_cur_freq_mhz", "gt/gt0/rps_cur_freq_mhz", "tile0/gt0/freq0/cur_freq", "tile0/gt0/freq0/act_freq"}
        for name in frequency_files {
            value, ok := linux_gpu_uint(&device.path, name)
            if !ok { value, ok = linux_gpu_uint(&device.drm, name) }
            if ok {
                g.frequency_mhz, g.frequency_available = f32(value), true
                break
            }
        }
    }
    if !g.frequency_available {
        path_buffer: [256]u8
        value_buffer: [2048]u8
        path := fmt.bprintf(path_buffer[:], "%s/pp_dpm_sclk", linux_gpu_path(&device.path))
        text := telemetry_read(path, value_buffer[:])
        for line in strings.split_lines_iterator(&text) {
            if !strings.contains(line, "*") { continue }
            fields: [4]string
            if telemetry_fields(line, fields[:]) < 2 { continue }
            clock := fields[1]
            if strings.has_suffix(clock, "Mhz") || strings.has_suffix(clock, "MHz") {
                value, ok := strconv.parse_u64(clock[:len(clock)-3])
                if ok { g.frequency_mhz, g.frequency_available = f32(value), true }
            }
        }
    }
    fan, fan_ok := linux_gpu_uint(&device.hwmon, "fan1_input")
    maximum, maximum_ok := linux_gpu_uint(&device.hwmon, "fan1_max")
    if fan_ok && maximum_ok && maximum > 0 {
        g.fan_percent, g.fan_available = f32(min(f64(fan)/f64(maximum)*100, 100)), true
    }
}

linux_gpu_number :: proc(value: string) -> (number: u64, unit: string, valid: bool) {
    fields: [3]string
    count := telemetry_fields(value, fields[:])
    if count < 1 { return }
    number, valid = strconv.parse_u64(fields[0])
    if count > 1 { unit = fields[1] }
    return
}
linux_gpu_memory_number :: proc(value: string) -> (u64, bool) {
    number, unit, valid := linux_gpu_number(value)
    multiplier: u64 = 1
    switch unit { case "KiB": multiplier = 1024; case "MiB": multiplier = 1024*1024; case "", "B": case: return 0, false }
    if !valid || number > ~u64(0)/multiplier { return 0, false }
    return number*multiplier, true
}
linux_gpu_engine :: proc(engines: []Linux_GPU_Engine, count: ^int, name: string) -> ^Linux_GPU_Engine {
    id := linux_gpu_hash(name)
    for &engine in engines[:count^] { if engine.id == id { return &engine } }
    if count^ >= len(engines) { return nil }
    engine := &engines[count^]
    count^ += 1
    engine.id, engine.capacity = id, 1
    return engine
}
linux_gpu_client :: proc(sampler: ^Linux_GPU_Sampler, device: int, id: u64) -> ^Linux_GPU_Client {
    hash := (id ~ (u64(device+1)*0x9e3779b97f4a7c15))*1099511628211
    replacement := -1
    for probe in 0..<len(sampler.clients) {
        index := int((hash+u64(probe))%u64(len(sampler.clients)))
        client := &sampler.clients[index]
        if client.generation == 0 {
            if replacement < 0 { replacement = index }
            break
        }
        if client.device == device && client.id == id { return client }
        if replacement < 0 && client.generation+2 < sampler.generation { replacement = index }
    }
    if replacement < 0 { return nil }
    client := &sampler.clients[replacement]
    client^ = Linux_GPU_Client{device = device, id = id}
    return client
}

// Return one client's allocations. Duplicate fds within a PID are ignored;
// shared clients still keep each owning PID visible, while device rates are
// accumulated once globally. Residency wins over total virtual allocation.
linux_gpu_fdinfo :: proc(m: ^Metrics, sampler: ^Linux_GPU_Sampler, device_index: int, pid: i32, descriptor: string, text: string, elapsed_ns: f64) -> (memory: u64, available, include: bool) {
    client_id: u64
    has_id, is_drm: bool
    engines: [16]Linux_GPU_Engine
    engine_count := 0
    regions: [16]struct { id, bytes: u64, rank: int }
    region_count := 0
    system_memory, local_memory: bool
    contents := text
    for line in strings.split_lines_iterator(&contents) {
        colon := strings.index_byte(line, ':')
        if colon < 0 { continue }
        key, value := line[:colon], strings.trim_space(line[colon+1:])
        if key == "drm-driver" { is_drm = true; continue }
        if key == "drm-client-id" { client_id, has_id = strconv.parse_u64(value); continue }
        engine_name := ""
        mode := 0
        switch {
        case strings.has_prefix(key, "drm-engine-capacity-"): engine_name, mode = key[len("drm-engine-capacity-"):], 2
        case strings.has_prefix(key, "drm-engine-"): engine_name, mode = key[len("drm-engine-"):], 1
        case strings.has_prefix(key, "drm-cycles-"): engine_name, mode = key[len("drm-cycles-"):], 3
        case strings.has_prefix(key, "drm-total-cycles-"): engine_name, mode = key[len("drm-total-cycles-"):], 4
        case strings.has_prefix(key, "drm-maxfreq-"): engine_name, mode = key[len("drm-maxfreq-"):], 5
        }
        if mode != 0 {
            number, unit, valid := linux_gpu_number(value)
            if !valid { continue }
            engine := linux_gpu_engine(engines[:], &engine_count, engine_name)
            if engine == nil { m.process_group_overflow = true; continue }
            switch mode {
            case 1: if unit == "ns" || unit == "" { engine.busy, engine.has_busy = number, true }
            case 2: engine.capacity = max(number, 1)
            case 3: engine.cycles, engine.has_cycles = number, true
            case 4: engine.total, engine.has_total = number, true
            case 5:
                multiplier: u64 = 1
                if unit == "MHz" { multiplier = 1000000 }
                if unit == "KHz" || unit == "kHz" { multiplier = 1000 }
                if number <= ~u64(0)/multiplier { engine.maximum = number*multiplier }
            }
            continue
        }
        region_name := ""
        rank := 0
        switch {
        case strings.has_prefix(key, "drm-resident-"): region_name, rank = key[len("drm-resident-"):], 3
        case strings.has_prefix(key, "drm-memory-"): region_name, rank = key[len("drm-memory-"):], 2
        case strings.has_prefix(key, "drm-total-"): region_name, rank = key[len("drm-total-"):], 1
        }
        if rank == 0 { continue }
        bytes, valid := linux_gpu_memory_number(value)
        if !valid { continue }
        if region_name == "system" || region_name == "memory" || region_name == "gtt" || region_name == "stolen" { system_memory = true }
        if strings.has_prefix(region_name, "local") || strings.has_prefix(region_name, "vram") || strings.has_prefix(region_name, "lmem") { local_memory = true }
        id := linux_gpu_hash(region_name)
        index := -1
        for region, i in regions[:region_count] { if region.id == id { index = i; break } }
        if index < 0 {
            if region_count >= len(regions) { m.process_group_overflow = true; continue }
            index, region_count = region_count, region_count+1
            regions[index].id = id
        }
        if rank > regions[index].rank { regions[index].bytes, regions[index].rank = bytes, rank }
    }
    if !is_drm { return }
    device := &sampler.devices[device_index]
    if device.intel {
        device.local_memory_seen = device.local_memory_seen || local_memory
        if device.local_memory_seen { m.gpus[device.slot].unified_memory = false }
        else if system_memory { m.gpus[device.slot].unified_memory = true }
    }
    if !has_id {
        // Older drivers lack client IDs: descriptor-scoped history is the only
        // available identity, so shared/duplicated files cannot be deduplicated.
        client_id = (u64(u32(pid))<<32) ~ linux_gpu_hash(descriptor)
    }
    client := linux_gpu_client(sampler, device_index, client_id)
    if client == nil { m.process_group_overflow = true; return }
    duplicate := client.generation == sampler.generation
    if duplicate && client.last_pid == pid { return }
    include = true
    client.last_pid = pid
    for region in regions[:region_count] { memory += region.bytes }
    available = region_count > 0
    if duplicate { return }
    previous_generation := client.generation
    client.generation = sampler.generation
    for engine in engines[:engine_count] {
        mode: u8
        current: u64
        if engine.has_busy { mode, current = 1, engine.busy }
        else if engine.has_cycles && engine.has_total { mode, current = 2, engine.cycles }
        else if engine.has_cycles && engine.maximum > 0 { mode, current = 3, engine.cycles }
        else { continue }
        device.engine_observed = true
        previous: ^Linux_GPU_Previous_Engine
        for &entry in client.engines {
            if entry.id == engine.id { previous = &entry; break }
            if previous == nil && entry.id == 0 { previous = &entry }
        }
        if previous == nil { m.process_group_overflow = true; continue }
        value := current
        total := engine.total
        if previous.id == engine.id && previous.mode == mode {
            value, total = max(value, previous.value), max(total, previous.total)
            if previous_generation+1 == sampler.generation && elapsed_ns > 0 {
                percentage: f64
                valid := true
                switch mode {
                case 1: percentage = f64(value-previous.value)/elapsed_ns*100/f64(engine.capacity)
                case 2:
                    valid = total > previous.total
                    if valid { percentage = f64(value-previous.value)/f64(total-previous.total)*100/f64(engine.capacity) }
                case 3: percentage = f64(value-previous.value)/(elapsed_ns/1e9*f64(engine.maximum))*100/f64(engine.capacity)
                }
                if valid {
                    device.rate_ready = true
                    index := -1
                    for id, i in device.engine_ids[:device.engine_count] { if id == engine.id { index = i; break } }
                    if index < 0 && device.engine_count < len(device.engine_ids) {
                        index = device.engine_count
                        device.engine_count += 1
                        device.engine_ids[index] = engine.id
                    }
                    if index >= 0 { device.engine_percent[index] += percentage } else { m.process_group_overflow = true }
                }
            }
        }
        previous^ = Linux_GPU_Previous_Engine{id = engine.id, value = value, total = total, mode = mode}
    }
    return
}

metrics_linux_sample_gpus :: proc(m: ^Metrics, output: []GPU_Process_Memory) -> int {
    sampler := cast(^Linux_GPU_Sampler)m._gpu_platform
    if sampler == nil || sampler.count == 0 { return 0 }
    now := time.tick_now()
    elapsed_ns := f64(time.tick_diff(sampler.previous_tick, now))
    if sampler.generation == 0 { elapsed_ns = 0 }
    sampler.previous_tick = now
    sampler.generation += 1
    for &device in sampler.devices[:sampler.count] {
        device.engine_ids, device.engine_percent, device.engine_count = {}, {}, 0
        device.engine_observed, device.rate_ready = false, false
        linux_gpu_sample_sensors(&device, &m.gpus[device.slot], u64(time.tick_diff({}, now)))
    }
    proc_fd, err := linux.open("/proc", {.DIRECTORY, .CLOEXEC})
    if err != nil { return 0 }
    defer linux.close(proc_fd)
    proc_buffer: [32768]u8
    fd_buffer: [8192]u8
    info_buffer: [8192]u8
    output_count := 0
    for {
        count, read_error := linux.getdents(proc_fd, proc_buffer[:])
        if read_error != nil || count <= 0 { break }
        offset := 0
        for {
            entry, ok := linux.dirent_iterate_buf(proc_buffer[:count], &offset)
            if !ok { break }
            name := linux.dirent_name(entry)
            pid_value, numeric := strconv.parse_u64(name)
            if !numeric || pid_value == 0 || pid_value > 0x7fffffff { continue }
            path_buffer: [128]u8
            path := fmt.bprintf(path_buffer[:], "%s/fd", name)
            terminated: [128]u8
            copy(terminated[:], path)
            fd, open_error := linux.openat(proc_fd, cstring(&terminated[0]), {.DIRECTORY, .CLOEXEC})
            if open_error != nil { continue }
            process := GPU_Process_Memory{pid = i32(pid_value)}
            process_seen := false
            for {
                fd_count, fd_error := linux.getdents(fd, fd_buffer[:])
                if fd_error != nil || fd_count <= 0 { break }
                fd_offset := 0
                for {
                    descriptor_entry, descriptor_ok := linux.dirent_iterate_buf(fd_buffer[:fd_count], &fd_offset)
                    if !descriptor_ok { break }
                    descriptor := linux.dirent_name(descriptor_entry)
                    if descriptor == "." || descriptor == ".." { continue }
                    link_buffer: [256]u8
                    target := linux_gpu_link(descriptor, link_buffer[:], directory = fd)
                    if !strings.has_prefix(target, "/dev/dri/") { continue }
                    node := target[len("/dev/dri/"):]
                    device_index := -1
                    for &device, index in sampler.devices[:sampler.count] {
                        for &alias in device.nodes[:device.node_count] {
                            if string(alias.bytes[:alias.count]) == node { device_index = index; break }
                        }
                        if device_index >= 0 { break }
                    }
                    if device_index < 0 { continue }
                    path = fmt.bprintf(path_buffer[:], "%s/fdinfo/%s", name, descriptor)
                    text := telemetry_read(path, info_buffer[:], directory = proc_fd)
                    if len(text) == len(info_buffer) { m.process_group_overflow = true; continue }
                    memory, available, include := linux_gpu_fdinfo(m, sampler, device_index, process.pid, descriptor, text, elapsed_ns)
                    if include {
                        process.available = available if !process_seen else process.available && available
                        process_seen = true
                        process.memory += memory
                    }
                }
            }
            linux.close(fd)
            if process_seen {
                if output_count >= len(output) { m.process_group_overflow = true; continue }
                output[output_count] = process
                output_count += 1
            }
        }
    }
    for &device in sampler.devices[:sampler.count] {
        g := &m.gpus[device.slot]
        if !g.utilization_available && device.rate_ready {
            // Engines can run concurrently. The busiest engine is an occupancy
            // estimate from readable clients, not a sum that exceeds 100%.
            percentage: f64
            for value in device.engine_percent[:device.engine_count] { percentage = max(percentage, value) }
            g.utilization, g.utilization_available = f32(clamp(percentage, 0, 100)), true
        }
    }
    return output_count
}
metrics_linux_destroy_gpus :: proc(m: ^Metrics) {
    if m._gpu_platform != nil { free(cast(^Linux_GPU_Sampler)m._gpu_platform); m._gpu_platform = nil }
}

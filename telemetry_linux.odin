#+build linux
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

CPU_Power_Domain :: struct {
    path: [256]u8,
    path_len: int,
    previous_energy, energy_range: u64,
    previous_enabled, previous_running: u64,
    joules_per_count: f64,
    perf_fd: linux.Fd,
    perf_open: bool,
    ready: bool,
    package_id: int,
}
telemetry_read :: proc(path: string, buffer: []u8, read_error: ^linux.Errno = nil, directory: linux.Fd = linux.AT_FDCWD) -> string {
    if read_error != nil { read_error^ = nil }
    path_buffer: [256]u8
    if len(path) >= len(path_buffer) {
        if read_error != nil { read_error^ = .ENAMETOOLONG }
        return ""
    }
    copy(path_buffer[:], path)
    fd, err := linux.openat(directory, cstring(&path_buffer[0]), {})
    if err != nil {
        if read_error != nil { read_error^ = err }
        return ""
    }
    defer linux.close(fd)
    used := 0
    for used < len(buffer) {
        n, read_err := linux.read(fd, buffer[used:])
        if read_err == .EINTR { continue }
        if read_err != nil && read_error != nil { read_error^ = read_err }
        if n <= 0 || read_err != nil { break }
        used += n
    }
    return string(buffer[:used])
}

metrics_cpu_power_error :: proc(m: ^Metrics, message: string, err: linux.Errno = nil) {
    m.cpu_power_error_len = copy(m.cpu_power_error[:], message)
    if err != nil {
        m.cpu_power_error_len += len(fmt.bprintf(m.cpu_power_error[m.cpu_power_error_len:], " (%v)", err))
    }
    m.cpu_power_permission_denied = err == .EACCES || err == .EPERM
}

metrics_init_cpu :: proc(m: ^Metrics) {
    m.platform = "linux"
    stage:=time.tick_now()
    if m._sampler == nil { m._sampler = new(Metrics_Sampler) }
    m._ticks_per_second = f64(posix.sysconf(._CLK_TCK))
    m._page_size = f64(posix.sysconf(._PAGESIZE))
    if m._ticks_per_second <= 0 { m._ticks_per_second = 100 }
    if m._page_size <= 0 { m._page_size = 4096 }
    hostname := strings.trim_space(telemetry_read("/proc/sys/kernel/hostname", m._scratch[:]))
    n := copy(m._hostname[:], hostname)
    m.hostname = string(m._hostname[:n])
    cpuinfo := telemetry_read("/proc/cpuinfo", m._scratch[:])
    for line in strings.split_lines_iterator(&cpuinfo) {
        if strings.has_prefix(line, "model name") || strings.has_prefix(line, "Hardware") {
            colon := strings.index_byte(line, ':')
            if colon >= 0 {
                count := copy(m._cpu_model[:], strings.trim_space(line[colon+1:]))
                m.cpu_model = string(m._cpu_model[:count])
                break
            }
        }
    }
    if m.cpu_model == "" { m.cpu_model = "CPU" }
    metrics_init_cpu_power(m)
    // A persistent, installed helper hands back open perf descriptors and
    // immediately exits. This also works for an unprivileged development build.
    if m.cpu_power_source != .Perf && m.cpu_power_permission_denied {
        _ = metrics_init_cpu_power_helper(m)
    }
    if !telemetry_drop_perf_capability() {
        fmt.eprintln("Unable to drop CPU perf capability before loading drivers")
        os.exit(1)
    }
    stage=startup_stage(stage,"CPU discovery / power")
}

// Debian owns /usr/libexec; source/AppImage power installation uses /usr/local.
CPU_POWER_HELPER :: "/usr/local/libexec/task_master/collector"
CPU_POWER_PACKAGE_HELPER :: "/usr/libexec/task_master/collector"
CPU_POWER_HELPER_VERSION :: 1
CPU_Power_Transfer :: struct {
    magic, version, count, permission_denied: u32,
    packages: [16]struct { id: i32, reserved: u32, scale: f64 },
    error: [384]u8,
    error_len: u32,
}
// Linux cmsghdr followed by SCM_RIGHTS descriptors, aligned to sizeof(size_t).
CPU_Power_Control :: struct { length: uint, level, kind: i32, fds: [16]i32 }
CPU_POWER_CONTROL_HEADER :: size_of(uint)+2*size_of(i32)

metrics_init_cpu_power_helper :: proc(m: ^Metrics) -> bool {
    sockets: [2]linux.Fd
    if linux.socketpair(.LOCAL, .SEQPACKET, linux.Protocol(0), &sockets) != nil { return false }
    defer linux.close(sockets[0])
    // Both originals close on exec; os.process_start duplicates the child end
    // onto stdin. Spawn happens before workers and before PR_SET_NO_NEW_PRIVS.
    _ = linux.fcntl(sockets[0], linux.F_SETFD, 1) // FD_CLOEXEC
    _ = linux.fcntl(sockets[1], linux.F_SETFD, 1)
    input := os.new_file(uintptr(sockets[1]), "CPU power helper")
    helper:=CPU_POWER_PACKAGE_HELPER if os.is_file(CPU_POWER_PACKAGE_HELPER) else CPU_POWER_HELPER
    child, err := os.process_start({command = []string{helper, "--power-fds"}, stdin = input})
    os.close(input)
    if err != nil { return false }
    defer {
        _, wait_error := os.process_wait(child, 200*time.Millisecond)
        if wait_error == .Timeout {
            _ = os.process_kill(child)
            _, _ = os.process_wait(child, time.Second)
        }
    }
    poll := [1]linux.Poll_Fd{{fd = sockets[0], events = {.IN}}}
    ready, poll_error := linux.poll(poll[:], 2000)
    if poll_error != nil || ready == 0 { return false }
    transfer: CPU_Power_Transfer
    control: CPU_Power_Control
    vectors := [1]linux.IO_Vec{{base = cast([^]u8)&transfer, len = size_of(transfer)}}
    message := linux.Msg_Hdr{ iov = vectors[:], control = (cast([^]u8)&control)[:size_of(control)] }
    received, receive_error := linux.recvmsg(sockets[0], &message, {.CMSG_CLOEXEC})
    fd_count := 0
    if len(message.control) >= CPU_POWER_CONTROL_HEADER && control.level == 1 && control.kind == 1 &&
        control.length >= CPU_POWER_CONTROL_HEADER && control.length <= uint(len(message.control)) {
        fd_count = int(control.length-CPU_POWER_CONTROL_HEADER)/size_of(i32)
    }
    complete := false
    defer if !complete { for fd in control.fds[:fd_count] { _ = linux.close(linux.Fd(fd)) } }
    if receive_error != nil || received != size_of(transfer) || .CTRUNC in message.flags || .TRUNC in message.flags ||
        transfer.magic != 0x544d5057 || transfer.version != CPU_POWER_HELPER_VERSION ||
        transfer.count > 16 || int(transfer.count) != fd_count || transfer.error_len > u32(len(transfer.error)) { return false }
    if fd_count == 0 {
        metrics_cpu_power_error(m, string(transfer.error[:transfer.error_len]))
        m.cpu_power_permission_denied = transfer.permission_denied != 0
        return false
    }
    domains: [16]CPU_Power_Domain
    for pkg, i in transfer.packages[:fd_count] {
        if pkg.id < 0 || !(pkg.scale > 0) { return false }
        domains[i] = {package_id = int(pkg.id), joules_per_count = pkg.scale,
            perf_fd = linux.Fd(control.fds[i]), perf_open = true}
    }
    m._cpu_power_domains = domains
    m._cpu_power_domain_count = fd_count
    m.cpu_power_source = .Perf
    m.cpu_power_error_len = 0
    m.cpu_power_permission_denied = false
    complete = true
    return true
}

metrics_send_cpu_power_fds :: proc() -> bool {
    m := new(Metrics)
    defer free(m)
    // The privileged helper initializes only perf access, without recursing
    // through normal CPU discovery and the installed-helper fallback.
    m._sampler = new(Metrics_Sampler)
    defer metrics_destroy(m)
    metrics_cpu_power_error(m, "No package-energy perf counters available")
    _ = metrics_init_cpu_perf_power(m)
    if !telemetry_drop_perf_capability() { return false }
    transfer := CPU_Power_Transfer{magic = 0x544d5057, version = CPU_POWER_HELPER_VERSION,
        count = u32(m._cpu_power_domain_count), permission_denied = u32(1) if m.cpu_power_permission_denied else 0,
        error_len = u32(m.cpu_power_error_len), error = m.cpu_power_error}
    control := CPU_Power_Control{level = 1, kind = 1} // SOL_SOCKET, SCM_RIGHTS
    for domain, i in m._cpu_power_domains[:m._cpu_power_domain_count] {
        transfer.packages[i] = {id = i32(domain.package_id), scale = domain.joules_per_count}
        control.fds[i] = i32(domain.perf_fd)
    }
    vectors := [1]linux.IO_Vec{{base = cast([^]u8)&transfer, len = size_of(transfer)}}
    message := linux.Msg_Hdr{ iov = vectors[:] }
    if transfer.count > 0 {
        control.length = CPU_POWER_CONTROL_HEADER+uint(transfer.count)*size_of(i32)
        space := (control.length+size_of(uint)-1)&~uint(size_of(uint)-1)
        message.control = (cast([^]u8)&control)[:space]
    }
    sent, err := linux.sendmsg(0, &message, {.NOSIGNAL})
    return err == nil && sent == size_of(transfer)
}

metrics_sample_cpu :: proc(m: ^Metrics) {
    text := telemetry_read("/proc/stat", m._scratch[:])
    m.cpu_available = len(text) > 0
    m.cpu_count = 0
    online: [256]bool
    m.cores = {}
    for line in strings.split_lines_iterator(&text) {
        if !strings.has_prefix(line, "cpu") { continue }
        fields: [12]string
        n := telemetry_fields(line, fields[:])
        if n < 5 { continue }
        slot := 0
        if fields[0] != "cpu" {
            slot = int(telemetry_uint(fields[0][3:]))+1
            if slot >= len(m._cpu) { continue }
            m.cpu_count = max(m.cpu_count, slot)
            online[slot-1] = true
        }
        current: CPU_Counters
        // guest/guest_nice are already included in user/nice, so exclude them.
        for i in 1..<min(n, 9) { current.total += telemetry_uint(fields[i]) }
        current.idle = telemetry_uint(fields[4])
        if n > 5 { current.idle += telemetry_uint(fields[5]) }
        old := m._cpu[slot]
        utilization: f32
        if m.rates_ready && (slot == 0 || m._cpu_online[slot-1]) && current.total > old.total && current.idle >= old.idle {
            total := current.total-old.total
            idle := min(current.idle-old.idle, total)
            utilization = f32(f64(total-idle)/f64(total)*100)
        }
        if slot == 0 { m.cpu_percent = utilization } else { m.cores[slot-1] = utilization }
        m._cpu[slot] = current
    }
    changed := !m._cpu_topology_ready
    m.cpu_online_count = 0
    for is_online, i in online {
        if is_online { m.cpu_online_count += 1 }
        if is_online != m._cpu_online[i] { changed = true }
    }
    m._cpu_online = online
    if changed { metrics_refresh_cpu_topology(m) }
    metrics_sample_cpu_cores(m)
}

metrics_refresh_cpu_topology :: proc(m: ^Metrics) {
    m.physical_cores = {}
    m.physical_core_count = 0
    m.cpu_topology_available = m.cpu_available && m.cpu_online_count > 0
    // Stable Linux package/core identities group siblings, including sparse CPU IDs.
    for is_online, cpu in m._cpu_online {
        if !is_online { continue }
        path_buffer: [128]u8
        value_buffer: [64]u8
        path := fmt.bprintf(path_buffer[:], "/sys/devices/system/cpu/cpu%d/topology/physical_package_id", cpu)
        package_value, package_ok := strconv.parse_int(strings.trim_space(telemetry_read(path, value_buffer[:])))
        path = fmt.bprintf(path_buffer[:], "/sys/devices/system/cpu/cpu%d/topology/core_id", cpu)
        core_value, core_ok := strconv.parse_int(strings.trim_space(telemetry_read(path, value_buffer[:])))
        package_id, core_id := int(package_value), int(core_value)
        valid := package_ok && core_ok && package_id >= 0 && core_id >= 0
        if !valid {
            // One logical CPU per fallback row: do not invent sibling relationships.
            m.cpu_topology_available = false
            package_id, core_id = -1, cpu
        }
        index := -1
        for i in 0..<m.physical_core_count {
            core := &m.physical_cores[i]
            if core.package_id == package_id && core.core_id == core_id { index = i; break }
        }
        if index < 0 {
            index = m.physical_core_count
            m.physical_core_count += 1
            m.physical_cores[index].package_id = package_id
            m.physical_cores[index].core_id = core_id
        }
        core := &m.physical_cores[index]
        if core.logical_count >= len(core.logical_ids) {
            // Keep every CPU visible if an unusually wide SMT core exceeds the row cap.
            m.cpu_topology_available = false
            index = m.physical_core_count
            m.physical_core_count += 1
            core = &m.physical_cores[index]
            core.package_id, core.core_id = -1, cpu
        }
        core.logical_ids[core.logical_count] = cpu
        core.logical_count += 1
    }
    if !m.cpu_topology_available {
        // Missing topology uses a consistently logical view, never a mixed unit.
        m.physical_cores = {}
        m.physical_core_count = 0
        for is_online, cpu in m._cpu_online {
            if !is_online { continue }
            core := &m.physical_cores[m.physical_core_count]
            core.package_id, core.core_id = -1, cpu
            core.logical_ids[0], core.logical_count = cpu, 1
            m.physical_core_count += 1
        }
    }
    m.cpu_topology_generation += 1
    m._cpu_topology_ready = true
}

telemetry_cpu_frequency :: proc(m: ^Metrics, cpu: int) -> (mhz: f32, source: CPU_Frequency_Source) {
    path_buffer: [128]u8
    value_buffer: [64]u8
    // Kernel CPU feedback is measured. scaling_cur_freq may be a driver request.
    filenames := [3]string{"cpuinfo_avg_freq", "cpuinfo_cur_freq", "scaling_cur_freq"}
    for filename in filenames {
        path := fmt.bprintf(path_buffer[:], "/sys/devices/system/cpu/cpu%d/cpufreq/%s", cpu, filename)
        value := strings.trim_space(telemetry_read(path, value_buffer[:]))
        if len(value) == 0 { continue }
        khz, ok := strconv.parse_u64(value)
        if !ok || khz == 0 { continue }
        source = .Measured
        if filename == "scaling_cur_freq" { source = .Driver }
        return f32(f64(khz)/1000), source
    }
    return 0, .None
}

telemetry_drop_perf_capability :: proc() -> bool {
    // CAP_PERFMON is only needed to open the package counters. Existing fds
    // remain usable, so revoke it before loading drivers or starting the UI.
    header := struct { version: u32, pid: i32 } { version = 0x20080522 }
    data: [2]struct { effective, permitted, inheritable: u32 }
    if linux.syscall(linux.SYS_capget, &header, &data) != 0 { return false }
    perfmon := u32(1)<<6 // Linux capability 38 occupies bit 6 of the second word.
    if (data[1].effective|data[1].permitted|data[1].inheritable)&perfmon != 0 {
        data[1].effective &= ~perfmon
        data[1].permitted &= ~perfmon
        data[1].inheritable &= ~perfmon
        if linux.syscall(linux.SYS_capset, &header, &data) != 0 {return false}
    }
    return linux.prctl(38,1,0,0,0)==nil // PR_SET_NO_NEW_PRIVS: never regain file capabilities on exec.
}

metrics_init_cpu_perf_power :: proc(m: ^Metrics) -> bool {
    // The RAPL PMU exports package energy without opening root-only energy_uj.
    // System-wide events need CAP_PERFMON when perf_event_paranoid restricts them.
    value_buffer: [256]u8
    pmu_type, type_ok := strconv.parse_u64(strings.trim_space(telemetry_read("/sys/bus/event_source/devices/power/type", value_buffer[:])))
    if !type_ok || pmu_type > 0xffffffff { return false }
    event := strings.trim_space(telemetry_read("/sys/bus/event_source/devices/power/events/energy-pkg", value_buffer[:]))
    if !strings.has_prefix(event, "event=") { return false }
    config, config_ok := strconv.parse_u64(event[len("event="):])
    if !config_ok { return false }
    scale, scale_ok := strconv.parse_f64(strings.trim_space(telemetry_read("/sys/bus/event_source/devices/power/events/energy-pkg.scale", value_buffer[:])))
    if !scale_ok || !(scale > 0) { return false }
    if strings.trim_space(telemetry_read("/sys/bus/event_source/devices/power/events/energy-pkg.unit", value_buffer[:])) != "Joules" { return false }
    cpumask := strings.trim_space(telemetry_read("/sys/bus/event_source/devices/power/cpumask", value_buffer[:]))
    domains: [16]CPU_Power_Domain
    domain_count := 0
    complete := false
    defer {
        if !complete {
            for domain in domains[:domain_count] { _ = linux.close(domain.perf_fd) }
        }
    }
    for part in strings.split_by_byte_iterator(&cpumask, ',') {
        first, last: int
        dash := strings.index_byte(part, '-')
        valid: bool
        if dash < 0 {
            first, valid = strconv.parse_int(part)
            last = first
        } else {
            first, valid = strconv.parse_int(part[:dash])
            if !valid { return false }
            last, valid = strconv.parse_int(part[dash+1:])
        }
        if !valid || first < 0 || last < first || last >= len(m.cores) { return false }
        for cpu in first..=last {
            path_buffer: [128]u8
            package_buffer: [32]u8
            path := fmt.bprintf(path_buffer[:], "/sys/devices/system/cpu/cpu%d/topology/physical_package_id", cpu)
            package_id, package_ok := strconv.parse_int(strings.trim_space(telemetry_read(path, package_buffer[:])))
            if !package_ok || package_id < 0 { return false }
            duplicate := false
            for domain in domains[:domain_count] {
                if domain.package_id == package_id { duplicate = true; break }
            }
            if duplicate { continue }
            if domain_count >= len(domains) { return false }
            attr := linux.Perf_Event_Attr {
                type = linux.Perf_Event_Type(pmu_type),
                size = u32(size_of(linux.Perf_Event_Attr)),
                read_format = {.TOTAL_TIME_ENABLED, .TOTAL_TIME_RUNNING},
            }
            attr.config.other = config
            // RAPL cannot exclude kernel/hypervisor work: it measures the package.
            fd, err := linux.perf_event_open(&attr, -1, cpu, -1, {.FD_CLOEXEC})
            if err != nil {
                metrics_cpu_power_error(m, fmt.bprintf(path_buffer[:], "Opening package-energy perf counter on CPU %d", cpu), err)
                return false
            }
            domains[domain_count] = CPU_Power_Domain { package_id = package_id, perf_fd = fd, perf_open = true, joules_per_count = scale }
            domain_count += 1
        }
    }
    if domain_count == 0 { return false }
    m._cpu_power_domains = domains
    m._cpu_power_domain_count = domain_count
    m.cpu_power_source = .Perf
    m.cpu_power_error_len = 0
    m.cpu_power_permission_denied = false
    complete = true
    return true
}

metrics_init_cpu_power :: proc(m: ^Metrics) {
    metrics_cpu_power_error(m, "No package power counter found")
    // Only package domains count; child core/uncore domains overlap their parent.
    fd, err := linux.open("/sys/class/powercap", {.DIRECTORY})
    energy_readable := true
    if err == nil {
        directory_buffer: [8192]u8
        for {
            count, read_error := linux.getdents(fd, directory_buffer[:])
            if read_error != nil || count <= 0 { break }
            offset := 0
            for {
                entry, ok := linux.dirent_iterate_buf(directory_buffer[:count], &offset)
                if !ok { break }
                name := linux.dirent_name(entry)
                if name == "." || name == ".." { continue }
                path_buffer: [256]u8
                value_buffer: [128]u8
                path := fmt.bprintf(path_buffer[:], "/sys/class/powercap/%s/name", name)
                label := strings.trim_space(telemetry_read(path, value_buffer[:]))
                if !strings.has_prefix(label, "package-") || m._cpu_power_domain_count >= len(m._cpu_power_domains) { continue }
                package_id, package_ok := strconv.parse_int(label[len("package-"):])
                if !package_ok || package_id < 0 { continue }
                duplicate := false
                for existing in m._cpu_power_domains[:m._cpu_power_domain_count] {
                    if existing.package_id == package_id { duplicate = true; break }
                }
                if duplicate { continue }
                domain := &m._cpu_power_domains[m._cpu_power_domain_count]
                domain.package_id = package_id
                path = fmt.bprintf(path_buffer[:], "/sys/class/powercap/%s/max_energy_range_uj", name)
                domain.energy_range = telemetry_uint(strings.trim_space(telemetry_read(path, value_buffer[:])))
                path = fmt.bprintf(path_buffer[:], "/sys/class/powercap/%s/energy_uj", name)
                domain.path_len = copy(domain.path[:], path)
                access_error: linux.Errno
                _, readable := strconv.parse_u64(strings.trim_space(telemetry_read(path, value_buffer[:], &access_error)))
                if !readable { metrics_cpu_power_error(m, path, access_error) }
                energy_readable = energy_readable && readable
                m._cpu_power_domain_count += 1
            }
        }
        _ = linux.close(fd)
    }
    if m._cpu_power_domain_count > 0 {
        m.cpu_power_source = .Energy
        if energy_readable {
            m.cpu_power_error_len = 0
            m.cpu_power_permission_denied = false
            return
        }
    }
    if metrics_init_cpu_perf_power(m) { return }
    // Package/PPT sensors are an alternative to energy deltas, never an addition.
    sensor_domains: [16]CPU_Power_Domain
    sensor_count := 0
    fd, err = linux.open("/sys/class/hwmon", {.DIRECTORY})
    if err != nil { return }
    defer linux.close(fd)
    directory_buffer: [8192]u8
    for {
        count, read_error := linux.getdents(fd, directory_buffer[:])
        if read_error != nil || count <= 0 { break }
        offset := 0
        for {
            entry, ok := linux.dirent_iterate_buf(directory_buffer[:count], &offset)
            if !ok { break }
            name := linux.dirent_name(entry)
            if !strings.has_prefix(name, "hwmon") || sensor_count >= len(sensor_domains) { continue }
            path_buffer: [256]u8
            value_buffer: [128]u8
            path := fmt.bprintf(path_buffer[:], "/sys/class/hwmon/%s/name", name)
            driver := strings.trim_space(telemetry_read(path, value_buffer[:]))
            if driver != "k10temp" && driver != "zenpower" && driver != "amd_energy" && driver != "fam15h_power" { continue }
            legacy_package := driver == "fam15h_power"
            for channel in 1..=32 {
                path = fmt.bprintf(path_buffer[:], "/sys/class/hwmon/%s/power%d_label", name, channel)
                label := strings.trim_space(telemetry_read(path, value_buffer[:]))
                package_sensor := strings.has_prefix(label, "Package") || strings.has_prefix(label, "package") || strings.has_prefix(label, "Socket") || strings.has_prefix(label, "socket") || label == "PPT"
                if !package_sensor && !(legacy_package && channel == 1) { continue }
                found := false
                suffixes := [2]string{"input", "average"}
                for suffix in suffixes {
                    path = fmt.bprintf(path_buffer[:], "/sys/class/hwmon/%s/power%d_%s", name, channel, suffix)
                    _, readable := strconv.parse_u64(strings.trim_space(telemetry_read(path, value_buffer[:])))
                    if !readable { continue }
                    domain := &sensor_domains[sensor_count]
                    domain.path_len = copy(domain.path[:], path)
                    domain.package_id = -1 // CPU hwmon device names need not encode package IDs.
                    sensor_count += 1
                    found = true
                    break
                }
                // One package reading per CPU hwmon device prevents domain overlap.
                if found { break }
            }
        }
    }
    if sensor_count > 0 {
        m._cpu_power_domains = sensor_domains
        m._cpu_power_domain_count = sensor_count
        m.cpu_power_source = .Sensor
        m.cpu_power_error_len = 0
        m.cpu_power_permission_denied = false
    }
}

metrics_sample_cpu_power :: proc(m: ^Metrics, elapsed: f64) {
    m.cpu_power_available = false
    m.cpu_power_watts = 0
    if m._cpu_power_domain_count == 0 { return }
    metrics_cpu_power_error(m, "Waiting for sample")
    package_count := 0
    for core, i in m.physical_cores[:m.physical_core_count] {
        seen := false
        for previous in m.physical_cores[:i] {
            if previous.package_id == core.package_id { seen = true; break }
        }
        if !seen { package_count += 1 }
    }
    all_available := !m.cpu_topology_available || package_count == m._cpu_power_domain_count
    if m.cpu_topology_available && m.cpu_power_source != .Sensor {
        for domain in m._cpu_power_domains[:m._cpu_power_domain_count] {
            found := false
            for core in m.physical_cores[:m.physical_core_count] {
                if core.package_id == domain.package_id { found = true; break }
            }
            if !found { all_available = false }
        }
    }
    if !all_available { metrics_cpu_power_error(m, "Incomplete package counters") }
    watts: f64
    for &domain in m._cpu_power_domains[:m._cpu_power_domain_count] {
        if m.cpu_power_source == .Perf {
            // One binary counter read per package. Kernel energy counts already
            // handle hardware counter wraps; never sum overlapping child events.
            buffer: [24]u8
            count, err := linux.read(domain.perf_fd, buffer[:])
            if err != nil || count != len(buffer) {
                metrics_cpu_power_error(m, "Reading package-energy perf counter", err)
                domain.ready = false; all_available = false; continue
            }
            reading := transmute([3]u64)buffer
            value, enabled, running := reading[0], reading[1], reading[2]
            if !domain.ready || elapsed <= 0 || value < domain.previous_energy || enabled < domain.previous_enabled || running <= domain.previous_running {
                all_available = false
            } else {
                enabled_delta := enabled-domain.previous_enabled
                running_delta := running-domain.previous_running
                watts += f64(value-domain.previous_energy)*domain.joules_per_count*f64(enabled_delta)/f64(running_delta)/elapsed
            }
            domain.previous_energy, domain.previous_enabled, domain.previous_running = value, enabled, running
            domain.ready = true
            continue
        }
        value_buffer: [128]u8
        access_error: linux.Errno
        path := string(domain.path[:domain.path_len])
        value, ok := strconv.parse_u64(strings.trim_space(telemetry_read(path, value_buffer[:], &access_error)))
        if !ok {
            metrics_cpu_power_error(m, path, access_error)
            domain.ready = false; all_available = false; continue
        }
        if m.cpu_power_source == .Sensor {
            watts += f64(value)/1e6 // Linux hwmon power is microwatts.
            continue
        }
        if !domain.ready || elapsed <= 0 {
            all_available = false
        } else if value >= domain.previous_energy {
            watts += f64(value-domain.previous_energy)/1e6/elapsed
        } else if domain.energy_range > 0 && domain.previous_energy < domain.energy_range && value < domain.energy_range {
            watts += f64(domain.energy_range-domain.previous_energy+value)/1e6/elapsed
        } else {
            all_available = false
        }
        domain.previous_energy = value
        domain.ready = true
    }
    if all_available {
        m.cpu_power_available = true
        m.cpu_power_watts = f32(watts)
        m.cpu_power_error_len = 0
        m.cpu_power_permission_denied = false
    }
}

metrics_sample_memory :: proc(m: ^Metrics) {
    text := telemetry_read("/proc/meminfo", m._scratch[:])
    m.ram_available = len(text) > 0
    m.memory_free,m.memory_cached,m.memory_buffers=0,0,0
    cached,reclaimable,shared:u64
    free_read,cache_read,buffers_read:bool
    for line in strings.split_lines_iterator(&text) {
        fields: [3]string
        if telemetry_fields(line, fields[:]) < 2 { continue }
        value := telemetry_uint(fields[1])*1024
        switch fields[0] {
        case "MemTotal:": m.memory_total = value
        case "MemAvailable:": m.memory_available = value
        case "MemFree:": m.memory_free=value;free_read=true
        case "Cached:": cached=value;cache_read=true
        case "Buffers:": m.memory_buffers=value;buffers_read=true
        case "SReclaimable:": reclaimable=value
        case "Shmem:": shared=value
        case "SwapTotal:": m.swap_total = value
        case "SwapFree:": m.swap_used = value
        }
    }
    m.memory_used = m.memory_total-min(m.memory_total, m.memory_available)
    // File cache plus reclaimable slab, excluding shared/tmpfs memory.
    cache_total:=cached+reclaimable
    m.memory_cached=min(m.memory_total,cache_total-min(cache_total,shared))
    m.memory_free=min(m.memory_total,m.memory_free)
    m.memory_buffers=min(m.memory_total,m.memory_buffers)
    m.memory_free_available,m.memory_cached_available,m.memory_buffers_available=free_read,cache_read,buffers_read
    m.memory_breakdown_available=m.ram_available&&free_read&&cache_read&&buffers_read
    m.swap_used = m.swap_total-min(m.swap_total, m.swap_used)
}

metrics_sample_io :: proc(m: ^Metrics, elapsed: f64) {
    rx, tx: u64
    text := telemetry_read("/proc/net/dev", m._scratch[:])
    for line in strings.split_lines_iterator(&text) {
        colon := strings.index_byte(line, ':')
        if colon < 0 || strings.trim_space(line[:colon]) == "lo" { continue }
        fields: [16]string
        if telemetry_fields(line[colon+1:], fields[:]) < 9 { continue }
        rx += telemetry_uint(fields[0])
        tx += telemetry_uint(fields[8])
    }
    m.network_rx = telemetry_rate(rx, m._network_rx, elapsed, m.rates_ready)
    m.network_tx = telemetry_rate(tx, m._network_tx, elapsed, m.rates_ready)
    m._network_rx, m._network_tx = rx, tx
    read, write: u64
    text = telemetry_read("/proc/diskstats", m._scratch[:])
    for line in strings.split_lines_iterator(&text) {
        fields: [20]string
        if telemetry_fields(line, fields[:]) < 10 { continue }
        name := fields[2]
        if strings.has_prefix(name, "loop") || strings.has_prefix(name, "ram") || strings.has_prefix(name, "dm-") || strings.has_prefix(name, "md") { continue }
        // sysfs exposes /partition only for partitions, not whole disks.
        path_buffer: [128]u8
        path := fmt.bprintf(path_buffer[:], "/sys/class/block/%s/partition", name)
        partition_buffer: [16]u8
        if telemetry_read(path, partition_buffer[:]) != "" { continue }
        read += telemetry_uint(fields[5])*512
        write += telemetry_uint(fields[9])*512
    }
    m.disk_read = telemetry_rate(read, m._disk_read, elapsed, m.rates_ready)
    m.disk_write = telemetry_rate(write, m._disk_write, elapsed, m.rates_ready)
    m._disk_read, m._disk_write = read, write
}

telemetry_system_service :: proc(pid:i32, directory:linux.Fd)->bool {
    path_buffer:[64]u8
    buffer:[2048]u8
    path:=fmt.bprintf(path_buffer[:],"%d/cgroup",pid)
    cgroups:=telemetry_read(path,buffer[:],directory=directory)
    // Match the cgroup path, never the service name, UID or parent PID.
    // Unreadable, truncated or unfamiliar metadata leaves a process visible.
    if len(cgroups)==len(buffer) {return false}
    for line in strings.split_lines_iterator(&cgroups) {
        colon:=strings.index_byte(line,':')
        if colon<0 {continue}
        rest:=line[colon+1:]
        colon=strings.index_byte(rest,':')
        if colon<0 {continue}
        group:=rest[colon+1:]
        if group=="/system.slice"||strings.has_prefix(group,"/system.slice/") {return true}
    }
    return false
}

metrics_sample_processes :: proc(m: ^Metrics, elapsed: f64) {
    m._generation += 1
    m.process_count, m.total_processes = 0, 0
    m.memory_process_count = 0
    m.total_process_groups, m._group_pid_count = 0, 0
    m.process_group_overflow = false
    for &slot in m._group_table {slot=0}
    fd, err := linux.open("/proc", {.DIRECTORY})
    if err != nil { return }
    defer linux.close(fd)
    directory_buffer: [32768]u8
    for {
        count, read_error := linux.getdents(fd, directory_buffer[:])
        if read_error != nil || count <= 0 { break }
        offset := 0
        for {
            entry, ok := linux.dirent_iterate_buf(directory_buffer[:count], &offset)
            if !ok { break }
            name := linux.dirent_name(entry)
            if len(name) == 0 || name[0] < '1' || name[0] > '9' { continue }
            pid := i32(telemetry_uint(name))
            if pid <= 0 { continue }
            path_buffer: [64]u8
            // Reuse the open procfs directory instead of resolving /proc for every PID.
            path := fmt.bprintf(path_buffer[:], "%s/stat", name)
            stat := telemetry_read(path, m._scratch[:4096], directory=fd)
            open := strings.index_byte(stat, '(')
            close := strings.last_index_byte(stat, ')')
            if open < 0 || close <= open || close+2 >= len(stat) { continue }
            fields: [24]string
            if telemetry_fields(stat[close+2:], fields[:]) < 22 { continue }
            process := Process_Metric{pid = pid}
            process.name_len = copy(process.name[:], stat[open+1:close])
            ticks := telemetry_uint(fields[11])+telemetry_uint(fields[12])
            start := telemetry_uint(fields[19])
            process.start = start
            process.memory_bytes = u64(f64(telemetry_uint(fields[21]))*m._page_size)
            kernel_thread:=(telemetry_uint(fields[6])&0x00200000)!=0 // Linux PF_KTHREAD.
            if old := metrics_process_history(m, pid); old != nil {
                if m.rates_ready && elapsed > 0 && old.pid == pid && old.start == start && old.generation+1 == m._generation && ticks >= old.ticks {
                    process.cpu_percent = f32(f64(ticks-old.ticks)/m._ticks_per_second/elapsed*100)
                }
                role_generation:=m._generation
                if kernel_thread {process.system_process=true}
                else if old.pid==pid&&old.start==start&&old.role_generation+10>m._generation {
                    process.system_process=old.system_process
                    role_generation=old.role_generation
                } else {process.system_process=telemetry_system_service(pid,fd)}
                old^ = Process_History{pid = pid, ticks = ticks, start = start, generation = m._generation, cpu_percent = process.cpu_percent, system_process=process.system_process, role_generation=role_generation}
            } else {
                process.system_process=kernel_thread||telemetry_system_service(pid,fd)
            }
            metrics_groups_ensure(&m._groups,&m._group_table,m.total_process_groups,MAX_SYSTEM_PIDS)
            metrics_buffer_ensure(&m._pid_links,min(m._group_pid_count+1,MAX_SYSTEM_PIDS))
            if !metrics_add_group_process(m._groups[:], m._group_table[:], &m.total_process_groups, m._pid_links[:], &m._group_pid_count, process) {
                m.process_group_overflow = true
            }
            m.total_processes += 1
        }
    }
    metrics_buffer_ensure(&m.process_pids,m._group_pid_count)
    metrics_finalize_group_pids(m._groups[:m.total_process_groups], m._pid_links[:m._group_pid_count], m.process_pids[:])
    for index in 0..<m.total_process_groups {
        group := m._groups[index]
        metrics_insert_ranked(m.processes[:], &m.process_count, group)
        metrics_insert_ranked(m.memory_processes[:], &m.memory_process_count, group, memory = true)
    }
}

// NVML may report the same PID in compute/graphics lists and on several GPUs.
// Sort once, then reduce in place: max within one GPU, sum across GPUs.
metrics_sample :: proc(m: ^Metrics, elapsed: f64) {
    m._sample_started=time.tick_now()
    metrics_sample_cpu(m)
    metrics_sample_cpu_power(m, elapsed)
    metrics_sample_memory(m)
    metrics_sample_io(m, elapsed)
    uptime := telemetry_read("/proc/uptime", m._scratch[:])
    fields: [4]string
    if telemetry_fields(uptime, fields[:]) >= 1 { m.uptime, _ = strconv.parse_f64(fields[0]) }
    load := telemetry_read("/proc/loadavg", m._scratch[:])
    if telemetry_fields(load, fields[:]) >= 3 {
        for i in 0..<3 { m.load[i], _ = strconv.parse_f64(fields[i]) }
    }
    metrics_sample_processes(m, elapsed)
    metrics_sample_gpu(m)
    m.rates_ready = true
}

metrics_gpu_process_details :: proc(m: ^Metrics, process: ^Process_Metric) {
        path_buffer: [64]u8
        path := fmt.bprintf(path_buffer[:], "/proc/%d/stat", process.pid)
        stat := telemetry_read(path, m._scratch[:4096])
        open := strings.index_byte(stat, '(')
        close := strings.last_index_byte(stat, ')')
        if open >= 0 && close > open+1 && close+2 < len(stat) {
            process.name_len = copy(process.name[:], stat[open+1:close])
            fields: [24]string
            if telemetry_fields(stat[close+2:], fields[:]) >= 22 {
                process.start = telemetry_uint(fields[19])
                process.memory_bytes = u64(f64(telemetry_uint(fields[21]))*m._page_size)
                if old := metrics_process_history(m, process.pid,create=false); old != nil && old.pid == process.pid && old.generation == m._generation && old.start == telemetry_uint(fields[19]) {
                    process.cpu_percent = old.cpu_percent
                    process.system_process=old.system_process
                }
            }
        } else {
            // Procfs can deny access or the process can exit between snapshots.
            fallback_buffer: [32]u8
            fallback := fmt.bprintf(fallback_buffer[:], "PID %d", process.pid)
            process.name_len = copy(process.name[:], fallback)
        }
}

metrics_destroy_platform :: proc(m: ^Metrics) {
    for &domain in m._cpu_power_domains[:m._cpu_power_domain_count] {
        if domain.perf_open { _ = linux.close(domain.perf_fd); domain.perf_open = false }
    }
}

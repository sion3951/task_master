#+build windows
package main

import "core:fmt"
import "core:math"
import "core:strings"
import "core:sys/windows"
import "core:time"
import "core:unicode/utf16"

foreign import tm_kernel32 "system:kernel32.lib"
foreign import tm_pdh "system:pdh.lib"
foreign import tm_ntdll "system:ntdll.lib"
foreign import tm_psapi "system:psapi.lib"
foreign import tm_advapi32 "system:advapi32.lib"

// These narrow declarations cover APIs not currently exposed by Odin's Win32
// bindings. Keep UTF-16 and native pointer widths at every ABI boundary.
@(default_calling_convention="system")
foreign tm_kernel32 {
    GetTickCount64 :: proc() -> u64 ---
    GetComputerNameW :: proc(^u16, ^u32) -> i32 ---
    GetActiveProcessorGroupCount :: proc() -> u16 ---
    GetActiveProcessorCount :: proc(u16) -> u32 ---
    GetLogicalProcessorInformationEx :: proc(u32, rawptr, ^u32) -> i32 ---
}
Windows_PDH_Value :: struct { status:u32, value:f64 }
Windows_PDH_Item :: struct { name:[^]u16, using reading:Windows_PDH_Value }
@(default_calling_convention="system")
foreign tm_pdh {
    PdhOpenQueryW :: proc(rawptr, uintptr, ^rawptr) -> u32 ---
    PdhAddEnglishCounterW :: proc(rawptr, ^u16, uintptr, ^rawptr) -> u32 ---
    PdhCollectQueryData :: proc(rawptr) -> u32 ---
    PdhGetFormattedCounterValue :: proc(rawptr, u32, ^u32, ^Windows_PDH_Value) -> u32 ---
    PdhGetFormattedCounterArrayW :: proc(rawptr, u32, ^u32, ^u32, rawptr) -> u32 ---
    PdhCloseQuery :: proc(rawptr) -> u32 ---
}
@(default_calling_convention="system")
foreign tm_ntdll { NtQuerySystemInformation :: proc(u32, rawptr, u32, ^u32) -> i32 --- }
Windows_Pagefile_Info :: struct { size, reserved:u32, total, used, peak:uintptr }
@(default_calling_convention="system")
foreign tm_psapi {
    EnumPageFilesW :: proc(proc "system"(rawptr,^Windows_Pagefile_Info,[^]u16)->i32,rawptr)->i32 ---
}
Windows_Service_Status :: struct { service_type,state,controls,win32_exit,service_exit,checkpoint,wait_hint,pid,flags:u32 }
Windows_Service_Entry :: struct { name,display_name:rawptr, status:Windows_Service_Status }
@(default_calling_convention="system")
foreign tm_advapi32 {
    OpenSCManagerW :: proc(rawptr,rawptr,u32)->windows.HANDLE ---
    EnumServicesStatusExW :: proc(windows.HANDLE,u32,u32,u32,rawptr,u32,^u32,^u32,^u32,rawptr)->i32 ---
    CloseServiceHandle :: proc(windows.HANDLE)->i32 ---
}
Windows_Native_Process :: struct {
    next,thread_count:u32,
    private_working_set:i64,
    hard_faults,thread_high_water:u32,
    cycle_time:u64,
    start,user,kernel:i64,
    name_length,name_maximum:u16,
    name:[^]u16,
    priority:i32,
    pid,parent:uintptr,
    handles,session:u32,
    key,peak_virtual,virtual_size:uintptr,
    page_faults:u32,
    peak_working_set,working_set:uintptr,
}
Windows_Group_Affinity :: struct { mask:uintptr, group:u16, reserved:[3]u16 }
Windows_CPU_Relationship :: struct { relationship,size:u32, flags,efficiency:u8, reserved:[20]u8, group_count:u16, masks:[1]Windows_Group_Affinity }
Windows_Sensor_Snapshot :: struct #packed {
    magic,version:u32,
    uptime_ms:u64,
    power_watts:f32,
    flags,core_count,reserved:u32,
    frequencies:[256]f32,
    error:[384]u8,
    error_len:u32,
}
#assert(size_of(Windows_Sensor_Snapshot)==1444)
CPU_Power_Domain :: struct { _unused:u8 }
Windows_Sampler :: struct {
    query:rawptr,
    busy,frequency,queue,free,standby_core,standby_normal,standby_reserve,modified:rawptr,
    network_rx,network_tx,disk_read,disk_write,gpu_memory,gpu_engine:rawptr,
    pdh_buffer,process_buffer,topology_buffer,service_buffer:[dynamic]u64,
    services:[dynamic]i32,
    groups:[16]int,
    group_count:int,
    clocks:[256]f32,
    sensor_clocks:[256]f32,
    sensor_clocks_valid:bool,
    process_snapshot:[]u8,
    load_last:time.Tick,
}

windows_wide :: proc(s:string)->[]u16 {
    b:=make([]u16,len(s)+1,context.temp_allocator)
    n:=utf16.encode_string(b,s)
    return b[:n+1]
}
windows_utf8 :: proc(destination:[]u8,s:[]u16)->int { return utf16.decode_to_utf8(destination,s) }
windows_wide_name :: proc(s:[^]u16, destination:[]u8)->string {
    n:=0
    for n<4096&&s[n]!=0 {n+=1}
    return string(destination[:windows_utf8(destination,s[:n])])
}
windows_sampler :: proc(m:^Metrics)->^Windows_Sampler { return cast(^Windows_Sampler)m._platform }
windows_counter_add :: proc(w:^Windows_Sampler,path:string)->rawptr {
    handle:rawptr
    text:=windows_wide(path)
    if w.query==nil||PdhAddEnglishCounterW(w.query,raw_data(text),0,&handle)!=0 {return nil}
    return handle
}
windows_counter_value :: proc(counter:rawptr)->(f64,bool) {
    value:Windows_PDH_Value
    if counter==nil||PdhGetFormattedCounterValue(counter,0x200|0x1000,nil,&value)!=0||value.status>1||!windows_finite(value.value)||value.value<0 {return 0,false}
    return value.value,true
}
windows_counter_array :: proc(w:^Windows_Sampler,counter:rawptr)->([]Windows_PDH_Item,bool) {
    if counter==nil {return nil,false}
    size,count:u32
    _=PdhGetFormattedCounterArrayW(counter,0x200|0x8000|0x1000,&size,&count,nil)
    if size==0 {return nil,false}
    metrics_buffer_ensure(&w.pdh_buffer,(int(size)+7)/8)
    if PdhGetFormattedCounterArrayW(counter,0x200|0x8000|0x1000,&size,&count,raw_data(w.pdh_buffer))!=0||int(count)*size_of(Windows_PDH_Item)>int(size) {return nil,false}
    return (cast([^]Windows_PDH_Item)raw_data(w.pdh_buffer))[:count],true
}
metrics_cpu_power_error :: proc(m:^Metrics,message:string) {
    m.cpu_power_error_len=copy(m.cpu_power_error[:],message)
    m.cpu_power_permission_denied=false
}
metrics_init_cpu :: proc(m:^Metrics) {
    m.platform="windows"
    if m._sampler==nil {m._sampler=new(Metrics_Sampler)}
    w:=new(Windows_Sampler)
    m._platform=w
    m._ticks_per_second=10000000
    info:windows.SYSTEM_INFO
    windows.GetSystemInfo(&info)
    m._page_size=f64(info.dwPageSize)
    name:[128]u16
    length:=u32(len(name))
    if GetComputerNameW(&name[0],&length)!=0 {m.hostname=string(m._hostname[:windows_utf8(m._hostname[:],name[:length])])}
    subkey:=windows_wide("HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0")
    key:=windows_wide("ProcessorNameString")
    model:[192]u16
    bytes:=u32(size_of(model))
    if windows.RegGetValueW(windows.HKEY_LOCAL_MACHINE,cstring16(raw_data(subkey)),cstring16(raw_data(key)),2,nil,&model,&bytes)==0 {
        count:=min(int(bytes)/2,len(model))
        for count>0&&model[count-1]==0 {count-=1}
        m.cpu_model=string(m._cpu_model[:windows_utf8(m._cpu_model[:],model[:count])])
    }
    if m.cpu_model=="" {m.cpu_model="CPU"}
    _=PdhOpenQueryW(nil,0,&w.query)
    w.busy=windows_counter_add(w,"\\Processor Information(*)\\% Processor Time")
    w.frequency=windows_counter_add(w,"\\Processor Information(*)\\Processor Frequency")
    w.queue=windows_counter_add(w,"\\System\\Processor Queue Length")
    w.free=windows_counter_add(w,"\\Memory\\Free & Zero Page List Bytes")
    w.standby_core=windows_counter_add(w,"\\Memory\\Standby Cache Core Bytes")
    w.standby_normal=windows_counter_add(w,"\\Memory\\Standby Cache Normal Priority Bytes")
    w.standby_reserve=windows_counter_add(w,"\\Memory\\Standby Cache Reserve Bytes")
    w.modified=windows_counter_add(w,"\\Memory\\Modified Page List Bytes")
    w.network_rx=windows_counter_add(w,"\\Network Interface(*)\\Bytes Received/sec")
    w.network_tx=windows_counter_add(w,"\\Network Interface(*)\\Bytes Sent/sec")
    w.disk_read=windows_counter_add(w,"\\PhysicalDisk(_Total)\\Disk Read Bytes/sec")
    w.disk_write=windows_counter_add(w,"\\PhysicalDisk(_Total)\\Disk Write Bytes/sec")
    w.gpu_memory=windows_counter_add(w,"\\GPU Process Memory(*)\\Dedicated Usage")
    w.gpu_engine=windows_counter_add(w,"\\GPU Engine(*)\\Utilization Percentage")
    metrics_refresh_cpu_topology(m)
    metrics_cpu_power_error(m,"Windows sensor helper unavailable; install task_master Sensors for CPU package power")
    w.load_last=time.tick_now()
}
metrics_refresh_cpu_topology :: proc(m:^Metrics) {
    w:=windows_sampler(m)
    w.group_count=min(int(GetActiveProcessorGroupCount()),len(w.groups))
    total:=0
    for group in 0..<w.group_count {w.groups[group]=total;total+=int(GetActiveProcessorCount(u16(group)))}
    m.cpu_count=min(total,len(m.cores));m.cpu_online_count=m.cpu_count
    for &online,i in m._cpu_online {online=i<m.cpu_count}
    size:u32
    _=GetLogicalProcessorInformationEx(0xffff,nil,&size)
    if size==0 {return}
    metrics_buffer_ensure(&w.topology_buffer,(int(size)+7)/8)
    if GetLogicalProcessorInformationEx(0xffff,raw_data(w.topology_buffer),&size)==0 {return}
    data:=(cast([^]u8)raw_data(w.topology_buffer))[:size]
    packages:[256]int
    package_index:=0
    // Package records and core records are not guaranteed to arrive together.
    for offset:=0;offset+8<=len(data); {
        entry:=cast(^Windows_CPU_Relationship)&data[offset]
        if entry.size<8||offset+int(entry.size)>len(data) {break}
        if entry.relationship==3&&entry.size>=32 {
            masks:=(cast([^]Windows_Group_Affinity)&data[offset+32])[:min(int(entry.group_count),(int(entry.size)-32)/size_of(Windows_Group_Affinity))]
            for mask in masks {if int(mask.group)<w.group_count {for bit in 0..<64 {logical:=w.groups[mask.group]+bit;if logical<m.cpu_count&&(mask.mask&(uintptr(1)<<uint(bit)))!=0 {packages[logical]=package_index}}}}
            package_index+=1
        }
        offset+=int(entry.size)
    }
    m.physical_core_count=0;m.physical_cores={}
    for offset:=0;offset+8<=len(data); {
        entry:=cast(^Windows_CPU_Relationship)&data[offset]
        if entry.size<8||offset+int(entry.size)>len(data) {break}
        if entry.relationship==0&&entry.size>=32&&m.physical_core_count<len(m.physical_cores) {
            core:=&m.physical_cores[m.physical_core_count]
            core.core_id=m.physical_core_count
            masks:=(cast([^]Windows_Group_Affinity)&data[offset+32])[:min(int(entry.group_count),(int(entry.size)-32)/size_of(Windows_Group_Affinity))]
            for mask in masks {if int(mask.group)<w.group_count {for bit in 0..<64 {logical:=w.groups[mask.group]+bit;if logical<m.cpu_count&&(mask.mask&(uintptr(1)<<uint(bit)))!=0&&core.logical_count<len(core.logical_ids) {core.logical_ids[core.logical_count]=logical;core.logical_count+=1;core.package_id=packages[logical]}}}}
            if core.logical_count>0 {m.physical_core_count+=1}
        }
        offset+=int(entry.size)
    }
    m.cpu_topology_available=m.physical_core_count>0
    m._cpu_topology_ready=m.cpu_topology_available;m.cpu_topology_generation+=1
}
windows_processor_instance :: proc(w:^Windows_Sampler,name:string)->int {
    comma:=strings.index_byte(name,',')
    if comma<0||name=="_Total"||strings.contains(name,"_Total") {return -1}
    group:=int(telemetry_uint(name[:comma]));cpu:=int(telemetry_uint(name[comma+1:]))
    if group<0||group>=w.group_count||cpu<0||cpu>=int(GetActiveProcessorCount(u16(group))) {return -1}
    return w.groups[group]+cpu
}
metrics_sample_cpu :: proc(m:^Metrics) {
    w:=windows_sampler(m)
    m.cpu_available=false;m.cpu_percent=0;m.cores={};w.clocks={}
    items,ok:=windows_counter_array(w,w.busy)
    if ok {for item in items {
        if item.status>1||!windows_finite(item.value) {continue}
        buf:[256]u8
        name:=windows_wide_name(item.name,buf[:])
        index:=windows_processor_instance(w,name)
        if index>=0&&index<m.cpu_count {m.cores[index]=f32(clamp(item.value,0,100));m.cpu_percent+=m.cores[index];m.cpu_available=true}
    }}
    if m.cpu_count>0 {m.cpu_percent/=f32(m.cpu_count)}
    items,ok=windows_counter_array(w,w.frequency)
    if ok {for item in items {
        if item.status>1||!windows_finite(item.value)||item.value<=0 {continue}
        buf:[256]u8
        index:=windows_processor_instance(w,windows_wide_name(item.name,buf[:]))
        if index>=0&&index<m.cpu_count {w.clocks[index]=f32(item.value)}
    }}
}
telemetry_cpu_frequency :: proc(m:^Metrics,cpu:int)->(f32,CPU_Frequency_Source) {
    w:=windows_sampler(m)
    if w.sensor_clocks_valid&&w.sensor_clocks[cpu]>0 {return w.sensor_clocks[cpu],.Measured}
    if w.clocks[cpu]>0 {return w.clocks[cpu],.Driver}
    return 0,.None
}
metrics_sample_cpu_power :: proc(m:^Metrics,elapsed:f64) {
    w:=windows_sampler(m)
    m.cpu_power_available=false;w.sensor_clocks_valid=false;w.sensor_clocks={}
    path:=windows_wide("\\\\.\\pipe\\task_master_sensors-v1")
    pipe:=windows.CreateFileW(cstring16(raw_data(path)),windows.GENERIC_READ,0,nil,windows.OPEN_EXISTING,windows.FILE_FLAG_OVERLAPPED,nil)
    if pipe==windows.INVALID_HANDLE_VALUE {
        metrics_cpu_power_error(m,"Windows sensor helper unavailable; install task_master Sensors for CPU package power")
        m.cpu_power_permission_denied=windows.GetLastError()==5
        return
    }
    defer windows.CloseHandle(pipe)
    event:=windows.CreateEventW(nil,true,false,nil)
    if event==nil {return}
    defer windows.CloseHandle(event)
    overlapped:=windows.OVERLAPPED{hEvent=event}
    packet:Windows_Sensor_Snapshot
    count:u32
    completed:=windows.ReadFile(pipe,&packet,u32(size_of(packet)),&count,&overlapped)!=false
    if !completed&&windows.GetLastError()==997 {
        if windows.WaitForSingleObject(event,100)!=0 {
            _=windows.CancelIoEx(pipe,&overlapped)
            _=windows.GetOverlappedResult(pipe,&overlapped,&count,true)
            metrics_cpu_power_error(m,"Windows sensor helper did not respond")
            return
        }
        completed=windows.GetOverlappedResult(pipe,&overlapped,&count,false)!=false
    }
    now:=GetTickCount64()
    if !completed||count!=u32(size_of(packet))||packet.magic!=0x544d5753||packet.version!=1||packet.core_count>256||packet.error_len>384||packet.uptime_ms>now||now-packet.uptime_ms>5000 {
        metrics_cpu_power_error(m,"Windows sensor helper returned an invalid or stale snapshot")
        return
    }
    metrics_cpu_power_error(m,string(packet.error[:packet.error_len]))
    m.cpu_power_permission_denied=(packet.flags&2)!=0
    if packet.flags&1!=0&&windows_finite(packet.power_watts)&&packet.power_watts>=0 {
        m.cpu_power_watts=packet.power_watts;m.cpu_power_available=true;m.cpu_power_source=.Sensor
        m.cpu_power_error_len=0
    }
    for frequency,index in packet.frequencies[:packet.core_count] {
        if windows_finite(frequency)&&frequency>0 {w.sensor_clocks[index]=frequency;w.sensor_clocks_valid=true} else {w.sensor_clocks[index]=0}
    }
}
metrics_sample_memory :: proc(m:^Metrics) {
    info:=windows.MEMORYSTATUSEX{dwLength=u32(size_of(windows.MEMORYSTATUSEX))}
    m.ram_available=windows.GlobalMemoryStatusEx(&info)!=false
    if !m.ram_available {return}
    m.memory_total=info.ullTotalPhys;m.memory_available=info.ullAvailPhys
    m.memory_used=m.memory_total-min(m.memory_available,m.memory_total)
    w:=windows_sampler(m)
    free,free_ok:=windows_counter_value(w.free)
    core,core_ok:=windows_counter_value(w.standby_core)
    normal,normal_ok:=windows_counter_value(w.standby_normal)
    reserve,reserve_ok:=windows_counter_value(w.standby_reserve)
    modified,modified_ok:=windows_counter_value(w.modified)
    m.memory_free=min(m.memory_total,u64(free))
    m.memory_cached=min(m.memory_total,u64(core+normal+reserve))
    m.memory_buffers=min(m.memory_total,u64(modified))
    m.memory_free_available,m.memory_cached_available,m.memory_buffers_available=free_ok,core_ok&&normal_ok&&reserve_ok,modified_ok
    m.memory_breakdown_available=free_ok&&core_ok&&normal_ok&&reserve_ok&&modified_ok
    m.swap_total,m.swap_used=0,0
    // ullTotalPageFile is a commit limit, not pagefile size. Enumerate actual
    // pagefiles instead, including multiple files on different volumes.
    _=EnumPageFilesW(proc "system"(parameter:rawptr,info:^Windows_Pagefile_Info,name:[^]u16)->i32 {
        m:=cast(^Metrics)parameter
        m.swap_total+=u64(f64(info.total)*m._page_size)
        m.swap_used+=u64(f64(info.used)*m._page_size)
        return 1
    },m)
}
windows_counter_sum :: proc(w:^Windows_Sampler,counter:rawptr)->f64 {
    total:f64
    items,ok:=windows_counter_array(w,counter)
    if ok {for item in items {if item.status<=1&&windows_finite(item.value)&&item.value>0 {total+=item.value}}}
    return total
}
metrics_sample_io :: proc(m:^Metrics,elapsed:f64) {
    w:=windows_sampler(m)
    m.network_rx=windows_counter_sum(w,w.network_rx)
    m.network_tx=windows_counter_sum(w,w.network_tx)
    m.disk_read,_=windows_counter_value(w.disk_read)
    m.disk_write,_=windows_counter_value(w.disk_write)
}
windows_service_pids :: proc(w:^Windows_Sampler) {
    clear(&w.services)
    manager:=OpenSCManagerW(nil,nil,4)
    if manager==nil {return}
    defer CloseServiceHandle(manager)
    required,count,resume:u32
    _=EnumServicesStatusExW(manager,0,0x30,1,nil,0,&required,&count,&resume,nil)
    if required==0 {return}
    metrics_buffer_ensure(&w.service_buffer,(int(required)+7)/8)
    resume=0
    if EnumServicesStatusExW(manager,0,0x30,1,raw_data(w.service_buffer),u32(len(w.service_buffer)*8),&required,&count,&resume,nil)==0 {return}
    entries:=(cast([^]Windows_Service_Entry)raw_data(w.service_buffer))[:count]
    for entry in entries {if entry.status.pid!=0 {append(&w.services,i32(entry.status.pid))}}
}
windows_process_lookup :: proc(w:^Windows_Sampler,pid:i32)->^Windows_Native_Process {
    data:=w.process_snapshot
    for offset:=0;offset+size_of(Windows_Native_Process)<=len(data); {
        entry:=cast(^Windows_Native_Process)&data[offset]
        if entry.pid==uintptr(pid) {return entry}
        if entry.next==0||int(entry.next)<size_of(Windows_Native_Process) {break}
        offset+=int(entry.next)
    }
    return nil
}
metrics_sample_processes :: proc(m:^Metrics,elapsed:f64) {
    w:=windows_sampler(m)
    m._generation+=1;m.process_count,m.memory_process_count,m.total_processes=0,0,0
    m.total_process_groups,m._group_pid_count=0,0;m.process_group_overflow=false
    for &slot in m._group_table {slot=0}
    metrics_buffer_ensure(&w.process_buffer,32768)
    needed:u32
    status:=NtQuerySystemInformation(5,raw_data(w.process_buffer),u32(len(w.process_buffer)*8),&needed)
    for _ in 0..<3 {
        if status!=-1073741820 {break}
        metrics_buffer_ensure(&w.process_buffer,max(len(w.process_buffer)+1,(int(needed)+65543)/8))
        status=NtQuerySystemInformation(5,raw_data(w.process_buffer),u32(len(w.process_buffer)*8),&needed)
    }
    if status<0 {w.process_snapshot=nil;return}
    w.process_snapshot=(cast([^]u8)raw_data(w.process_buffer))[:min(int(needed),len(w.process_buffer)*8)]
    windows_service_pids(w)
    data:=w.process_snapshot
    for offset:=0;offset+size_of(Windows_Native_Process)<=len(data); {
        entry:=cast(^Windows_Native_Process)&data[offset]
        if entry.pid!=0&&entry.pid<=uintptr(max(i32)) {
            process:=Process_Metric{pid=i32(entry.pid),start=u64(entry.start),memory_bytes=u64(entry.working_set)}
            if entry.name!=nil {process.name_len=windows_utf8(process.name[:],entry.name[:entry.name_length/2])}
            if process.name_len==0 {process.name_len=copy(process.name[:],"System")}
            process.system_process=entry.pid==4
            for service in w.services {if service==process.pid {process.system_process=true;break}}
            ticks:=u64(entry.user)+u64(entry.kernel)
            if old:=metrics_process_history(m,process.pid);old!=nil {
                if m.rates_ready&&elapsed>0&&old.pid==process.pid&&old.start==process.start&&old.generation+1==m._generation&&ticks>=old.ticks {process.cpu_percent=f32(f64(ticks-old.ticks)/10000000/elapsed*100)}
                old^=Process_History{pid=process.pid,ticks=ticks,start=process.start,generation=m._generation,cpu_percent=process.cpu_percent,system_process=process.system_process,role_generation=m._generation}
            }
            metrics_groups_ensure(&m._groups,&m._group_table,m.total_process_groups,MAX_SYSTEM_PIDS)
            metrics_buffer_ensure(&m._pid_links,min(m._group_pid_count+1,MAX_SYSTEM_PIDS))
            if !metrics_add_group_process(m._groups[:],m._group_table[:],&m.total_process_groups,m._pid_links[:],&m._group_pid_count,process) {m.process_group_overflow=true}
            m.total_processes+=1
        }
        if entry.next==0||int(entry.next)<size_of(Windows_Native_Process) {break}
        offset+=int(entry.next)
    }
    metrics_buffer_ensure(&m.process_pids,m._group_pid_count)
    metrics_finalize_group_pids(m._groups[:m.total_process_groups],m._pid_links[:m._group_pid_count],m.process_pids[:])
    for group in m._groups[:m.total_process_groups] {metrics_insert_ranked(m.processes[:],&m.process_count,group);metrics_insert_ranked(m.memory_processes[:],&m.memory_process_count,group,memory=true)}
}
metrics_gpu_process_details :: proc(m:^Metrics,process:^Process_Metric) {
    entry:=windows_process_lookup(windows_sampler(m),process.pid)
    if entry!=nil {
        process.start=u64(entry.start);process.memory_bytes=u64(entry.working_set)
        if entry.name!=nil {process.name_len=windows_utf8(process.name[:],entry.name[:entry.name_length/2])}
        if old:=metrics_process_history(m,process.pid,create=false);old!=nil&&old.start==process.start&&old.generation==m._generation {process.cpu_percent=old.cpu_percent;process.system_process=old.system_process}
    }
    if process.name_len==0 {buffer:[32]u8;process.name_len=copy(process.name[:],fmt.bprintf(buffer[:],"PID %d",process.pid))}
}
windows_gpu_processes :: proc(m:^Metrics,output:[]GPU_Process_Memory)->int {
    w:=windows_sampler(m)
    items,ok:=windows_counter_array(w,w.gpu_memory)
    if !ok {return -1}
    count:=0
    // One counter instance is one PID/adapter. Sum across adapters only once;
    // the NVML compute/graphics lists are replaced, preventing WDDM double counts.
    for item in items {
        if item.status>1||!windows_finite(item.value)||item.value<0 {continue}
        buffer:[512]u8
        name:=windows_wide_name(item.name,buffer[:])
        if !strings.has_prefix(name,"pid_") {continue}
        pid:=i32(telemetry_uint(name[4:]))
        if pid<=0 {continue}
        if count>=len(output) {m.process_group_overflow=true;break}
        output[count]={pid=pid,memory=u64(item.value),available=true};count+=1
    }
    // Processes using only shared GPU memory still belong in the GPU list.
    // Add each active PID once with measured zero dedicated memory.
    count=metrics_reduce_gpu_processes(output[:count],sum_memory=true)
    engines,engine_ok:=windows_counter_array(w,w.gpu_engine)
    if engine_ok {for item in engines {
        if item.status>1||!windows_finite(item.value)||item.value<=0 {continue}
        buffer:[512]u8
        name:=windows_wide_name(item.name,buffer[:])
        if !strings.has_prefix(name,"pid_") {continue}
        pid:=i32(telemetry_uint(name[4:]));if pid<=0 {continue}
        found:=false
        for process in output[:count] {if process.pid==pid {found=true;break}}
        if !found&&count<len(output) {output[count]={pid=pid,available=true};count+=1}
    }}
    return count
}
metrics_sample :: proc(m:^Metrics,elapsed:f64) {
    m._sample_started=time.tick_now()
    w:=windows_sampler(m)
    if w.query!=nil {_=PdhCollectQueryData(w.query)}
    metrics_sample_cpu(m);metrics_sample_cpu_power(m,elapsed)
    metrics_sample_cpu_cores(m)
    metrics_sample_memory(m);metrics_sample_io(m,elapsed)
    m.uptime=f64(GetTickCount64())/1000
    queue,queue_ok:=windows_counter_value(w.queue)
    if queue_ok {
        seconds:=time.duration_seconds(time.tick_since(w.load_last))
        for period,i in ([3]f64{60,300,900}) {decay:=math.exp(-seconds/period);m.load[i]=m.load[i]*decay+queue*(1-decay)}
    }
    w.load_last=time.tick_now()
    metrics_sample_processes(m,elapsed);metrics_sample_gpu(m)
    m.rates_ready=true
}
metrics_destroy_platform :: proc(m:^Metrics) {
    w:=windows_sampler(m)
    if w==nil {return}
    if w.query!=nil {_=PdhCloseQuery(w.query)}
    delete(w.pdh_buffer);delete(w.process_buffer);delete(w.topology_buffer);delete(w.service_buffer);delete(w.services)
    free(w);m._platform=nil
}

windows_finite :: proc(value:$T)->bool {return !math.is_nan(value)&&!math.is_inf(value)}

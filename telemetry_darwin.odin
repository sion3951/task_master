#+build darwin
package main

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/darwin"
import CF "core:sys/darwin/CoreFoundation"
import "core:sys/posix"
import "core:time"

foreign import tm_darwin_system "system:System"
foreign import tm_darwin_iokit "system:IOKit.framework"
foreign import tm_darwin_cf "system:CoreFoundation.framework"
foreign tm_darwin_system {
    @(link_name="sysctlbyname") darwin_sysctlbyname :: proc(cstring,rawptr,^uintptr,rawptr,uintptr)->i32 ---
    @(link_name="sysctl") darwin_sysctl :: proc(^i32,u32,rawptr,^uintptr,rawptr,uintptr)->i32 ---
    @(link_name="mach_host_self") darwin_host_self :: proc()->u32 ---
    @(link_name="mach_task_self_") darwin_task_self:u32
    @(link_name="host_processor_info") darwin_processor_info :: proc(u32,i32,^u32,^[^]u32,^u32)->i32 ---
    @(link_name="host_statistics64") darwin_host_statistics :: proc(u32,i32,rawptr,^u32)->i32 ---
    @(link_name="host_page_size") darwin_host_page_size :: proc(u32,^uintptr)->i32 ---
    @(link_name="vm_deallocate") darwin_vm_deallocate :: proc(u32,uintptr,uintptr)->i32 ---
    @(link_name="mach_port_deallocate") darwin_port_deallocate :: proc(u32,u32)->i32 ---
    @(link_name="getloadavg") darwin_getloadavg :: proc(^f64,i32)->i32 ---
}
foreign tm_darwin_iokit {
    @(link_name="IOServiceMatching") darwin_service_matching :: proc(cstring)->rawptr ---
    @(link_name="IOServiceGetMatchingServices") darwin_matching_services :: proc(u32,rawptr,^u32)->i32 ---
    @(link_name="IOIteratorNext") darwin_iterator_next :: proc(u32)->u32 ---
    @(link_name="IOObjectRelease") darwin_object_release :: proc(u32)->i32 ---
    @(link_name="IORegistryEntryCreateCFProperty") darwin_registry_property :: proc(u32,rawptr,rawptr,u32)->rawptr ---
    @(link_name="IORegistryEntrySearchCFProperty") darwin_registry_search :: proc(u32,cstring,rawptr,rawptr,u32)->rawptr ---
    @(link_name="IORegistryEntryGetRegistryEntryID") darwin_registry_id :: proc(u32,^u64)->i32 ---
}
foreign tm_darwin_cf {
    @(link_name="CFStringCreateWithCString") darwin_cf_string :: proc(rawptr,cstring,u32)->rawptr ---
    @(link_name="CFRelease") darwin_cf_release :: proc(rawptr) ---
    @(link_name="CFGetTypeID") darwin_cf_type :: proc(rawptr)->uintptr ---
    @(link_name="CFNumberGetTypeID") darwin_cf_number_type :: proc()->uintptr ---
    @(link_name="CFNumberGetValue") darwin_cf_number :: proc(rawptr,int,rawptr)->u8 ---
    @(link_name="CFDataGetTypeID") darwin_cf_data_type :: proc()->uintptr ---
    @(link_name="CFDataGetLength") darwin_cf_data_length :: proc(rawptr)->int ---
    @(link_name="CFDataGetBytePtr") darwin_cf_data_bytes :: proc(rawptr)->[^]u8 ---
    @(link_name="CFDictionaryGetTypeID") darwin_cf_dictionary_type :: proc()->uintptr ---
    @(link_name="CFDictionaryGetValue") darwin_cf_dictionary_get :: proc(rawptr,rawptr)->rawptr ---
    @(link_name="CFStringGetTypeID") darwin_cf_string_type :: proc()->uintptr ---
}

// HOST_VM_INFO64 revision 1 is available on both target architectures.
// Keep the C ABI's 64-bit alignment; Mach counts these structures in u32 words.
Darwin_VM_Statistics :: struct {
    free,active,inactive,wired:u32,
    zero_fill,reactivations,pageins,pageouts,faults,cow_faults,lookups,hits,purges:u64,
    purgeable,speculative:u32,
    decompressions,compressions,swapins,swapouts:u64,
    compressor,throttled,external,internal:u32,
    uncompressed_in_compressor:u64,
}
#assert(size_of(Darwin_VM_Statistics)==152)
Darwin_Swap :: struct {total,available,used:u64,page_size:u32,encrypted:i32}
Darwin_Boot_Time :: struct {seconds:i64,microseconds:i32}
Darwin_Interface_Info :: struct {
    length:u16,version,kind:u8,addresses:i32,flags:u32,index:u16,_padding:u16,
    send_length,send_max,send_drops,timer:i32,
    media:[8]u8,mtu,metric:u32,baud,packets_rx,errors_rx,packets_tx,errors_tx,collisions,bytes_rx,bytes_tx,multicast_rx,multicast_tx,drops,unsupported:u64,
    receive_timing,transmit_timing:u32,last_change:[2]i32,
}
#assert(size_of(Darwin_Interface_Info)==160)
CPU_Power_Domain :: struct {_unused:u8}
Darwin_IO_History :: struct {id,read,write,generation:u64,kind:u8}
Darwin_Service_Identity :: struct {pid:i32,start:u64}
Darwin_Sampler :: struct {
    host:u32,
    cpu_ticks:[256][4]u32,
    sensors:rawptr,
    pids:[dynamic]i32,
    network_buffer:[dynamic]u64,
    io_history:[dynamic]Darwin_IO_History,
    io_generation:u64,
    service_pids:[dynamic]Darwin_Service_Identity,
    service_process:os.Process,
    service_output:^os.File,
    service_buffer:[dynamic]u8,
    service_used:int,
    service_started:time.Tick,
    service_last_generation:u64,
    service_running,service_truncated:bool,
    service_exited:bool,
    service_exitcode:int,
}
darwin_sampler :: proc(m:^Metrics)->^Darwin_Sampler {return cast(^Darwin_Sampler)m._platform}
darwin_sysctl_value :: proc(name:cstring,value:^$T)->bool {
    size:=uintptr(size_of(T))
    return darwin_sysctlbyname(name,value,&size,nil,0)==0&&size==uintptr(size_of(T))
}
darwin_sysctl_text :: proc(name:cstring,buffer:[]u8)->string {
    size:=uintptr(len(buffer))
    if darwin_sysctlbyname(name,raw_data(buffer),&size,nil,0)!=0||size==0 {return ""}
    return string(buffer[:telemetry_cstring_len(buffer[:min(int(size),len(buffer))])])
}
metrics_init_cpu :: proc(m:^Metrics) {
    m.platform="darwin"
    // Returning from a persistence cache reuses live platform handles. Restart
    // delta baselines, since the intervening samples came from another process.
    if m._sampler!=nil&&m._platform!=nil {m.rates_ready=false;return}
    if m._sampler==nil {m._sampler=new(Metrics_Sampler)}
    d:=new(Darwin_Sampler)
    m._platform=d
    d.host=darwin_host_self()
    page:uintptr
    if darwin_host_page_size(d.host,&page)==0 {m._page_size=f64(page)}
    m._ticks_per_second=1e9
    m.hostname=darwin_sysctl_text("kern.hostname",m._hostname[:])
    m.cpu_model=darwin_sysctl_text("machdep.cpu.brand_string",m._cpu_model[:])
    if m.cpu_model=="" {m.cpu_model=darwin_sysctl_text("hw.model",m._cpu_model[:])}
    if m.cpu_model=="" {m.cpu_model="CPU"}
    logical:i32
    if darwin_sysctl_value("hw.logicalcpu",&logical) {m.cpu_count=min(max(int(logical),0),len(m.cores))}
    m.cpu_online_count=m.cpu_count
    for &online,i in m._cpu_online {online=i<m.cpu_count}
    metrics_refresh_cpu_topology(m)
    metrics_darwin_init_sensors(m)
}

darwin_cf_key :: proc(key:cstring)->rawptr {return darwin_cf_string(nil,key,0x08000100)}
darwin_cf_uint :: proc(value:rawptr)->(u64,bool) {
    if value==nil||darwin_cf_type(value)!=darwin_cf_number_type() {return 0,false}
    number:i64
    ok:=darwin_cf_number(value,4,&number)!=0&&number>=0 // kCFNumberSInt64Type
    return u64(max(number,0)),ok
}
darwin_registry_uint :: proc(entry:u32,key:cstring,search:bool=false,data_little_endian:bool=false)->(u64,bool) {
    name:=darwin_cf_key(key)
    if name==nil {return 0,false}
    defer darwin_cf_release(name)
    value:rawptr
    if search {value=darwin_registry_search(entry,"IOService",name,nil,3)} // recursively search parents
    else {value=darwin_registry_property(entry,name,nil,0)}
    if value==nil {return 0,false}
    defer darwin_cf_release(value)
    if darwin_cf_type(value)==darwin_cf_number_type() {return darwin_cf_uint(value)}
    if darwin_cf_type(value)!=darwin_cf_data_type() {return 0,false}
    length:=darwin_cf_data_length(value)
    if length!=4&&length!=8 {return 0,false}
    bytes:=darwin_cf_data_bytes(value)
    number:u64
    if data_little_endian {for byte,i in bytes[:length] {number|=u64(byte)<<uint(i*8)}}
    else {for byte in bytes[:length] {number=(number<<8)|u64(byte)}}
    return number,true
}

metrics_refresh_cpu_topology :: proc(m:^Metrics) {
    m.physical_cores={};m.physical_core_count=0;m.cpu_topology_available=false
    physical:i32
    no_smt:=darwin_sysctl_value("hw.physicalcpu",&physical)&&int(physical)==m.cpu_count&&m.cpu_count>0
    // Intel maps require actual APIC identities. Counts alone cannot establish
    // siblings, and firmware CPU discovery order is not a sibling relationship.
    smt_shift,package_shift:u32
    topology_bits:=false
    _=smt_shift;_=package_shift;_=topology_bits
    when ODIN_ARCH==.amd64 {
        max_leaf,_,_,_:=intrinsics.x86_cpuid(0,0)
        leaf:u32=0xB
        if max_leaf>=0x1F {leaf=0x1F}
        if max_leaf>=leaf {
            for level in 0..<8 {
                eax,ebx,ecx,_:=intrinsics.x86_cpuid(leaf,u32(level))
                if ebx==0 {break}
                kind:=(ecx>>8)&0xff
                if kind==1 {smt_shift=eax&31;topology_bits=true}
                // On newer Intel layouts the levels above Core include dies;
                // the highest enumerated shift identifies the whole package.
                if kind>=2 {package_shift=max(package_shift,eax&31)}
            }
        }
        topology_bits=topology_bits&&package_shift>=smt_shift
    }
    iterator:u32
    matched:[256]bool
    if darwin_matching_services(0,darwin_service_matching("IOCPU"),&iterator)==0 {
        for {
            entry:=darwin_iterator_next(iterator)
            if entry==0 {break}
            logical,logical_ok:=darwin_registry_uint(entry,"IOCPUNumber")
            if logical_ok&&logical<u64(m.cpu_count)&&!matched[logical] {
                package_id,core_id:=0,int(logical)
                valid:=no_smt
                when ODIN_ARCH==.amd64 {
                    apic,apic_ok:=darwin_registry_uint(entry,"apic-id",search=true,data_little_endian=true)
                    if !apic_ok {apic,apic_ok=darwin_registry_uint(entry,"cpu-id",search=true,data_little_endian=true)}
                    if apic_ok&&topology_bits {
                        package_id=int(apic>>uint(package_shift))
                        core_id=int((apic>>uint(smt_shift))&((u64(1)<<uint(package_shift-smt_shift))-1))
                        valid=true
                    }
                }
                if valid {
                    index:=-1
                    for core,i in m.physical_cores[:m.physical_core_count] {if core.package_id==package_id&&core.core_id==core_id {index=i;break}}
                    if index<0 {index=m.physical_core_count;m.physical_core_count+=1;m.physical_cores[index].package_id=package_id;m.physical_cores[index].core_id=core_id}
                    core:=&m.physical_cores[index]
                    if core.logical_count<len(core.logical_ids) {core.logical_ids[core.logical_count]=int(logical);core.logical_count+=1;matched[logical]=true}
                }
            }
            _=darwin_object_release(entry)
        }
        _=darwin_object_release(iterator)
    }
    complete:=m.cpu_count>0
    for found in matched[:m.cpu_count] {complete=complete&&found}
    if no_smt&&!complete {
        // Apple Silicon has one scheduler CPU per physical core, regardless of
        // cluster type. This also covers Intel CPUs with SMT disabled.
        m.physical_cores={};m.physical_core_count=m.cpu_count
        for &core,i in m.physical_cores[:m.physical_core_count] {core.package_id=0;core.core_id=i;core.logical_count=1;core.logical_ids[0]=i}
        complete=true
    }
    m.cpu_topology_available=complete&&m.physical_core_count==int(physical)
    if !m.cpu_topology_available {
        m.physical_cores={};m.physical_core_count=m.cpu_count
        for &core,i in m.physical_cores[:m.physical_core_count] {core.package_id=-1;core.core_id=i;core.logical_count=1;core.logical_ids[0]=i}
    }
    m._cpu_topology_ready=true;m.cpu_topology_generation+=1
}
metrics_sample_cpu :: proc(m:^Metrics) {
    m.cpu_available=false;m.cpu_percent=0;m.cores={}
    d:=darwin_sampler(m)
    count,word_count:u32
    ticks:[^]u32
    if darwin_processor_info(d.host,2,&count,&ticks,&word_count)!=0 {return} // PROCESSOR_CPU_LOAD_INFO
    defer _=darwin_vm_deallocate(darwin_task_self,uintptr(ticks),uintptr(word_count)*4)
    if ticks==nil||word_count<count*4||count==0 {return}
    previous_count:=m.cpu_count
    m.cpu_count=min(int(count),len(m.cores));m.cpu_online_count=m.cpu_count
    m.cpu_available=true
    for i in 0..<m.cpu_count {
        // Darwin's natural_t counters are u32 and wrap individually. Keep each
        // raw component so a wrap is handled before summing deltas.
        old_raw:=&d.cpu_ticks[i]
        delta_total,delta_idle:u64
        for component in 0..<4 {
            delta:=u64(ticks[i*4+component]-old_raw[component])
            delta_total+=delta
            if component==2 {delta_idle=delta}
        }
        if m.rates_ready&&i<previous_count&&delta_total>0 {m.cores[i]=f32(f64(delta_total-min(delta_total,delta_idle))/f64(delta_total)*100)}
        for component in 0..<4 {old_raw[component]=ticks[i*4+component]}
        m.cpu_percent+=m.cores[i]
    }
    m.cpu_percent/=f32(m.cpu_count)
    for &online,i in m._cpu_online {online=i<m.cpu_count}
    if previous_count!=m.cpu_count||!m._cpu_topology_ready {metrics_refresh_cpu_topology(m)}
}
metrics_sample_memory :: proc(m:^Metrics) {
    vm:Darwin_VM_Statistics
    count:=u32(size_of(vm)/4)
    m.ram_available=darwin_sampler(m).host!=0&&darwin_host_statistics(darwin_sampler(m).host,4,&vm,&count)==0&&count>=38&&m._page_size>0 // HOST_VM_INFO64
    total:u64
    m.ram_available=m.ram_available&&darwin_sysctl_value("hw.memsize",&total)
    m.memory_free_available,m.memory_cached_available,m.memory_buffers_available=false,false,false
    m.memory_breakdown_available=false
    if !m.ram_available {return}
    page:=u64(m._page_size)
    m.memory_total=total
    // free_count already includes speculative pages, as does the pageable
    // external count. Count these once under file cache. Wired and compressor
    // pages remain used; purgeable anonymous pages join the reusable cache.
    m.memory_free=min(total,u64(vm.free-min(vm.free,vm.speculative))*page)
    m.memory_cached=min(total,(u64(vm.external)+u64(vm.purgeable))*page)
    m.memory_available=min(total,m.memory_free+m.memory_cached)
    m.memory_used=total-m.memory_available
    m.memory_buffers=0 // Darwin has no independent Linux-style buffer counter.
    m.memory_free_available,m.memory_cached_available=true,true
    swap:Darwin_Swap
    if darwin_sysctl_value("vm.swapusage",&swap) {m.swap_total=swap.total;m.swap_used=min(swap.used,swap.total)}
}
darwin_io_rates :: proc(m:^Metrics,kind:u8,id,read,write:u64,elapsed:f64)->(f64,f64) {
    d:=darwin_sampler(m)
    reusable:=-1
    for &old,i in d.io_history {
        if old.kind==kind&&old.id==id {
            ready:=m.rates_ready&&old.generation+1==d.io_generation
            r,w:=telemetry_rate(read,old.read,elapsed,ready),telemetry_rate(write,old.write,elapsed,ready)
            old.read,old.write,old.generation=read,write,d.io_generation
            return r,w
        }
        if old.generation+3<d.io_generation {reusable=i}
    }
    record:=Darwin_IO_History{id=id,read=read,write=write,generation=d.io_generation,kind=kind}
    if reusable>=0 {d.io_history[reusable]=record} else if len(d.io_history)<4096 {append(&d.io_history,record)}
    return 0,0
}
darwin_virtual_disk :: proc(entry:u32)->bool {
    key:=darwin_cf_key("Protocol Characteristics")
    if key==nil {return false}
    defer darwin_cf_release(key)
    value:=darwin_registry_search(entry,"IOService",key,nil,3)
    if value==nil {return false}
    defer darwin_cf_release(value)
    if darwin_cf_type(value)!=darwin_cf_dictionary_type() {return false}
    interconnect:=darwin_cf_key("Physical Interconnect")
    if interconnect==nil {return false}
    defer darwin_cf_release(interconnect)
    kind:=darwin_cf_dictionary_get(value,interconnect)
    if kind==nil||darwin_cf_type(kind)!=darwin_cf_string_type() {return false}
    text:[128]u8
    if !CF.StringGetCString(CF.String(kind),&text[0],CF.Index(len(text)),CF.StringEncoding(0x08000100)) {return false}
    return string(text[:telemetry_cstring_len(text[:])])=="Virtual Interface"
}
metrics_sample_io :: proc(m:^Metrics,elapsed:f64) {
    d:=darwin_sampler(m);d.io_generation+=1
    m.network_rx,m.network_tx,m.disk_read,m.disk_write=0,0,0,0
    // NET_RT_IFLIST2 provides u64 byte counters. getifaddrs' if_data counters
    // truncate at 4 GiB, which is too frequent on current network hardware.
    mib:=[6]i32{4,17,0,0,6,0}
    size:uintptr
    if darwin_sysctl(&mib[0],6,nil,&size,nil,0)==0&&size>0&&size<=16*1024*1024 {
        metrics_buffer_ensure(&d.network_buffer,(int(size)+7)/8)
        if darwin_sysctl(&mib[0],6,raw_data(d.network_buffer),&size,nil,0)==0 {
            data:=(cast([^]u8)raw_data(d.network_buffer))[:size]
            for offset:=0;offset+4<=len(data); {
                length:=int(data[offset])|int(data[offset+1])<<8
                if length<4||offset+length>len(data) {break}
                if data[offset+3]==0x12&&length>=size_of(Darwin_Interface_Info) {
                    info:=cast(^Darwin_Interface_Info)&data[offset]
                    if info.flags&8==0 {
                        r,w:=darwin_io_rates(m,1,u64(info.index),info.bytes_rx,info.bytes_tx,elapsed)
                        m.network_rx+=r;m.network_tx+=w
                    }
                }
                offset+=length
            }
        }
    }
    iterator:u32
    if darwin_matching_services(0,darwin_service_matching("IOBlockStorageDriver"),&iterator)!=0 {return}
    defer _=darwin_object_release(iterator)
    statistics_key:=darwin_cf_key("Statistics")
    read_key,write_key:=darwin_cf_key("Bytes (Read)"),darwin_cf_key("Bytes (Write)")
    defer darwin_cf_release(statistics_key);defer darwin_cf_release(read_key);defer darwin_cf_release(write_key)
    for {
        entry:=darwin_iterator_next(iterator)
        if entry==0 {break}
        id:u64
        // Driver statistics represent the whole disk, excluding IOMedia
        // partitions. Ignore disk images/RAM disks to avoid counting their
        // backing physical disk's traffic twice.
        value:rawptr
        if !darwin_virtual_disk(entry) {value=darwin_registry_property(entry,statistics_key,nil,0)}
        if value!=nil {
            if darwin_cf_type(value)==darwin_cf_dictionary_type()&&darwin_registry_id(entry,&id)==0 {
                read,r_ok:=darwin_cf_uint(darwin_cf_dictionary_get(value,read_key))
                write,w_ok:=darwin_cf_uint(darwin_cf_dictionary_get(value,write_key))
                if r_ok&&w_ok {r,w:=darwin_io_rates(m,2,id,read,write,elapsed);m.disk_read+=r;m.disk_write+=w}
            }
            darwin_cf_release(value)
        }
        _=darwin_object_release(entry)
    }
}

// launchd's system domain is authoritative service metadata. Neither root UID,
// PPID 1 nor a familiar executable path proves that a process is a service.
// Read it asynchronously so launchctl never stalls the sampling thread.
darwin_sample_services :: proc(m:^Metrics) {
    d:=darwin_sampler(m)
    if d.service_running {
        eof:=false
        for _ in 0..<32 {
            chunk:[16384]u8
            n,err:=os.read(d.service_output,chunk[:])
            if n>0 {
                room:=1024*1024-d.service_used
                keep:=min(n,max(room,0))
                if keep<n {d.service_truncated=true}
                if keep>0 {metrics_buffer_ensure(&d.service_buffer,d.service_used+keep);copy(d.service_buffer[d.service_used:d.service_used+keep],chunk[:keep]);d.service_used+=keep}
            }
            if n==0&&err==nil {eof=true;break}
            if err!=nil {break}
        }
        if !d.service_exited {
            state,err:=os.process_wait(d.service_process,0)
            if err==nil&&state.exited {d.service_exited=true;d.service_exitcode=state.exit_code}
        }
        if d.service_exited&&eof {
            // The output can exceed a pipe's capacity, so parse only after EOF.
            if d.service_exitcode==0&&!d.service_truncated {
                clear(&d.service_pids)
                text:=string(d.service_buffer[:d.service_used])
                in_services:=false
                for line in strings.split_lines_iterator(&text) {
                    value:=strings.trim_space(line)
                    if value=="services = {" {in_services=true;continue}
                    if !in_services {continue}
                    if value=="}" {break}
                    fields:[4]string
                    if telemetry_fields(value,fields[:])<3 {continue}
                    if fields[0]==""||fields[0][0]<'1'||fields[0][0]>'9' {continue}
                    pid:=telemetry_uint(fields[0])
                    if pid>0&&pid<=u64(max(i32)) {
                        start:=metrics_darwin_process_identity(i32(pid))
                        if start!=0 {append(&d.service_pids,Darwin_Service_Identity{pid=i32(pid),start=start})}
                    }
                }
            }
            _=os.close(d.service_output);d.service_output=nil;d.service_running=false
        } else if time.tick_since(d.service_started)>3*time.Second {
            if !d.service_exited {_=os.process_kill(d.service_process);_,_=os.process_wait(d.service_process)}
            _=os.close(d.service_output);d.service_output=nil;d.service_running=false
        }
    }
    if d.service_running||d.service_last_generation+10>m._generation&&d.service_last_generation!=0 {return}
    d.service_last_generation=m._generation
    input,output,pipe_error:=os.pipe()
    if pipe_error!=nil {return}
    command:=[3]string{"/bin/launchctl","print","system"}
    child,err:=os.process_start(os.Process_Desc{command=command[:],stdout=output})
    _=os.close(output)
    if err!=nil {_=os.close(input);return}
    flags:=posix.fcntl(posix.FD(os.fd(input)),.GETFL)
    if flags<0||posix.fcntl(posix.FD(os.fd(input)),.SETFL,flags|4)<0 {
        _=os.process_kill(child);_,_=os.process_wait(child);_=os.close(input);return
    }
    d.service_process=child;d.service_output=input;d.service_used=0;d.service_truncated=false;d.service_running=true;d.service_exited=false;d.service_started=time.tick_now()
}
metrics_darwin_process_identity :: proc(pid:i32)->u64 {
    bsd:darwin.proc_bsdinfo
    if pid<=0||darwin.proc_pidinfo(posix.pid_t(pid),.BSDINFO,0,&bsd,i32(size_of(bsd)))!=i32(size_of(bsd)) {return 0}
    return bsd.pbi_start_tvsec*1000000+bsd.pbi_start_tvusec
}
darwin_process_metric :: proc(pid:i32)->(Process_Metric,u64,bool) {
    bsd:darwin.proc_bsdinfo
    if darwin.proc_pidinfo(posix.pid_t(pid),.BSDINFO,0,&bsd,i32(size_of(bsd)))!=i32(size_of(bsd)) {return {},0,false}
    usage:darwin.rusage_info_v0
    if darwin.proc_pid_rusage(posix.pid_t(pid),.V0,&usage)!=0 {return {},0,false}
    start:=bsd.pbi_start_tvsec*1000000+bsd.pbi_start_tvusec
    if start==0||metrics_darwin_process_identity(pid)!=start {return {},0,false}
    process:=Process_Metric{pid=pid,start=start,memory_bytes=usage.ri_resident_size,system_process=.SYSTEM in bsd.pbi_flags||pid==1}
    name:=string(bsd.pbi_name[:telemetry_cstring_len(bsd.pbi_name[:])])
    if name=="" {name=string(bsd.pbi_comm[:telemetry_cstring_len(bsd.pbi_comm[:])])}
    if len(name)>=len(bsd.pbi_name)-1 {
        path:[4096]u8
        n:=darwin.proc_pidpath(posix.pid_t(pid),&path[0],u32(len(path)))
        if n>0 {full:=string(path[:telemetry_cstring_len(path[:])]);slash:=strings.last_index_byte(full,'/');name=full[slash+1:];process.name_len=copy(process.name[:],name)}
    }
    if process.name_len==0 {process.name_len=copy(process.name[:],name)}
    if process.name_len==0 {process.name_len=copy(process.name[:],fmt.tprintf("PID %d",pid))}
    return process,usage.ri_user_time+usage.ri_system_time,true
}
metrics_sample_processes :: proc(m:^Metrics,elapsed:f64) {
    d:=darwin_sampler(m)
    m._generation+=1;m.process_count,m.memory_process_count,m.total_processes=0,0,0
    m.total_process_groups,m._group_pid_count=0,0;m.process_group_overflow=false
    for &slot in m._group_table {slot=0}
    darwin_sample_services(m)
    needed:=darwin.proc_listallpids(nil,0)
    if needed<=0 {return}
    metrics_buffer_ensure(&d.pids,int(needed)+256)
    count:=darwin.proc_listallpids(raw_data(d.pids),i32(len(d.pids)*size_of(i32)))
    if int(count)>=len(d.pids) {
        metrics_buffer_ensure(&d.pids,len(d.pids)+256)
        count=darwin.proc_listallpids(raw_data(d.pids),i32(len(d.pids)*size_of(i32)))
    }
    for pid in d.pids[:min(max(int(count),0),len(d.pids))] {
        if pid<=0 {continue}
        process,ticks,ok:=darwin_process_metric(pid)
        if !ok {continue}
        for service in d.service_pids {if service.pid==pid&&service.start==process.start {process.system_process=true;break}}
        if old:=metrics_process_history(m,pid);old!=nil {
            if m.rates_ready&&elapsed>0&&old.pid==pid&&old.start==process.start&&old.generation+1==m._generation&&ticks>=old.ticks {process.cpu_percent=f32(f64(ticks-old.ticks)/1e9/elapsed*100)}
            old^=Process_History{pid=pid,ticks=ticks,start=process.start,generation=m._generation,cpu_percent=process.cpu_percent,system_process=process.system_process,role_generation=m._generation}
        }
        metrics_groups_ensure(&m._groups,&m._group_table,m.total_process_groups,MAX_SYSTEM_PIDS)
        metrics_buffer_ensure(&m._pid_links,min(m._group_pid_count+1,MAX_SYSTEM_PIDS))
        if !metrics_add_group_process(m._groups[:],m._group_table[:],&m.total_process_groups,m._pid_links[:],&m._group_pid_count,process) {m.process_group_overflow=true}
        m.total_processes+=1
    }
    metrics_buffer_ensure(&m.process_pids,m._group_pid_count)
    metrics_finalize_group_pids(m._groups[:m.total_process_groups],m._pid_links[:m._group_pid_count],m.process_pids[:])
    for group in m._groups[:m.total_process_groups] {metrics_insert_ranked(m.processes[:],&m.process_count,group);metrics_insert_ranked(m.memory_processes[:],&m.memory_process_count,group,memory=true)}
}
metrics_gpu_process_details :: proc(m:^Metrics,process:^Process_Metric) {
    details,_,ok:=darwin_process_metric(process.pid)
    if ok {
        process.start=details.start;process.name=details.name;process.name_len=details.name_len;process.memory_bytes=details.memory_bytes;process.system_process=details.system_process
        if old:=metrics_process_history(m,process.pid,create=false);old!=nil&&old.pid==process.pid&&old.start==process.start&&old.generation==m._generation {process.cpu_percent=old.cpu_percent;process.system_process=old.system_process}
    } else {process.name_len=copy(process.name[:],fmt.tprintf("PID %d",process.pid))}
}
metrics_sample :: proc(m:^Metrics,elapsed:f64) {
    m._sample_started=time.tick_now()
    metrics_sample_cpu(m)
    metrics_sample_cpu_power(m,elapsed)
    metrics_sample_cpu_cores(m)
    metrics_sample_memory(m)
    metrics_sample_io(m,elapsed)
    boot:Darwin_Boot_Time
    now:posix.timeval
    if darwin_sysctl_value("kern.boottime",&boot)&&posix.gettimeofday(&now)==nil {m.uptime=max(0,f64(i64(now.tv_sec)-boot.seconds)+f64(i64(now.tv_usec)-i64(boot.microseconds))/1e6)}
    _=darwin_getloadavg(&m.load[0],3)
    metrics_sample_processes(m,elapsed)
    metrics_sample_gpu(m)
    m.rates_ready=true
}
metrics_destroy_platform :: proc(m:^Metrics) {
    d:=darwin_sampler(m)
    if d==nil {return}
    metrics_darwin_destroy_sensors(m)
    if d.service_running&&!d.service_exited {_=os.process_kill(d.service_process);_,_=os.process_wait(d.service_process)}
    if d.service_output!=nil {_=os.close(d.service_output)}
    if d.host!=0 {_=darwin_port_deallocate(darwin_task_self,d.host)}
    delete(d.pids);delete(d.network_buffer);delete(d.io_history);delete(d.service_pids);delete(d.service_buffer)
    free(d);m._platform=nil
}

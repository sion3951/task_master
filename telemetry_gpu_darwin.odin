#+build darwin
package main

import "core:math"
import "core:dynlib"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import CF "core:sys/darwin/CoreFoundation"

foreign import tm_gpu_iokit "system:IOKit.framework"
foreign import tm_gpu_cf "system:CoreFoundation.framework"
foreign import tm_gpu_metal "system:Metal.framework"
@(default_calling_convention="c")
foreign tm_gpu_metal {
    @(link_name="MTLCopyAllDevices") gpu_metal_devices :: proc()->rawptr ---
}
Darwin_ObjC :: struct {
    __handle:dynlib.Library,
    selector:proc "c"(cstring)->rawptr `dynlib:"sel_registerName"`,
    message:proc "c"(rawptr,rawptr)->rawptr `dynlib:"objc_msgSend"`,
}
// Use the stable Objective-C runtime C ABI directly. This also avoids importing
// Odin's Objective-C intrinsics into headless cross-compiled collector builds.
gpu_objc_u64 :: proc(api:^Darwin_ObjC,object:rawptr,selector:cstring)->u64 {
    call:=cast(proc "c"(rawptr,rawptr)->u64)api.message
    return call(object,api.selector(selector))
}
gpu_objc_bool :: proc(api:^Darwin_ObjC,object:rawptr,selector:cstring)->bool {
    call:=cast(proc "c"(rawptr,rawptr)->u8)api.message
    return call(object,api.selector(selector))!=0
}
gpu_objc_at_index :: proc(api:^Darwin_ObjC,object:rawptr,index:u64)->rawptr {
    call:=cast(proc "c"(rawptr,rawptr,u64)->rawptr)api.message
    return call(object,api.selector("objectAtIndex:"),index)
}
@(default_calling_convention="c")
foreign tm_gpu_iokit {
    @(link_name="IOServiceMatching") gpu_matching :: proc(cstring)->rawptr ---
    @(link_name="IOServiceGetMatchingServices") gpu_services :: proc(u32,rawptr,^u32)->i32 ---
    @(link_name="IOIteratorNext") gpu_next :: proc(u32)->u32 ---
    @(link_name="IOObjectRelease") gpu_release :: proc(u32)->i32 ---
    @(link_name="IORegistryEntryGetRegistryEntryID") gpu_registry_id :: proc(u32,^u64)->i32 ---
    @(link_name="IORegistryEntryCreateCFProperty") gpu_property :: proc(u32,rawptr,rawptr,u32)->rawptr ---
    @(link_name="IORegistryEntryGetChildIterator") gpu_children :: proc(u32,cstring,^u32)->i32 ---
    @(link_name="IORegistryEntryGetParentEntry") gpu_parent :: proc(u32,cstring,^u32)->i32 ---
}
@(default_calling_convention="c")
foreign tm_gpu_cf {
    @(link_name="CFStringCreateWithCString") gpu_cf_string :: proc(rawptr,cstring,u32)->rawptr ---
    @(link_name="CFRelease") gpu_cf_release :: proc(rawptr) ---
    @(link_name="CFGetTypeID") gpu_cf_type :: proc(rawptr)->uint ---
    @(link_name="CFNumberGetTypeID") gpu_cf_number_type :: proc()->uint ---
    @(link_name="CFDictionaryGetTypeID") gpu_cf_dictionary_type :: proc()->uint ---
    @(link_name="CFStringGetTypeID") gpu_cf_string_type :: proc()->uint ---
    @(link_name="CFDictionaryGetValue") gpu_cf_value :: proc(rawptr,rawptr)->rawptr ---
    @(link_name="CFNumberGetValue") gpu_cf_number :: proc(rawptr,int,rawptr)->u8 ---
    @(link_name="CFArrayGetTypeID") gpu_cf_array_type :: proc()->uint ---
    @(link_name="CFArrayGetCount") gpu_cf_array_count :: proc(rawptr)->int ---
    @(link_name="CFArrayGetValueAtIndex") gpu_cf_array_value :: proc(rawptr,int)->rawptr ---
}
gpu_cf_cstring :: proc(value:rawptr,buffer:^u8,size:int,encoding:u32)->b8 {
    return CF.StringGetCString(CF.String(value),cast([^]u8)buffer,CF.Index(size),CF.StringEncoding(encoding))
}
Darwin_GPU_Sensors :: struct {
    services:[8]u32,
    registry_ids:[8]u64,
    clocks:[256]f32,
    system_clock:f32,
    gpu_power,gpu_clock,gpu_temperature,gpu_utilization:f32,
    gpu_power_available,gpu_clock_available,gpu_temperature_available,gpu_utilization_available:bool,
}
darwin_gpu_sensors :: proc(m:^Metrics)->^Darwin_GPU_Sensors {
    return cast(^Darwin_GPU_Sensors)darwin_sampler(m).sensors
}
metrics_darwin_init_sensors :: proc(m:^Metrics) {
    darwin_sampler(m).sensors=new(Darwin_GPU_Sensors)
}
metrics_darwin_destroy_sensors :: proc(m:^Metrics) {
    s:=darwin_gpu_sensors(m)
    if s==nil {return}
    for service in s.services {if service!=0 {_=gpu_release(service)}}
    free(s);darwin_sampler(m).sensors=nil
}
darwin_gpu_property :: proc(service:u32,key:cstring)->rawptr {
    name:=gpu_cf_string(nil,key,0x08000100)
    if name==nil {return nil}
    defer gpu_cf_release(name)
    return gpu_property(service,name,nil,0)
}
darwin_gpu_number :: proc(dict:rawptr,key:cstring)->(f64,bool) {
    if dict==nil||gpu_cf_type(dict)!=gpu_cf_dictionary_type() {return 0,false}
    name:=gpu_cf_string(nil,key,0x08000100)
    if name==nil {return 0,false}
    defer gpu_cf_release(name)
    value:=gpu_cf_value(dict,name)
    if value==nil||gpu_cf_type(value)!=gpu_cf_number_type() {return 0,false}
    n:f64
    if gpu_cf_number(value,13,&n)==0||math.is_nan(n)||math.is_inf(n)||n<0||n>9.0e15 {return 0,false}
    return n,true
}
darwin_gpu_property_number :: proc(service:u32,key:cstring)->(f64,bool) {
    value:=darwin_gpu_property(service,key)
    if value==nil {return 0,false}
    defer gpu_cf_release(value)
    if gpu_cf_type(value)!=gpu_cf_number_type() {return 0,false}
    n:f64
    ok:=gpu_cf_number(value,13,&n)!=0&&!math.is_nan(n)&&!math.is_inf(n)&&n>=0
    return n,ok
}
// Metal's currentAllocatedSize is process-local and recommendedMaxWorkingSetSize
// is a budget, so neither is substituted for system-wide allocation or VRAM.
metrics_darwin_init_devices :: proc(m:^Metrics) {
    s:=darwin_gpu_sensors(m)
    api:Darwin_ObjC
    _,loaded:=dynlib.initialize_symbols(&api,"/usr/lib/libobjc.A.dylib")
    if !loaded||api.selector==nil||api.message==nil {return}
    defer _=dynlib.unload_library(api.__handle)
    devices:=gpu_metal_devices()
    if devices!=nil {
        release:=cast(proc "c"(rawptr,rawptr))api.message
        defer release(devices,api.selector("release"))
        for i in 0..<min(int(gpu_objc_u64(&api,devices,"count")),len(m.gpus)) {
            device:=gpu_objc_at_index(&api,devices,u64(i))
            g:=&m.gpus[i]
            name:=api.message(device,api.selector("name"))
            utf8:=cast(cstring)api.message(name,api.selector("UTF8String"))
            if utf8!=nil {g.name_len=copy(g.name[:],string(utf8))}
            g.unified_memory=gpu_objc_bool(&api,device,"hasUnifiedMemory")
            s.registry_ids[i]=gpu_objc_u64(&api,device,"registryID")
            m.gpu_count+=1
        }
    }
    iterator:u32
    if gpu_services(0,gpu_matching("IOAccelerator"),&iterator)==0 {
        defer _=gpu_release(iterator)
        for service:=gpu_next(iterator);service!=0;service=gpu_next(iterator) {
            id:u64;_=gpu_registry_id(service,&id)
            slot:=-1
            for i in 0..<m.gpu_count {if s.registry_ids[i]==id {slot=i;break}}
            // Intel/AMD Metal devices may identify the accelerator's PCI
            // ancestor. Match registry identity rather than enumeration order.
            ancestor:=service
            for _ in 0..<8 {
                if slot>=0 {break}
                parent:u32
                if gpu_parent(ancestor,"IOService",&parent)!=0 {break}
                if ancestor!=service {_=gpu_release(ancestor)}
                ancestor=parent;_=gpu_registry_id(ancestor,&id)
                for i in 0..<m.gpu_count {if s.registry_ids[i]==id {slot=i;break}}
            }
            if ancestor!=service {_=gpu_release(ancestor)}
            // Metal registry IDs refer to the accelerator on modern drivers.
            // If a driver differs, only single-device mapping is unambiguous.
            if slot<0&&m.gpu_count==1&&s.services[0]==0 {slot=0}
            if slot<0 {_=gpu_release(service);continue}
            if s.services[slot]!=0 {_=gpu_release(s.services[slot])}
            s.services[slot]=service
        }
    }
    m.nvml_available=m.gpu_count>0 // Historical flag means GPU backend available.
    when ODIN_ARCH==.arm64 {m.gpu_process_memory_shared=true}
}
darwin_sensor_number :: proc(text:string)->(f32,bool) {
    end:=0
    for b in text {if (b<'0'||b>'9')&&b!='.'&&b!='-' {break};end+=1}
    if end==0 {return 0,false}
    value,ok:=strconv.parse_f32(text[:end])
    return value,ok&&!math.is_nan(value)&&!math.is_inf(value)&&value>=0
}
darwin_sensor_after_colon :: proc(line:string)->string {
    colon:=strings.index_byte(line,':')
    if colon<0 {return ""}
    return strings.trim_space(line[colon+1:])
}
metrics_cpu_power_error :: proc(m:^Metrics,message:string) {
    m.cpu_power_error_len=copy(m.cpu_power_error[:],message)
}
metrics_sample_cpu_power :: proc(m:^Metrics,elapsed:f64) {
    s:=darwin_gpu_sensors(m)
    s.clocks={};s.system_clock=0;s.gpu_power_available=false;s.gpu_clock_available=false;s.gpu_temperature_available=false;s.gpu_utilization_available=false
    m.cpu_power_available=false;m.cpu_power_source=.None;m.cpu_power_permission_denied=false
    metrics_cpu_power_error(m,"Install the macOS sensor helper for CPU power and measured clocks")
    file,err:=os.open("/var/run/task_master/sensors.txt")
    if err!=nil {return}
    defer _=os.close(file)
    buf:[65536]u8
    n,read_err:=os.read(file,buf[:])
    if read_err!=nil||n<=0||n==len(buf) {return}
    text:=string(buf[:n]);header,has_header:=strings.split_lines_iterator(&text)
    fields:[4]string
    if !has_header||telemetry_fields(header,fields[:])!=3||fields[0]!="TASK_MASTER_SENSORS"||fields[1]!="1" {return}
    stamp:=i64(telemetry_uint(fields[2]));now:=time.time_to_unix(time.now())
    if stamp>now+1||now-stamp>5 {metrics_cpu_power_error(m,"macOS sensor helper snapshot is stale");return}
    cpu_only_power:=false
    for raw_line in strings.split_lines_iterator(&text) {
        line:=strings.trim_space(raw_line)
        explicit_cpu:=strings.has_prefix(line,"CPU Power:")
        package_power:=strings.has_prefix(line,"Package Power:")||strings.has_prefix(line,"Intel energy model derived package power")
        if explicit_cpu||package_power&&!cpu_only_power {
            value,ok:=darwin_sensor_number(darwin_sensor_after_colon(line))
            if ok {if strings.contains(line,"mW") {value/=1000};m.cpu_power_watts=value;m.cpu_power_available=true;m.cpu_power_source=.Sensor;m.cpu_power_error_len=0;if explicit_cpu {cpu_only_power=true}}
        }
        if (strings.has_prefix(line,"CPU ")||strings.has_prefix(line,"cpu "))&&strings.contains(line,"frequency:") {
            number:=line[4:];cpu:=int(telemetry_uint(number))
            if len(number)>0&&number[0]>='0'&&number[0]<='9'&&cpu<len(s.clocks) {
                value,ok:=darwin_sensor_number(darwin_sensor_after_colon(line));if ok {s.clocks[cpu]=value}
            }
        }
        if strings.contains(line,"frequency as fraction of nominal:") {
            open:=strings.last_index_byte(line,'(')
            if open>=0 {value,ok:=darwin_sensor_number(line[open+1:]);if ok {
                if strings.has_prefix(line,"CPU Average")||strings.has_prefix(line,"System Average") {s.system_clock=value}
                else if strings.has_prefix(line,"CPU ") {cpu:=int(telemetry_uint(line[4:]));if cpu<len(s.clocks) {s.clocks[cpu]=value}}
            }}
        }
        if strings.has_prefix(line,"GPU Power:")||strings.has_prefix(line,"Intel energy model derived GPU power") {value,ok:=darwin_sensor_number(darwin_sensor_after_colon(line));if ok {if strings.contains(line,"mW") {value/=1000};s.gpu_power=value;s.gpu_power_available=true}}
        if strings.has_prefix(line,"GPU HW active frequency:")||strings.has_prefix(line,"GPU active frequency:") {s.gpu_clock,s.gpu_clock_available=darwin_sensor_number(darwin_sensor_after_colon(line))}
        if strings.has_prefix(line,"GPU HW active residency:")||strings.has_prefix(line,"GPU active residency:")||strings.has_prefix(line,"GPU Active:") {s.gpu_utilization,s.gpu_utilization_available=darwin_sensor_number(darwin_sensor_after_colon(line));s.gpu_utilization_available=s.gpu_utilization_available&&s.gpu_utilization<=100}
        if strings.has_prefix(line,"GPU die temperature:") {s.gpu_temperature,s.gpu_temperature_available=darwin_sensor_number(darwin_sensor_after_colon(line))}
    }
    if !m.cpu_power_available {metrics_cpu_power_error(m,"powermetrics does not expose CPU package power on this Mac")}
}
metrics_darwin_cpu_frequency_aggregate :: proc(m:^Metrics) {
    s:=darwin_gpu_sensors(m)
    if !m.cpu_frequency_available&&s.system_clock>0 {
        // A system average is retained as an aggregate, never copied into
        // individual cores that the sensor did not measure independently.
        m.cpu_frequency_mhz=s.system_clock;m.cpu_frequency_available=true;m.cpu_frequency_source=.Measured
    }
}
telemetry_cpu_frequency :: proc(m:^Metrics,cpu:int)->(f32,CPU_Frequency_Source) {
    s:=darwin_gpu_sensors(m)
    if cpu>=0&&cpu<len(s.clocks)&&s.clocks[cpu]>0 {return s.clocks[cpu],.Measured}
    return 0,.None
}
metrics_darwin_sample_gpus :: proc(m:^Metrics,processes:[]GPU_Process_Memory)->int {
    s:=darwin_gpu_sensors(m);count:=0
    for i in 0..<m.gpu_count {
        g:=&m.gpus[i];service:=s.services[i]
        g.utilization_available=false;g.memory_available=false;g.power_available=false;g.frequency_available=false;g.temperature_available=false
        if m.gpu_count==1 {g.power_watts=s.gpu_power;g.power_available=s.gpu_power_available;g.frequency_mhz=s.gpu_clock;g.frequency_available=s.gpu_clock_available;g.temperature=s.gpu_temperature;g.temperature_available=s.gpu_temperature_available;g.utilization=s.gpu_utilization;g.utilization_available=s.gpu_utilization_available}
        if service==0 {continue}
        stats:=darwin_gpu_property(service,"PerformanceStatistics")
        if stats!=nil {
            value,ok:=darwin_gpu_number(stats,"Device Utilization %")
            if ok {g.utilization=f32(clamp(value,0,100));g.utilization_available=true}
            used,used_ok:=darwin_gpu_number(stats,"Alloc system memory")
            if g.unified_memory {
                if !used_ok {used,used_ok=darwin_gpu_number(stats,"gartUsedBytes")}
                if used_ok {g.memory_used=u64(used);g.memory_total=m.memory_total;g.memory_available=g.memory_total>0}
            } else {
                used,used_ok=darwin_gpu_number(stats,"vramUsedBytes")
                total,total_ok:=darwin_gpu_number(stats,"vramTotalBytes")
                if !used_ok {used,used_ok=darwin_gpu_number(stats,"inUseVidMemoryBytes")}
                if !total_ok {free,free_ok:=darwin_gpu_number(stats,"vramFreeBytes");if free_ok&&used_ok {total=used+free;total_ok=true}}
                if !total_ok {mb,mb_ok:=darwin_gpu_property_number(service,"VRAM,totalMB");if mb_ok {total=mb*1024*1024;total_ok=true}}
                if used_ok&&total_ok&&used<=total {g.memory_used=u64(used);g.memory_total=u64(total);g.memory_available=true}
            }
            gpu_cf_release(stats)
        }
        // Intel/AMD OpenGL clients expose process ownership in SurfaceList.
        // Surfaces describe resources, not resident VRAM, so retain the PID
        // roster without inventing byte counts from dimensions or process RSS.
        surfaces:=darwin_gpu_property(service,"SurfaceList")
        if surfaces!=nil {
            if gpu_cf_type(surfaces)==gpu_cf_array_type() {
                for index in 0..<min(gpu_cf_array_count(surfaces),MAX_GPU_PIDS*4) {
                    surface:=gpu_cf_array_value(surfaces,index)
                    value,ok:=darwin_gpu_number(surface,"pid")
                    if ok&&value>0&&value<=0x7fffffff {
                        if count<len(processes) {processes[count]=GPU_Process_Memory{pid=i32(value),available=false};count+=1}else {m.process_group_overflow=true}
                    }
                }
            }
            gpu_cf_release(surfaces)
        }
        children:u32
        if gpu_children(service,"IOService",&children)!=0 {continue}
        for child:=gpu_next(children);child!=0;child=gpu_next(children) {
            creator:=darwin_gpu_property(child,"IOUserClientCreator")
            if creator!=nil&&gpu_cf_type(creator)==gpu_cf_string_type() {
                buf:[512]u8
                if gpu_cf_cstring(creator,&buf[0],len(buf),0x08000100)!=false {
                    name:=string(buf[:telemetry_cstring_len(buf[:])])
                    if strings.has_prefix(name,"pid ") {
                        pid:=i32(telemetry_uint(name[4:]))
                        // Membership comes from the GPU's own clients. Darwin
                        // exposes no reliable per-process resident VRAM byte
                        // counter: retain the process and mark bytes unknown.
                        if pid>0 {if count<len(processes) {processes[count]=GPU_Process_Memory{pid=pid,available=false};count+=1}else {m.process_group_overflow=true}}
                    }
                }
            }
            if creator!=nil {gpu_cf_release(creator)}
            _=gpu_release(child)
        }
        _=gpu_release(children)
    }
    return metrics_reduce_gpu_processes(processes[:count],false)
}

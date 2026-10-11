#+build windows
package main

import "core:dynlib"
import "core:fmt"
import "core:strings"
import "core:sys/windows"
import "vendor:directx/d3d12"
import "vendor:directx/dxgi"

foreign import tm_gpu_gdi32 "system:gdi32.lib"
Windows_GPU_Open :: struct { luid:windows.LUID, handle:u32 }
Windows_GPU_Query :: struct { handle,kind:u32, data:rawptr, size:u32 }
Windows_GPU_Address :: struct { bus,device,function:u32 }
@(default_calling_convention="system")
foreign tm_gpu_gdi32 {
    D3DKMTOpenAdapterFromLuid :: proc(^Windows_GPU_Open)->i32 ---
    D3DKMTQueryAdapterInfo :: proc(^Windows_GPU_Query)->i32 ---
    D3DKMTCloseAdapter :: proc(^u32)->i32 ---
}
Windows_GPU_Adapter :: struct {
    valid:bool,
    luid:u64,
    vendor:u32,
    address:Windows_GPU_Address,
    address_valid:bool,
    dedicated,shared:u64,
}
Windows_GPU_Sensor :: struct #packed {
    name:[96]u8,
    vendor:u32,
    bus,device:i32,
    flags:u32,
    temperature,power_watts,fan_percent,frequency_mhz:f32,
}
#assert(size_of(Windows_GPU_Sensor)==128)

windows_gpu_sensor_slot :: proc(m:^Metrics,sensor:Windows_GPU_Sensor)->int {
    w:=windows_sampler(m)
    if sensor.vendor==0 {return -1}
    // Prefer a unique PCI bus/device join (AMD). Otherwise accept only a
    // unique exact name, or the sole adapter of a vendor (Intel iGPU naming).
    pci_slot,name_slot,vendor_slot:=-1,-1,-1
    pci_count,name_count,vendor_count:=0,0,0
    sensor_name_buffer:=sensor.name
    sensor_name:=string(sensor_name_buffer[:telemetry_cstring_len(sensor_name_buffer[:])])
    for info,i in w.gpu_adapters {
        if !info.valid||info.vendor!=sensor.vendor {continue}
        vendor_slot=i;vendor_count+=1
        if sensor.bus>=0&&sensor.device>=0&&info.address_valid&&info.address.bus==u32(sensor.bus)&&info.address.device==u32(sensor.device) {pci_slot=i;pci_count+=1}
        if sensor_name==string(m.gpus[i].name[:m.gpus[i].name_len]) {name_slot=i;name_count+=1}
    }
    if pci_count==1 {return pci_slot}
    if sensor.bus>=0&&sensor.device>=0 {return -1}
    if name_count==1 {return name_slot}
    if vendor_count==1 {return vendor_slot}
    return -1
}

// DXGI identifies every hardware adapter, independently of vendor SDKs. NVML
// remains the preferred NVIDIA sensor source; PCI identity joins its existing
// slot instead of creating a second card for the same physical GPU.
metrics_windows_init_gpus :: proc(m:^Metrics) {
    w:=windows_sampler(m)
    if w==nil {return}
    w.gpu_adapters={}
    factory:^dxgi.IFactory1
    if dxgi.CreateDXGIFactory1(dxgi.IFactory1_UUID,cast(^rawptr)&factory)<0||factory==nil {return}
    defer factory.Release(factory)
    by_pci:proc "c"(cstring,^rawptr)->i32
    if m._nvml.__handle!=nil {by_pci=cast(type_of(by_pci))dynlib.symbol_address(m._nvml.__handle,"nvmlDeviceGetHandleByPciBusId_v2")}
    nvml_count:=m.gpu_count
    claimed:[8]bool
    for index:u32=0;index<64;index+=1 {
        adapter:^dxgi.IAdapter1
        if factory.EnumAdapters1(factory,index,&adapter)<0||adapter==nil {break}
        desc:dxgi.ADAPTER_DESC1
        result:=adapter.GetDesc1(adapter,&desc)
        if result<0||.SOFTWARE in desc.Flags {_=adapter.Release(adapter);continue}
        if desc.VendorId==0x10de {m._gpu_nvml_expected=true}
        info:=Windows_GPU_Adapter{valid=true,vendor=desc.VendorId,
            luid=u64(desc.AdapterLuid.LowPart)|(u64(u32(desc.AdapterLuid.HighPart))<<32),
            dedicated=u64(desc.DedicatedVideoMemory)+u64(desc.DedicatedSystemMemory),shared=u64(desc.SharedSystemMemory)}
        integrated:=info.dedicated==0
        // BIOS-reserved "dedicated" RAM does not make an iGPU discrete. Ask
        // the actual architecture so single-adapter APUs/SoCs are classified
        // correctly too, not just hybrid laptops flagged by D3DKMT.
        device:^d3d12.IDevice
        if d3d12.CreateDevice(adapter,._11_0,d3d12.IDevice_UUID,cast(^rawptr)&device)>=0&&device!=nil {
            architecture:d3d12.FEATURE_DATA_ARCHITECTURE
            if device.CheckFeatureSupport(device,.ARCHITECTURE,&architecture,u32(size_of(architecture)))>=0 {integrated=architecture.UMA!=false}
            _=device.Release(device)
        }
        _=adapter.Release(adapter)
        opened:=Windows_GPU_Open{luid=desc.AdapterLuid}
        if D3DKMTOpenAdapterFromLuid(&opened)>=0 {
            query:=Windows_GPU_Query{handle=opened.handle,kind=6,data=&info.address,size=u32(size_of(info.address))}
            info.address_valid=D3DKMTQueryAdapterInfo(&query)>=0
            adapter_type:u32
            query={handle=opened.handle,kind=14,data=&adapter_type,size=4}
            if D3DKMTQueryAdapterInfo(&query)>=0 {integrated=integrated||(adapter_type&(1<<5))!=0}
            _=D3DKMTCloseAdapter(&opened.handle)
        }
        name_buffer:[96]u8
        name_count:=0
        for name_count<len(desc.Description)&&desc.Description[name_count]!=0 {name_count+=1}
        name_len:=windows_utf8(name_buffer[:],desc.Description[:name_count])
        slot:=-1
        if info.vendor==0x10de {
            if by_pci!=nil&&info.address_valid {
                buffer:[64]u8
                pci:=fmt.bprintf(buffer[:],"%x:%x.%x",info.address.bus,info.address.device,info.address.function)
                buffer[len(pci)]=0
                device:rawptr
                if by_pci(cstring(&buffer[0]),&device)==0 {
                    for i in 0..<nvml_count {if !claimed[i]&&m._gpu_devices[i]==device {slot=i;break}}
                }
            }
            if slot<0 {
                // Older drivers may not expose PCI lookup. Only an exact name
                // joins a slot; differently named GPUs must never be conflated.
                for i in 0..<nvml_count {
                    if !claimed[i]&&string(m.gpus[i].name[:m.gpus[i].name_len])==string(name_buffer[:name_len]) {slot=i;break}
                }
            }
        }
        if slot<0 {
            if m.gpu_count>=len(m.gpus) {continue}
            slot=m.gpu_count;m.gpu_count+=1
            g:=&m.gpus[slot]
            g^={name=name_buffer,name_len=name_len,unified_memory=integrated}
            if g.name_len==0 {g.name_len=copy(g.name[:],"Graphics adapter")}
            g.memory_total=info.dedicated
            if integrated {g.memory_total+=info.shared}
        } else {claimed[slot]=true}
        w.gpu_adapters[slot]=info
    }
}

windows_gpu_hex :: proc(text:string)->(u32,bool) {
    if len(text)!=8 {return 0,false}
    value:u32
    for c in text {
        digit:u32
        switch {
        case c>='0'&&c<='9':digit=u32(c-'0')
        case c>='a'&&c<='f':digit=u32(c-'a')+10
        case c>='A'&&c<='F':digit=u32(c-'A')+10
        case:return 0,false
        }
        value=(value<<4)|digit
    }
    return value,true
}
windows_gpu_counter_luid :: proc(name:string)->(u64,bool) {
    start:=strings.index(name,"luid_0x")
    if start<0||start+26>len(name) {return 0,false}
    high,high_ok:=windows_gpu_hex(name[start+7:start+15])
    if name[start+15:start+18]!="_0x" {return 0,false}
    low,low_ok:=windows_gpu_hex(name[start+18:start+26])
    if !high_ok||!low_ok {return 0,false}
    return u64(low)|(u64(high)<<32),true
}
windows_gpu_counter_slot :: proc(w:^Windows_Sampler,name:string)->int {
    luid,ok:=windows_gpu_counter_luid(name)
    if !ok {return -1}
    for adapter,i in w.gpu_adapters {if adapter.valid&&adapter.luid==luid {return i}}
    return -1
}
Windows_GPU_Process_Instance :: struct {
    pid:i32,
    luid:u64,
    physical,slot:int,
    dedicated,shared:u64,
    dedicated_available,shared_available:bool,
}
windows_gpu_process_identity :: proc(w:^Windows_Sampler,name:string)->(Windows_GPU_Process_Instance,bool) {
    if !strings.has_prefix(name,"pid_") {return {},false}
    pid:=telemetry_uint(name[4:])
    luid,luid_ok:=windows_gpu_counter_luid(name)
    physical:=strings.index(name,"_phys_")
    if pid==0||pid>u64(max(i32))||!luid_ok||physical<0 {return {},false}
    return Windows_GPU_Process_Instance{pid=i32(pid),luid=luid,physical=int(telemetry_uint(name[physical+6:])),slot=windows_gpu_counter_slot(w,name)},true
}
windows_gpu_process_instance :: proc(instances:^[dynamic]Windows_GPU_Process_Instance,identity:Windows_GPU_Process_Instance,limit:int)->^Windows_GPU_Process_Instance {
    for &entry in instances^ {
        if entry.pid==identity.pid&&entry.luid==identity.luid&&entry.physical==identity.physical {return &entry}
    }
    if len(instances^)>=limit {return nil}
    append(instances,identity)
    return &instances^[len(instances^)-1]
}
Windows_GPU_Engine :: struct {slot,physical,engine:int,usage:f64}

metrics_windows_sample_gpus :: proc(m:^Metrics) {
    w:=windows_sampler(m)
    if w==nil {return}
    for i in 0..<m.gpu_count {
        if m._gpu_devices[i]!=nil {continue}
        g:=&m.gpus[i]
        g.utilization_available,g.memory_available=false,false
        g.temperature_available,g.power_available,g.fan_available,g.frequency_available=false,false,false,false
    }
    // GPU Engine counters are per PID. Sum each physical engine across PIDs,
    // then select the busiest engine, matching Windows Task Manager semantics.
    engines:[dynamic]Windows_GPU_Engine
    defer delete(engines)
    items,ok:=windows_counter_array(w,w.gpu_engine)
    if ok {for item in items {
        if item.status>1||!windows_finite(item.value)||item.value<0 {continue}
        buffer:[512]u8
        name:=windows_wide_name(item.name,buffer[:])
        slot:=windows_gpu_counter_slot(w,name)
        phys:=strings.index(name,"_phys_");engine:=strings.index(name,"_eng_")
        if slot<0||phys<0||engine<0 {continue}
        physical:=int(telemetry_uint(name[phys+6:]));engine_id:=int(telemetry_uint(name[engine+5:]))
        found:=false
        for &entry in engines {
            if entry.slot==slot&&entry.physical==physical&&entry.engine==engine_id {entry.usage+=item.value;found=true;break}
        }
        if !found {append(&engines,Windows_GPU_Engine{slot=slot,physical=physical,engine=engine_id,usage=item.value})}
    }}
    busy:[8]f64;busy_ok:[8]bool
    for engine in engines {busy[engine.slot]=max(busy[engine.slot],engine.usage);busy_ok[engine.slot]=true}
    dedicated,shared:[8]u64
    dedicated_ok,shared_ok:[8]bool
    for counter,index in ([2]rawptr{w.gpu_adapter_memory,w.gpu_adapter_shared}) {
        memory,available:=windows_counter_array(w,counter)
        if !available {continue}
        for item in memory {
            if item.status>1||!windows_finite(item.value)||item.value<0||item.value>=f64(max(u64)) {continue}
            buffer:[512]u8
            slot:=windows_gpu_counter_slot(w,windows_wide_name(item.name,buffer[:]))
            if slot<0 {continue}
            if index==0 {dedicated[slot]+=u64(item.value);dedicated_ok[slot]=true} else {shared[slot]+=u64(item.value);shared_ok[slot]=true}
        }
    }
    for i in 0..<m.gpu_count {
        g:=&m.gpus[i]
        if !g.utilization_available&&busy_ok[i] {g.utilization=f32(clamp(busy[i],0,100));g.utilization_available=true}
        if !g.memory_available&&w.gpu_adapters[i].valid {
            info:=w.gpu_adapters[i]
            g.memory_total=info.dedicated
            g.memory_used=dedicated[i]
            g.memory_available=dedicated_ok[i]&&info.dedicated>0&&g.memory_used<=g.memory_total
            if g.unified_memory {
                g.memory_total+=info.shared;g.memory_used+=shared[i]
                g.memory_available=shared_ok[i]&&(dedicated_ok[i]||info.dedicated==0)&&g.memory_total>0
            }
        }
    }
    for sensor in w.gpu_sensors[:w.gpu_sensor_count] {
        slot:=windows_gpu_sensor_slot(m,sensor)
        if slot<0 {continue}
        g:=&m.gpus[slot]
        if !g.temperature_available&&sensor.flags&1!=0&&windows_finite(sensor.temperature)&&sensor.temperature>=0&&sensor.temperature<=200 {g.temperature=sensor.temperature;g.temperature_available=true}
        if !g.power_available&&sensor.flags&2!=0&&windows_finite(sensor.power_watts)&&sensor.power_watts>=0 {g.power_watts=sensor.power_watts;g.power_available=true}
        if !g.fan_available&&sensor.flags&4!=0&&windows_finite(sensor.fan_percent)&&sensor.fan_percent>=0&&sensor.fan_percent<=100 {g.fan_percent=sensor.fan_percent;g.fan_available=true}
        if !g.frequency_available&&sensor.flags&8!=0&&windows_finite(sensor.frequency_mhz)&&sensor.frequency_mhz>0 {g.frequency_mhz=sensor.frequency_mhz;g.frequency_available=true}
    }
}

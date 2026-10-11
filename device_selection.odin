package main

// Selection belongs to each machine, just like its scroll and pinned history.
device_selector :: proc(a:^App,index:^int,labels:[]string,x,y,w:f32,fallback:string="") {
    count:=len(labels)
    index^=clamp(index^,0,max(0,count-1))
    if count<=1 {
        fit_text(a,labels[0] if count==1 else fallback,x,y+20,w,17)
        return
    }
    max_title_w:=max(0,w-72)
    title_w:=min(max_title_w,renderer_text_width(&a.renderer,labels[index^],17*a.scale)/a.scale+1)
    draw_y:=y
    right:=x+36+title_w+8
    for direction in 0..<2 {
        bx:=x if direction==0 else right
        if hit(a,bx,y,28,28) {
            index^=(index^+count+(-1 if direction==0 else 1))%count
            draw_y=y+(a.cpu_scroll if a.view==.CPU else a.gpu_scroll)
            if a.view==.CPU {a.cpu_pinned_slot=-1;a.cpu_scroll=0}
            else {a.gpu_pinned_slot=-1;a.gpu_scroll=0}
            a.graph_readout.initialized=false
            a.click=false;a.dirty=true
            // Switching can change the name width. Draw both arrows around
            // the newly selected name immediately.
            title_w=min(max_title_w,renderer_text_width(&a.renderer,labels[index^],17*a.scale)/a.scale+1)
            right=x+36+title_w+8
            break
        }
    }
    for direction in 0..<2 {
        bx:=x if direction==0 else right
        hovered:=a.mouse_x>=bx&&a.mouse_x<bx+28&&a.mouse_y>=draw_y&&a.mouse_y<draw_y+28&&
            (!a.clip_active||a.mouse_y>=a.clip_top&&a.mouse_y<a.clip_bottom)
        if hovered {rounded_rect(a,bx,draw_y,28,28,5,LINE)}
        center:=bx+14
        tip:=center-3 if direction==0 else center+3
        tail:=center+3 if direction==0 else center-3
        tint:=TEXT if hovered else SOFT
        stroke(a,tail,draw_y+9,tip,draw_y+14,1.5,tint)
        stroke(a,tip,draw_y+14,tail,draw_y+19,1.5,tint)
    }
    fit_text(a,labels[index^],x+36,draw_y+20,title_w,17)
}

cpu_packages :: proc(m:^Metrics)->(ids:[256]int,count:int) {
    for core in m.physical_cores[:m.physical_core_count] {
        seen:=false
        for id in ids[:count] {if id==core.package_id {seen=true;break}}
        if !seen {ids[count]=core.package_id;count+=1}
    }
    return
}

CPU_Device_Sample :: struct {
    lower,upper,threads,power_watts,frequency_mhz:f32,
    power_available,frequency_available:bool,
}

cpu_device_sample :: proc(a:^App,s:^CPU_Sample)->CPU_Device_Sample {
    ids,count:=cpu_packages(&a.metrics)
    if count<=1 {return {lower=s.lower,upper=s.upper,threads=s.threads,power_watts=s.power_watts,
        frequency_mhz=s.frequency_mhz,power_available=s.power_available,frequency_available=s.frequency_available}}
    id:=ids[clamp(a.selected_cpu,0,count-1)]
    result:CPU_Device_Sample
    cores,threads,frequencies:int
    frequency_sum,weighted_frequency,weight:f32
    for &core,i in a.metrics.physical_cores[:a.metrics.physical_core_count] {
        if core.package_id!=id {continue}
        value:=&s.cores[i]
        result.lower+=value.lower;result.upper+=value.upper;cores+=1
        for logical in core.logical_ids[:core.logical_count] {result.threads+=s.logical[logical];threads+=1}
        if value.frequency_available {
            frequency_sum+=value.frequency_mhz;frequencies+=1
            weighted_frequency+=value.frequency_mhz*value.lower;weight+=value.lower
        }
    }
    if cores>0 {result.lower/=f32(cores);result.upper/=f32(cores)}
    if threads>0 {result.threads/=f32(threads)}
    if frequencies>0 {
        result.frequency_available=true
        result.frequency_mhz=weighted_frequency/weight if weight>0 else frequency_sum/f32(frequencies)
    }
    for power in s.cpu_package_power[:s.cpu_package_power_count] {
        if power.package_id==id {result.power_watts=power.watts;result.power_available=power.available;break}
    }
    return result
}

gpu_device_sample :: proc(a:^App,s:^CPU_Sample)->^GPU_Sample {
    index:=clamp(a.selected_gpu,0,max(0,a.metrics.gpu_count-1))
    if index<s.gpu_count {return &s.gpus[index]}
    // Caches from an older sampler only contain the first device's history.
    if index==0 {return &s.gpu}
    return &s.gpus[index]
}

// Merge only samples of the same timestamp; these fields never borrow a
// different device's or a different moment's readings.
history_device_cache :: proc(destination:^CPU_Sample,source:Persistence_Sample) {
    copy(destination.gpus[:],source.gpus);destination.gpu_count=len(source.gpus)
    copy(destination.cpu_package_power[:],source.cpu_package_power)
    destination.cpu_package_power_count=len(source.cpu_package_power)
}
history_device_copy :: proc(destination,source:^CPU_Sample) {
    if destination.gpu_count==0&&source.gpu_count>0 {destination.gpus=source.gpus;destination.gpu_count=source.gpu_count}
    if destination.cpu_package_power_count==0&&source.cpu_package_power_count>0 {
        destination.cpu_package_power=source.cpu_package_power;destination.cpu_package_power_count=source.cpu_package_power_count
    }
}

history_device_sample :: proc(destination:^CPU_Sample,m:^Metrics) {
    destination.gpu_count=m.gpu_count
    for &device,i in m.gpus[:m.gpu_count] {destination.gpus[i]=gpu_sample(&device,true)}
    destination.cpu_package_power=m.cpu_package_power;destination.cpu_package_power_count=m.cpu_package_power_count
}

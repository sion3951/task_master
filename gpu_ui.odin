package main

import "core:fmt"
import "core:math"

GPU_Sample :: struct {
    utilization, power_watts, temperature, fan_percent, memory_percent, frequency_mhz, power_max_watts: f32,
    memory_used, memory_total: u64,
    utilization_available, memory_available, power_available, temperature_available, fan_available, frequency_available, power_max_available: bool,
    unified_memory: bool,
    recorded: bool,
    legacy: bool,
}
GPU_Plot :: enum { Utilization, Memory, Power, Frequency }
GPU_MEMORY_GB :: 1073741824

gpu_sample :: proc(g:^GPU_Metric,available:bool)->GPU_Sample {
    if !available {return {recorded=true}}
    return {unified_memory=g.unified_memory,utilization=g.utilization,power_watts=g.power_watts,temperature=g.temperature,fan_percent=g.fan_percent,
        frequency_mhz=g.frequency_mhz,frequency_available=g.frequency_available,
        power_max_watts=g.power_max_watts,power_max_available=g.power_max_available,
        memory_used=g.memory_used,memory_total=g.memory_total,utilization_available=g.utilization_available,
        memory_available=g.memory_available,power_available=g.power_available,
        temperature_available=g.temperature_available,fan_available=g.fan_available,recorded=true}
}
// Older persistence services already retain utilisation and VRAM percentages.
// Their latest snapshot also carries all sensors for that exact sample time.
gpu_cache_sample :: proc(s:Persistence_Sample,m:^Metrics,latest:bool)->GPU_Sample {
    if s.gpu.recorded {return s.gpu}
    if latest {return gpu_sample(&m.gpus[0],m.gpu_count>0)}
    g:=&m.gpus[0]
    return {utilization=s.overview[1],memory_percent=s.overview[3],
        memory_used=u64(f64(s.overview[3])*f64(g.memory_total)/100),memory_total=g.memory_total,
        utilization_available=m.gpu_count>0&&g.utilization_available,
        memory_available=m.gpu_count>0&&g.memory_available,unified_memory=g.unified_memory,recorded=true,legacy=true}
}
gpu_plot_value :: proc(s:^GPU_Sample,kind:GPU_Plot)->(f32,bool) {
    switch kind {
    case .Utilization:return s.utilization,s.utilization_available
    case .Memory:return f32(f64(s.memory_used)/GPU_MEMORY_GB),s.memory_available&&s.memory_total>0
    case .Power:return s.power_watts,s.power_available
    case .Frequency:return s.frequency_mhz,s.frequency_available
    }
    return 0,false
}
gpu_plot :: proc(a:^App,kind:GPU_Plot,x,y,w,h,ceiling:f32,render_pass:Graph_Pass=.All) {
    if a.history_count<2||w<=0||h<=0 {return}
    if render_pass==.All {
        for pass in ([2]Graph_Pass{.Fill,.Line}) {
            for incoming in ([2]bool{false,true}) {
                animation,draw:=graph_animation_begin(a,incoming,x,w)
                if draw {gpu_plot(a,kind,x,y,w,h,ceiling,pass)}
                graph_animation_end(a,animation)
            }
        }
        return
    }
    graph_smoothing_prepare(a)
    first:=(a.history_next-a.history_count+HISTORY_CAPACITY)%HISTORY_CAPACITY
    for i in 1..<a.history_count {
        prev,next:=graph_plot_sample(a,(first+i-1)%HISTORY_CAPACITY),graph_plot_sample(a,(first+i)%HISTORY_CAPACITY)
        v0,ok0:=gpu_plot_value(&prev.gpu,kind)
        v1,ok1:=gpu_plot_value(&next.gpu,kind)
        dt:=f32(next.timestamp-prev.timestamp)
        if !ok0||!ok1||!history_segment_contiguous(prev,next) {continue}
        p0,p1:=history_position(a,(first+i-1)%HISTORY_CAPACITY),history_position(a,(first+i)%HISTORY_CAPACITY)
        if p1<=0||p1<=p0 {continue}
        slope:=(v1-v0)/dt
        m0,m1:=slope,slope
        if i>1 {
            before:=graph_plot_sample(a,(first+i-2)%HISTORY_CAPACITY)
            value,available:=gpu_plot_value(&before.gpu,kind)
            before_dt:=f32(prev.timestamp-before.timestamp)
            if available&&history_segment_contiguous(before,prev) {m0=cpu_curve_slope((v0-value)/before_dt,slope,before_dt,dt)}
        }
        if i+1<a.history_count {
            after:=graph_plot_sample(a,(first+i+1)%HISTORY_CAPACITY)
            value,available:=gpu_plot_value(&after.gpu,kind)
            after_dt:=f32(after.timestamp-next.timestamp)
            if available&&history_segment_contiguous(next,after) {m1=cpu_curve_slope(slope,(value-v1)/after_dt,dt,after_dt)}
        }
        curve:=[4]f32{v0,v1,m0*dt,m1*dt}
        start:=max(0,-p0/(p1-p0))
        extent:=max(w*(p1-p0)*(1-start),h*abs(v1-v0)/ceiling)
        steps:=clamp(int(math.ceil(extent*a.scale/3)),4,128)
        last_x,last_y:f32
        last_color:Color
        for j in 0..=steps {
            t:=start+(1-start)*f32(j)/f32(steps)
            value:=cpu_curve_value(curve,t)
            xx,yy:=x+w*(p0+(p1-p0)*t),y+h*(1-clamp(value/ceiling,0,1))
            color_value:=value
            if kind==.Memory {color_value=100*value/f32(f64(prev.gpu.memory_total)/GPU_MEMORY_GB)}
            tint:=AMBER if kind==.Power else (CYAN if kind==.Frequency else utilization_color(color_value))
            if j>0 {
                if render_pass==.Fill {
                    color_scale:=ceiling/f32(f64(prev.gpu.memory_total)/GPU_MEMORY_GB) if kind==.Memory else f32(1)
                    graph_fill_segment(a,last_x,last_y,xx,yy,y+h,last_color,tint,h,kind==.Utilization||kind==.Memory,color_scale)
                }
                else {stroke_gradient(a,last_x,last_y,xx,yy,1.6,last_color,tint)}
            }
            last_x,last_y,last_color=xx,yy,tint
        }
    }
}

gpu_dashboard :: proc(a:^App) {
    m:=&a.metrics
    x,w:=a.content_x,a.width-a.content_x-16
    if w<160 {return}
    compact:=w<700
    stats_cols:=2 if compact else 5
    stats_h:=f32(198) if compact else f32(66)
    graph_y:=f32(72)+65+stats_h
    viewport_top,viewport_bottom:=f32(72),a.height-28
    plot_gap,header_h,time_axis_h:=f32(50),f32(36),f32(22)
    busy_h,small_h:=f32(82),f32(38)
    process_h:=f32(230)
    controls_h:=graph_controls_height(w-36)+8
    graph_h:=header_h+busy_h+small_h*2+plot_gap*2+time_axis_h+controls_h
    spare:=max(0,viewport_bottom-(graph_y+graph_h+34+process_h))
    busy_h+=spare*0.25;small_h+=spare*0.125;process_h+=spare*0.5
    graph_h=header_h+busy_h+small_h*2+plot_gap*2+time_axis_h+controls_h
    process_y:=graph_y+graph_h+34
    content_bottom:=process_y+process_h
    max_scroll:=max(0,content_bottom-viewport_bottom)
    a.gpu_scroll=clamp(a.gpu_scroll,0,max_scroll)
    offset:=a.gpu_scroll
    a.clip_active=true;a.clip_top,a.clip_bottom=viewport_top,viewport_bottom
    defer a.clip_active=false
    g:=&m.gpus[0]
    fit_text(a,string(g.name[:g.name_len]) if m.gpu_count>0 else "No NVIDIA device available",x,99-offset,w,17)
    first:=(a.history_next-a.history_count+HISTORY_CAPACITY)%HISTORY_CAPACITY
    gx,gy,gw:=x+36,graph_y+header_h-offset,w-36
    power_y:=gy+busy_h+small_h+plot_gap*2
    column_gap:=f32(24)
    column_w:=(w-column_gap)/2
    power_w:=column_w-36
    frequency_gx:=x+column_w+column_gap+36
    a.cpu_graph_x,a.cpu_graph_y,a.cpu_graph_w,a.cpu_graph_h=gx,gy,gw,busy_h+small_h*2+plot_gap*2
    hover_x,hover_w:=gx,gw
    if a.mouse_y>=power_y {
        hover_w=power_w
        if a.mouse_x>=frequency_gx {hover_x=frequency_gx}
    }
    in_plot:=a.mouse_x>=hover_x&&a.mouse_x<=hover_x+hover_w&&a.mouse_y>=gy&&a.mouse_y<=gy+a.cpu_graph_h&&a.mouse_y>=viewport_top&&a.mouse_y<=viewport_bottom
    hover_slot:=-1
    position:=clamp((a.mouse_x-hover_x)/hover_w,0,1)
    hover_graph:=0
    if a.mouse_y>=gy+busy_h+plot_gap {hover_graph=1}
    if a.mouse_y>=power_y {hover_graph=3 if a.mouse_x>=frequency_gx else 2}
    if in_plot&&a.history_count>0 {
        if position>=history_position(a,first) {
            distance:=f32(2)
            for i in 0..<a.history_count {
                candidate:=(first+i)%HISTORY_CAPACITY
                p:=history_position(a,candidate)
                if p<0 {continue}
                delta:=abs(p-position)
                if delta<distance {distance=delta;hover_slot=candidate}
            }
        }
    }
    if a.click&&in_plot {
        if a.gpu_pinned_slot>=0 {a.gpu_pinned_slot=-1}
        else {a.gpu_pinned_slot=hover_slot;a.gpu_pinned_graph=hover_graph}
    }
    slot:=a.gpu_pinned_slot if a.gpu_pinned_slot>=0 else hover_slot
    if slot>=0&&history_position(a,slot)<0 {slot=-1;a.gpu_pinned_slot=-1}
    if slot<0&&a.history_count>0 {slot=(a.history_next+HISTORY_CAPACITY-1)%HISTORY_CAPACITY}
    current:=gpu_sample(g,m.gpu_count>0)
    if slot>=0 {current=graph_readout_sample(a,&a.cpu_history[slot],hover_slot>=0||a.gpu_pinned_slot>=0,hover_slot>=0&&a.gpu_pinned_slot<0,hover_w).gpu}
    detail:="GPU telemetry unavailable. CPU and memory remain live."
    if m.gpu_count>0 {
        memory:=bytes_label(g.memory_total) if g.memory_available else "Memory unavailable"
        fan:=fmt.tprintf("Fan %.0f%%",current.fan_percent) if current.fan_available else "Fan unavailable"
        detail=fmt.tprintf("%s %s memory / %s",memory,"shared system" if g.unified_memory else "dedicated",fan) if g.memory_available else fmt.tprintf("%s / %s",memory,fan)
    }
    fit_text(a,detail,x,121-offset,w,12,MUTED)
    labels:=[5]string{"GPU utilization","Shared allocations" if current.unified_memory else "Video memory used","GPU power","GPU frequency","Temperature"}
    values:=[5]string{
        fmt.tprintf("%.0f%%",current.utilization) if current.utilization_available else "--",
        (bytes_label(current.memory_used) if current.memory_total>0 else fmt.tprintf("%.0f%%",current.memory_percent)) if current.memory_available else "--",
        fmt.tprintf("%.0f W",current.power_watts) if current.power_available else "--",
        fmt.tprintf("%.0f MHz",current.frequency_mhz) if current.frequency_available else "--",
        fmt.tprintf("%.0f C",current.temperature) if current.temperature_available else "--"}
    stats_w:=(w-f32(stats_cols-1)*20)/f32(stats_cols)
    for label,i in labels {
        sx,sy:=x+f32(i%stats_cols)*(stats_w+20),f32(147)+f32(i/stats_cols)*66-offset
        fit_text(a,label,sx,sy,stats_w,12,MUTED)
        tint:=TEXT
        if i==0&&current.utilization_available {tint=utilization_color(current.utilization)}
        if i==1&&current.memory_available {tint=utilization_color(memory_pct(current.memory_used,current.memory_total))}
        if i==3&&current.frequency_available {tint=CYAN}
        fit_text(a,values[i],sx,sy+34,stats_w,27 if w>850||compact else 22,tint)
    }
    power_max_known:=g.power_max_available||current.power_max_available
    power_max:=g.power_max_watts if g.power_max_available else (current.power_max_watts if current.power_max_available else f32(50))
    frequency_max:=f32(500)
    for i in 0..<a.history_count {
        candidate:=(first+i)%HISTORY_CAPACITY
        s:=&a.cpu_history[candidate].gpu
        if history_position(a,candidate)<0 {continue}
        if !power_max_known&&s.power_available {power_max=max(power_max,f32(math.ceil(s.power_watts/50))*50)}
        if s.frequency_available {frequency_max=max(frequency_max,f32(math.ceil(s.frequency_mhz/500))*500)}
    }
    kinds:=[2]GPU_Plot{.Utilization,.Memory}
    power_max=graph_animation_ceiling(a,power_max,.GPU_Power)
    frequency_max=graph_animation_ceiling(a,frequency_max,.GPU_Frequency)
    headings:=[2]string{"GPU UTILIZATION %","SHARED ALLOCATIONS GB" if current.unified_memory else "VIDEO MEMORY GB"}
    memory_total:=g.memory_total if g.memory_total>0 else current.memory_total
    memory_max:=max(f32(1),f32(math.ceil(f64(memory_total)/GPU_MEMORY_GB)))
    if g.unified_memory {
        for i in 0..<a.history_count {
            s:=&a.cpu_history[(first+i)%HISTORY_CAPACITY].gpu
            if s.unified_memory&&s.memory_available {memory_max=max(memory_max,f32(math.ceil(f64(s.memory_used)/GPU_MEMORY_GB)))}
        }
    }
    memory_max=graph_animation_ceiling(a,memory_max,.GPU_Memory)
    yy:=gy
    for kind,i in kinds {
        hh:=busy_h if i==0 else small_h
        ceiling:=memory_max if kind==.Memory else f32(100)
        fit_text(a,headings[i],x,yy-18,w,12,MUTED)
        _,available:=gpu_plot_value(&current,kind)
        if !available {right_text(a,"Unavailable",x+w,yy-18,12,MUTED)}
        if kind==.Memory {memory_gb_grid(a,gx,yy,gw,hh,ceiling)}
        else {cpu_grid(a,gx,yy,gw,hh,ceiling,.Busy)}
        gpu_plot(a,kind,gx,yy,gw,hh,ceiling)
        yy+=hh+plot_gap
    }
    graph_bottom:=gy+a.cpu_graph_h
    paired_kinds:=[2]GPU_Plot{.Power,.Frequency}
    paired_headings:=[2]string{"GPU POWER W","GPU FREQUENCY MHz"}
    paired_ceilings:=[2]f32{power_max,frequency_max}
    for kind,column in paired_kinds {
        column_x:=x+f32(column)*(column_w+column_gap)
        plot_x:=column_x+36
        fit_text(a,paired_headings[column],column_x,power_y-18,column_w,12,MUTED)
        _,available:=gpu_plot_value(&current,kind)
        if !available {right_text(a,"Unavailable",column_x+column_w,power_y-18,12,MUTED)}
        cpu_grid(a,plot_x,power_y,power_w,small_h,paired_ceilings[column],.Power)
        gpu_plot(a,kind,plot_x,power_y,power_w,small_h,paired_ceilings[column])
        text(a,graph_time_axis_label(a),plot_x,graph_bottom+time_axis_h,12,MUTED)
        right_text(a,history_end_label(a),plot_x+power_w,graph_bottom+time_axis_h,12,MUTED)
    }
    if slot>=0&&(hover_slot>=0||a.gpu_pinned_slot>=0) {
        cursor_position:=history_position(a,slot)
        if a.gpu_pinned_slot<0 {cursor_position=position}
        cursor_x:=gx+gw*cursor_position
        stroke(a,cursor_x,gy,cursor_x,power_y-plot_gap,1,MUTED)
        for column in 0..<2 {
            cursor_x=gx+f32(column)*(column_w+column_gap)+power_w*cursor_position
            stroke(a,cursor_x,power_y,cursor_x,graph_bottom,1,MUTED)
        }
        graph_xs:=[4]f32{gx,gx,gx,frequency_gx}
        graph_ys:=[4]f32{gy,gy+busy_h+plot_gap,power_y,power_y}
        graph_ws:=[4]f32{gw,gw,power_w,power_w}
        graph_hs:=[4]f32{busy_h,small_h,small_h,small_h}
        label_graph:=clamp(a.gpu_pinned_graph if a.gpu_pinned_slot>=0 else hover_graph,0,3)
        cursor_x=graph_xs[label_graph]+graph_ws[label_graph]*cursor_position
        history_time_label(a,slot,a.gpu_pinned_slot>=0,cursor_x,graph_xs[label_graph],graph_ys[label_graph],graph_ws[label_graph],graph_hs[label_graph])
    }
    graph_controls_draw(a,gx,graph_bottom+time_axis_h+8,gw)
    // Keep the process table's established sorting, PID expansion and scrolling.
    process_panel(a,x-18,process_y-offset,w+36,process_h,gpu=true,unboxed=true)
    if max_scroll>0 {
        track_h:=viewport_bottom-viewport_top
        thumb_h:=max(24,track_h*track_h/(content_bottom-viewport_top))
        thumb_y:=viewport_top+(track_h-thumb_h)*a.gpu_scroll/max_scroll
        rect(a,x+w+9,thumb_y,2,thumb_h,MUTED)
    }
}

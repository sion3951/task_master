package main

import "core:fmt"
import "core:math"

// Memory, disk and network share the CPU dashboard's smooth history renderer.
CPU_Plot :: enum { Busy, Threads, Power, Frequency, Memory, Swap, Disk_Read, Disk_Write, Network_RX, Network_TX, Memory_Free, Memory_Cached, Memory_Buffers, Memory_Available }

cpu_plot_topology :: proc(kind:CPU_Plot)->bool {
    return kind==.Busy||kind==.Threads||kind==.Power||kind==.Frequency
}

cpu_plot_utilization :: proc(kind:CPU_Plot)->bool {
    return kind==.Busy||kind==.Threads||kind==.Swap
}

cpu_range_label :: proc(lower,upper:f32)->string {
    if math.round(lower)==math.round(upper) {return fmt.tprintf("%.0f%%",lower)}
    return fmt.tprintf("%.0f-%.0f%%",lower,upper)
}

cpu_plot_value :: proc(s:^CPU_Sample,kind:CPU_Plot,core:int=-1)->(f32,bool) {
    switch kind {
    case .Busy:
        if core>=0 {return s.cores[core].lower,true}
        return s.lower,true
    case .Threads: return s.threads,true
    case .Power: return s.power_watts,s.power_available
    case .Frequency:
        if core>=0 {return s.cores[core].frequency_mhz,s.cores[core].frequency_available}
        return s.frequency_mhz,s.frequency_available
    case .Memory: return memory_gb(s.memory_used),s.ram_available
    case .Memory_Free: return memory_gb(s.memory_free),s.ram_available&&(s.memory_free_available||s.memory_breakdown_available)
    case .Memory_Cached: return memory_gb(s.memory_cached),s.ram_available&&(s.memory_cached_available||s.memory_breakdown_available)
    case .Memory_Buffers: return memory_gb(s.memory_buffers),s.ram_available&&(s.memory_buffers_available||s.memory_breakdown_available)
    case .Memory_Available: return memory_gb(s.memory_available),s.ram_available
    case .Swap: return memory_pct(s.swap_used,s.swap_total),s.ram_available&&s.swap_total>0
    case .Disk_Read: return f32(s.disk_read),s.rates_ready
    case .Disk_Write: return f32(s.disk_write),s.rates_ready
    case .Network_RX: return f32(s.network_rx),s.network_rates_ready
    case .Network_TX: return f32(s.network_tx),s.network_rates_ready
    }
    return 0,false
}

cpu_curve_sample :: proc(s:^CPU_Sample,kind:CPU_Plot,core:int,upper:bool)->(f32,bool) {
    if kind==.Busy&&upper {
        if core>=0 {return s.cores[core].upper,true}
        return s.upper,true
    }
    return cpu_plot_value(s,kind,core)
}

cpu_curve_slope :: proc(left,right,left_dt,right_dt:f32)->f32 {
    // Monotone cubic tangents round corners without inventing peaks or dips.
    if left*right<=0 {return 0}
    w0,w1:=2*right_dt+left_dt,right_dt+2*left_dt
    return (w0+w1)/(w0/left+w1/right)
}

cpu_plot_curve :: proc(a:^App,kind:CPU_Plot,first,index,core:int,upper:bool=false)->[4]f32 {
    prev:=graph_plot_sample(a,(first+index)%HISTORY_CAPACITY)
    next:=graph_plot_sample(a,(first+index+1)%HISTORY_CAPACITY)
    v0,_:=cpu_curve_sample(prev,kind,core,upper)
    v1,_:=cpu_curve_sample(next,kind,core,upper)
    dt:=f32(next.timestamp-prev.timestamp)
    if dt<=0 {return {v0,v1,0,0}}
    slope:=(v1-v0)/dt
    m0,m1:=slope,slope
    if index>0 {
        before:=graph_plot_sample(a,(first+index-1)%HISTORY_CAPACITY)
        before_dt:=f32(prev.timestamp-before.timestamp)
        value,available:=cpu_curve_sample(before,kind,core,upper)
        if available&&(!cpu_plot_topology(kind)||before.generation==prev.generation)&&history_segment_contiguous(before,prev) {
            m0=cpu_curve_slope((v0-value)/before_dt,slope,before_dt,dt)
        }
    }
    if index+2<a.history_count {
        after:=graph_plot_sample(a,(first+index+2)%HISTORY_CAPACITY)
        after_dt:=f32(after.timestamp-next.timestamp)
        value,available:=cpu_curve_sample(after,kind,core,upper)
        if available&&(!cpu_plot_topology(kind)||after.generation==next.generation)&&history_segment_contiguous(next,after) {
            m1=cpu_curve_slope(slope,(value-v1)/after_dt,dt,after_dt)
        }
    }
    return {v0,v1,m0*dt,m1*dt}
}

cpu_curve_value :: proc(curve:[4]f32,t:f32)->f32 {
    t2,t3:=t*t,t*t*t
    value:=(2*t3-3*t2+1)*curve[0]+(t3-2*t2+t)*curve[2]+(-2*t3+3*t2)*curve[1]+(t3-t2)*curve[3]
    return clamp(value,min(curve[0],curve[1]),max(curve[0],curve[1]))
}

cpu_plot_smooth_segment :: proc(a:^App,kind:CPU_Plot,first,index,core:int,x,y,w,h,ceiling:f32,color:Color,band:bool,render_pass:Graph_Pass) {
    p0,p1:=history_position(a,(first+index)%HISTORY_CAPACITY),history_position(a,(first+index+1)%HISTORY_CAPACITY)
    if p1<=0||p1<=p0 {return}
    start:=max(0,-p0/(p1-p0))
    lower:=cpu_plot_curve(a,kind,first,index,core)
    upper:[4]f32
    if band&&render_pass==.Fill {upper=cpu_plot_curve(a,kind,first,index,core,true)}
    // Tessellate in screen pixels, then send both the line and band to Vulkan.
    extent:=max(w*(p1-p0)*(1-start),h*abs(lower[1]-lower[0])/ceiling)
    steps:=clamp(int(math.ceil(extent*a.scale/3)),4,128)
    bottom,top:[129][2]f32
    colors:[129]Color
    for j in 0..=steps {
        t:=start+(1-start)*f32(j)/f32(steps)
        value:=cpu_curve_value(lower,t)
        xx:=x+w*(p0+(p1-p0)*t)
        bottom[j]={xx,y+h*(1-clamp(value/ceiling,0,1))}
        if band&&render_pass==.Fill {top[j]={xx,y+h*(1-clamp(max(value,cpu_curve_value(upper,t))/ceiling,0,1))}}
        colors[j]=utilization_color(value) if cpu_plot_utilization(kind) else color
    }
    if render_pass==.Fill {
        for j in 1..=steps {
            b0,b1:=bottom[j-1],bottom[j]
            graph_fill_segment(a,b0[0],b0[1],b1[0],b1[1],y+h,colors[j-1],colors[j],h,cpu_plot_utilization(kind))
        }
    }
    // Keep the existing busy-time uncertainty band stronger than the fade.
    if band&&render_pass==.Fill {
        for j in 1..=steps {
            b0,b1,t0,t1:=bottom[j-1],bottom[j],top[j-1],top[j]
            if a.clip_active {
                b0[1],b1[1]=clamp(b0[1],a.clip_top,a.clip_bottom),clamp(b1[1],a.clip_top,a.clip_bottom)
                t0[1],t1[1]=clamp(t0[1],a.clip_top,a.clip_bottom),clamp(t1[1],a.clip_top,a.clip_bottom)
            }
            c0,c1:=colors[j-1],colors[j];c0[3],c1[3]=0.16,0.16
            points:=[6][2]f32{t0,t1,b1,t0,b1,b0}
            shades:=[6]Color{c0,c1,c1,c0,c1,c0}
            for p,k in points {append(&a.vertices,Vertex{pos={p[0]*a.scale,p[1]*a.scale},color=shades[k]})}
        }
    }
    if render_pass==.Fill {return}
    for j in 1..=steps {
        b0,b1:=bottom[j-1],bottom[j]
        stroke_gradient(a,b0[0],b0[1],b1[0],b1[1],1.6,colors[j-1],colors[j])
    }
}

cpu_plot :: proc(a:^App,kind:CPU_Plot,core:int,x,y,w,h,ceiling:f32,color:Color,band:bool=false,dashed:bool=false,render_pass:Graph_Pass=.All) {
    if w<=0||h<=0||ceiling<=0||a.history_count<2 {return}
    if render_pass==.All {
        for pass in ([2]Graph_Pass{.Fill,.Line}) {
            for incoming in ([2]bool{false,true}) {
                animation,draw:=graph_animation_begin(a,incoming,x,w)
                if draw {cpu_plot(a,kind,core,x,y,w,h,ceiling,color,band,dashed,pass)}
                graph_animation_end(a,animation)
            }
        }
        return
    }
    graph_smoothing_prepare(a)
    first:=(a.history_next-a.history_count+HISTORY_CAPACITY)%HISTORY_CAPACITY
    for i in 1..<a.history_count {
        prev:=graph_plot_sample(a,(first+i-1)%HISTORY_CAPACITY)
        next:=graph_plot_sample(a,(first+i)%HISTORY_CAPACITY)
        if cpu_plot_topology(kind)&&(prev.generation!=a.metrics.cpu_topology_generation||next.generation!=a.metrics.cpu_topology_generation) {continue}
        pv,pok:=cpu_plot_value(prev,kind,core)
        nv,nok:=cpu_plot_value(next,kind,core)
        if !pok||!nok {continue}
        if !history_segment_contiguous(prev,next) {continue}
        if kind!=.Threads {
            cpu_plot_smooth_segment(a,kind,first,i-1,core,x,y,w,h,ceiling,color,band,render_pass)
            continue
        }
        raw_prev,raw_next:=pv,nv
        pc,nc:=color,color
        if kind==.Busy||kind==.Threads {pc,nc=utilization_color(pv),utilization_color(nv)}
        p0,p1:=history_position(a,(first+i-1)%HISTORY_CAPACITY),history_position(a,(first+i)%HISTORY_CAPACITY)
        if p1<=0 {continue}
        clipped:=f32(0)
        if p0<0 {
            clipped=-p0/(p1-p0)
            pv+=(nv-pv)*clipped
            pc=color_mix(pc,nc,clipped)
            p0=0
        }
        x0:=x+w*p0
        x1:=x+w*p1
        y0:=y+h*(1-clamp(pv/ceiling,0,1))
        y1:=y+h*(1-clamp(nv/ceiling,0,1))
        if render_pass==.Fill {graph_fill_segment(a,x0,y0,x1,y1,y+h,pc,nc,h,cpu_plot_utilization(kind))}
        if band&&render_pass==.Fill {
            pu,nu:=prev.upper,next.upper
            if core>=0 {pu,nu=prev.cores[core].upper,next.cores[core].upper}
            pu+=(nu-pu)*clipped
            lower0:=raw_prev+(raw_next-raw_prev)*clipped
            top0,top1:=y+h*(1-clamp(pu/ceiling,0,1)),y+h*(1-clamp(nu/ceiling,0,1))
            bottom0,bottom1:=y+h*(1-clamp(lower0/ceiling,0,1)),y+h*(1-clamp(raw_next/ceiling,0,1))
            // Vertical clipping keeps scrolling inside the same GPU draw.
            if a.clip_active {
                top0,top1=clamp(top0,a.clip_top,a.clip_bottom),clamp(top1,a.clip_top,a.clip_bottom)
                bottom0,bottom1=clamp(bottom0,a.clip_top,a.clip_bottom),clamp(bottom1,a.clip_top,a.clip_bottom)
            }
            pt,nt:=utilization_color(lower0),utilization_color(raw_next);pt[3],nt[3]=0.16,0.16
            points:=[6][2]f32{{x0,top0},{x1,top1},{x1,bottom1},{x0,top0},{x1,bottom1},{x0,bottom0}}
            colors:=[6]Color{pt,nt,nt,pt,nt,pt}
            for p,j in points {append(&a.vertices,Vertex{pos={p[0]*a.scale,p[1]*a.scale},color=colors[j]})}
        }
        if render_pass==.Fill {continue}
        if dashed {
            length:=x1-x0
            for dx:=f32(0);dx<length;dx+=7 {
                end:=min(dx+4,length)
                stroke_gradient(a,x0+dx,y0+(y1-y0)*dx/length,x0+end,y0+(y1-y0)*end/length,1.2,color_mix(pc,nc,dx/length),color_mix(pc,nc,end/length))
            }
        } else {stroke_gradient(a,x0,y0,x1,y1,1.6,pc,nc)}
    }
}

cpu_grid :: proc(a:^App,x,y,w,h,ceiling:f32,kind:CPU_Plot) {
    for i in 0..<3 {
        value:=ceiling*f32(2-i)/2
        yy:=y+h*f32(i)/2
        rect(a,x,yy,w,1,LINE)
        label:=fmt.tprintf("%.0f",value)
        if kind==.Frequency {label=fmt.tprintf("%.1f",value/1000)}
        right_text(a,label,x-8,yy+4,12,MUTED)
    }
}

cpu_dashboard :: proc(a:^App) {
    m:=&a.metrics
    x,w:=a.content_x,a.width-a.content_x-16
    if w<160 {return}
    compact:=w<700
    stats_rows:=2 if compact else 1
    stats_cols:=2 if compact else 4
    stats_h:=f32(stats_rows)*66
    graph_y:=f32(72)+65+stats_h
    cols:=1 if w<460 else (2 if compact else 4)
    rows:=(m.physical_core_count+cols-1)/cols
    siblings:=2
    for core in m.physical_cores[:m.physical_core_count] {siblings=max(siblings,core.logical_count)}
    viewport_top,viewport_bottom:=f32(72),a.height-28
    plot_gap:=f32(50)
    plot_header_h,time_axis_h,core_heading_gap:=f32(36),f32(22),f32(34)
    busy_h,small_h:=f32(82),f32(38)
    controls_h:=graph_controls_height(w-36)+8
    cell_h:=f32(158+(siblings-2)*21)
    graph_h:=plot_header_h+busy_h+small_h*2+plot_gap*2+time_axis_h+controls_h
    // Share spare height between the histories and core rows; keep scrolling
    // for smaller windows and machines with more cores instead of squeezing.
    spare:=max(0,viewport_bottom-(graph_y+graph_h+core_heading_gap+22+f32(rows)*cell_h))
    busy_h+=spare*0.25
    small_h+=spare*0.125
    if rows>0 {cell_h+=spare*0.5/f32(rows)}
    graph_h=plot_header_h+busy_h+small_h*2+plot_gap*2+time_axis_h+controls_h
    core_heading_y:=graph_y+graph_h+core_heading_gap
    core_y:=core_heading_y+22
    content_bottom:=core_y+f32(rows)*cell_h
    max_scroll:=max(0,content_bottom-viewport_bottom)
    a.cpu_scroll=clamp(a.cpu_scroll,0,max_scroll)
    offset:=a.cpu_scroll
    // Reuse the existing input region, with CPU-specific scrolling in its callback.
    a.table_x,a.table_y,a.table_w,a.table_h=x,viewport_top,w,max(0,viewport_bottom-viewport_top)
    a.clip_active=true;a.clip_top,a.clip_bottom=viewport_top,viewport_bottom
    defer a.clip_active=false
    fit_text(a,m.cpu_model,x,99-offset,w,17)
    fit_text(a,fmt.tprintf("%d physical cores / %d online threads",m.physical_core_count,m.cpu_online_count) if m.cpu_topology_available else "Topology unavailable - logical CPU fallback",x,121-offset,w,12,MUTED)

    first:=(a.history_next-a.history_count+HISTORY_CAPACITY)%HISTORY_CAPACITY
    hover_slot:=-1
    gx,gy,gw:=x+36,graph_y+plot_header_h-offset,w-36
    a.cpu_graph_x,a.cpu_graph_y,a.cpu_graph_w,a.cpu_graph_h=gx,gy,gw,busy_h+small_h*2+plot_gap*2
    in_plot:=a.mouse_x>=gx&&a.mouse_x<=gx+gw&&a.mouse_y>=gy&&a.mouse_y<=gy+a.cpu_graph_h&&a.mouse_y>=viewport_top&&a.mouse_y<=viewport_bottom
    hover_graph:=0
    if a.mouse_y>=gy+busy_h+plot_gap {hover_graph=1}
    if a.mouse_y>=gy+busy_h+small_h+plot_gap*2 {hover_graph=2}
    if in_plot&&a.history_count>0 {
        position:=clamp((a.mouse_x-gx)/gw,0,1)
        // The empty portion of a filling graph has no sample to inspect.
        if position>=history_position(a,first) {
            distance:=f32(2)
            for i in 0..<a.history_count {
                candidate:=(first+i)%HISTORY_CAPACITY
                sample_position:=history_position(a,candidate)
                if sample_position<0||a.cpu_history[candidate].generation!=m.cpu_topology_generation {continue}
                delta:=abs(sample_position-position)
                if delta<distance {distance=delta;hover_slot=candidate}
            }
        }
    }
    if a.click&&in_plot {
        if a.cpu_pinned_slot>=0 {a.cpu_pinned_slot=-1}
        else {a.cpu_pinned_slot=hover_slot;a.cpu_pinned_graph=hover_graph}
    }
    slot:=a.cpu_pinned_slot if a.cpu_pinned_slot>=0 else hover_slot
    if slot>=0&&(a.cpu_history[slot].generation!=m.cpu_topology_generation||history_position(a,slot)<0) {slot=-1;a.cpu_pinned_slot=-1}
    if slot<0&&a.history_count>0 {slot=(a.history_next+HISTORY_CAPACITY-1)%HISTORY_CAPACITY}
    s:^CPU_Sample
    if slot>=0&&a.cpu_history[slot].generation==m.cpu_topology_generation {s=&a.cpu_history[slot]}
    if s!=nil {s=graph_readout_sample(a,s,hover_slot>=0||a.cpu_pinned_slot>=0,hover_slot>=0&&a.cpu_pinned_slot<0,gw)}
    ready:=s!=nil&&m.cpu_available
    labels:=[4]string{"Physical cores busy","Logical threads busy","CPU package power","Active mean frequency"}
    if !m.cpu_topology_available {labels[0]="CPU busy"}
    if m.cpu_frequency_source==.Driver||m.cpu_frequency_source==.Mixed {labels[3]="Active frequency (reported)"}
    if ready&&s.lower==0 {labels[3]="Core mean frequency (idle)"}
    gap:=f32(20)
    cell_w:=(w-gap*f32(cols-1))/f32(cols)
    stats_w:=(w-gap*f32(stats_cols-1))/f32(stats_cols)
    for label,i in labels {
        sx:=x+f32(i%stats_cols)*(stats_w+gap)
        sy:=f32(147)+f32(i/stats_cols)*66-offset
        fit_text(a,label,sx,sy,stats_w,12,MUTED)
        value:="--"
        if ready {
            switch i {
            case 0:value=cpu_range_label(s.lower,s.upper)
            case 1:value=fmt.tprintf("%.0f%%",s.threads)
            case 2:if s.power_available {value=fmt.tprintf("%.0f W",s.power_watts)}
            case 3:if s.frequency_available {value=fmt.tprintf("%.2f GHz",s.frequency_mhz/1000)}
            }
        }
        value_color:=TEXT
        if ready&&i<2 {value_color=utilization_color(s.lower if i==0 else s.threads)}
        fit_text(a,value,sx,sy+34,stats_w,27 if w>850||compact else 22,value_color)
    }
    // Aligned histories sit directly on the background, each with its own scale.
    fit_text(a,"BUSY TIME %",x,gy-18,w,12,MUTED)
    if w>450 {right_text(a,"Physical cores",x+w,gy-18,12,MUTED)}
    cpu_grid(a,gx,gy,gw,busy_h,100,.Busy)
    cpu_plot(a,.Busy,-1,gx,gy,gw,busy_h,100,PURPLE,band=true)
    power_max,freq_max:=f32(50),f32(6000)
    for _,i in 0..<a.history_count {
        hist:=&a.cpu_history[(first+i)%HISTORY_CAPACITY]
        if hist.generation!=m.cpu_topology_generation||history_position(a,(first+i)%HISTORY_CAPACITY)<0 {continue}
        if hist.power_available {power_max=max(power_max,f32(math.ceil(hist.power_watts/50))*50)}
        if hist.frequency_available {freq_max=max(freq_max,f32(math.ceil(hist.frequency_mhz/1000))*1000)}
    }
    power_y:=gy+busy_h+plot_gap
    power_max=graph_animation_ceiling(a,power_max,.CPU_Power)
    freq_max=graph_animation_ceiling(a,freq_max,.CPU_Frequency)
    text(a,"PACKAGE POWER W",x,power_y-18,12,MUTED)
    if !m.cpu_power_available {
        status := metrics_cpu_power_status(m)
        if m.cpu_power_permission_denied {
            status = "Permission denied - install task_master on this host"
        }
        fit_text(a,status,x+155,power_y-18,w-155,12,MUTED)
        if a.mouse_y>=power_y && a.mouse_y<=power_y+small_h && m.cpu_power_permission_denied {
            command := "make install" if a.active_machine==0 else fmt.tprintf("make install-remote HOST=%s",string(a.machines[a.active_machine].host[:a.machines[a.active_machine].host_len]))
            if m.platform=="windows" {command="Install the task_master CPU sensor service on this host (scripts/install-sensors.ps1)."}
            fit_text(a,command,gx+8,power_y+small_h/2,gw-16,12,SOFT)
        }
    }
    cpu_grid(a,gx,power_y,gw,small_h,power_max,.Power)
    cpu_plot(a,.Power,-1,gx,power_y,gw,small_h,power_max,AMBER)
    freq_y:=power_y+small_h+plot_gap
    text(a,"ACTIVE FREQUENCY GHz",x,freq_y-18,12,MUTED)
    if !m.cpu_frequency_available {right_text(a,"Unavailable",x+w,freq_y-18,12,MUTED)}
    cpu_grid(a,gx,freq_y,gw,small_h,freq_max,.Frequency)
    cpu_plot(a,.Frequency,-1,gx,freq_y,gw,small_h,freq_max,CYAN)
    text(a,graph_time_axis_label(a),gx,freq_y+small_h+time_axis_h,12,MUTED)
    right_text(a,history_end_label(a),gx+gw,freq_y+small_h+time_axis_h,12,MUTED)
    graph_controls_draw(a,gx,freq_y+small_h+time_axis_h+8,gw)
    if a.history_count>0 {
        if (hover_slot>=0||a.cpu_pinned_slot>=0)&&s!=nil {
            cursor_x:=gx+gw*history_position(a,slot)
            if a.cpu_pinned_slot<0 {cursor_x=clamp(a.mouse_x,gx,gx+gw)}
            stroke(a,cursor_x,gy,cursor_x,freq_y+small_h,1,MUTED)
            graph_ys:=[3]f32{gy,power_y,freq_y}
            graph_hs:=[3]f32{busy_h,small_h,small_h}
            label_graph:=clamp(a.cpu_pinned_graph if a.cpu_pinned_slot>=0 else hover_graph,0,2)
            history_time_label(a,slot,a.cpu_pinned_slot>=0,cursor_x,gx,graph_ys[label_graph],gw,graph_hs[label_graph])
        }
    }
    fit_text(a,"PHYSICAL CORES / SIBLING THREADS",x,core_heading_y-offset,w,12,SOFT)
    if !m.cpu_topology_available {fit_text(a,"LOGICAL CPU FALLBACK",x,core_heading_y-offset,w,12,SOFT)}
    for col in 1..<cols {
        divider_x:=x+f32(col)*(cell_w+gap)-gap/2
        rect(a,divider_x,core_y-offset,1,f32(rows)*cell_h-24,LINE)
    }
    for core,i in m.physical_cores[:m.physical_core_count] {
        cx,cy,cw,ch:=x+f32(i%cols)*(cell_w+gap),core_y+f32(i/cols)*cell_h-offset,cell_w,cell_h-24
        if cy+ch<viewport_top||cy>viewport_bottom {continue}
        current:=CPU_Core_Sample{lower=core.busy_lower,upper=core.busy_upper,frequency_mhz=core.frequency_mhz,frequency_available=core.frequency_available}
        if s!=nil {current=s.cores[i]}
        busy_color:=utilization_color(current.lower) if ready else TEXT
        logical:=m.cores
        if s!=nil {logical=s.logical}
        freq:=fmt.tprintf("%.2f GHz",current.frequency_mhz/1000) if current.frequency_available else "-- GHz"
        text(a,fmt.tprintf("Core %d",i),cx,cy+17,12,TEXT)
        right_text(a,freq,cx+cw,cy+17,12,MUTED)
        text(a,cpu_range_label(current.lower,current.upper) if ready else "--",cx,cy+47,22,busy_color)
        // Spend additional row height on the plot, keeping the sibling bars
        // and the divider's bottom together instead of growing empty space.
        core_plot_h:=cell_h-f32(89+siblings*21)
        cpu_plot(a,.Busy,i,cx,cy+64,cw,core_plot_h,100,PURPLE,band=true)
        for j in 0..<core.logical_count {
            id:=core.logical_ids[j]
            yy:=cy+64+core_plot_h+22+f32(j)*21
            text(a,fmt.tprintf("CPU %d",id),cx,yy,12,MUTED)
            tint:=utilization_color(logical[id])
            bar(a,cx+65,yy-7,max(1,cw-108),4,logical[id],tint)
            right_text(a,fmt.tprintf("%.0f%%",logical[id]),cx+cw,yy,12,tint)
        }
    }
    if max_scroll>0 {
        track_h:=viewport_bottom-viewport_top
        thumb_h:=max(24,track_h*track_h/(content_bottom-viewport_top))
        thumb_y:=viewport_top+(track_h-thumb_h)*a.cpu_scroll/max_scroll
        rect(a,x+w+9,thumb_y,2,thumb_h,MUTED)
    }
}

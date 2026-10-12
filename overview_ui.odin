package main

import "core:fmt"
import "core:math"

// Use the CPU view's monotone curves and GPU line rendering, retaining
// logical-thread utilization for the Overview CPU summary.
overview_plot :: proc(a:^App,kind:int,x,y,w,h:f32,render_pass:Graph_Pass=.All) {
    if render_pass==.All {
        for pass in ([2]Graph_Pass{.Fill,.Line}) {
            for incoming in ([2]bool{false,true}) {
                animation,draw:=graph_animation_begin(a,incoming,x,w)
                if draw {overview_plot(a,kind,x,y,w,h,pass)}
                graph_animation_end(a,animation)
            }
        }
        return
    }
    smoothed:=graph_smoothing_prepare(a)
    values:=&smoothed.history
    if smoothed.identity {values=&a.history}
    first:=(a.history_next-a.history_count+HISTORY_CAPACITY)%HISTORY_CAPACITY
    for i in 1..<a.history_count {
        prev,next:=(first+i-1)%HISTORY_CAPACITY,(first+i)%HISTORY_CAPACITY
        p0,p1:=history_position(a,prev),history_position(a,next)
        dt:=f32(a.cpu_history[next].timestamp-a.cpu_history[prev].timestamp)
        if p1<=0||p1<=p0||!history_segment_contiguous(&a.cpu_history[prev],&a.cpu_history[next]) {continue}
        v0,v1:=values[kind][prev],values[kind][next]
        slope:=(v1-v0)/dt
        m0,m1:=slope,slope
        if i>1 {
            before:=(first+i-2)%HISTORY_CAPACITY
            before_dt:=f32(a.cpu_history[prev].timestamp-a.cpu_history[before].timestamp)
            if history_segment_contiguous(&a.cpu_history[before],&a.cpu_history[prev]) {
                m0=cpu_curve_slope((v0-values[kind][before])/before_dt,slope,before_dt,dt)
            }
        }
        if i+1<a.history_count {
            after:=(first+i+1)%HISTORY_CAPACITY
            after_dt:=f32(a.cpu_history[after].timestamp-a.cpu_history[next].timestamp)
            if history_segment_contiguous(&a.cpu_history[next],&a.cpu_history[after]) {
                m1=cpu_curve_slope(slope,(values[kind][after]-v1)/after_dt,dt,after_dt)
            }
        }
        curve:=[4]f32{v0,v1,m0*dt,m1*dt}
        start:=max(0,-p0/(p1-p0))
        extent:=max(w*(p1-p0)*(1-start),h*abs(v1-v0)/100)
        steps:=clamp(int(math.ceil(extent*a.scale/3)),4,128)
        value:=cpu_curve_value(curve,start)
        px,py:=x+w*(p0+(p1-p0)*start),y+h*(1-clamp(value/100,0,1))
        color:=utilization_color(value)
        for j in 1..=steps {
            t:=start+(1-start)*f32(j)/f32(steps)
            value=cpu_curve_value(curve,t)
            nx,ny:=x+w*(p0+(p1-p0)*t),y+h*(1-clamp(value/100,0,1))
            next_color:=utilization_color(value)
            if render_pass==.Fill {graph_fill_segment(a,px,py,nx,ny,y+h,color,next_color,h,true)}
            else {stroke_gradient(a,px,py,nx,ny,1.6,color,next_color)}
            px,py,color=nx,ny,next_color
        }
    }
}

overview_summary :: proc(a:^App,kind:int,label,detail:string,value:f32,available:bool,x,y,w,h:f32) {
    current_value,current_available,current_detail:=value,available,detail
    gx,gy,gw,gh:=x+36,y+122,w-36,h-148
    in_plot:=a.mouse_x>=gx&&a.mouse_x<=gx+gw&&a.mouse_y>=gy&&a.mouse_y<=gy+gh&&a.mouse_y>=a.clip_top&&a.mouse_y<=a.clip_bottom
    hover_slot:=process_history_nearest(a,clamp((a.mouse_x-gx)/gw,0,1)) if in_plot else -1
    if a.cpu_pinned_slot>=0&&history_position(a,a.cpu_pinned_slot)<0 {a.cpu_pinned_slot=-1}
    slot:=a.cpu_pinned_slot if a.cpu_pinned_slot>=0 else hover_slot
    if slot>=0 {
        sample:=&a.cpu_history[slot]
        switch kind {
        case 0: current_value=sample.threads;current_available=sample.processes.cpu_available if sample.processes.recorded else available
        case 1: current_value=sample.gpu.utilization;current_available=sample.gpu.utilization_available
        case 2: current_value=memory_pct(sample.memory_used,sample.memory_total);current_available=sample.ram_available
            current_detail=fmt.tprintf("%s used / %s",bytes_label(sample.memory_used),bytes_label(sample.memory_total))
        }
    }
    fit_text(a,label,x,y+27,w,12,MUTED)
    tint:=utilization_color(current_value) if current_available else TEXT
    fit_text(a,fmt.tprintf("%.1f%%",current_value) if current_available else "--",x,y+61,w,27,tint)
    fit_text(a,current_detail,x,y+86,w,12,MUTED)
    cpu_grid(a,gx,gy,gw,gh,100,.Busy,label_x=x)
    if available {overview_plot(a,kind,gx,gy,gw,gh)}
    text(a,graph_time_axis_label(a),x,gy+gh+22,12,MUTED)
    right_text(a,history_end_label(a),gx+gw,gy+gh+22,12,MUTED)
    if slot>=0 {
        cursor_x:=gx+gw*history_position(a,slot)
        stroke(a,cursor_x,gy,cursor_x,gy+gh,1,MUTED)
        if (a.cpu_pinned_slot>=0&&a.cpu_pinned_graph==kind)||hover_slot>=0 {
            history_time_label(a,slot,a.cpu_pinned_slot>=0,cursor_x,gx,gy,gw,gh)
        }
    }
}

overview_graphics :: proc(a:^App,x,y,w:f32) {
    text(a,"GRAPHICS",x,y+20,12,SOFT)
    if a.metrics.gpu_count==0 {
        fit_text(a,"No GPU telemetry available",x,y+52,w,17)
        fit_text(a,"CPU and memory remain live.",x,y+78,w,12,MUTED)
        return
    }
    g:=&a.metrics.gpus[0]
    fit_text(a,string(g.name[:g.name_len]),x,y+48,w,17)
    pct:=memory_pct(g.memory_used,g.memory_total)
    tint:=utilization_color(pct) if g.memory_available else TEXT
    text(a,"Shared allocations" if g.unified_memory else "Dedicated memory",x,y+74,12,MUTED)
    right_text(a,fmt.tprintf("%s / %s",bytes_label(g.memory_used),bytes_label(g.memory_total)) if g.memory_available else "Unavailable",x+w,y+74,12,tint)
    bar(a,x,y+86,w,4,pct,tint)
    labels:=[3]string{"Temperature","Power","Fan"}
    values:=[3]string{fmt.tprintf("%.0f C",g.temperature) if g.temperature_available else "--",fmt.tprintf("%.0f W",g.power_watts) if g.power_available else "--",fmt.tprintf("%.0f%%",g.fan_percent) if g.fan_available else "--"}
    cell:=(w-40)/3
    for label,i in labels {
        cx:=x+f32(i)*(cell+20)
        fit_text(a,label,cx,y+119,cell,12,MUTED)
        fit_text(a,values[i],cx,y+151,cell,22,TEXT)
    }
}

overview_io :: proc(a:^App,x,y,w:f32) {
    text(a,"NETWORK & STORAGE",x,y+20,12,SOFT)
    labels:=[4]string{"Network receive","Network send","Disk read","Disk write"}
    if w<280 {labels={"Receive","Send","Read","Write"}}
    values:=[4]f64{a.metrics.network_rx,a.metrics.network_tx,a.metrics.disk_read,a.metrics.disk_write}
    for label,i in labels {
        yy:=y+52+f32(i)*27
        fit_text(a,label,x,yy,max(0,w-115),12,MUTED)
        right_text(a,rate_label(values[i]),x+w,yy,14,TEXT)
    }
}

overview :: proc(a:^App) {
    x,w:=a.content_x,a.width-2*a.content_x
    if w<160 {return}
    compact:=w<700
    cols:=1 if compact else 3
    gap:=f32(20)
    summary_h:=f32(228)
    details_h:=f32(342) if compact else f32(164)
    controls_h:=graph_controls_height(w-36)+8
    viewport_top,viewport_bottom:=f32(72),a.height-a.content_x
    rows:=f32(3/cols)
    details_gap,process_gap:=f32(28),f32(20)
    viewport_h:=viewport_bottom-viewport_top
    // Tighten section gaps first, then shorten the histories to a readable
    // 56-pixel plot. Keep room for the process headings and three rows before
    // falling back to whole-page scrolling on genuinely small windows.
    minimum_h:=rows*summary_h+controls_h+details_gap+details_h+process_gap+180
    shortfall:=max(0,minimum_h-viewport_h)
    gap_reduction:=min(shortfall,24)
    details_gap-=gap_reduction/2
    process_gap-=gap_reduction/2
    summary_h-=min(24,(shortfall-gap_reduction)/rows)
    minimum_h=rows*summary_h+controls_h+details_gap+details_h+process_gap+180
    spare:=max(0,viewport_h-minimum_h)
    summary_h+=spare*0.25/rows
    process_y:=viewport_top+rows*summary_h+controls_h+details_gap+details_h+process_gap
    process_h:=max(180,viewport_bottom-process_y)
    content_bottom:=process_y+process_h
    max_scroll:=max(0,content_bottom-viewport_bottom)
    a.overview_scroll=clamp(a.overview_scroll,0,max_scroll)
    offset:=a.overview_scroll
    a.clip_active=true;a.clip_top,a.clip_bottom=viewport_top,viewport_bottom
    defer a.clip_active=false
    cw:=(w-gap*f32(cols-1))/f32(cols)
    m:=&a.metrics
    g:=&m.gpus[0]
    labels:=[3]string{"CPU utilization","GPU utilization","Physical memory"}
    details:=[3]string{fmt.tprintf("%d threads / %s %.2f",m.cpu_count,"queue average" if m.platform=="windows" else "load",m.load[0]),string(g.name[:g.name_len]) if m.gpu_count>0 else "GPU device unavailable",fmt.tprintf("%s used / %s",bytes_label(m.memory_used),bytes_label(m.memory_total))}
    values:=[3]f32{m.cpu_percent,g.utilization,memory_pct(m.memory_used,m.memory_total)}
    available:=[3]bool{m.cpu_available&&a.history_count>0,m.gpu_count>0&&g.utilization_available,m.ram_available}
    a.cpu_graph_x,a.cpu_graph_y,a.cpu_graph_w,a.cpu_graph_h=x,viewport_top-offset,w,rows*summary_h
    // Resolve a click before drawing summaries so every panel and attribution
    // table uses the same pinned timestamp in this frame.
    if a.click {
        for kind in 0..<3 {
            sx,sy:=x+f32(kind%cols)*(cw+gap),viewport_top+f32(kind/cols)*summary_h-offset
            gx,gy,gw,gh:=sx+36,sy+122,cw-36,summary_h-148
            in_plot:=a.mouse_x>=gx&&a.mouse_x<=gx+gw&&a.mouse_y>=gy&&a.mouse_y<=gy+gh&&a.mouse_y>=viewport_top&&a.mouse_y<=viewport_bottom
            if in_plot {
                if a.cpu_pinned_slot>=0 {a.cpu_pinned_slot=-1}
                else {a.cpu_pinned_slot=process_history_nearest(a,clamp((a.mouse_x-gx)/gw,0,1));a.cpu_pinned_graph=kind}
                a.click=false
                break
            }
        }
    }
    for label,i in labels {
        cx,cy:=x+f32(i%cols)*(cw+gap),viewport_top+f32(i/cols)*summary_h-offset
        overview_summary(a,i,label,details[i],values[i],available[i],cx,cy,cw,summary_h)
        if !compact&&i>0 {rect(a,cx-gap/2,viewport_top-offset,1,summary_h-4,LINE)}
    }
    graph_controls_draw(a,x+36,viewport_top+rows*summary_h+8-offset,w-36)
    details_y:=viewport_top+rows*summary_h+controls_h+details_gap-offset
    lw:=w if compact else (w-gap)*0.60
    overview_graphics(a,x,details_y,lw)
    if compact {overview_io(a,x,details_y+178,w)}
    else {
        rect(a,x+lw+gap/2,details_y,1,details_h,LINE)
        overview_io(a,x+lw+gap,details_y,w-lw-gap)
    }
    process_panel(a,x-18,process_y-offset,w+36,process_h,gpu=a.cpu_pinned_slot>=0&&a.cpu_pinned_graph==1,unboxed=true)
    if max_scroll>0 {
        track_h:=viewport_bottom-viewport_top
        thumb_h:=max(24,track_h*track_h/(content_bottom-viewport_top))
        thumb_y:=viewport_top+(track_h-thumb_h)*a.overview_scroll/max_scroll
        rect(a,x+w+9,thumb_y,2,thumb_h,MUTED)
    }
}

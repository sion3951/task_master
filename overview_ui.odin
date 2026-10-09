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
    first:=(a.history_next-a.history_count+HISTORY_CAPACITY)%HISTORY_CAPACITY
    for i in 1..<a.history_count {
        prev,next:=(first+i-1)%HISTORY_CAPACITY,(first+i)%HISTORY_CAPACITY
        p0,p1:=history_position(a,prev),history_position(a,next)
        dt:=f32(a.cpu_history[next].timestamp-a.cpu_history[prev].timestamp)
        if p1<=0||p1<=p0||!history_segment_contiguous(&a.cpu_history[prev],&a.cpu_history[next]) {continue}
        v0,v1:=smoothed.history[kind][prev],smoothed.history[kind][next]
        slope:=(v1-v0)/dt
        m0,m1:=slope,slope
        if i>1 {
            before:=(first+i-2)%HISTORY_CAPACITY
            before_dt:=f32(a.cpu_history[prev].timestamp-a.cpu_history[before].timestamp)
            if history_segment_contiguous(&a.cpu_history[before],&a.cpu_history[prev]) {
                m0=cpu_curve_slope((v0-smoothed.history[kind][before])/before_dt,slope,before_dt,dt)
            }
        }
        if i+1<a.history_count {
            after:=(first+i+1)%HISTORY_CAPACITY
            after_dt:=f32(a.cpu_history[after].timestamp-a.cpu_history[next].timestamp)
            if history_segment_contiguous(&a.cpu_history[next],&a.cpu_history[after]) {
                m1=cpu_curve_slope(slope,(smoothed.history[kind][after]-v1)/after_dt,dt,after_dt)
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
    fit_text(a,label,x,y+27,w,12,MUTED)
    tint:=utilization_color(value) if available else TEXT
    fit_text(a,fmt.tprintf("%.1f%%",value) if available else "--",x,y+61,w,27,tint)
    fit_text(a,detail,x,y+86,w,12,MUTED)
    gx,gy,gw,gh:=x+36,y+122,w-36,h-148
    cpu_grid(a,gx,gy,gw,gh,100,.Busy)
    if available {overview_plot(a,kind,gx,gy,gw,gh)}
    text(a,graph_time_axis_label(a),gx,gy+gh+22,12,MUTED)
    right_text(a,history_end_label(a),gx+gw,gy+gh+22,12,MUTED)
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
    x,w:=a.content_x,a.width-a.content_x-16
    if w<160 {return}
    compact:=w<700
    cols:=1 if compact else 3
    gap:=f32(20)
    summary_h:=f32(228)
    details_h:=f32(342) if compact else f32(164)
    controls_h:=graph_controls_height(w-36)+8
    viewport_top,viewport_bottom:=f32(72),a.height-28
    // Share spare height with the histories and process list; stack and scroll
    // on small windows so every section stays reachable.
    minimum_h:=f32(3/cols)*summary_h+controls_h+28+details_h+20+180
    spare:=max(0,viewport_bottom-viewport_top-minimum_h)
    summary_h+=spare*0.25
    process_y:=viewport_top+f32(3/cols)*summary_h+controls_h+28+details_h+20
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
    details:=[3]string{fmt.tprintf("%d threads / %s %.2f",m.cpu_count,"queue average" if m.platform=="windows" else "load",m.load[0]),string(g.name[:g.name_len]) if m.gpu_count>0 else "NVIDIA device unavailable",fmt.tprintf("%s used / %s",bytes_label(m.memory_used),bytes_label(m.memory_total))}
    values:=[3]f32{m.cpu_percent,g.utilization,memory_pct(m.memory_used,m.memory_total)}
    available:=[3]bool{m.cpu_available&&a.history_count>0,m.gpu_count>0&&g.utilization_available,m.ram_available}
    for label,i in labels {
        cx,cy:=x+f32(i%cols)*(cw+gap),viewport_top+f32(i/cols)*summary_h-offset
        overview_summary(a,i,label,details[i],values[i],available[i],cx,cy,cw,summary_h)
        if !compact&&i>0 {rect(a,cx-gap/2,viewport_top-offset,1,summary_h-8,LINE)}
    }
    graph_controls_draw(a,x+36,viewport_top+f32(3/cols)*summary_h+8-offset,w-36)
    details_y:=viewport_top+f32(3/cols)*summary_h+controls_h+28-offset
    lw:=w if compact else (w-gap)*0.60
    overview_graphics(a,x,details_y,lw)
    if compact {overview_io(a,x,details_y+178,w)}
    else {
        rect(a,x+lw+gap/2,details_y,1,details_h,LINE)
        overview_io(a,x+lw+gap,details_y,w-lw-gap)
    }
    process_panel(a,x-18,process_y-offset,w+36,process_h,unboxed=true)
    if max_scroll>0 {
        track_h:=viewport_bottom-viewport_top
        thumb_h:=max(24,track_h*track_h/(content_bottom-viewport_top))
        thumb_y:=viewport_top+(track_h-thumb_h)*a.overview_scroll/max_scroll
        rect(a,x+w+9,thumb_y,2,thumb_h,MUTED)
    }
}

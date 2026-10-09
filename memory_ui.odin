package main

import "core:fmt"
import "core:math"

memory_capacity_ceiling :: proc(total:u64)->f32 {
    capacity:=f64(total)/1073741824
    ceiling:=f64(4)
    for capacity>ceiling {
        if ceiling>=8&&capacity<=ceiling*1.5 {return f32(ceiling*1.5)}
        ceiling*=2
    }
    return f32(ceiling)
}

memory_gb_grid :: proc(a:^App,x,y,w,h,ceiling,label_x:f32) {
    for i in 0..<3 {
        value:=ceiling*f32(2-i)/2
        yy:=y+h*f32(i)/2
        rect(a,x,yy,w,1,LINE)
        label:=fmt.tprintf("%.0f",value) if value==math.floor(value) else fmt.tprintf("%.1f",value)
        text(a,label,label_x,yy+4,12,MUTED)
    }
}

memory_rate_grid :: proc(a:^App,x,y,w,h,ceiling,label_x:f32) {
    unit:=f32(1048576) if ceiling>=1048576 else f32(1024)
    for i in 0..<3 {
        yy:=y+h*f32(i)/2
        value:=ceiling*f32(2-i)/2/unit
        rect(a,x,yy,w,1,LINE)
        text(a,fmt.tprintf("%.0f",value) if value==0||value>=1 else fmt.tprintf("%.1f",value),label_x,yy+4,12,MUTED)
    }
}

memory_dashboard :: proc(a:^App) {
    m:=&a.metrics
    x,w:=a.content_x,a.width-2*a.content_x
    if w<160 {return}
    show_swap:=m.swap_total>0
    compact:=w<700
    stats_rows:=3 if compact else 1
    stats_h:=f32(96)
    stats_y:=f32(99)
    graph_y:=stats_y+26+f32(stats_rows)*stats_h
    viewport_top,viewport_bottom:=f32(72),a.height-a.content_x
    plot_gap,time_axis_h:=f32(50),f32(22)
    legend_cols:=5 if w>=700 else (2 if w>=350 else 1)
    legend_rows:=(5+legend_cols-1)/legend_cols
    ram_gap:=plot_gap+f32(legend_rows-1)*18
    heights:=[4]f32{82,38,50,50}
    if !show_swap {heights[1]=0}
    graph_gaps:=ram_gap+plot_gap*f32(2 if show_swap else 1)
    controls_h:=graph_controls_height(w-48)+8
    content_bottom:=graph_y+heights[0]+heights[1]+heights[2]+heights[3]+graph_gaps+time_axis_h+controls_h
    spare:=max(0,viewport_bottom-content_bottom)
    for &height,i in heights {
        if i==1&&!show_swap {continue}
        height+=spare*(0.4 if i==0 else 0.2)/(1 if show_swap else 0.8)
    }
    content_bottom+=spare
    max_scroll:=max(0,content_bottom-viewport_bottom)
    a.memory_scroll=clamp(a.memory_scroll,0,max_scroll)
    offset:=a.memory_scroll
    a.table_x,a.table_y,a.table_w,a.table_h=x,viewport_top,w,max(0,viewport_bottom-viewport_top)
    a.clip_active=true;a.clip_top,a.clip_bottom=viewport_top,viewport_bottom
    defer a.clip_active=false
    first:=(a.history_next-a.history_count+HISTORY_CAPACITY)%HISTORY_CAPACITY
    gx,gy,gw:=x+48,graph_y-offset,w-48
    graph_h:=heights[0]+heights[1]+heights[2]+heights[3]+graph_gaps
    io_y:=gy+heights[0]+ram_gap
    if show_swap {io_y+=heights[1]+plot_gap}
    column_gap:=f32(24)
    column_w:=(w-column_gap)/2
    io_w:=column_w-48
    network_gx:=x+column_w+column_gap+48
    // Use the same input bounds as the CPU history, with a separate machine pin.
    a.cpu_graph_x,a.cpu_graph_y,a.cpu_graph_w,a.cpu_graph_h=gx,gy,gw,graph_h
    hover_x,hover_w:=gx,gw
    if a.mouse_y>=io_y {
        hover_w=io_w
        if a.mouse_x>=network_gx {hover_x=network_gx}
    }
    in_plot:=a.mouse_x>=hover_x&&a.mouse_x<=hover_x+hover_w&&a.mouse_y>=gy&&a.mouse_y<=gy+graph_h&&a.mouse_y>=viewport_top&&a.mouse_y<=viewport_bottom
    hover_slot:=-1
    position:=clamp((a.mouse_x-hover_x)/hover_w,0,1)
    swap_y:=gy+heights[0]+ram_gap
    write_y:=io_y+heights[2]+plot_gap
    hover_graph:=0
    if show_swap&&a.mouse_y>=swap_y {hover_graph=1}
    if a.mouse_y>=io_y {
        hover_graph=3 if a.mouse_y>=write_y else 2
        if a.mouse_x>=network_gx {hover_graph+=2}
    }
    if in_plot&&a.history_count>0 {
        if position>=history_position(a,first) {
            distance:=f32(2)
            for i in 0..<a.history_count {
                candidate:=(first+i)%HISTORY_CAPACITY
                sample_position:=history_position(a,candidate)
                sample:=&a.cpu_history[candidate]
                if sample_position<0||(!sample.ram_available&&!sample.rates_ready&&!sample.network_rates_ready) {continue}
                delta:=abs(sample_position-position)
                if delta<distance {distance=delta;hover_slot=candidate}
            }
        }
    }
    if !show_swap&&a.memory_pinned_graph==1 {a.memory_pinned_graph=0}
    if a.click&&in_plot {
        if a.memory_pinned_slot>=0 {a.memory_pinned_slot=-1}
        else {a.memory_pinned_slot=hover_slot;a.memory_pinned_graph=hover_graph}
    }
    slot:=a.memory_pinned_slot if a.memory_pinned_slot>=0 else hover_slot
    if slot>=0&&history_position(a,slot)<0 {slot=-1;a.memory_pinned_slot=-1}
    if slot<0&&a.history_count>0 {slot=(a.history_next+HISTORY_CAPACITY-1)%HISTORY_CAPACITY}
    s:^CPU_Sample
    if slot>=0 {s=&a.cpu_history[slot]}
    if s!=nil {s=graph_readout_sample(a,s,hover_slot>=0||a.memory_pinned_slot>=0,hover_slot>=0&&a.memory_pinned_slot<0,hover_w)}
    show_swap_stat:=show_swap&&(s==nil||s.swap_total>0)
    stats_count:=6 if show_swap_stat else 5
    stats_cols:=2 if compact else stats_count
    labels:=[6]string{"RAM used","Swap used","Disk read","Disk write","Network receive","Network transmit"}
    if m.platform=="windows" {labels[1]="Pagefile used"}
    gap:=f32(20)
    stats_w:=(w-gap*f32(stats_cols-1))/f32(stats_cols)
    for label,i in labels {
        if i==1&&!show_swap_stat {continue}
        stat_index:=i
        if !show_swap_stat&&i>1 {stat_index-=1}
        sx:=x+f32(stat_index%stats_cols)*(stats_w+gap)
        sy:=stats_y+f32(stat_index/stats_cols)*stats_h-offset
        fit_text(a,label,sx,sy,stats_w,12,MUTED)
        value,detail:="--","Unavailable"
        color:=TEXT
        if s!=nil {
            switch i {
            case 0:
                if s.ram_available {
                    value=fmt.tprintf("%.1f GB",memory_gb(s.memory_used))
                    detail=fmt.tprintf("%.1fGB/%.1fGB available",memory_gb(s.memory_available),memory_gb(s.memory_total))
                    color=AMBER
                }
            case 1:
                if s.ram_available&&s.swap_total>0 {
                    used:=memory_pct(s.swap_used,s.swap_total)
                    value=bytes_label(s.swap_used)
                    detail=fmt.tprintf("%.0f%% / %s total",used,bytes_label(s.swap_total))
                    color=utilization_color(used)
                }
            case 2:
                if s.rates_ready {value=rate_label(s.disk_read);color=CYAN}
            case 3:
                if s.rates_ready {value=rate_label(s.disk_write);color=AMBER}
            case 4:
                if s.network_rates_ready {value=rate_label(s.network_rx);color=CYAN}
            case 5:
                if s.network_rates_ready {value=rate_label(s.network_tx);color=AMBER}
            }
        }
        fit_text(a,value,sx,sy+34,stats_w,27 if w>850||compact else 22,color)
        if i>=2 {
            summary:=&a.io_summary
            total_label,max_label:="Total --","Max --"
            if summary.available[i-2] {
                total_label=fmt.tprintf("Total %s",io_total_label(summary.totals[i-2]))
                max_label=fmt.tprintf("Max %s",rate_label(summary.max_rates[i-2]))
            }
            fit_text(a,total_label,sx,sy+55,stats_w,12,MUTED)
            fit_text(a,max_label,sx,sy+73,stats_w,12,MUTED)
        } else {fit_text(a,detail,sx,sy+55,stats_w,12,MUTED)}
    }

    // Each I/O pair shares its scale; disk and network scale independently.
    disk_max,network_max:=f32(1024),f32(1024)
    for i in 0..<a.history_count {
        candidate:=(first+i)%HISTORY_CAPACITY
        sample:=&a.cpu_history[candidate]
        if history_position(a,candidate)<0 {continue}
        if sample.rates_ready {
            peak:=f32(max(sample.disk_read,sample.disk_write))
            for disk_max<peak {disk_max*=2}
        }
        if sample.network_rates_ready {
            peak:=f32(max(sample.network_rx,sample.network_tx))
            for network_max<peak {network_max*=2}
        }
    }
    kinds:=[2]CPU_Plot{.Memory,.Swap}
    disk_max=graph_animation_ceiling(a,disk_max,.Disk)
    network_max=graph_animation_ceiling(a,network_max,.Network)
    plot_labels:=[2]string{"RAM GB","SWAP USED %"}
    if m.platform=="windows" {plot_labels[1]="PAGEFILE USED %"}
    ram_kinds:=[5]CPU_Plot{.Memory,.Memory_Free,.Memory_Cached,.Memory_Buffers,.Memory_Available}
    ram_labels:=[5]string{"Used","Free","Cache","Buffers","Available"}
    if m.platform=="windows" {ram_labels[2],ram_labels[3]="Standby","Modified"}
    if m.platform=="darwin" {ram_labels[2]="File cache"}
    ram_colors:=[5]Color{AMBER,GREEN,CYAN,PURPLE,SOFT}
    ram_max:=memory_capacity_ceiling(m.memory_total)
    ram_max=graph_animation_ceiling(a,ram_max,.RAM)
    legend_w:=gw/f32(legend_cols)
    yy:=gy
    for kind,i in kinds {
        if i==1&&!show_swap {continue}
        text(a,plot_labels[i],x,yy-18,12,MUTED)
        available:=m.ram_available
        if !available {right_text(a,"Unavailable",x+w,yy-18,12,MUTED)}
        if i==0 {
            memory_gb_grid(a,gx,yy,gw,heights[i],ram_max,label_x=x)
            for pass in ([2]Graph_Pass{.Fill,.Line}) {
                for incoming in ([2]bool{false,true}) {
                    animation,draw:=graph_animation_begin(a,incoming,gx,gw)
                    if draw {
                        for ram_kind,j in ram_kinds {cpu_plot(a,ram_kind,-1,gx,yy,gw,heights[i],ram_max,ram_colors[j],render_pass=pass)}
                    }
                    graph_animation_end(a,animation)
                }
            }
            for ram_kind,j in ram_kinds {
                legend_x:=gx+f32(j%legend_cols)*legend_w
                legend_y:=yy+heights[i]+20+f32(j/legend_cols)*18
                value:f32
                series_available:=false
                if s!=nil {value,series_available=cpu_plot_value(s,ram_kind)}
                label:=fmt.tprintf("%s %.1f GB",ram_labels[j],value) if series_available else fmt.tprintf("%s --",ram_labels[j])
                stroke(a,legend_x,legend_y-4,legend_x+12,legend_y-4,2,ram_colors[j])
                fit_text(a,label,legend_x+18,legend_y,legend_w-24,12,ram_colors[j])
            }
        } else {
            cpu_grid(a,gx,yy,gw,heights[i],100,kind,label_x=x)
            cpu_plot(a,kind,-1,gx,yy,gw,heights[i],100,GREEN)
        }
        yy+=heights[i]+(ram_gap if i==0 else plot_gap)
    }
    io_kinds:=[2][2]CPU_Plot{{.Disk_Read,.Disk_Write},{.Network_RX,.Network_TX}}
    io_labels:=[2][2]string{{"DISK READ","DISK WRITE"},{"NETWORK RECEIVE","NETWORK TRANSMIT"}}
    io_ceilings:=[2]f32{disk_max,network_max}
    io_colors:=[2]Color{CYAN,AMBER}
    for ceiling,column in io_ceilings {
        column_x:=x+f32(column)*(column_w+column_gap)
        plot_x:=column_x+48
        unit:="MiB/s" if ceiling>=1048576 else "KiB/s"
        yy=io_y
        for kind,row in io_kinds[column] {
            hh:=heights[row+2]
            fit_text(a,fmt.tprintf("%s %s",io_labels[column][row],unit),column_x,yy-18,column_w,12,MUTED)
            available:=false
            if s!=nil {_,available=cpu_plot_value(s,kind)}
            if !available {right_text(a,"Unavailable",column_x+column_w,yy-18,12,MUTED)}
            memory_rate_grid(a,plot_x,yy,io_w,hh,ceiling,label_x=column_x)
            cpu_plot(a,kind,-1,plot_x,yy,io_w,hh,ceiling,io_colors[row])
            yy+=hh
            if row==0 {yy+=plot_gap}
        }
        text(a,graph_time_axis_label(a),column_x,yy+time_axis_h,12,MUTED)
        right_text(a,history_end_label(a),plot_x+io_w,yy+time_axis_h,12,MUTED)
    }
    if (hover_slot>=0||a.memory_pinned_slot>=0)&&s!=nil {
        cursor_position:=history_position(a,slot)
        if a.memory_pinned_slot<0 {cursor_position=position}
        cursor_x:=gx+gw*cursor_position
        memory_bottom:=swap_y+heights[1] if show_swap else gy+heights[0]
        stroke(a,cursor_x,gy,cursor_x,memory_bottom,1,MUTED)
        for column in 0..<2 {
            cursor_x=gx+f32(column)*(column_w+column_gap)+io_w*cursor_position
            stroke(a,cursor_x,io_y,cursor_x,yy,1,MUTED)
        }
        graph_xs:=[6]f32{gx,gx,gx,gx,network_gx,network_gx}
        graph_ys:=[6]f32{gy,swap_y,io_y,write_y,io_y,write_y}
        graph_ws:=[6]f32{gw,gw,io_w,io_w,io_w,io_w}
        graph_hs:=[6]f32{heights[0],heights[1],heights[2],heights[3],heights[2],heights[3]}
        label_graph:=clamp(a.memory_pinned_graph if a.memory_pinned_slot>=0 else hover_graph,0,5)
        cursor_x=graph_xs[label_graph]+graph_ws[label_graph]*cursor_position
        history_time_label(a,slot,a.memory_pinned_slot>=0,cursor_x,graph_xs[label_graph],graph_ys[label_graph],graph_ws[label_graph],graph_hs[label_graph])
    }
    graph_controls_draw(a,gx,yy+time_axis_h+8,gw)
    if max_scroll>0 {
        track_h:=viewport_bottom-viewport_top
        thumb_h:=max(24,track_h*track_h/(content_bottom-viewport_top))
        thumb_y:=viewport_top+(track_h-thumb_h)*a.memory_scroll/max_scroll
        rect(a,x+w+9,thumb_y,2,thumb_h,MUTED)
    }
}

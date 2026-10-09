package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import "core:thread"
import glfw "vendor:glfw"

Color :: [4]f32
BG      :: Color{0, 0, 0, 1}
PANEL   :: Color{0.040, 0.040, 0.040, 1}
LINE    :: Color{0.13, 0.13, 0.13, 1}
TEXT    :: Color{0.93, 0.93, 0.93, 1}
MUTED   :: Color{0.49, 0.49, 0.49, 1}
SOFT    :: Color{0.74, 0.74, 0.74, 1}
PURPLE  :: Color{0.70, 0.53, 0.98, 1}
CYAN    :: Color{0.32, 0.79, 0.86, 1}
GREEN   :: Color{0.43, 0.83, 0.64, 1}
AMBER   :: Color{0.96, 0.72, 0.39, 1}
RED     :: Color{0.96, 0.36, 0.36, 1}

color_mix :: proc(from,to:Color,t:f32)->Color {
    return from+(to-from)*clamp(t,0,1)
}

utilization_color :: proc(value:f32)->Color {
    load:=clamp(value,0,100)
    if load<=50 {return color_mix(GREEN,AMBER,load/50)}
    return color_mix(AMBER,RED,(load-50)/50)
}

View :: enum { Overview, CPU, GPU, Memory }
// Retain the full five minutes even when the visible time span is shorter.
// Include both endpoints at the fastest supported 100 ms polling interval.
HISTORY_SECONDS :: 300
HISTORY_CAPACITY :: HISTORY_SECONDS*10+1
CPU_Core_Sample :: struct {
    lower, upper, frequency_mhz: f32,
    frequency_available: bool,
}
CPU_Sample :: struct {
    generation: u64,
    timestamp: f64,
    polling_seconds: f64,
    continuity_recorded, gap_before: bool,
    lower, upper, threads, power_watts, frequency_mhz: f32,
    power_available, frequency_available: bool,
    memory_total, memory_used, memory_available, swap_total, swap_used: u64,
    memory_free, memory_cached, memory_buffers: u64,
    memory_breakdown_available: bool,
    memory_free_available, memory_cached_available, memory_buffers_available: bool,
    disk_read, disk_write, network_rx, network_tx: f64,
    ram_available, rates_ready, network_rates_ready: bool,
    cores: [256]CPU_Core_Sample,
    logical: [256]f32,
    gpu: GPU_Sample,
}
Machine_State :: struct {
    metrics: Metrics,
    io_summary: IO_Summary,
    paused: bool,
    process_order: [4]Process_Order,
    process_revision: u64,
    process_frozen: [4]^Process_Frozen_Table,
    process_preferences: [128]Process_Preference,
    process_preference_count: int,
    process_preferences_path: [1024]u8,
    process_preferences_path_len: int,
    process_preference_error: bool,
    expanded_processes: [4][dynamic]string,
    history: [4][HISTORY_CAPACITY]f32,
    history_count: int,
    history_next: int,
    history_connected: bool,
    history_handoff_pending: bool,
    history_handoff_timestamp: f64,
    last_sample: f64,
    process_scroll: [5]f32,
    cpu_history: [HISTORY_CAPACITY]CPU_Sample,
    graph_smoothing: ^Graph_Smoothing,
    cpu_scroll: f32,
    overview_scroll: f32,
    cpu_pinned_slot: int,
    cpu_pinned_graph: int,
    gpu_scroll: f32,
    gpu_pinned_slot: int,
    gpu_pinned_graph: int,
    memory_scroll: f32,
    memory_pinned_slot: int,
    memory_pinned_graph: int,
}
App :: struct {
    using machine: ^Machine_State,
    view: View,
    renderer: Renderer,
    vertices: [dynamic]Vertex,
    vertex_small_frames: int,
    process_menu_open: bool,
    process_menu_name: [64]u8,
    process_menu_name_len: int,
    process_menu_x,process_menu_y:f32,
    process_menu_pids: [dynamic]PID_Node,
    process_menu_kill: bool,
    process_menu_scroll: int,
    process_menu_error: [256]u8,
    process_menu_error_len: int,
    process_kill: ^Process_Kill_Action,
    process_rows: [dynamic]Process_Row,
    process_cache: Process_Cache,
    process_freeze_x, process_freeze_y: f32,
    process_freeze_visible: bool,
    graphs_frozen: bool,
    graphs_frozen_at: i64,
    graphs_catching_up: bool,
    graph_catchup_started: time.Tick,
    graph_catchup_progress: f32,
    graph_readout: Graph_Readout,
    graph_freeze_x, graph_freeze_w: f32,
    interval: f64,
    history_seconds: f64,
    graph_controls: [2]Graph_Control_Bounds,
    graph_control_drag: int,
    graph_control_x: f32,
    graph_control_raw: f64,
    graph_control_ctrl: bool,
    graph_settings_data: string,
    graph_settings_error: bool,
    graph_settings_pending: bool,
    graph_settings_saved_at: time.Tick,
    started: f64,
    mouse_down: bool,
    click: bool,
    pending_click: bool,
    mouse_x, mouse_y: f32,
    scale: f32,
    width, height: f32,
    content_x: f32,
    dirty: bool,
    frame_count: int,
    clock_second: i64,
    table_x,table_y,table_w,table_h:f32,
    clip_active:bool,
    clip_top,clip_bottom:f32,
    cpu_graph_x,cpu_graph_y,cpu_graph_w,cpu_graph_h: f32,
    machines: [dynamic]^Machine,
    local_machine: ^Machine,
    dismissed_machines: [dynamic]Machine_Record,
    machine_tabs: [dynamic]Machine_Tab,
    machine_menu_scroll: int,
    machine_drag_index, machine_drag_target: int,
    machine_pointer_down, machine_dragging: bool,
    machine_drag_x, machine_drag_y: f32,
    machine_overflow_x: f32,
    machine_count, active_machine: int,
    machine_status_poll: f64,
    machine_next_rank: int,
    machine_order_edited: bool,
    machine_login_candidates: [dynamic]SSH_Login_Candidate,
    machine_saved_records: [dynamic]Machine_Record,
    machine_dialog_scroll: int,
    machine_terminal_jobs: [dynamic]Machine_Terminal_Job,
    machine_login_discovery: ^SSH_Login_Discovery,
    machine_menu, machine_dialog: bool,
    machine_config_path: [1024]u8,
    machine_config_path_len: int,
    machine_menu_x, machine_menu_w: f32,
    machine_input: [3][1024]u8,
    machine_input_len: [3]int,
    machine_input_focus: int,
    machine_error: [512]u8,
    machine_error_len: int,
    persistence_enabled: bool,
    persistence_io_session: f64,
    persistence_error: [512]u8,
    persistence_error_len: int,
    persistence_last_poll: f64,
    persistence_config_data: string,
    persistence_x, persistence_w: f32,
    persistence_change: ^Persistence_Change,
    persistence_reconnect_pending: bool,
    persistence_reader: ^Persistence_Reader,
    persistence_live_reader: ^Persistence_Reader,
}

// Headless service workers use the same sampling code without touching GLFW.
persistence_headless: bool
app_wake :: proc() {
    if !persistence_headless {glfw.PostEmptyEvent()}
}

rect :: proc(a: ^App, x,y,w,h:f32, c:Color) {
    if w<=0||h<=0 {return}
    // Align both rectangle edges to physical pixels, including fractional DPI.
    x0,y0:=math.round(x*a.scale),math.round(y*a.scale)
    x1,y1:=math.round((x+w)*a.scale),math.round((y+h)*a.scale)
    top,bottom:=y0,y1
    if a.clip_active {top=max(top,math.round(a.clip_top*a.scale));bottom=min(bottom,math.round(a.clip_bottom*a.scale))}
    if bottom<=top {return}
    renderer_rect(&a.vertices,x0,top,max(x1-x0,1),bottom-top,c)
}
text :: proc(a:^App, s:string,x,y,size:f32,c:Color=TEXT) {
    font_size:=max(size,12)
    clip_top,clip_bottom:=f32(-1e30),f32(1e30)
    if a.clip_active {clip_top=math.round(a.clip_top*a.scale);clip_bottom=math.round(a.clip_bottom*a.scale)}
    renderer_text(&a.renderer,&a.vertices,s,x*a.scale,(y-font_size*0.8)*a.scale,font_size*a.scale,c,clip_top,clip_bottom)
}
right_text :: proc(a:^App,s:string,x,y,size:f32,c:Color=TEXT) {
    w := renderer_text_width(&a.renderer,s,max(size,12)*a.scale)/a.scale
    text(a,s,x-w,y,size,c)
}
fit_text :: proc(a:^App,s:string,x,y,w,size:f32,c:Color=TEXT) {
    if renderer_text_width(&a.renderer,s,max(size,12)*a.scale) <= w*a.scale { text(a,s,x,y,size,c); return }
    // Measure the prefix once, keeping UTF-8 codepoints intact.
    font:=renderer_font_size(&a.renderer,max(size,12)*a.scale)
    width:=f32(0)
    n:=len(s)
    for ch,index in s {
        c:=ch
        if c<32||c>126 {c='?'}
        width+=font.glyphs[c-32].advance
        if width>(w-16)*a.scale {n=index;break}
    }
    text(a,fmt.tprintf("%s...",s[:n]),x,y,size,c)
}
hit :: proc(a:^App,x,y,w,h:f32)->bool {
    if a.clip_active&&(a.mouse_y<a.clip_top||a.mouse_y>=a.clip_bottom) {return false}
    return a.click && a.mouse_x >= x && a.mouse_y >= y && a.mouse_x < x+w && a.mouse_y < y+h
}
panel :: proc(a:^App,x,y,w,h:f32) {
    rounded_rect(a,x,y,w,h,8,LINE)
    rounded_rect(a,x+1,y+1,w-2,h-2,7,PANEL)
}
rounded_rect :: proc(a:^App,x,y,w,h,radius:f32,c:Color) {
    if w<=0||h<=0{return}
    r:=min(radius,min(w,h)/2)
    centers:=[4][2]f32{{x+r,y+r},{x+w-r,y+r},{x+w-r,y+h-r},{x+r,y+h-r}}
    outline: [36][2]f32
    for center,k in centers {
        start:=f32(k+2)*math.PI/2
        for i in 0..<9 {
            t:=start+f32(i)*math.PI/16
            outline[k*9+i]={center[0]+math.cos(t)*r,center[1]+math.sin(t)*r}
        }
    }
    // Share every triangle edge; separately pixel-rounded rectangles leave
    // seams against the curved ends at fractional display scales.
    for p,i in outline {
        points:=[3][2]f32{{x+w/2,y+h/2},p,outline[(i+1)%len(outline)]}
        for point in points {
            py:=point[1]
            if a.clip_active {py=clamp(py,a.clip_top,a.clip_bottom)}
            append(&a.vertices,Vertex{pos={point[0]*a.scale,py*a.scale},uv={0,0},color=c})
        }
    }
}
bar :: proc(a:^App,x,y,w,h,value:f32,c:Color) {
    rect(a,x,y,w,h,LINE)
    rect(a,x,y,w*clamp(value/100,0,1),h,c)
}
stroke :: proc(a:^App,start_x,start_y,end_x,end_y,width:f32,c:Color) {
    stroke_gradient(a,start_x,start_y,end_x,end_y,width,c,c)
}
Graph_Pass :: enum { All, Fill, Line }

graph_fill_segment :: proc(a:^App,x0,y0,x1,y1,bottom:f32,c0,c1:Color,height:f32,height_color:bool=false,color_scale:f32=1) {
    if x1<=x0||height<=0||bottom<=min(y0,y1) {return}
    points: [8]Vertex
    points[0]=Vertex{pos={x0,y0},color=c0}
    points[1]=Vertex{pos={x1,y1},color=c1}
    points[2]=Vertex{pos={x1,bottom},color=c1}
    points[3]=Vertex{pos={x0,bottom},color=c0}
    count:=4
    // Clip the polygon and interpolate its colours together, preserving the
    // fade's original position when a graph scrolls through the viewport.
    if a.clip_active {
        if bottom<=a.clip_top||min(y0,y1)>=a.clip_bottom {return}
        if min(y0,y1)<a.clip_top||bottom>a.clip_bottom {
            boundaries:=[2]f32{a.clip_top,a.clip_bottom}
            for boundary,side in boundaries {
                clipped: [8]Vertex
                clipped_count:=0
                previous:=points[count-1]
                previous_inside:=previous.pos[1]>=boundary if side==0 else previous.pos[1]<=boundary
                for current in points[:count] {
                    inside:=current.pos[1]>=boundary if side==0 else current.pos[1]<=boundary
                    if inside!=previous_inside {
                        t:=(boundary-previous.pos[1])/(current.pos[1]-previous.pos[1])
                        clipped[clipped_count]=Vertex{pos=previous.pos+(current.pos-previous.pos)*t,
                            color=previous.color+(current.color-previous.color)*t}
                        clipped_count+=1
                    }
                    if inside {clipped[clipped_count]=current;clipped_count+=1}
                    previous,previous_inside=current,inside
                }
                if clipped_count<3 {return}
                points,count=clipped,clipped_count
            }
        }
    }
    // The line only cuts off the fill. Coordinates refer to the whole graph,
    // so the shader uses the same colour and opacity at each height everywhere.
    mode:=f32(-1) if height_color else f32(-2)
    for i in 1..<(count-1) {
        indices:=[3]int{0,i,i+1}
        for index in indices {
            vertex:=points[index]
            level:=(bottom-vertex.pos[1])/height
            vertex.uv={level*color_scale,level}
            vertex.stroke={mode,0}
            vertex.pos*=a.scale
            append(&a.vertices,vertex)
        }
    }
}

stroke_gradient :: proc(a:^App,start_x,start_y,end_x,end_y,width:f32,start_color,end_color:Color) {
    x1,y1,x2,y2:=start_x,start_y,end_x,end_y
    c1,c2:=start_color,end_color
    if a.clip_active {
        if math.abs(y2-y1)<0.001 {if y1<a.clip_top||y1>a.clip_bottom{return}}
        else {
            t0,t1:=(a.clip_top-y1)/(y2-y1),(a.clip_bottom-y1)/(y2-y1)
            lo,hi:=max(0,min(t0,t1)),min(1,max(t0,t1))
            if hi<=lo{return}
            ox,oy,dx,dy:=x1,y1,x2-x1,y2-y1
            x1,y1=ox+lo*dx,oy+lo*dy
            x2,y2=ox+hi*dx,oy+hi*dy
            c1,c2=color_mix(start_color,end_color,lo),color_mix(start_color,end_color,hi)
        }
    }
    dx,dy := x2-x1,y2-y1
    length := math.sqrt(dx*dx+dy*dy)
    if length < 0.001 {return}
    tx,ty:=dx/length,dy/length
    nx,ny:=-ty,tx
    half_width:=width*a.scale/2
    outer:=half_width+0.5
    pixels:=length*a.scale
    sx,sy:=x1*a.scale,y1*a.scale
    local:=[6][2]f32{{-outer,outer},{pixels+outer,outer},{pixels+outer,-outer},
        {-outer,outer},{pixels+outer,-outer},{-outer,-outer}}
    for p in local {
        px,py:=sx+tx*p[0]+nx*p[1],sy+ty*p[0]+ny*p[1]
        if a.clip_active {py=clamp(py,a.clip_top*a.scale,a.clip_bottom*a.scale)}
        // Recompute local coordinates after clipping to preserve the distance
        // field; text and filled rectangles keep their existing atlas path.
        uv:=[2]f32{(px-sx)*tx+(py-sy)*ty,(px-sx)*nx+(py-sy)*ny}
        color:=color_mix(c1,c2,uv[0]/pixels)
        append(&a.vertices,Vertex{pos={px,py},uv=uv,color=color,stroke={half_width,pixels}})
    }
}
bytes_label :: proc(v:u64)->string {
    f:=f64(v)
    if f >= 1073741824 {return fmt.tprintf("%.1f GiB",f/1073741824)}
    if f >= 1048576 {return fmt.tprintf("%.0f MiB",f/1048576)}
    return fmt.tprintf("%.0f KiB",f/1024)
}
rate_label :: proc(v:f64)->string {
    if v >= 1048576 {return fmt.tprintf("%.1f MiB/s",v/1048576)}
    return fmt.tprintf("%.1f KiB/s",v/1024)
}
memory_pct :: proc(used,total:u64)->f32 {if total==0{return 0}; return 100*f32(used)/f32(total)}
memory_gb :: proc(bytes:u64)->f32 {return f32(f64(bytes)/1073741824)}

history_position :: proc(a:^App,slot:int)->f32 {
    latest:=(a.history_next+HISTORY_CAPACITY-1)%HISTORY_CAPACITY
    return 1-f32((a.cpu_history[latest].timestamp-a.cpu_history[slot].timestamp)/a.history_seconds)
}

history_time_label :: proc(a:^App,slot:int,pinned:bool,cursor_x,x,y,w,h:f32) {
    if slot<0||a.history_count==0 {return}
    latest:=(a.history_next+HISTORY_CAPACITY-1)%HISTORY_CAPACITY
    age:=max(0,a.cpu_history[latest].timestamp-a.cpu_history[slot].timestamp)
    label:=fmt.tprintf("-%.1f s%s",age," / pinned" if pinned else "")
    label_w:=renderer_text_width(&a.renderer,label,12*a.scale)/a.scale+12
    label_h:=f32(24)
    left,right:=x,x+w
    // A narrow split plot can borrow the content width to keep the time legible.
    if label_w>w {left,right=a.content_x,a.width-a.content_x}
    label_x:=cursor_x+10
    if label_x+label_w>right {label_x=cursor_x-label_w-10}
    label_x=clamp(label_x,left,max(left,right-label_w))
    top,bottom:=y,y+h
    if a.clip_active {
        if a.cpu_graph_y+a.cpu_graph_h<=a.clip_top||a.cpu_graph_y>=a.clip_bottom {return}
        top,bottom=max(top,a.clip_top),min(bottom,a.clip_bottom)
        if bottom-top<label_h+12 {top,bottom=a.clip_top,a.clip_bottom}
    }
    label_y:=clamp(y+6,top+4,max(top+4,bottom-label_h-4))
    rounded_rect(a,label_x,label_y,label_w,label_h,4,LINE)
    rounded_rect(a,label_x+1,label_y+1,label_w-2,label_h-2,3,PANEL)
    text(a,label,label_x+6,label_y+16,12,SOFT)
}

graph :: proc(a:^App,kind:int,x,y,w,h:f32,render_pass:Graph_Pass=.All) {
    if render_pass==.All {
        for i in 0..<3 {rect(a,x,y+f32(i)*h/2,w,1,LINE)}
        for pass in ([2]Graph_Pass{.Fill,.Line}) {
            for incoming in ([2]bool{false,true}) {
                animation,draw:=graph_animation_begin(a,incoming,x,w)
                if draw {graph(a,kind,x,y,w,h,pass)}
                graph_animation_end(a,animation)
            }
        }
        return
    }
    count:=a.history_count
    if count < 2 {return}
    first:=(a.history_next-count+HISTORY_CAPACITY)%HISTORY_CAPACITY
    for i in 1..<count {
        prev_slot,curr_slot:=(first+i-1)%HISTORY_CAPACITY,(first+i)%HISTORY_CAPACITY
        if !history_segment_contiguous(&a.cpu_history[prev_slot],&a.cpu_history[curr_slot]) {continue}
        prev:=a.history[kind][prev_slot]
        curr:=a.history[kind][curr_slot]
        p0,p1:=history_position(a,prev_slot),history_position(a,curr_slot)
        if p1<=0 {continue}
        if p0<0 {prev+=(curr-prev)*(-p0/(p1-p0));p0=0}
        px:=x+w*p0
        cx:=x+w*p1
        py:=y+h*(1-clamp(prev/100,0,1))
        cy:=y+h*(1-clamp(curr/100,0,1))
        if render_pass==.Fill {graph_fill_segment(a,px,py,cx,cy,y+h,utilization_color(prev),utilization_color(curr),h,true)}
        else {stroke_gradient(a,px,py,cx,cy,2,utilization_color(prev),utilization_color(curr))}
    }
}
history_memory_sample :: proc(sample:^CPU_Sample,m:^Metrics) {
    sample.memory_total,sample.memory_used,sample.memory_available=m.memory_total,m.memory_used,m.memory_available
    sample.memory_free,sample.memory_cached,sample.memory_buffers=m.memory_free,m.memory_cached,m.memory_buffers
    sample.memory_breakdown_available=m.memory_breakdown_available
    sample.memory_free_available,sample.memory_cached_available,sample.memory_buffers_available=m.memory_free_available,m.memory_cached_available,m.memory_buffers_available
    sample.swap_total,sample.swap_used=m.swap_total,m.swap_used
    sample.disk_read,sample.disk_write=m.disk_read,m.disk_write
    sample.network_rx,sample.network_tx=m.network_rx,m.network_tx
    sample.ram_available,sample.rates_ready=m.ram_available,m.rates_ready
    sample.network_rates_ready=m.rates_ready
}

history_memory_copy :: proc(destination,source:^CPU_Sample) {
    if !destination.ram_available&&source.ram_available {
        destination.memory_total,destination.memory_used,destination.memory_available=source.memory_total,source.memory_used,source.memory_available
        destination.swap_total,destination.swap_used=source.swap_total,source.swap_used
        destination.ram_available=true
    }
    if !destination.rates_ready&&source.rates_ready {
        destination.disk_read,destination.disk_write=source.disk_read,source.disk_write
        destination.rates_ready=true
    }
    if !destination.memory_free_available&&(source.memory_free_available||source.memory_breakdown_available) {
        destination.memory_free=source.memory_free;destination.memory_free_available=true
    }
    if !destination.memory_cached_available&&(source.memory_cached_available||source.memory_breakdown_available) {
        destination.memory_cached=source.memory_cached;destination.memory_cached_available=true
    }
    if !destination.memory_buffers_available&&(source.memory_buffers_available||source.memory_breakdown_available) {
        destination.memory_buffers=source.memory_buffers;destination.memory_buffers_available=true
    }
    destination.memory_breakdown_available=destination.memory_free_available&&destination.memory_cached_available&&destination.memory_buffers_available
    if !destination.network_rates_ready&&source.network_rates_ready {
        destination.network_rx,destination.network_tx=source.network_rx,source.network_tx
        destination.network_rates_ready=true
    }
}

history_push :: proc(a:^App,timestamp:f64=0) {
    a.process_revision+=1
    m:=&a.metrics
    slot:=a.history_next
    if a.cpu_pinned_slot==slot {a.cpu_pinned_slot=-1}
    if a.gpu_pinned_slot==slot {a.gpu_pinned_slot=-1}
    if a.memory_pinned_slot==slot {a.memory_pinned_slot=-1}
    sample:=&a.cpu_history[slot]
    sampled_at:=timestamp
    if sampled_at==0 {sampled_at=f64(time.to_unix_nanoseconds(time.now()))/1e9}
    gap_before:=!a.history_connected
    if a.history_handoff_pending {
        if a.history_count>0 {
            previous:=&a.cpu_history[(slot+HISTORY_CAPACITY-1)%HISTORY_CAPACITY]
            gap_before=!history_handoff_contiguous(previous.timestamp,sampled_at,previous.polling_seconds,a.interval)
        } else {
            // The asynchronous cache may supply this sample's predecessor later.
            a.history_handoff_timestamp=sampled_at
        }
        a.history_handoff_pending=false
    }
    sample^=CPU_Sample{generation=m.cpu_topology_generation,timestamp=sampled_at,polling_seconds=a.interval,
        continuity_recorded=true,gap_before=gap_before,
        lower=m.cpu_busy_lower,upper=m.cpu_busy_upper,threads=m.cpu_percent,
        power_watts=m.cpu_power_watts,frequency_mhz=m.cpu_frequency_mhz,
        power_available=m.cpu_power_available,frequency_available=m.cpu_frequency_available,
        memory_total=m.memory_total,memory_used=m.memory_used,memory_available=m.memory_available,
        memory_free=m.memory_free,memory_cached=m.memory_cached,memory_buffers=m.memory_buffers,
        memory_breakdown_available=m.memory_breakdown_available,
            memory_free_available=m.memory_free_available,memory_cached_available=m.memory_cached_available,memory_buffers_available=m.memory_buffers_available,
        swap_total=m.swap_total,swap_used=m.swap_used,disk_read=m.disk_read,disk_write=m.disk_write,
        network_rx=m.network_rx,network_tx=m.network_tx,
        ram_available=m.ram_available,rates_ready=m.rates_ready,network_rates_ready=m.rates_ready,
        logical=m.cores}
    a.history_connected=true
    sample.gpu=gpu_sample(&m.gpus[0],m.gpu_count>0)
    for core,i in m.physical_cores[:m.physical_core_count] {
        sample.cores[i]=CPU_Core_Sample{lower=core.busy_lower,upper=core.busy_upper,
            frequency_mhz=core.frequency_mhz,frequency_available=core.frequency_available}
    }
    if persistence_headless {io_summary_sample(&a.io_summary,sample,a.persistence_io_session)}
    a.history[0][a.history_next]=m.cpu_percent
    a.history[1][a.history_next]=m.gpus[0].utilization
    a.history[2][a.history_next]=memory_pct(m.memory_used,m.memory_total)
    a.history[3][a.history_next]=memory_pct(m.gpus[0].memory_used,m.gpus[0].memory_total)
    a.history_next=(a.history_next+1)%HISTORY_CAPACITY
    a.history_count=min(a.history_count+1,HISTORY_CAPACITY)
    // Changing the polling interval must not shorten retention. Prune by age,
    // retaining the boundary sample needed to draw the full 300-second axis.
    for a.history_count>1 {
        first:=(a.history_next-a.history_count+HISTORY_CAPACITY)%HISTORY_CAPACITY
        second:=(first+1)%HISTORY_CAPACITY
        if a.cpu_history[second].timestamp>=sampled_at-HISTORY_SECONDS {break}
        if a.cpu_pinned_slot==first {a.cpu_pinned_slot=-1}
        if a.gpu_pinned_slot==first {a.gpu_pinned_slot=-1}
        if a.memory_pinned_slot==first {a.memory_pinned_slot=-1}
        a.history_count-=1
    }
}

navigation :: proc(a:^App)->f32 {
    y:=a.content_x
    compact:=a.width<600
    names:=[4]string{"Overview 1","CPU 2","GPU 3","Mem+IO 4"}
    if compact {names={"All 1","CPU 2","GPU 3","Mem+IO 4"}}
    gap:=f32(12) if compact else f32(18)
    widths: [4]f32
    total:=gap*3
    for name,i in names {
        widths[i]=renderer_text_width(&a.renderer,name,12*a.scale)/a.scale
        total+=widths[i]
    }
    start:=a.width-a.content_x-total
    x:=start
    for _,i in names {
        if hit(a,x-6,y,widths[i]+12,28){a.view=View(i)}
        x+=widths[i]+gap
    }
    x=start
    for name,i in names {
        text(a,name,x,y+16,12,TEXT if int(a.view)==i else MUTED)
        x+=widths[i]+gap
    }
    return persistence_control(a,start)
}

persistence_control :: proc(a:^App,nav_x:f32)->f32 {
    y:=a.content_x
    label:="Persist" if a.width<600 else "Persistence"
    label_w:=renderer_text_width(&a.renderer,label,12*a.scale)/a.scale
    w:=label_w+44
    x:=nav_x-w-20
    a.persistence_x=x;a.persistence_w=w
    hovered:=!a.machine_dialog&&!a.machine_menu&&a.mouse_x>=x-5&&a.mouse_x<x+w+5&&a.mouse_y>=y&&a.mouse_y<y+28
    if hovered&&hit(a,x-5,y,w+10,28) {
        _=persistence_toggle(a)
        a.click=false;a.dirty=true
    }
    enabled:=a.persistence_enabled
    if a.persistence_change!=nil {enabled=a.persistence_change.desired}
    color:=GREEN if enabled else MUTED
    if a.persistence_change!=nil {color=AMBER}
    if a.persistence_error_len>0 {color=AMBER}
    rounded_rect(a,x,y+3,32,18,9,color if enabled||a.persistence_change!=nil else LINE)
    knob_x:=x+17 if enabled else x+3
    rounded_rect(a,knob_x,y+6,12,12,6,BG if enabled||a.persistence_change!=nil else SOFT)
    text(a,label,x+40,y+16,12,TEXT if hovered else color)
    return x
}

persistence_message :: proc(a:^App) {
    if a.persistence_error_len==0 {return}
    // Keep service diagnostics in a hover tooltip instead of covering graphs.
    y:=a.content_x
    if a.machine_dialog||a.machine_menu||a.mouse_x<a.persistence_x-5||a.mouse_x>=a.persistence_x+a.persistence_w+5||a.mouse_y<y||a.mouse_y>=y+28 {return}
    w:=min(a.width-56,f32(720))
    panel(a,a.width-w-a.content_x,y+36,w,34)
    fit_text(a,string(a.persistence_error[:a.persistence_error_len]),a.width-w-a.content_x+12,y+58,w-24,12,AMBER)
}

header :: proc(a:^App) {
    nav_x:=navigation(a)
    nav_x=graph_freeze_control(a,nav_x)
    // Reserve clock space before laying out the machine tabs and controls.
    clock_w:=renderer_text_width(&a.renderer,"00:00:00",12*a.scale)/a.scale
    clock_x:=nav_x-clock_w-20
    text(a,platform_clock_text(a.clock_second),clock_x,a.content_x+16,12,SOFT)
    nav_x=clock_x
    titles:=[4]string{"Overview","Processor","Graphics","Memory + IO"}
    selector_x:=a.content_x
    if nav_x-a.content_x>490 {
        title_width:=f32(0)
        for title in titles {
            title_width=max(title_width,renderer_text_width(&a.renderer,title,24*a.scale)/a.scale)
        }
        title:=titles[int(a.view)]
        font:=renderer_font_size(&a.renderer,24*a.scale)
        top:=f32(0)
        for ch in title {top=max(top,f32(font.glyphs[ch-32].top))}
        // Match the visible title's top to the side margin at every DPI.
        text(a,title,a.content_x,a.content_x+top/a.scale,24)
        selector_x+=title_width+26
    }
    machine_header(a,selector_x,max(90,nav_x-selector_x-14))
}
summary_card :: proc(a:^App,kind:int,label,detail:string,value:f32,available:bool,x,y,w:f32) {
    panel(a,x,y,w,197)
    current_color:=utilization_color(value) if available else MUTED
    rect(a,x+18,y+21,6,6,current_color)
    text(a,label,x+33,y+28,12,SOFT)
    value_label:=fmt.tprintf("%.1f",value) if available else "--"
    number_size:=f32(30) if w<220 else f32(36)
    text(a,value_label,x+18,y+78,number_size,current_color)
    if available {
        number_width:=renderer_text_width(&a.renderer,value_label,number_size*a.scale)/a.scale
        text(a,"%",x+24+number_width,y+76,15,current_color)
    }
    fit_text(a,detail,x+18,y+104,w-36,14,MUTED)
    graph(a,kind,x+18,y+124,w-36,45)
    text(a,"RECENT ACTIVITY",x+18,y+186,8,MUTED)
    right_text(a,"100%",x+w-18,y+136,8,MUTED)
}
gpu_panel :: proc(a:^App,x,y,w,h:f32) {
    panel(a,x,y,w,h)
    text(a,"GRAPHICS",x+18,y+28,10,SOFT)
    if a.metrics.gpu_count==0 {
        text(a,"No GPU telemetry available",x+18,y+66,17)
        text(a,"CPU and memory remain live.",x+18,y+96,12,MUTED)
        return
    }
    g:=&a.metrics.gpus[0]
    fit_text(a,string(g.name[:g.name_len]),x+18,y+58,w-36,18)
    compact:=w<440
    memory_util:=memory_pct(g.memory_used,g.memory_total)
    memory_color:=utilization_color(memory_util) if g.memory_available else MUTED
    text(a,"Shared allocations" if g.unified_memory else "Dedicated memory",x+18,y+83 if compact else y+88,12 if compact else 14,MUTED)
    right_text(a,fmt.tprintf("%s / %s",bytes_label(g.memory_used),bytes_label(g.memory_total)) if g.memory_available else "Unavailable",x+w-18,y+105 if compact else y+88,14,memory_color)
    bar(a,x+18,y+116 if compact else y+101,w-36,5,memory_util,memory_color)
    cell:=(w-36)/3
    labels:=[3]string{"TEMPERATURE","POWER","FAN"}
    values:=[3]string{fmt.tprintf("%.0f C",g.temperature) if g.temperature_available else "--",fmt.tprintf("%.0f W",g.power_watts) if g.power_available else "--",fmt.tprintf("%.0f %%",g.fan_percent) if g.fan_available else "--"}
    for label,i in labels {
        cx:=x+18+cell*f32(i)
        fit_text(a,label,cx,y+145 if compact else y+135,cell-8,12,MUTED)
        text(a,values[i],cx,y+169 if compact else y+158,20,SOFT)
    }
}
io_panel :: proc(a:^App,x,y,w,h:f32) {
    panel(a,x,y,w,h)
    text(a,"NETWORK & STORAGE",x+18,y+28,10,SOFT)
    labels:=[4]string{"Network receive","Network send","Disk read","Disk write"}
    if w<280 {labels={"Receive","Send","Read","Write"}}
    vals:=[4]f64{a.metrics.network_rx,a.metrics.network_tx,a.metrics.disk_read,a.metrics.disk_write}
    for label,i in labels {
        yy:=y+58+f32(i)*27
        rect(a,x+18,yy-7,4,4,CYAN if i<2 else AMBER)
        text(a,label,x+30,yy,14,MUTED)
        right_text(a,rate_label(vals[i]),x+w-18,yy,14,SOFT)
    }
}
cpu_view :: proc(a:^App) {cpu_dashboard(a)}
gpu_view :: proc(a:^App) {gpu_dashboard(a)}
memory_view :: proc(a:^App) {
    memory_dashboard(a)
}
draw :: proc(a:^App) {
    clear(&a.vertices)
    a.graph_readout.used=false
    a.table_w=0
    a.graph_controls={}
    a.process_freeze_visible=false
    if !renderer_prepare_frame(&a.renderer) {glfw.SetWindowShouldClose(a.renderer.window,true);return}
    fw,fh:=a.renderer.width,a.renderer.height
    ww,wh:=glfw.GetWindowSize(a.renderer.window)
    if fw<=0||fh<=0||ww<=0||wh<=0{return}
    // The compositor owns logical layout dimensions; the framebuffer owns DPI.
    // Do not derive a smaller logical window using the largest axis ratio.
    scale_x,scale_y:=f32(fw)/f32(ww),f32(fh)/f32(wh)
    if math.abs(scale_x-scale_y)>0.01 {a.dirty=true;return}
    a.scale=scale_x
    a.width,a.height=f32(ww),f32(wh)
    when ODIN_OS==.Windows {
        dpi_x,dpi_y:=glfw.GetWindowContentScale(a.renderer.window)
        a.scale=clamp(max(dpi_x,dpi_y),0.5,4)
        a.width,a.height=f32(fw)/a.scale,f32(fh)/a.scale
    }
    if !renderer_set_scale(&a.renderer,a.scale) {glfw.SetWindowShouldClose(a.renderer.window,true);return}
    image,ready,ok:=renderer_acquire_frame(&a.renderer)
    if !ok {glfw.SetWindowShouldClose(a.renderer.window,true);return}
    if !ready {a.dirty=true;return}
    // Input may have arrived during telemetry sampling or the GPU/image wait.
    // Drain it now instead of rendering a marker from the previous mouse event.
    glfw.PollEvents()
    mx,my:=glfw.GetCursorPos(a.renderer.window)
    mx,my=window_ui_position(a,mx,my)
    a.mouse_x,a.mouse_y=f32(mx),f32(my)
    a.content_x=16
    process_menu_handle(a)
    machine_overlay_handle(a)
    rect(a,0,0,a.width,a.height,BG)
    header(a)
    if !machine_connection_draw(a) {
        graph_page_draw(a)
    }
    if !a.graph_readout.used {a.graph_readout.initialized=false;a.graph_readout.active=false}
    process_menu_draw(a)
    machine_overlay_draw(a)
    persistence_message(a)
    graph_freeze_message(a)
    process_freeze_message(a)
    graph_controls_message(a)
    if !renderer_draw(&a.renderer,a.vertices[:],image) {glfw.SetWindowShouldClose(a.renderer.window,true)}
    if cap(a.vertices)>4096&&len(a.vertices)<=cap(a.vertices)/4 {
        a.vertex_small_frames+=1
        if a.vertex_small_frames>=120 {
            compact:=make([dynamic]Vertex,0,max(4096,len(a.vertices)*2))
            if cap(compact)>0 {append(&compact,..a.vertices[:]);delete(a.vertices);a.vertices=compact}
            a.vertex_small_frames=0
        }
    } else {a.vertex_small_frames=0}
    a.frame_count+=1
}

// GLFW uses physical pixel coordinates on Windows; UI layout uses DPI-scaled
// coordinates. Linux compositors already supply logical window/input units.
window_ui_position :: proc(a:^App,x,y:f64)->(f64,f64) {
    when ODIN_OS==.Windows {
        scale_x,scale_y:=glfw.GetWindowContentScale(a.renderer.window)
        scale:=f64(clamp(max(scale_x,scale_y),0.5,4))
        return x/scale,y/scale
    } else {return x,y}
}

mouse_button_callback :: proc "c" (window:glfw.WindowHandle,button,action,mods:i32) {
    context=runtime.default_context()
    a:=cast(^App)glfw.GetWindowUserPointer(window)
    if a==nil {return}
    x,y:=glfw.GetCursorPos(window)
    x,y=window_ui_position(a,x,y)
    if graph_control_pointer(a,button,action,f32(x),f32(y),mods) {return}
    if button==glfw.MOUSE_BUTTON_LEFT {
        if action==glfw.PRESS&&!a.process_menu_open&&machine_pointer_press(a,f32(x),f32(y)) {return}
        if action==glfw.RELEASE&&a.machine_pointer_down {machine_pointer_release(a,f32(x),f32(y));return}
    }
    if action!=glfw.PRESS {return}
    if button==glfw.MOUSE_BUTTON_LEFT {a.pending_click=true}
    a.dirty=true
}

refresh_callback :: proc "c" (window:glfw.WindowHandle) {
    a:=cast(^App)glfw.GetWindowUserPointer(window)
    if a!=nil {a.dirty=true}
}
resize_callback :: proc "c" (window:glfw.WindowHandle,width,height:i32) {
    refresh_callback(window)
}
scale_callback :: proc "c" (window:glfw.WindowHandle,xscale,yscale:f32) {
    refresh_callback(window)
}
scroll_callback :: proc "c" (window:glfw.WindowHandle,xoffset,yoffset:f64) {
    context=runtime.default_context()
    a:=cast(^App)glfw.GetWindowUserPointer(window)
    if a==nil {return}
    if a.machine_dialog {a.machine_dialog_scroll=max(0,a.machine_dialog_scroll-int(yoffset));a.dirty=true;return}
    if a.machine_menu {a.machine_menu_scroll=max(0,a.machine_menu_scroll-int(yoffset));a.dirty=true;return}
    if a.process_menu_open {
        if a.process_menu_kill {a.process_menu_scroll=max(0,a.process_menu_scroll-int(yoffset));a.dirty=true}
        return
    }
    x,y:=glfw.GetCursorPos(window)
    x,y=window_ui_position(a,x,y)
    if a.view==.GPU&&f32(x)>=a.content_x&&f32(x)<a.width-a.content_x&&f32(y)>=72&&f32(y)<a.height-a.content_x {
        in_table:=f32(x)>=a.table_x&&f32(x)<a.table_x+a.table_w&&f32(y)>=a.table_y&&f32(y)<a.table_y+a.table_h
        if in_table {a.process_scroll[int(a.view)]-=f32(yoffset)*36}
        else {a.gpu_scroll-=f32(yoffset)*36}
        a.dirty=true;return
    }
    if f32(x)>=a.table_x&&f32(x)<a.table_x+a.table_w&&f32(y)>=a.table_y&&f32(y)<a.table_y+a.table_h {
        if a.view==.CPU {a.cpu_scroll-=f32(yoffset)*36}
        else if a.view==.Memory {a.memory_scroll-=f32(yoffset)*36}
        else {a.process_scroll[int(a.view)]-=f32(yoffset)*36}
        a.dirty=true
    } else if a.view==.Overview&&f32(y)>=72&&f32(y)<a.height-a.content_x {
        a.overview_scroll-=f32(yoffset)*36
        a.dirty=true
    }
}
cursor_callback :: proc "c" (window:glfw.WindowHandle,x,y:f64) {
    context=runtime.default_context()
    a:=cast(^App)glfw.GetWindowUserPointer(window)
    if a==nil {return}
    ui_x,ui_y:=window_ui_position(a,x,y)
    if graph_control_motion(a,f32(ui_x)) {a.mouse_x,a.mouse_y=f32(ui_x),f32(ui_y);return}
    if graph_control_hovered(a,f32(ui_x),f32(ui_y))>=0||graph_control_hovered(a,a.mouse_x,a.mouse_y)>=0 {a.dirty=true}
    machine_pointer_motion(a,f32(ui_x),f32(ui_y))
    px,pw:=a.persistence_x,a.persistence_w
    persistence_hover:=f32(ui_x)>=px-5&&f32(ui_x)<px+pw+5&&f32(ui_y)>=a.content_x&&f32(ui_y)<a.content_x+28
    was_persistence_hover:=a.mouse_x>=px-5&&a.mouse_x<px+pw+5&&a.mouse_y>=a.content_x&&a.mouse_y<a.content_x+28
    if persistence_hover||was_persistence_hover {a.dirty=true}
    if process_freeze_hovered(a,f32(ui_x),f32(ui_y))||process_freeze_hovered(a,a.mouse_x,a.mouse_y) {a.dirty=true}
    if graph_freeze_hovered(a,f32(ui_x),f32(ui_y))||graph_freeze_hovered(a,a.mouse_x,a.mouse_y) {a.dirty=true}
    if a.process_menu_open {a.mouse_x,a.mouse_y=f32(ui_x),f32(ui_y);a.dirty=true}
    if a.view!=.CPU&&a.view!=.GPU&&a.view!=.Memory {return}
    gx,gy,gw,gh:=a.cpu_graph_x,a.cpu_graph_y,a.cpu_graph_w,a.cpu_graph_h
    was_inside:=a.mouse_x>=gx&&a.mouse_x<=gx+gw&&a.mouse_y>=gy&&a.mouse_y<=gy+gh
    inside:=f32(ui_x)>=gx&&f32(ui_x)<=gx+gw&&f32(ui_y)>=gy&&f32(ui_y)<=gy+gh
    a.mouse_x,a.mouse_y=f32(ui_x),f32(ui_y)
    displayed:=graph_display_state(a)
    pinned:=displayed.memory_pinned_slot if a.view==.Memory else (displayed.gpu_pinned_slot if a.view==.GPU else displayed.cpu_pinned_slot)
    if pinned<0&&(was_inside||inside) {a.dirty=true}
}
main :: proc() {
    platform_process_init()
    for arg in os.args[1:] {
        if arg=="--persistence-service" {
            persistence_headless=true
            persistence_service_main()
            return
        }
    }
    smoke:=false
    show_machines:=false
    stats:=false
    capture_path:string
    initial_view:=View.Overview
    persistence_command:=-1
    for arg in os.args[1:] {
        if arg=="--smoke" {smoke=true}
        else if arg=="--machines" {show_machines=true}
        else if arg=="--stats" {stats=true}
        else if arg=="--startup-profile" {startup_profile=true}
        else if arg=="--persistence=on" {persistence_command=1}
        else if arg=="--persistence=off" {persistence_command=0}
        else if strings.has_prefix(arg,"--capture="){capture_path=arg[len("--capture="):];smoke=true}
        else if arg=="--view=cpu" {initial_view=.CPU}
        else if arg=="--view=gpu" {initial_view=.GPU}
        else if arg=="--view=memory"||arg=="--view=mem+disk" {initial_view=.Memory}
        else if arg=="--view=overview" {initial_view=.Overview}
        else if arg=="--help" {
            fmt.println("task_master: native Odin + Vulkan system monitor\nSpace pause machine | F freeze all graphs | 1-4 views | Ctrl+1-9 / arrows / A D machines | + SSH machines | Esc/Q quit\n--view=overview|cpu|gpu|mem+disk  initial view (memory alias supported)\n--remote=SSH_ALIAS  verify passwordless SSH and connect for this session\n--machines  open the SSH machine picker\n--persistence=on|off  enable or stop background sampling and exit\n--stats  sample telemetry and exit\n--smoke  open the window, sample for 4 seconds, then exit\n--startup-profile  print startup stage timings\n--capture=path.png  save a real GPU-rendered frame and exit")
            return
        }
    }
    boot:=time.tick_now()
    a:=new(App)
    defer free(a)
    machines_init(a)
    defer machines_destroy(a)
    defer delete(a.process_menu_pids)
    graph_settings_load(a)
    defer {if a.graph_settings_pending {graph_settings_save(a)};delete(a.graph_settings_data)}
    a.view=initial_view
    a.process_order[int(View.GPU)].column=.Memory
    a.process_order[int(View.Memory)].column=.Memory
    process_preferences_load(a)
    if !stats {persistence_init(a)}
    a.cpu_pinned_slot=-1
    defer delete(a.process_rows)
    stage:=startup_stage(boot,"app allocation / prefs")
    // Open power counters and drop CAP_PERFMON before either worker or driver
    // starts. Workers inherit the unprivileged main thread's capabilities.
    metrics_init_cpu(&a.metrics)
    defer metrics_destroy(&a.local_machine.state.metrics)
    if persistence_command>=0 {
        if !persistence_service_set(a,persistence_command==1) {
            fmt.eprintln(string(a.persistence_error[:a.persistence_error_len]));os.exit(1)
        }
        fmt.println("Persistence on" if a.persistence_enabled else "Persistence off")
        return
    }
    if stats {
        metrics_init_devices(&a.metrics)
        time.sleep(time.Second)
        metrics_sample(&a.metrics,time.duration_seconds(time.tick_since(a.metrics._sample_started)))
        fmt.printf("%s | CPU %.1f%% (%d cores) | RAM %s / %s | %d processes | %d GPUs\n",a.metrics.hostname,a.metrics.cpu_percent,a.metrics.cpu_count,bytes_label(a.metrics.memory_used),bytes_label(a.metrics.memory_total),a.metrics.total_processes,a.metrics.gpu_count)
        fmt.printf("CPU physical: %d cores / %d online threads | busy %s | frequency %s (%v) | package power %s\n",a.metrics.physical_core_count,a.metrics.cpu_online_count,cpu_range_label(a.metrics.cpu_busy_lower,a.metrics.cpu_busy_upper),fmt.tprintf("%.2f GHz",a.metrics.cpu_frequency_mhz/1000) if a.metrics.cpu_frequency_available else "unavailable",a.metrics.cpu_frequency_source,fmt.tprintf("%.1f W",a.metrics.cpu_power_watts) if a.metrics.cpu_power_available else "unavailable")
        fmt.printf("CPU power: %v | %s\n", a.metrics.cpu_power_source, metrics_cpu_power_status(&a.metrics))
        if a.metrics.cpu_power_permission_denied {fmt.printf("CPU power error: %s\n",string(a.metrics.cpu_power_error[:a.metrics.cpu_power_error_len]))}
        if a.metrics.cpu_power_permission_denied { fmt.println(platform_power_install_hint()) }
        for i in 0..<a.metrics.gpu_count {
            g:=&a.metrics.gpus[i]
            fmt.printf("%s | utilization %.0f%% | %.0f C | %.1f W | %s %s / %s\n",string(g.name[:g.name_len]),g.utilization,g.temperature,g.power_watts,"Shared GPU allocations" if g.unified_memory else "VRAM",bytes_label(g.memory_used),bytes_label(g.memory_total))
        }
        return
    }
    a.vertices=make([dynamic]Vertex,0,4096)
    defer delete(a.vertices)
    metrics_worker:=thread.create(startup_metrics_worker)
    if metrics_worker!=nil {
        metrics_worker.data=&a.metrics
        thread.start(metrics_worker)
    } else {metrics_init_devices(&a.metrics)}
    renderer_ready:=renderer_init(&a.renderer,1180,820,"task_master")
    // Join before reading telemetry, and on failure before cleaning it up.
    if metrics_worker!=nil {thread.join(metrics_worker);thread.destroy(metrics_worker)}
    if !renderer_ready {os.exit(1)}
    stage=startup_stage(stage,"renderer total")
    defer {process_kill_destroy(a.process_kill);a.process_kill=nil;persistence_change_destroy(a);persistence_reader_stop(a);machines_disconnect(a);renderer_destroy(&a.renderer)}
    glfw.SetWindowUserPointer(a.renderer.window,a)
    glfw.SetWindowRefreshCallback(a.renderer.window,refresh_callback)
    glfw.SetFramebufferSizeCallback(a.renderer.window,resize_callback)
    glfw.SetWindowSizeCallback(a.renderer.window,resize_callback)
    glfw.SetWindowContentScaleCallback(a.renderer.window,scale_callback)
    glfw.SetScrollCallback(a.renderer.window,scroll_callback)
    glfw.SetCursorPosCallback(a.renderer.window,cursor_callback)
    glfw.SetCharCallback(a.renderer.window,machine_char_callback)
    glfw.SetKeyCallback(a.renderer.window,machine_key_callback)
    glfw.SetMouseButtonCallback(a.renderer.window,mouse_button_callback)
    a.started=glfw.GetTime()
    machines_load(a)
    machines_discover(a)
    for arg in os.args[1:] {
        if strings.has_prefix(arg,"--remote=") {
            host:=arg[len("--remote="):]
            existing:=machine_find(a,host)
            if existing>=0 {machine_connect(a,a.machines[existing])}
            else {machines_discovery_candidate(a,host,host,DEFAULT_COLLECTOR,0,persistent=false,automatic=false);machines_discovery_start(a)}
        }
    }
    // The counter baseline was collected during graphics startup. Include that
    // time in the first rate interval instead of overstating CPU and I/O rates.
    a.last_sample=a.started-time.duration_seconds(time.tick_since(a.metrics._sample_started))
    persistence_local_startup(a)
    if a.persistence_enabled {
        persistence_reader_start(a)
        _=persistence_change_start(a,refresh=true)
    }
    a.clock_second=time.time_to_unix(time.now())
    if show_machines {machine_dialog_open(a)}
    draw(a)
    stage=startup_stage(stage,"first draw")
    glfw.ShowWindow(a.renderer.window)
    stage=startup_stage(stage,"show window")
    fmt.printf("First frame: %.0f ms | Vulkan: %s | %d GPUs\n",time.duration_seconds(time.tick_since(boot))*1000,a.renderer.device_name,a.metrics.gpu_count)
    for !glfw.WindowShouldClose(a.renderer.window) {
        now:=glfw.GetTime()
        if smoke&&now-a.started>=4 {break}
        mouse:=glfw.GetMouseButton(a.renderer.window,glfw.MOUSE_BUTTON_LEFT)==glfw.PRESS
        a.click=a.graph_control_drag<0&&!a.machine_pointer_down&&(a.pending_click||(mouse&&!a.mouse_down))
        a.pending_click=false
        a.mouse_down=mouse
        mx,my:=glfw.GetCursorPos(a.renderer.window)
        mx,my=window_ui_position(a,mx,my)
        a.mouse_x,a.mouse_y=f32(mx),f32(my)
        persistence_change_poll(a)
        graph_settings_flush(a)
        machines_discovery_poll(a)
        machine_terminal_poll(a)
        machines_sample(a,now)
        graph_catchup_poll(a)
        if a.graph_readout.active {a.dirty=true}
        process_kill_poll(a)
        clock_second:=time.time_to_unix(time.now())
        if clock_second!=a.clock_second {a.clock_second=clock_second;a.dirty=true}
        fw,fh:=glfw.GetFramebufferSize(a.renderer.window)
        if int(fw)!=a.renderer.width||int(fh)!=a.renderer.height {a.dirty=true}
        if capture_path!=""&&now-a.started>=3 {a.renderer.capture_path=capture_path;capture_path="";a.dirty=true}
        if a.click||a.dirty {
            a.dirty=false
            draw(a)
            if a.click {a.click=false;draw(a)}
        }
        a.click=false
        // GLFW blocks between samples; input wakes it immediately.
        local:=a.local_machine.state
        wait:=max(0.01,a.interval-(glfw.GetTime()-local.last_sample))
        if local.paused||a.persistence_enabled {wait=min(1,a.interval)}
        if a.machine_count>1 {wait=min(wait,1)}
        if a.graphs_catching_up||a.graph_readout.active {wait=min(wait,1.0/120)}
        // Wake at the next wall-clock second even when sampling is paused.
        wall_ns:=time.to_unix_nanoseconds(time.now())
        wait=min(wait,f64(1_000_000_000-wall_ns%1_000_000_000)/1e9)
        if a.dirty||a.pending_click {glfw.PollEvents()}
        else {glfw.WaitEventsTimeout(wait)}
        free_all(context.temp_allocator)
    }
    if smoke {fmt.printf("Smoke complete | %d samples / %d frames | CPU %.1f%% | GPU %.0f%% | vertices %d | window %.0fx%.0f @ %.2fx | capture %v\n",a.history_count,a.frame_count,a.metrics.cpu_percent,a.metrics.gpus[0].utilization,len(a.vertices),a.width,a.height,a.scale,a.renderer.capture_success)}
}

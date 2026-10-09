package main

import "core:fmt"
import "core:math"
import "core:time"

// Display snapshots never replace the live sampler or persistence histories.
// A frozen machine owns its copied buffers until resume, removal or shutdown.
graph_freeze_capture :: proc(m:^Machine) {
    graph_freeze_release(m)
    frozen:=new(Machine_State)
    machine_state_init(frozen)
    if m.state!=nil {
        live:=m.state
        metrics_display_copy(&frozen.metrics,&live.metrics)
        frozen.io_summary=live.io_summary
        frozen.history=live.history;frozen.cpu_history=live.cpu_history
        frozen.history_count,frozen.history_next=live.history_count,live.history_next
        frozen.cpu_pinned_slot,frozen.cpu_pinned_graph=live.cpu_pinned_slot,live.cpu_pinned_graph
        frozen.gpu_pinned_slot,frozen.gpu_pinned_graph=live.gpu_pinned_slot,live.gpu_pinned_graph
        frozen.memory_pinned_slot,frozen.memory_pinned_graph=live.memory_pinned_slot,live.memory_pinned_graph
    }
    m.frozen_graphs=frozen
}

graph_freeze_release :: proc(m:^Machine) {
    if m.frozen_graphs==nil {return}
    metrics_destroy(&m.frozen_graphs.metrics)
    graph_smoothing_destroy(m.frozen_graphs.graph_smoothing)
    free(m.frozen_graphs);m.frozen_graphs=nil
}

graph_resume_pin :: proc(live,frozen:^Machine_State,slot:int)->int {
    if slot<0 {return -1}
    timestamp:=frozen.cpu_history[slot].timestamp
    first:=(live.history_next-live.history_count+HISTORY_CAPACITY)%HISTORY_CAPACITY
    for i in 0..<live.history_count {
        candidate:=(first+i)%HISTORY_CAPACITY
        if live.cpu_history[candidate].timestamp==timestamp {return candidate}
    }
    return -1
}

graph_freeze_toggle :: proc(a:^App) {
    if !a.graphs_frozen {
        graph_catchup_finish(a)
        a.graphs_frozen_at=time.time_to_unix(time.now())
        for m in a.machines {graph_freeze_capture(m)}
        a.graphs_frozen=true
    } else {
        for m in a.machines {
            if m.state!=nil&&m.frozen_graphs!=nil {
                live,frozen:=m.state,m.frozen_graphs
                live.cpu_pinned_slot=graph_resume_pin(live,frozen,frozen.cpu_pinned_slot)
                live.gpu_pinned_slot=graph_resume_pin(live,frozen,frozen.gpu_pinned_slot)
                live.memory_pinned_slot=graph_resume_pin(live,frozen,frozen.memory_pinned_slot)
                live.cpu_pinned_graph=frozen.cpu_pinned_graph
                live.gpu_pinned_graph=frozen.gpu_pinned_graph
                live.memory_pinned_graph=frozen.memory_pinned_graph
            }
        }
        a.graphs_frozen=false
        a.graphs_catching_up=true
        a.graph_catchup_started=time.tick_now()
        a.graph_catchup_progress=0
    }
    a.click=false;a.dirty=true
}

GRAPH_CATCHUP_SECONDS :: 0.4

graph_catchup_finish :: proc(a:^App) {
    if !a.graphs_catching_up {return}
    for m in a.machines {graph_freeze_release(m)}
    a.graphs_catching_up=false;a.graph_catchup_progress=1
}

graph_catchup_ease :: proc(t:f32)->f32 {
    remaining:=1-clamp(t,0,1)
    return 1-remaining*remaining*remaining
}

graph_catchup_poll :: proc(a:^App) {
    if !a.graphs_catching_up {return}
    elapsed:=time.duration_seconds(time.tick_since(a.graph_catchup_started))
    a.graph_catchup_progress=graph_catchup_ease(f32(elapsed/GRAPH_CATCHUP_SECONDS))
    if elapsed>=GRAPH_CATCHUP_SECONDS {graph_catchup_finish(a)}
    a.dirty=true
}

Graph_Animation_Plot :: struct {
    live: ^Machine_State,
    start: int,
    shift, left, right: f32,
    clipped: bool,
}

graph_animation_begin :: proc(a:^App,incoming:bool,x,w:f32)->(plot:Graph_Animation_Plot,draw:bool) {
    plot.live=a.machine;plot.start=len(a.vertices)
    frozen:=a.machines[a.active_machine].frozen_graphs
    if !a.graphs_catching_up||frozen==nil {return plot,incoming}
    distance:=f32(1)
    if frozen.history_count>0&&plot.live.history_count>0 {
        old_slot:=(frozen.history_next+HISTORY_CAPACITY-1)%HISTORY_CAPACITY
        new_slot:=(plot.live.history_next+HISTORY_CAPACITY-1)%HISTORY_CAPACITY
        distance=clamp(f32((plot.live.cpu_history[new_slot].timestamp-frozen.cpu_history[old_slot].timestamp)/a.history_seconds),0,1)
    }
    if distance==0 {return plot,incoming}
    seam:=x+w*(1-distance*a.graph_catchup_progress)
    plot.clipped=true
    if incoming {
        plot.shift=w*distance*(1-a.graph_catchup_progress)
        plot.left,plot.right=seam,x+w
    } else {
        plot.shift=-w*distance*a.graph_catchup_progress
        plot.left,plot.right=x,seam
        a.machine=frozen
    }
    return plot,plot.right>plot.left
}

graph_animation_end :: proc(a:^App,plot:Graph_Animation_Plot) {
    a.machine=plot.live
    if !plot.clipped {return}
    // The GPU clips both traces to the plot and their moving seam. UVs stay
    // unchanged, preserving the line antialiasing and height-based fill.
    for &vertex in a.vertices[plot.start:] {
        vertex.pos[0]+=plot.shift*a.scale
        vertex.clip_x={plot.left*a.scale,plot.right*a.scale}
    }
}

Graph_Animation_Axis :: enum { CPU_Power, CPU_Frequency, GPU_Power, GPU_Frequency, GPU_Memory, RAM, Disk, Network }

graph_animation_ceiling :: proc(a:^App,current:f32,axis:Graph_Animation_Axis)->f32 {
    frozen:=a.machines[a.active_machine].frozen_graphs
    if !a.graphs_catching_up||frozen==nil {return current}
    m:=&frozen.metrics
    previous,step:=f32(50),f32(50)
    gpu_power_known:=false
    switch axis {
    case .CPU_Power:
    case .CPU_Frequency:previous,step=6000,1000
    case .GPU_Power:
        gpu_power_known=m.gpus[0].power_max_available
        if gpu_power_known {previous=m.gpus[0].power_max_watts}
    case .GPU_Frequency:previous,step=500,500
    case .GPU_Memory:previous=max(f32(1),f32(math.ceil(f64(m.gpus[0].memory_total)/GPU_MEMORY_GB)))
    case .RAM:previous=memory_capacity_ceiling(m.memory_total)
    case .Disk,.Network:previous=1024
    }
    first:=(frozen.history_next-frozen.history_count+HISTORY_CAPACITY)%HISTORY_CAPACITY
    latest:=(frozen.history_next+HISTORY_CAPACITY-1)%HISTORY_CAPACITY
    for i in 0..<frozen.history_count {
        sample:=&frozen.cpu_history[(first+i)%HISTORY_CAPACITY]
        if frozen.cpu_history[latest].timestamp-sample.timestamp>a.history_seconds {continue}
        value:f32
        available:=false
        switch axis {
        case .CPU_Power:value,available=sample.power_watts,sample.power_available&&sample.generation==m.cpu_topology_generation
        case .CPU_Frequency:value,available=sample.frequency_mhz,sample.frequency_available&&sample.generation==m.cpu_topology_generation
        case .GPU_Power:value,available=sample.gpu.power_watts,sample.gpu.power_available&&!gpu_power_known
        case .GPU_Frequency:value,available=sample.gpu.frequency_mhz,sample.gpu.frequency_available
        case .GPU_Memory,.RAM:
        case .Disk:value,available=f32(max(sample.disk_read,sample.disk_write)),sample.rates_ready
        case .Network:value,available=f32(max(sample.network_rx,sample.network_tx)),sample.network_rates_ready
        }
        if !available {continue}
        if axis==.Disk||axis==.Network {for previous<value {previous*=2}}
        else {previous=max(previous,f32(math.ceil(value/step))*step)}
    }
    return previous+(current-previous)*a.graph_catchup_progress
}

graph_display_state :: proc(a:^App)->^Machine_State {
    m:=a.machines[a.active_machine]
    if a.graphs_frozen&&m.frozen_graphs!=nil {return m.frozen_graphs}
    return m.state
}

graph_page_draw :: proc(a:^App) {
    live:=a.machine
    displayed:=graph_display_state(a)
    if displayed!=live {
        displayed.cpu_scroll,displayed.gpu_scroll=live.cpu_scroll,live.gpu_scroll
        displayed.memory_scroll,displayed.overview_scroll=live.memory_scroll,live.overview_scroll
    }
    a.machine=displayed
    defer {
        live.cpu_scroll,live.gpu_scroll=displayed.cpu_scroll,displayed.gpu_scroll
        live.memory_scroll,live.overview_scroll=displayed.memory_scroll,displayed.overview_scroll
        a.machine=live
    }
    if a.graphs_frozen&&displayed.history_count==0 {
        fit_text(a,"No graph samples at freeze time. Resume to see live graphs.",a.content_x,68,a.width-a.content_x-16,12,SOFT)
    }
    switch a.view {
    case .Overview: overview(a)
    case .CPU: cpu_view(a)
    case .GPU: gpu_view(a)
    case .Memory: memory_view(a)
    }
}

graph_freeze_hovered :: proc(a:^App,x,y:f32)->bool {
    return !a.machine_menu&&!a.machine_dialog&&!a.process_menu_open&&
        x>=a.graph_freeze_x&&x<a.graph_freeze_x+a.graph_freeze_w&&y>=a.content_x&&y<a.content_x+28
}

graph_freeze_control :: proc(a:^App,right:f32)->f32 {
    y:=a.content_x
    compact:=a.width<1100
    label:="Frozen" if a.graphs_frozen else "Freeze"
    w:=f32(28)
    if !compact {w+=renderer_text_width(&a.renderer,label,12*a.scale)/a.scale+10}
    x:=right-w-12
    a.graph_freeze_x,a.graph_freeze_w=x,w
    hovered:=graph_freeze_hovered(a,a.mouse_x,a.mouse_y)
    if hovered&&hit(a,x,y,w,28) {graph_freeze_toggle(a)}
    tint:=CYAN if a.graphs_frozen else (TEXT if hovered else SOFT)
    if hovered||a.graphs_frozen {rounded_rect(a,x,y,w,24,5,LINE)}
    process_snowflake(a,x+14,y+12,tint)
    if !compact {text(a,"Frozen" if a.graphs_frozen else "Freeze",x+34,y+16,12,tint)}
    return x
}

graph_freeze_message :: proc(a:^App) {
    if !graph_freeze_hovered(a,a.mouse_x,a.mouse_y) {return}
    label:="Freeze graphs across all pages and machines / F"
    if a.graphs_frozen {label=fmt.tprintf("Frozen at %s / resume all graphs / F",platform_clock_text(a.graphs_frozen_at))}
    w:=min(a.width-16,renderer_text_width(&a.renderer,label,12*a.scale)/a.scale+24)
    x:=clamp(a.graph_freeze_x,8,max(8,a.width-w-8))
    panel(a,x,a.content_x+36,w,30)
    fit_text(a,label,x+12,a.content_x+56,w-24,12,SOFT)
}

history_end_label :: proc(a:^App)->string {
    return "Frozen" if a.graphs_frozen else "Now"
}

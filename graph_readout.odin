package main

import "core:math"
import "core:time"

GRAPH_READOUT_SECONDS :: 0.14
GRAPH_READOUT_FAST_SECONDS :: 0.56

// Only display values are eased. The history, cursor time and pinned sample
// remain exact, and live sampling does not start an animation on its own.
Graph_Readout :: struct {
    machine: ^Machine_State,
    view: View,
    initialized, inspecting, active, used: bool,
    advanced, motion_updated: time.Tick,
    progress, duration, pointer_x, pointer_speed: f32,
    pointer_ready: bool,
    from, target, current: CPU_Sample,
}

graph_readout_bytes :: proc(from,to:u64,t:f32)->u64 {
    return u64(math.round(f64(from)+(f64(to)-f64(from))*f64(t)))
}

graph_readout_motion :: proc(r:^Graph_Readout,x,width:f32,scrubbing:bool) {
    r.duration=GRAPH_READOUT_SECONDS
    if !scrubbing||width<=0 {
        r.pointer_ready=false;r.pointer_speed=0
        return
    }
    if !r.pointer_ready {
        r.pointer_x=x;r.motion_updated=time.tick_now();r.pointer_ready=true
        return
    }
    elapsed:=time.duration_seconds(time.tick_since(r.motion_updated))
    if elapsed<=0 {return}
    // Measure horizontal travel in graph widths/second. Filter event timing
    // noise, and let the speed decay on animation frames when movement stops.
    speed:=min(f32(abs(f64(x-r.pointer_x)/f64(width))/max(elapsed,0.001)),4)
    blend:=f32(1-math.exp(-elapsed/0.06))
    r.pointer_speed+=(speed-r.pointer_speed)*blend
    r.pointer_x=x;r.motion_updated=time.tick_now()
    amount:=clamp((r.pointer_speed-0.25)/1.75,0,1)
    amount=amount*amount*(3-2*amount)
    r.duration=GRAPH_READOUT_SECONDS+(GRAPH_READOUT_FAST_SECONDS-GRAPH_READOUT_SECONDS)*amount
}

graph_readout_advance :: proc(r:^Graph_Readout) {
    if !r.active {return}
    elapsed:=time.duration_seconds(time.tick_since(r.advanced))
    r.advanced=time.tick_now()
    // Integrate progress so changing speed cannot jump or reverse an easing
    // already in flight. Slowing/stopping promptly catches up to the sample.
    r.progress=clamp(r.progress+f32(elapsed)/max(r.duration,GRAPH_READOUT_SECONDS),0,1)
    if r.progress>=1 {r.current=r.target;r.active=false;return}
    t:=graph_catchup_ease(r.progress)
    from,to,s:=&r.from,&r.target,&r.current
    s^=to^
    s.lower=from.lower+(to.lower-from.lower)*t
    s.upper=from.upper+(to.upper-from.upper)*t
    s.threads=from.threads+(to.threads-from.threads)*t
    if from.power_available&&to.power_available {s.power_watts=from.power_watts+(to.power_watts-from.power_watts)*t}
    if from.frequency_available&&to.frequency_available {s.frequency_mhz=from.frequency_mhz+(to.frequency_mhz-from.frequency_mhz)*t}
    for &core,i in s.cores {
        first,last:=&from.cores[i],&to.cores[i]
        core.lower=first.lower+(last.lower-first.lower)*t
        core.upper=first.upper+(last.upper-first.upper)*t
        if first.frequency_available&&last.frequency_available {core.frequency_mhz=first.frequency_mhz+(last.frequency_mhz-first.frequency_mhz)*t}
    }
    for &logical,i in s.logical {logical=from.logical[i]+(to.logical[i]-from.logical[i])*t}
    if from.ram_available&&to.ram_available {
        s.memory_used=graph_readout_bytes(from.memory_used,to.memory_used,t)
        s.memory_available=graph_readout_bytes(from.memory_available,to.memory_available,t)
        if from.swap_total>0&&to.swap_total>0 {s.swap_used=graph_readout_bytes(from.swap_used,to.swap_used,t)}
        if (from.memory_free_available||from.memory_breakdown_available)&&(to.memory_free_available||to.memory_breakdown_available) {s.memory_free=graph_readout_bytes(from.memory_free,to.memory_free,t)}
        if (from.memory_cached_available||from.memory_breakdown_available)&&(to.memory_cached_available||to.memory_breakdown_available) {s.memory_cached=graph_readout_bytes(from.memory_cached,to.memory_cached,t)}
        if (from.memory_buffers_available||from.memory_breakdown_available)&&(to.memory_buffers_available||to.memory_breakdown_available) {s.memory_buffers=graph_readout_bytes(from.memory_buffers,to.memory_buffers,t)}
    }
    if from.rates_ready&&to.rates_ready {
        s.disk_read=from.disk_read+(to.disk_read-from.disk_read)*f64(t)
        s.disk_write=from.disk_write+(to.disk_write-from.disk_write)*f64(t)
    }
    if from.network_rates_ready&&to.network_rates_ready {
        s.network_rx=from.network_rx+(to.network_rx-from.network_rx)*f64(t)
        s.network_tx=from.network_tx+(to.network_tx-from.network_tx)*f64(t)
    }
    g0,g1,g:=&from.gpu,&to.gpu,&s.gpu
    if g0.utilization_available&&g1.utilization_available {g.utilization=g0.utilization+(g1.utilization-g0.utilization)*t}
    if g0.memory_available&&g1.memory_available {
        g.memory_used=graph_readout_bytes(g0.memory_used,g1.memory_used,t)
        g.memory_percent=g0.memory_percent+(g1.memory_percent-g0.memory_percent)*t
    }
    if g0.power_available&&g1.power_available {g.power_watts=g0.power_watts+(g1.power_watts-g0.power_watts)*t}
    if g0.frequency_available&&g1.frequency_available {g.frequency_mhz=g0.frequency_mhz+(g1.frequency_mhz-g0.frequency_mhz)*t}
    if g0.temperature_available&&g1.temperature_available {g.temperature=g0.temperature+(g1.temperature-g0.temperature)*t}
    if g0.fan_available&&g1.fan_available {g.fan_percent=g0.fan_percent+(g1.fan_percent-g0.fan_percent)*t}
}

graph_readout_sample :: proc(a:^App,target:^CPU_Sample,inspecting,scrubbing:bool,plot_width:f32)->^CPU_Sample {
    r:=&a.graph_readout
    r.used=true
    // A page/machine/topology change has unrelated values; initialize its own
    // readout immediately rather than animating from the previous dashboard.
    if !r.initialized||r.machine!=a.machine||r.view!=a.view||r.target.generation!=target.generation {
        r.machine,r.view=a.machine,a.view
        r.initialized=true;r.active=false;r.inspecting=inspecting
        r.pointer_ready=false;r.pointer_speed=0
        graph_readout_motion(r,a.mouse_x,plot_width,scrubbing)
        r.from,r.target,r.current=target^,target^,target^
        return &r.current
    }
    graph_readout_motion(r,a.mouse_x,plot_width,scrubbing)
    graph_readout_advance(r)
    if r.target.timestamp!=target.timestamp {
        r.from,r.target=r.current,target^
        r.active=inspecting||r.inspecting||r.active
        r.progress=0;r.advanced=time.tick_now()
        // Retarget from the value already on screen even during fast scrubbing.
        // Apply availability flags immediately so missing sensors remain '--'.
        if r.active {graph_readout_advance(r)}
        else {r.current=target^}
    }
    r.inspecting=inspecting
    return &r.current
}

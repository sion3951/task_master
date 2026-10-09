package main

import "core:math"

// Polling changes the density of the trace, not its smoothing time scale.
// These display buffers never replace recorded samples or inspection values.
Graph_Smoothing :: struct {
    cpu_history: [HISTORY_CAPACITY]CPU_Sample,
    history: [4][HISTORY_CAPACITY]f32,
    initialized: bool,
    latest_slot: int,
    latest_timestamp: f64,
    history_count: int,
    first_timestamp: f64,
}

graph_smoothing_destroy :: proc(s:^Graph_Smoothing) {
    if s!=nil {free(s)}
}

graph_smoothing_bytes :: proc(previous,current:u64,alpha:f32)->u64 {
    return u64(math.round(f64(previous)+(f64(current)-f64(previous))*f64(alpha)))
}

graph_smoothing_append :: proc(a:^App,cache:^Graph_Smoothing,slot:int,previous_slot:int) {
    raw:=&a.cpu_history[slot]
    current:=&cache.cpu_history[slot]
    current^=raw^
    for kind in 0..<4 {cache.history[kind][slot]=a.history[kind][slot]}
    if previous_slot<0 {return}
    previous:=&cache.cpu_history[previous_slot]
    dt:=raw.timestamp-previous.timestamp
    if !history_segment_contiguous(previous,raw) {return}
    // Exactly preserve the established 1-second trace. Faster acquisition
    // advances the display each sample, with elapsed-time weighted smoothing.
    alpha:=f32(clamp(dt,0,1))
    if raw.polling_seconds>=1||raw.polling_seconds<=0 {alpha=1}
    if alpha>=1 {return}
    same_topology:=previous.generation==raw.generation
    if same_topology {
        current.lower=previous.lower+(raw.lower-previous.lower)*alpha
        current.upper=previous.upper+(raw.upper-previous.upper)*alpha
        current.threads=previous.threads+(raw.threads-previous.threads)*alpha
        if previous.power_available&&raw.power_available {current.power_watts=previous.power_watts+(raw.power_watts-previous.power_watts)*alpha}
        if previous.frequency_available&&raw.frequency_available {current.frequency_mhz=previous.frequency_mhz+(raw.frequency_mhz-previous.frequency_mhz)*alpha}
        for &core,i in current.cores[:a.metrics.physical_core_count] {
            p,r:=&previous.cores[i],&raw.cores[i]
            core.lower=p.lower+(r.lower-p.lower)*alpha
            core.upper=p.upper+(r.upper-p.upper)*alpha
            if p.frequency_available&&r.frequency_available {core.frequency_mhz=p.frequency_mhz+(r.frequency_mhz-p.frequency_mhz)*alpha}
        }
        for &logical,i in current.logical[:a.metrics.cpu_count] {logical=previous.logical[i]+(raw.logical[i]-previous.logical[i])*alpha}
    }
    if previous.ram_available&&raw.ram_available&&previous.memory_total==raw.memory_total {
        current.memory_used=graph_smoothing_bytes(previous.memory_used,raw.memory_used,alpha)
        current.memory_available=graph_smoothing_bytes(previous.memory_available,raw.memory_available,alpha)
        if previous.swap_total>0&&previous.swap_total==raw.swap_total {current.swap_used=graph_smoothing_bytes(previous.swap_used,raw.swap_used,alpha)}
        if (previous.memory_free_available||previous.memory_breakdown_available)&&(raw.memory_free_available||raw.memory_breakdown_available) {current.memory_free=graph_smoothing_bytes(previous.memory_free,raw.memory_free,alpha)}
        if (previous.memory_cached_available||previous.memory_breakdown_available)&&(raw.memory_cached_available||raw.memory_breakdown_available) {current.memory_cached=graph_smoothing_bytes(previous.memory_cached,raw.memory_cached,alpha)}
        if (previous.memory_buffers_available||previous.memory_breakdown_available)&&(raw.memory_buffers_available||raw.memory_breakdown_available) {current.memory_buffers=graph_smoothing_bytes(previous.memory_buffers,raw.memory_buffers,alpha)}
    }
    if previous.rates_ready&&raw.rates_ready {
        current.disk_read=previous.disk_read+(raw.disk_read-previous.disk_read)*f64(alpha)
        current.disk_write=previous.disk_write+(raw.disk_write-previous.disk_write)*f64(alpha)
    }
    if previous.network_rates_ready&&raw.network_rates_ready {
        current.network_rx=previous.network_rx+(raw.network_rx-previous.network_rx)*f64(alpha)
        current.network_tx=previous.network_tx+(raw.network_tx-previous.network_tx)*f64(alpha)
    }
    pg,rg,g:=&previous.gpu,&raw.gpu,&current.gpu
    if pg.legacy==rg.legacy {
        if pg.utilization_available&&rg.utilization_available {g.utilization=pg.utilization+(rg.utilization-pg.utilization)*alpha}
        if pg.memory_available&&rg.memory_available&&pg.memory_total==rg.memory_total {
            g.memory_used=graph_smoothing_bytes(pg.memory_used,rg.memory_used,alpha)
            g.memory_percent=pg.memory_percent+(rg.memory_percent-pg.memory_percent)*alpha
        }
        if pg.power_available&&rg.power_available {g.power_watts=pg.power_watts+(rg.power_watts-pg.power_watts)*alpha}
        if pg.frequency_available&&rg.frequency_available {g.frequency_mhz=pg.frequency_mhz+(rg.frequency_mhz-pg.frequency_mhz)*alpha}
    }
    // Overview uses normalized values, but shares the same filter cadence and
    // availability boundaries as the detailed plots.
    available:=[4]bool{same_topology,pg.utilization_available&&rg.utilization_available,
        previous.ram_available&&raw.ram_available&&previous.memory_total==raw.memory_total,
        pg.memory_available&&rg.memory_available&&pg.memory_total==rg.memory_total}
    for kind in 0..<4 {
        if available[kind] {cache.history[kind][slot]=cache.history[kind][previous_slot]+(a.history[kind][slot]-cache.history[kind][previous_slot])*alpha}
    }
}

graph_smoothing_prepare :: proc(a:^App)->^Graph_Smoothing {
    if a.graph_smoothing==nil {a.graph_smoothing=new(Graph_Smoothing)}
    cache:=a.graph_smoothing
    if a.history_count<=0 {cache.initialized=false;return cache}
    latest:=(a.history_next+HISTORY_CAPACITY-1)%HISTORY_CAPACITY
    latest_timestamp:=a.cpu_history[latest].timestamp
    first:=(a.history_next-a.history_count+HISTORY_CAPACITY)%HISTORY_CAPACITY
    first_timestamp:=a.cpu_history[first].timestamp
    if cache.initialized&&cache.latest_slot==latest&&cache.latest_timestamp==latest_timestamp&&cache.history_count==a.history_count&&cache.first_timestamp==first_timestamp {return cache}
    start,previous_slot:=first,-1
    // Reuse previous filtered points while the source ring still contains the
    // last processed sample. Normal polling therefore filters only new data.
    appended:=(latest-cache.latest_slot+HISTORY_CAPACITY)%HISTORY_CAPACITY
    if cache.initialized&&latest_timestamp>cache.latest_timestamp&&first_timestamp>=cache.first_timestamp&&a.history_count<=cache.history_count+appended&&a.cpu_history[cache.latest_slot].timestamp==cache.latest_timestamp {
        start=(cache.latest_slot+1)%HISTORY_CAPACITY
        previous_slot=cache.latest_slot
    }
    slot:=start
    for _ in 0..<a.history_count {
        graph_smoothing_append(a,cache,slot,previous_slot)
        if slot==latest {break}
        previous_slot=slot
        slot=(slot+1)%HISTORY_CAPACITY
    }
    cache.initialized=true;cache.latest_slot=latest;cache.latest_timestamp=latest_timestamp
    cache.history_count=a.history_count;cache.first_timestamp=first_timestamp
    return cache
}

graph_plot_sample :: proc(a:^App,slot:int)->^CPU_Sample {
    return &a.graph_smoothing.cpu_history[slot]
}

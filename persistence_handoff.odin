package main

import "core:fmt"
import "core:time"

// The desktop has already sampled the hardware before opening its window.
// Keep that sampler live until a current service snapshot can take ownership.
persistence_local_handoff_pending: bool
persistence_local_handoff_after: f64

persistence_local_startup :: proc(a: ^App) {
    local := a.local_machine
    local.has_sample = true
    local.status = .Live
    local.received = a.metrics._sample_started
}

persistence_local_handoff_start :: proc(a: ^App) {
    local := a.local_machine.state
    if local.history_count==0 {local.history_handoff_pending=true}
    if !persistence_local_captured {
        persistence_local_nvml = local.metrics.nvml_available
        persistence_local_gpu_count = local.metrics.gpu_count
        persistence_local_power_source = local.metrics.cpu_power_source
        persistence_local_captured = true
    }
    persistence_local_handoff_pending = true
    persistence_local_handoff_after = persistence_wall_time()-time.duration_seconds(time.tick_since(local.metrics._sample_started))
}

persistence_local_snapshot_ready :: proc(a: ^App, m: ^Machine, result: ^Persistence_Read_Result) -> bool {
    if m != a.local_machine || !persistence_local_handoff_pending { return true }
    // A heartbeat alone is insufficient: an old snapshot can be republished
    // while the service restarts. Do not replace freshly detected GPU data
    // with an older daemon's unavailable-device snapshot.
    wall := persistence_wall_time()
    if !result.has_sample || result.sampled_at < persistence_local_handoff_after ||
        result.sampled_at > wall+2 || wall-result.sampled_at > persistence_freshness_seconds(a) ||
        persistence_local_gpu_count > 0 && (!result.metrics.nvml_available || result.metrics.gpu_count == 0) {
        return false
    }
    persistence_local_handoff_pending = false
    m.state.history_handoff_pending = false
    metrics_suspend_devices(&m.state.metrics)
    if startup_profile {
        fmt.printf("Persistence local handoff: %.0f ms | %d GPUs\n",(wall-persistence_local_handoff_after)*1000,result.metrics.gpu_count)
    }
    return true
}

package main

import "core:fmt"
import "core:time"
import "core:thread"

startup_profile: bool

startup_stage :: proc(start: time.Tick, label: string) -> time.Tick {
    end := time.tick_now()
    if startup_profile {
        fmt.printf("Startup %-24s %.2f ms\n", label, time.duration_seconds(time.tick_diff(start,end))*1000)
    }
    return end
}

startup_metrics_worker :: proc(worker: ^thread.Thread) {
    metrics_init_devices(cast(^Metrics)worker.data)
}

startup_font_worker :: proc(worker: ^thread.Thread) {
    atlas:=cast(^Font_Atlas)worker.data
    atlas.ready=renderer_font_rasterize(atlas)
}

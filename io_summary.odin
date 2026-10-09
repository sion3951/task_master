package main

import "core:fmt"

// Disk read/write and network receive/transmit, accumulated by the persistence
// sampler independently of the rolling graph history.
IO_Summary :: struct {
    started_at, sampled_at, polling_seconds: f64,
    totals, max_rates: [4]f64,
    available: [4]bool,
}

io_summary_sample :: proc(summary:^IO_Summary,sample:^CPU_Sample,session:f64) {
    if session<=0||sample.timestamp<session {return}
    if summary.started_at!=session {summary^=IO_Summary{started_at=session}}
    if sample.timestamp<=summary.sampled_at {return}
    elapsed:=min(sample.polling_seconds,sample.timestamp-session)
    if summary.sampled_at>0 {
        elapsed=sample.timestamp-max(summary.sampled_at,session)
        if sample.gap_before||!history_handoff_contiguous(summary.sampled_at,sample.timestamp,summary.polling_seconds,sample.polling_seconds) {elapsed=0}
    }
    rates:=[4]f64{sample.disk_read,sample.disk_write,sample.network_rx,sample.network_tx}
    for rate,i in rates {
        ready:=sample.rates_ready if i<2 else sample.network_rates_ready
        if !ready {continue}
        summary.available[i]=true
        summary.totals[i]+=rate*max(0,elapsed)
        summary.max_rates[i]=max(summary.max_rates[i],rate)
    }
    summary.sampled_at=sample.timestamp
    summary.polling_seconds=sample.polling_seconds
}

io_summary_valid :: proc(summary:IO_Summary)->bool {
    if !remote_nonnegative(summary.started_at)||!remote_nonnegative(summary.sampled_at)||
        !remote_nonnegative(summary.polling_seconds)||summary.polling_seconds>10 {return false}
    for value in summary.totals {if !remote_nonnegative(value) {return false}}
    for value in summary.max_rates {if !remote_nonnegative(value) {return false}}
    return true
}

io_summary_apply :: proc(state:^Machine_State,summary:IO_Summary) {
    current:=&state.io_summary
    // The full-history and live readers finish independently. An older cache
    // must never undo a session reset or decrease the current totals.
    if summary.started_at<current.started_at||
        summary.started_at==current.started_at&&summary.sampled_at<current.sampled_at {return}
    current^=summary
}

io_total_label :: proc(value:f64)->string {
    if value>=1099511627776 {return fmt.tprintf("%.1f TiB",value/1099511627776)}
    if value>=1073741824 {return fmt.tprintf("%.1f GiB",value/1073741824)}
    if value>=1048576 {return fmt.tprintf("%.0f MiB",value/1048576)}
    return fmt.tprintf("%.0f KiB",value/1024)
}

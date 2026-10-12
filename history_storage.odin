package main

history_storage_trim :: proc(state:^Machine_State) {
    if state!=nil {history_storage_trim_samples(state.cpu_history[:],state.history_count,state.history_next)}
}

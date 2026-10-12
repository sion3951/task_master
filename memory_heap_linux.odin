#+build linux
package main

import "core:sys/posix"
import "core:sync"
import "core:time"

linux_heap_trim: proc "c" (uintptr)->i32
linux_heap_trim_mutex: sync.Mutex
linux_heap_trim_at: time.Tick

// Resolve before workers start. Other Linux allocators can omit this extension.
platform_memory_init :: proc() {
    linux_heap_trim=cast(proc "c" (uintptr)->i32)posix.dlsym(nil,"malloc_trim")
}

// Return already-freed startup/JSON scratch to the OS. Avoid arena scans in the
// frame/sample hot path, and serialize/throttle the background publishers.
platform_memory_release :: proc(force:bool=false) {
    if linux_heap_trim==nil||!sync.mutex_try_lock(&linux_heap_trim_mutex) {return}
    defer sync.mutex_unlock(&linux_heap_trim_mutex)
    if !force&&time.tick_since(linux_heap_trim_at)<30*time.Second {return}
    linux_heap_trim_at=time.tick_now()
    _=linux_heap_trim(0)
}

#+build linux
package main

foreign import history_storage_libc "system:c"
foreign history_storage_libc {
    @(link_name="madvise") history_storage_madvise :: proc(rawptr,uintptr,i32)->i32 ---
    @(link_name="getpagesize") history_storage_pagesize :: proc()->i32 ---
}

// CPU_Sample owns no heap buffers. Its inactive slots can be discarded without
// changing ring indices or retained samples. These large calloc-backed rings are
// private anonymous memory on Linux; DONTNEED returns these pages to the kernel
// and subsequent accesses see zeroes. Only complete pages strictly inside an
// inactive span are advised, leaving allocator metadata and adjacent data alone.
// Call with exclusive ownership: the UI owns live rings, and publishers trim
// their independent snapshots before handing them to the worker. Smoothing
// and persistence merge scratch follow the same exclusive-owner rule.
history_storage_trim_samples :: proc(samples:[]CPU_Sample,count,next:int) {
    capacity:=len(samples)
    if capacity==0||count<0||count>=capacity||next<0||next>=capacity {return}
    system_page_size:=history_storage_pagesize()
    if system_page_size<=0 {return}
    page_size:=uintptr(system_page_size)
    first:=(next-count+capacity)%capacity
    base:=uintptr(&samples[0])
    stride:=uintptr(size_of(CPU_Sample))
    trim_span :: proc(base,stride,page_size:uintptr,first,last:int) {
        if first>=last {return}
        start:=base+uintptr(first)*stride
        end:=base+uintptr(last)*stride
        // Round inward: no page can contain even a byte of an active sample or
        // of the fields surrounding the ring in its owning allocation.
        start=((start+page_size-1)/page_size)*page_size
        end=(end/page_size)*page_size
        if start<end {_=history_storage_madvise(rawptr(start),end-start,4)} // MADV_DONTNEED
    }
    if count==0 {
        trim_span(base,stride,page_size,0,capacity)
    } else if next<first {
        trim_span(base,stride,page_size,next,first)
    } else {
        trim_span(base,stride,page_size,next,capacity)
        trim_span(base,stride,page_size,0,first)
    }
}

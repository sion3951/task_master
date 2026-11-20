package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

// The sampler transfers complete, independent heap snapshots. JSON and disk
// work never holds this mutex or accesses live machine/sensor state.
Persistence_Publish_Job :: struct {
    machine: Machine,
    cancelled: bool,
    // Also refresh the durable copy. Replacement snapshots inherit the flag.
    durable: bool,
    retry_after: time.Tick,
    shutdown_attempts: int,
    // Consecutive failures for this identity, kept across replacement
    // snapshots so a full or unwritable disk backs off and logs once.
    failures: int,
}
Persistence_Publisher :: struct {
    worker: ^thread.Thread,
    mutex: sync.Mutex,
    // Signalled for new jobs and shutdown; the idle worker does not poll.
    wake: sync.Cond,
    stop: bool,
    live: bool,
    pending, spare: [dynamic]^Persistence_Publish_Job,
    inflight: ^Persistence_Publish_Job,
}

persistence_publish_identity_equal :: proc(a,b:^Machine)->bool {
    return a.host_len==b.host_len&&a.host==b.host&&a.port==b.port&&
        a.collector_len==b.collector_len&&a.collector==b.collector
}
persistence_publish_job_destroy :: proc(job:^Persistence_Publish_Job) {
    if job==nil {return}
    metrics_destroy(&job.machine.state.metrics)
    free(job.machine.state)
    free(job)
}
persistence_publisher_start :: proc(live:bool=false)->^Persistence_Publisher {
    publisher:=new(Persistence_Publisher)
    publisher.live=live
    publisher.worker=thread.create_and_start_with_poly_data(publisher,persistence_publisher_worker,name="Persistence live publisher" if live else "Persistence cache publisher")
    if publisher.worker==nil {free(publisher);return nil}
    return publisher
}

persistence_publisher_submit :: proc(publisher:^Persistence_Publisher,m:^Machine,durable:bool=false) {
    job:^Persistence_Publish_Job
    durable:=durable
    sync.mutex_lock(&publisher.mutex)
    // Replace an unpublished snapshot first; there is never a queue of older
    // histories for the same machine, even when publication is slower than 1 Hz.
    for candidate,i in publisher.pending {
        if persistence_publish_identity_equal(&candidate.machine,m) {
            job=candidate;durable=durable||candidate.durable;ordered_remove(&publisher.pending,i);break
        }
    }
    if job==nil {
        for candidate,i in publisher.spare {
            if persistence_publish_identity_equal(&candidate.machine,m) {
                job=candidate;ordered_remove(&publisher.spare,i);break
            }
        }
    }
    sync.mutex_unlock(&publisher.mutex)
    if job==nil {job=new(Persistence_Publish_Job);job.machine.state=new(Machine_State)}
    state:=job.machine.state
    job.machine=Machine{state=state,name=m.name,name_len=m.name_len,host=m.host,host_len=m.host_len,
        collector=m.collector,collector_len=m.collector_len,port=m.port,status=m.status,
        message=m.message,message_len=m.message_len,has_sample=m.has_sample}
    if publisher.live {
        count:=min(m.state.history_count,PERSISTENCE_LIVE_SAMPLES)
        first:=(m.state.history_next-count+HISTORY_CAPACITY)%HISTORY_CAPACITY
        for offset in 0..<count {
            slot:=(first+offset)%HISTORY_CAPACITY
            state.cpu_history[offset]=m.state.cpu_history[slot]
            for kind in 0..<4 {state.history[kind][offset]=m.state.history[kind][slot]}
        }
        state.history_count=count;state.history_next=count%HISTORY_CAPACITY
    } else {
        // Preserve ring indices while touching only populated samples. On Linux
        // copying unused calloc-backed slots commits the entire maximum ring.
        first:=(m.state.history_next-m.state.history_count+HISTORY_CAPACITY)%HISTORY_CAPACITY
        for offset in 0..<m.state.history_count {
            slot:=(first+offset)%HISTORY_CAPACITY
            state.cpu_history[slot]=m.state.cpu_history[slot]
            for kind in 0..<4 {state.history[kind][slot]=m.state.history[kind][slot]}
        }
        state.history_count=m.state.history_count;state.history_next=m.state.history_next
    }
    history_storage_trim(state)
    metrics_display_copy(&state.metrics,&m.state.metrics)
    state.io_summary=m.state.io_summary
    sync.atomic_store(&job.cancelled,false)
    job.durable=durable
    // A replacement snapshot waits out an active failure backoff.
    if job.failures==0 {job.retry_after={}}
    job.shutdown_attempts=0
    retired:^Persistence_Publish_Job
    sync.mutex_lock(&publisher.mutex)
    // A failed in-flight write can enqueue its retry during the heap copy.
    // The freshly captured history supersedes that retry as well.
    for candidate,i in publisher.pending {
        if persistence_publish_identity_equal(&candidate.machine,m) {
            retired=candidate;job.durable=job.durable||candidate.durable;ordered_remove(&publisher.pending,i)
            if candidate.failures>job.failures {job.failures=candidate.failures;job.retry_after=candidate.retry_after}
            break
        }
    }
    append(&publisher.pending,job)
    sync.cond_signal(&publisher.wake)
    sync.mutex_unlock(&publisher.mutex)
    persistence_publish_job_destroy(retired)
}

persistence_publisher_reconcile :: proc(publisher:^Persistence_Publisher,a:^App) {
    retired: [dynamic]^Persistence_Publish_Job
    sync.mutex_lock(&publisher.mutex)
    if publisher.inflight!=nil {
        keep:=false
        for m in a.machines {if persistence_publish_identity_equal(&publisher.inflight.machine,m) {keep=true;break}}
        if !keep {sync.atomic_store(&publisher.inflight.cancelled,true)}
    }
    queues:=[2]^[dynamic]^Persistence_Publish_Job{&publisher.pending,&publisher.spare}
    for queue in queues {
        for i:=len(queue^)-1;i>=0;i-=1 {
            job:=queue^[i]
            keep:=false
            for m in a.machines {if persistence_publish_identity_equal(&job.machine,m) {keep=true;break}}
            if !keep {append(&retired,job);ordered_remove(queue,i)}
        }
    }
    sync.mutex_unlock(&publisher.mutex)
    for job in retired {persistence_publish_job_destroy(job)}
    delete(retired)
}

persistence_publisher_worker :: proc(publisher:^Persistence_Publisher) {
    for {
        job:^Persistence_Publish_Job
        sync.mutex_lock(&publisher.mutex)
        stopping:=publisher.stop
        // Sleep until a submission, shutdown, or the earliest failed-write retry.
        wait:=time.Duration(-1)
        for candidate,i in publisher.pending {
            remaining:=-time.tick_since(candidate.retry_after)
            if stopping||remaining<=0 {
                job=candidate;ordered_remove(&publisher.pending,i);publisher.inflight=job;break
            }
            if wait<0||remaining<wait {wait=remaining}
        }
        drained:=stopping&&job==nil&&len(publisher.pending)==0
        if job==nil&&!drained {_=sync.cond_wait_with_timeout(&publisher.wake,&publisher.mutex,wait if wait>=0 else time.Second)}
        sync.mutex_unlock(&publisher.mutex)
        if drained {break}
        if job==nil {continue}
        if stopping {job.shutdown_attempts+=1}
        success:=false
        if !sync.atomic_load(&job.cancelled) {
            success=persistence_cache_write(nil,&job.machine,publisher.live,job.durable)
        }
        failed_name:=job.machine.name
        failed_name_len:=job.machine.name_len
        mem.free_all(context.temp_allocator)
        if !publisher.live {platform_memory_release()}
        sync.mutex_lock(&publisher.mutex)
        publisher.inflight=nil
        cancelled:=sync.atomic_load(&job.cancelled)
        // A newer queued snapshot supersedes a failed write's retry.
        newer:=false
        for candidate in publisher.pending {
            if persistence_publish_identity_equal(&candidate.machine,&job.machine) {newer=true;break}
        }
        retired:^Persistence_Publish_Job
        // Shutdown drains the final history with at most two retries. A signal
        // interrupting the first write must not silently discard the last batch.
        if publisher.stop&&job.shutdown_attempts==0 {job.shutdown_attempts=1}
        retry_allowed:=!publisher.stop||job.shutdown_attempts<3
        report:=!success&&!cancelled&&job.failures==0
        if success {job.failures=0} else if !cancelled {job.failures+=1}
        if !cancelled&&!success&&retry_allowed&&!newer {
            job.retry_after=time.tick_add(time.tick_now(),time.Duration(1<<uint(min(job.failures-1,5)))*time.Second)
            append(&publisher.pending,job)
        } else if !cancelled {
            for candidate,i in publisher.spare {
                if persistence_publish_identity_equal(&candidate.machine,&job.machine) {
                    retired=candidate;ordered_remove(&publisher.spare,i);break
                }
            }
            append(&publisher.spare,job)
        }
        sync.mutex_unlock(&publisher.mutex)
        if report {
            fmt.eprintf("Could not publish persistence %s cache for %s; retrying with backoff\n","live" if publisher.live else "history",string(failed_name[:failed_name_len]))
        }
        if cancelled {
            // Reconciliation can remove a machine while its file is written.
            // The sole writer removes that retired identity after finishing.
            _=os.remove(persistence_cache_path(&job.machine,publisher.live))
            if !publisher.live {_=os.remove(persistence_cache_path(&job.machine,durable=true))}
            persistence_publish_job_destroy(job)
        }
        persistence_publish_job_destroy(retired)
        mem.free_all(context.temp_allocator)
    }
}

persistence_publisher_destroy :: proc(publisher:^Persistence_Publisher) {
    if publisher==nil {return}
    sync.mutex_lock(&publisher.mutex)
    publisher.stop=true
    sync.cond_signal(&publisher.wake)
    sync.mutex_unlock(&publisher.mutex)
    thread.join(publisher.worker);thread.destroy(publisher.worker)
    for job in publisher.pending {persistence_publish_job_destroy(job)}
    for job in publisher.spare {persistence_publish_job_destroy(job)}
    delete(publisher.pending);delete(publisher.spare)
    free(publisher)
}

#+build darwin
package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:sys/info"
import "core:sys/posix"
import "core:thread"

Collector_Kill_PID :: struct {pid:i32,start:u64}
Collector_Kill_Batch :: struct {
    mutex:sync.Mutex,
    nodes:[]Collector_Kill_PID,
    next,failed:int,
}

collector_kill_diagnostic :: proc(batch:^Collector_Kill_Batch,message:string) {
    sync.mutex_lock(&batch.mutex)
    fmt.eprintln(message)
    batch.failed+=1
    sync.mutex_unlock(&batch.mutex)
}
collector_kill_decimal :: proc(value:string)->(number:u64,ok:bool) {
    if len(value)==0 {return}
    for ch in value {
        if ch<'0'||ch>'9' {return 0,false}
        digit:=u64(ch-'0')
        if number>(max(u64)-digit)/10 {return 0,false}
        number=number*10+digit
    }
    return number,true
}
collector_kill_parse :: proc(batch:^Collector_Kill_Batch,nodes:^[dynamic]Collector_Kill_PID,line:string)->bool {
    split:=strings.index_byte(line,' ')
    if split<=0 {collector_kill_diagnostic(batch,"Malformed PID identity list.");return false}
    pid,pid_ok:=collector_kill_decimal(line[:split])
    start,start_ok:=collector_kill_decimal(line[split+1:])
    if !pid_ok||!start_ok||pid==0||pid>u64(max(i32))||start==0 {
        collector_kill_diagnostic(batch,"PID list contains an invalid or missing sampled identity.");return false
    }
    append(nodes,Collector_Kill_PID{pid=i32(pid),start=start})
    return true
}
collector_kill_one :: proc(batch:^Collector_Kill_Batch,node:Collector_Kill_PID) {
    actual:=metrics_darwin_process_identity(node.pid)
    if actual==0||actual!=node.start {
        collector_kill_diagnostic(batch,fmt.tprintf("PID %d exited or changed; select its current row.",node.pid))
        return
    }
    if posix.kill(posix.pid_t(node.pid),.SIGKILL)!=.OK {
        collector_kill_diagnostic(batch,fmt.tprintf("Could not kill PID %d: %s",node.pid,string(posix.strerror(posix.errno()))))
    }
}
collector_kill_worker :: proc(batch:^Collector_Kill_Batch) {
    defer mem.free_all(context.temp_allocator)
    for {
        sync.mutex_lock(&batch.mutex)
        index:=batch.next
        batch.next+=1
        sync.mutex_unlock(&batch.mutex)
        if index>=len(batch.nodes) {return}
        collector_kill_one(batch,batch.nodes[index])
    }
}
collector_kill_pids :: proc()->bool {
    batch:Collector_Kill_Batch
    nodes:=make([dynamic]Collector_Kill_PID,0,64)
    defer delete(nodes)
    buffer:[4096]u8
    line:[96]u8
    used:=0
    overflow:=false
    // Read the complete group before starting workers. EOF is sent by the SSH
    // uploader, and no process is signalled from a partial identity record.
    for {
        count:=posix.read(0,raw_data(buffer[:]),uint(len(buffer)))
        if count<0 {
            if posix.errno()==.EINTR {continue}
            fmt.eprintln("Could not read the SSH PID identity list.");return false
        }
        if count==0 {break}
        for ch in buffer[:int(count)] {
            if ch=='\n' {
                if overflow {collector_kill_diagnostic(&batch,"PID identity line is too long.")}
                else {_=collector_kill_parse(&batch,&nodes,string(line[:used]))}
                used=0;overflow=false
            } else if used<len(line) {line[used]=ch;used+=1}
            else {overflow=true}
        }
    }
    if used>0||overflow {collector_kill_diagnostic(&batch,"SSH PID identity list ended during a record.")}
    if len(nodes)==0 {fmt.eprintln("No complete PID identities were received.");return false}
    // A group can contain this transient collector. Delay its signal until all
    // other PIDs have been attempted so killing it cannot abandon group work.
    self:Collector_Kill_PID
    own_pid:=i32(posix.getpid())
    for node,index in nodes {
        if node.pid==own_pid {
            self=node
            nodes[index]=nodes[len(nodes)-1]
            resize(&nodes,len(nodes)-1)
            break
        }
    }
    batch.nodes=nodes[:]
    _,logical,_:=info.cpu_core_count()
    workers:=make([dynamic]^thread.Thread,0,min(max(logical-1,0),32))
    defer delete(workers)
    for _ in 0..<min(len(nodes),min(max(logical-1,0),32)) {
        worker:=thread.create_and_start_with_poly_data(&batch,collector_kill_worker,name="Kill PID")
        if worker!=nil {append(&workers,worker)}
    }
    collector_kill_worker(&batch)
    for worker in workers {thread.join(worker);thread.destroy(worker)}
    if self.pid>0 {collector_kill_one(&batch,self)}
    return batch.failed==0
}

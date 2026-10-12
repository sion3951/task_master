package main

import "core:math"

// Keep the union of the twelve busiest CPU and RAM groups, and twelve GPU
// groups. Fixed buffers make ring replacement, frozen copies and cache handoff
// ownership-free. Metrics and all available process identities are copied.
PROCESS_HISTORY_GROUPS :: 24
PROCESS_HISTORY_GPU_GROUPS :: 12
PROCESS_HISTORY_PIDS :: 96
PROCESS_HISTORY_GPU_PIDS :: 48
Process_Snapshot :: struct {
    recorded, partial, pids_partial, cpu_available, gpu_memory_shared: bool,
    groups: [PROCESS_HISTORY_GROUPS]Process_Group,
    gpu_groups: [PROCESS_HISTORY_GPU_GROUPS]Process_Group,
    nodes: [PROCESS_HISTORY_PIDS]PID_Node,
    gpu_nodes: [PROCESS_HISTORY_GPU_PIDS]PID_Node,
    group_count, gpu_group_count, node_count, gpu_node_count: int,
    total, gpu_total: int,
}
Process_Snapshot_Cache :: struct {
    recorded, partial, pids_partial, cpu_available, gpu_memory_shared: bool,
    groups, gpu_groups: []Process_Group,
    nodes, gpu_nodes: []PID_Node,
    total, gpu_total: int,
}

process_history_group_append :: proc(groups:[]Process_Group,count:^int,group:Process_Group) {
    for existing in groups[:count^] {
        if existing.name_len==group.name_len&&existing.name==group.name {return}
    }
    if count^<len(groups) {groups[count^]=group;count^+=1}
}
process_history_nodes :: proc(groups:[]Process_Group,destination,source:[]PID_Node)->(used:int,partial:bool) {
    // Share the identity budget between retained groups so one large workload
    // cannot erase every other group's PIDs. Original grouped counts survive.
    for &group,i in groups {
        cursor,visited:=group.pid_head,0
        group.pid_head=-1
        quota:=max(1,(len(destination)-used)/(len(groups)-i))
        previous:=-1
        for cursor>=0&&cursor<len(source)&&visited<group.pid_count&&visited<quota&&used<len(destination) {
            node:=source[cursor]
            destination[used]=PID_Node{pid=node.pid,start=node.start,next=-1}
            if previous>=0 {destination[previous].next=used} else {group.pid_head=used}
            previous=used;used+=1;visited+=1;cursor=node.next
        }
        if visited<group.pid_count {partial=true}
    }
    return
}
process_history_sample :: proc(s:^CPU_Sample,m:^Metrics) {
    p:=&s.processes
    p^=Process_Snapshot{recorded=true,cpu_available=m.cpu_available,gpu_memory_shared=m.gpu_process_memory_shared,
        total=m.total_processes,gpu_total=m.gpu_total_processes,partial=m.process_group_overflow}
    for group in m.processes[:m.process_count] {process_history_group_append(p.groups[:],&p.group_count,group)}
    for group in m.memory_processes[:m.memory_process_count] {process_history_group_append(p.groups[:],&p.group_count,group)}
    for group in m.gpu_processes[:m.gpu_process_count] {process_history_group_append(p.gpu_groups[:],&p.gpu_group_count,group)}
    partial:bool
    p.node_count,partial=process_history_nodes(p.groups[:p.group_count],p.nodes[:],m.process_pids[:m._group_pid_count])
    p.pids_partial=partial
    p.gpu_node_count,partial=process_history_nodes(p.gpu_groups[:p.gpu_group_count],p.gpu_nodes[:],m.gpu_process_pids[:])
    p.pids_partial=p.pids_partial||partial
}
process_history_cache :: proc(p:^Process_Snapshot)->Process_Snapshot_Cache {
    return Process_Snapshot_Cache{recorded=p.recorded,partial=p.partial,pids_partial=p.pids_partial,
        cpu_available=p.cpu_available,gpu_memory_shared=p.gpu_memory_shared,
        total=p.total,gpu_total=p.gpu_total,groups=p.groups[:p.group_count],gpu_groups=p.gpu_groups[:p.gpu_group_count],
        nodes=p.nodes[:p.node_count],gpu_nodes=p.gpu_nodes[:p.gpu_node_count]}
}
process_history_restore :: proc(p:^Process_Snapshot,c:Process_Snapshot_Cache) {
    p^=Process_Snapshot{recorded=c.recorded,partial=c.partial,pids_partial=c.pids_partial,
        cpu_available=c.cpu_available,gpu_memory_shared=c.gpu_memory_shared,total=c.total,gpu_total=c.gpu_total,
        group_count=len(c.groups),gpu_group_count=len(c.gpu_groups),node_count=len(c.nodes),gpu_node_count=len(c.gpu_nodes)}
    copy(p.groups[:],c.groups);copy(p.gpu_groups[:],c.gpu_groups)
    copy(p.nodes[:],c.nodes);copy(p.gpu_nodes[:],c.gpu_nodes)
}
process_history_valid :: proc(c:Process_Snapshot_Cache)->bool {
    if len(c.groups)>PROCESS_HISTORY_GROUPS||len(c.gpu_groups)>PROCESS_HISTORY_GPU_GROUPS||
        len(c.nodes)>PROCESS_HISTORY_PIDS||len(c.gpu_nodes)>PROCESS_HISTORY_GPU_PIDS||
        c.total<0||c.gpu_total<0 {return false}
    groups:=[2][]Process_Group{c.groups,c.gpu_groups}
    pools:=[2][]PID_Node{c.nodes,c.gpu_nodes}
    for table,index in groups {
        nodes:=pools[index]
        for node in nodes {
            if node.pid<=0||node.next< -1||node.next>=len(nodes) {return false}
        }
        for group in table {
            if group.name_len<=0||group.name_len>len(group.name)||group.pid_count<0||group.pid_count>MAX_SYSTEM_PIDS||
                group.system_processes<0||group.system_processes>group.pid_count||group.pid_head< -1||group.pid_head>=len(nodes)||
                math.is_nan(group.cpu_percent)||math.is_inf(group.cpu_percent)||group.cpu_percent<0 {return false}
            cursor,visited:=group.pid_head,0
            seen:[PROCESS_HISTORY_PIDS]bool
            for cursor>=0 {
                if seen[cursor]||visited>=group.pid_count {return false}
                seen[cursor]=true;visited+=1;cursor=nodes[cursor].next
            }
        }
    }
    return true
}

process_history_slot :: proc(a:^App)->int {
    slot:=a.cpu_pinned_slot
    if a.view==.GPU {slot=a.gpu_pinned_slot}
    else if a.view==.Memory {slot=a.memory_pinned_slot}
    if slot>=0&&slot<HISTORY_CAPACITY&&history_position(a,slot)>=0 {return slot}
    return -1
}
process_history_resume :: proc(a:^App) {
    switch a.view {
    case .GPU: a.gpu_pinned_slot=-1
    case .Memory: a.memory_pinned_slot=-1
    case .CPU,.Overview: a.cpu_pinned_slot=-1
    }
    a.process_cache.valid=false;a.click=false;a.dirty=true
}

process_history_data :: proc(s:^CPU_Sample,gpu:bool)->Process_Table_Data {
    p:=&s.processes
    data:=Process_Table_Data{groups=p.groups[:p.group_count],nodes=p.nodes[:p.node_count],
        total=p.total,partial=p.partial,cpu_available=p.cpu_available,pids_partial=p.pids_partial,
        memory_shared=p.gpu_memory_shared,memory_capacity=s.memory_total if s.ram_available else 0}
    if gpu {
        data.groups=p.gpu_groups[:p.gpu_group_count];data.nodes=p.gpu_nodes[:p.gpu_node_count];data.total=p.gpu_total
        data.memory_capacity=0
        for device in s.gpus[:s.gpu_count] {if device.memory_available {data.memory_capacity+=device.memory_total}}
        if s.gpu_count==0&&s.gpu.memory_available {data.memory_capacity=s.gpu.memory_total}
    }
    return data
}

process_history_nearest :: proc(a:^App,position:f32)->int {
    if a.history_count==0 {return -1}
    first:=(a.history_next-a.history_count+HISTORY_CAPACITY)%HISTORY_CAPACITY
    if position<history_position(a,first) {return -1}
    nearest:=-1
    distance:=f32(2)
    for i in 0..<a.history_count {
        slot:=(first+i)%HISTORY_CAPACITY
        sample_position:=history_position(a,slot)
        if sample_position<0 {continue}
        delta:=abs(sample_position-position)
        if delta<distance {distance=delta;nearest=slot}
    }
    return nearest
}

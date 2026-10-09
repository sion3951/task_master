package main

import "core:fmt"
import "core:sort"
import "core:strings"

Process_Column :: enum { CPU, Memory, Name, PIDs }
Process_Order :: struct { column: Process_Column, ascending: bool }
Process_Table_Data :: struct {
    groups: []Process_Group,
    nodes: []PID_Node,
    total: int,
    partial, cpu_available: bool,
    memory_capacity: u64,
}
Process_Row :: struct {
    group: Process_Group,
    sort_value: f64,
    height: f32,
    overflow, expanded: bool,
}
Process_Frozen_Table :: struct {
    rows: [dynamic]Process_Row,
    indices: map[string]int,
    pid_width, scale: f32,
    reset: bool,
}

process_table_data :: proc(a:^App,gpu:bool)->Process_Table_Data {
    m:=&a.metrics
    data:=Process_Table_Data{
        groups=m._groups[:m.total_process_groups],nodes=m.process_pids[:m._group_pid_count],
        total=m.total_processes,partial=m.process_group_overflow,
        cpu_available=m.cpu_available,memory_capacity=m.memory_total if m.ram_available else 0,
    }
    if gpu {
        data.groups=m._gpu_groups[:m.gpu_total_groups]
        pid_count:=0
        for group in data.groups {pid_count+=group.pid_count}
        data.nodes=m.gpu_process_pids[:pid_count]
        data.total=m.gpu_total_processes;data.memory_capacity=0
        for device in m.gpus[:m.gpu_count] {
            if device.memory_available {data.memory_capacity+=device.memory_total}
        }
    }
    return data
}
process_frozen_clear :: proc(frozen:^Process_Frozen_Table) {
    for name in frozen.indices {delete(name)}
    clear(&frozen.indices);clear(&frozen.rows)
}
process_frozen_destroy :: proc(frozen:^Process_Frozen_Table) {
    if frozen==nil {return}
    process_frozen_clear(frozen)
    delete(frozen.indices);delete(frozen.rows);free(frozen)
}
process_positions_reset :: proc(a:^App,all_views:bool=false) {
    for frozen,i in a.process_frozen {
        if frozen!=nil&&(all_views||i==int(a.view)) {frozen.reset=true}
    }
    a.process_cache.valid=false
}
process_frozen_append :: proc(frozen:^Process_Frozen_Table,row:Process_Row) {
    group:=row.group
    name:=string(group.name[:group.name_len])
    frozen.indices[strings.clone(name)]=len(frozen.rows)
    append(&frozen.rows,row)
}
process_freeze_toggle :: proc(a:^App) {
    frozen:=&a.process_frozen[int(a.view)]
    if frozen^!=nil {process_frozen_destroy(frozen^);frozen^=nil}
    else {
        frozen^=new(Process_Frozen_Table)
        frozen^^.indices=make(map[string]int)
        // Capture the displayed order and row heights, not the sampled values.
        if a.process_cache.machine==a.machine&&a.process_cache.view==a.view {
            for row in a.process_rows {process_frozen_append(frozen^,row)}
            frozen^^.pid_width=a.process_cache.pid_width;frozen^^.scale=a.process_cache.scale
        } else {frozen^^.reset=true}
    }
    a.process_cache.valid=false
    a.click=false;a.dirty=true
}
process_frozen_update :: proc(a:^App,frozen:^Process_Frozen_Table,groups:[]Process_Group) {
    // Clear departed groups' readings without removing their row slots.
    for &row in frozen.rows {
        name,name_len:=row.group.name,row.group.name_len
        row.group=Process_Group{name=name,name_len=name_len,pid_head=-1}
    }
    for &group in groups {
        name:=string(group.name[:group.name_len])
        if index,exists:=frozen.indices[name];exists {frozen.rows[index].group=group}
        else {
            process_frozen_append(frozen,Process_Row{group=group})
        }
    }
}
process_snowflake :: proc(a:^App,x,y:f32,c:Color) {
    directions:=[6][2]f32{{0,-1},{0.866,-0.5},{0.866,0.5},{0,1},{-0.866,0.5},{-0.866,-0.5}}
    for d,i in directions {
        dx,dy:=d[0],d[1]
        if i<3 {stroke(a,x-dx*8,y-dy*8,x+dx*8,y+dy*8,1.5,c)}
        // Outward-facing forks keep the centre open and read as ice crystals.
        bx,by:=x+dx*4,y+dy*4
        stroke(a,bx,by,bx+dx*2.5-dy*2.5,by+dy*2.5+dx*2.5,1.5,c)
        stroke(a,bx,by,bx+dx*2.5+dy*2.5,by+dy*2.5-dx*2.5,1.5,c)
    }
}
process_freeze_hovered :: proc(a:^App,x,y:f32)->bool {
    return a.process_freeze_visible&&!a.machine_menu&&!a.machine_dialog&&!a.process_menu_open&&
        x>=a.process_freeze_x&&x<a.process_freeze_x+28&&y>=a.process_freeze_y&&y<a.process_freeze_y+28
}
process_freeze_message :: proc(a:^App) {
    if !process_freeze_hovered(a,a.mouse_x,a.mouse_y) {return}
    label:="Resume automatic sorting" if a.process_frozen[int(a.view)]!=nil else "Freeze row positions"
    w:=renderer_text_width(&a.renderer,label,12*a.scale)/a.scale+24
    x:=clamp(a.process_freeze_x,8,max(8,a.width-w-8))
    y:=clamp(a.process_freeze_y+32,8,max(8,a.height-38))
    panel(a,x,y,w,30)
    text(a,label,x+12,y+20,12,SOFT)
}

// Cache the full sort and PID wrapping across hover/scroll redraws.
Process_Cache :: struct {
    machine: ^Machine_State,
    revision: u64,
    view: View,
    gpu: bool,
    order: Process_Order,
    pid_width, scale, content_height: f32,
    pinned_count: int,
    valid: bool,
}
process_cache_matches :: proc(a:^App,gpu:bool,pid_width:f32)->bool {
    c:=&a.process_cache
    order:=a.process_order[int(a.view)]
    return c.valid&&c.machine==a.machine&&c.revision==a.process_revision&&c.view==a.view&&c.gpu==gpu&&
        c.order.column==order.column&&c.order.ascending==order.ascending&&
        c.pid_width==pid_width&&c.scale==a.scale
}

process_expanded :: proc(a:^App,name:string)->bool {
    for key in a.expanded_processes[int(a.view)] {if key==name {return true}}
    return false
}
process_toggle :: proc(a:^App,name:string) {
    a.process_revision+=1
    a.process_cache.valid=false
    names:=&a.expanded_processes[int(a.view)]
    for key,i in names^ {
        if key==name {
            delete(key)
            ordered_remove(names,i)
            return
        }
    }
    append(names,strings.clone(name))
}
process_chevron :: proc(a:^App,x,y:f32,up:bool,c:Color=MUTED) {
    dy:=f32(-2) if up else f32(2)
    stroke(a,x-3,y-dy,x,y+dy,1,c)
    stroke(a,x,y+dy,x+3,y-dy,1,c)
}
process_sort_label :: proc(a:^App,label:string,end_x,y:f32,column:Process_Column) {
    order:=a.process_order[int(a.view)]
    active:=order.column==column
    right_text(a,label,end_x,y,12,TEXT if active else MUTED)
    if active {
        width:=renderer_text_width(&a.renderer,label,12*a.scale)/a.scale
        process_chevron(a,end_x-width-10,y-4,order.ascending,SOFT)
    }
}
process_sort_select :: proc(a:^App,column:Process_Column) {
    order:=&a.process_order[int(a.view)]
    if order.column==column {order.ascending=!order.ascending}
    else {order.column=column;order.ascending=column==.Name}
    a.process_scroll[int(a.view)]=0
    process_positions_reset(a)
    if !process_sort_preferences_save(a) {fmt.eprintln("Could not save task_master process sort preference")}
}
process_row_compare :: proc(a,b:Process_Row)->int {
    if a.sort_value<b.sort_value {return -1}
    if a.sort_value>b.sort_value {return 1}
    an,bn:=a.group.name,b.group.name
    return strings.compare(string(an[:a.group.name_len]),string(bn[:b.group.name_len]))
}

// A collapsed row stops at the first wrap. Expanded rows use the same PID column.
process_pid_lines :: proc(a:^App,p:^Process_Group,nodes:[]PID_Node,x,y,w:f32,render:bool,max_lines:int=0)->int {
    line:[1024]u8
    used:=0
    width:=f32(0)
    lines:=0
    cursor,visited:=p.pid_head,0
    on_line:=0
    for cursor>=0&&cursor<len(nodes)&&visited<p.pid_count {
        token_buffer:[24]u8
        token:=fmt.bprintf(token_buffer[:],"%s%d",", " if on_line>0 else "",nodes[cursor].pid)
        token_width:=renderer_text_width(&a.renderer,token,12*a.scale)/a.scale
        if on_line>0&&(width+token_width>w||used+len(token)>len(line)) {
            if render {right_text(a,string(line[:used]),x+w,y+f32(lines)*18,12,MUTED)}
            lines+=1
            if max_lines>0&&lines>=max_lines {return lines+1}
            used,width,on_line=0,0,0
            token=fmt.bprintf(token_buffer[:],"%d",nodes[cursor].pid)
            token_width=renderer_text_width(&a.renderer,token,12*a.scale)/a.scale
        }
        used+=copy(line[used:],token)
        width+=token_width
        on_line+=1
        visited+=1
        cursor=nodes[cursor].next
    }
    if render {right_text(a,string(line[:used]),x+w,y+f32(lines)*18,12,MUTED)}
    return lines+1
}

process_panel :: proc(a:^App,x,y,w,h:f32,gpu:bool=false,unboxed:bool=false) {
    // Graph inspection holds its own readings; process tables stay live.
    displayed:=a.machine
    a.machine=a.machines[a.active_machine].state
    defer a.machine=displayed
    if !unboxed {panel(a,x,y,w,h)}
    outer_clip:=a.clip_active
    outer_top,outer_bottom:=a.clip_top,a.clip_bottom
    defer {a.clip_active=outer_clip;a.clip_top,a.clip_bottom=outer_top,outer_bottom}
    text(a,"GPU PROCESSES" if gpu else "PROCESSES",x+18,y+28,10,SOFT)
    a.process_freeze_x,a.process_freeze_y=x+122,y+8
    a.process_freeze_visible=!outer_clip||(y+8>=outer_top&&y+36<=outer_bottom)
    if hit(a,x+122,y+8,28,28) {process_freeze_toggle(a)}
    frozen:=a.process_frozen[int(a.view)]
    color:=CYAN if frozen!=nil else SOFT
    if process_freeze_hovered(a,a.mouse_x,a.mouse_y) {rounded_rect(a,x+124,y+10,24,24,5,LINE);if frozen==nil {color=TEXT}}
    process_snowflake(a,x+136,y+22,color)
    data:=process_table_data(a,gpu)
    right_text(a,fmt.tprintf("%d groups / %d PIDs%s",len(data.groups),data.total," (partial)" if data.partial else ""),x+w-18,y+28,10,MUTED)
    processes,nodes:=data.groups,data.nodes
    pid_end:=x+w-222
    pid_start:=min(x+18+(w-36)*0.32,pid_end-52)
    pid_width:=pid_end-pid_start
    if hit(a,x+18,y+40,pid_start-x-18,28) {process_sort_select(a,.Name)}
    if hit(a,pid_start,y+40,pid_width,28) {process_sort_select(a,.PIDs)}
    if hit(a,pid_end,y+40,90,28) {process_sort_select(a,.CPU)}
    if hit(a,x+w-132,y+40,114,28) {process_sort_select(a,.Memory)}
    order:=a.process_order[int(a.view)]
    text(a,"NAME",x+18,y+59,12,TEXT if order.column==.Name else MUTED)
    if order.column==.Name {process_chevron(a,x+66,y+55,order.ascending,SOFT)}
    process_sort_label(a,"PIDS",pid_end,y+59,.PIDs)
    process_sort_label(a,"CPU %",x+w-144,y+59,.CPU)
    process_sort_label(a,("GPU RAM" if a.metrics.gpu_process_memory_shared else "VRAM") if gpu else "RAM",x+w-18,y+59,.Memory)
    rect(a,x+18,y+70,w-36,1,LINE)
    if !process_cache_matches(a,gpu,pid_width) {
        hold_layout:=frozen!=nil&&!frozen.reset&&frozen.pid_width==pid_width&&frozen.scale==a.scale
        if frozen!=nil&&frozen.reset {process_frozen_clear(frozen)}
        clear(&a.process_rows)
        if frozen!=nil&&!frozen.reset {
            process_frozen_update(a,frozen,processes)
            append(&a.process_rows,..frozen.rows[:])
        } else {
            for &p in processes {
                value:f64
                switch order.column {
                case .CPU: value=f64(p.cpu_percent)
                case .Memory: value=f64(p.gpu_memory_bytes if gpu else p.memory_bytes)
                case .PIDs: value=f64(p.pid_count)
                case .Name:
                }
                if !order.ascending {value=-value}
                append(&a.process_rows,Process_Row{group=p,sort_value=value})
            }
            sort.quick_sort_proc(a.process_rows[:],process_row_compare)
            if order.column==.Name&&!order.ascending {
                rows:=a.process_rows[:]
                for i in 0..<len(rows)/2 {rows[i],rows[len(rows)-1-i]=rows[len(rows)-1-i],rows[i]}
            }
        }
        rows:=a.process_rows[:]
        // Stable partition preserves both the chosen sort and held row positions.
        partition:=make([dynamic]Process_Row,0,len(rows),context.temp_allocator)
        for row in rows {
            name:=row.group.name
            if process_pinned(a,string(name[:row.group.name_len])) {append(&partition,row)}
        }
        pinned_count:=len(partition)
        for row in rows {
            name:=row.group.name
            if !process_pinned(a,string(name[:row.group.name_len])) {append(&partition,row)}
        }
        copy(rows,partition[:])
        content_height:f32
        for &row in rows {
            p:=&row.group
            row.overflow=process_pid_lines(a,p,nodes,pid_start,0,pid_width,false,1)>1
            expanded:=(row.overflow||(hold_layout&&row.expanded))&&process_expanded(a,string(p.name[:p.name_len]))
            lines:=1
            if expanded {lines=process_pid_lines(a,p,nodes,pid_start,0,pid_width-16,false)}
            if !hold_layout||row.height==0||expanded!=row.expanded {row.height=f32(14+lines*18)}
            row.expanded=expanded
            content_height+=row.height
        }
        if pinned_count>0&&pinned_count<len(rows) {content_height+=8}
        if frozen!=nil {
            frozen.pid_width=pid_width;frozen.scale=a.scale
            if frozen.reset {
                for row in rows {process_frozen_append(frozen,row)}
                frozen.reset=false
            } else {
                copy(frozen.rows[:],rows)
                for row,i in rows {
                    name:=row.group.name
                    frozen.indices[string(name[:row.group.name_len])]=i
                }
            }
        }
        a.process_cache=Process_Cache{machine=a.machine,revision=a.process_revision,view=a.view,gpu=gpu,
            order=order,pid_width=pid_width,scale=a.scale,
            content_height=content_height,pinned_count=pinned_count,valid=true}
    }
    rows:=a.process_rows[:]
    a.table_x,a.table_y,a.table_w,a.table_h=x,y+73,w,h-73
    if outer_clip {
        a.table_y=max(a.table_y,outer_top)
        a.table_h=max(0,min(y+h,outer_bottom)-a.table_y)
    }
    content_height:=a.process_cache.content_height
    body_height:=max(0,h-83)
    view_index:=int(a.view)
    scroll_max:=max(0,content_height-body_height)
    a.process_scroll[view_index]=clamp(a.process_scroll[view_index],0,scroll_max)
    a.clip_top,a.clip_bottom=y+78,y+h-10
    if outer_clip {a.clip_top=max(a.clip_top,outer_top);a.clip_bottom=min(a.clip_bottom,outer_bottom)}
    a.clip_active=true
    if len(rows)==0 {
        message:="No processes reported" if gpu else "Waiting for first sample"
        text(a,message,x+18,y+101,12,MUTED)
    }
    row_y:=y+94-a.process_scroll[view_index]
    memory_capacity:=data.memory_capacity
    for &row,i in rows {
        if i>0&&i==a.process_cache.pinned_count {
            rect(a,x+18,row_y-18,w-36,1,LINE)
            row_y+=8
        }
        p:=&row.group
        if row_y+row.height>a.clip_top&&row_y-18<a.clip_bottom {
            name:=string(p.name[:p.name_len])
            label:=fmt.tprintf("%s (%d)",name,p.pid_count) if p.pid_count>1 else name
            pinned:=i<a.process_cache.pinned_count
            if pinned {rect(a,x+18,row_y-7,3,3,CYAN)}
            fit_text(a,label,x+26 if pinned else x+18,row_y,pid_start-x-42 if pinned else pid_start-x-34,14)
            cpu_color:=utilization_color(p.cpu_percent) if data.cpu_available else SOFT
            memory_used:=p.gpu_memory_bytes if gpu else p.memory_bytes
            memory_known:=!gpu||p.gpu_memory_available
            memory_color:=utilization_color(memory_pct(memory_used,memory_capacity)) if memory_capacity>0&&memory_known else SOFT
            exited:=p.pid_count==0
            right_text(a,"-" if exited else fmt.tprintf("%.1f",p.cpu_percent),x+w-144,row_y,14,MUTED if exited else cpu_color)
            right_text(a,"-" if exited else (bytes_label(memory_used) if memory_known else "N/A"),x+w-18,row_y,14,MUTED if exited else memory_color)
            width:=pid_width-16 if row.overflow||row.expanded else pid_width
            if exited {right_text(a,"Exited",pid_end,row_y,12,MUTED)}
            else {
                // Live PID changes cannot expand a held row into its neighbour.
                max_lines:=max(1,int((row.height-14)/18)) if row.expanded else 1
                _=process_pid_lines(a,p,nodes,pid_start,row_y,width,true,max_lines)
            }
            if (row.overflow||row.expanded)&&!exited {
                process_chevron(a,pid_end-5,row_y-4,row.expanded)
                if a.mouse_y>=a.clip_top&&a.mouse_y<a.clip_bottom&&hit(a,pid_end-18,row_y-16,18,24) {process_toggle(a,name);a.click=false}
            }
            if a.click&&a.mouse_x>=x+18&&a.mouse_x<x+w-18&&a.mouse_y>=max(a.clip_top,row_y-16)&&a.mouse_y<min(a.clip_bottom,row_y+row.height-16) {
                process_menu_open_row(a,p,nodes)
            }
            if i<len(rows)-1&&i+1!=a.process_cache.pinned_count {rect(a,x+18,row_y+row.height-20,w-36,1,Color{0.08,0.08,0.08,1})}
        }
        row_y+=row.height
    }
    if scroll_max>0&&body_height>0 {
        track_height:=a.clip_bottom-a.clip_top
        thumb_height:=max(20,track_height*body_height/content_height)
        thumb_y:=a.clip_top+(track_height-thumb_height)*a.process_scroll[view_index]/scroll_max
        rect(a,x+w-8,thumb_y,2,thumb_height,MUTED)
    }
}

package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

Process_Preference :: struct { name:[64]u8, name_len:int }
Process_Preference_Record :: struct { name:string, pinned:bool }
Process_Sort_Record :: struct { view, column:string, ascending:bool }

process_pinned :: proc(a:^App,name:string)->bool {
    for &p in a.process_preferences[:a.process_preference_count] {
        if name==string(p.name[:p.name_len]) {return true}
    }
    return false
}
process_preferences_file_path :: proc(a:^App,filename:string)->string {
    directory,err:=os.user_config_dir(context.temp_allocator)
    if err!=nil {return ""}
    path:=fmt.tprintf("%s/task_master/%s.json",directory,filename)
    // Local keeps its established filename; remote rules are scoped to SSH host.
    for m in a.machines[:a.machine_count] {
        if m!=a.local_machine&&a.machine==m.state {
            identity:=string(m.host[:m.host_len])
            if m.port>0 {identity=fmt.tprintf("%s:%d",identity,m.port)}
            path=fmt.tprintf("%s/task_master/%s-%016x.json",directory,filename,telemetry_name_hash(identity))
            break
        }
    }
    return path
}
process_preferences_load :: proc(a:^App) {
    process_sort_preferences_load(a)
    path:=process_preferences_file_path(a,"process-pins")
    if len(path)==0 {return}
    if len(path)>=len(a.process_preferences_path) {return}
    a.process_preferences_path_len=copy(a.process_preferences_path[:],path)
    data,read_error:=os.read_entire_file(path,context.temp_allocator)
    // Retain any existing pins while discarding the retired visibility rules.
    if read_error!=nil {data,read_error=os.read_entire_file(process_preferences_file_path(a,"process-visibility"),context.temp_allocator)}
    if read_error!=nil {return}
    records:[]Process_Preference_Record
    if json.unmarshal(data,&records,allocator=context.temp_allocator)!=nil {return}
    for record in records {
        if len(record.name)==0||len(record.name)>64||!record.pinned {continue}
        process_pin_set(a,record.name,true,save=false)
    }
}
process_preferences_save :: proc(a:^App)->bool {
    if a.process_preferences_path_len==0 {return false}
    records:[128]Process_Preference_Record
    for &p,i in a.process_preferences[:a.process_preference_count] {
        records[i]=Process_Preference_Record{name=string(p.name[:p.name_len]),pinned=true}
    }
    data,encode_error:=json.marshal(records[:a.process_preference_count],allocator=context.temp_allocator)
    if encode_error!=nil {return false}
    path:=string(a.process_preferences_path[:a.process_preferences_path_len])
    slash:=max(strings.last_index_byte(path,'/'),strings.last_index_byte(path,'\\'))
    if slash<0 {return false}
    directory_error:=os.mkdir_all(path[:slash],{.Read_User,.Write_User,.Execute_User})
    if directory_error!=nil&&directory_error!=.Exist {return false}
    if !platform_private_path(path[:slash],true) {return false}
    temporary:=fmt.tprintf("%s.tmp-%d",path,os.get_pid())
    if os.write_entire_file(temporary,data,{.Read_User,.Write_User})!=nil {_=os.remove(temporary);return false}
    if !platform_private_path(temporary,false)||!platform_atomic_replace(temporary,path) {_=os.remove(temporary);return false}
    return true
}
PROCESS_SORT_VIEWS :: [4]string{"overview","cpu","gpu","memory"}
PROCESS_SORT_COLUMNS :: [4]string{"cpu","memory","name","pids"}

process_sort_preferences_load :: proc(a:^App) {
    path:=process_preferences_file_path(a,"process-sort")
    if len(path)==0 {return}
    data,read_error:=os.read_entire_file(path,context.temp_allocator)
    if read_error!=nil {return}
    records:[]Process_Sort_Record
    if json.unmarshal(data,&records,allocator=context.temp_allocator)!=nil {return}
    for record in records {
        view,column:=-1,-1
        for name,i in PROCESS_SORT_VIEWS {if record.view==name {view=i;break}}
        for name,i in PROCESS_SORT_COLUMNS {if record.column==name {column=i;break}}
        if view<0||column<0 {continue}
        a.process_order[view]=Process_Order{column=Process_Column(column),ascending=record.ascending}
    }
}
process_sort_preferences_save :: proc(a:^App)->bool {
    path:=process_preferences_file_path(a,"process-sort")
    if len(path)==0 {return false}
    records:[4]Process_Sort_Record
    views,columns:=PROCESS_SORT_VIEWS,PROCESS_SORT_COLUMNS
    for order,i in a.process_order {
        records[i]=Process_Sort_Record{view=views[i],column=columns[int(order.column)],ascending=order.ascending}
    }
    data,encode_error:=json.marshal(records[:],allocator=context.temp_allocator)
    if encode_error!=nil {return false}
    slash:=max(strings.last_index_byte(path,'/'),strings.last_index_byte(path,'\\'))
    if slash<0 {return false}
    directory_error:=os.mkdir_all(path[:slash],{.Read_User,.Write_User,.Execute_User})
    if directory_error!=nil&&directory_error!=.Exist {return false}
    if !platform_private_path(path[:slash],true) {return false}
    temporary:=fmt.tprintf("%s.tmp-%d",path,os.get_pid())
    if os.write_entire_file(temporary,data,{.Read_User,.Write_User})!=nil {_=os.remove(temporary);return false}
    if !platform_private_path(temporary,false)||!platform_atomic_replace(temporary,path) {_=os.remove(temporary);return false}
    return true
}
process_pin_set :: proc(a:^App,name:string,pinned:bool,save:bool=true) {
    a.process_revision+=1
    a.process_cache.valid=false
    index:=a.process_preference_count
    for &p,i in a.process_preferences[:a.process_preference_count] {
        if name==string(p.name[:p.name_len]) {index=i;break}
    }
    if !pinned {
        if index<a.process_preference_count {
            a.process_preference_count-=1
            a.process_preferences[index]=a.process_preferences[a.process_preference_count]
        }
    } else {
        if index>=len(a.process_preferences) {a.process_preference_error=true;return}
        p:=&a.process_preferences[index]
        p.name_len=copy(p.name[:],name)
        if index==a.process_preference_count {a.process_preference_count+=1}
    }
    if save {
        a.process_preference_error=!process_preferences_save(a)
        if a.process_preference_error {fmt.eprintln("Could not save task_master process preference")}
        a.process_scroll={}
    }
}
process_menu_open_row :: proc(a:^App,p:^Process_Group,nodes:[]PID_Node) {
    a.process_menu_name_len=copy(a.process_menu_name[:],p.name[:p.name_len])
    clear(&a.process_menu_pids)
    cursor:=p.pid_head
    for cursor>=0&&cursor<len(nodes)&&len(a.process_menu_pids)<p.pid_count {
        append(&a.process_menu_pids,nodes[cursor])
        cursor=nodes[cursor].next
    }
    a.process_menu_x,a.process_menu_y=a.mouse_x,a.mouse_y
    a.process_menu_open=true;a.process_menu_kill=false;a.process_menu_scroll=0
    a.process_preference_error=false;a.process_menu_error_len=0
    a.click=false
}
process_menu_bounds :: proc(a:^App)->(x,y,h:f32,rows:int) {
    rows=min(len(a.process_menu_pids),max(1,int((a.height-120)/28)))
    h=76+f32(rows)*28 if a.process_menu_kill else 104
    if a.process_menu_error_len>0||a.process_preference_error {h+=28}
    a.process_menu_x=clamp(a.process_menu_x,8,max(8,a.width-236))
    a.process_menu_y=clamp(a.process_menu_y,8,max(8,a.height-h-8))
    a.process_menu_scroll=clamp(a.process_menu_scroll,0,max(0,len(a.process_menu_pids)-rows))
    return a.process_menu_x,a.process_menu_y,h,rows
}
process_menu_handle :: proc(a:^App) {
    if !a.process_menu_open||!a.click {return}
    x,y,h,rows:=process_menu_bounds(a)
    name:=string(a.process_menu_name[:a.process_menu_name_len])
    if !hit(a,x,y,228,h) {a.process_menu_open=false}
    else if a.process_menu_kill {
        if hit(a,x,y+34,228,28)&&a.process_kill==nil {process_kill_start_many(a,a.process_menu_pids[:])}
        else if hit(a,x,y+70,228,f32(rows)*28)&&a.process_kill==nil {
            index:=a.process_menu_scroll+int((a.mouse_y-y-70)/28)
            process_kill_start(a,a.process_menu_pids[index])
        }
    } else if hit(a,x,y+34,228,28) {
        process_pin_set(a,name,!process_pinned(a,name))
        a.process_menu_open=a.process_preference_error
    } else if hit(a,x,y+70,228,28)&&len(a.process_menu_pids)>0&&a.process_kill==nil {
        if len(a.process_menu_pids)==1 {process_kill_start(a,a.process_menu_pids[0])}
        else {a.process_menu_kill=true;a.process_menu_scroll=0}
    }
    // Consume clicks before the table, graphs or navigation can handle them.
    a.click=false
}
process_menu_item :: proc(a:^App,label:string,x,y:f32,enabled:bool=true,color:Color=TEXT) {
    if enabled&&a.mouse_x>=x&&a.mouse_x<x+228&&a.mouse_y>=y&&a.mouse_y<y+28 {rect(a,x+4,y,220,28,LINE)}
    fit_text(a,label,x+12,y+19,204,14,color if enabled else MUTED)
}
process_menu_draw :: proc(a:^App) {
    if !a.process_menu_open {return}
    x,y,h,rows:=process_menu_bounds(a)
    panel(a,x,y,228,h)
    name:=string(a.process_menu_name[:a.process_menu_name_len])
    fit_text(a,name,x+12,y+23,204,12,SOFT)
    if a.process_menu_kill {
        process_menu_item(a,"Killing all..." if a.process_kill!=nil else "Kill all",x,y+34,a.process_kill==nil,RED)
        for i in 0..<rows {
            node:=a.process_menu_pids[a.process_menu_scroll+i]
            process_menu_item(a,fmt.tprintf("Kill PID %d",node.pid),x,y+70+f32(i)*28,a.process_kill==nil,RED)
        }
        if len(a.process_menu_pids)>rows {
            track:=f32(rows)*28
            thumb:=max(12,track*f32(rows)/f32(len(a.process_menu_pids)))
            yy:=y+70+(track-thumb)*f32(a.process_menu_scroll)/f32(len(a.process_menu_pids)-rows)
            rect(a,x+224,yy,2,thumb,MUTED)
        }
    } else {
        process_menu_item(a,"Unpin" if process_pinned(a,name) else "Pin",x,y+34)
        kill_label:="Killing PID..." if a.process_kill!=nil else fmt.tprintf("Kill PID %d",a.process_menu_pids[0].pid) if len(a.process_menu_pids)==1 else "Kill PID..."
        process_menu_item(a,kill_label,x,y+70,len(a.process_menu_pids)>0&&a.process_kill==nil,RED)
    }
    rect(a,x+12,y+66,204,1,LINE)
    if a.process_menu_error_len>0||a.process_preference_error {
        message:=string(a.process_menu_error[:a.process_menu_error_len]) if a.process_menu_error_len>0 else "Preference could not be saved"
        fit_text(a,message,x+12,y+h-10,204,12,AMBER)
    }
}

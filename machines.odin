package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import glfw "vendor:glfw"

DEFAULT_COLLECTOR :: "~/.local/bin/task_master-collector"
Machine_Record :: struct { name, host, collector:string, port:u16, automatic, hidden:bool }
Machine_Tab :: struct { index:int, x,y,w,h:f32 }
Machine :: struct {
    state: ^Machine_State,
    frozen_graphs: ^Machine_State,
    name:[128]u8, name_len:int,
    host:[256]u8, host_len:int,
    collector:[1024]u8, collector_len:int,
    port:u16,
    order_rank:int,
    connection:^Remote_Connection,
    status:Connection_Status,
    message:[512]u8, message_len:int,
    received:time.Tick,
    has_sample, persistent, automatic:bool,
    persistence_stamp:f64,
    persistence_live_stamp:f64,
    setup_verifying, setup_failed:bool,
    setup_started, setup_check_after:time.Tick,
}
machine_state_init :: proc(m:^Machine_State) {
    m.cpu_pinned_slot=-1
    m.gpu_pinned_slot=-1
    m.memory_pinned_slot=-1
    m.process_order[int(View.GPU)].column=.Memory
    m.process_order[int(View.Memory)].column=.Memory
}
machines_init :: proc(a:^App) {
    m:=new(Machine)
    m.state=new(Machine_State)
    m.name_len=copy(m.name[:],"Local")
    machine_state_init(m.state)
    a.local_machine=m
    append(&a.machines,m)
    a.machine_count=1
    a.machine_next_rank=1
    a.machine=m.state
    a.machine_drag_index=-1;a.machine_drag_target=-1
    directory,err:=os.user_config_dir(context.temp_allocator)
    if err==nil {
        path:=fmt.tprintf("%s/task_master/machines.json",directory)
        if len(path)<len(a.machine_config_path) {a.machine_config_path_len=copy(a.machine_config_path[:],path)}
    }
}
machine_free :: proc(m:^Machine) {
    if m.connection!=nil {remote_connection_destroy(m.connection)}
    graph_freeze_release(m)
    if m.state!=nil {
        for frozen in m.state.process_frozen {process_frozen_destroy(frozen)}
        for names in m.state.expanded_processes {
            for name in names {delete(name)}
            delete(names)
        }
        metrics_destroy(&m.state.metrics)
        graph_smoothing_destroy(m.state.graph_smoothing)
        free(m.state)
    }
    free(m)
}
machines_disconnect :: proc(a:^App) {
    if a.machine_login_discovery!=nil {ssh_login_discovery_destroy(a.machine_login_discovery);a.machine_login_discovery=nil}
    for m in a.machines[:] {
        if m.connection!=nil {remote_connection_destroy(m.connection);m.connection=nil}
    }
}
machines_destroy :: proc(a:^App) {
    if a.machine_login_discovery!=nil {ssh_login_discovery_destroy(a.machine_login_discovery)}
    machines_candidates_clear(a)
    for m in a.machines[:] {machine_free(m)}
    for r in a.machine_saved_records {delete(r.host);delete(r.name);delete(r.collector)}
    delete(a.machine_saved_records)
    machine_terminal_destroy(a)
    for r in a.dismissed_machines {delete(r.host)}
    delete(a.dismissed_machines);delete(a.machine_tabs);delete(a.machines)
}
machine_host_valid :: proc(host:string)->bool {
    if len(host)==0||len(host)>256||host[0]=='-' {return false}
    for c in host {
        if !((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='.'||c=='_'||c=='-'||c=='@'||c==':'||c=='['||c==']'||c=='%') {return false}
    }
    return true
}
machine_text_valid :: proc(value:string,limit:int)->bool {
    if len(value)==0||len(value)>limit||!utf8.valid_string(value) {return false}
    for c in value {if c<32||c==127 {return false}}
    return true
}
machine_error_set :: proc(a:^App,message:string) {a.machine_error_len=copy(a.machine_error[:],message);a.dirty=true}
machine_find :: proc(a:^App,host:string,port:u16=0)->int {
    for m,i in a.machines[:] {
        if strings.equal_fold(host,string(m.host[:m.host_len]))&&port==m.port {return i}
    }
    return -1
}
machine_is_dismissed :: proc(a:^App,host:string,port:u16)->bool {
    for r in a.dismissed_machines {if strings.equal_fold(host,r.host)&&r.port==port {return true}}
    return false
}
machine_dismiss :: proc(a:^App,host:string,port:u16) {
    if !machine_is_dismissed(a,host,port) {append(&a.dismissed_machines,Machine_Record{host=strings.clone(host),port=port,hidden=true})}
}
machines_save :: proc(a:^App,skip:int=-1)->bool {
    if a.machine_config_path_len==0 {return false}
    records:=make([dynamic]Machine_Record,0,a.machine_count+len(a.dismissed_machines),context.temp_allocator)
    for m,i in a.machines[:] {
        if i==skip||(m!=a.local_machine&&!m.persistent) {continue}
        append(&records,Machine_Record{name=string(m.name[:m.name_len]),host=string(m.host[:m.host_len]),collector=string(m.collector[:m.collector_len]),port=m.port,automatic=m.automatic})
    }
    // Preserve saved hosts that failed this launch's passwordless check without
    // putting them in the live machine list or erasing their saved settings.
    for r in a.machine_saved_records {
        if machine_find(a,r.host,r.port)<0&&!machine_is_dismissed(a,r.host,r.port) {append(&records,r)}
    }
    for r in a.dismissed_machines {
        index:=machine_find(a,r.host,r.port)
        if index<0||index==skip {append(&records,r)}
    }
    data,err:=json.marshal(records[:],allocator=context.temp_allocator)
    if err!=nil {return false}
    path:=string(a.machine_config_path[:a.machine_config_path_len])
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
machine_connect :: proc(a:^App,m:^Machine) {
    if m.state==nil {
        m.state=new(Machine_State)
        machine_state_init(m.state)
        previous:=a.machine;a.machine=m.state
        process_preferences_load(a)
        a.machine=previous
    }
    if m==a.local_machine||m.connection!=nil {return}
    if a.persistence_enabled&&m.persistent&&!persistence_headless {return}
    // A new SSH sampler may take over recent cached/service history. Pausing
    // clears this pending handoff, so an explicit pause still leaves a gap.
    m.state.history_handoff_pending=!m.state.paused
    m.status=.Connecting
    m.connection=remote_connection_create(string(m.host[:m.host_len]),string(m.collector[:m.collector_len]),m.port,a.interval)
    if m.connection==nil {m.status=.Disconnected;m.message_len=copy(m.message[:],"Could not start the SSH worker.")}
}
machine_add :: proc(a:^App,host,name,collector:string,save:bool=true,persistent:bool=true,port:u16=0,automatic:bool=false,verified:bool=false)->bool {
    if !machine_host_valid(host) {machine_error_set(a,"Enter an SSH alias or user@host (configure ports in SSH config).");return false}
    if !machine_text_valid(name,128)||!machine_text_valid(collector,1024) {machine_error_set(a,"Name or collector path is too long or contains invalid characters.");return false}
    if machine_find(a,host,port)>=0 {machine_error_set(a,"That SSH host is already in the machine list.");return false}
    if !verified {
        machines_discovery_candidate(a,host,name,collector,port,persistent=persistent,automatic=automatic)
        machines_discovery_start(a)
        return true
    }
    m:=new(Machine)
    m.name_len=copy(m.name[:],name);m.host_len=copy(m.host[:],host);m.collector_len=copy(m.collector[:],collector)
    m.status=.Saved;m.persistent=persistent;m.automatic=automatic;m.port=port
    m.order_rank=a.machine_next_rank;a.machine_next_rank+=1
    if a.graphs_frozen {graph_freeze_capture(m)}
    append(&a.machines,m);a.machine_count=len(a.machines)
    if save&&!machines_save(a) {
        pop(&a.machines);a.machine_count=len(a.machines);machine_free(m)
        machine_error_set(a,"Could not save the machine list. Check config directory permissions.");return false
    }
    machine_connect(a,m)
    if persistence_headless {
        cache,ok:=persistence_cache_read(m)
        if ok {
            first_recent:=persistence_recent_start(cache.samples,persistence_wall_time()-HISTORY_SECONDS)
            cache.samples=cache.samples[first_recent:]
            _=persistence_cache_apply(a,m,cache,restore_snapshot=true)
        }
    }
    a.machine_error_len=0;a.dirty=true
    return true
}
machine_move :: proc(a:^App,from,to:int,save:bool=true) {
    // Local remains the first slot, including when a remote is dropped onto it.
    if from<=0||to<0||from>=a.machine_count||to>=a.machine_count {return}
    destination:=max(1,to)
    if from==destination {return}
    if save {a.machine_order_edited=true}
    selected:=a.machines[a.active_machine]
    moving:=a.machines[from]
    if from<destination {for i in from..<destination {a.machines[i]=a.machines[i+1]}}
    else {for i:=from;i>destination;i-=1 {a.machines[i]=a.machines[i-1]}}
    a.machines[destination]=moving
    for m,i in a.machines[:] {if m==selected {a.active_machine=i;break}}
    if save&&!machines_save(a) {machine_move(a,destination,from,save=false);machine_error_set(a,"Could not save the machine order.");a.machine_menu=true}
    a.dirty=true
}
machines_load :: proc(a:^App) {
    if a.machine_config_path_len==0 {return}
    data,err:=os.read_entire_file(string(a.machine_config_path[:a.machine_config_path_len]),context.temp_allocator)
    if err!=nil {return}
    records:[]Machine_Record
    if json.unmarshal(data,&records,allocator=context.temp_allocator)!=nil {machine_error_set(a,"Could not read machines.json.");return}
    for r in records {
        if r.hidden {machine_dismiss(a,r.host,r.port);continue}
        if r.host=="" {continue}
        name:=r.name;collector:=r.collector
        if name=="" {name=r.host};if collector=="" {collector=DEFAULT_COLLECTOR}
        append(&a.machine_saved_records,Machine_Record{host=strings.clone(r.host),name=strings.clone(name),collector=strings.clone(collector),port=r.port,automatic=r.automatic})
        machines_discovery_candidate(a,r.host,name,collector,r.port,automatic=r.automatic)
    }
}
machines_candidates_clear :: proc(a:^App) {
    for h in a.machine_login_candidates {delete(h.host);delete(h.name);delete(h.collector)}
    delete(a.machine_login_candidates);a.machine_login_candidates=nil
}
machines_discovery_candidate :: proc(a:^App,host,name,collector:string,port:u16,persistent:bool=true,automatic:bool=true,select_after:bool=false) {
    if !machine_host_valid(host)||!machine_text_valid(name,128)||!machine_text_valid(collector,1024) {return}
    for h in a.machine_login_candidates {if strings.equal_fold(h.host,host)&&h.port==port {return}}
    if machine_find(a,host,port)>=0 {return}
    rank:=a.machine_next_rank;a.machine_next_rank+=1
    append(&a.machine_login_candidates,SSH_Login_Candidate{host=strings.clone(host),name=strings.clone(name),collector=strings.clone(collector),port=port,rank=rank,persistent=persistent,automatic=automatic,select_after=select_after})
}
machines_discovery_start :: proc(a:^App) {
    if a.machine_login_discovery!=nil||len(a.machine_login_candidates)==0 {return}
    a.machine_login_discovery=ssh_login_discovery_create(a.machine_login_candidates[:])
    machines_candidates_clear(a)
    a.dirty=true
}
machines_discover :: proc(a:^App) {
    if a.machine_login_discovery!=nil {return}
    for r in a.machine_saved_records {
        if !machine_is_dismissed(a,r.host,r.port) {machines_discovery_candidate(a,r.host,r.name,r.collector,r.port,automatic=r.automatic)}
    }
    home,err:=os.user_home_dir(context.temp_allocator)
    if err==nil {
        for h in ssh_discover_hosts(home) {
            if machine_is_dismissed(a,h.host,h.port) {continue}
            machines_discovery_candidate(a,h.host,h.name,DEFAULT_COLLECTOR,h.port)
        }
    }
    machines_discovery_start(a)
    a.dirty=true
}
machines_discovery_poll :: proc(a:^App) {
    d:=a.machine_login_discovery
    if d==nil||a.machine_pointer_down||!sync.mutex_try_lock(&d.mutex) {return}
    ready:=make([dynamic]SSH_Login_Candidate,context.temp_allocator)
    for &h in d.candidates {
        if h.complete&&!h.delivered {h.delivered=true;append(&ready,h)}
    }
    finished:=d.completed==len(d.candidates)
    sync.mutex_unlock(&d.mutex)
    added_batch:=false
    for h in ready {
        if machine_is_dismissed(a,h.host,h.port)&&!h.select_after {continue}
        index:=machine_find(a,h.host,h.port)
        if index>=0 {
            m:=a.machines[index]
            // Offline hosts keep their cached place and name. A temporary
            // network failure must not erase the user's saved machine order.
            // Connected workers already provide a more precise current status.
            if m.automatic&&m.connection==nil {
                m.message_len=0
                if h.passed {machine_connect(a,m)}
                else {m.status=.Disconnected;m.message_len=copy(m.message[:],"Passwordless SSH is currently unavailable. Refresh to check again.")}
                a.dirty=true
            }
            continue
        }
        if !h.passed {
            if h.select_after {machine_error_set(a,"Passwordless SSH failed. Use ssh in a terminal first, then check again.")}
            continue
        }
        if h.select_after {
            for r,i in a.dismissed_machines {
                if strings.equal_fold(r.host,h.host)&&r.port==h.port {delete(r.host);ordered_remove(&a.dismissed_machines,i);break}
            }
        }
        if !machine_add(a,h.host,h.name,h.collector,save=false,persistent=h.persistent,port=h.port,automatic=h.automatic,verified=true) {continue}
        added:=a.machines[a.machine_count-1]
        added_batch=true
        added.order_rank=h.rank
        if !a.machine_order_edited {
            position:=a.machine_count-1
            for m,i in a.machines[:] {if i>0&&m.order_rank>h.rank {position=i;break}}
            machine_move(a,a.machine_count-1,position,save=false)
        }
        if h.select_after {machine_select(a,machine_find(a,h.host,h.port))}
        a.dirty=true
    }
    if added_batch&&!persistence_headless&&!machines_save(a) {machine_error_set(a,"Could not cache discovered machines. Check config directory permissions.");a.machine_menu=true}
    if finished {ssh_login_discovery_destroy(d);a.machine_login_discovery=nil;machines_discovery_start(a);a.dirty=true}
}
machine_select :: proc(a:^App,index:int) {
    a.process_cache.valid=false
    if index<0||index>=a.machine_count {return}
    m:=a.machines[index]
    machine_connect(a,m)
    a.active_machine=index;a.machine=m.state
    a.process_menu_open=false;a.machine_menu=false;a.table_w=0;a.cpu_graph_w=0;a.dirty=true
    if a.renderer.window!=nil {glfw.SetWindowTitle(a.renderer.window,strings.clone_to_cstring(fmt.tprintf("task_master - %s",string(m.name[:m.name_len])),context.temp_allocator))}
}
machine_remove :: proc(a:^App,index:int) {
    if index<0||index>=a.machine_count||a.machines[index]==a.local_machine {return}
    old:=a.machines[index]
    was_dismissed:=machine_is_dismissed(a,string(old.host[:old.host_len]),old.port)
    machine_dismiss(a,string(old.host[:old.host_len]),old.port)
    if !machines_save(a,skip=index) {
        if !was_dismissed {delete(a.dismissed_machines[len(a.dismissed_machines)-1].host);pop(&a.dismissed_machines)}
        machine_error_set(a,"Could not save the machine list.");return
    }
    selected:=a.machines[a.active_machine]
    ordered_remove(&a.machines,index);a.machine_count=len(a.machines)
    if selected==old {selected=a.local_machine}
    for m,i in a.machines[:] {if m==selected {machine_select(a,i);break}}
    machine_free(old)
}
machines_sample :: proc(a:^App,now:f64) {
    if a.persistence_enabled&&!persistence_headless {persistence_reader_poll(a,now)}
    selected:=a.machine;local:=a.local_machine.state
    if !a.persistence_enabled&&!local.paused&&persistence_local_needs_prime {
        if local.metrics._nvml.__handle==nil {metrics_init_devices(&local.metrics)}
        else {metrics_sample(&local.metrics,0)}
        local.last_sample=now
        persistence_local_needs_prime=false
    }
    if (!a.persistence_enabled||persistence_local_handoff_pending)&&!local.paused&&now-local.last_sample>=a.interval {
        metrics_sample(&local.metrics,now-local.last_sample);local.last_sample=now;a.machine=local;history_push(a)
        a.local_machine.has_sample=true;a.local_machine.status=.Live;a.local_machine.received=time.tick_now()
        if selected==local {a.dirty=true}
    }
    for m,i in a.machines[:] {
        c:=m.connection
        if c==nil||!sync.mutex_try_lock(&c.mutex) {continue}
        status_changed:=m.status!=c.status||m.message_len!=c.message_len||m.message!=c.message
        m.status=c.status;m.message=c.message;m.message_len=c.message_len;m.received=c.received
        sync.mutex_unlock(&c.mutex)
        if !m.state.paused {
            for {
                received_ok,received,sample_break:=remote_connection_take(c,&m.state.metrics)
                if !received_ok {break}
                m.has_sample=true
                a.machine=m.state
                switch sample_break {
                case .Session:
                    a.history_handoff_pending=a.history_handoff_pending||a.history_connected
                    a.history_connected=false
                case .Dropped:
                    a.history_connected=false
                    a.history_handoff_pending=false
                    a.history_handoff_timestamp=0
                case .None:
                }
                history_push(a,persistence_wall_time()-time.duration_seconds(time.tick_since(received)))
                if a.active_machine==i {a.dirty=true}
            }
        }
        if status_changed {a.dirty=true}
    }
    a.machine=selected
    // Connection ages and stale indicators need a one-second heartbeat, not
    // another full redraw for every input event when no snapshot changed.
    if now-a.machine_status_poll>=1 {
        a.machine_status_poll=now
        if a.machine_menu||a.machines[a.active_machine]!=a.local_machine||a.persistence_enabled {a.dirty=true}
    }
}
machine_stale :: proc(a:^App,m:^Machine)->bool {return (m.host_len>0||a.persistence_enabled)&&(!m.has_sample||m.status!=.Live||time.duration_seconds(time.tick_since(m.received))>max(3,2*a.interval+1))}
machine_color :: proc(a:^App,m:^Machine)->Color {
    if m.host_len==0&&!a.persistence_enabled {return GREEN};if m.status==.Saved {return MUTED};if m.status==.Disconnected {return RED}
    if machine_stale(a,m) {return AMBER};return GREEN
}
machine_status_message :: proc(m:^Machine)->string {
    if !m.has_sample&&m.state!=nil&&m.state.paused {return "Telemetry is paused. Press Space to receive samples."}
    message:=strings.trim_space(string(m.message[:m.message_len]))
    message,_=strings.replace_all(message,"\r","",context.temp_allocator)
    message,_=strings.replace_all(message,"\n"," / ",context.temp_allocator)
    if message!=""&&message!="Connecting" {return message}
    switch m.status {
    case .Saved: return "Waiting for the SSH telemetry connection."
    case .Connecting: return "Opening the SSH telemetry connection."
    case .Disconnected: return "SSH connection is unavailable; retrying automatically."
    case .Live: return "No telemetry sample received."
    }
    return ""
}
// Return true when there is no remote telemetry to draw. Showing the actual
// connection state here keeps unavailable machines from looking like idle PCs.
machine_connection_draw :: proc(a:^App)->bool {
    m:=a.machines[a.active_machine]
    if m==a.local_machine&&!a.persistence_enabled {return false}
    if m.has_sample&&!machine_stale(a,m) {return false}
    host:="Local persistence" if m==a.local_machine else string(m.host[:m.host_len])
    if m.port!=0 {host=fmt.tprintf("[%s]:%d",host,m.port) if strings.contains(host,":") else fmt.tprintf("%s:%d",host,m.port)}
    status:="Saved" if m.status==.Saved else "Connecting" if m.status==.Connecting else "Disconnected" if m.status==.Disconnected else "Stale telemetry" if m.has_sample else "Connected"
    color:=machine_color(a,m)
    x,w:=a.content_x,a.width-2*a.content_x
    if m.has_sample {
        if m.status==.Connecting {status="Reconnecting"}
        detail:=fmt.tprintf("%s / %s / last sample %.0fs ago",host,status,time.duration_seconds(time.tick_since(m.received)))
        if m.message_len>0 {detail=fmt.tprintf("%s / %s",detail,machine_status_message(m))}
        fit_text(a,detail,x,68,w,12,color)
        return false
    }
    a.cpu_graph_w=0;a.cpu_graph_h=0
    panel(a,x,72,w,84)
    rect(a,x+18,94,5,5,color)
    fit_text(a,fmt.tprintf("%s / %s",host,status),x+31,101,w-49,13,color)
    fit_text(a,machine_status_message(m),x+18,130,w-36,14,SOFT)
    return true
}
machine_inline :: proc(a:^App,index:int)->bool {
    for t in a.machine_tabs {if t.index==index&&t.y==a.content_x {return true}}
    return false
}
machine_tab_at :: proc(a:^App,x,y:f32)->int {
    // Popup rows are appended after header tabs.
    for i:=len(a.machine_tabs)-1;i>=0;i-=1 {
        t:=a.machine_tabs[i]
        if x>=t.x&&x<t.x+t.w&&y>=t.y&&y<t.y+t.h {return i}
    }
    return -1
}
machine_pointer_press :: proc(a:^App,x,y:f32)->bool {
    if a.machine_dialog {return false}
    hit:=machine_tab_at(a,x,y)
    if hit<0 {return false}
    a.machine_pointer_down=true;a.machine_dragging=false;a.machine_drag_index=a.machine_tabs[hit].index
    a.machine_drag_target=a.machine_drag_index;a.machine_drag_x=x;a.machine_drag_y=y;a.dirty=true
    return true
}
machine_pointer_motion :: proc(a:^App,x,y:f32) {
    if machine_refresh_hover(a,x,y)||machine_refresh_hover(a,a.mouse_x,a.mouse_y) {a.dirty=true}
    if !a.machine_pointer_down||a.machine_drag_index<=0 {return}
    if abs(x-a.machine_drag_x)+abs(y-a.machine_drag_y)>5 {a.machine_dragging=true}
    if !a.machine_dragging {return}
    hit:=machine_tab_at(a,x,y)
    if hit>=0 {
        index:=a.machine_tabs[hit].index
        if index==-1 {a.machine_menu=true}
        else {a.machine_drag_target=index}
    }
    a.dirty=true
}
machine_pointer_release :: proc(a:^App,x,y:f32) {
    source:=a.machine_drag_index
    target:=machine_tab_at(a,x,y)
    a.machine_pointer_down=false
    if a.machine_dragging {
        if target>=0&&a.machine_tabs[target].index>=0 {machine_move(a,source,a.machine_tabs[target].index)}
    } else if target>=0&&a.machine_tabs[target].index==source {
        if source==-1||source==a.active_machine {a.machine_menu=!a.machine_menu;a.process_menu_open=false}
        else {machine_select(a,source)}
    }
    a.machine_dragging=false;a.machine_drag_index=-1;a.machine_drag_target=-1;a.dirty=true
}
machine_header :: proc(a:^App,x,w:f32) {
    y:=a.content_x
    clear(&a.machine_tabs)
    widths:=make([]f32,a.machine_count,context.temp_allocator)
    for m,i in a.machines[:] {
        widths[i]=min(180,renderer_text_width(&a.renderer,string(m.name[:m.name_len]),13*a.scale)/a.scale+31)
        if m==a.machines[a.active_machine]&&m.state!=nil&&m.state.paused {widths[i]=min(180,widths[i]+54)}
    }
    budget:=max(0,w-88)
    used:=f32(0)
    selected_width:=min(widths[a.active_machine],budget)
    local_width:=min(widths[0],budget)
    if a.active_machine>0&&budget>=120 {
        local_width=min(local_width,budget/2)
        selected_width=min(selected_width,budget-local_width-16)
    }
    active_room:=selected_width
    for m,i in a.machines[:] {
        if budget<32 {continue}
        item_w:=min(widths[i],budget)
        if i==0&&a.active_machine>0&&budget>=120 {item_w=local_width}
        if i==a.active_machine {item_w=selected_width}
        reserve:=active_room if i!=a.active_machine else f32(0)
        if used+item_w+8+reserve>budget&&i!=a.active_machine {continue}
        if i==a.active_machine {active_room=0}
        xx:=x+used
        append(&a.machine_tabs,Machine_Tab{i,xx,y,item_w,28})
        if i==a.active_machine {rect(a,xx,y+27,item_w-4,1,SOFT)}
        if a.machine_dragging&&a.machine_drag_target==i {rect(a,xx-3,y+3,2,23,CYAN)}
        rect(a,xx+3,y+10,5,5,machine_color(a,m))
        label:=string(m.name[:m.name_len])
        if m.state!=nil&&m.state.paused {label=fmt.tprintf("%s (paused)",label)}
        else if m.has_sample&&machine_stale(a,m) {label=fmt.tprintf("%s (stale)",label)}
        fit_text(a,label,xx+14,y+17,item_w-20,13,TEXT if i==a.active_machine else MUTED)
        used+=item_w+8
    }
    // Keep a details dropdown even when all hosts fit; hidden hosts share it.
    a.machine_overflow_x=x+used
    append(&a.machine_tabs,Machine_Tab{-1,x+used,y,24,28})
    text(a,"v",x+used+6,y+15,12,MUTED)
    a.machine_menu_x=min(x+used,max(16,a.width-308));a.machine_menu_w=280
    if hit(a,x+used+27,y,26,28)&&!a.machine_dialog {machine_dialog_open(a);a.click=false}
    text(a,"+",x+used+33,y+18,19,SOFT)
    refresh_x:=x+used+54
    busy:=a.machine_login_discovery!=nil
    hovering:=machine_refresh_hover(a,a.mouse_x,a.mouse_y)
    if hit(a,refresh_x,y,26,28)&&!a.machine_dialog {
        if !busy {machines_discover(a)}
        a.click=false;a.dirty=true
    }
    color:=AMBER if busy else TEXT if hovering else SOFT
    cx,cy,r:=refresh_x+13,y+12,f32(6)
    start,finish:=f32(-0.45)*math.PI,f32(1.15)*math.PI
    for i in 0..<14 {
        theta0:=start+(finish-start)*f32(i)/14
        theta1:=start+(finish-start)*f32(i+1)/14
        stroke(a,cx+r*math.cos(theta0),cy+r*math.sin(theta0),cx+r*math.cos(theta1),cy+r*math.sin(theta1),1.25,color)
    }
    ex,ey:=cx+r*math.cos(finish),cy+r*math.sin(finish)
    tx,ty:=-math.sin(finish),math.cos(finish)
    stroke(a,ex,ey,ex-3*tx-2*ty,ey-3*ty+2*tx,1.25,color)
    stroke(a,ex,ey,ex-3*tx+2*ty,ey-3*ty-2*tx,1.25,color)
}
machine_refresh_hover :: proc(a:^App,x,y:f32)->bool {
    return !a.machine_dialog&&x>=a.machine_overflow_x+54&&x<a.machine_overflow_x+80&&y>=a.content_x&&y<a.content_x+28
}
machine_dialog_open :: proc(a:^App) {
    a.machine_menu=false
    a.process_menu_open=false
    a.machine_dialog=true
    a.machine_input={}
    a.machine_input_len={}
    a.machine_input_focus=0
    a.machine_error_len=0
    a.machine_dialog_scroll=0
    machines_discover(a)
    a.dirty=true
}
machine_dialog_submit :: proc(a:^App) {
    host:=strings.trim_space(string(a.machine_input[0][:a.machine_input_len[0]]))
    if !machine_host_valid(host) {machine_error_set(a,"Enter an SSH alias or user@host that already works without a password.");return}
    existing:=machine_find(a,host)
    if existing>=0 {machine_select(a,existing);return}
    machines_discovery_candidate(a,host,host,DEFAULT_COLLECTOR,0,automatic=false,select_after=true)
    machines_discovery_start(a)
    machine_error_set(a,"Checking passwordless SSH...")
}
machine_dialog_bounds :: proc(a:^App)->(x,y,w,h:f32) {
    w=min(760,a.width-32)
    h=min(540,a.height-32)
    return (a.width-w)/2,max(16,(a.height-h)/2),w,h
}
machine_dialog_rows :: proc(a:^App,h:f32)->int {return max(0,int((h-238)/64))}
machine_setup_label :: proc(a:^App,m:^Machine)->string {
    if machine_terminal_busy(a,m) {return "Setup terminal open"}
    if m.setup_verifying {return "Checking telemetry after installation..."}
    if m.setup_failed {
        if m.state!=nil&&m.state.metrics.cpu_power_permission_denied {return "Telemetry connected / power access still denied"}
        return fmt.tprintf("Setup not verified / %s",machine_status_message(m))
    }
    if m.status==.Live&&!machine_stale(a,m) {
        if m.state!=nil&&m.state.metrics.cpu_power_permission_denied {return "Telemetry working / install power access"}
        return "Working / telemetry connected"
    }
    if m.status==.Connecting {return "Starting telemetry..."}
    if m.status==.Saved {return "Passwordless SSH verified / starting telemetry"}
    return machine_status_message(m)
}
machine_overlay_handle :: proc(a:^App) {
    if a.machine_dialog {
        if a.click {
            x,y,w,h:=machine_dialog_bounds(a)
            rows:=machine_dialog_rows(a,h)
            a.machine_dialog_scroll=clamp(a.machine_dialog_scroll,0,max(0,a.machine_count-1-rows))
            for row in 0..<rows {
                index:=1+a.machine_dialog_scroll+row
                if index>=a.machine_count {break}
                yy:=y+103+f32(row)*64
                m:=a.machines[index]
                if hit(a,x+w-207,yy+12,96,32) {machine_terminal_open(a,m,install=true)}
                else if hit(a,x+w-103,yy+12,83,32) {machine_terminal_open(a,m)}
                else if hit(a,x+20,yy,w-235,58) {machine_select(a,index);a.machine_dialog=false}
            }
            if hit(a,x+20,y+h-93,w-154,34) {a.machine_input_focus=0}
            if hit(a,x+w-124,y+h-93,104,34) {machine_dialog_submit(a)}
            if hit(a,x+w-129,y+49,109,30) {machines_discover(a)}
            if hit(a,x+w-100,y+h-42,80,26)||hit(a,x+w-38,y+12,24,24) {a.machine_dialog=false}
            a.click=false
        }
        return
    }
    // Handle these before the open menu consumes an outside click; header
    // rendering then sees click=false and cannot launch a second refresh.
    if hit(a,a.machine_overflow_x+54,a.content_x,26,28) {
        if a.machine_login_discovery==nil {machines_discover(a)}
        a.machine_menu=false;a.click=false;a.dirty=true
        return
    }
    if a.machine_menu&&hit(a,a.machine_overflow_x+27,a.content_x,26,28) {machine_dialog_open(a);a.click=false;return}
    if !a.machine_menu {return}
    if a.click {
        bottom:=a.content_x+48
        for t in a.machine_tabs {if t.y>a.content_x+28 {bottom=max(bottom,t.y+t.h+8)}}
        if hit(a,a.machine_menu_x+a.machine_menu_w-65,bottom+8,53,23) {machine_remove(a,a.active_machine);a.click=false;return}
        for t in a.machine_tabs {
            if t.y<=a.content_x+28 {continue}
            if hit(a,t.x+t.w,t.y,32,t.h) {machine_remove(a,t.index);a.click=false;return}
        }
        a.machine_menu=false;a.click=false
    }
}
machine_overlay_draw :: proc(a:^App) {
    if a.machine_menu {
        x,y,w:=a.machine_menu_x,a.content_x+32,a.machine_menu_w
        m:=a.machines[a.active_machine]
        hidden:=make([dynamic]int,0,a.machine_count,context.temp_allocator)
        for _,i in a.machines[:] {if !machine_inline(a,i) {append(&hidden,i)}}
        rows:=min(len(hidden),max(1,int((a.height-y-154)/32)))
        a.machine_menu_scroll=clamp(a.machine_menu_scroll,0,max(0,len(hidden)-rows))
        bottom:=y+16+f32(rows)*32
        h:=bottom-y+76
        if m.message_len>0||a.machine_error_len>0 {h+=44}
        panel(a,x,y,w,h)
        for row in 0..<rows {
            index:=hidden[a.machine_menu_scroll+row];item:=a.machines[index]
            yy:=y+8+f32(row)*32
            append(&a.machine_tabs,Machine_Tab{index,x+4,yy,w-40,32})
            if index==a.active_machine {rect(a,x+4,yy,w-8,32,LINE)}
            if a.machine_dragging&&a.machine_drag_target==index {rect(a,x+5,yy,2,32,CYAN)}
            rect(a,x+12,yy+14,5,5,machine_color(a,item))
            fit_text(a,string(item.name[:item.name_len]),x+26,yy+22,w-114,13)
            if index<9 {right_text(a,fmt.tprintf("Ctrl+%d",index+1),x+w-38,yy+22,12,MUTED)}
            if item!=a.local_machine {text(a,"x",x+w-24,yy+22,12,MUTED)}
        }
        status:="Local machine"
        if m.host_len>0 {
            status=string(m.host[:m.host_len])
            age:="Saved SSH host / awaiting telemetry" if m.status==.Saved else "Checking SSH access..." if m.status==.Connecting&&m.connection==nil else "Connecting..." if m.status==.Connecting else "Offline / refresh to check" if m.status==.Disconnected&&m.connection==nil else "Disconnected / retrying" if m.status==.Disconnected else "Connected"
            if m.has_sample {age=fmt.tprintf("%s / last sample %.0fs ago%s",age,time.duration_seconds(time.tick_since(m.received))," / paused" if m.state.paused else "")}
            fit_text(a,age,x+12,bottom+45,w-24,12,MUTED)
        } else {text(a,"Arrows / A D switch machines",x+12,bottom+45,12,MUTED)}
        fit_text(a,status,x+12,bottom+22,w-90 if m!=a.local_machine else w-24,12,SOFT)
        if m!=a.local_machine {
            text(a,"Remove",x+w-65,bottom+22,12,MUTED)
        }
        message:=string(m.message[:m.message_len])
        if a.machine_error_len>0 {message=string(a.machine_error[:a.machine_error_len])}
        if len(message)>0 {
            fit_text(a,message,x+12,bottom+73,w-24,12,AMBER)
            text(a,"SSH uses your keys, agent and known_hosts.",x+12,bottom+94,12,MUTED)
        }
    }
    if !a.machine_dialog {
        if !a.machine_dragging&&machine_refresh_hover(a,a.mouse_x,a.mouse_y) {
            label:="Checking machines" if a.machine_login_discovery!=nil else "Refresh machines"
            w:=renderer_text_width(&a.renderer,label,12*a.scale)/a.scale+20
            x:=clamp(a.machine_overflow_x+54,f32(8),max(8,a.width-w-8))
            panel(a,x,a.content_x+32,w,29)
            text(a,label,x+10,a.content_x+52,12,SOFT)
        }
        return
    }
    rect(a,0,0,a.width,a.height,Color{0,0,0,0.70})
    x,y,w,h:=machine_dialog_bounds(a)
    panel(a,x,y,w,h)
    text(a,"SSH machines",x+20,y+32,20)
    text(a,"x",x+w-30,y+30,15,MUTED)
    fit_text(a,"Only machines with verified passwordless SSH appear here.",x+20,y+63,w-164,13,SOFT)
    text(a,"Checking..." if a.machine_login_discovery!=nil else "Refresh",x+w-111,y+68,13,AMBER if a.machine_login_discovery!=nil else TEXT)
    rows:=machine_dialog_rows(a,h)
    a.machine_dialog_scroll=clamp(a.machine_dialog_scroll,0,max(0,a.machine_count-1-rows))
    for row in 0..<rows {
        index:=1+a.machine_dialog_scroll+row
        if index>=a.machine_count {break}
        m:=a.machines[index]
        yy:=y+103+f32(row)*64
        rect(a,x+20,yy,w-40,58,BG)
        rect(a,x+30,yy+16,5,5,machine_color(a,m))
        fit_text(a,string(m.name[:m.name_len]),x+45,yy+22,w-278,14)
        fit_text(a,machine_setup_label(a,m),x+30,yy+44,w-250,12,MUTED)
        panel(a,x+w-207,yy+12,96,32)
        text(a,"Install / fix",x+w-199,yy+34,12,MUTED if machine_terminal_busy(a,m) else TEXT)
        panel(a,x+w-103,yy+12,83,32)
        text(a,"Terminal",x+w-93,yy+34,12)
    }
    if a.machine_count==1 {
        fit_text(a,"Checking saved SSH hosts..." if a.machine_login_discovery!=nil else "No passwordless SSH machines found.",x+20,y+130,w-40,14,SOFT)
        fit_text(a,"Set up SSH outside task_master, then refresh or check an unlisted host below.",x+20,y+157,w-40,12,MUTED)
    } else if a.machine_count-1>rows {
        right_text(a,fmt.tprintf("%d-%d of %d / scroll for more",a.machine_dialog_scroll+1,min(a.machine_count-1,a.machine_dialog_scroll+rows),a.machine_count-1),x+w-20,y+h-140,11,MUTED)
    }
    fit_text(a,"Install / fix opens a terminal for installation and any administrator password.",x+20,y+h-120,w-40,12,MUTED)
    rect(a,x+20,y+h-93,w-154,34,LINE)
    s:=string(a.machine_input[0][:a.machine_input_len[0]])
    fit_text(a,s if len(s)>0 else "Unlisted SSH alias or user@host",x+29,y+h-70,w-179,13,TEXT if len(s)>0 else MUTED)
    cursor_x:=min(x+w-143,x+29+renderer_text_width(&a.renderer,s,13*a.scale)/a.scale)
    rect(a,cursor_x,y+h-85,1,18,SOFT)
    panel(a,x+w-124,y+h-93,104,34)
    text(a,"Check SSH",x+w-113,y+h-70,13)
    if a.machine_error_len>0 {fit_text(a,string(a.machine_error[:a.machine_error_len]),x+20,y+h-43,w-132,12,AMBER)}
    text(a,"Done",x+w-83,y+h-22,14,MUTED)
}
machine_input_append :: proc(a:^App,value:string) {
    index:=a.machine_input_focus
    for c in value {
        if c<32||c==127 {continue}
        if index==0&&c>127 {continue}
        bytes,count:=utf8.encode_rune(c)
        limit:=256 if index==0 else 128 if index==1 else 1024
        if a.machine_input_len[index]+count>limit {break}
        copied:=copy(a.machine_input[index][a.machine_input_len[index]:],bytes[:count])
        a.machine_input_len[index]+=copied
    }
    a.machine_error_len=0
    a.dirty=true
}
machine_char_callback :: proc "c" (window:glfw.WindowHandle,codepoint:rune) {
    context=runtime.default_context()
    a:=cast(^App)glfw.GetWindowUserPointer(window)
    if a==nil||!a.machine_dialog {return}
    bytes,count:=utf8.encode_rune(rune(codepoint))
    machine_input_append(a,string(bytes[:count]))
}
machine_key_callback :: proc "c" (window:glfw.WindowHandle,key,scancode,action,mods:i32) {
    context=runtime.default_context()
    a:=cast(^App)glfw.GetWindowUserPointer(window)
    if a!=nil&&a.graph_control_drag>=0&&(key==glfw.KEY_LEFT_CONTROL||key==glfw.KEY_RIGHT_CONTROL) {
        a.graph_control_raw=a.history_seconds if a.graph_control_drag==0 else a.interval
        a.graph_control_ctrl=action!=glfw.RELEASE||glfw.GetKey(window,glfw.KEY_LEFT_CONTROL)==glfw.PRESS||glfw.GetKey(window,glfw.KEY_RIGHT_CONTROL)==glfw.PRESS
        a.dirty=true
    }
    if a==nil||action==glfw.RELEASE {return}
    if key==glfw.KEY_ESCAPE&&a.process_menu_open {
        a.process_menu_open=false;a.dirty=true
        return
    }
    if key==glfw.KEY_ESCAPE&&(a.machine_dialog||a.machine_menu) {
        a.machine_dialog=false;a.machine_menu=false;a.dirty=true
        return
    }
    if !a.machine_dialog {
        if action!=glfw.PRESS {return}
        if key==glfw.KEY_ESCAPE||key==glfw.KEY_Q {glfw.SetWindowShouldClose(window,true)}
        if key==glfw.KEY_N&&mods&glfw.MOD_CONTROL!=0 {machine_dialog_open(a);return}
        if mods&glfw.MOD_CONTROL!=0&&key>=glfw.KEY_1&&key<=glfw.KEY_9 {machine_select(a,int(key-glfw.KEY_1));return}
        if mods&(glfw.MOD_CONTROL|glfw.MOD_ALT|glfw.MOD_SUPER)==0 {
            if key==glfw.KEY_SPACE {a.paused=!a.paused;a.history_connected=false;a.history_handoff_pending=false;a.history_handoff_timestamp=0;a.dirty=true}
            if key==glfw.KEY_F {graph_freeze_toggle(a)}
            if key>=glfw.KEY_1&&key<=glfw.KEY_4 {a.view=View(key-glfw.KEY_1);a.dirty=true}

            if key==glfw.KEY_LEFT||key==glfw.KEY_A {machine_select(a,(a.active_machine+a.machine_count-1)%a.machine_count)}
            else if key==glfw.KEY_RIGHT||key==glfw.KEY_D {machine_select(a,(a.active_machine+1)%a.machine_count)}
        }
        return
    }
    if key==glfw.KEY_TAB {
        a.machine_input_focus=0
    } else if key==glfw.KEY_BACKSPACE {
        index:=a.machine_input_focus
        n:=a.machine_input_len[index]
        if n>0 {_,size:=utf8.decode_last_rune(a.machine_input[index][:n]);a.machine_input_len[index]-=size}
    } else if key==glfw.KEY_ENTER||key==glfw.KEY_KP_ENTER {machine_dialog_submit(a)}
    else if key==glfw.KEY_V&&mods&glfw.MOD_CONTROL!=0 {machine_input_append(a,glfw.GetClipboardString(window))}
    else if key==glfw.KEY_U&&mods&glfw.MOD_CONTROL!=0 {a.machine_input_len[a.machine_input_focus]=0}
    a.dirty=true
}

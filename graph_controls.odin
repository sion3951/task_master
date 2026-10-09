package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import glfw "vendor:glfw"

Graph_Control_Bounds :: struct {x,y,w,h:f32}
Graph_Settings :: struct {max_time, polling_seconds:f64}
GRAPH_TIME_DEFAULT :: 90.0
GRAPH_POLL_DEFAULT :: 1.0
GRAPH_TIME_SNAPS :: [?]f64{10,15,20,30,45,60,90,120,150,180,210,240,270,300}
GRAPH_POLL_SNAPS :: [?]f64{0.1,0.2,0.25,0.5,0.75,1,1.5,2,3,5,7.5,10}

graph_seconds_label :: proc(value:f64)->string {
    if abs(value-math.round(value))<0.0005 {return fmt.tprintf("%.0f s",value)}
    number:=fmt.tprintf("%.3f",value)
    for len(number)>0&&number[len(number)-1]=='0' {number=number[:len(number)-1]}
    return fmt.tprintf("%s s",number)
}
graph_time_axis_label :: proc(a:^App)->string {return fmt.tprintf("-%s",graph_seconds_label(a.history_seconds))}

graph_settings_path :: proc()->string {
    base,err:=os.user_config_dir(context.temp_allocator)
    if err!=nil {return ""}
    return fmt.tprintf("%s/task_master/graphs.json",base)
}
graph_settings_apply :: proc(a:^App,max_time,polling:f64) {
    if !remote_nonnegative(max_time)||!remote_nonnegative(polling) {return}
    a.history_seconds=clamp(max_time,10,300)
    interval:=clamp(polling,0.1,10)
    if a.interval!=interval {
        a.interval=interval
        for m in a.machines {if m.connection!=nil {remote_connection_set_interval(m.connection,interval)}}
    }
    a.dirty=true
}
graph_settings_poll :: proc(a:^App) {
    path:=graph_settings_path()
    if path=="" {return}
    data,err:=os.read_entire_file(path,context.temp_allocator)
    if err!=nil||len(data)>4096||string(data)==a.graph_settings_data {return}
    settings:Graph_Settings
    if json.unmarshal(data,&settings,allocator=context.temp_allocator)!=nil||
        !remote_nonnegative(settings.max_time)||!remote_nonnegative(settings.polling_seconds)||
        settings.max_time<10||settings.max_time>300||settings.polling_seconds<0.1||settings.polling_seconds>10 {return}
    delete(a.graph_settings_data);a.graph_settings_data=strings.clone(string(data))
    graph_settings_apply(a,settings.max_time,settings.polling_seconds)
}
graph_settings_load :: proc(a:^App) {
    a.interval=GRAPH_POLL_DEFAULT;a.history_seconds=GRAPH_TIME_DEFAULT
    a.graph_control_drag=-1
    graph_settings_poll(a)
}
graph_settings_save :: proc(a:^App) {
    settings:=Graph_Settings{max_time=a.history_seconds,polling_seconds=a.interval}
    data,err:=json.marshal(settings,allocator=context.temp_allocator)
    a.graph_settings_error=err!=nil
    if err==nil {
        a.graph_settings_error=!persistence_atomic_write(graph_settings_path(),data)
        if !a.graph_settings_error {delete(a.graph_settings_data);a.graph_settings_data=strings.clone(string(data))}
    }
    if a.graph_settings_error {fmt.eprintln("Could not save task_master graph controls.")}
    a.graph_settings_pending=false;a.graph_settings_saved_at=time.tick_now()
    a.dirty=true
}
graph_settings_flush :: proc(a:^App) {
    if a.graph_settings_pending&&time.duration_seconds(time.tick_since(a.graph_settings_saved_at))>=0.1 {graph_settings_save(a)}
}

// Cadence remains useful for caches written before continuity was recorded.
history_segment_interval :: proc(left,right:^CPU_Sample)->f64 {
    return max(0.1,max(left.polling_seconds if left.polling_seconds>0 else 1,right.polling_seconds if right.polling_seconds>0 else 1))
}

// A fresh predecessor survives a sampler handoff, including the short service
// refresh at launch. Longer downtime still starts a separate trace.
history_handoff_contiguous :: proc(previous,current,previous_interval,current_interval:f64)->bool {
    interval:=max(previous_interval,current_interval)
    return current>previous&&current-previous<=max(3,2*interval+1)
}

// Rendering/SSH delays and cadence changes do not mean samples were lost.
// New samples record actual sampling breaks; legacy caches keep their heuristic.
history_segment_contiguous :: proc(left,right:^CPU_Sample)->bool {
    if right.timestamp<=left.timestamp {return false}
    if right.continuity_recorded {return !right.gap_before}
    return right.timestamp-left.timestamp<=2*history_segment_interval(left,right)
}

graph_controls_height :: proc(w:f32)->f32 {return 60 if w<300 else 28}
graph_controls_draw :: proc(a:^App,x,y,w:f32) {
    stacked:=w<300
    width:=min(w,f32(144))
    labels:=[2]string{"Max time","Polling"}
    values:=[2]f64{a.history_seconds,a.interval}
    for label,i in labels {
        xx,yy:=x+f32(i)*156,y
        if stacked {xx,yy=x,y+f32(i)*32}
        bounds:=Graph_Control_Bounds{xx,yy,width,28}
        if !a.clip_active||yy+28>a.clip_top&&yy<a.clip_bottom {
            if a.clip_active {
                bounds.y=max(yy,a.clip_top);bounds.h=min(yy+28,a.clip_bottom)-bounds.y
            }
            a.graph_controls[i]=bounds
        }
        hovered:=graph_control_hovered(a,a.mouse_x,a.mouse_y)==i
        tint:=TEXT if hovered||a.graph_control_drag==i else SOFT
        rounded_rect(a,xx,yy,width,28,4,LINE if hovered||a.graph_control_drag==i else PANEL)
        text(a,label,xx+8,yy+18,12,MUTED)
        right_text(a,graph_seconds_label(values[i]),xx+width-8,yy+18,12,tint)
        // A quiet underline indicates position; clicking never seeks this track.
        fraction:=f32((values[i]-10)/290) if i==0 else f32(math.ln(values[i]/0.1)/math.ln(100.0))
        rect(a,xx+5,yy+26,(width-10)*clamp(fraction,0,1),1,SOFT)
    }
}
graph_control_hovered :: proc(a:^App,x,y:f32)->int {
    if a.machine_dialog||a.machine_menu||a.process_menu_open {return -1}
    for b,i in a.graph_controls {
        if b.w>0&&b.h>0&&x>=b.x&&x<b.x+b.w&&y>=b.y&&y<b.y+b.h {return i}
    }
    return -1
}
graph_control_set :: proc(a:^App,index:int,value:f64) {
    if index==0 {graph_settings_apply(a,value,a.interval)}
    else {graph_settings_apply(a,a.history_seconds,value)}
}
graph_control_pointer :: proc(a:^App,button,action:i32,x,y:f32,mods:i32)->bool {
    if button==glfw.MOUSE_BUTTON_LEFT&&action==glfw.RELEASE&&a.graph_control_drag>=0 {
        a.graph_control_drag=-1;a.mouse_down=false;a.pending_click=false
        graph_settings_save(a)
        return true
    }
    if action!=glfw.PRESS {return false}
    index:=graph_control_hovered(a,x,y)
    if index<0 {return false}
    if button==glfw.MOUSE_BUTTON_RIGHT {
        graph_control_set(a,index,GRAPH_TIME_DEFAULT if index==0 else GRAPH_POLL_DEFAULT)
        graph_settings_save(a)
        a.pending_click=false;a.click=false
        return true
    }
    if button!=glfw.MOUSE_BUTTON_LEFT {return false}
    a.graph_control_drag=index;a.graph_control_x=x
    a.graph_control_raw=a.history_seconds if index==0 else a.interval
    a.graph_control_ctrl=mods&glfw.MOD_CONTROL!=0
    a.pending_click=false;a.click=false;a.mouse_down=true;a.dirty=true
    return true
}
graph_control_motion :: proc(a:^App,x:f32)->bool {
    index:=a.graph_control_drag
    if index<0 {return false}
    ctrl:=glfw.GetKey(a.renderer.window,glfw.KEY_LEFT_CONTROL)==glfw.PRESS||glfw.GetKey(a.renderer.window,glfw.KEY_RIGHT_CONTROL)==glfw.PRESS
    if ctrl!=a.graph_control_ctrl {
        a.graph_control_raw=a.history_seconds if index==0 else a.interval
        a.graph_control_ctrl=ctrl
    }
    delta:=f64(x-a.graph_control_x);a.graph_control_x=x
    if delta==0 {return true}
    // Relative drags start at the selected value. Logarithmic polling movement
    // gives equal travel to each doubling rather than a dead zone near 0.1 s.
    raw:=clamp(a.graph_control_raw+delta,10,300) if index==0 else clamp(a.graph_control_raw*math.pow(2.0,delta/48),0.1,10)
    a.graph_control_raw=raw
    value:=raw
    if !ctrl {
        time_snaps,poll_snaps:=GRAPH_TIME_SNAPS,GRAPH_POLL_SNAPS
        snaps:=time_snaps[:] if index==0 else poll_snaps[:]
        distance:=f64(1e30)
        for snap in snaps {
            difference:=abs(snap-raw) if index==0 else abs(math.ln(snap/raw))
            if difference<distance {distance=difference;value=snap}
        }
    }
    graph_control_set(a,index,value)
    a.graph_settings_pending=true
    return true
}
graph_controls_message :: proc(a:^App) {
    index:=graph_control_hovered(a,a.mouse_x,a.mouse_y)
    if index<0 {index=a.graph_control_drag}
    if index<0 {return}
    message:="Drag left/right / Ctrl: no snapping / Right-click: reset"
    if a.graph_settings_error {message="Could not save graph settings. Check config directory permissions."}
    width:=min(a.width-32,renderer_text_width(&a.renderer,message,12*a.scale)/a.scale+24)
    x:=clamp(a.graph_controls[index].x,16,max(16,a.width-width-16))
    y:=max(60,a.graph_controls[index].y-36)
    panel(a,x,y,width,30)
    fit_text(a,message,x+12,y+20,width-24,12,AMBER if a.graph_settings_error else SOFT)
}

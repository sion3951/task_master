package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import glfw "desktop_window"

updater_control :: proc(a:^App,nav_x:f32)->f32 {
    label:="Updates"
    w:=renderer_text_width(&a.renderer,label,12*a.scale)/a.scale
    x:=nav_x-w-20
    color:=MUTED
    if a.updater!=nil {
        #partial switch a.updater.state {
        case .Ready:color=GREEN
        case .Checking,.Downloading:color=AMBER
        case .Error:color=AMBER
        case:
        }
    }
    if !a.machine_dialog&&!a.machine_menu&&hit(a,x-5,a.content_x,w+10,28) {
        a.update_dialog=true;a.process_menu_open=false;a.click=false;a.dirty=true
    }
    text(a,label,x,a.content_x+16,12,color)
    return x
}

updater_ui_button :: proc(a:^App,label:string,x,y,w:f32,enabled:bool=true)->bool {
    hovered:=a.mouse_x>=x&&a.mouse_x<x+w&&a.mouse_y>=y&&a.mouse_y<y+32
    rounded_rect(a,x,y,w,32,5,LINE if hovered&&enabled else PANEL)
    text(a,label,x+12,y+21,12,TEXT if enabled else MUTED)
    return enabled&&hit(a,x,y,w,32)
}

updater_ui_message :: proc(a:^App,message:string,x,y,w:f32,color:Color) {
    words:=strings.fields(message,context.temp_allocator)
    line:=""
    row:=0
    for word in words {
        candidate:=fmt.tprintf("%s%s%s",line," " if line!="" else "",word)
        if line!=""&&renderer_text_width(&a.renderer,candidate,12*a.scale)/a.scale>w {
            fit_text(a,line,x,y+f32(row)*20,w,12,color)
            row+=1
            if row>=4 {fit_text(a,fmt.tprintf("%s ...",word),x,y+f32(row)*20,w,12,color);return}
            line=word
        } else {line=candidate}
    }
    fit_text(a,line,x,y+f32(row)*20,w,12,color)
}

updater_dialog_draw :: proc(a:^App) {
    u:=a.updater
    if u==nil {a.update_dialog=false;return}
    w:=min(f32(560),a.width-32)
    h:=f32(330)
    x,y:=(a.width-w)/2,max(f32(16),(a.height-h)/2)
    rect(a,0,0,a.width,a.height,{0,0,0,0.8})
    panel(a,x,y,w,h)
    text(a,"Updates",x+20,y+32,20)
    if updater_ui_button(a,"Close",x+w-84,y+12,64) {a.update_dialog=false;a.dirty=true;return}
    text(a,fmt.tprintf("Installed version %s",strings.trim_space(UPDATER_VERSION)),x+20,y+65,12,SOFT)
    status:="Updates are checked and downloaded in the background."
    #partial switch u.state {
    case .Checking:status="Checking for updates..."
    case .Downloading:status="Downloading and verifying the update..."
    case .Ready:status=fmt.tprintf("Version %s is ready to install.",u.version)
    case .Current:status="You have the latest stable version."
    case .Error:status="Could not complete the update."
    case:
    }
    text(a,status,x+20,y+99,12,GREEN if u.state==.Ready else TEXT)
    if u.message!="" {updater_ui_message(a,u.message,x+20,y+124,w-40,AMBER if u.state==.Error else SOFT)}
    automatic_label:="Automatic downloads: on" if u.automatic else "Automatic downloads: off"
    if updater_ui_button(a,automatic_label,x+20,y+228,min(w-40,f32(230))) {
        updater_set_automatic(a,!u.automatic);a.dirty=true
    }
    busy:=u.state==.Checking||u.state==.Downloading
    if updater_ui_button(a,"Check now",x+20,y+280,100,!busy) {updater_check(a)}
    if updater_ui_button(a,"Update and restart",x+w-186,y+280,166,u.state==.Ready&&a.persistence_change==nil) {
        // The helper waits for normal shutdown and owns its files from here.
        // It installs with authorization, then starts an ordinary user desktop.
        success,message:=updater_platform_install(&u.target,u.package_path,u.stage,i32(os.get_pid()))
        if success {
            u.handed_off=true
            if a.graph_settings_pending {graph_settings_save(a)}
            glfw.SetWindowShouldClose(a.renderer.window,true)
        } else {
            delete(u.message);u.message=strings.clone(message);a.dirty=true
        }
    }
}

updater_key_callback :: proc "c" (window:glfw.WindowHandle,key,scancode,action,mods:i32) {
    context=runtime.default_context()
    a:=cast(^App)glfw.GetWindowUserPointer(window)
    if a!=nil&&a.update_dialog {
        if action==glfw.PRESS&&key==glfw.KEY_ESCAPE {a.update_dialog=false;a.dirty=true}
        return
    }
    machine_key_callback(window,key,scancode,action,mods)
}

updater_cli_check :: proc() {
    persistence_headless=true
    a:=new(App)
    defer free(a)
    updater_init(a,automatic=false)
    defer updater_destroy(a)
    updater_check(a)
    for a.updater!=nil&&(a.updater.state==.Checking||a.updater.state==.Downloading) {
        updater_poll(a)
        time.sleep(50*time.Millisecond)
        free_all(context.temp_allocator)
    }
    if a.updater==nil {fmt.eprintln("Could not initialize the updater.");return}
    fmt.println(a.updater.message)
    if a.updater.state==.Error {
        updater_destroy(a)
        os.exit(1)
    }
}

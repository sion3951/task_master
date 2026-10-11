package desktop_window

// Native AppKit windowing. The compatibility names keep UI code shared without
// linking GLFW (or its graphics backends) into the macOS application.
import "base:intrinsics"
import "base:runtime"
import F "core:sys/darwin/Foundation"
import "core:time"

send :: intrinsics.objc_send
Obj :: ^F.Object
WindowHandle :: ^Window
Window :: struct {
    native, view, delegate: Obj,
    user: rawptr,
    close: bool,
    keys: [512]i32,
    buttons: [8]i32,
    width, height, framebuffer_width, framebuffer_height: i32,
    scale: f32,
    marked: Obj,
    refresh: proc "c" (WindowHandle),
    resize, framebuffer_resize: proc "c" (WindowHandle,i32,i32),
    content_scale: proc "c" (WindowHandle,f32,f32),
    cursor: proc "c" (WindowHandle,f64,f64),
    mouse: proc "c" (WindowHandle,i32,i32,i32),
    scroll: proc "c" (WindowHandle,f64,f64),
    key: proc "c" (WindowHandle,i32,i32,i32,i32),
    char: proc "c" (WindowHandle,rune),
}
RELEASE :: 0
PRESS :: 1
REPEAT :: 2
MOUSE_BUTTON_LEFT :: 0
MOUSE_BUTTON_RIGHT :: 1
MOD_SHIFT :: 1
MOD_CONTROL :: 2
MOD_ALT :: 4
MOD_SUPER :: 8
KEY_SPACE :: 32
KEY_1 :: 49
KEY_4 :: 52
KEY_9 :: 57
KEY_A :: 65
KEY_D :: 68
KEY_F :: 70
KEY_N :: 78
KEY_Q :: 81
KEY_U :: 85
KEY_V :: 86
KEY_ESCAPE :: 256
KEY_ENTER :: 257
KEY_TAB :: 258
KEY_BACKSPACE :: 259
KEY_RIGHT :: 262
KEY_LEFT :: 263
KEY_KP_ENTER :: 335
KEY_LEFT_CONTROL :: 341
KEY_RIGHT_CONTROL :: 345
CLIENT_API :: 0x00022001
NO_API :: 0
VISIBLE :: 0x00020004

@(private) app: Obj
@(private) windows: [dynamic]WindowHandle
@(private) view_class, delegate_class: F.Class
@(private) callback_context: runtime.Context
@(private) start: time.Tick
@(private) visible_hint := true

@(private) ns :: proc "contextless" (text: cstring)->Obj {
    return send(Obj,Obj(F.objc_lookUpClass("NSString")),"stringWithUTF8String:",text)
}
@(private) find :: proc(object: Obj)->WindowHandle {
    for w in windows {if w.native==object||w.view==object||w.delegate==object {return w}}
    return nil
}
@(private) method :: proc(cls:F.Class,name:cstring,impl:rawptr,encoding:cstring) {
    F.class_addMethod(cls,F.sel_registerName(name),cast(F.IMP)impl,encoding)
}
@(private) yes :: proc "c" (self:Obj,cmd:F.SEL)->bool {return true}
@(private) noop_command :: proc "c" (self:Obj,cmd:F.SEL,selector:F.SEL) {}
@(private) window_close :: proc "c" (self:Obj,cmd:F.SEL,native:Obj)->bool {
    context=callback_context
    if w:=find(native);w!=nil {w.close=true}
    return false // The renderer owns teardown, so the drawable stays alive until then.
}
@(private) application_quit :: proc "c" (self:Obj,cmd:F.SEL,sender:Obj)->uint {
    context=callback_context
    for w in windows {w.close=true}
    return 0 // NSTerminateCancel: finish the application's own shutdown path.
}
@(private) quit_action :: proc "c" (self:Obj,cmd:F.SEL,sender:Obj) {
    context=callback_context
    for w in windows {w.close=true}
}
@(private) refresh_notification :: proc "c" (self:Obj,cmd:F.SEL,notification:Obj) {
    context=callback_context
    if w:=find(send(Obj,notification,"object"));w!=nil {
        update_size(w)
        if w.refresh!=nil {w.refresh(w)}
    }
}
@(private) focus_lost :: proc "c" (self:Obj,cmd:F.SEL,notification:Obj) {
    context=callback_context
    if w:=find(send(Obj,notification,"object"));w!=nil {
        for state,k in w.keys {if state!=RELEASE {w.keys[k]=RELEASE;if w.key!=nil {w.key(w,i32(k),0,RELEASE,0)}}}
        for state,b in w.buttons {if state!=RELEASE {w.buttons[b]=RELEASE;if w.mouse!=nil {w.mouse(w,i32(b),RELEASE,0)}}}
    }
}

Init :: proc()->bool {
    if app!=nil {return true}
    callback_context=context
    start=time.tick_now()
    pool:=send(Obj,Obj(F.objc_lookUpClass("NSAutoreleasePool")),"new")
    defer send(nil,pool,"drain")
    app=send(Obj,Obj(F.objc_lookUpClass("NSApplication")),"sharedApplication")
    if app==nil {return false}
    send(bool,app,"setActivationPolicy:",uint(0))
    view_class=F.objc_lookUpClass("TaskMasterMetalView")
    if view_class==nil {
        view_class=F.objc_allocateClassPair(F.objc_lookUpClass("NSView"),"TaskMasterMetalView",0)
        method(view_class,"acceptsFirstResponder",rawptr(yes),"B@:")
        method(view_class,"isFlipped",rawptr(yes),"B@:")
        method(view_class,"acceptsFirstMouse:",rawptr(first_mouse),"B@:@")
        method(view_class,"keyDown:",rawptr(key_down),"v@:@")
        method(view_class,"keyUp:",rawptr(key_up),"v@:@")
        method(view_class,"flagsChanged:",rawptr(flags_changed),"v@:@")
        method(view_class,"insertText:replacementRange:",rawptr(insert_text),"v@:@{_NSRange=QQ}")
        method(view_class,"setMarkedText:selectedRange:replacementRange:",rawptr(set_marked),"v@:@{_NSRange=QQ}{_NSRange=QQ}")
        method(view_class,"unmarkText",rawptr(unmark),"v@:")
        method(view_class,"hasMarkedText",rawptr(has_marked),"B@:")
        method(view_class,"markedRange",rawptr(marked_range),"{_NSRange=QQ}@:")
        method(view_class,"selectedRange",rawptr(selected_range),"{_NSRange=QQ}@:")
        method(view_class,"validAttributesForMarkedText",rawptr(valid_attributes),"@@:")
        method(view_class,"attributedSubstringForProposedRange:actualRange:",rawptr(attributed_substring),"@@:{_NSRange=QQ}^{_NSRange=QQ}")
        method(view_class,"characterIndexForPoint:",rawptr(character_index),"Q@:{CGPoint=dd}")
        method(view_class,"firstRectForCharacterRange:actualRange:",rawptr(first_rect),"{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}")
        method(view_class,"doCommandBySelector:",rawptr(noop_command),"v@::")
        F.class_addProtocol(view_class,F.objc_getProtocol("NSTextInputClient"))
        F.objc_registerClassPair(view_class)
    }
    delegate_class=F.objc_lookUpClass("TaskMasterWindowDelegate")
    if delegate_class==nil {
        delegate_class=F.objc_allocateClassPair(F.objc_lookUpClass("NSObject"),"TaskMasterWindowDelegate",0)
        method(delegate_class,"windowShouldClose:",rawptr(window_close),"B@:@")
        method(delegate_class,"applicationShouldTerminate:",rawptr(application_quit),"Q@:@")
        method(delegate_class,"quit:",rawptr(quit_action),"v@:@")
        for name in ([6]cstring{"windowDidResize:","windowDidChangeBackingProperties:","windowDidChangeScreen:","windowDidExpose:","windowDidDeminiaturize:","windowDidBecomeKey:"}) {
            method(delegate_class,name,rawptr(refresh_notification),"v@:@")
        }
        method(delegate_class,"windowDidResignKey:",rawptr(focus_lost),"v@:@")
        F.objc_registerClassPair(delegate_class)
    }
    send(nil,app,"finishLaunching")
    return true
}
WindowHint :: proc(hint:i32,value:$T) {if hint==VISIBLE {when T==bool {visible_hint=value} else {visible_hint=value!=0}}}
CreateWindow :: proc(width,height:i32,title:cstring,monitor:rawptr=nil,share:WindowHandle=nil)->WindowHandle {
    if app==nil||width<=0||height<=0 {return nil}
    pool:=send(Obj,Obj(F.objc_lookUpClass("NSAutoreleasePool")),"new")
    defer send(nil,pool,"drain")
    w:=new(Window)
    rect:=F.Rect{{0,0},{F.Float(width),F.Float(height)}}
    w.native=send(Obj,send(Obj,Obj(F.objc_lookUpClass("NSWindow")),"alloc"),"initWithContentRect:styleMask:backing:defer:",rect,uint(15),uint(2),bool(false))
    if w.native==nil {free(w);return nil}
    send(nil,w.native,"setReleasedWhenClosed:",bool(false))
    w.view=send(Obj,send(Obj,Obj(view_class),"alloc"),"initWithFrame:",rect)
    w.delegate=send(Obj,Obj(delegate_class),"new")
    send(nil,w.native,"setContentView:",w.view)
    send(nil,w.native,"setDelegate:",w.delegate)
    send(bool,w.native,"makeFirstResponder:",w.view)
    send(nil,w.native,"setAcceptsMouseMovedEvents:",bool(true))
    send(nil,w.native,"setTitle:",ns(title))
    send(nil,w.native,"center")
    append(&windows,w)
    update_size(w)
    if len(windows)==1 {install_menu(w.delegate);send(nil,app,"setDelegate:",w.delegate)}
    if visible_hint {ShowWindow(w)}
    return w
}
@(private) install_menu :: proc(target:Obj) {
    menu:=send(Obj,Obj(F.objc_lookUpClass("NSMenu")),"new")
    item:=send(Obj,Obj(F.objc_lookUpClass("NSMenuItem")),"new")
    submenu:=send(Obj,Obj(F.objc_lookUpClass("NSMenu")),"new")
    menu_item(submenu,"About task_master","orderFrontStandardAboutPanel:","",Obj(nil))
    send(nil,submenu,"addItem:",send(Obj,Obj(F.objc_lookUpClass("NSMenuItem")),"separatorItem"))
    menu_item(submenu,"Hide task_master","hide:","h",Obj(nil))
    menu_item(submenu,"Show All","unhideAllApplications:","",Obj(nil))
    send(nil,submenu,"addItem:",send(Obj,Obj(F.objc_lookUpClass("NSMenuItem")),"separatorItem"))
    menu_item(submenu,"Quit task_master","quit:","q",target)
    send(nil,item,"setSubmenu:",submenu)
    send(nil,menu,"addItem:",item)
    send(nil,app,"setMainMenu:",menu)
    window_item:=send(Obj,Obj(F.objc_lookUpClass("NSMenuItem")),"new")
    window_menu:=send(Obj,send(Obj,Obj(F.objc_lookUpClass("NSMenu")),"alloc"),"initWithTitle:",ns("Window"))
    send(nil,window_item,"setTitle:",ns("Window"))
    send(nil,window_item,"setSubmenu:",window_menu)
    send(nil,menu,"addItem:",window_item)
    menu_item(window_menu,"Minimize","performMiniaturize:","m",Obj(nil))
    menu_item(window_menu,"Zoom","performZoom:","",Obj(nil))
    send(nil,app,"setWindowsMenu:",window_menu)
    for object in ([5]Obj{submenu,item,window_item,window_menu,menu}) {send(nil,object,"release")}
}
@(private) menu_item :: proc(menu:Obj,title,action,key:cstring,target:Obj) {
    item:=send(Obj,send(Obj,Obj(F.objc_lookUpClass("NSMenuItem")),"alloc"),"initWithTitle:action:keyEquivalent:",ns(title),F.sel_registerName(action),ns(key))
    send(nil,item,"setTarget:",target)
    send(nil,menu,"addItem:",item)
    send(nil,item,"release")
}
DestroyWindow :: proc(w:WindowHandle) {
    if w==nil {return}
    if send(Obj,app,"delegate")==w.delegate {send(nil,app,"setDelegate:",Obj(nil))}
    send(nil,w.native,"setDelegate:",Obj(nil))
    send(nil,w.native,"orderOut:",Obj(nil))
    send(nil,w.native,"close")
    if w.marked!=nil {send(nil,w.marked,"release")}
    send(nil,w.view,"release")
    send(nil,w.delegate,"release")
    send(nil,w.native,"release")
    for value,i in windows {if value==w {ordered_remove(&windows,i);break}}
    free(w)
}
Terminate :: proc() {
    for len(windows)>0 {DestroyWindow(windows[len(windows)-1])}
    delete(windows);windows=nil
    app=nil;visible_hint=true
}
GetNativeView :: proc "contextless" (w:WindowHandle)->rawptr {return rawptr(w.view)}
ShowWindow :: proc "contextless" (w:WindowHandle) {
    pool:=send(Obj,Obj(F.objc_lookUpClass("NSAutoreleasePool")),"new")
    defer send(nil,pool,"drain")
    send(nil,w.native,"makeKeyAndOrderFront:",Obj(nil))
    send(nil,app,"activateIgnoringOtherApps:",bool(true))
}
SetWindowTitle :: proc "contextless" (w:WindowHandle,title:cstring) {
    pool:=send(Obj,Obj(F.objc_lookUpClass("NSAutoreleasePool")),"new")
    defer send(nil,pool,"drain")
    send(nil,w.native,"setTitle:",ns(title))
}
SetWindowShouldClose :: proc "contextless" (w:WindowHandle,value:bool) {w.close=value}
WindowShouldClose :: proc "contextless" (w:WindowHandle)->bool {return w.close}
SetWindowUserPointer :: proc "contextless" (w:WindowHandle,value:rawptr) {w.user=value}
GetWindowUserPointer :: proc "contextless" (w:WindowHandle)->rawptr {return w.user}
GetTime :: proc "contextless" ()->f64 {return f64(time.tick_diff(start,time.tick_now()))/1e9}
GetWindowSize :: proc "contextless" (w:WindowHandle)->(i32,i32) {rect:=send(F.Rect,w.view,"bounds");return i32(rect.size.width),i32(rect.size.height)}
GetWindowContentScale :: proc "contextless" (w:WindowHandle)->(f32,f32) {scale:=f32(send(f64,w.native,"backingScaleFactor"));return scale,scale}
GetFramebufferSize :: proc "contextless" (w:WindowHandle)->(i32,i32) {
    rect:=send(F.Rect,w.view,"convertRectToBacking:",send(F.Rect,w.view,"bounds"))
    return i32(rect.size.width),i32(rect.size.height)
}
GetCursorPos :: proc "contextless" (w:WindowHandle)->(f64,f64) {
    point:=send(F.Point,w.native,"mouseLocationOutsideOfEventStream")
    point=send(F.Point,w.view,"convertPoint:fromView:",point,Obj(nil))
    return f64(point.x),f64(point.y)
}
GetMouseButton :: proc "contextless" (w:WindowHandle,button:i32)->i32 {return w.buttons[button] if button>=0&&button<len(w.buttons) else RELEASE}
GetKey :: proc "contextless" (w:WindowHandle,key:i32)->i32 {return w.keys[key] if key>=0&&key<len(w.keys) else RELEASE}
GetClipboardString :: proc "contextless" (w:WindowHandle)->string {
    pasteboard:=send(Obj,Obj(F.objc_lookUpClass("NSPasteboard")),"generalPasteboard")
    text:=send(Obj,pasteboard,"stringForType:",ns("public.utf8-plain-text"))
    if text==nil {return ""}
    return string(send(cstring,text,"UTF8String"))
}
@(private) update_size :: proc(w:WindowHandle) {
    width,height:=GetWindowSize(w)
    fw,fh:=GetFramebufferSize(w)
    scale,_:=GetWindowContentScale(w)
    size_changed:=width!=w.width||height!=w.height
    framebuffer_changed:=fw!=w.framebuffer_width||fh!=w.framebuffer_height
    scale_changed:=scale!=w.scale
    w.width,w.height,w.framebuffer_width,w.framebuffer_height,w.scale=width,height,fw,fh,scale
    if size_changed&&w.resize!=nil {w.resize(w,width,height)}
    if framebuffer_changed&&w.framebuffer_resize!=nil {w.framebuffer_resize(w,fw,fh)}
    if scale_changed&&w.content_scale!=nil {w.content_scale(w,scale,scale)}
}

PollEvents :: proc() {pump(0)}
WaitEventsTimeout :: proc(timeout:f64) {pump(max(0,timeout))}
@(private) pump :: proc(timeout:f64) {
    if app==nil {return}
    pool:=send(Obj,Obj(F.objc_lookUpClass("NSAutoreleasePool")),"new")
    defer send(nil,pool,"drain")
    until:=send(Obj,Obj(F.objc_lookUpClass("NSDate")),"dateWithTimeIntervalSinceNow:",timeout)
    for {
        event:=send(Obj,app,"nextEventMatchingMask:untilDate:inMode:dequeue:",max(uint),until,ns("kCFRunLoopDefaultMode"),bool(true))
        if event==nil {break}
        dispatch(event)
        send(nil,app,"sendEvent:",event)
        until=send(Obj,Obj(F.objc_lookUpClass("NSDate")),"distantPast")
    }
    send(nil,app,"updateWindows")
    for w in windows {update_size(w)}
}
PostEmptyEvent :: proc "contextless" () {
    if app==nil {return}
    pool:=send(Obj,Obj(F.objc_lookUpClass("NSAutoreleasePool")),"new")
    defer send(nil,pool,"drain")
    event:=send(Obj,Obj(F.objc_lookUpClass("NSEvent")),"otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:",uint(15),F.Point{},uint(0),f64(0),int(0),Obj(nil),i16(0),int(0),int(0))
    send(nil,app,"postEvent:atStart:",event,bool(true))
}
@(private) mods :: proc(event:Obj)->i32 {
    flags:=send(uint,event,"modifierFlags")
    result:i32
    if flags&(1<<17)!=0 {result|=MOD_SHIFT}
    if flags&(1<<18)!=0 {result|=MOD_CONTROL}
    if flags&(1<<19)!=0 {result|=MOD_ALT}
    if flags&(1<<20)!=0 {result|=MOD_SUPER}
    return result
}
@(private) dispatch :: proc(event:Obj) {
    w:=find(send(Obj,event,"window"))
    if w==nil {return}
    kind:=send(uint,event,"type")
    switch kind {
    case 1,2,3,4,25,26:
        button:=i32(send(int,event,"buttonNumber"))
        action:i32=PRESS if kind==1||kind==3||kind==25 else RELEASE
        point:=send(F.Point,w.view,"convertPoint:fromView:",send(F.Point,event,"locationInWindow"),Obj(nil))
        bounds:=send(F.Rect,w.view,"bounds")
        inside:=point.x>=0&&point.y>=0&&point.x<bounds.size.width&&point.y<bounds.size.height
        if action==PRESS&&!inside {return}
        if action==RELEASE&&GetMouseButton(w,button)==RELEASE {return}
        if button>=0&&button<len(w.buttons) {w.buttons[button]=action}
        if w.mouse!=nil {w.mouse(w,button,action,mods(event))}
    case 5,6,7,27:
        if w.cursor!=nil {x,y:=GetCursorPos(w);w.cursor(w,x,y)}
    case 22:
        x:=send(f64,event,"scrollingDeltaX")
        y:=send(f64,event,"scrollingDeltaY")
        if send(bool,event,"hasPreciseScrollingDeltas") {x*=0.1;y*=0.1}
        if w.scroll!=nil {w.scroll(w,x,y)}
    }
}

// Apple virtual key codes mapped to the shared UI key identifiers.
@(private) key_codes := [128]i32{
    65,83,68,70,72,71,90,88,67,86,96,66,81,87,69,82,
    89,84,49,50,51,52,54,53,61,57,55,45,56,48,93,79,
    85,91,73,80,257,76,74,39,75,59,92,44,47,78,77,46,
    258,32,96,259,-1,256,347,343,340,280,342,341,344,346,345,-1,
    -1,330,-1,332,-1,334,-1,282,-1,-1,-1,331,335,-1,333,-1,
    -1,336,320,321,322,323,324,325,326,327,-1,328,329,-1,-1,-1,
    294,295,296,292,297,298,-1,300,-1,302,-1,303,-1,299,-1,301,
    -1,-1,260,268,266,261,293,269,291,267,290,263,262,264,265,-1,
}
@(private) first_mouse :: proc "c" (self:Obj,cmd:F.SEL,event:Obj)->bool {return true}
@(private) deliver_key :: proc(w:WindowHandle,event:Obj,action:i32) {
    scan:=i32(send(u16,event,"keyCode"))
    key:=key_codes[scan] if scan>=0&&scan<len(key_codes) else -1
    if key>=0&&key<len(w.keys) {w.keys[key]=RELEASE if action==RELEASE else PRESS}
    if w.key!=nil {w.key(w,key,scan,action,mods(event))}
}
@(private) key_down :: proc "c" (self:Obj,cmd:F.SEL,event:Obj) {
    context=callback_context
    if w:=find(self);w!=nil {
        deliver_key(w,event,REPEAT if send(bool,event,"isARepeat") else PRESS)
        // AppKit's text input system handles keyboard layouts, dead keys and IME
        // composition; only committed text reaches the shared character callback.
        if mods(event)&(MOD_CONTROL|MOD_SUPER)==0 {
            events:=send(Obj,Obj(F.objc_lookUpClass("NSArray")),"arrayWithObject:",event)
            send(nil,self,"interpretKeyEvents:",events)
        }
    }
}
@(private) key_up :: proc "c" (self:Obj,cmd:F.SEL,event:Obj) {
    context=callback_context
    if w:=find(self);w!=nil {deliver_key(w,event,RELEASE)}
}
@(private) flags_changed :: proc "c" (self:Obj,cmd:F.SEL,event:Obj) {
    context=callback_context
    w:=find(self)
    if w==nil {return}
    scan:=i32(send(u16,event,"keyCode"))
    flags:=send(uint,event,"modifierFlags")
    device_mask:uint
    switch scan {
    case 54: device_mask=0x10
    case 55: device_mask=0x08
    case 56: device_mask=0x02
    case 58: device_mask=0x20
    case 59: device_mask=0x01
    case 60: device_mask=0x04
    case 61: device_mask=0x40
    case 62: device_mask=0x2000
    case: return
    }
    deliver_key(w,event,PRESS if flags&device_mask!=0 else RELEASE)
}
@(private) plain_string :: proc(value:Obj)->Obj {
    if send(bool,value,"isKindOfClass:",F.objc_lookUpClass("NSAttributedString")) {return send(Obj,value,"string")}
    return value
}
@(private) insert_text :: proc "c" (self:Obj,cmd:F.SEL,value:Obj,replacement:F.Range) {
    context=callback_context
    w:=find(self)
    if w==nil {return}
    unmark(self,cmd)
    if w.char!=nil {
        text:=string(send(cstring,plain_string(value),"UTF8String"))
        for character in text {if character>=32&&character!=127&&!(character>=0xf700&&character<=0xf8ff) {w.char(w,character)}}
    }
}
@(private) set_marked :: proc "c" (self:Obj,cmd:F.SEL,value:Obj,selected,replacement:F.Range) {
    context=callback_context
    if w:=find(self);w!=nil {
        if w.marked!=nil {send(nil,w.marked,"release")}
        w.marked=send(Obj,plain_string(value),"copy")
    }
}
@(private) unmark :: proc "c" (self:Obj,cmd:F.SEL) {
    context=callback_context
    if w:=find(self);w!=nil&&w.marked!=nil {send(nil,w.marked,"release");w.marked=nil}
}
@(private) has_marked :: proc "c" (self:Obj,cmd:F.SEL)->bool {
    context=callback_context
    w:=find(self)
    return w!=nil&&w.marked!=nil&&send(uint,w.marked,"length")>0
}
@(private) marked_range :: proc "c" (self:Obj,cmd:F.SEL)->F.Range {
    context=callback_context
    if w:=find(self);w!=nil&&w.marked!=nil {return F.Range{0,send(F.UInteger,w.marked,"length")}}
    return F.Range{F.UInteger(F.NotFound),0}
}
@(private) selected_range :: proc "c" (self:Obj,cmd:F.SEL)->F.Range {return F.Range{0,0}}
@(private) valid_attributes :: proc "c" (self:Obj,cmd:F.SEL)->Obj {return send(Obj,Obj(F.objc_lookUpClass("NSArray")),"array")}
@(private) attributed_substring :: proc "c" (self:Obj,cmd:F.SEL,range:F.Range,actual:^F.Range)->Obj {
    if actual!=nil {actual^=F.Range{F.UInteger(F.NotFound),0}}
    return nil
}
@(private) character_index :: proc "c" (self:Obj,cmd:F.SEL,point:F.Point)->uint {return 0}
@(private) first_rect :: proc "c" (self:Obj,cmd:F.SEL,range:F.Range,actual:^F.Range)->F.Rect {
    context=callback_context
    if actual!=nil {actual^=range}
    w:=find(self)
    if w==nil {return F.Rect{}}
    x,y:=GetCursorPos(w)
    rect:=F.Rect{{F.Float(x),F.Float(y)},{1,16}}
    rect=send(F.Rect,w.view,"convertRect:toView:",rect,Obj(nil))
    return send(F.Rect,w.native,"convertRectToScreen:",rect)
}

SetWindowRefreshCallback :: proc(w:WindowHandle,callback:proc "c" (WindowHandle))->proc "c" (WindowHandle) {previous:=w.refresh;w.refresh=callback;return previous}
SetWindowSizeCallback :: proc(w:WindowHandle,callback:proc "c" (WindowHandle,i32,i32))->proc "c" (WindowHandle,i32,i32) {previous:=w.resize;w.resize=callback;return previous}
SetFramebufferSizeCallback :: proc(w:WindowHandle,callback:proc "c" (WindowHandle,i32,i32))->proc "c" (WindowHandle,i32,i32) {previous:=w.framebuffer_resize;w.framebuffer_resize=callback;return previous}
SetWindowContentScaleCallback :: proc(w:WindowHandle,callback:proc "c" (WindowHandle,f32,f32))->proc "c" (WindowHandle,f32,f32) {previous:=w.content_scale;w.content_scale=callback;return previous}
SetCursorPosCallback :: proc(w:WindowHandle,callback:proc "c" (WindowHandle,f64,f64))->proc "c" (WindowHandle,f64,f64) {previous:=w.cursor;w.cursor=callback;return previous}
SetMouseButtonCallback :: proc(w:WindowHandle,callback:proc "c" (WindowHandle,i32,i32,i32))->proc "c" (WindowHandle,i32,i32,i32) {previous:=w.mouse;w.mouse=callback;return previous}
SetScrollCallback :: proc(w:WindowHandle,callback:proc "c" (WindowHandle,f64,f64))->proc "c" (WindowHandle,f64,f64) {previous:=w.scroll;w.scroll=callback;return previous}
SetKeyCallback :: proc(w:WindowHandle,callback:proc "c" (WindowHandle,i32,i32,i32,i32))->proc "c" (WindowHandle,i32,i32,i32,i32) {previous:=w.key;w.key=callback;return previous}
SetCharCallback :: proc(w:WindowHandle,callback:proc "c" (WindowHandle,rune))->proc "c" (WindowHandle,rune) {previous:=w.char;w.char=callback;return previous}

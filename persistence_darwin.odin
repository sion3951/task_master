#+build darwin
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

PERSISTENCE_DARWIN_LABEL :: "dev.task_master.persistence"
foreign import persistence_darwin_system "system:System"
foreign persistence_darwin_system {
    @(link_name="flock")
    persistence_darwin_flock :: proc(fd:i32,operation:i32)->i32 ---
}

persistence_darwin_domain :: proc()->string {return fmt.tprintf("gui/%d",posix.getuid())}
persistence_darwin_target :: proc()->string {return fmt.tprintf("%s/%s",persistence_darwin_domain(),PERSISTENCE_DARWIN_LABEL)}
persistence_darwin_plist_path :: proc()->string {
    home,error:=os.user_home_dir(context.temp_allocator)
    if error!=nil {return ""}
    return fmt.tprintf("%s/Library/LaunchAgents/%s.plist",home,PERSISTENCE_DARWIN_LABEL)
}
persistence_darwin_command :: proc(arguments:[]string)->(success:bool,output:string) {
    capture,error:=os.create_temp_file("","task_master-launchctl-*")
    if error!=nil {return false,fmt.tprintf("Could not capture launchctl output: %v",error)}
    _=os.remove(os.name(capture))
    defer os.close(capture)
    args:=make([dynamic]string,0,len(arguments)+1,context.temp_allocator)
    append(&args,"/bin/launchctl");append(&args,..arguments)
    sync.mutex_lock(&remote_spawn_mutex)
    process,start_error:=os.process_start({command=args[:],stdout=capture,stderr=capture})
    sync.mutex_unlock(&remote_spawn_mutex)
    if start_error!=nil {return false,fmt.tprintf("Could not run launchctl: %v",start_error)}
    state,wait_error:=os.process_wait(process,25*time.Second)
    if wait_error==.Timeout {_=os.process_kill(process);_,_=os.process_wait(process,2*time.Second)}
    _,_=os.seek(capture,0,.Start)
    buffer:=make([]u8,4096,context.temp_allocator)
    count,_:=os.read(capture,buffer)
    output=strings.trim_space(string(buffer[:count]))
    if wait_error!=nil {return false,fmt.tprintf("launchctl did not finish: %v",wait_error)}
    return state.exit_code==0,output
}
persistence_darwin_xml_quote :: proc(value:string)->string {
    builder:=strings.builder_make(context.temp_allocator)
    for c in value {
        switch c {
        case '&':strings.write_string(&builder,"&amp;")
        case '<':strings.write_string(&builder,"&lt;")
        case '>':strings.write_string(&builder,"&gt;")
        case '"':strings.write_string(&builder,"&quot;")
        case '\'':strings.write_string(&builder,"&apos;")
        case:strings.write_rune(&builder,c)
        }
    }
    return strings.to_string(builder)
}
persistence_init :: proc(a:^App) {
    persistence_local_captured=false
    a.persistence_last_poll=-1e9
    path:=persistence_darwin_plist_path()
    if path=="" {persistence_error_set(a,"Could not locate the user LaunchAgents directory.");return}
    a.persistence_enabled=os.is_file(path)
}

// The lock is held through all metric/SSH teardown. Probing it avoids treating
// launchctl's asynchronous removal of a job as completion of collector cleanup.
persistence_darwin_lock_path :: proc()->string {
    directory:=persistence_directory()
    if directory=="" {return ""}
    return fmt.tprintf("%s/collector.lock",directory)
}
persistence_darwin_running :: proc()->bool {
    path:=persistence_darwin_lock_path()
    if path=="" {return false}
    file,error:=os.open(path,{.Write})
    if error!=nil {return false}
    defer os.close(file)
    if persistence_darwin_flock(i32(os.fd(file)),2|4)!=0 {return true}
    _=persistence_darwin_flock(i32(os.fd(file)),8)
    return false
}
persistence_darwin_stop :: proc(a:^App)->bool {
    loaded,output:=persistence_darwin_command([]string{"print",persistence_darwin_target()})
    if loaded {
        ok:bool
        ok,output=persistence_darwin_command([]string{"bootout",persistence_darwin_target()})
        if !ok {persistence_error_set(a,fmt.tprintf("Could not stop persistence: %s",output));return false}
    } else if !strings.contains(output,"Could not find service") {
        persistence_error_set(a,fmt.tprintf("Could not inspect the user persistence service: %s",output));return false
    }
    started:=time.tick_now()
    for persistence_darwin_running()&&time.tick_since(started)<35*time.Second {time.sleep(50*time.Millisecond)}
    if persistence_darwin_running() {
        persistence_error_set(a,"The persistence collector did not stop cleanly. Its executable has been retained.");return false
    }
    return true
}

Persistence_Darwin_Dependency :: struct {source,destination:string,permissions:os.Permissions}
persistence_darwin_dependencies :: proc(source,destination:string,files:^[dynamic]Persistence_Darwin_Dependency)->bool {
    entries,error:=os.read_all_directory_by_path(source,context.temp_allocator)
    if error!=nil {return false}
    for entry in entries {
        source_path:=fmt.tprintf("%s/%s",source,entry.name)
        destination_path:=fmt.tprintf("%s/%s",destination,entry.name)
        #partial switch entry.type {
        case .Directory:
            if !persistence_darwin_dependencies(source_path,destination_path,files) {return false}
        case .Regular:
            append(files,Persistence_Darwin_Dependency{source_path,destination_path,{.Read_User,.Write_User}})
        case:
            // The installer stages real dylibs, so stable service dependencies
            // never point back into a moved app or a developer's package store.
            return false
        }
    }
    return true
}
persistence_install_unit :: proc(a:^App)->(success,updated:bool) {
    executable,executable_error:=os.get_executable_path(context.temp_allocator)
    data_directory,data_error:=os.user_data_dir(context.temp_allocator)
    plist_path:=persistence_darwin_plist_path()
    if executable_error!=nil||data_error!=nil||plist_path=="" {
        persistence_error_set(a,"Could not locate the executable or user data directory.");return
    }
    directory:=fmt.tprintf("%s/task_master/persistence",data_directory)
    stable:=fmt.tprintf("%s/MacOS/task_master",directory)
    dependencies:=make([dynamic]Persistence_Darwin_Dependency,0,16,context.temp_allocator)
    append(&dependencies,Persistence_Darwin_Dependency{executable,stable,{.Read_User,.Write_User,.Execute_User}})
    slash:=strings.last_index_byte(executable,'/')
    if slash<0 {persistence_error_set(a,"Could not locate the background runtime dependencies.");return}
    // Keep the same relative framework layout as the installed .app. The full
    // executable enters --persistence-service before any GLFW/Vulkan startup.
    source_directory:=executable[:slash]
    frameworks:=fmt.tprintf("%s/../Frameworks",source_directory)
    if os.is_dir(frameworks)&&!persistence_darwin_dependencies(frameworks,fmt.tprintf("%s/Frameworks",directory),&dependencies) {
        persistence_error_set(a,"Could not enumerate background dependencies; package real dylibs in Contents/Frameworks.");return
    }
    // A separate collector beside the app is used for native remote deployments.
    collector:=fmt.tprintf("%s/task_master-collector",source_directory)
    if os.is_file(collector) {append(&dependencies,Persistence_Darwin_Dependency{collector,fmt.tprintf("%s/MacOS/task_master-collector",directory),{.Read_User,.Write_User,.Execute_User}})}
    dependencies_changed:=false
    for dependency in dependencies {
        source,error:=os.read_entire_file(dependency.source,context.temp_allocator)
        if error!=nil {persistence_error_set(a,fmt.tprintf("Could not read background dependency: %s",dependency.source));return}
        installed,installed_error:=os.read_entire_file(dependency.destination,context.temp_allocator)
        if installed_error!=nil||string(source)!=string(installed) {dependencies_changed=true}
    }
    // Explicit UMask applies even to files opened by SSH subprocesses. launchd
    // runs this agent as the logged-in account, preserving SSH-agent/key access.
    plist:=fmt.tprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>%s</string>
<key>ProgramArguments</key><array><string>%s</string><string>--persistence-service</string></array>
<key>WorkingDirectory</key><string>%s</string>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string>
<key>ThrottleInterval</key><integer>2</integer>
<key>ExitTimeOut</key><integer>30</integer>
<key>Umask</key><integer>63</integer>
</dict></plist>
`,PERSISTENCE_DARWIN_LABEL,persistence_darwin_xml_quote(stable),persistence_darwin_xml_quote(directory))
    installed_plist,plist_error:=os.read_entire_file(plist_path,context.temp_allocator)
    plist_changed:=plist_error!=nil||string(installed_plist)!=plist
    if !dependencies_changed&&!plist_changed {return true,false}
    if !persistence_darwin_stop(a) {return}
    for dependency in dependencies {
        source,error:=os.read_entire_file(dependency.source,context.temp_allocator)
        if error!=nil||!persistence_atomic_write(dependency.destination,source,dependency.permissions) {
            persistence_error_set(a,fmt.tprintf("Could not install background dependency: %s",dependency.source));return
        }
    }
    if !persistence_atomic_write(plist_path,transmute([]u8)plist) {persistence_error_set(a,"Could not save the user persistence LaunchAgent.");return}
    return true,true
}
persistence_platform_service_set :: proc(a:^App,enable:bool,refresh_only:bool=false,force_restart:bool=false)->bool {
    if !enable {
        if !persistence_darwin_stop(a) {return false}
        path:=persistence_darwin_plist_path()
        if path==""||(os.is_file(path)&&os.remove(path)!=nil) {persistence_error_set(a,"Could not remove the persistence LaunchAgent.");return false}
        a.persistence_enabled=false;a.persistence_error_len=0
        return true
    }
    installed,updated:=persistence_install_unit(a)
    if !installed {return false}
    if !updated&&!force_restart&&persistence_darwin_running() {a.persistence_enabled=true;a.persistence_error_len=0;return true}
    if force_restart&&!persistence_darwin_stop(a) {return false}
    loaded,_:=persistence_darwin_command([]string{"print",persistence_darwin_target()})
    ok:bool
    output:string
    if !loaded {
        ok,output=persistence_darwin_command([]string{"enable",persistence_darwin_target()})
        if ok {ok,output=persistence_darwin_command([]string{"bootstrap",persistence_darwin_domain(),persistence_darwin_plist_path()})}
    } else {ok,output=persistence_darwin_command([]string{"kickstart",persistence_darwin_target()})}
    if !ok {persistence_error_set(a,fmt.tprintf("Could not start persistence: %s",output));return false}
    started:=time.tick_now()
    for !persistence_darwin_running()&&time.tick_since(started)<8*time.Second {time.sleep(50*time.Millisecond)}
    if !persistence_darwin_running() {persistence_error_set(a,"macOS registered the LaunchAgent but its collector did not start.");return false}
    a.persistence_enabled=true;a.persistence_error_len=0
    return true
}

persistence_darwin_stop_requested:bool
persistence_darwin_lock:^os.File
persistence_darwin_signal :: proc "c" (signal:posix.Signal) {sync.atomic_store(&persistence_darwin_stop_requested,true)}
persistence_platform_service_init :: proc()->bool {
    path:=persistence_darwin_lock_path()
    if path=="" {return false}
    slash:=strings.last_index_byte(path,'/')
    error:=os.mkdir_all(path[:slash],{.Read_User,.Write_User,.Execute_User})
    if error!=nil&&error!=.Exist {return false}
    if !platform_private_path(path[:slash],true) {return false}
    persistence_darwin_lock,error=os.open(path,{.Write,.Create},{.Read_User,.Write_User})
    if error!=nil {return false}
    if !platform_private_path(path,false)||persistence_darwin_flock(i32(os.fd(persistence_darwin_lock)),2|4)!=0 {
        os.close(persistence_darwin_lock);persistence_darwin_lock=nil;return false
    }
    // SSH children must not retain the ownership lock after the collector exits.
    _=posix.fcntl(posix.FD(os.fd(persistence_darwin_lock)),.SETFD,i32(posix.FD_CLOEXEC))
    _=posix.signal(.SIGPIPE,auto_cast posix.SIG_IGN)
    _=posix.signal(.SIGTERM,persistence_darwin_signal)
    _=posix.signal(.SIGINT,persistence_darwin_signal)
    return true
}
persistence_platform_service_stop_requested :: proc()->bool {return sync.atomic_load(&persistence_darwin_stop_requested)}
persistence_platform_service_destroy :: proc() {
    if persistence_darwin_lock!=nil {os.close(persistence_darwin_lock);persistence_darwin_lock=nil}
}
platform_atomic_replace :: proc(source,destination:string)->bool {return os.rename(source,destination)==nil}
platform_private_path :: proc(path:string,directory:bool)->bool {
    if directory {return os.chmod(path,{.Read_User,.Write_User,.Execute_User})==nil}
    information,error:=os.stat(path,context.temp_allocator)
    if error!=nil {return false}
    permissions:=information.mode&os.Permissions{.Read_User,.Write_User,.Execute_User}
    return os.chmod(path,permissions)==nil
}
persistence_platform_cache_open :: proc(path:string)->(^os.File,os.Error) {return os.open(path)}

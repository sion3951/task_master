#+build linux
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

PERSISTENCE_UNIT :: "task_master-persistence.service"

// Capture command diagnostics in an anonymous file instead of a pipe, avoiding
// pipe-buffer deadlocks and leaving no files after the command returns.
persistence_systemctl :: proc(arguments:[]string)->(success:bool,output:string) {
    capture,err:=os.create_temp_file("","task_master-systemctl-*")
    if err!=nil {return false,fmt.tprintf("Could not capture systemctl output: %v",err)}
    _=os.remove(os.name(capture))
    defer os.close(capture)
    args:=make([dynamic]string,0,len(arguments)+2,context.temp_allocator)
    append(&args,"systemctl","--user")
    append(&args,..arguments)
    sync.mutex_lock(&remote_spawn_mutex)
    process,start_error:=os.process_start({command=args[:],stdout=capture,stderr=capture})
    sync.mutex_unlock(&remote_spawn_mutex)
    if start_error!=nil {return false,fmt.tprintf("Could not run systemctl --user: %v",start_error)}
    state,wait_error:=os.process_wait(process,25*time.Second)
    if wait_error==.Timeout {
        _=os.process_kill(process)
        _,_=os.process_wait(process,2*time.Second)
    }
    _,_=os.seek(capture,0,.Start)
    buffer:=make([]u8,4096,context.temp_allocator)
    count,_:=os.read(capture,buffer)
    output=strings.trim_space(string(buffer[:count]))
    if wait_error!=nil {return false,fmt.tprintf("systemctl --user did not finish: %v",wait_error)}
    return state.exit_code==0,output
}
persistence_init :: proc(a:^App) {
    persistence_local_captured=false
    a.persistence_last_poll=-1e9
    enabled,output:=persistence_systemctl([]string{"is-enabled",PERSISTENCE_UNIT})
    a.persistence_enabled=enabled&&strings.trim_space(output)=="enabled"
    // A missing or disabled unit is the normal first-run state. Bus and command
    // failures remain visible so users can tell why the service is unavailable.
    if !enabled&&(strings.contains(output,"Failed to connect")||strings.contains(output,"Could not run")||strings.contains(output,"did not finish")) {
        persistence_error_set(a,output)
    }
}
persistence_unit_quote :: proc(path:string)->string {
    builder:=strings.builder_make(context.temp_allocator)
    strings.write_byte(&builder,'"')
    for character in path {
        switch character {
        case '\\':strings.write_string(&builder,"\\\\")
        case '"':strings.write_string(&builder,"\\\"")
        case '%':strings.write_string(&builder,"%%")
        case '$':strings.write_string(&builder,"$$")
        case '\n':strings.write_string(&builder,"\\n")
        case '\r':strings.write_string(&builder,"\\r")
        case:strings.write_rune(&builder,character)
        }
    }
    strings.write_byte(&builder,'"')
    return strings.to_string(builder)
}
Persistence_Linux_Runtime_File :: struct {
    source,destination:string,
    permissions:os.Permissions,
}
persistence_linux_runtime_files :: proc(source,destination:string,files:^[dynamic]Persistence_Linux_Runtime_File)->bool {
    entries,error:=os.read_all_directory_by_path(source,context.temp_allocator)
    if error!=nil {return false}
    for entry in entries {
        source_path:=fmt.tprintf("%s/%s",source,entry.name)
        destination_path:=fmt.tprintf("%s/%s",destination,entry.name)
        #partial switch entry.type {
        case .Directory:
            if !persistence_linux_runtime_files(source_path,destination_path,files) {return false}
        case .Regular,.Symlink:
            // Read library aliases through their symlink and install real files;
            // stable service resources cannot point back into an AppImage mount.
            append(files,Persistence_Linux_Runtime_File{source_path,destination_path,{.Read_User,.Write_User}})
        case:return false
        }
    }
    return true
}
persistence_linux_stop_for_update :: proc(a:^App)->bool {
    active,output:=persistence_systemctl([]string{"is-active",PERSISTENCE_UNIT})
    if !active&&(output=="inactive"||output=="failed"||output=="unknown") {return true}
    if !(active||output=="activating"||output=="deactivating"||output=="reloading") {
        persistence_error_set(a,fmt.tprintf("Could not inspect persistence before updating its runtime: %s",output));return false
    }
    // systemctl waits for the unit's complete control group to stop, including
    // collector SSH/proxy children. Keep its enablement for the subsequent start.
    stopped,diagnostic:=persistence_systemctl([]string{"stop",PERSISTENCE_UNIT})
    if !stopped {persistence_error_set(a,fmt.tprintf("Could not stop persistence before updating its runtime: %s",diagnostic));return false}
    return true
}
persistence_install_unit :: proc(a:^App)->(success,updated:bool) {
    directory,directory_error:=os.user_config_dir(context.temp_allocator)
    executable,executable_error:=os.get_executable_path(context.temp_allocator)
    data_directory,data_directory_error:=os.user_data_dir(context.temp_allocator)
    if directory_error!=nil||executable_error!=nil||data_directory_error!=nil {
        persistence_error_set(a,"Could not locate the executable or user configuration directory.");return
    }
    stable_directory:=fmt.tprintf("%s/task_master/persistence",data_directory)
    stable_executable:=fmt.tprintf("%s/bin/task_master",stable_directory)
    runtime_files:=make([dynamic]Persistence_Linux_Runtime_File,0,16,context.temp_allocator)
    append(&runtime_files,Persistence_Linux_Runtime_File{executable,stable_executable,{.Read_User,.Write_User,.Execute_User}})
    slash:=strings.last_index_byte(executable,'/')
    if slash<0 {persistence_error_set(a,"Could not locate the background executable directory.");return}
    // AppImage AppDir and .deb layouts both use usr/bin and usr/lib/task_master.
    // Retain that relationship for $ORIGIN/../lib/task_master in the ELF RUNPATH.
    source_libraries:=fmt.tprintf("%s/../lib/task_master",executable[:slash])
    if os.is_dir(source_libraries)&&!persistence_linux_runtime_files(source_libraries,fmt.tprintf("%s/lib/task_master",stable_directory),&runtime_files) {
        persistence_error_set(a,"Could not enumerate the packaged background runtime libraries.");return
    }
    runtime_changed:=false
    for runtime_file in runtime_files {
        source,source_error:=os.read_entire_file(runtime_file.source,context.temp_allocator)
        if source_error!=nil {persistence_error_set(a,fmt.tprintf("Could not read background runtime file: %s",runtime_file.source));return}
        installed,installed_error:=os.read_entire_file(runtime_file.destination,context.temp_allocator)
        if installed_error!=nil||string(installed)!=string(source) {runtime_changed=true}
    }
    runtime_environment:="UnsetEnvironment=LD_LIBRARY_PATH APPDIR APPIMAGE LIBDECOR_PLUGIN_DIR XLOCALEDIR XKB_CONFIG_ROOT FONTCONFIG_PATH FONTCONFIG_FILE"
    if os.is_dir(fmt.tprintf("%s/libdecor/plugins-1",source_libraries)) {
        // Override AppRun's mounted plugin path without unsetting our own stable
        // value. Native/dev runtimes instead discard any inherited plugin path.
        plugin_assignment:=fmt.tprintf("LIBDECOR_PLUGIN_DIR=%s/lib/task_master/libdecor/plugins-1",stable_directory)
        runtime_environment=fmt.tprintf("UnsetEnvironment=LD_LIBRARY_PATH APPDIR APPIMAGE XLOCALEDIR XKB_CONFIG_ROOT FONTCONFIG_PATH FONTCONFIG_FILE\nEnvironment=%s",persistence_unit_quote(plugin_assignment))
    }
    unit:=fmt.tprintf(`[Unit]
Description=task_master background device telemetry

[Service]
Type=simple
ExecStart=%s --persistence-service
Restart=on-failure
RestartSec=2
TimeoutStartSec=20
TimeoutStopSec=20
UMask=0077
%s

[Install]
WantedBy=default.target
`,persistence_unit_quote(stable_executable),runtime_environment)
    unit_path:=fmt.tprintf("%s/systemd/user/%s",directory,PERSISTENCE_UNIT)
    installed_unit,unit_error:=os.read_entire_file(unit_path,context.temp_allocator)
    unit_changed:=unit_error!=nil||string(installed_unit)!=unit
    if !runtime_changed&&!unit_changed {return true,false}
    if !persistence_linux_stop_for_update(a) {return}
    if runtime_changed {
        for runtime_file in runtime_files {
            source,source_error:=os.read_entire_file(runtime_file.source,context.temp_allocator)
            if source_error!=nil||!persistence_atomic_write(runtime_file.destination,source,runtime_file.permissions) {
                persistence_error_set(a,fmt.tprintf("Could not install background runtime file: %s",runtime_file.source));return
            }
        }
    }
    if unit_changed {
        if !persistence_atomic_write(unit_path,transmute([]u8)unit) {
            persistence_error_set(a,"Could not save the user persistence service. Check configuration directory permissions.");return
        }
        output:string
        success,output=persistence_systemctl([]string{"daemon-reload"})
        if !success {persistence_error_set(a,fmt.tprintf("Could not reload the user service: %s",output));return}
    }
    // Retire the pre-package executable only after the new unit is installed.
    _=os.remove(fmt.tprintf("%s/task_master",stable_directory))
    return true,true
}
// Service commands run synchronously only for terminal control or on a worker.
persistence_service_set :: proc(a:^App,enable:bool,refresh_only:bool=false,force_restart:bool=false)->bool {
    updated:=false
    if enable {
        installed:bool
        installed,updated=persistence_install_unit(a)
        if !installed {return false}
        if refresh_only&&!updated&&!force_restart {return true}
    }
    action:="enable" if enable else "disable"
    success:bool
    output:string
    if refresh_only {success,output=persistence_systemctl([]string{"restart",PERSISTENCE_UNIT})}
    else if enable&&updated {
        success,output=persistence_systemctl([]string{action,PERSISTENCE_UNIT})
        if success {success,output=persistence_systemctl([]string{"restart",PERSISTENCE_UNIT})}
    } else {success,output=persistence_systemctl([]string{action,"--now",PERSISTENCE_UNIT})}
    if success&&enable {success,output=persistence_systemctl([]string{"is-active",PERSISTENCE_UNIT})}
    if !success {
        if enable&&!refresh_only&&!a.persistence_enabled {_,_=persistence_systemctl([]string{"disable","--now",PERSISTENCE_UNIT})}
        persistence_error_set(a,fmt.tprintf("Could not %s persistence: %s",action,output));return false
    }
    a.persistence_enabled=enable
    a.persistence_error_len=0
    return true
}

persistence_stop:bool
persistence_stop_signal :: proc "c" (signal:posix.Signal) {sync.atomic_store(&persistence_stop,true)}
persistence_platform_service_init :: proc()->bool {
    _=posix.signal(.SIGPIPE,auto_cast posix.SIG_IGN)
    _=posix.signal(.SIGTERM,persistence_stop_signal)
    _=posix.signal(.SIGINT,persistence_stop_signal)
    return true
}
persistence_platform_service_stop_requested :: proc()->bool {return sync.atomic_load(&persistence_stop)}
persistence_platform_service_destroy :: proc() {}

platform_atomic_replace :: proc(source,destination:string)->bool {return os.rename(source,destination)==nil}
platform_private_path :: proc(path:string,directory:bool)->bool {
    if !directory {return true}
    return os.chmod(path,{.Read_User,.Write_User,.Execute_User})==nil
}

persistence_platform_cache_open :: proc(path:string)->(^os.File,os.Error) {return os.open(path)}

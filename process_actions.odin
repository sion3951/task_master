package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// Each action owns copied input; workers never access App or Machine storage.
Process_Kill_Action :: struct {
    node: PID_Node,
    nodes: []PID_Node,
    host: string,
    port: u16,
    local, success, done, stop: bool,
    windows, darwin: bool,
    collector, architecture: string,
    worker: ^thread.Thread,
    error: [256]u8,
    error_len: int,
    menu_name: [64]u8,
    menu_name_len: int,
}

process_kill_error :: proc(action:^Process_Kill_Action,message:string) {
    action.error_len=copy(action.error[:],message)
}


process_kill_remote :: proc(action:^Process_Kill_Action)->bool {
    // Send the captured identities over stdin, keeping even large groups out of
    // SSH's command-length limit. Each PID is checked before it is signalled.
    command:=`set -f
kill_one() {
pid=$1
expected=$2
if [ "$pid" -le 0 ] || [ "$expected" = 0 ]; then
    echo "PID $pid has no sampled identity." >&2
    return 1
fi
stat=$(cat "/proc/$pid/stat") || return 1
fields=${stat##*) }
set -- $fields
if [ "$#" -lt 20 ]; then
    echo "Could not read PID $pid identity." >&2
    return 1
fi
shift 19
if [ "$1" != "$expected" ]; then
    echo "PID $pid exited or changed; select its current row." >&2
    return 1
fi
kill -KILL "$pid"
}
failed=0
while IFS=' ' read -r pid expected; do
    if ! kill_one "$pid" "$expected"; then failed=1; fi
done
exit "$failed"
`
    binary:[]u8
    if action.darwin {
        architecture:=action.architecture
        if architecture==""&&action.collector==DEFAULT_COLLECTOR {
            probe:=Remote_Connection{host=action.host,port=action.port}
            platform,detected,ok:=remote_detect_platform(&probe)
            if !ok||platform!=.Darwin {process_kill_error(action,"Could not identify the macOS collector architecture.");return false}
            architecture=detected
        }
        command,binary=process_kill_darwin_command(architecture,action.collector)
        defer delete(command)
    } else if action.windows {command=process_kill_windows_command();defer delete(command)}
    s,start_error:=remote_ssh_start(action.host,command,action.port)
    if start_error!=nil {
        process_kill_error(action,fmt.tprintf("Could not start SSH: %v",start_error))
        return false
    }
    defer remote_ssh_close(&s)
    payload:=strings.builder_make(context.temp_allocator)
    if len(binary)>0 {strings.write_string(&payload,string(binary))}
    for node in action.nodes {strings.write_string(&payload,fmt.tprintf("%d %d\n",node.pid,node.start))}
    input:=transmute([]u8)strings.to_string(payload)
    if remote_ssh_prepare_transfer(&s)!=nil {
        process_kill_error(action,"Could not prepare the SSH PID list.")
        return false
    }
    when ODIN_OS==.Linux||ODIN_OS==.Darwin {transferred:=0}
    when ODIN_OS==.Windows {
        upload:=Remote_Upload{file=s.input,binary=input}
        upload.worker=thread.create_and_start_with_poly_data(&upload,remote_upload_worker,name="SSH PID list")
        if upload.worker==nil {process_kill_error(action,"Could not send the SSH PID list.");return false}
        defer remote_upload_close(&upload)
    }
    started:=time.tick_now()
    timeout:=15*time.Second+time.Duration(len(action.nodes))*100*time.Millisecond
    output:[1024]u8
    scratch:[1024]u8
    used:=0
    stdout_open,stderr_open,reaped,success:=true,true,false,false
    for {
        if sync.atomic_load(&action.stop) {
            process_kill_error(action,"PID kill was interrupted.")
            return false
        }
        if time.tick_since(started)>timeout {
            process_kill_error(action,"SSH PID kill timed out.")
            return false
        }
        if reaped&&!stdout_open&&!stderr_open {
            if !success {
                message:=strings.trim_space(string(output[:used]))
                if message=="" {message="SSH could not kill the selected PID."}
                process_kill_error(action,message)
            }
            return success
        }
        write_open:=false
        when ODIN_OS==.Linux||ODIN_OS==.Darwin {write_open=s.input!=nil&&transferred<len(input)}
        ready,poll_error:=remote_ssh_poll(&s,stdout_open,stderr_open,write_open,100)
        if poll_error!=nil {
            process_kill_error(action,fmt.tprintf("Could not read SSH result: %v",poll_error))
            return false
        }
        for index in 0..<2 {
            if !ready[index] {continue}
            file:=s.output if index==0 else s.errors
            count,eof,read_error:=remote_pipe_read(file,scratch[:])
            if count>0 {remote_error_append(output[:],&used,scratch[:count])}
            if read_error!=nil {
                process_kill_error(action,fmt.tprintf("Could not read SSH result: %v",read_error))
                return false
            }
            if eof {
                if index==0 {stdout_open=false} else {stderr_open=false}
            }
        }
        when ODIN_OS==.Linux||ODIN_OS==.Darwin {
            if ready[2] {
                remaining:=input[transferred:]
                count,write_error:=remote_pipe_write(s.input,remaining[:min(len(remaining),4096)])
                if write_error!=nil {process_kill_error(action,fmt.tprintf("Could not send the SSH PID list: %v",write_error));return false}
                transferred+=count
            }
            if s.input!=nil&&transferred==len(input) {os.close(s.input);s.input=nil}
        } else when ODIN_OS==.Windows {
            if sync.atomic_load(&upload.failed) {process_kill_error(action,"Could not send the SSH PID list.");return false}
            if s.input!=nil&&sync.atomic_load(&upload.done) {remote_upload_close(&upload);os.close(s.input);s.input=nil}
        }
        if !reaped {
            state,wait_error:=os.process_wait(s.process,0)
            if wait_error!=.Timeout {
                // A completed wait releases the child's handle.
                s.started=false;reaped=true
                success=wait_error==nil&&state.exited&&state.exit_code==0
                if wait_error!=nil {
                    process_kill_error(action,fmt.tprintf("Could not wait for SSH: %v",wait_error))
                    return false
                }
            }
        }
    }
}

process_kill_worker :: proc(action:^Process_Kill_Action) {
    if action.local {
        killed:=0
        first_error:[256]u8
        first_error_len:=0
        for node in action.nodes {
            if sync.atomic_load(&action.stop) {process_kill_error(action,"PID kill was interrupted.");break}
            action.node=node
            ok:=false
            if node.pid<=0||node.start==0 {process_kill_error(action,fmt.tprintf("PID %d has no sampled identity.",node.pid))}
            else {ok=process_kill_local(action)}
            if ok {killed+=1}
            else if first_error_len==0 {first_error_len=copy(first_error[:],action.error[:action.error_len])}
        }
        action.success=killed==len(action.nodes)
        if !action.success&&first_error_len>0 {
            process_kill_error(action,fmt.tprintf("Killed %d/%d PIDs: %s",killed,len(action.nodes),string(first_error[:first_error_len])))
        }
    } else {action.success=process_kill_remote(action)}
    free_all(context.temp_allocator)
    sync.atomic_store(&action.done,true)
    app_wake()
}

process_kill_start :: proc(a:^App,node:PID_Node) {
    if a.process_kill!=nil {return}
    if node.pid<=0||node.start==0 {
        a.process_menu_error_len=copy(a.process_menu_error[:],"Process identity is unavailable; wait for a current sample.")
        a.process_menu_open=true;a.dirty=true
        return
    }
    nodes:=[1]PID_Node{node}
    process_kill_start_many(a,nodes[:])
}

process_kill_start_many :: proc(a:^App,nodes:[]PID_Node) {
    if a.process_kill!=nil||len(nodes)==0 {return}
    selected:=a.machines[a.active_machine]
    action:=new(Process_Kill_Action)
    action.nodes=make([]PID_Node,len(nodes));copy(action.nodes,nodes)
    action.port=selected.port;action.local=selected==a.local_machine
    // If this app is in the group, send its signal last so it can kill the rest.
    if action.local {
        for node,i in action.nodes {
            if node.pid==i32(os.get_pid()) {action.nodes[i],action.nodes[len(action.nodes)-1]=action.nodes[len(action.nodes)-1],action.nodes[i];break}
        }
    }
    action.windows=selected.state.metrics.platform=="windows"
    action.darwin=selected.state.metrics.platform=="darwin"
    action.collector=strings.clone(string(selected.collector[:selected.collector_len]))
    if action.collector=="" {delete(action.collector);action.collector=strings.clone(DEFAULT_COLLECTOR)}
    if selected.connection!=nil {
        sync.mutex_lock(&selected.connection.mutex)
        action.architecture=strings.clone(string(selected.connection.architecture[:selected.connection.architecture_len]))
        sync.mutex_unlock(&selected.connection.mutex)
    }
    action.host=strings.clone(string(selected.host[:selected.host_len]))
    action.menu_name=a.process_menu_name;action.menu_name_len=a.process_menu_name_len
    action.worker=thread.create_and_start_with_poly_data(action,process_kill_worker,name="Kill PID")
    if action.worker==nil {
        process_kill_destroy(action)
        a.process_menu_error_len=copy(a.process_menu_error[:],"Could not start the PID kill worker.")
        a.process_menu_open=true
    } else {
        a.process_kill=action;a.process_menu_error_len=0
    }
    a.dirty=true
}

process_kill_poll :: proc(a:^App) {
    action:=a.process_kill
    if action==nil||!sync.atomic_load(&action.done) {return}
    selected:=a.machines[a.active_machine]
    same_machine:=selected==a.local_machine if action.local else selected!=a.local_machine&&selected.port==action.port&&string(selected.host[:selected.host_len])==action.host
    same_menu:=a.process_menu_name_len==action.menu_name_len&&string(a.process_menu_name[:a.process_menu_name_len])==string(action.menu_name[:action.menu_name_len])
    if same_machine&&same_menu {
        a.process_menu_error_len=copy(a.process_menu_error[:],action.error[:action.error_len])
        a.process_menu_open=!action.success
    }
    if !action.success {fmt.eprintln(string(action.error[:action.error_len]))}
    a.process_kill=nil
    process_kill_destroy(action)
    a.dirty=true
}

process_kill_destroy :: proc(action:^Process_Kill_Action) {
    if action==nil {return}
    sync.atomic_store(&action.stop,true)
    if action.worker!=nil {thread.join(action.worker);thread.destroy(action.worker)}
    delete(action.host)
    delete(action.collector)
    delete(action.architecture)
    delete(action.nodes)
    free(action)
}

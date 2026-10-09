#+build windows
package main

import "core:os"
import "core:fmt"
import "core:strings"
import "core:thread"
import "core:sync"
import "core:time"
import win "core:sys/windows"

foreign import ssh_kernel32 "system:kernel32.lib"
foreign ssh_kernel32 {
    @(link_name="CancelSynchronousIo")
    ssh_cancel_synchronous_io :: proc "system"(handle:win.HANDLE)->win.BOOL ---
    @(link_name="CreateJobObjectW")
    ssh_create_job :: proc "system"(attributes:^win.SECURITY_ATTRIBUTES,name:win.LPCWSTR)->win.HANDLE ---
    @(link_name="SetInformationJobObject")
    ssh_set_job_information :: proc "system"(job:win.HANDLE,class:u32,data:rawptr,bytes:u32)->win.BOOL ---
    @(link_name="AssignProcessToJobObject")
    ssh_assign_job_process :: proc "system"(job,process:win.HANDLE)->win.BOOL ---
}

// Native JOBOBJECT_EXTENDED_LIMIT_INFORMATION ABI, including SIZE_T fields.
SSH_Job_Basic_Limits :: struct {
    process_time,job_time:i64,
    flags:u32,
    minimum_working_set,maximum_working_set:uintptr,
    active_process_limit:u32,
    affinity:uintptr,
    priority_class,scheduling_class:u32,
}
SSH_Job_IO_Counters :: struct {read_operations,write_operations,other_operations,read_bytes,write_bytes,other_bytes:u64}
SSH_Job_Extended_Limits :: struct {
    basic:SSH_Job_Basic_Limits,
    io:SSH_Job_IO_Counters,
    process_memory,job_memory,peak_process_memory,peak_job_memory:uintptr,
}

remote_ssh_platform_close :: proc(s:^Remote_SSH) {
    if s.job!=0 {
        // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE terminates ProxyJump/ProxyCommand
        // descendants even when the primary SSH process was already reaped.
        win.CloseHandle(win.HANDLE(s.job))
        s.job=0
    }
}

remote_ssh_poll :: proc(s:^Remote_SSH,stdout_open,stderr_open,write_open:bool,timeout_ms:int)->(ready:[3]bool,err:os.Error) {
    started:=time.tick_now()
    for {
        files:=[2]^os.File{s.output,s.errors}
        opened:=[2]bool{stdout_open,stderr_open}
        for file,i in files {
            if !opened[i] {continue}
            available:u32
            if win.PeekNamedPipe(win.HANDLE(os.fd(file)),nil,0,nil,&available,nil) {ready[i]=available>0}
            else {
                code:=win.GetLastError()
                if code==win.ERROR_BROKEN_PIPE||code==win.ERROR_NO_DATA {ready[i]=true}
                else {return ready,os.Platform_Error(code)}
            }
        }
        if ready[0]||ready[1]||timeout_ms<=0||time.tick_since(started)>=time.Duration(timeout_ms)*time.Millisecond {return ready,nil}
        time.sleep(10*time.Millisecond)
    }
}

remote_pipe_read :: proc(file:^os.File,buffer:[]u8)->(count:int,eof:bool,err:os.Error) {
    available:u32
    if !win.PeekNamedPipe(win.HANDLE(os.fd(file)),nil,0,nil,&available,nil) {
        code:=win.GetLastError()
        if code==win.ERROR_BROKEN_PIPE||code==win.ERROR_NO_DATA {return 0,true,nil}
        return 0,false,os.Platform_Error(code)
    }
    if available==0 {return 0,false,nil}
    n,read_error:=os.read(file,buffer[:min(len(buffer),int(available))])
    return n,n==0,read_error
}

remote_ssh_prepare_parent_pipes :: proc(s:^Remote_SSH)->os.Error {
    // Inheriting the parent's pipe ends prevents EOF and leaks remote sessions.
    for file in ([]^os.File{s.input,s.output,s.errors}) {
        if !win.SetHandleInformation(win.HANDLE(os.fd(file)),win.HANDLE_FLAG_INHERIT,0) {return os.Platform_Error(win.GetLastError())}
    }
    return nil
}

remote_ssh_process_start :: proc(args:[]string,input,output,errors:^os.File)->(os.Process,uintptr,os.Error) {
    job:=ssh_create_job(nil,nil)
    if job==nil {return {},0,os.Platform_Error(win.GetLastError())}
    retained:=false
    defer if !retained {win.CloseHandle(job)}
    limits:=SSH_Job_Extended_Limits{basic={flags=0x2000}} // KILL_ON_JOB_CLOSE
    if !ssh_set_job_information(job,9,&limits,size_of(limits)) {return {},0,os.Platform_Error(win.GetLastError())}
    // CreateProcess' quoting rules differ from shell quoting. Quote every argument
    // and double trailing/backslash-before-quote runs exactly as the CRT expects.
    builder:=strings.builder_make(context.temp_allocator)
    for arg,index in args {
        if index>0 {strings.write_byte(&builder,' ')}
        strings.write_byte(&builder,'"')
        slashes:=0
        for ch in transmute([]u8)arg {
            if ch=='\\' {slashes+=1;continue}
            count:=slashes
            if ch=='"' {count=slashes*2+1}
            for _ in 0..<count {strings.write_byte(&builder,'\\')}
            strings.write_byte(&builder,ch)
            slashes=0
        }
        for _ in 0..<slashes*2 {strings.write_byte(&builder,'\\')}
        strings.write_byte(&builder,'"')
    }
    command:=win.utf8_to_utf16(strings.to_string(builder),context.temp_allocator)
    info:win.PROCESS_INFORMATION
    startup:=win.STARTUPINFOW{cb=size_of(win.STARTUPINFOW),dwFlags=win.STARTF_USESTDHANDLES,
        hStdInput=win.HANDLE(os.fd(input)),hStdOutput=win.HANDLE(os.fd(output)),hStdError=win.HANDLE(os.fd(errors))}
    // Suspend before assignment: SSH must never create a proxy child outside
    // our job during the race between CreateProcess and AssignProcessToJobObject.
    if !win.CreateProcessW(nil,cstring16(raw_data(command)),nil,nil,true,win.CREATE_NO_WINDOW|win.CREATE_SUSPENDED,nil,nil,&startup,&info) {return {},0,os.Platform_Error(win.GetLastError())}
    defer win.CloseHandle(info.hThread)
    if !ssh_assign_job_process(job,info.hProcess)||win.ResumeThread(info.hThread)==0xffffffff {
        error:=os.Platform_Error(win.GetLastError())
        _=win.TerminateProcess(info.hProcess,1)
        _=win.WaitForSingleObject(info.hProcess,2000)
        win.CloseHandle(info.hProcess)
        return {},0,error
    }
    retained=true
    return {pid=int(info.dwProcessId),handle=uintptr(info.hProcess)},uintptr(job),nil
}

Remote_Upload :: struct {
    file:^os.File,
    binary:[]u8,
    worker:^thread.Thread,
    done,failed,stop:bool,
}

remote_upload_worker :: proc(upload:^Remote_Upload) {
    offset:=0
    for offset<len(upload.binary)&&!sync.atomic_load(&upload.stop) {
        n,err:=os.write(upload.file,upload.binary[offset:min(offset+65536,len(upload.binary))])
        if err!=nil||n<=0 {sync.atomic_store(&upload.failed,true);break}
        offset+=n
    }
    sync.atomic_store(&upload.done,true)
}

remote_upload_close :: proc(upload:^Remote_Upload) {
    if upload.worker==nil {return}
    sync.atomic_store(&upload.stop,true)
    // Retry cancellation until the worker exits: it may have been between writes
    // when cancellation first raced with its next blocking synchronous write.
    for !sync.atomic_load(&upload.done) {
        ssh_cancel_synchronous_io(upload.worker.win32_thread)
        time.sleep(time.Millisecond)
    }
    thread.join(upload.worker)
    thread.destroy(upload.worker)
    upload.worker=nil
}

remote_ssh_prepare_transfer :: proc(s:^Remote_SSH)->os.Error {return nil}

machine_platform_terminal :: proc(script_path:string)->(os.Process,os.Error) {
    // A real console keeps SSH's tty and administrator prompts interactive.
    command:=win.utf8_to_utf16(fmt.tprintf("powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File \"%s\"",script_path),context.temp_allocator)
    info:win.PROCESS_INFORMATION
    startup:=win.STARTUPINFOW{cb=size_of(win.STARTUPINFOW)}
    if !win.CreateProcessW(nil,cstring16(raw_data(command)),nil,nil,false,win.CREATE_NEW_CONSOLE,nil,nil,&startup,&info) {return {},os.Platform_Error(win.GetLastError())}
    win.CloseHandle(info.hThread)
    return {pid=int(info.dwProcessId),handle=uintptr(info.hProcess)},nil
}
machine_platform_terminal_release :: proc(process:os.Process) {
    if process.handle!=0 {win.CloseHandle(win.HANDLE(process.handle))}
}

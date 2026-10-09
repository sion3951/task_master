#+build darwin
package main

import "core:os"
import "core:fmt"
import "core:strings"
import "core:sys/posix"

// Use libc's Darwin descriptors and errno rather than Linux syscall numbers.
remote_ssh_poll :: proc(s:^Remote_SSH,stdout_open,stderr_open,write_open:bool,timeout_ms:int)->(ready:[3]bool,err:os.Error) {
    descriptors:=[3]posix.pollfd{{fd=-1,events={.IN,.HUP}},{fd=-1,events={.IN,.HUP}},{fd=-1,events={.OUT,.HUP}}}
    if stdout_open {descriptors[0].fd=posix.FD(os.fd(s.output))}
    if stderr_open {descriptors[1].fd=posix.FD(os.fd(s.errors))}
    if write_open {descriptors[2].fd=posix.FD(os.fd(s.input))}
    if posix.poll(raw_data(descriptors[:]),posix.nfds_t(len(descriptors)),i32(timeout_ms))<0 {
        poll_error:=posix.errno()
        if poll_error==.EINTR {return ready,nil}
        return ready,poll_error
    }
    for descriptor,i in descriptors {ready[i]=descriptor.revents!={}}
    return ready,nil
}

remote_pipe_read :: proc(file:^os.File,buffer:[]u8)->(count:int,eof:bool,err:os.Error) {
    n:=posix.read(posix.FD(os.fd(file)),raw_data(buffer),uint(len(buffer)))
    if n<0 {
        read_error:=posix.errno()
        if read_error==.EINTR||read_error==.EAGAIN {return 0,false,nil}
        return 0,false,read_error
    }
    return int(n),n==0,nil
}

remote_darwin_nonblocking :: proc(file:^os.File)->os.Error {
    fd:=posix.FD(os.fd(file))
    flags:=posix.fcntl(fd,.GETFL)
    if flags<0 {return posix.errno()}
    if posix.fcntl(fd,.SETFL,flags|posix.O_NONBLOCK)<0 {return posix.errno()}
    return nil
}

remote_ssh_prepare_parent_pipes :: proc(s:^Remote_SSH)->os.Error {
    // Ready pipes can become empty when a signal interrupts reading. Keeping
    // only the parent's read ends nonblocking preserves cancellation latency.
    if err:=remote_darwin_nonblocking(s.output);err!=nil {return err}
    return remote_darwin_nonblocking(s.errors)
}
remote_ssh_process_start :: proc(args:[]string,input,output,errors:^os.File)->(os.Process,uintptr,os.Error) {
    process,error:=os.process_start({command=args,stdin=input,stdout=output,stderr=errors})
    return process,0,error
}
remote_ssh_prepare_transfer :: proc(s:^Remote_SSH)->os.Error {return remote_darwin_nonblocking(s.input)}
remote_pipe_write :: proc(file:^os.File,buffer:[]u8)->(int,os.Error) {
    n:=posix.write(posix.FD(os.fd(file)),raw_data(buffer),uint(len(buffer)))
    if n<0 {
        write_error:=posix.errno()
        if write_error==.EINTR||write_error==.EAGAIN {return 0,nil}
        return 0,write_error
    }
    return int(n),nil
}
remote_ssh_platform_close :: proc(s:^Remote_SSH) {}

machine_platform_terminal :: proc(script_path:string)->(os.Process,os.Error) {
    shell:=fmt.tprintf("/bin/sh %s",machine_shell_quote(script_path))
    shell,_=strings.replace_all(shell,"\\","\\\\",context.temp_allocator)
    shell,_=strings.replace_all(shell,"\"","\\\"",context.temp_allocator)
    script:=fmt.tprintf("tell application \"Terminal\"\nactivate\ndo script \"%s\"\nend tell",shell)
    return os.process_start({command=[]string{"osascript","-e",script},stdout=os.stdout,stderr=os.stderr})
}
machine_platform_terminal_release :: proc(process:os.Process) {}

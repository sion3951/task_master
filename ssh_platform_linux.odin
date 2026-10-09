#+build linux
package main

import "core:os"
import "core:sys/linux"

remote_ssh_poll :: proc(s:^Remote_SSH,stdout_open,stderr_open,write_open:bool,timeout_ms:int)->(ready:[3]bool,err:os.Error) {
    descriptors:=[3]linux.Poll_Fd{{fd=-1,events={.IN,.HUP}},{fd=-1,events={.IN,.HUP}},{fd=-1,events={.OUT,.HUP}}}
    if stdout_open {descriptors[0].fd=linux.Fd(os.fd(s.output))}
    if stderr_open {descriptors[1].fd=linux.Fd(os.fd(s.errors))}
    if write_open {descriptors[2].fd=linux.Fd(os.fd(s.input))}
    _,poll_error:=linux.poll(descriptors[:],i32(timeout_ms))
    if poll_error==.EINTR {return ready,nil}
    for descriptor,i in descriptors {ready[i]=descriptor.revents!={}}
    return ready,poll_error
}

remote_pipe_read :: proc(file:^os.File,buffer:[]u8)->(count:int,eof:bool,err:os.Error) {
    n,read_error:=linux.read(linux.Fd(os.fd(file)),buffer)
    if read_error==.EINTR||read_error==.EAGAIN {return 0,false,nil}
    return int(n),n==0,read_error
}

remote_ssh_prepare_parent_pipes :: proc(s:^Remote_SSH)->os.Error {return nil}
remote_ssh_process_start :: proc(args:[]string,input,output,errors:^os.File)->(os.Process,uintptr,os.Error) {
    process,error:=os.process_start({command=args,stdin=input,stdout=output,stderr=errors})
    return process,0,error
}

remote_ssh_prepare_transfer :: proc(s:^Remote_SSH)->os.Error {
    flags,err:=linux.fcntl(linux.Fd(os.fd(s.input)),linux.F_GETFL)
    if err==nil {err=linux.fcntl(linux.Fd(os.fd(s.input)),linux.F_SETFL,flags|{.NONBLOCK})}
    return err
}
remote_pipe_write :: proc(file:^os.File,buffer:[]u8)->(int,os.Error) {
    n,err:=linux.write(linux.Fd(os.fd(file)),buffer)
    if err==.EINTR||err==.EAGAIN {return 0,nil}
    return int(n),err
}

remote_ssh_platform_close :: proc(s:^Remote_SSH) {}

machine_platform_terminal :: proc(script_path:string)->(os.Process,os.Error) {
    choices:=[][]string{
        {"kitty","--","/bin/sh",script_path}, {"foot","--","/bin/sh",script_path},
        {"alacritty","-e","/bin/sh",script_path}, {"konsole","-e","/bin/sh",script_path},
        {"gnome-terminal","--wait","--","/bin/sh",script_path},
        {"xfce4-terminal","--disable-server","-x","/bin/sh",script_path},
        {"x-terminal-emulator","-e","/bin/sh",script_path}, {"xterm","-e","/bin/sh",script_path},
    }
    last_error:os.Error
    for args in choices {
        process,error:=os.process_start({command=args,stdout=os.stdout,stderr=os.stderr})
        if error==nil {return process,nil}
        last_error=error
    }
    return {},last_error
}
machine_platform_terminal_release :: proc(process:os.Process) {
    if process.handle!=0&&process.handle!=~uintptr(0) {_=linux.close(linux.Fd(process.handle))}
}

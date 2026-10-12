#+build linux, darwin
package main

import "core:crypto/sha2"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:sys/posix"
import security "../updater_security"

VERSION :: #config(TASK_MASTER_VERSION,string(#load("../VERSION")))
INSTALL_SCRIPT :: string(#load("../scripts/update-install-root.sh"))

// Open untrusted inputs once, without following a final symlink or blocking on
// a FIFO. Validate the open descriptor rather than racing a path-based stat.
open_input :: proc(path:string,limit:i64)->(^os.File,bool) {
    fd:=posix.open(strings.clone_to_cstring(path,context.temp_allocator),{.NOFOLLOW,.NONBLOCK,.CLOEXEC})
    if fd<0 {return nil,false}
    info:posix.stat_t
    if posix.fstat(fd,&info)!=nil||!posix.S_ISREG(info.st_mode)||info.st_size<0||i64(info.st_size)>limit {
        _=posix.close(fd);return nil,false
    }
    return os.new_file(uintptr(fd),path),true
}

read_metadata :: proc(path:string,limit:i64)->([]u8,bool) {
    file,ok:=open_input(path,limit)
    if !ok {return nil,false}
    defer os.close(file)
    size,err:=os.file_size(file)
    if err!=nil||size<=0||size>limit {return nil,false}
    data:=make([]u8,int(size),context.temp_allocator)
    used:=0
    for used<len(data) {
        count,re:=os.read(file,data[used:])
        if count<=0||re!=nil {return nil,false}
        used+=count
    }
    extra:[1]u8
    count,re:=os.read(file,extra[:])
    if count!=0||(re!=nil&&re!=io.Error.EOF) {return nil,false}
    return data,true
}

// The destination is private to this process. Hash the bytes as they are
// copied; no elevated command ever opens the mutable source package again.
snapshot_package :: proc(source,destination:string,asset:security.Asset)->bool {
    wanted:[32]u8
    if asset.size<=0||asset.size>security.MAX_PACKAGE||!security.hex(asset.sha256,wanted[:]) {return false}
    input,ok:=open_input(source,asset.size)
    if !ok {return false}
    defer os.close(input)
    size,se:=os.file_size(input)
    if se!=nil||size!=asset.size {return false}
    output,oe:=os.open(destination,{.Write,.Create,.Excl},{.Read_User,.Write_User})
    if oe!=nil {return false}
    defer os.close(output)
    hash:sha2.Context_256
    sha2.init_256(&hash)
    buffer:=make([]u8,1024*1024)
    defer delete(buffer)
    total:i64
    for {
        count,re:=os.read(input,buffer)
        if re!=nil&&re!=io.Error.EOF {return false}
        if count==0 {break}
        total+=i64(count)
        if total>asset.size {return false}
        written,we:=os.write(output,buffer[:count])
        if we!=nil||written!=count {return false}
        sha2.update(&hash,buffer[:count])
    }
    digest:[32]u8
    sha2.final(&hash,digest[:])
    return total==asset.size&&digest==wanted
}

verify_and_install :: proc(kind,stage,name:string,install:bool)->(bool,string) {
    platform:="linux" when ODIN_OS==.Linux else "darwin"
    arch:="amd64" when ODIN_ARCH==.amd64 else "arm64"
    when ODIN_ARCH!=.amd64&&ODIN_ARCH!=.arm64 {return false,"Unsupported updater architecture."}
    when ODIN_OS==.Darwin {arch=helper_darwin_native_architecture(arch)}
    when ODIN_OS==.Linux {
        if kind!="deb"&&kind!="appimage" {return false,"Invalid Linux package format."}
    } else {
        if kind!="macos" {return false,"Invalid macOS package format."}
    }
    if stage==""||stage[0]!='/'||strings.contains(stage,"\x00") {return false,"Invalid update staging directory."}
    data,mok:=read_metadata(fmt.tprintf("%s/update.json",stage),65536)
    signature,sok:=read_metadata(fmt.tprintf("%s/update.json.sig",stage),64)
    if !mok||!sok {return false,"Could not read bounded regular update metadata files."}
    manifest,verified:=security.verify_manifest(data,signature)
    if !verified {return false,"Update signature verification failed. Nothing was installed."}
    newer,valid:=security.version_newer(manifest.version,VERSION)
    if !valid||!newer {return false,"The signed update must be newer than the installed helper."}
    asset:security.Asset
    found:=false
    for candidate in manifest.assets {
        if candidate.os==platform&&candidate.arch==arch&&candidate.kind==kind {
            if found {return false,"Ambiguous signed platform packages."}
            asset=candidate;found=true
        }
    }
    if !found||asset.name!=name||
        !(security.release_url(asset.url,fmt.tprintf("v%s",manifest.version),asset.name)||
          security.release_url(asset.url,manifest.version,asset.name)) {
        return false,"The package does not match the signed release and this platform."
    }
    template:=strings.clone_to_cstring("/tmp/task_master-update-XXXXXX",context.temp_allocator)
    directory:=posix.mkdtemp(cast([^]u8)template)
    if directory==nil {return false,"Could not create a private installer directory."}
    work:=string(directory)
    defer os.remove_all(work)
    extension:="deb" if kind=="deb" else "pkg" if kind=="macos" else "AppImage"
    package_path:=fmt.tprintf("%s/update.%s",work,extension)
    if !snapshot_package(fmt.tprintf("%s/%s",stage,asset.name),package_path,asset) {
        return false,"The copied package did not match its signed size and checksum. Nothing was installed."
    }
    if !install {return true,"Signed update and private package copy verified; nothing was installed."}
    // A clean environment and fixed script embedded in this protected binary
    // prevent PATH, shell startup files or cache scripts from supplying code.
    process,error:=os.process_start({
        command=[]string{"/bin/sh","-c",INSTALL_SCRIPT,"task_master-update",kind,package_path,work},
        working_dir=work,env=[]string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin","HOME=/root","LANG=C"},
        stdin=os.stdin,stdout=os.stdout,stderr=os.stderr,
    })
    if error!=nil {return false,"Could not start the protected package installation."}
    state,wait_error:=os.process_wait(process)
    if wait_error!=nil||!state.exited||state.exit_code!=0 {return false,"Package installation failed; see the installation log."}
    return true,"The verified update was installed successfully."
}

main :: proc() {
    if len(os.args)!=5||(os.args[1]!="--install"&&os.args[1]!="--verify") {
        fmt.eprintln("Usage: update-helper --install|--verify deb|appimage|macos PRIVATE_STAGE PACKAGE_NAME")
        os.exit(2)
    }
    install:=os.args[1]=="--install"
    if install&&(posix.getuid()!=0||posix.geteuid()!=0) {
        fmt.eprintln("Installation requires administrator authorization.");os.exit(1)
    }
    _=posix.umask({.IWGRP,.IROTH,.IWOTH,.IXGRP,.IRGRP,.IXOTH})
    os.clear_env()
    success,message:=verify_and_install(os.args[2],os.args[3],os.args[4],install)
    if !success {fmt.eprintln(message);os.exit(1)}
    fmt.println(message)
}

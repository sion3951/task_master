package main

import "core:crypto/sha2"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import security "updater_security"


UPDATER_VERSION :: #config(TASK_MASTER_VERSION,string(#load("VERSION")))
UPDATER_PUBLIC_KEY :: security.PUBLIC_KEY
UPDATER_REPOSITORY :: security.REPOSITORY
UPDATER_INTERVAL :: 6*60*60
UPDATER_MAX_PACKAGE :: security.MAX_PACKAGE

Update_State :: enum {Idle,Checking,Downloading,Ready,Current,Error}
Update_Target :: struct {
    os,arch,kind,executable,portable_path:string,
    sha256:string,
    size:i64,
}
Update_Asset :: security.Asset
Update_Manifest :: security.Manifest
Update_GitHub_Asset :: struct {name,browser_download_url:string}
Update_GitHub_Release :: struct {tag_name:string,draft,prerelease:bool,assets:[]Update_GitHub_Asset}
Update_Settings :: struct {automatic:bool,last_checked:f64}
Updater :: struct {
    state:Update_State,
    message,version,package_path,stage:string,
    target:Update_Target,
    automatic,allow_automatic,handed_off:bool,
    last_checked,created_at:f64,
    directory:string,
    job:^Update_Job,
    worker:^thread.Thread,
}
// Everything touched by the worker is separately owned. The UI only observes
// the atomic flags until completion publishes the result with release/acquire.
Update_Job :: struct {
    stop,done,downloading:bool,
    target:Update_Target,
    directory,stage,message,version,package_path:string,
    state:Update_State,
}

updater_target_clone :: proc(t:Update_Target)->Update_Target {
    return {os=strings.clone(t.os),arch=strings.clone(t.arch),kind=strings.clone(t.kind),
        executable=strings.clone(t.executable),portable_path=strings.clone(t.portable_path),
        sha256=strings.clone(t.sha256),size=t.size}
}
updater_target_destroy :: proc(t:^Update_Target) {
    delete(t.os);delete(t.arch);delete(t.kind);delete(t.executable);delete(t.portable_path);delete(t.sha256)
    t^={}
}
updater_message :: proc(u:^Updater,message:string) {delete(u.message);u.message=strings.clone(message)}
updater_settings_save :: proc(u:^Updater) {
    if u.directory=="" {return}
    data,err:=json.marshal(Update_Settings{automatic=u.automatic,last_checked=u.last_checked},allocator=context.temp_allocator)
    if err==nil {_=persistence_atomic_write(fmt.tprintf("%s/settings.json",u.directory),data)}
}
updater_set_automatic :: proc(a:^App,enabled:bool) {
    if a.updater==nil {return}
    a.updater.automatic=enabled
    updater_settings_save(a.updater)
    a.dirty=true
}
// Read only bounded regular files, including before parsing untrusted metadata.
updater_read_bounded :: proc(path:string,limit:i64,allocator:=context.allocator)->([]u8,bool) {
    file,err:=os.open(path)
    if err!=nil {return nil,false}
    defer os.close(file)
    size,se:=os.file_size(file)
    if se!=nil||size<0||size>limit {return nil,false}
    data:=make([]u8,int(size),allocator)
    used:=0
    for used<len(data) {
        count,re:=os.read(file,data[used:])
        if re!=nil||count<=0 {delete(data,allocator);return nil,false}
        used+=count
    }
    return data,true
}
updater_init :: proc(a:^App,automatic:bool=true) {
    if a.updater!=nil {return}
    u:=new(Updater)
    a.updater=u
    u.automatic=true;u.allow_automatic=automatic;u.created_at=persistence_wall_time()
    base,err:=os.user_cache_dir(context.temp_allocator)
    if err!=nil {updater_message(u,"Could not find the update cache directory.");return}
    u.directory=strings.clone(fmt.tprintf("%s/task_master/updates",base))
    if os.mkdir_all(u.directory,{.Read_User,.Write_User,.Execute_User})!=nil||!platform_private_path(u.directory,true) {
        updater_message(u,"Could not create the private update cache directory.");return
    }
    settings:=Update_Settings{automatic=true}
    if data,ok:=updater_read_bounded(fmt.tprintf("%s/settings.json",u.directory),4096,context.temp_allocator);ok {
        if json.unmarshal(data,&settings,allocator=context.temp_allocator)==nil {
            u.automatic=settings.automatic
            now:=persistence_wall_time()
            if settings.last_checked>0&&settings.last_checked<=now {u.last_checked=settings.last_checked}
        }
    }
    result_path:=fmt.tprintf("%s/install-result.txt",u.directory)
    if data,ok:=updater_read_bounded(result_path,8192,context.temp_allocator);ok {
        result:=strings.trim_space(string(data))
        if strings.has_prefix(result,"success\n")||result=="success" {
            u.state=.Current;updater_message(u,"Update installed successfully.")
        } else {u.state=.Error;updater_message(u,result)}
        _=os.remove(result_path)
    }
}
updater_release_stage :: proc(u:^Updater) {
    if u.stage!=""&&!u.handed_off {_=os.remove_all(u.stage)}
    delete(u.stage);delete(u.package_path);delete(u.version)
    u.stage="";u.package_path="";u.version=""
    updater_target_destroy(&u.target)
}
updater_check :: proc(a:^App) {
    u:=a.updater
    if u==nil||u.job!=nil||u.handed_off {return}
    if u.directory=="" {u.state=.Error;updater_message(u,"Update cache is unavailable.");a.dirty=true;return}
    target,error:=updater_platform_target()
    if error!="" {u.state=.Error;updater_message(u,error);a.dirty=true;return}
    updater_release_stage(u)
    job:=new(Update_Job)
    job.target=updater_target_clone(target)
    job.directory=strings.clone(u.directory)
    job.stage=strings.clone(fmt.tprintf("%s/stage-%d-%d",u.directory,os.get_pid(),time.to_unix_nanoseconds(time.now())))
    u.state=.Checking;updater_message(u,"Checking GitHub for updates…")
    u.last_checked=persistence_wall_time();updater_settings_save(u)
    u.job=job
    u.worker=thread.create_and_start_with_poly_data(job,updater_worker,name="Automatic updates")
    if u.worker==nil {
        job.state=.Error;job.message=strings.clone("Could not start the update worker.")
        sync.atomic_store(&job.done,true)
    }
    a.dirty=true
}
updater_job_destroy :: proc(job:^Update_Job,retain_stage:bool=false) {
    if job==nil {return}
    if !retain_stage&&job.stage!="" {_=os.remove_all(job.stage)}
    updater_target_destroy(&job.target)
    delete(job.directory);delete(job.stage);delete(job.message);delete(job.version);delete(job.package_path)
    free(job)
}
updater_poll :: proc(a:^App) {
    u:=a.updater
    if u==nil {return}
    job:=u.job
    if job!=nil {
        if !sync.atomic_load(&job.done) {
            if u.state==.Checking&&sync.atomic_load(&job.downloading) {
                u.state=.Downloading;updater_message(u,"Downloading and verifying the update…");a.dirty=true
            }
            return
        }
        if u.worker!=nil {thread.join(u.worker);thread.destroy(u.worker);u.worker=nil}
        u.state=job.state
        updater_message(u,job.message)
        u.version=job.version;job.version=""
        if job.state==.Ready {
            u.stage=job.stage;job.stage=""
            u.package_path=job.package_path;job.package_path=""
            u.target=job.target;job.target={}
        }
        updater_job_destroy(job);u.job=nil;a.dirty=true
        return
    }
    now:=persistence_wall_time()
    if u.allow_automatic&&u.automatic&&u.state!=.Ready&&!u.handed_off&&now-u.created_at>=10&&now-u.last_checked>=UPDATER_INTERVAL {
        // A source checkout does not silently install a system package.
        _,error:=updater_platform_target()
        if error!="" {u.last_checked=now;updater_settings_save(u);return}
        updater_check(a)
    }
}
updater_destroy :: proc(a:^App) {
    u:=a.updater
    if u==nil {return}
    if u.job!=nil {
        sync.atomic_store(&u.job.stop,true)
        if u.worker!=nil {thread.join(u.worker);thread.destroy(u.worker)}
        updater_job_destroy(u.job)
    }
    updater_release_stage(u)
    delete(u.directory);delete(u.message);free(u);a.updater=nil
}

updater_version_parse :: security.version_parse
updater_version_newer :: security.version_newer
updater_hex :: security.hex
updater_url_component :: security.url_component
updater_release_url :: security.release_url

updater_verify_package :: proc(path:string,size:i64,expected:string,job:^Update_Job=nil)->bool {
    digest,wanted:[32]u8
    if size<=0||size>UPDATER_MAX_PACKAGE||!updater_hex(expected,wanted[:]) {return false}
    file,err:=os.open(path)
    if err!=nil {return false}
    defer os.close(file)
    actual,se:=os.file_size(file)
    if se!=nil||actual!=size {return false}
    hash:sha2.Context_256
    sha2.init_256(&hash)
    // SHA2 selects the host CPU's accelerated implementation when supported.
    buffer:=make([]u8,1024*1024)
    defer delete(buffer)
    total:i64
    for {
        if job!=nil&&sync.atomic_load(&job.stop) {return false}
        count,re:=os.read(file,buffer)
        if re!=nil&&re!=io.Error.EOF {return false}
        if count==0 {break}
        total+=i64(count)
        if total>size {return false}
        sha2.update(&hash,buffer[:count])
    }
    sha2.final(&hash,digest[:])
    return total==size&&digest==wanted
}
// Windows uses its built-in PowerShell/.NET client; AppImages bundle curl.
// Platform launchers quote arguments; redirects remain HTTPS with bounded size/time.
updater_fetch :: proc(job:^Update_Job,url,path:string,limit:i64)->bool {
    if sync.atomic_load(&job.stop) {return false}
    child:os.Process
    err:os.Error
    child_job:uintptr
    sync.mutex_lock(&remote_spawn_mutex)
    when ODIN_OS==.Windows {child,child_job,err=updater_windows_fetch_start(url,path,limit)}
    else {child,err=updater_unix_fetch_start(job,url,path,limit)}
    sync.mutex_unlock(&remote_spawn_mutex)
    if err!=nil {return false}
    defer updater_fetch_process_close(child_job)
    started:=time.tick_now()
    for {
        if sync.atomic_load(&job.stop)||time.tick_since(started)>310*time.Second {
            _=os.process_kill(child);_,_=os.process_wait(child,2*time.Second);_=os.remove(path);return false
        }
        // Also cap responses lacking Content-Length on older curl versions.
        if file,open_error:=os.open(path);open_error==nil {
            size,_:=os.file_size(file);_=os.close(file)
            if size>limit {_=os.process_kill(child);_,_=os.process_wait(child,2*time.Second);_=os.remove(path);return false}
        }
        state,wait_error:=os.process_wait(child,100*time.Millisecond)
        if wait_error==.Timeout {continue}
        if wait_error!=nil||!state.exited||state.exit_code!=0 {_=os.remove(path);return false}
        return platform_private_path(path,false)
    }
}
updater_fetch_process_close :: proc(child_job:uintptr) {
    when ODIN_OS==.Windows {updater_windows_fetch_close(child_job)}
}
updater_fail :: proc(job:^Update_Job,message:string) {job.state=.Error;job.message=strings.clone(message)}
updater_worker :: proc(job:^Update_Job) {
    defer {
        sync.atomic_store(&job.done,true)
        if !persistence_headless&&!sync.atomic_load(&job.stop) {app_wake()}
    }
    if os.make_directory(job.stage,{.Read_User,.Write_User,.Execute_User})!=nil||!platform_private_path(job.stage,true) {
        updater_fail(job,"Could not create the update download directory.");return
    }
    api_path:=fmt.tprintf("%s/release.json",job.stage)
    if !updater_fetch(job,"https://api.github.com/repos/sion3951/task_master/releases/latest",api_path,1024*1024) {
        when ODIN_OS==.Windows {updater_fail(job,"Could not check GitHub. Check your connection and Windows HTTPS/proxy settings, then try again.")}
        else {updater_fail(job,"Could not check GitHub. Check your connection and that curl is installed, then try again.")}
        return
    }
    release_bytes,read_ok:=updater_read_bounded(api_path,1024*1024,context.temp_allocator)
    release:Update_GitHub_Release
    if !read_ok||json.unmarshal(release_bytes,&release,allocator=context.temp_allocator)!=nil||release.draft||release.prerelease {
        updater_fail(job,"GitHub returned invalid stable release metadata.");return
    }
    newer,valid:=updater_version_newer(release.tag_name,UPDATER_VERSION)
    if !valid {updater_fail(job,"The release or installed version is not a supported stable semantic version.");return}
    if !newer {job.state=.Current;job.message=strings.clone("You are running the latest version.");return}
    manifest_url,signature_url:="",""
    for asset in release.assets {
        if asset.name=="update.json"&&updater_release_url(asset.browser_download_url,release.tag_name,asset.name) {manifest_url=asset.browser_download_url}
        if asset.name=="update.json.sig"&&updater_release_url(asset.browser_download_url,release.tag_name,asset.name) {signature_url=asset.browser_download_url}
    }
    if manifest_url==""||signature_url=="" {updater_fail(job,"This release has no signed update metadata yet. Install it from GitHub manually.");return}
    manifest_path:=fmt.tprintf("%s/update.json",job.stage)
    signature_path:=fmt.tprintf("%s/update.json.sig",job.stage)
    if !updater_fetch(job,manifest_url,manifest_path,65536)||!updater_fetch(job,signature_url,signature_path,64) {
        updater_fail(job,"Could not download the signed update metadata.");return
    }
    manifest_bytes,mok:=updater_read_bounded(manifest_path,65536,context.temp_allocator)
    signature,sok:=updater_read_bounded(signature_path,64,context.temp_allocator)
    manifest,verified:=security.verify_manifest(manifest_bytes,signature)
    if !mok||!sok||!verified {
        updater_fail(job,"Update signature verification failed. Nothing was installed.");return
    }
    if strings.trim_prefix(release.tag_name,"v")!=manifest.version {
        updater_fail(job,"The signed update manifest is invalid or belongs to a different release.");return
    }
    asset:Update_Asset
    found:=false
    for candidate in manifest.assets {
        if candidate.os==job.target.os&&candidate.arch==job.target.arch&&candidate.kind==job.target.kind {
            if found {updater_fail(job,"The update manifest contains ambiguous platform packages.");return}
            asset=candidate;found=true
        }
    }
    wanted:[32]u8
    if !found {updater_fail(job,"This release has no package for your platform and installation format.");return}
    if asset.size<=0||asset.size>UPDATER_MAX_PACKAGE||!updater_hex(asset.sha256,wanted[:])||
        !updater_release_url(asset.url,release.tag_name,asset.name) {
        updater_fail(job,"The signed update package metadata is invalid.");return
    }
    sync.atomic_store(&job.downloading,true)
    package_path:=fmt.tprintf("%s/%s",job.stage,asset.name)
    if !updater_fetch(job,asset.url,package_path,asset.size) {
        updater_fail(job,"The update download failed. Check your connection and available disk space, then try again.");return
    }
    if !updater_verify_package(package_path,asset.size,asset.sha256,job) {
        updater_fail(job,"The downloaded update did not match its signed size and checksum. Nothing was installed.");return
    }
    job.state=.Ready;job.version=strings.clone(manifest.version)
    job.package_path=strings.clone(package_path)
    job.target.sha256=strings.clone(asset.sha256);job.target.size=asset.size
    job.message=strings.clone(fmt.tprintf("Version %s is downloaded and verified. Restart to install.",manifest.version))
}

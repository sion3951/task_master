package main

import "core:crypto/ed25519"
import "core:crypto/sha2"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

REMOTE_HELPER_MAX_BYTES :: i64(256*1024*1024)

Remote_Helper_Cancel :: struct {
    job:^Update_Job,
    source:^bool,
    done:bool,
}
remote_helper_cancel_worker :: proc(cancel:^Remote_Helper_Cancel) {
    for !sync.atomic_load(&cancel.done) {
        if sync.atomic_load(cancel.source) {sync.atomic_store(&cancel.job.stop,true);return}
        time.sleep(100*time.Millisecond)
    }
}
remote_helper_platform :: proc(system:string)->Remote_Platform {
    switch system {
    case "linux":return .Linux
    case "darwin":return .Darwin
    case "windows":return .Windows
    }
    return .Unknown
}
remote_helper_system :: proc(platform:Remote_Platform)->string {
    #partial switch platform {
    case .Linux:return "linux"
    case .Darwin:return "darwin"
    case .Windows:return "windows"
    }
    return ""
}
remote_helper_supported :: proc(system,architecture:string)->bool {
    if remote_helper_platform(system)==.Unknown {return false}
    return architecture=="amd64"||architecture=="arm64"||system=="linux"&&architecture=="riscv64"
}

// A cache entry remains useful offline only while its signature, exact version,
// and selected asset checksum still verify. Never resolve helpers via latest:
// collectors must agree with this desktop's protocol and release.
remote_helper_manifest :: proc(directory,version:string)->(Update_Manifest,bool) {
    manifest_bytes,mok:=updater_read_bounded(fmt.tprintf("%s/update.json",directory),65536,context.temp_allocator)
    signature,sok:=updater_read_bounded(fmt.tprintf("%s/update.json.sig",directory),64,context.temp_allocator)
    key_bytes:[32]u8
    key:ed25519.Public_Key
    if !mok||!sok||len(signature)!=64||!updater_hex(UPDATER_PUBLIC_KEY,key_bytes[:])||
        !ed25519.public_key_set_bytes(&key,key_bytes[:])||!ed25519.verify(&key,manifest_bytes,signature) {return {},false}
    manifest:Update_Manifest
    if json.unmarshal(manifest_bytes,&manifest,allocator=context.temp_allocator)!=nil||manifest.schema!=1||manifest.version!=version {return {},false}
    return manifest,true
}

remote_helper_download :: proc(system,architecture,kind:string,stop:^bool=nil)->(data:[]u8,error:string) {
    if !remote_helper_supported(system,architecture)||kind!="collector"&&!(system=="windows"&&kind=="sensors") {
        return nil,"This release does not support that remote helper platform."
    }
    version:=strings.trim_space(UPDATER_VERSION)
    if version==""||len(version)>160||strings.contains_any(version,"/\\\r\n\t")||version=="."||version==".." {
        return nil,"This build has no valid exact release version for remote helpers."
    }
    base,base_error:=os.user_cache_dir(context.temp_allocator)
    if base_error!=nil {return nil,"Could not find the remote helper cache directory."}
    directory:=fmt.tprintf("%s/task_master/helpers/%s",base,version)
    if os.mkdir_all(directory,{.Read_User,.Write_User,.Execute_User})!=nil||!platform_private_path(directory,true) {
        return nil,"Could not create the private remote helper cache directory."
    }
    // Each caller stages separately. Atomic rename publishes complete files,
    // without a process-global temporary filename or a stale persistent lock.
    stage,stage_error:=os.make_directory_temp(directory,"download-*",context.allocator)
    if stage_error!=nil {return nil,"Could not create remote helper download staging."}
    defer {_=os.remove_all(stage);delete(stage)}
    if os.chmod(stage,{.Read_User,.Write_User,.Execute_User})!=nil||!platform_private_path(stage,true) {
        return nil,"Could not protect remote helper download staging."
    }
    target,_:=updater_platform_target()
    if ODIN_OS==.Linux {
        // Helper preparation also runs in manual installs and source builds;
        // these are intentionally not updater installation targets.
        executable,executable_error:=os.get_executable_path(context.temp_allocator)
        if executable_error==nil&&os.is_file(fmt.tprintf("%s/curl",filepath.dir(executable))) {
            target.os="linux";target.kind="appimage";target.executable=executable
        }
    }
    job:=Update_Job{target=target}
    cancel:=Remote_Helper_Cancel{job=&job,source=stop}
    cancel_worker:^thread.Thread
    if stop!=nil {
        cancel_worker=thread.create_and_start_with_poly_data(&cancel,remote_helper_cancel_worker,name="Remote helper cancellation")
        if cancel_worker==nil {return nil,"Could not start remote helper cancellation monitoring."}
    }
    defer {
        sync.atomic_store(&cancel.done,true)
        if cancel_worker!=nil {thread.join(cancel_worker);thread.destroy(cancel_worker)}
    }
    tag:=fmt.tprintf("v%s",version)
    manifest,verified:=remote_helper_manifest(directory,version)
    if !verified {
        for name in ([]string{"update.json","update.json.sig"}) {
            limit:=i64(65536) if name=="update.json" else i64(64)
            url:=fmt.tprintf("%s%s/%s",UPDATER_REPOSITORY,updater_url_component(tag),name)
            if !updater_fetch(&job,url,fmt.tprintf("%s/%s",stage,name),limit) {
                return nil,"Could not download this version's signed remote helper metadata. Internet access is required until the helper is cached; check curl and the published release."
            }
        }
        manifest,verified=remote_helper_manifest(stage,version)
        if !verified {return nil,"Remote helper metadata signature or exact release version verification failed."}
        for name in ([]string{"update.json","update.json.sig"}) {
            if !platform_atomic_replace(fmt.tprintf("%s/%s",stage,name),fmt.tprintf("%s/%s",directory,name)) {
                return nil,"Could not retain signed remote helper metadata in the private cache."
            }
        }
    }
    name:=fmt.tprintf("task_master-collector-%s-%s",system,architecture)
    if kind=="sensors" {name=fmt.tprintf("task_master-windows-sensors-%s.zip",architecture)}
    asset:Update_Asset
    found:=false
    for candidate in manifest.assets {
        if candidate.os==system&&candidate.arch==architecture&&candidate.kind==kind {
            if found {return nil,"The signed remote helper manifest contains ambiguous platform assets."}
            asset=candidate;found=true
        }
    }
    wanted:[32]u8
    if !found {return nil,"This exact release has no published helper for the remote OS and architecture."}
    if asset.name!=name||asset.size<=0||asset.size>REMOTE_HELPER_MAX_BYTES||!updater_hex(asset.sha256,wanted[:])||
        !updater_release_url(asset.url,tag,asset.name) {return nil,"The signed remote helper asset metadata is invalid."}
    path:=fmt.tprintf("%s/%s",directory,name)
    if !updater_verify_package(path,asset.size,asset.sha256,&job) {
        pending:=fmt.tprintf("%s/%s",stage,name)
        if !updater_fetch(&job,asset.url,pending,asset.size) {
            return nil,"Could not download the remote helper. Internet access is required until it is cached."
        }
        if !updater_verify_package(pending,asset.size,asset.sha256,&job) {
            return nil,"Remote helper checksum verification failed; the downloaded file was discarded."
        }
        if !platform_atomic_replace(pending,path) {return nil,"Could not retain the verified remote helper in the private cache."}
    }
    if sync.atomic_load(&job.stop) {return nil,"Remote helper download cancelled."}
    bytes,ok:=updater_read_bounded(path,asset.size)
    if !ok||i64(len(bytes))!=asset.size {delete(bytes);return nil,"Could not read the verified remote helper cache entry."}
    // Verify the actual bytes returned too: another caller can atomically
    // replace a cache entry between the file verification and this read.
    hash:sha2.Context_256
    digest:[32]u8
    sha2.init_256(&hash);sha2.update(&hash,bytes);sha2.final(&hash,digest[:])
    if digest!=wanted {delete(bytes);return nil,"Remote helper cache bytes did not match the signed checksum."}
    return bytes,""
}

remote_helper_collector :: proc(platform:Remote_Platform,architecture:string,stop:^bool=nil)->([]u8,string) {
    return remote_helper_download(remote_helper_system(platform),remote_architecture_name(architecture),"collector",stop)
}

remote_helper_prepare :: proc(system,architecture,stage:string)->bool {
    arch:=remote_architecture_name(architecture)
    if !remote_helper_supported(system,arch) {fmt.eprintln("Unsupported remote helper OS or architecture.");return false}
    if !os.is_dir(stage)||!platform_private_path(stage,true) {fmt.eprintln("Remote helper staging must be an existing private directory.");return false}
    collector:=remote_collector_payload(remote_helper_platform(system),arch)
    owned:=false
    if len(collector)==0 {
        error:string
        collector,error=remote_helper_download(system,arch,"collector")
        if error!="" {fmt.eprintln(error);return false}
        owned=true
    }
    defer {if owned {delete(collector)}}
    path:=fmt.tprintf("%s/collector-%s-%s",stage,system,arch)
    if os.write_entire_file(path,collector,{.Read_User,.Write_User})!=nil||!platform_private_path(path,false) {
        fmt.eprintln("Could not stage the remote collector.");return false
    }
    if system=="windows" {
        sensors,error:=remote_helper_download(system,arch,"sensors")
        if error!="" {fmt.eprintln(error);return false}
        defer delete(sensors)
        sensors_path:=fmt.tprintf("%s/sensors.zip",stage)
        if os.write_entire_file(sensors_path,sensors,{.Read_User,.Write_User})!=nil||!platform_private_path(sensors_path,false) {
            fmt.eprintln("Could not stage the Windows remote sensors.");return false
        }
    }
    fmt.printf("Prepared %s %s remote helpers for version %s.\n",system,arch,strings.trim_space(UPDATER_VERSION))
    return true
}

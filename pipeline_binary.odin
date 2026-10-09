package main

import "core:fmt"
import "core:os"
import vk "vendor:vulkan"

// One replaceable cache per surface format. Driver global and pipeline keys
// cover device/driver compatibility, shaders and all fixed pipeline state.
PIPELINE_BINARY_MAGIC :: "TMPBIN01"
PIPELINE_BINARY_MAX_BYTES :: 8*1024*1024
PIPELINE_BINARY_MAX_COUNT :: 64

pipeline_binary_extensions :: proc(r:^Renderer, api_version:u32)->bool {
    properties:vk.PhysicalDeviceProperties
    vk.GetPhysicalDeviceProperties(r.physical,&properties)
    if api_version<vk.API_VERSION_1_3||properties.apiVersion<vk.API_VERSION_1_3 {return false}
    count:u32
    if vk.EnumerateDeviceExtensionProperties(r.physical,nil,&count,nil)!=.SUCCESS {return false}
    extensions:=make([]vk.ExtensionProperties,int(count));defer delete(extensions)
    if vk.EnumerateDeviceExtensionProperties(r.physical,nil,&count,raw_data(extensions))!=.SUCCESS {return false}
    binary,maintenance:bool
    for &extension in extensions[:int(count)] {
        name:=string(cast(cstring)&extension.extensionName[0])
        binary=binary||name=="VK_KHR_pipeline_binary"
        maintenance=maintenance||name=="VK_KHR_maintenance5"
    }
    return binary&&maintenance
}

pipeline_binary_hash :: proc(data:[]u8)->u64 {
    hash:u64=14695981039346656037
    for byte in data {hash=(hash~u64(byte))*1099511628211}
    return hash
}
pipeline_binary_put_u32 :: proc(data:^[dynamic]u8,value:u32) {
    for shift in 0..<4 {append(data,u8(value>>u32(shift*8)))}
}
pipeline_binary_put_key :: proc(data:^[dynamic]u8,key:vk.PipelineBinaryKeyKHR) {
    pipeline_binary_put_u32(data,key.keySize)
    for i in 0..<int(key.keySize) {append(data,key.key[i])}
}
pipeline_binary_key_valid :: proc(key:vk.PipelineBinaryKeyKHR)->bool {
    return key.keySize>0&&key.keySize<=vk.MAX_PIPELINE_BINARY_KEY_SIZE_KHR
}
pipeline_binary_key_equal :: proc(a,b:vk.PipelineBinaryKeyKHR)->bool {
    if !pipeline_binary_key_valid(a)||a.keySize!=b.keySize {return false}
    for i in 0..<int(a.keySize) {if a.key[i]!=b.key[i] {return false}}
    return true
}

Pipeline_Binary_Reader :: struct {data:[]u8,offset:int,valid:bool}
pipeline_binary_take :: proc(reader:^Pipeline_Binary_Reader,size:int)->[]u8 {
    if !reader.valid||size<0||size>len(reader.data)-reader.offset {reader.valid=false;return nil}
    result:=reader.data[reader.offset:reader.offset+size]
    reader.offset+=size
    return result
}
pipeline_binary_u32 :: proc(reader:^Pipeline_Binary_Reader)->u32 {
    bytes:=pipeline_binary_take(reader,4)
    if !reader.valid {return 0}
    value:u32
    for byte,i in bytes {value|=u32(byte)<<u32(i*8)}
    return value
}
pipeline_binary_key :: proc(reader:^Pipeline_Binary_Reader)->vk.PipelineBinaryKeyKHR {
    key:=vk.PipelineBinaryKeyKHR{sType=.PIPELINE_BINARY_KEY_KHR,keySize=pipeline_binary_u32(reader)}
    if !pipeline_binary_key_valid(key) {reader.valid=false;return key}
    copy(key.key[:],pipeline_binary_take(reader,int(key.keySize)))
    return key
}

pipeline_binary_identity :: proc(r:^Renderer,info:^vk.GraphicsPipelineCreateInfo,
    global,pipeline:^vk.PipelineBinaryKeyKHR)->(path:string) {
    if !r.pipeline_binaries {return ""}
    global^=vk.PipelineBinaryKeyKHR{sType=.PIPELINE_BINARY_KEY_KHR}
    pipeline^=vk.PipelineBinaryKeyKHR{sType=.PIPELINE_BINARY_KEY_KHR}
    create:=vk.PipelineCreateInfoKHR{sType=.PIPELINE_CREATE_INFO_KHR,pNext=info}
    if vk.GetPipelineKeyKHR(r.device,nil,global)!=.SUCCESS||!pipeline_binary_key_valid(global^)||
        vk.GetPipelineKeyKHR(r.device,&create,pipeline)!=.SUCCESS||!pipeline_binary_key_valid(pipeline^) {return ""}
    directory,err:=os.user_cache_dir(context.temp_allocator)
    if err!=nil {return ""}
    return fmt.tprintf("%s/task_master/pipelines/ui-%d.bin",directory,int(r.format))
}

pipeline_binary_destroy :: proc(r:^Renderer,binaries:[]vk.PipelineBinaryKHR) {
    for binary in binaries {if binary!=0 {vk.DestroyPipelineBinaryKHR(r.device,binary,nil)}}
}

// Validate bounded file data and both identities before handing opaque bytes to
// the driver. A corrupt, outdated or rejected cache simply takes the cold path.
pipeline_binary_load :: proc(r:^Renderer,path:string,global,pipeline:vk.PipelineBinaryKeyKHR,
    info:^vk.GraphicsPipelineCreateInfo)->bool {
    if path=="" {return false}
    file,err:=os.open(path)
    if err!=nil {return false}
    defer os.close(file)
    size,size_error:=os.file_size(file)
    if size_error!=nil||size<16||size>PIPELINE_BINARY_MAX_BYTES {return false}
    bytes:=make([]u8,int(size));defer delete(bytes)
    used:=0
    for used<len(bytes) {
        n,read_error:=os.read(file,bytes[used:])
        if read_error!=nil||n<=0 {return false}
        used+=n
    }
    reader:=Pipeline_Binary_Reader{data=bytes,valid=true}
    if string(pipeline_binary_take(&reader,8))!=PIPELINE_BINARY_MAGIC {return false}
    checksum_bytes:=pipeline_binary_take(&reader,8)
    checksum:u64
    for byte,i in checksum_bytes {checksum|=u64(byte)<<u32(i*8)}
    if !reader.valid||checksum!=pipeline_binary_hash(bytes[16:]) {return false}
    saved_global:=pipeline_binary_key(&reader)
    saved_pipeline:=pipeline_binary_key(&reader)
    if !reader.valid||!pipeline_binary_key_equal(global,saved_global)||!pipeline_binary_key_equal(pipeline,saved_pipeline) {return false}
    count:=pipeline_binary_u32(&reader)
    if !reader.valid||count==0||count>PIPELINE_BINARY_MAX_COUNT {return false}
    keys:=make([]vk.PipelineBinaryKeyKHR,int(count));defer delete(keys)
    data:=make([]vk.PipelineBinaryDataKHR,int(count));defer delete(data)
    for &key,i in keys {
        key=pipeline_binary_key(&reader)
        data_size:=pipeline_binary_u32(&reader)
        if !reader.valid||data_size==0||data_size>PIPELINE_BINARY_MAX_BYTES {return false}
        blob:=pipeline_binary_take(&reader,int(data_size))
        if !reader.valid {return false}
        data[i]=vk.PipelineBinaryDataKHR{dataSize=len(blob),pData=raw_data(blob)}
    }
    if reader.offset!=len(bytes) {return false}
    binaries:=make([]vk.PipelineBinaryKHR,int(count));defer delete(binaries)
    defer pipeline_binary_destroy(r,binaries)
    keys_data:=vk.PipelineBinaryKeysAndDataKHR{binaryCount=count,pPipelineBinaryKeys=raw_data(keys),pPipelineBinaryData=&data[0]}
    create:=vk.PipelineBinaryCreateInfoKHR{sType=.PIPELINE_BINARY_CREATE_INFO_KHR,pKeysAndDataInfo=&keys_data}
    handles:=vk.PipelineBinaryHandlesInfoKHR{sType=.PIPELINE_BINARY_HANDLES_INFO_KHR,pipelineBinaryCount=count,pPipelineBinaries=raw_data(binaries)}
    if vk.CreatePipelineBinariesKHR(r.device,&create,nil,&handles)!=.SUCCESS||handles.pipelineBinaryCount!=count {return false}
    binary_info:=vk.PipelineBinaryInfoKHR{sType=.PIPELINE_BINARY_INFO_KHR,binaryCount=count,pPipelineBinaries=raw_data(binaries)}
    previous:=info.pNext
    info.pNext=&binary_info
    defer {info.pNext=previous}
    loaded:vk.Pipeline
    result:=vk.CreateGraphicsPipelines(r.device,0,1,info,nil,&loaded)
    if result!=.SUCCESS {
        if loaded!=0 {vk.DestroyPipeline(r.device,loaded,nil)}
        return false
    }
    r.pipeline=loaded
    if startup_profile {fmt.printf("Pipeline binary: loaded %d binaries (%d bytes); no shader modules\n",count,len(bytes))}
    return true
}

pipeline_binary_save :: proc(r:^Renderer,path:string,global,pipeline:vk.PipelineBinaryKeyKHR) {
    if path=="" {return}
    release:=vk.ReleaseCapturedPipelineDataInfoKHR{sType=.RELEASE_CAPTURED_PIPELINE_DATA_INFO_KHR,pipeline=r.pipeline}
    defer vk.ReleaseCapturedPipelineDataKHR(r.device,&release,nil)
    create:=vk.PipelineBinaryCreateInfoKHR{sType=.PIPELINE_BINARY_CREATE_INFO_KHR,pipeline=r.pipeline}
    handles:=vk.PipelineBinaryHandlesInfoKHR{sType=.PIPELINE_BINARY_HANDLES_INFO_KHR}
    if vk.CreatePipelineBinariesKHR(r.device,&create,nil,&handles)!=.SUCCESS||
        handles.pipelineBinaryCount==0||handles.pipelineBinaryCount>PIPELINE_BINARY_MAX_COUNT {return}
    count:=handles.pipelineBinaryCount
    binaries:=make([]vk.PipelineBinaryKHR,int(count));defer delete(binaries)
    defer pipeline_binary_destroy(r,binaries)
    handles.pPipelineBinaries=raw_data(binaries)
    if vk.CreatePipelineBinariesKHR(r.device,&create,nil,&handles)!=.SUCCESS||handles.pipelineBinaryCount!=count {return}
    bytes:=make([dynamic]u8,0,4096);defer delete(bytes)
    append(&bytes,PIPELINE_BINARY_MAGIC)
    for _ in 0..<8 {append(&bytes,0)}
    pipeline_binary_put_key(&bytes,global)
    pipeline_binary_put_key(&bytes,pipeline)
    pipeline_binary_put_u32(&bytes,count)
    for binary in binaries {
        data_info:=vk.PipelineBinaryDataInfoKHR{sType=.PIPELINE_BINARY_DATA_INFO_KHR,pipelineBinary=binary}
        key:=vk.PipelineBinaryKeyKHR{sType=.PIPELINE_BINARY_KEY_KHR}
        size:int
        if vk.GetPipelineBinaryDataKHR(r.device,&data_info,&key,&size,nil)!=.SUCCESS||
            !pipeline_binary_key_valid(key)||size<=0||size>PIPELINE_BINARY_MAX_BYTES-len(bytes)-40 {return}
        blob:=make([]u8,size)
        result:=vk.GetPipelineBinaryDataKHR(r.device,&data_info,&key,&size,raw_data(blob))
        valid:=result==.SUCCESS&&pipeline_binary_key_valid(key)&&size>0&&size<=len(blob)
        if valid {
            pipeline_binary_put_key(&bytes,key)
            pipeline_binary_put_u32(&bytes,u32(size))
            append(&bytes,..blob[:size])
        }
        delete(blob)
        if !valid {return}
    }
    checksum:=pipeline_binary_hash(bytes[16:])
    for i in 0..<8 {bytes[8+i]=u8(checksum>>u32(i*8))}
    saved:=persistence_atomic_write(path,bytes[:])
    if startup_profile {fmt.printf("Pipeline binary: compiled; %d binaries / %d bytes; saved %v\n",count,len(bytes),saved)}
}

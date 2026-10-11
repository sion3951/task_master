#+build darwin
package main

import "core:fmt"
import "core:os"
import "core:strings"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"

RENDERER_METAL_CACHE_MAX_BYTES :: 8*1024*1024
// Increment this when vertex layout or other fixed pipeline state changes.
RENDERER_METAL_CACHE_VERSION :: "task-master-metal-ui-1-BGRA8Unorm"

renderer_metal_cache_hash :: proc(value:string)->u64 {
    hash:u64=14695981039346656037
    for byte in transmute([]u8)value {hash=(hash~u64(byte))*1099511628211}
    return hash
}
renderer_metal_cache_identity :: proc(r:^Renderer,descriptor:^MTL.RenderPipelineDescriptor)->string {
    version:=NS.ProcessInfo_operatingSystemVersion(NS.ProcessInfo_processInfo())
    attachment:=MTL.RenderPipelineColorAttachmentDescriptorArray_object(
        MTL.RenderPipelineDescriptor_colorAttachments(descriptor),0)
    state:=fmt.tprintf("%s/%d/%d.%d.%d/%d/%v/%d/%d/%d/%d/%d/%d/%d/%d/%d/%d",
        RENDERER_METAL_CACHE_VERSION,MTL.Device_registryID(r.device),
        version.majorVersion,version.minorVersion,version.patchVersion,
        MTL.RenderPipelineColorAttachmentDescriptor_pixelFormat(attachment),
        MTL.RenderPipelineColorAttachmentDescriptor_isBlendingEnabled(attachment),
        MTL.RenderPipelineColorAttachmentDescriptor_sourceRGBBlendFactor(attachment),
        MTL.RenderPipelineColorAttachmentDescriptor_destinationRGBBlendFactor(attachment),
        MTL.RenderPipelineColorAttachmentDescriptor_rgbBlendOperation(attachment),
        MTL.RenderPipelineColorAttachmentDescriptor_sourceAlphaBlendFactor(attachment),
        MTL.RenderPipelineColorAttachmentDescriptor_destinationAlphaBlendFactor(attachment),
        MTL.RenderPipelineColorAttachmentDescriptor_alphaBlendOperation(attachment),
        MTL.RenderPipelineColorAttachmentDescriptor_writeMask(attachment),
        MTL.RenderPipelineDescriptor_rasterSampleCount(descriptor),
        MTL.RenderPipelineDescriptor_depthAttachmentPixelFormat(descriptor),
        MTL.RenderPipelineDescriptor_stencilAttachmentPixelFormat(descriptor))
    return fmt.tprintf("%016x-%016x",renderer_metal_cache_hash(#load("shaders/ui.metal")),renderer_metal_cache_hash(state))
}
renderer_metal_cache_url :: proc(path:string)->^NS.URL {
    value:=NS.String_initWithOdinString(NS.String_alloc(),path)
    if value==nil {return nil}
    defer NS.release(value)
    return NS.URL_initFileURLWithPath(NS.URL_alloc(),value)
}
renderer_metal_cache_matches :: proc(path,identity:string)->bool {
    metadata,error:=os.open(fmt.tprintf("%s.key",path))
    if error!=nil {return false}
    defer os.close(metadata)
    size,size_error:=os.file_size(metadata)
    if size_error!=nil||size!=i64(len(identity)) {return false}
    bytes:[33]u8
    count,read_error:=os.read(metadata,bytes[:])
    if read_error!=nil||count!=len(identity)||string(bytes[:count])!=identity {return false}
    archive,archive_error:=os.open(path)
    if archive_error!=nil {return false}
    defer os.close(archive)
    size,size_error=os.file_size(archive)
    return size_error==nil&&size>0&&size<=RENDERER_METAL_CACHE_MAX_BYTES
}
renderer_metal_cache_save :: proc(archive:^MTL.BinaryArchive,path,identity:string) {
    slash:=strings.last_index(path,"/")
    if slash<0 {return}
    directory:=path[:slash]
    if os.mkdir_all(directory,{.Read_User,.Write_User,.Execute_User})!=nil||!platform_private_path(directory,true) {return}
    temporary,error:=os.create_temp_file(directory,"ui-metal-*")
    if error!=nil {return}
    temporary_path:=strings.clone(os.name(temporary),context.temp_allocator)
    os.close(temporary)
    defer os.remove(temporary_path)
    url:=renderer_metal_cache_url(temporary_path)
    if url==nil {return}
    defer NS.release(url)
    saved,_:=MTL.BinaryArchive_serializeToURL(archive,url)
    if !saved {return}
    information,stat_error:=os.stat(temporary_path,context.temp_allocator)
    if stat_error!=nil||information.size<=0||information.size>RENDERER_METAL_CACHE_MAX_BYTES||
        !platform_private_path(temporary_path,false)||!platform_atomic_replace(temporary_path,path) {return}
    key_file,key_error:=os.create_temp_file(directory,"ui-metal-key-*")
    if key_error!=nil {return}
    key_path:=strings.clone(os.name(key_file),context.temp_allocator)
    count,write_error:=os.write(key_file,transmute([]u8)identity)
    os.close(key_file)
    defer os.remove(key_path)
    if write_error!=nil||count!=len(identity)||!platform_private_path(key_path,false) {return}
    _=platform_atomic_replace(key_path,fmt.tprintf("%s.key",path))
}

// One replaceable native archive prevents shader or OS upgrades accumulating
// unbounded cache files. Any cache failure takes the normal Metal compiler path.
renderer_metal_pipeline :: proc(r:^Renderer,descriptor:^MTL.RenderPipelineDescriptor)->bool {
    path,identity:string
    directory,directory_error:=os.user_cache_dir(context.temp_allocator)
    if directory_error==nil {
        path=fmt.tprintf("%s/task_master/pipelines/ui-metal.metalar",directory)
        identity=renderer_metal_cache_identity(r,descriptor)
    }
    archive:^MTL.BinaryArchive
    archive_descriptor:=MTL.BinaryArchiveDescriptor_init(MTL.BinaryArchiveDescriptor_alloc())
    if archive_descriptor!=nil {
        defer NS.release(archive_descriptor)
        if path!=""&&renderer_metal_cache_matches(path,identity) {
            url:=renderer_metal_cache_url(path)
            if url!=nil {
                MTL.BinaryArchiveDescriptor_setUrl(archive_descriptor,url)
                archive,_=MTL.Device_newBinaryArchive(r.device,archive_descriptor)
                NS.release(url)
            }
        }
        if archive==nil {
            MTL.BinaryArchiveDescriptor_setUrl(archive_descriptor,nil)
            archive,_=MTL.Device_newBinaryArchive(r.device,archive_descriptor)
        }
    }
    if archive!=nil {
        defer NS.release(archive)
        objects:=[1]^NS.Object{cast(^NS.Object)archive}
        archives:=NS.Array_initWithObjects(NS.Array_alloc(),raw_data(objects[:]),1)
        if archives!=nil {
            defer NS.release(archives)
            MTL.RenderPipelineDescriptor_setBinaryArchives(descriptor,archives)
            reflection:MTL.AutoreleasedRenderPipelineReflection
            r.pipeline,_=MTL.Device_newRenderPipelineStateWithDescriptorWithReflection(r.device,descriptor,{.FailOnBinaryArchiveMiss},&reflection)
            MTL.RenderPipelineDescriptor_setBinaryArchives(descriptor,nil)
            if r.pipeline!=nil {return true}
            // Populate before creating the state, so Metal can reuse this work.
            added,_:=MTL.BinaryArchive_addRenderPipelineFunctions(archive,descriptor)
            if added {
                MTL.RenderPipelineDescriptor_setBinaryArchives(descriptor,archives)
                r.pipeline,_=MTL.Device_newRenderPipelineStateWithDescriptor(r.device,descriptor)
                MTL.RenderPipelineDescriptor_setBinaryArchives(descriptor,nil)
                if r.pipeline!=nil {
                    if path!="" {renderer_metal_cache_save(archive,path,identity)}
                    return true
                }
            }
        }
    }
    error:^NS.Error
    r.pipeline,error=MTL.Device_newRenderPipelineStateWithDescriptor(r.device,descriptor)
    if r.pipeline==nil {
        if error!=nil {fmt.printf("Metal pipeline: %s\n",NS.String_UTF8String(NS.Error_localizedDescription(error)))}
        else {fmt.println("Could not create the Metal UI pipeline.")}
        return false
    }
    return true
}

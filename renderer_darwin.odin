#+build darwin
package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"
import "core:thread"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"
import window "desktop_window"

@(require)
foreign import "system:QuartzCore.framework"

// Each frame owns CPU-writable shared storage until its GPU command completes.
// This allows the CPU and Metal queue to overlap without rewriting live vertices.
Metal_Frame :: struct {
    vertices: ^MTL.Buffer,
    command: ^MTL.CommandBuffer,
    capacity, small_frames: int,
}
Renderer :: struct {
    window: window.WindowHandle,
    width, height: int,
    device_name: string,
    capture_path: string,
    capture_supported, capture_success: bool,
    device: ^MTL.Device,
    queue: ^MTL.CommandQueue,
    layer: ^CA.MetalLayer,
    pipeline: ^MTL.RenderPipelineState,
    font_texture: ^MTL.Texture,
    fonts: [len(FONT_SIZES)]Font_Size,
    font_scale: f32,
    atlas_height: int,
    frames: [3]Metal_Frame,
    frame_index: int,
    drawable: ^CA.MetalDrawable,
    frame_pool: ^NS.AutoreleasePool,
}
#assert(size_of(Vertex)==48)

renderer_backend_name :: proc()->string {return "Metal"}
renderer_metal_error :: proc(error:^NS.Error,action:string) {
    if error!=nil {fmt.eprintf("Metal %s: %s\n",action,error->localizedDescription()->odinString())}
    else {fmt.eprintf("Metal %s failed\n",action)}
}
renderer_metal_wait :: proc(command:^MTL.CommandBuffer)->bool {
    if command==nil {return true}
    command->waitUntilCompleted()
    if command->status()==.Error {renderer_metal_error(command->error(),"command");return false}
    return true
}
renderer_metal_idle :: proc(r:^Renderer)->bool {
    ok:=true
    for &frame in r.frames {
        if frame.command!=nil {
            ok=renderer_metal_wait(frame.command)&&ok
            frame.command->release();frame.command=nil
        }
    }
    return ok
}
renderer_font_upload :: proc(r:^Renderer,atlas:^Font_Atlas)->bool {
    description:=MTL.TextureDescriptor.alloc()->init()
    defer description->release()
    description->setTextureType(.Type2D)
    description->setPixelFormat(.R8Unorm)
    description->setWidth(ATLAS_SIZE)
    description->setHeight(NS.UInteger(atlas.height))
    description->setStorageMode(.Private)
    description->setUsage({.ShaderRead})
    texture:=r.device->newTexture(description)
    if texture==nil {renderer_metal_error(nil,"font texture");return false}
    uploaded:=false
    defer {if !uploaded {texture->release()}}
    pixels:=atlas.pixels[:ATLAS_SIZE*atlas.height]
    staging:=r.device->newBufferWithBytes(pixels,{})
    if staging==nil {renderer_metal_error(nil,"font staging buffer");return false}
    defer staging->release()
    command:=r.queue->commandBuffer()
    if command==nil {return false}
    encoder:=command->blitCommandEncoder()
    if encoder==nil {return false}
    encoder->copyFromBufferEx(staging,0,ATLAS_SIZE,NS.UInteger(len(pixels)),
        {ATLAS_SIZE,NS.Integer(atlas.height),1},texture,0,0,{})
    encoder->endEncoding()
    command->commit()
    if !renderer_metal_wait(command) {return false}
    if r.font_texture!=nil {r.font_texture->release()}
    r.font_texture=texture
    r.fonts=atlas.fonts;r.font_scale=atlas.scale;r.atlas_height=atlas.height
    uploaded=true
    return true
}
renderer_set_scale :: proc(r:^Renderer,scale:f32)->bool {
    target:=clamp(scale,0.5,4.0)
    if abs(r.font_scale-target)<0.001 {return true}
    pool:=NS.AutoreleasePool.alloc()->init()
    defer pool->drain()
    // A DPI change is infrequent; finish frames before replacing their texture.
    if !renderer_metal_idle(r) {return false}
    atlas:=Font_Atlas{scale=target}
    defer delete(atlas.pixels)
    return renderer_font_rasterize(&atlas)&&renderer_font_upload(r,&atlas)
}
renderer_init :: proc(r:^Renderer,width,height:int,title:cstring)->bool {
    stage:=time.tick_now()
    pool:=NS.AutoreleasePool.alloc()->init()
    defer pool->drain()
    initialized:=false
    defer {if !initialized {renderer_destroy(r)}}
    if !window.Init() {return false}
    window.WindowHint(window.VISIBLE,false)
    r.window=window.CreateWindow(i32(width),i32(height),title,nil,nil)
    if r.window==nil {return false}
    sx,sy:=window.GetWindowContentScale(r.window)
    atlas:=Font_Atlas{scale=clamp(max(sx,sy),0.5,4.0)}
    worker:=thread.create(startup_font_worker)
    if worker!=nil {worker.data=&atlas;thread.start(worker)}
    else {atlas.ready=renderer_font_rasterize(&atlas)}
    defer {
        if worker!=nil {thread.destroy(worker)}
        delete(atlas.pixels)
    }
    stage=startup_stage(stage,"AppKit / window")
    r.device=MTL.CreateSystemDefaultDevice()
    if r.device==nil {renderer_metal_error(nil,"GPU discovery");return false}
    r.device_name=strings.clone(r.device->name()->odinString())
    r.queue=r.device->newCommandQueue()
    if r.queue==nil {renderer_metal_error(nil,"command queue");return false}
    r.layer=CA.MetalLayer.layer()
    if r.layer==nil {renderer_metal_error(nil,"drawable layer");return false}
    r.layer->retain()
    r.layer->setDevice(r.device)
    r.layer->setPixelFormat(.BGRA8Unorm)
    r.layer->setFramebufferOnly(false) // Native GPU readback retains screenshots.
    r.layer->setDisplaySyncEnabled(true)
    r.layer->setMaximumDrawableCount(3)
    r.layer->setOpaque(true)
    view:=cast(^NS.View)window.GetNativeView(r.window)
    if view==nil {return false}
    view->setWantsLayer(true)
    view->setLayer(cast(^NS.Layer)r.layer)
    if !renderer_prepare_frame(r) {return false}
    stage=startup_stage(stage,"Metal device / layer")
    source:=NS.String.alloc()->initWithOdinString(#load("shaders/ui.metal"))
    defer source->release()
    library,error:=r.device->newLibraryWithSource(source,nil)
    if library==nil {renderer_metal_error(error,"shader library");return false}
    defer library->release()
    vertex_name:=NS.String.alloc()->initWithOdinString("ui_vertex")
    fragment_name:=NS.String.alloc()->initWithOdinString("ui_fragment")
    defer vertex_name->release()
    defer fragment_name->release()
    vertex:=library->newFunctionWithName(vertex_name)
    fragment:=library->newFunctionWithName(fragment_name)
    if vertex==nil||fragment==nil {vertex->release();fragment->release();return false}
    defer vertex->release()
    defer fragment->release()
    descriptor:=MTL.RenderPipelineDescriptor.alloc()->init()
    defer descriptor->release()
    descriptor->setVertexFunction(vertex)
    descriptor->setFragmentFunction(fragment)
    attachment:=descriptor->colorAttachments()->object(0)
    attachment->setPixelFormat(.BGRA8Unorm)
    attachment->setBlendingEnabled(true)
    attachment->setSourceRGBBlendFactor(.SourceAlpha)
    attachment->setDestinationRGBBlendFactor(.OneMinusSourceAlpha)
    attachment->setSourceAlphaBlendFactor(.One)
    attachment->setDestinationAlphaBlendFactor(.OneMinusSourceAlpha)
    if !renderer_metal_pipeline(r,descriptor) {return false}
    stage=startup_stage(stage,"Metal shaders / pipeline")
    if worker!=nil {thread.join(worker)}
    if !atlas.ready||!renderer_font_upload(r,&atlas) {return false}
    stage=startup_stage(stage,"CoreText join / upload")
    r.capture_supported=true
    initialized=true
    return true
}
renderer_prepare_frame :: proc(r:^Renderer)->bool {
    w,h:=window.GetFramebufferSize(r.window)
    r.width=int(w);r.height=int(h)
    if w<=0||h<=0 {return true}
    view:=cast(^NS.View)window.GetNativeView(r.window)
    r.layer->setFrame(view->bounds())
    sx,sy:=window.GetWindowContentScale(r.window)
    NS.Layer_setContentsScale(cast(^NS.Layer)r.layer,NS.Float(max(sx,sy)))
    r.layer->setDrawableSize({NS.Float(w),NS.Float(h)})
    return true
}
renderer_release_frame :: proc(r:^Renderer) {
    r.drawable=nil
    if r.frame_pool!=nil {r.frame_pool->drain();r.frame_pool=nil}
}
renderer_acquire_frame :: proc(r:^Renderer)->(index:u32,ready,ok:bool) {
    renderer_release_frame(r)
    if r.width<=0||r.height<=0 {return 0,false,true}
    frame:=&r.frames[r.frame_index]
    if !renderer_metal_wait(frame.command) {return 0,false,false}
    if frame.command!=nil {frame.command->release();frame.command=nil}
    r.frame_pool=NS.AutoreleasePool.alloc()->init()
    r.drawable=r.layer->nextDrawable()
    if r.drawable==nil {renderer_release_frame(r);return 0,false,true}
    return u32(r.frame_index),true,true
}
renderer_reserve_vertices :: proc(r:^Renderer,frame:^Metal_Frame,size:int)->bool {
    capacity:=VERTEX_INITIAL_CAPACITY
    if frame.vertices!=nil&&size<=frame.capacity {
        if frame.capacity<=VERTEX_INITIAL_CAPACITY||size>frame.capacity/4 {frame.small_frames=0;return true}
        frame.small_frames+=1
        if frame.small_frames<120 {return true}
    } else {capacity=max(capacity,frame.capacity)}
    frame.small_frames=0
    for capacity<size {capacity*=2}
    buffer:=r.device->newBufferWithLength(NS.UInteger(capacity),{.CPUCacheModeWriteCombined})
    if buffer==nil {return capacity<frame.capacity}
    if frame.vertices!=nil {frame.vertices->release()}
    frame.vertices=buffer;frame.capacity=capacity
    return true
}
renderer_draw :: proc(r:^Renderer,vertices:[]Vertex,image_index:u32)->bool {
    defer renderer_release_frame(r)
    if r.drawable==nil||int(image_index)!=r.frame_index {return false}
    frame:=&r.frames[r.frame_index]
    if !renderer_reserve_vertices(r,frame,len(vertices)*size_of(Vertex)) {return false}
    mem.copy(frame.vertices->contentsPointer(),raw_data(vertices),len(vertices)*size_of(Vertex))
    command:=r.queue->commandBuffer()
    if command==nil {return false}
    pass:=MTL.RenderPassDescriptor.alloc()->init()
    defer pass->release()
    attachment:=pass->colorAttachments()->object(0)
    attachment->setTexture(r.drawable->texture())
    attachment->setLoadAction(.Clear)
    attachment->setStoreAction(.Store)
    attachment->setClearColor({0.055,0.064,0.082,1})
    encoder:=command->renderCommandEncoderWithDescriptor(pass)
    if encoder==nil {return false}
    encoder->setRenderPipelineState(r.pipeline)
    encoder->setViewport({0,0,f64(r.width),f64(r.height),0,1})
    encoder->setScissorRect({0,0,NS.Integer(r.width),NS.Integer(r.height)})
    encoder->setVertexBuffer(frame.vertices,0,0)
    extent:=[2]f32{f32(r.width),f32(r.height)}
    encoder->setVertexBytes((cast([^]u8)&extent)[:size_of(extent)],1)
    encoder->setFragmentTexture(r.font_texture,0)
    encoder->drawPrimitives(.Triangle,0,NS.UInteger(len(vertices)))
    encoder->endEncoding()
    // Metal requires aligned readback rows; ImageIO consumes that same stride.
    capture:^MTL.Buffer
    row_bytes:=(r.width*4+255)&~255
    if r.capture_path!="" {
        capture=r.device->newBufferWithLength(NS.UInteger(row_bytes*r.height),{})
        if capture==nil {renderer_metal_error(nil,"screenshot buffer");return false}
        blit:=command->blitCommandEncoder()
        if blit==nil {capture->release();return false}
        blit->copyFromTextureEx(r.drawable->texture(),0,0,{},
            {NS.Integer(r.width),NS.Integer(r.height),1},capture,0,NS.UInteger(row_bytes),NS.UInteger(row_bytes*r.height))
        blit->endEncoding()
    }
    defer {if capture!=nil {capture->release()}}
    command->presentDrawable(cast(^MTL.Drawable)r.drawable)
    command->retain()
    frame.command=command
    command->commit()
    if capture!=nil {
        if !renderer_metal_wait(command) {return false}
        r.capture_success=renderer_capture_png(r.capture_path,capture->contents(),r.width,r.height,row_bytes)
        r.capture_path=""
    }
    r.frame_index=(r.frame_index+1)%len(r.frames)
    return true
}
renderer_destroy :: proc(r:^Renderer) {
    renderer_metal_idle(r)
    renderer_release_frame(r)
    for &frame in r.frames {if frame.vertices!=nil {frame.vertices->release()}}
    if r.font_texture!=nil {r.font_texture->release()}
    if r.pipeline!=nil {r.pipeline->release()}
    if r.window!=nil {
        view:=cast(^NS.View)window.GetNativeView(r.window)
        view->setLayer(nil)
    }
    if r.layer!=nil {r.layer->release()}
    if r.queue!=nil {r.queue->release()}
    if r.device!=nil {r.device->release()}
    if r.window!=nil {window.DestroyWindow(r.window)}
    if r.device_name!="" {delete(r.device_name)}
    window.Terminate()
    r^={}
}

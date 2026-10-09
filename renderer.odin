package main

import vk "vendor:vulkan"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import "core:c"
import "core:mem"
import "core:fmt"
import "core:strings"
import "core:math"
import "core:time"
import "core:thread"
import "core:dynlib"

// FreeType's public C structure prefixes. Only fields through the rendered
// bitmap are needed; the library owns the complete structures and their tails.
FT_Generic :: struct { data, finalizer: rawptr }
FT_Bitmap :: struct {
    rows, width: c.uint,
    pitch: c.int,
    buffer: [^]u8,
    num_grays: c.ushort,
    pixel_mode, palette_mode: u8,
    palette: rawptr,
}
FT_Glyph_Slot :: struct {
    library, face, next: rawptr,
    glyph_index: c.uint,
    generic: FT_Generic,
    metrics: [8]c.long,
    linear_hori_advance, linear_vert_advance: c.long,
    advance: [2]c.long,
    format: c.uint,
    bitmap: FT_Bitmap,
    bitmap_left, bitmap_top: c.int,
}
FT_Face :: struct {
    num_faces, face_index, face_flags, style_flags, num_glyphs: c.long,
    family_name, style_name: cstring,
    num_fixed_sizes: c.int,
    available_sizes: rawptr,
    num_charmaps: c.int,
    charmaps: rawptr,
    generic: FT_Generic,
    bbox: [4]c.long,
    units_per_em: c.ushort,
    ascender, descender, height, max_advance_width, max_advance_height,
        underline_position, underline_thickness: c.short,
    glyph: ^FT_Glyph_Slot,
}
when ODIN_OS == .Windows {
    FREETYPE_LIBRARY :: #config(FREETYPE_LIBRARY,"system:freetype.lib")
    foreign import freetype {FREETYPE_LIBRARY}
} else {
    FREETYPE_LIBRARY :: #config(FREETYPE_LIBRARY,"system:freetype")
    foreign import freetype {FREETYPE_LIBRARY}
}
foreign freetype {
    FT_Init_FreeType :: proc(library: ^rawptr) -> c.int ---
    FT_Done_FreeType :: proc(library: rawptr) -> c.int ---
    FT_New_Memory_Face :: proc(library: rawptr, data: [^]u8, length, index: c.long, face: ^^FT_Face) -> c.int ---
    FT_Done_Face :: proc(face: ^FT_Face) -> c.int ---
    FT_Set_Pixel_Sizes :: proc(face: ^FT_Face, width, height: c.uint) -> c.int ---
    FT_Load_Char :: proc(face: ^FT_Face, codepoint: c.ulong, flags: c.int) -> c.int ---
}
Font_Glyph :: struct {
    x, y, width, height: int,
    left, top: int,
    advance: f32,
}
Font_Size :: struct {
    pixels: f32,
    glyphs: [95]Font_Glyph,
}
FONT_SIZES :: [13]f32{12,13,14,15,16,17,18,20,23,24,30,32,36}

// CPU-owned raster data is prepared while the main thread creates the GPU device.
Font_Atlas :: struct {
    pixels: [dynamic]u8,
    fonts: [len(FONT_SIZES)]Font_Size,
    height: int,
    scale: f32,
    ready: bool,
}

Vertex :: struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]f32,
    // Positive width selects an antialiased stroke; UV is along/across it.
    // Negative width selects a graph fill: -1 for height-based utilisation
    // colour, -2 for a fixed hue. UV carries colour level and full-graph height.
    stroke: [2]f32,
    // Physical horizontal bounds for sliding graph traces; zero disables it.
    clip_x: [2]f32,
}
Renderer :: struct {
    window: glfw.WindowHandle,
    vulkan_library: dynlib.Library,
    width, height: int,
    device_name: string,
    capture_path: string,
    capture_supported, capture_success: bool,
    instance: vk.Instance,
    physical: vk.PhysicalDevice,
    device: vk.Device,
    surface: vk.SurfaceKHR,
    queue: vk.Queue,
    family: u32,
    swapchain: vk.SwapchainKHR,
    format: vk.Format,
    images: []vk.Image,
    views: []vk.ImageView,
    framebuffers: []vk.Framebuffer,
    present_semaphores: []vk.Semaphore,
    render_pass: vk.RenderPass,
    pipeline: vk.Pipeline,
    layout: vk.PipelineLayout,
    pool: vk.CommandPool,
    command: vk.CommandBuffer,
    fence: vk.Fence,
    acquired: vk.Semaphore,
    vertex_buffer: vk.Buffer,
    vertex_memory: vk.DeviceMemory,
    vertex_mapping: rawptr,
    vertex_capacity: int,
    vertex_small_frames: int,
    font_image: vk.Image,
    font_memory: vk.DeviceMemory,
    font_view: vk.ImageView,
    sampler: vk.Sampler,
    descriptor_layout: vk.DescriptorSetLayout,
    descriptor_pool: vk.DescriptorPool,
    descriptor: vk.DescriptorSet,
    fonts: [len(FONT_SIZES)]Font_Size,
    font_scale: f32,
    atlas_height: int,
    pipeline_binaries: bool,
}
VERTEX_INITIAL_CAPACITY :: 256*1024
ATLAS_SIZE :: 1024

renderer_ok :: proc(result: vk.Result, action: string) -> bool {
    if result != .SUCCESS { fmt.eprintf("Vulkan %s: %v\n", action, result); return false }
    return true
}
renderer_memory_type :: proc(r: ^Renderer, bits: u32, flags: vk.MemoryPropertyFlags) -> (u32, bool) {
    props: vk.PhysicalDeviceMemoryProperties
    vk.GetPhysicalDeviceMemoryProperties(r.physical, &props)
    for i in 0..<props.memoryTypeCount {
        if bits & (1 << i) != 0 && flags <= props.memoryTypes[i].propertyFlags { return i, true }
    }
    return 0, false
}
renderer_buffer :: proc(r: ^Renderer, size: int, usage: vk.BufferUsageFlags, buffer: ^vk.Buffer, memory: ^vk.DeviceMemory) -> bool {
    info := vk.BufferCreateInfo{sType=.BUFFER_CREATE_INFO, size=vk.DeviceSize(size), usage=usage, sharingMode=.EXCLUSIVE}
    if !renderer_ok(vk.CreateBuffer(r.device,&info,nil,buffer), "create buffer") { return false }
    req: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(r.device,buffer^,&req)
    idx, ok := renderer_memory_type(r,req.memoryTypeBits,{.HOST_VISIBLE,.HOST_COHERENT})
    if !ok { return false }
    alloc := vk.MemoryAllocateInfo{sType=.MEMORY_ALLOCATE_INFO,allocationSize=req.size,memoryTypeIndex=idx}
    if !renderer_ok(vk.AllocateMemory(r.device,&alloc,nil,memory), "buffer memory") { return false }
    return renderer_ok(vk.BindBufferMemory(r.device,buffer^,memory^,0), "bind buffer")
}
// The caller waits for the previous frame before replacing its vertex storage.
// Allocate for actual geometry, grow geometrically for dense histories, and
// release a large view's spare storage once a smaller view has settled.
renderer_reserve_vertices :: proc(r: ^Renderer, size: int) -> bool {
    capacity := VERTEX_INITIAL_CAPACITY
    if r.vertex_buffer!=0 && size<=r.vertex_capacity {
        if r.vertex_capacity<=VERTEX_INITIAL_CAPACITY || size>r.vertex_capacity/4 {
            r.vertex_small_frames=0
            return true
        }
        r.vertex_small_frames+=1
        if r.vertex_small_frames<120 { return true }
    } else {
        capacity=max(capacity,r.vertex_capacity)
    }
    r.vertex_small_frames=0
    for capacity<size { capacity*=2 }
    shrinking := capacity<r.vertex_capacity
    buffer: vk.Buffer
    memory: vk.DeviceMemory
    mapping: rawptr
    defer {
        if mapping!=nil { vk.UnmapMemory(r.device,memory) }
        if buffer!=0 { vk.DestroyBuffer(r.device,buffer,nil) }
        if memory!=0 { vk.FreeMemory(r.device,memory,nil) }
    }
    // An optional trim must never interrupt rendering if allocation fails.
    if !renderer_buffer(r,capacity,{.VERTEX_BUFFER},&buffer,&memory) { return shrinking }
    if !renderer_ok(vk.MapMemory(r.device,memory,0,vk.DeviceSize(capacity),{},&mapping), "map vertices") { return shrinking }
    if r.vertex_mapping!=nil { vk.UnmapMemory(r.device,r.vertex_memory) }
    if r.vertex_buffer!=0 { vk.DestroyBuffer(r.device,r.vertex_buffer,nil) }
    if r.vertex_memory!=0 { vk.FreeMemory(r.device,r.vertex_memory,nil) }
    r.vertex_buffer,r.vertex_memory,r.vertex_mapping,r.vertex_capacity=buffer,memory,mapping,capacity
    buffer=0;memory=0;mapping=nil
    return true
}
renderer_image_view :: proc(r: ^Renderer, image: vk.Image, format: vk.Format, view: ^vk.ImageView) -> bool {
    info := vk.ImageViewCreateInfo{sType=.IMAGE_VIEW_CREATE_INFO,image=image,viewType=.D2,format=format,
        subresourceRange={aspectMask={.COLOR},levelCount=1,layerCount=1}}
    return renderer_ok(vk.CreateImageView(r.device,&info,nil,view), "image view")
}
renderer_shader :: proc(r: ^Renderer, data: string) -> vk.ShaderModule {
    info := vk.ShaderModuleCreateInfo{sType=.SHADER_MODULE_CREATE_INFO,codeSize=len(data),pCode=cast([^]u32)raw_data(data)}
    shader: vk.ShaderModule
    renderer_ok(vk.CreateShaderModule(r.device,&info,nil,&shader), "shader")
    return shader
}
renderer_font_rasterize :: proc(atlas: ^Font_Atlas) -> bool {
    font :: #load("assets/DejaVuSans.ttf")
    library: rawptr
    if FT_Init_FreeType(&library) != 0 { fmt.eprintln("Cannot initialize FreeType"); return false }
    defer FT_Done_FreeType(library)
    face: ^FT_Face
    if FT_New_Memory_Face(library,raw_data(font),c.long(len(font)),0,&face) != 0 { return false }
    defer FT_Done_Face(face)
    // Rasterize all UI sizes once at native framebuffer resolution, with the
    // font's TrueType hinting. No large glyph is downsampled into small text.
    atlas.pixels = make([dynamic]u8,ATLAS_SIZE*64,ATLAS_SIZE*64)
    x, y, row_height := 3, 1, 0
    for logical_size,i in FONT_SIZES {
        pixel_size := max(1,int(math.round(logical_size*atlas.scale)))
        atlas.fonts[i].pixels=f32(pixel_size)
        if FT_Set_Pixel_Sizes(face,0,c.uint(pixel_size)) != 0 { return false }
        for codepoint in 32..<127 {
            // FT_LOAD_RENDER | FT_LOAD_NO_BITMAP: grayscale hinted outlines.
            if FT_Load_Char(face,c.ulong(codepoint),(1<<2)|(1<<3)) != 0 { return false }
            slot := face.glyph
            bitmap := slot.bitmap
            w, h := int(bitmap.width),int(bitmap.rows)
            if x+w+1 >= ATLAS_SIZE { x=1; y+=row_height+2; row_height=0 }
            if y+h+1 >= 4096 { fmt.eprintln("Font atlas exceeds capacity"); return false }
            needed := (y+h+2)*ATLAS_SIZE
            if needed>len(atlas.pixels) {
                size:=len(atlas.pixels)
                for size<needed {size*=2}
                if resize(&atlas.pixels,size)!=nil {return false}
            }
            if w > 0 && h > 0 {
                if bitmap.pixel_mode != 2 { fmt.eprintln("Expected grayscale font bitmap"); return false }
                for row in 0..<h {
                    source_row := row
                    if bitmap.pitch < 0 { source_row=h-1-row }
                    source := &bitmap.buffer[source_row*abs(int(bitmap.pitch))]
                    mem.copy(&atlas.pixels[(y+row)*ATLAS_SIZE+x],source,w)
                }
            }
            atlas.fonts[i].glyphs[codepoint-32]={x=x,y=y,width=w,height=h,
                left=int(slot.bitmap_left),top=int(slot.bitmap_top),advance=f32(slot.advance[0])/64}
            x+=w+2; row_height=max(row_height,h)
        }
    }
    // Vulkan supports non-power-of-two textures; unused rows need no GPU copy.
    atlas.height=max(64,y+row_height+2)
    pixels := atlas.pixels[:ATLAS_SIZE*atlas.height]
    // Reserve a white texel for solid geometry; glyph padding leaves this corner free.
    pixels[0]=255; pixels[1]=255; pixels[ATLAS_SIZE]=255; pixels[ATLAS_SIZE+1]=255
    return true
}
renderer_font_upload :: proc(r: ^Renderer, atlas: ^Font_Atlas) -> bool {
    pixels := atlas.pixels[:ATLAS_SIZE*atlas.height]
    r.fonts=atlas.fonts
    r.atlas_height=atlas.height
    image_info := vk.ImageCreateInfo{sType=.IMAGE_CREATE_INFO,imageType=.D2,format=.R8_UNORM,
        extent={ATLAS_SIZE,u32(r.atlas_height),1},mipLevels=1,arrayLayers=1,samples={._1},tiling=.OPTIMAL,
        usage={.TRANSFER_DST,.SAMPLED},sharingMode=.EXCLUSIVE,initialLayout=.UNDEFINED}
    if !renderer_ok(vk.CreateImage(r.device,&image_info,nil,&r.font_image), "font image") { return false }
    req: vk.MemoryRequirements
    vk.GetImageMemoryRequirements(r.device,r.font_image,&req)
    idx, ok := renderer_memory_type(r,req.memoryTypeBits,{.DEVICE_LOCAL})
    if !ok { return false }
    alloc := vk.MemoryAllocateInfo{sType=.MEMORY_ALLOCATE_INFO,allocationSize=req.size,memoryTypeIndex=idx}
    if !renderer_ok(vk.AllocateMemory(r.device,&alloc,nil,&r.font_memory), "font memory") { return false }
    if !renderer_ok(vk.BindImageMemory(r.device,r.font_image,r.font_memory,0), "bind font") { return false }
    staging: vk.Buffer; memory: vk.DeviceMemory
    if !renderer_buffer(r,len(pixels),{.TRANSFER_SRC},&staging,&memory) { return false }
    defer vk.FreeMemory(r.device,memory,nil)
    defer vk.DestroyBuffer(r.device,staging,nil)
    mapped: rawptr
    vk.MapMemory(r.device,memory,0,vk.DeviceSize(len(pixels)),{},&mapped)
    mem.copy(mapped,raw_data(pixels),len(pixels)); vk.UnmapMemory(r.device,memory)
    begin := vk.CommandBufferBeginInfo{sType=.COMMAND_BUFFER_BEGIN_INFO,flags={.ONE_TIME_SUBMIT}}
    vk.BeginCommandBuffer(r.command,&begin)
    barrier := vk.ImageMemoryBarrier{sType=.IMAGE_MEMORY_BARRIER,oldLayout=.UNDEFINED,newLayout=.TRANSFER_DST_OPTIMAL,
        srcQueueFamilyIndex=vk.QUEUE_FAMILY_IGNORED,dstQueueFamilyIndex=vk.QUEUE_FAMILY_IGNORED,
        image=r.font_image,subresourceRange={aspectMask={.COLOR},levelCount=1,layerCount=1},dstAccessMask={.TRANSFER_WRITE}}
    vk.CmdPipelineBarrier(r.command,{.TOP_OF_PIPE},{.TRANSFER},{},0,nil,0,nil,1,&barrier)
    region := vk.BufferImageCopy{imageSubresource={aspectMask={.COLOR},layerCount=1},imageExtent={ATLAS_SIZE,u32(r.atlas_height),1}}
    vk.CmdCopyBufferToImage(r.command,staging,r.font_image,.TRANSFER_DST_OPTIMAL,1,&region)
    barrier.oldLayout=.TRANSFER_DST_OPTIMAL; barrier.newLayout=.SHADER_READ_ONLY_OPTIMAL
    barrier.srcAccessMask={.TRANSFER_WRITE}; barrier.dstAccessMask={.SHADER_READ}
    vk.CmdPipelineBarrier(r.command,{.TRANSFER},{.FRAGMENT_SHADER},{},0,nil,0,nil,1,&barrier)
    vk.EndCommandBuffer(r.command)
    submit := vk.SubmitInfo{sType=.SUBMIT_INFO,commandBufferCount=1,pCommandBuffers=&r.command}
    vk.QueueSubmit(r.queue,1,&submit,0); vk.QueueWaitIdle(r.queue)
    vk.ResetCommandBuffer(r.command,{})
    if !renderer_image_view(r,r.font_image,.R8_UNORM,&r.font_view) { return false }
    if r.sampler == 0 {
        sampler := vk.SamplerCreateInfo{sType=.SAMPLER_CREATE_INFO,magFilter=.NEAREST,minFilter=.NEAREST,
            mipmapMode=.NEAREST,addressModeU=.CLAMP_TO_EDGE,addressModeV=.CLAMP_TO_EDGE,addressModeW=.CLAMP_TO_EDGE,maxLod=0}
        if !renderer_ok(vk.CreateSampler(r.device,&sampler,nil,&r.sampler), "font sampler") { return false }
        binding := vk.DescriptorSetLayoutBinding{binding=0,descriptorType=.COMBINED_IMAGE_SAMPLER,descriptorCount=1,stageFlags={.FRAGMENT}}
        layout := vk.DescriptorSetLayoutCreateInfo{sType=.DESCRIPTOR_SET_LAYOUT_CREATE_INFO,bindingCount=1,pBindings=&binding}
        if !renderer_ok(vk.CreateDescriptorSetLayout(r.device,&layout,nil,&r.descriptor_layout), "descriptor layout") { return false }
        pool_size := vk.DescriptorPoolSize{type=.COMBINED_IMAGE_SAMPLER,descriptorCount=1}
        pool := vk.DescriptorPoolCreateInfo{sType=.DESCRIPTOR_POOL_CREATE_INFO,maxSets=1,poolSizeCount=1,pPoolSizes=&pool_size}
        if !renderer_ok(vk.CreateDescriptorPool(r.device,&pool,nil,&r.descriptor_pool), "descriptor pool") { return false }
        set := vk.DescriptorSetAllocateInfo{sType=.DESCRIPTOR_SET_ALLOCATE_INFO,descriptorPool=r.descriptor_pool,descriptorSetCount=1,pSetLayouts=&r.descriptor_layout}
        if !renderer_ok(vk.AllocateDescriptorSets(r.device,&set,&r.descriptor), "descriptor set") { return false }
    }
    image := vk.DescriptorImageInfo{sampler=r.sampler,imageView=r.font_view,imageLayout=.SHADER_READ_ONLY_OPTIMAL}
    write := vk.WriteDescriptorSet{sType=.WRITE_DESCRIPTOR_SET,dstSet=r.descriptor,descriptorCount=1,descriptorType=.COMBINED_IMAGE_SAMPLER,pImageInfo=&image}
    vk.UpdateDescriptorSets(r.device,1,&write,0,nil)
    r.font_scale=atlas.scale
    return true
}
renderer_font :: proc(r: ^Renderer, scale: f32) -> bool {
    atlas:=Font_Atlas{scale=scale}
    defer delete(atlas.pixels)
    return renderer_font_rasterize(&atlas)&&renderer_font_upload(r,&atlas)
}
renderer_set_scale :: proc(r: ^Renderer, scale: f32) -> bool {
    target_scale := clamp(scale,0.5,4.0)
    if abs(r.font_scale-target_scale) < 0.001 { return true }
    // This runs only when the monitor DPI changes, before generating vertices.
    if !renderer_ok(vk.DeviceWaitIdle(r.device),"wait font resize") { return false }
    if r.font_view != 0 { vk.DestroyImageView(r.device,r.font_view,nil); r.font_view=0 }
    if r.font_image != 0 { vk.DestroyImage(r.device,r.font_image,nil); r.font_image=0 }
    if r.font_memory != 0 { vk.FreeMemory(r.device,r.font_memory,nil); r.font_memory=0 }
    return renderer_font(r,target_scale)
}
renderer_pipeline :: proc(r: ^Renderer) -> bool {
    attachment := vk.AttachmentDescription{format=r.format,samples={._1},loadOp=.CLEAR,storeOp=.STORE,
        stencilLoadOp=.DONT_CARE,stencilStoreOp=.DONT_CARE,initialLayout=.UNDEFINED,finalLayout=.PRESENT_SRC_KHR}
    reference := vk.AttachmentReference{attachment=0,layout=.COLOR_ATTACHMENT_OPTIMAL}
    subpass := vk.SubpassDescription{pipelineBindPoint=.GRAPHICS,colorAttachmentCount=1,pColorAttachments=&reference}
    dependency := vk.SubpassDependency{srcSubpass=vk.SUBPASS_EXTERNAL,dstSubpass=0,
        srcStageMask={.COLOR_ATTACHMENT_OUTPUT},dstStageMask={.COLOR_ATTACHMENT_OUTPUT},dstAccessMask={.COLOR_ATTACHMENT_WRITE}}
    pass := vk.RenderPassCreateInfo{sType=.RENDER_PASS_CREATE_INFO,attachmentCount=1,pAttachments=&attachment,subpassCount=1,pSubpasses=&subpass,dependencyCount=1,pDependencies=&dependency}
    if !renderer_ok(vk.CreateRenderPass(r.device,&pass,nil,&r.render_pass), "render pass") { return false }
    push := vk.PushConstantRange{stageFlags={.VERTEX},size=8}
    layout := vk.PipelineLayoutCreateInfo{sType=.PIPELINE_LAYOUT_CREATE_INFO,setLayoutCount=1,pSetLayouts=&r.descriptor_layout,pushConstantRangeCount=1,pPushConstantRanges=&push}
    if !renderer_ok(vk.CreatePipelineLayout(r.device,&layout,nil,&r.layout), "pipeline layout") { return false }
    stages := [2]vk.PipelineShaderStageCreateInfo{
        {sType=.PIPELINE_SHADER_STAGE_CREATE_INFO,stage={.VERTEX},pName="main"},
        {sType=.PIPELINE_SHADER_STAGE_CREATE_INFO,stage={.FRAGMENT},pName="main"}}
    binding := vk.VertexInputBindingDescription{binding=0,stride=size_of(Vertex),inputRate=.VERTEX}
    attributes := [5]vk.VertexInputAttributeDescription{
        {location=0,binding=0,format=.R32G32_SFLOAT,offset=0},
        {location=1,binding=0,format=.R32G32_SFLOAT,offset=8},
        {location=2,binding=0,format=.R32G32B32A32_SFLOAT,offset=16},
        {location=3,binding=0,format=.R32G32_SFLOAT,offset=32},
        {location=4,binding=0,format=.R32G32_SFLOAT,offset=40}}
    vertex := vk.PipelineVertexInputStateCreateInfo{sType=.PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,vertexBindingDescriptionCount=1,pVertexBindingDescriptions=&binding,vertexAttributeDescriptionCount=5,pVertexAttributeDescriptions=raw_data(attributes[:])}
    assembly := vk.PipelineInputAssemblyStateCreateInfo{sType=.PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,topology=.TRIANGLE_LIST}
    viewport := vk.PipelineViewportStateCreateInfo{sType=.PIPELINE_VIEWPORT_STATE_CREATE_INFO,viewportCount=1,scissorCount=1}
    raster := vk.PipelineRasterizationStateCreateInfo{sType=.PIPELINE_RASTERIZATION_STATE_CREATE_INFO,polygonMode=.FILL,cullMode={},frontFace=.COUNTER_CLOCKWISE,lineWidth=1}
    multisample := vk.PipelineMultisampleStateCreateInfo{sType=.PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,rasterizationSamples={._1}}
    blend_attachment := vk.PipelineColorBlendAttachmentState{blendEnable=true,srcColorBlendFactor=.SRC_ALPHA,dstColorBlendFactor=.ONE_MINUS_SRC_ALPHA,colorBlendOp=.ADD,srcAlphaBlendFactor=.ONE,dstAlphaBlendFactor=.ONE_MINUS_SRC_ALPHA,alphaBlendOp=.ADD,colorWriteMask={.R,.G,.B,.A}}
    blend := vk.PipelineColorBlendStateCreateInfo{sType=.PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,attachmentCount=1,pAttachments=&blend_attachment}
    dynamics := [2]vk.DynamicState{.VIEWPORT,.SCISSOR}
    dynamic_state := vk.PipelineDynamicStateCreateInfo{sType=.PIPELINE_DYNAMIC_STATE_CREATE_INFO,dynamicStateCount=2,pDynamicStates=raw_data(dynamics[:])}
    info := vk.GraphicsPipelineCreateInfo{sType=.GRAPHICS_PIPELINE_CREATE_INFO,stageCount=2,pStages=raw_data(stages[:]),pVertexInputState=&vertex,pInputAssemblyState=&assembly,pViewportState=&viewport,pRasterizationState=&raster,pMultisampleState=&multisample,pColorBlendState=&blend,pDynamicState=&dynamic_state,layout=r.layout,renderPass=r.render_pass}
    global_key,pipeline_key:vk.PipelineBinaryKeyKHR
    cache_path:string
    capture:=vk.PipelineCreateFlags2CreateInfo{sType=.PIPELINE_CREATE_FLAGS_2_CREATE_INFO,flags={.CAPTURE_DATA_KHR}}
    if r.pipeline_binaries {
        // Inline shader code is only used to query the exact driver pipeline
        // identity. Binary replay itself has no shader modules or SPIR-V.
        vertex_code :: #load("shaders/ui.vert.spv")
        fragment_code :: #load("shaders/ui.frag.spv")
        vertex_info:=vk.ShaderModuleCreateInfo{sType=.SHADER_MODULE_CREATE_INFO,codeSize=len(vertex_code),pCode=cast([^]u32)raw_data(vertex_code)}
        fragment_info:=vk.ShaderModuleCreateInfo{sType=.SHADER_MODULE_CREATE_INFO,codeSize=len(fragment_code),pCode=cast([^]u32)raw_data(fragment_code)}
        stages[0].pNext=&vertex_info;stages[1].pNext=&fragment_info
        info.pNext=&capture
        cache_path=pipeline_binary_identity(r,&info,&global_key,&pipeline_key)
        stages[0].pNext=nil;stages[1].pNext=nil
        info.pNext=nil
        if pipeline_binary_load(r,cache_path,global_key,pipeline_key,&info) {return true}
    }
    vert:=renderer_shader(r,#load("shaders/ui.vert.spv"));frag:=renderer_shader(r,#load("shaders/ui.frag.spv"))
    defer if vert!=0 {vk.DestroyShaderModule(r.device,vert,nil)}
    defer if frag!=0 {vk.DestroyShaderModule(r.device,frag,nil)}
    if vert==0||frag==0 {return false}
    stages[0].module=vert;stages[1].module=frag
    if cache_path!="" {info.pNext=&capture}
    result:=vk.CreateGraphicsPipelines(r.device,0,1,&info,nil,&r.pipeline)
    if result!=.SUCCESS&&info.pNext!=nil {
        // Capturing is optional, even when the driver advertised support.
        if r.pipeline!=0 {vk.DestroyPipeline(r.device,r.pipeline,nil);r.pipeline=0}
        info.pNext=nil;cache_path=""
        result=vk.CreateGraphicsPipelines(r.device,0,1,&info,nil,&r.pipeline)
    }
    if !renderer_ok(result,"graphics pipeline") {return false}
    if cache_path!="" {pipeline_binary_save(r,cache_path,global_key,pipeline_key)}
    else if startup_profile {fmt.println("Pipeline binary: unavailable; compiled SPIR-V")}
    return true
}
renderer_swapchain_destroy :: proc(r: ^Renderer) {
    for framebuffer in r.framebuffers { vk.DestroyFramebuffer(r.device,framebuffer,nil) }
    for view in r.views { vk.DestroyImageView(r.device,view,nil) }
    for sem in r.present_semaphores { vk.DestroySemaphore(r.device,sem,nil) }
    delete(r.framebuffers); delete(r.views); delete(r.images); delete(r.present_semaphores)
    r.framebuffers=nil; r.views=nil; r.images=nil; r.present_semaphores=nil
    if r.swapchain != 0 { vk.DestroySwapchainKHR(r.device,r.swapchain,nil); r.swapchain=0 }
}
renderer_swapchain :: proc(r: ^Renderer) -> bool {
    vk.DeviceWaitIdle(r.device)
    renderer_swapchain_destroy(r)
    w,h := glfw.GetFramebufferSize(r.window)
    if w <= 0 || h <= 0 { r.width=0; r.height=0; return true }
    caps: vk.SurfaceCapabilitiesKHR
    if !renderer_ok(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(r.physical,r.surface,&caps), "surface capabilities") { return false }
    count: u32
    vk.GetPhysicalDeviceSurfaceFormatsKHR(r.physical,r.surface,&count,nil)
    if count == 0 { fmt.eprintln("Vulkan device has no supported window surface format"); return false }
    formats := make([]vk.SurfaceFormatKHR,int(count)); defer delete(formats)
    vk.GetPhysicalDeviceSurfaceFormatsKHR(r.physical,r.surface,&count,raw_data(formats))
    selected := formats[0]
    // UNORM keeps the deliberate UI palette identical to its authored RGB colors.
    for format in formats { if format.format == .B8G8R8A8_UNORM || format.format == .R8G8B8A8_UNORM { selected=format; break } }
    if r.render_pass == 0 { r.format=selected.format; if !renderer_pipeline(r) { return false } }
    extent := caps.currentExtent
    if extent.width == ~u32(0) { extent={clamp(u32(w),caps.minImageExtent.width,caps.maxImageExtent.width),clamp(u32(h),caps.minImageExtent.height,caps.maxImageExtent.height)} }
    r.width=int(extent.width); r.height=int(extent.height)
    image_count := caps.minImageCount+1
    if caps.maxImageCount > 0 { image_count=min(image_count,caps.maxImageCount) }
    alpha: vk.CompositeAlphaFlagKHR = .OPAQUE
    if !(.OPAQUE in caps.supportedCompositeAlpha) {
        for candidate in vk.CompositeAlphaFlagKHR { if candidate in caps.supportedCompositeAlpha { alpha=candidate; break } }
    }
    r.capture_supported=.TRANSFER_SRC in caps.supportedUsageFlags
    usage: vk.ImageUsageFlags={.COLOR_ATTACHMENT}
    if r.capture_supported { usage += {.TRANSFER_SRC} }
    // Mailbox presents the newest hover frame instead of queuing old positions.
    // FIFO remains the supported fallback on surfaces without mailbox mode.
    present_mode:=vk.PresentModeKHR.FIFO
    vk.GetPhysicalDeviceSurfacePresentModesKHR(r.physical,r.surface,&count,nil)
    modes:=make([]vk.PresentModeKHR,int(count),context.temp_allocator)
    vk.GetPhysicalDeviceSurfacePresentModesKHR(r.physical,r.surface,&count,raw_data(modes))
    for mode in modes {if mode==.MAILBOX {present_mode=.MAILBOX;break}}
    info := vk.SwapchainCreateInfoKHR{sType=.SWAPCHAIN_CREATE_INFO_KHR,surface=r.surface,minImageCount=image_count,
        imageFormat=r.format,imageColorSpace=selected.colorSpace,imageExtent=extent,imageArrayLayers=1,imageUsage=usage,
        imageSharingMode=.EXCLUSIVE,preTransform=caps.currentTransform,compositeAlpha={alpha},presentMode=present_mode,clipped=true}
    if !renderer_ok(vk.CreateSwapchainKHR(r.device,&info,nil,&r.swapchain), "swapchain") { return false }
    vk.GetSwapchainImagesKHR(r.device,r.swapchain,&count,nil)
    r.images=make([]vk.Image,int(count)); r.views=make([]vk.ImageView,int(count)); r.framebuffers=make([]vk.Framebuffer,int(count)); r.present_semaphores=make([]vk.Semaphore,int(count))
    vk.GetSwapchainImagesKHR(r.device,r.swapchain,&count,raw_data(r.images))
    sem_info := vk.SemaphoreCreateInfo{sType=.SEMAPHORE_CREATE_INFO}
    for image,i in r.images {
        if !renderer_image_view(r,image,r.format,&r.views[i]) { return false }
        framebuffer := vk.FramebufferCreateInfo{sType=.FRAMEBUFFER_CREATE_INFO,renderPass=r.render_pass,attachmentCount=1,pAttachments=&r.views[i],width=extent.width,height=extent.height,layers=1}
        if !renderer_ok(vk.CreateFramebuffer(r.device,&framebuffer,nil,&r.framebuffers[i]), "framebuffer") { return false }
        if !renderer_ok(vk.CreateSemaphore(r.device,&sem_info,nil,&r.present_semaphores[i]), "presentation semaphore") { return false }
    }
    return true
}
renderer_init :: proc(r: ^Renderer, width,height: int, title: cstring) -> bool {
    stage:=time.tick_now()
    when ODIN_OS==.Darwin {if !renderer_darwin_load(r) {return false}}
    if !glfw.Init() { fmt.eprintln("Cannot initialize GLFW"); renderer_destroy(r); return false }
    stage=startup_stage(stage,"GLFW initialization")
    if !glfw.VulkanSupported() { fmt.eprintln("Vulkan loader or graphics driver unavailable"); renderer_destroy(r); return false }
    stage=startup_stage(stage,"Vulkan loader")
    glfw.WindowHint(glfw.CLIENT_API,glfw.NO_API)
    when ODIN_OS==.Windows {glfw.WindowHint(glfw.SCALE_TO_MONITOR,true)}
    // Wayland needs an XDG role and its first configure before Vulkan attaches
    // a buffer. A visible Wayland window still maps only at the first present.
    glfw.WindowHint(glfw.VISIBLE,glfw.GetPlatform() == glfw.PLATFORM_WAYLAND)
    r.window=glfw.CreateWindow(i32(width),i32(height),title,nil,nil)
    if r.window == nil { renderer_destroy(r); return false }
    r.width=width; r.height=height
    scale_x,scale_y := glfw.GetWindowContentScale(r.window)
    atlas:=Font_Atlas{scale=clamp(max(scale_x,scale_y),0.5,4.0)}
    font_worker:=thread.create(startup_font_worker)
    if font_worker!=nil {font_worker.data=&atlas;thread.start(font_worker)}
    else {atlas.ready=renderer_font_rasterize(&atlas)}
    defer {
        // Also wait on early Vulkan failures before releasing worker-owned data.
        if font_worker!=nil {thread.destroy(font_worker)}
        delete(atlas.pixels)
    }
    stage=startup_stage(stage,"GLFW / window")
    vk.load_proc_addresses_global(glfw.GetInstanceProcAddress(nil,"vkGetInstanceProcAddr"))
    required_extensions := glfw.GetRequiredInstanceExtensions()
    extensions:=make([dynamic]cstring,0,len(required_extensions)+2,context.temp_allocator)
    append(&extensions,..required_extensions)
    if len(extensions) == 0 { fmt.eprintln("GLFW cannot create Vulkan surfaces on this display"); renderer_destroy(r); return false }
    api_version:u32=vk.API_VERSION_1_0
    loader_version:u32
    if vk.EnumerateInstanceVersion!=nil&&vk.EnumerateInstanceVersion(&loader_version)==.SUCCESS {
        api_version=min(loader_version,vk.API_VERSION_1_3)
    }
    portability:=false
    available_count:u32
    vk.EnumerateInstanceExtensionProperties(nil,&available_count,nil)
    available:=make([]vk.ExtensionProperties,int(available_count),context.temp_allocator)
    vk.EnumerateInstanceExtensionProperties(nil,&available_count,raw_data(available))
    for &extension in available {
        name:=string(cast(cstring)&extension.extensionName[0])
        if name=="VK_KHR_portability_enumeration" {append(&extensions,"VK_KHR_portability_enumeration");portability=true}
        if api_version<vk.API_VERSION_1_1&&name=="VK_KHR_get_physical_device_properties2" {append(&extensions,"VK_KHR_get_physical_device_properties2")}
    }
    app := vk.ApplicationInfo{sType=.APPLICATION_INFO,pApplicationName="task_master",apiVersion=api_version}
    instance := vk.InstanceCreateInfo{sType=.INSTANCE_CREATE_INFO,pApplicationInfo=&app,enabledExtensionCount=u32(len(extensions)),ppEnabledExtensionNames=raw_data(extensions)}
    if portability {instance.flags={.ENUMERATE_PORTABILITY_KHR}}
    if !renderer_ok(vk.CreateInstance(&instance,nil,&r.instance), "instance") { renderer_destroy(r); return false }
    vk.load_proc_addresses_instance(r.instance)
    if !renderer_ok(glfw.CreateWindowSurface(r.instance,r.window,nil,&r.surface), "window surface") { renderer_destroy(r); return false }
    stage=startup_stage(stage,"Vulkan instance / surface")
    count: u32
    vk.EnumeratePhysicalDevices(r.instance,&count,nil)
    devices := make([]vk.PhysicalDevice,int(count)); defer delete(devices)
    vk.EnumeratePhysicalDevices(r.instance,&count,raw_data(devices))
    best_score := -1
    for device in devices {
        props: vk.PhysicalDeviceProperties; vk.GetPhysicalDeviceProperties(device,&props)
        score := 1
        if props.deviceType == .INTEGRATED_GPU { score=2 }
        if props.deviceType == .DISCRETE_GPU { score=3 }
        family_count: u32
        vk.GetPhysicalDeviceQueueFamilyProperties(device,&family_count,nil)
        families := make([]vk.QueueFamilyProperties,int(family_count))
        vk.GetPhysicalDeviceQueueFamilyProperties(device,&family_count,raw_data(families))
        for family,i in families {
            supported: b32
            vk.GetPhysicalDeviceSurfaceSupportKHR(device,u32(i),r.surface,&supported)
            if .GRAPHICS in family.queueFlags && supported && score > best_score {
                r.physical=device; r.family=u32(i); best_score=score
                if r.device_name != "" { delete(r.device_name) }
                r.device_name=strings.clone(string(cast(cstring)&props.deviceName[0]))
            }
        }
        delete(families)
    }
    if best_score < 0 { fmt.eprintln("No graphics device with presentation support"); renderer_destroy(r); return false }
    stage=startup_stage(stage,"GPU discovery")
    priority: f32=1
    queue := vk.DeviceQueueCreateInfo{sType=.DEVICE_QUEUE_CREATE_INFO,queueFamilyIndex=r.family,queueCount=1,pQueuePriorities=&priority}
    device_extensions := [4]cstring{"VK_KHR_swapchain","VK_KHR_maintenance5","VK_KHR_pipeline_binary",nil}
    extension_count:u32=1
    binary_features:=vk.PhysicalDevicePipelineBinaryFeaturesKHR{sType=.PHYSICAL_DEVICE_PIPELINE_BINARY_FEATURES_KHR}
    maintenance_features:=vk.PhysicalDeviceMaintenance5Features{sType=.PHYSICAL_DEVICE_MAINTENANCE_5_FEATURES,pNext=&binary_features}
    device := vk.DeviceCreateInfo{sType=.DEVICE_CREATE_INFO,queueCreateInfoCount=1,pQueueCreateInfos=&queue,enabledExtensionCount=extension_count,ppEnabledExtensionNames=raw_data(device_extensions[:])}
    if pipeline_binary_extensions(r,api_version) {
        features:=vk.PhysicalDeviceFeatures2{sType=.PHYSICAL_DEVICE_FEATURES_2,pNext=&maintenance_features}
        vk.GetPhysicalDeviceFeatures2(r.physical,&features)
        if bool(maintenance_features.maintenance5)&&bool(binary_features.pipelineBinaries) {
            r.pipeline_binaries=true
            device.enabledExtensionCount=3;extension_count=3;device.pNext=&maintenance_features
        }
    }
    vk.EnumerateDeviceExtensionProperties(r.physical,nil,&available_count,nil)
    device_available:=make([]vk.ExtensionProperties,int(available_count),context.temp_allocator)
    vk.EnumerateDeviceExtensionProperties(r.physical,nil,&available_count,raw_data(device_available))
    for &extension in device_available {
        if string(cast(cstring)&extension.extensionName[0])=="VK_KHR_portability_subset" {
            device_extensions[extension_count]="VK_KHR_portability_subset"
            device.enabledExtensionCount=extension_count+1
            break
        }
    }
    if !renderer_ok(vk.CreateDevice(r.physical,&device,nil,&r.device), "device") { renderer_destroy(r); return false }
    vk.load_proc_addresses_device(r.device)
    r.pipeline_binaries=r.pipeline_binaries&&vk.GetPipelineKeyKHR!=nil&&vk.CreatePipelineBinariesKHR!=nil&&
        vk.GetPipelineBinaryDataKHR!=nil&&vk.DestroyPipelineBinaryKHR!=nil&&vk.ReleaseCapturedPipelineDataKHR!=nil
    stage=startup_stage(stage,"Vulkan device")
    vk.GetDeviceQueue(r.device,r.family,0,&r.queue)
    pool := vk.CommandPoolCreateInfo{sType=.COMMAND_POOL_CREATE_INFO,flags={.RESET_COMMAND_BUFFER},queueFamilyIndex=r.family}
    if !renderer_ok(vk.CreateCommandPool(r.device,&pool,nil,&r.pool), "command pool") { renderer_destroy(r); return false }
    command := vk.CommandBufferAllocateInfo{sType=.COMMAND_BUFFER_ALLOCATE_INFO,commandPool=r.pool,level=.PRIMARY,commandBufferCount=1}
    if !renderer_ok(vk.AllocateCommandBuffers(r.device,&command,&r.command), "command buffer") { renderer_destroy(r); return false }
    fence := vk.FenceCreateInfo{sType=.FENCE_CREATE_INFO,flags={.SIGNALED}}
    sem := vk.SemaphoreCreateInfo{sType=.SEMAPHORE_CREATE_INFO}
    if !renderer_ok(vk.CreateFence(r.device,&fence,nil,&r.fence), "fence") || !renderer_ok(vk.CreateSemaphore(r.device,&sem,nil,&r.acquired), "acquire semaphore") { renderer_destroy(r); return false }
    stage=startup_stage(stage,"buffers / commands")
    if font_worker!=nil {thread.join(font_worker)}
    if !atlas.ready || !renderer_font_upload(r,&atlas) { renderer_destroy(r); return false }
    stage=startup_stage(stage,"font join / upload")
    if !renderer_swapchain(r) { renderer_destroy(r); return false }
    stage=startup_stage(stage,"pipeline / swapchain")
    return true
}
renderer_prepare_frame :: proc(r: ^Renderer) -> bool {
    w,h := glfw.GetFramebufferSize(r.window)
    if int(w) != r.width || int(h) != r.height { if !renderer_swapchain(r) { return false } }
    return true
}
renderer_acquire_frame :: proc(r:^Renderer)->(index:u32,ready,ok:bool) {
    if r.width<=0||r.height<=0 {return 0,false,true}
    if !renderer_ok(vk.WaitForFences(r.device,1,&r.fence,true,~u64(0)), "wait frame") {return 0,false,false}
    // Wait before reading input and building geometry, so hover uses fresh input.
    acquired := vk.AcquireNextImageKHR(r.device,r.swapchain,~u64(0),r.acquired,0,&index)
    if acquired == .ERROR_OUT_OF_DATE_KHR {return 0,false,renderer_swapchain(r)}
    if acquired != .SUCCESS && acquired != .SUBOPTIMAL_KHR {renderer_ok(acquired,"acquire image");return 0,false,false}
    return index,true,true
}
renderer_draw :: proc(r: ^Renderer, vertices: []Vertex,image_index:u32) -> bool {
    index:=image_index
    if !renderer_reserve_vertices(r,len(vertices)*size_of(Vertex)) { return false }
    capture_buffer: vk.Buffer
    capture_memory: vk.DeviceMemory
    capture_bytes := r.width*r.height*4
    capturing := r.capture_path != "" && r.capture_supported
    if r.capture_path != "" && !r.capture_supported {
        fmt.eprintln("Surface does not support Vulkan screenshot transfer")
        r.capture_path=""; r.capture_success=false
    }
    if capturing {
        if !renderer_buffer(r,capture_bytes,{.TRANSFER_DST},&capture_buffer,&capture_memory) { return false }
    }
    defer {
        if capture_buffer != 0 { vk.DestroyBuffer(r.device,capture_buffer,nil) }
        if capture_memory != 0 { vk.FreeMemory(r.device,capture_memory,nil) }
    }
    mem.copy(r.vertex_mapping,raw_data(vertices),len(vertices)*size_of(Vertex))
    vk.ResetCommandBuffer(r.command,{})
    begin := vk.CommandBufferBeginInfo{sType=.COMMAND_BUFFER_BEGIN_INFO,flags={.ONE_TIME_SUBMIT}}
    vk.BeginCommandBuffer(r.command,&begin)
    clear := vk.ClearValue{color={float32={0.055,0.064,0.082,1}}}
    pass := vk.RenderPassBeginInfo{sType=.RENDER_PASS_BEGIN_INFO,renderPass=r.render_pass,framebuffer=r.framebuffers[index],renderArea={extent={u32(r.width),u32(r.height)}},clearValueCount=1,pClearValues=&clear}
    vk.CmdBeginRenderPass(r.command,&pass,.INLINE)
    vk.CmdBindPipeline(r.command,.GRAPHICS,r.pipeline)
    viewport := vk.Viewport{width=f32(r.width),height=f32(r.height),maxDepth=1}
    scissor := vk.Rect2D{extent={u32(r.width),u32(r.height)}}
    vk.CmdSetViewport(r.command,0,1,&viewport); vk.CmdSetScissor(r.command,0,1,&scissor)
    offset: vk.DeviceSize=0
    vk.CmdBindVertexBuffers(r.command,0,1,&r.vertex_buffer,&offset)
    vk.CmdBindDescriptorSets(r.command,.GRAPHICS,r.layout,0,1,&r.descriptor,0,nil)
    extent := [2]f32{f32(r.width),f32(r.height)}
    vk.CmdPushConstants(r.command,r.layout,{.VERTEX},0,8,&extent)
    vk.CmdDraw(r.command,u32(len(vertices)),1,0,0)
    vk.CmdEndRenderPass(r.command)
    if capturing {
        barrier := vk.ImageMemoryBarrier{sType=.IMAGE_MEMORY_BARRIER,oldLayout=.PRESENT_SRC_KHR,newLayout=.TRANSFER_SRC_OPTIMAL,
            srcQueueFamilyIndex=vk.QUEUE_FAMILY_IGNORED,dstQueueFamilyIndex=vk.QUEUE_FAMILY_IGNORED,image=r.images[index],
            subresourceRange={aspectMask={.COLOR},levelCount=1,layerCount=1},srcAccessMask={.COLOR_ATTACHMENT_WRITE},dstAccessMask={.TRANSFER_READ}}
        vk.CmdPipelineBarrier(r.command,{.COLOR_ATTACHMENT_OUTPUT},{.TRANSFER},{},0,nil,0,nil,1,&barrier)
        region := vk.BufferImageCopy{imageSubresource={aspectMask={.COLOR},layerCount=1},imageExtent={u32(r.width),u32(r.height),1}}
        vk.CmdCopyImageToBuffer(r.command,r.images[index],.TRANSFER_SRC_OPTIMAL,capture_buffer,1,&region)
        barrier.oldLayout=.TRANSFER_SRC_OPTIMAL; barrier.newLayout=.PRESENT_SRC_KHR
        barrier.srcAccessMask={.TRANSFER_READ}; barrier.dstAccessMask={}
        vk.CmdPipelineBarrier(r.command,{.TRANSFER},{.BOTTOM_OF_PIPE},{},0,nil,0,nil,1,&barrier)
    }
    vk.EndCommandBuffer(r.command)
    wait_stage: vk.PipelineStageFlags={.COLOR_ATTACHMENT_OUTPUT}
    submit := vk.SubmitInfo{sType=.SUBMIT_INFO,waitSemaphoreCount=1,pWaitSemaphores=&r.acquired,pWaitDstStageMask=&wait_stage,commandBufferCount=1,pCommandBuffers=&r.command,signalSemaphoreCount=1,pSignalSemaphores=&r.present_semaphores[index]}
    vk.ResetFences(r.device,1,&r.fence)
    if !renderer_ok(vk.QueueSubmit(r.queue,1,&submit,r.fence), "draw submit") { return false }
    if capturing {
        vk.WaitForFences(r.device,1,&r.fence,true,~u64(0))
        pixels: rawptr
        if renderer_ok(vk.MapMemory(r.device,capture_memory,0,vk.DeviceSize(capture_bytes),{},&pixels),"map screenshot") {
            // Encoding repeatedly reads neighbouring pixels. Keep that work
            // in ordinary RAM instead of making byte-sized reads over the GPU
            // mapping for every PNG filter candidate.
            bytes := make([]u8,capture_bytes)
            defer delete(bytes)
            copy(bytes,(cast([^]u8)pixels)[:capture_bytes])
            if r.format == .B8G8R8A8_UNORM || r.format == .B8G8R8A8_SRGB {
                for i := 0; i < capture_bytes; i += 4 { bytes[i],bytes[i+2]=bytes[i+2],bytes[i] }
            }
            path := strings.clone_to_cstring(r.capture_path)
            r.capture_success=stbi.write_png(path,i32(r.width),i32(r.height),4,raw_data(bytes),i32(r.width*4)) != 0
            delete(path)
            vk.UnmapMemory(r.device,capture_memory)
        }
        r.capture_path=""
    }
    present := vk.PresentInfoKHR{sType=.PRESENT_INFO_KHR,waitSemaphoreCount=1,pWaitSemaphores=&r.present_semaphores[index],swapchainCount=1,pSwapchains=&r.swapchain,pImageIndices=&index}
    result := vk.QueuePresentKHR(r.queue,&present)
    if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR { return renderer_swapchain(r) }
    return renderer_ok(result,"present")
}
renderer_destroy :: proc(r: ^Renderer) {
    if r.device != nil {
        vk.DeviceWaitIdle(r.device)
        renderer_swapchain_destroy(r)
        if r.pipeline != 0 { vk.DestroyPipeline(r.device,r.pipeline,nil) }
        if r.layout != 0 { vk.DestroyPipelineLayout(r.device,r.layout,nil) }
        if r.render_pass != 0 { vk.DestroyRenderPass(r.device,r.render_pass,nil) }
        if r.descriptor_pool != 0 { vk.DestroyDescriptorPool(r.device,r.descriptor_pool,nil) }
        if r.descriptor_layout != 0 { vk.DestroyDescriptorSetLayout(r.device,r.descriptor_layout,nil) }
        if r.sampler != 0 { vk.DestroySampler(r.device,r.sampler,nil) }
        if r.font_view != 0 { vk.DestroyImageView(r.device,r.font_view,nil) }
        if r.font_image != 0 { vk.DestroyImage(r.device,r.font_image,nil) }
        if r.font_memory != 0 { vk.FreeMemory(r.device,r.font_memory,nil) }
        if r.vertex_mapping != nil { vk.UnmapMemory(r.device,r.vertex_memory) }
        if r.vertex_buffer != 0 { vk.DestroyBuffer(r.device,r.vertex_buffer,nil) }
        if r.vertex_memory != 0 { vk.FreeMemory(r.device,r.vertex_memory,nil) }
        if r.fence != 0 { vk.DestroyFence(r.device,r.fence,nil) }
        if r.acquired != 0 { vk.DestroySemaphore(r.device,r.acquired,nil) }
        if r.pool != 0 { vk.DestroyCommandPool(r.device,r.pool,nil) }
        vk.DestroyDevice(r.device,nil)
    }
    if r.surface != 0 { vk.DestroySurfaceKHR(r.instance,r.surface,nil) }
    if r.instance != nil { vk.DestroyInstance(r.instance,nil) }
    if r.window != nil { glfw.DestroyWindow(r.window) }
    if r.device_name != "" { delete(r.device_name) }
    glfw.Terminate()
    if r.vulkan_library!=nil {dynlib.unload_library(r.vulkan_library)}
    r^={}
}
renderer_quad :: proc(vertices: ^[dynamic]Vertex, x0,y0,x1,y1,u0,v0,u1,v1: f32, color: [4]f32) {
    a := Vertex{pos={x0,y0},uv={u0,v0},color=color}; b := Vertex{pos={x1,y0},uv={u1,v0},color=color}
    c := Vertex{pos={x1,y1},uv={u1,v1},color=color}; d := Vertex{pos={x0,y1},uv={u0,v1},color=color}
    append(vertices,a,b,c,a,c,d)
}
renderer_rect :: proc(vertices: ^[dynamic]Vertex, x,y,w,h: f32, color: [4]f32) {
    renderer_quad(vertices,x,y,x+w,y+h,0,0,0,0,color)
}
renderer_font_size :: proc(r: ^Renderer, size: f32) -> ^Font_Size {
    nearest := 0
    distance := abs(r.fonts[0].pixels-size)
    for font,i in r.fonts {
        next_distance := abs(font.pixels-size)
        if next_distance < distance { nearest=i; distance=next_distance }
    }
    return &r.fonts[nearest]
}
renderer_text :: proc(r: ^Renderer, vertices: ^[dynamic]Vertex, text: string, x,y,size: f32, color: [4]f32,clip_top:f32=-1e30,clip_bottom:f32=1e30) {
    font := renderer_font_size(r,size)
    cursor := math.round(x)
    // Public y denotes the top of the text line rather than its baseline.
    baseline := math.round(y+size*0.80)
    for ch in text {
        c := ch
        if c < 32 || c > 126 { c='?' }
        glyph := font.glyphs[c-32]
        if glyph.width > 0 && glyph.height > 0 {
            gx := math.round(cursor)+f32(glyph.left)
            gy := baseline-f32(glyph.top)
            // Integer physical pixels and one atlas texel per framebuffer
            // pixel keep stems crisp even at fractional monitor scales.
            top,bottom:=max(gy,clip_top),min(gy+f32(glyph.height),clip_bottom)
            if bottom>top {
                renderer_quad(vertices,gx,top,gx+f32(glyph.width),bottom,
                    f32(glyph.x)/ATLAS_SIZE,(f32(glyph.y)+top-gy)/f32(r.atlas_height),
                    f32(glyph.x+glyph.width)/ATLAS_SIZE,(f32(glyph.y)+bottom-gy)/f32(r.atlas_height),color)
            }
        }
        cursor+=glyph.advance
    }
}
renderer_text_width :: proc(r: ^Renderer, text: string, size: f32) -> f32 {
    font := renderer_font_size(r,size)
    width: f32
    for ch in text { c:=ch; if c < 32 || c > 126 { c='?' }; width+=font.glyphs[c-32].advance }
    return width
}

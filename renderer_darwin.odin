package main

import "core:os"
import "core:path/filepath"
import "core:dynlib"
import "core:fmt"
import vk "vendor:vulkan"
import glfw "vendor:glfw"

renderer_darwin_load :: proc(r:^Renderer)->bool {
    executable,err:=os.get_executable_path(context.temp_allocator)
    if err!=nil {fmt.eprintln("Cannot locate the macOS application:",err);return false}
    library,_:=filepath.join({filepath.dir(executable),"../Frameworks/libMoltenVK.dylib"},context.temp_allocator)
    r.vulkan_library, _ = dynlib.load_library(library)
    if r.vulkan_library==nil {r.vulkan_library,_=dynlib.load_library("libMoltenVK.dylib")}
    if r.vulkan_library==nil {fmt.eprintln("Cannot load MoltenVK; use the packaged task_master.app.");return false}
    address,found:=dynlib.symbol_address(r.vulkan_library,"vkGetInstanceProcAddr")
    if !found {renderer_destroy(r);return false}
    glfw.InitVulkanLoader(cast(vk.ProcGetInstanceProcAddr)address)
    return true
}

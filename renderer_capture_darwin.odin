#+build darwin
package main

import "core:fmt"

foreign import renderer_capture_cf "system:CoreFoundation.framework"
foreign import renderer_capture_cg "system:CoreGraphics.framework"
foreign import renderer_capture_io "system:ImageIO.framework"
@(default_calling_convention="c")
foreign renderer_capture_cf {
    @(link_name="CFURLCreateFromFileSystemRepresentation") renderer_capture_url :: proc(rawptr,[^]u8,int,u8)->rawptr ---
    @(link_name="CFStringCreateWithBytes") renderer_capture_string :: proc(rawptr,[^]u8,int,u32,u8)->rawptr ---
    @(link_name="CFRelease") renderer_capture_release :: proc(rawptr) ---
}
@(default_calling_convention="c")
foreign renderer_capture_cg {
    @(link_name="CGColorSpaceCreateDeviceRGB") renderer_capture_color_space :: proc()->rawptr ---
    @(link_name="CGColorSpaceRelease") renderer_capture_color_space_release :: proc(rawptr) ---
    @(link_name="CGDataProviderCreateWithData") renderer_capture_provider :: proc(rawptr,rawptr,uint,rawptr)->rawptr ---
    @(link_name="CGDataProviderRelease") renderer_capture_provider_release :: proc(rawptr) ---
    @(link_name="CGImageCreate") renderer_capture_image :: proc(uint,uint,uint,uint,uint,rawptr,u32,rawptr,^f64,bool,u32)->rawptr ---
    @(link_name="CGImageRelease") renderer_capture_image_release :: proc(rawptr) ---
}
@(default_calling_convention="c")
foreign renderer_capture_io {
    @(link_name="CGImageDestinationCreateWithURL") renderer_capture_destination :: proc(rawptr,rawptr,uint,rawptr)->rawptr ---
    @(link_name="CGImageDestinationAddImage") renderer_capture_add_image :: proc(rawptr,rawptr,rawptr) ---
    @(link_name="CGImageDestinationFinalize") renderer_capture_finalize :: proc(rawptr)->u8 ---
}

// Metal's texture origin and ImageIO's raw image rows are both top-left. The
// 256-byte blit alignment is represented by bytesPerRow; no copy or flip is
// necessary. The shared GPU buffer stays alive until ImageIO finishes encoding.
renderer_capture_png :: proc(path:string,pixels:[]u8,width,height,row_bytes:int)->(success:bool) {
    defer {if !success {fmt.println("Could not encode the Metal screenshot as PNG.")}}
    if path==""||width<=0||height<=0||width>max(int)/4||row_bytes<width*4||
        row_bytes<=0||height>len(pixels)/row_bytes {return false}
    url:=renderer_capture_url(nil,raw_data(path),len(path),0)
    if url==nil {return false}
    defer renderer_capture_release(url)
    png_identifier:string="public.png"
    png_type:=renderer_capture_string(nil,raw_data(png_identifier),len(png_identifier),0x08000100,0)
    if png_type==nil {return false}
    defer renderer_capture_release(png_type)
    space:=renderer_capture_color_space()
    if space==nil {return false}
    defer renderer_capture_color_space_release(space)
    provider:=renderer_capture_provider(nil,raw_data(pixels),uint(height*row_bytes),nil)
    if provider==nil {return false}
    defer renderer_capture_provider_release(provider)
    // kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst = BGRA.
    image:=renderer_capture_image(uint(width),uint(height),8,32,uint(row_bytes),space,
        0x2000|2,provider,nil,false,0)
    if image==nil {return false}
    defer renderer_capture_image_release(image)
    destination:=renderer_capture_destination(url,png_type,1,nil)
    if destination==nil {return false}
    defer renderer_capture_release(destination)
    renderer_capture_add_image(destination,image,nil)
    return renderer_capture_finalize(destination)!=0
}

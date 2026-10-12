#+build darwin
package main

import "core:math"
import "core:mem"
import CF "core:sys/darwin/CoreFoundation"

// CoreText and Quartz expose stable C interfaces, including the geometry
// types shared with Foundation. No Objective-C bridge or FreeType is needed.
Darwin_Font_Transform :: struct {
    a, b, c, d, tx, ty: CF.CGFloat,
}

foreign import tm_font_coretext "system:CoreText.framework"
foreign import tm_font_quartz "system:CoreGraphics.framework"
foreign import tm_font_cf "system:CoreFoundation.framework"

@(default_calling_convention="c")
foreign tm_font_coretext {
    @(link_name="CTFontCreateWithGraphicsFont") darwin_font_create :: proc(rawptr, CF.CGFloat, ^Darwin_Font_Transform, rawptr) -> rawptr ---
    @(link_name="CTFontGetGlyphsForCharacters") darwin_font_glyphs :: proc(rawptr, ^u16, ^u16, int) -> b8 ---
    @(link_name="CTFontGetBoundingRectsForGlyphs") darwin_font_bounds :: proc(rawptr, u32, ^u16, ^CF.CGRect, int) -> CF.CGRect ---
    @(link_name="CTFontGetAdvancesForGlyphs") darwin_font_advances :: proc(rawptr, u32, ^u16, ^CF.CGSize, int) -> f64 ---
    @(link_name="CTFontCreateForString") darwin_font_fallback :: proc(rawptr,rawptr,CF.Range)->rawptr ---
    @(link_name="CTFontDrawGlyphs") darwin_font_draw :: proc(rawptr, ^u16, ^CF.CGPoint, uint, rawptr) ---
}

@(default_calling_convention="c")
foreign tm_font_quartz {
    @(link_name="CGDataProviderCreateWithData") darwin_font_provider :: proc(rawptr, rawptr, uint, rawptr) -> rawptr ---
    @(link_name="CGFontCreateWithDataProvider") darwin_font_graphics :: proc(rawptr) -> rawptr ---
    @(link_name="CGColorSpaceCreateDeviceGray") darwin_font_gray_space :: proc() -> rawptr ---
    @(link_name="CGBitmapContextCreate") darwin_font_bitmap :: proc(rawptr, uint, uint, uint, uint, rawptr, u32) -> rawptr ---
    @(link_name="CGBitmapContextGetData") darwin_font_bitmap_data :: proc(rawptr) -> rawptr ---
    @(link_name="CGBitmapContextGetBytesPerRow") darwin_font_bitmap_stride :: proc(rawptr) -> uint ---
    @(link_name="CGContextSetAllowsAntialiasing") darwin_font_allow_antialias :: proc(rawptr, b8) ---
    @(link_name="CGContextSetShouldAntialias") darwin_font_antialias :: proc(rawptr, b8) ---
    @(link_name="CGContextSetAllowsFontSmoothing") darwin_font_allow_smoothing :: proc(rawptr, b8) ---
    @(link_name="CGContextSetShouldSmoothFonts") darwin_font_smoothing :: proc(rawptr, b8) ---
    @(link_name="CGContextSetGrayFillColor") darwin_font_fill :: proc(rawptr, CF.CGFloat, CF.CGFloat) ---
}

@(default_calling_convention="c")
foreign tm_font_cf {
    @(link_name="CFStringCreateWithCharacters") darwin_font_string :: proc(rawptr,^u16,int)->rawptr ---
    @(link_name="CFRelease") darwin_font_release :: proc(rawptr) ---
}

renderer_font_rasterize :: proc(atlas:^Font_Atlas)->bool {
    font_data :: #load("assets/Inter-Regular.ttf")
    provider:=darwin_font_provider(nil,raw_data(font_data),uint(len(font_data)),nil)
    if provider==nil {return false}
    defer darwin_font_release(provider)
    graphics_font:=darwin_font_graphics(provider)
    if graphics_font==nil {return false}
    defer darwin_font_release(graphics_font)
    atlas.pixels=make([dynamic]u8,ATLAS_SIZE*ATLAS_HEIGHT)
    atlas.x=3;atlas.y=1
    for logical_size,index in FONT_SIZES {
        pixel_size:=max(1,int(math.round(logical_size*atlas.scale)))
        atlas.fonts[index].pixels=f32(pixel_size)
        font:=darwin_font_create(graphics_font,CF.CGFloat(pixel_size),nil,nil)
        if font==nil {return false}
        atlas.native_fonts[index]=font
        for codepoint in 32..<127 {
            glyph,ok:=renderer_font_coretext_glyph(atlas,font,rune(codepoint))
            if !ok {return false}
            atlas.fonts[index].glyphs[codepoint-32]=glyph
        }
    }
    atlas.pixels[0]=255;atlas.pixels[1]=255
    atlas.pixels[ATLAS_SIZE]=255;atlas.pixels[ATLAS_SIZE+1]=255
    renderer_font_prepare(atlas)
    atlas.dirty=false
    return true
}
renderer_font_utf16 :: proc(ch:rune)->(characters:[2]u16,count:int) {
    if ch<=0xffff {return {u16(ch),0},1}
    value:=u32(ch)-0x10000
    return {u16(0xd800+(value>>10)),u16(0xdc00+(value&0x3ff))},2
}
renderer_font_coretext_glyph :: proc(atlas:^Font_Atlas,font:rawptr,ch:rune)->(Font_Glyph,bool) {
    characters,count:=renderer_font_utf16(ch)
    glyphs:[2]u16
    // A surrogate pair can report an unmapped trailing UTF-16 unit even
    // though CoreText produced its valid scalar glyph in the leading slot.
    _=darwin_font_glyphs(font,&characters[0],&glyphs[0],count)
    glyph:=glyphs[0]
    if glyph==0 && count==2 {glyph=glyphs[1]}
    if glyph==0 {return {},false}
    bounds:CF.CGRect
    advance:CF.CGSize
    darwin_font_bounds(font,1,&glyph,&bounds,1)
    darwin_font_advances(font,1,&glyph,&advance,1)
    packed:=Font_Glyph{advance=f32(advance.width)}
    if bounds.width<=0 || bounds.height<=0 {return packed,true}
    left:=int(math.floor(f64(bounds.x)))-1
    bottom:=int(math.floor(f64(bounds.y)))-1
    right:=int(math.ceil(f64(bounds.x+bounds.width)))+1
    top:=int(math.ceil(f64(bounds.y+bounds.height)))+1
    width,height:=right-left,top-bottom
    x,y,ok:=renderer_font_pack(atlas,width,height)
    if !ok {return {},false}
    gray:=darwin_font_gray_space()
    if gray==nil {return {},false}
    defer darwin_font_release(gray)
    stride:=(width+15)&~15
    bitmap:=darwin_font_bitmap(nil,uint(width),uint(height),8,uint(stride),gray,0)
    if bitmap==nil {return {},false}
    defer darwin_font_release(bitmap)
    pixels:=cast([^]u8)darwin_font_bitmap_data(bitmap)
    if pixels==nil {return {},false}
    stride=int(darwin_font_bitmap_stride(bitmap))
    mem.zero(pixels,stride*height)
    darwin_font_allow_antialias(bitmap,true);darwin_font_antialias(bitmap,true)
    darwin_font_allow_smoothing(bitmap,false);darwin_font_smoothing(bitmap,false)
    darwin_font_fill(bitmap,1,1)
    position:=CF.CGPoint{x=CF.CGFloat(-left),y=CF.CGFloat(-bottom)}
    darwin_font_draw(font,&glyph,&position,1,bitmap)
    for row in 0..<height {mem.copy(&atlas.pixels[(y+row)*ATLAS_SIZE+x],&pixels[row*stride],width)}
    packed.x=x;packed.y=y;packed.width=width;packed.height=height;packed.left=left;packed.top=top
    atlas.dirty=true
    return packed,true
}
renderer_font_unicode :: proc(atlas:^Font_Atlas,index:int,ch:rune)->(Font_Glyph,bool) {
    base:=atlas.native_fonts[index]
    if glyph,ok:=renderer_font_coretext_glyph(atlas,base,ch);ok {return glyph,true}
    characters,count:=renderer_font_utf16(ch)
    text:=darwin_font_string(nil,&characters[0],count)
    if text==nil {return {},false}
    defer darwin_font_release(text)
    // CoreText chooses an installed face from the native cascade list.
    fallback:=darwin_font_fallback(base,text,CF.Range{0,CF.Index(count)})
    if fallback==nil {return {},false}
    defer darwin_font_release(fallback)
    return renderer_font_coretext_glyph(atlas,fallback,ch)
}
renderer_font_dispose :: proc(atlas:^Font_Atlas) {
    for font in atlas.native_fonts {if font!=nil {darwin_font_release(font)}}
    delete(atlas.pixels);delete(atlas.unicode)
    atlas^={}
}

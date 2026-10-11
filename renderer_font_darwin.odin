#+build darwin
package main

import "core:fmt"
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
    @(link_name="CFRelease") darwin_font_release :: proc(rawptr) ---
}

renderer_font_rasterize :: proc(atlas: ^Font_Atlas) -> bool {
    font_data :: #load("assets/DejaVuSans.ttf")
    provider := darwin_font_provider(nil, raw_data(font_data), uint(len(font_data)), nil)
    if provider == nil { fmt.eprintln("Cannot create CoreText font data provider"); return false }
    defer darwin_font_release(provider)
    graphics_font := darwin_font_graphics(provider)
    if graphics_font == nil { fmt.eprintln("Cannot load CoreText UI font"); return false }
    defer darwin_font_release(graphics_font)
    gray_space := darwin_font_gray_space()
    if gray_space == nil { return false }
    defer darwin_font_release(gray_space)

    atlas.pixels = make([dynamic]u8, ATLAS_SIZE*64, ATLAS_SIZE*64)
    x, y, row_height := 3, 1, 0
    for logical_size, index in FONT_SIZES {
        pixel_size := max(1, int(math.round(logical_size*atlas.scale)))
        atlas.fonts[index].pixels = f32(pixel_size)
        font := darwin_font_create(graphics_font, CF.CGFloat(pixel_size), nil, nil)
        if font == nil { return false }
        // These objects and their bitmap contexts belong exclusively to this
        // worker. CoreText font objects do not require an AppKit main thread.
        defer darwin_font_release(font)
        for codepoint in 32..<127 {
            character := u16(codepoint)
            glyph: u16
            if !darwin_font_glyphs(font, &character, &glyph, 1) { return false }
            bounds: CF.CGRect
            advance: CF.CGSize
            darwin_font_bounds(font, 1, &glyph, &bounds, 1) // Horizontal orientation.
            darwin_font_advances(font, 1, &glyph, &advance, 1)
            packed := Font_Glyph{advance=f32(advance.width)}
            // A space has a pen advance but no raster or quad.
            if bounds.width <= 0 || bounds.height <= 0 {
                atlas.fonts[index].glyphs[codepoint-32] = packed
                continue
            }
            // Quartz bounds are measured from the baseline, with y increasing
            // upwards. Add one pixel around ink to retain antialiased edges.
            left := int(math.floor(f64(bounds.x)))-1
            bottom := int(math.floor(f64(bounds.y)))-1
            right := int(math.ceil(f64(bounds.x+bounds.width)))+1
            top := int(math.ceil(f64(bounds.y+bounds.height)))+1
            width, height := right-left, top-bottom
            if width+2 >= ATLAS_SIZE { return false }
            if x+width+1 >= ATLAS_SIZE { x=1; y+=row_height+2; row_height=0 }
            if y+height+2 > 4096 {
                fmt.eprintln("CoreText font atlas exceeds capacity")
                return false
            }
            needed := (y+height+2)*ATLAS_SIZE
            if needed > len(atlas.pixels) {
                size := len(atlas.pixels)
                for size < needed { size*=2 }
                if resize(&atlas.pixels, min(size, ATLAS_SIZE*4096)) != nil { return false }
            }

            // An 8-bit grayscale bitmap produces coverage directly; disable
            // display-specific subpixel smoothing for the single-channel atlas.
            // Quartz's bitmap bytes are top-row-first despite its y-up CTM.
            stride := (width+15)&~15
            bitmap := darwin_font_bitmap(nil, uint(width), uint(height), 8, uint(stride), gray_space, 0)
            if bitmap == nil { return false }
            defer darwin_font_release(bitmap)
            pixels := cast([^]u8)darwin_font_bitmap_data(bitmap)
            if pixels == nil { return false }
            stride = int(darwin_font_bitmap_stride(bitmap))
            mem.zero(pixels, stride*height)
            darwin_font_allow_antialias(bitmap, true)
            darwin_font_antialias(bitmap, true)
            darwin_font_allow_smoothing(bitmap, false)
            darwin_font_smoothing(bitmap, false)
            darwin_font_fill(bitmap, 1, 1)
            position := CF.CGPoint{x=CF.CGFloat(-left), y=CF.CGFloat(-bottom)}
            darwin_font_draw(font, &glyph, &position, 1, bitmap)
            for row in 0..<height {
                mem.copy(&atlas.pixels[(y+row)*ATLAS_SIZE+x], &pixels[row*stride], width)
            }
            packed.x=x; packed.y=y; packed.width=width; packed.height=height
            packed.left=left; packed.top=top
            atlas.fonts[index].glyphs[codepoint-32] = packed
            x+=width+2; row_height=max(row_height,height)
        }
    }
    atlas.height = max(64, y+row_height+2)
    // Solid geometry samples the reserved opaque corner of the same texture.
    atlas.pixels[0]=255; atlas.pixels[1]=255
    atlas.pixels[ATLAS_SIZE]=255; atlas.pixels[ATLAS_SIZE+1]=255
    return true
}

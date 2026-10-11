package main

import "core:math"

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
VERTEX_INITIAL_CAPACITY :: 256*1024
ATLAS_SIZE :: 1024

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

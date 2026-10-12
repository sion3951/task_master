package main

import "core:math"
import "core:mem"

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

FONT_UNICODE_CACHE_LIMIT :: 2048
ATLAS_HEIGHT :: 4096
Font_Source :: struct {
    path: string,
    data: []u8,
    face: rawptr,
    attempted: bool,
}

// CPU-owned raster data is prepared while the main thread creates the GPU device.
Font_Atlas :: struct {
    pixels: [dynamic]u8,
    fonts: [len(FONT_SIZES)]Font_Size,
    height: int,
    scale: f32,
    ready, dirty, reset_pending: bool,
    x, y, row_height, unicode_y: int,
    unicode: map[u64]Font_Glyph,
    library, face: rawptr,
    native_fonts: [len(FONT_SIZES)]rawptr,
    sources: [dynamic]Font_Source,
    sources_scanned: bool,
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
ATLAS_SIZE :: 2048

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
        glyph := renderer_glyph(r,font,ch)
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
    for ch in text { width+=renderer_glyph(r,font,ch).advance }
    return width
}

// Measuring and drawing share the same glyph, including fallback advances.
// Atlas dimensions never change while vertices are being generated.
renderer_glyph :: proc(r:^Renderer,font:^Font_Size,ch:rune)->Font_Glyph {
    if ch>=32 && ch<=126 {return font.glyphs[ch-32]}
    // Formatting controls and variation selectors have no standalone ink.
    // Do not insert visible replacement marks into emoji or joined names.
    if ch==0x00ad || ch==0x061c || ch==0xfeff || (ch>=0x200b && ch<=0x200f) || (ch>=0x202a && ch<=0x202e) || (ch>=0x2060 && ch<=0x206f) || (ch>=0xfe00 && ch<=0xfe0f) || (ch>=0xe0000 && ch<=0xe007f) || (ch>=0xe0100 && ch<=0xe01ef) {return {}}
    if ch<32 || (ch>=127 && ch<160) {return font.glyphs['?'-32]}
    index:=0
    for value,i in r.fonts {if value.pixels==font.pixels {index=i;break}}
    key:=(u64(index)<<32)|u64(ch)
    if glyph,ok:=r.atlas.unicode[key];ok {return glyph}
    if len(r.atlas.unicode)>=FONT_UNICODE_CACHE_LIMIT {
        r.atlas.reset_pending=true
        return font.glyphs['?'-32]
    }
    glyph,ok:=renderer_font_unicode(&r.atlas,index,ch)
    if !ok {glyph=font.glyphs['?'-32]}
    r.atlas.unicode[key]=glyph
    return glyph
}
renderer_font_pack :: proc(atlas:^Font_Atlas,width,height:int)->(x,y:int,ok:bool) {
    if width+2>=ATLAS_SIZE {return 0,0,false}
    if atlas.x+width+1>=ATLAS_SIZE {atlas.x=1;atlas.y+=atlas.row_height+2;atlas.row_height=0}
    if atlas.y+height+2>ATLAS_HEIGHT {atlas.reset_pending=true;return 0,0,false}
    when ODIN_OS==.Linux {
        // Coordinates retain the maximum-height basis throughout a frame.
        // Only the occupied rows need CPU storage or a GPU texture backing.
        rows:=max(128,len(atlas.pixels)/ATLAS_SIZE)
        for rows<atlas.y+height+2 {rows=min(rows*2,ATLAS_HEIGHT)}
        if rows*ATLAS_SIZE>len(atlas.pixels) {resize(&atlas.pixels,rows*ATLAS_SIZE)}
    }
    x,y=atlas.x,atlas.y
    atlas.x+=width+2;atlas.row_height=max(atlas.row_height,height)
    return x,y,true
}
renderer_font_prepare :: proc(atlas:^Font_Atlas) {
    atlas.unicode_y=atlas.y+atlas.row_height+2
    atlas.x=1;atlas.y=atlas.unicode_y;atlas.row_height=0
    atlas.height=ATLAS_HEIGHT
    when ODIN_OS!=.Linux {resize(&atlas.pixels,ATLAS_SIZE*ATLAS_HEIGHT)}
    atlas.unicode=make(map[u64]Font_Glyph)
}
// Eviction happens only before a new frame, never underneath its vertices.
renderer_font_begin :: proc(r:^Renderer) {
    if !r.atlas.reset_pending {return}
    clear(&r.atlas.unicode)
    start:=r.atlas.unicode_y*ATLAS_SIZE
    when ODIN_OS==.Linux {
        rows:=128
        for rows<r.atlas.unicode_y+2 {rows=min(rows*2,ATLAS_HEIGHT)}
        if rows*ATLAS_SIZE<len(r.atlas.pixels) {
            compact:=make([dynamic]u8,rows*ATLAS_SIZE)
            copy(compact[:start],r.atlas.pixels[:start])
            delete(r.atlas.pixels);r.atlas.pixels=compact
        } else if start<len(r.atlas.pixels) {mem.zero(&r.atlas.pixels[start],len(r.atlas.pixels)-start)}
    } else {
        if start<len(r.atlas.pixels) {mem.zero(&r.atlas.pixels[start],len(r.atlas.pixels)-start)}
    }
    r.atlas.x=1;r.atlas.y=r.atlas.unicode_y;r.atlas.row_height=0
    r.atlas.reset_pending=false;r.atlas.dirty=true
}
renderer_font_accept :: proc(r:^Renderer,atlas:^Font_Atlas) {
    renderer_font_dispose(&r.atlas)
    r.atlas=atlas^
    atlas^={}
}

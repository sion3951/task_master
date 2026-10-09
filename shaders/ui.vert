#version 450
layout(location=0) in vec2 position;
layout(location=1) in vec2 uv;
layout(location=2) in vec4 color;
layout(location=3) in vec2 stroke;
layout(location=4) in vec2 clip_x;
layout(location=0) out vec2 frag_uv;
layout(location=1) out vec4 frag_color;
layout(location=2) flat out vec2 frag_stroke;
layout(location=3) flat out vec2 frag_clip_x;
layout(push_constant) uniform Viewport { vec2 extent; } view;
void main(){ gl_Position=vec4(position / view.extent * 2.0 - 1.0,0,1); frag_uv=uv; frag_color=color; frag_stroke=stroke; frag_clip_x=clip_x; }

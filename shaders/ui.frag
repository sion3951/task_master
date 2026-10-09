#version 450
layout(location=0) in vec2 frag_uv;
layout(location=1) in vec4 frag_color;
layout(location=2) flat in vec2 frag_stroke;
layout(location=3) flat in vec2 frag_clip_x;
layout(location=0) out vec4 output_color;
layout(binding=0) uniform sampler2D atlas;
void main(){
    if (frag_clip_x.y > frag_clip_x.x &&
        (gl_FragCoord.x < frag_clip_x.x || gl_FragCoord.x >= frag_clip_x.y)) discard;
    if (frag_stroke.x < 0.0) {
        // One gradient spans the full graph; its geometry is clipped by the
        // trace. A dip changes only the cutoff, never the gradient beneath it.
        float height = clamp(frag_uv.y,0.0,1.0);
        vec3 tint = frag_color.rgb;
        if (frag_stroke.x == -1.0) {
            float value = clamp(frag_uv.x,0.0,1.0);
            vec3 green = vec3(0.43,0.83,0.64);
            vec3 amber = vec3(0.96,0.72,0.39);
            vec3 red = vec3(0.96,0.36,0.36);
            tint = value <= 0.5 ? mix(green,amber,value*2.0)
                                : mix(amber,red,(value-0.5)*2.0);
        }
        output_color = vec4(tint,frag_color.a*mix(0.03,0.08,height));
        return;
    }
    float coverage;
    if (frag_stroke.x > 0.0) {
        // Distance to a finite segment gives smooth edges and round joins/caps.
        // All quantities use framebuffer pixels, including fractional DPI.
        vec2 nearest = vec2(clamp(frag_uv.x,0.0,frag_stroke.y),0.0);
        float distance = length(frag_uv-nearest)-frag_stroke.x;
        coverage = clamp(0.5-distance,0.0,1.0);
    } else {
        coverage = texture(atlas,frag_uv).r;
    }
    output_color = vec4(frag_color.rgb,frag_color.a*coverage);
}

#version 450

layout(set = 0, binding = 0) uniform sampler2D atlas;

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;

layout(location = 0) out vec4 out_color;

void main() {
    float coverage = texture(atlas, v_uv).r;
    out_color = vec4(v_color.rgb, v_color.a * coverage);
}

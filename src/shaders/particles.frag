#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;

layout(location = 0) out vec4 out_color;

void main() {
    float d = length(v_uv);
    if (d > 1.0) discard;

    out_color = vec4(v_color.rgb, v_color.a * (1.0 - d * d));
}

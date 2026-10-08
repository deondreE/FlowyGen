#version 450

layout(push_constant) uniform Screen {
    vec2 size; // framebuffer size in pixels
} screen;

layout(location = 0) in vec2 in_pos; // pixels, origin top-left
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_color;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;

void main() {
    vec2 ndc = in_pos / screen.size * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_uv = in_uv;
    v_color = in_color;
}

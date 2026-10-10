#version 450
layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec3 in_color;

layout(location = 0) out vec3 v_normal;
layout(location = 1) out vec3 v_color;
layout(location = 2) out vec3 v_world_pos;

void main() {
    vec3 world_pos = in_pos * 0.5;
    v_world_pos = world_pos;
    v_normal = in_normal;
    v_color = in_color;
    gl_Position = vec4(world_pos, 1.0);
}
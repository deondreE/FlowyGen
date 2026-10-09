#version 450

// Vertex pulling: no vertex buffer. Each particle is 6 vertices (2 triangles)
// and we read the particle straight from the storage buffer. This avoids
// gl_PointSize, which needs the largePoints device feature for sizes != 1.

struct Particle {
    vec2 pos;
    vec2 vel;
    float age;
    float lifetime;
};

layout(std430, set = 0, binding = 0) readonly buffer Particles {
    Particle particles[];
};

layout(push_constant) uniform Push {
    vec2 half_size; // quad half extent in clip space (already aspect-corrected)
} pc;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;

const vec2 corners[6] = vec2[](
    vec2(-1.0, -1.0), vec2( 1.0, -1.0), vec2( 1.0,  1.0),
    vec2(-1.0, -1.0), vec2( 1.0,  1.0), vec2(-1.0,  1.0)
);

void main() {
    uint id = uint(gl_VertexIndex) / 6u;
    vec2 corner = corners[uint(gl_VertexIndex) % 6u];

    Particle p = particles[id];
    float t = p.age / p.lifetime;

    // Waiting or dead: collapse to a point outside clip space.
    if (p.age < 0.0 || t >= 1.0) {
        gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
        v_uv = vec2(0.0);
        v_color = vec4(0.0);
        return;
    }

    vec3 hot = vec3(1.0, 0.85, 0.40);
    vec3 cool = vec3(0.90, 0.20, 0.05);

    v_uv = corner;
    v_color = vec4(mix(hot, cool, smoothstep(0.0, 1.0, t)), (1.0 - t) * 0.35);
    gl_Position = vec4(p.pos + corner * pc.half_size, 0.0, 1.0);
}

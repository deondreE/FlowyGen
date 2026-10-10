#version 450

// Vertex pulling, same idea as particles.vert: 6 vertices per particle, read
// straight from the simulation buffer. Pair with particles.frag.

struct Particle {
    vec2 pos; // grid cells
    vec2 vel; // cells/second
};

layout(std430, set = 0, binding = 0) readonly buffer Particles {
    Particle particles[];
};

layout(push_constant) uniform Push {
    vec2 grid;      // domain size in cells
    vec2 fit;       // clip-space scale that letterboxes the domain
    vec2 half_size; // quad half extent in clip space
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

    // Cells -> [-1,1]. +y is down in both, so no flip.
    vec2 ndc = (p.pos / pc.grid * 2.0 - 1.0) * pc.fit;

    float speed = smoothstep(0.0, 80.0, length(p.vel));
    vec3 deep = vec3(0.05, 0.30, 0.90);
    vec3 foam = vec3(0.75, 0.92, 1.00);

    v_uv = corner;
    v_color = vec4(mix(deep, foam, speed), 0.10);
    gl_Position = vec4(ndc + corner * pc.half_size, 0.0, 1.0);
}

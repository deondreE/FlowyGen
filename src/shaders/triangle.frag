#version 450
layout(location = 0) in vec3 v_normal;
layout(location = 1) in vec3 v_color;
layout(location = 2) in vec3 v_world_pos;

layout(location = 0) out vec4 out_color;

const vec3 lightPos = vec3(2.0, 2.0, 3.0);
const vec3 lightColor = vec3(1.0, 0.95, 0.9);

void main() {
    float ambientStrength = 0.15;
    vec3 ambient = ambientStrength * lightColor;
    
    vec3 norm = normalize(v_normal);
    vec3 lightDir = normalize(lightPos - v_world_pos);
    float diff = max(dot(norm, lightDir), 0.0);
    vec3 diffuse = diff * lightColor;
    
    vec3 result = (ambient + diffuse) * v_color;
    out_color = vec4(result, 1.0);
}
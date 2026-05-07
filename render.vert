#version 460
layout(location = 0) in vec4 inPosition;
layout(push_constant) uniform CameraInfo { mat4 viewProj; } pc;

layout(location = 0) out flat int vThreadID;
layout(location = 1) out float vDiffuse;
layout(location = 2) out vec3 vBaseColor; // Pass the random color!

const float size = 128.0; 
const vec3 corners[6] = vec3[](
    vec3(0.0, size, 0.0), vec3(0.0, -size, 0.0), vec3(size, 0.0, 0.0), 
    vec3(0.0, 0.0, size), vec3(-size, 0.0, 0.0), vec3(0.0, 0.0, -size)
);
const int lut[24] = int[](
    0, 2, 3,  0, 3, 4,  0, 4, 5,  0, 5, 2, 
    1, 3, 2,  1, 4, 3,  1, 5, 4,  1, 2, 5
);
const vec3 baseColors[3] = vec3[](
    vec3(0.2, 1.0, 0.5), vec3(0.2, 0.5, 1.0), vec3(1.0, 0.2, 0.5)
);

void main() {
    vThreadID = int(inPosition.w);
    vBaseColor = baseColors[gl_InstanceIndex % 3]; // The organic diverse color!

    int cornerIndex = lut[gl_VertexIndex % 24];
    int faceIndex = (gl_VertexIndex % 24) / 3;

    int i0 = lut[faceIndex * 3 + 0];
    int i1 = lut[faceIndex * 3 + 1];
    int i2 = lut[faceIndex * 3 + 2];
    vec3 faceNormal = normalize(cross(corners[i1] - corners[i0], corners[i2] - corners[i0]));

    vec3 worldPos = inPosition.xyz + corners[cornerIndex];
    gl_Position = pc.viewProj * vec4(worldPos, 1.0);

    vec3 lightDir = normalize(vec3(0.5, 1.0, -0.8));
    vDiffuse = max(dot(faceNormal, lightDir), 0.2);
}

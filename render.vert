#version 460

layout(location = 0) in vec4 inPosition; // (x, y, z, CPU_Thread_ID)

layout(push_constant) uniform CameraInfo {
    mat4 viewProj;
} pc;

layout(location = 0) out flat int vThreadID;
layout(location = 1) out float vDiffuse;

const float size = 48.0; 

// 6 Vertices for an Octahedron (Quantum Crystal)
const vec3 corners[6] = vec3[](
    vec3( 0.0,  size,  0.0), // 0: Top
    vec3( 0.0, -size,  0.0), // 1: Bottom
    vec3( size,  0.0,  0.0), // 2: Right
    vec3( 0.0,  0.0,  size), // 3: Front
    vec3(-size,  0.0,  0.0), // 4: Left
    vec3( 0.0,  0.0, -size)  // 5: Back
);

// 8 Faces (24 indices total)
const int lut[24] = int[](
    // Top Pyramid
    0, 2, 3,
    0, 3, 4,
    0, 4, 5,
    0, 5, 2,
    // Bottom Pyramid
    1, 3, 2,
    1, 4, 3,
    1, 5, 4,
    1, 2, 5
);

// We dynamically calculate normals now instead of hardcoding them!
vec3 getNormal(int faceIndex) {
    int i0 = lut[faceIndex * 3 + 0];
    int i1 = lut[faceIndex * 3 + 1];
    int i2 = lut[faceIndex * 3 + 2];
    vec3 p0 = corners[i0];
    vec3 p1 = corners[i1];
    vec3 p2 = corners[i2];
    return normalize(cross(p1 - p0, p2 - p0));
}

void main() {
    vThreadID = int(inPosition.w);

    // Dynamic array mapping based on our 24-vertex mesh
    int cornerIndex = lut[gl_VertexIndex % 24];
    int faceIndex = (gl_VertexIndex % 24) / 3;

    vec3 localPos = corners[cornerIndex];
    vec3 faceNormal = getNormal(faceIndex);

    vec3 worldPos = inPosition.xyz + localPos;
    gl_Position = pc.viewProj * vec4(worldPos, 1.0);

    // Fake Sun Lighting
    vec3 lightDir = normalize(vec3(0.5, 1.0, -0.8));
    vDiffuse = max(dot(faceNormal, lightDir), 0.2);
}

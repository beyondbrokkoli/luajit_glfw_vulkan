#version 460

layout(location = 0) in vec4 inPosition; // Swarm Particle Center (x, y, z, padding)

layout(push_constant) uniform CameraInfo {
    mat4 viewProj;
} pc;

layout(location = 0) out vec3 fragColor;

// 1. Define the 4 corners of the Tetrahedron
const float size = 64.0; // How big the particles are
const vec3 corners[4] = vec3[](
    vec3(0.0, size, 0.0),      // 0: Top
    vec3(-size, -size, size),  // 1: Bottom Left Front
    vec3(size, -size, size),   // 2: Bottom Right Front
    vec3(0.0, -size, -size)    // 3: Bottom Back
);

// 2. The Index Map: 12 vertices to make 4 triangles
const int lut[12] = int[](
    0, 1, 2, // Face 0 (Front)
    0, 2, 3, // Face 1 (Right)
    0, 3, 1, // Face 2 (Left)
    1, 3, 2  // Face 3 (Bottom)
);

// 3. Hardcoded Face Normals (For fake lighting!)
// Pre-calculated orthogonal vectors pointing OUT of each of the 4 faces
const vec3 normals[4] = vec3[](
    normalize(cross(corners[1] - corners[0], corners[2] - corners[0])),
    normalize(cross(corners[2] - corners[0], corners[3] - corners[0])),
    normalize(cross(corners[3] - corners[0], corners[1] - corners[0])),
    normalize(cross(corners[3] - corners[1], corners[2] - corners[1]))
);

// Base colors based on particle ID
const vec3 baseColors[3] = vec3[](
    vec3(0.2, 1.0, 0.5), // Mint Green
    vec3(0.2, 0.5, 1.0), // Ocean Blue
    vec3(1.0, 0.2, 0.5)  // Pinkish Red
);

void main() {
    // Determine which corner (0-3) and which face (0-3) we are drawing
    int cornerIndex = lut[gl_VertexIndex % 12];
    int faceIndex = (gl_VertexIndex % 12) / 3;

    // Grab local offset and face normal
    vec3 localPos = corners[cornerIndex];
    vec3 faceNormal = normals[faceIndex];

    // Project to screen
    vec3 worldPos = inPosition.xyz + localPos;
    gl_Position = pc.viewProj * vec4(worldPos, 1.0);

    // --- FAKE LIGHTING ---
    vec3 lightDir = normalize(vec3(0.5, 1.0, -0.8)); // Sun shining from top-right-front
    
    // N dot L (How directly is the light hitting this face?)
    // Max(0) prevents negative light on the dark side
    float diffuse = max(dot(faceNormal, lightDir), 0.2); // 0.2 is ambient ambient shadow

    // Pick a pseudo-random color based on the Particle ID (gl_InstanceIndex)
    vec3 rawColor = baseColors[gl_InstanceIndex % 3];

    // Multiply the color by the lighting!
    fragColor = rawColor * diffuse;
}

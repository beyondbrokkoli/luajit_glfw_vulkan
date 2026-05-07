#version 460

// These MUST exactly match the "out" variables in render.vert!
layout(location = 0) flat in int vThreadID;
layout(location = 1) in float vDiffuse;

layout(location = 0) out vec4 outColor;

void main() {
    vec3 rawColor;

    // The Heterogeneous Visualizer Matrix!
    switch(vThreadID) {
        // --- CPU THREADS (AVX2) ---
        case 0:  rawColor = vec3(1.0, 0.2, 0.2); break; // Red (Core 0)
        case 1:  rawColor = vec3(0.2, 1.0, 0.2); break; // Green (Core 1)
        case 2:  rawColor = vec3(0.2, 0.5, 1.0); break; // Blue (Core 2)
        case 3:  rawColor = vec3(1.0, 1.0, 0.2); break; // Yellow (Core 3)
        
        // --- GPU COMPUTE OVERRIDES ---
        case 5:  rawColor = vec3(1.0, 0.0, 1.0); break; // Purple (GPU Pull)
        case 6:  rawColor = vec3(0.0, 1.0, 1.0); break; // Cyan (GPU Push)
        
        default: rawColor = vec3(1.0, 1.0, 1.0); break; // White (Fallback)
    }

    // Apply the faux-3D lighting we calculated in the Vertex Shader
    outColor = vec4(rawColor * vDiffuse, 1.0);
}

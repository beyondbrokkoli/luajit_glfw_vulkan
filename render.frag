#version 460
layout(location = 0) flat in int vThreadID;
layout(location = 1) in float vDiffuse;
layout(location = 2) in vec3 vBaseColor;

layout(location = 0) out vec4 outColor;

void main() {
    vec3 finalColor = vBaseColor;

    // TINT the particle based on the AVX2 Thread that calculated it
    if (vThreadID == 0) finalColor *= vec3(1.5, 0.5, 0.5); // Thread 0: Warmer
    if (vThreadID == 1) finalColor *= vec3(0.5, 1.5, 0.5); // Thread 1: Greener
    if (vThreadID == 2) finalColor *= vec3(0.5, 0.5, 1.5); // Thread 2: Bluer
    if (vThreadID == 3) finalColor *= vec3(1.5, 1.5, 0.5); // Thread 3: Yellower

    // Overrides for the GPU Intercept (Mouse Clicks)
    if (vThreadID == 5) finalColor = vec3(1.0, 0.0, 1.0); // Purple Pull
    if (vThreadID == 6) finalColor = vec3(0.0, 1.0, 1.0); // Cyan Push

    outColor = vec4(finalColor * vDiffuse, 1.0);
}

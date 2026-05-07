#version 460
layout(location = 0) flat in int vThreadID;
layout(location = 1) in float vDiffuse;
layout(location = 2) in vec3 vBaseColor;

layout(location = 0) out vec4 outColor;

void main() {
    vec3 finalColor = vBaseColor;

    // THE CATPPUCCIN MOCHA PALETTE (Modern Linux WM Theme)
    // Tinting the soft pastel base colors with bold thread identifiers
    if (vThreadID == 0) finalColor *= vec3(0.80, 0.65, 0.97); // Mauve (Purple)
    if (vThreadID == 1) finalColor *= vec3(0.45, 0.78, 0.92); // Sapphire (Blue)
    if (vThreadID == 2) finalColor *= vec3(0.65, 0.89, 0.63); // Green (Mint)
    if (vThreadID == 3) finalColor *= vec3(0.98, 0.70, 0.53); // Peach (Orange)

    // Apply the faux-3D lighting we calculated in the Vertex Shader
    outColor = vec4(finalColor * vDiffuse, 1.0);
}

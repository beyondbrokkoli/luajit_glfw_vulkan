#version 460

// MUST match the output of your new render.vert perfectly
layout(location = 0) in vec3 fragColor; 

layout(location = 0) out vec4 outColor;

void main() {
    // We configured additive blending in Lua, so we just output the raw color!
    outColor = vec4(fragColor, 1.0);
}

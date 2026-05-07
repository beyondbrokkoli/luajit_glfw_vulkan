local ffi = require("ffi")
local bit = require("bit")

local GraphicsPipeline = {}

-- Helper function to read the raw binary SPIR-V files
local function ReadShaderFile(filename)
    local file = io.open(filename, "rb")
    assert(file, "FATAL: Failed to open shader file: " .. filename)
    local content = file:read("*a")
    file:close()
    return content
end

function GraphicsPipeline.Init(vk, core_state, width, height)
    print("[GRAPHICS] Building Depth Buffer and Shader Modules...")

    local device = core_state.device
    local physDevice = core_state.physicalDevice

    -- ========================================================
    -- 1. Create Depth Image (The Z-Buffer)
    -- ========================================================
    local dImgInfo = ffi.new("VkImageCreateInfo")
    ffi.fill(dImgInfo, ffi.sizeof(dImgInfo))
    dImgInfo.sType = 14 -- VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
    dImgInfo.imageType = 1 -- VK_IMAGE_TYPE_2D
    dImgInfo.extent.width = width
    dImgInfo.extent.height = height
    dImgInfo.extent.depth = 1
    dImgInfo.mipLevels = 1
    dImgInfo.arrayLayers = 1
    dImgInfo.format = 126 -- VK_FORMAT_D32_SFLOAT
    dImgInfo.tiling = 0 -- VK_IMAGE_TILING_OPTIMAL
    dImgInfo.initialLayout = 0 -- VK_IMAGE_LAYOUT_UNDEFINED
    dImgInfo.usage = 32 -- VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT
    dImgInfo.samples = 1 -- VK_SAMPLE_COUNT_1_BIT

    local pDepthImage = ffi.new("VkImage[1]")
    assert(vk.vkCreateImage(device, dImgInfo, nil, pDepthImage) == 0)
    local depthImage = pDepthImage[0]

    -- ========================================================
    -- 2. Allocate VRAM for the Depth Image
    -- ========================================================
    local memReqs = ffi.new("VkMemoryRequirements")
    vk.vkGetImageMemoryRequirements(device, depthImage, memReqs)

    local memProperties = ffi.new("VkPhysicalDeviceMemoryProperties")
    vk.vkGetPhysicalDeviceMemoryProperties(physDevice, memProperties)

    -- Find VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT (1)
    local memoryTypeIndex = -1
    for i = 0, memProperties.memoryTypeCount - 1 do
        local isTypeSupported = bit.band(memReqs.memoryTypeBits, bit.lshift(1, i)) ~= 0
        local isVRAM = bit.band(memProperties.memoryTypes[i].propertyFlags, 1) ~= 0
        if isTypeSupported and isVRAM then
            memoryTypeIndex = i
            break
        end
    end
    assert(memoryTypeIndex ~= -1, "FATAL: Could not find VRAM for Depth Buffer!")

    local dAllocInfo = ffi.new("VkMemoryAllocateInfo")
    ffi.fill(dAllocInfo, ffi.sizeof(dAllocInfo))
    dAllocInfo.sType = 5 -- VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
    dAllocInfo.allocationSize = memReqs.size
    dAllocInfo.memoryTypeIndex = memoryTypeIndex

    local pDepthMemory = ffi.new("VkDeviceMemory[1]")
    assert(vk.vkAllocateMemory(device, dAllocInfo, nil, pDepthMemory) == 0)
    local depthMemory = pDepthMemory[0]

    -- Bind memory to image
    assert(vk.vkBindImageMemory(device, depthImage, depthMemory, 0) == 0)

    -- ========================================================
    -- 3. Create the Depth Image View
    -- ========================================================
    local dViewInfo = ffi.new("VkImageViewCreateInfo")
    ffi.fill(dViewInfo, ffi.sizeof(dViewInfo))
    dViewInfo.sType = 15 -- VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
    dViewInfo.image = depthImage
    dViewInfo.viewType = 1 -- VK_IMAGE_VIEW_TYPE_2D
    dViewInfo.format = 126 -- VK_FORMAT_D32_SFLOAT
    dViewInfo.subresourceRange.aspectMask = 2 -- VK_IMAGE_ASPECT_DEPTH_BIT
    dViewInfo.subresourceRange.levelCount = 1
    dViewInfo.subresourceRange.layerCount = 1

    local pDepthView = ffi.new("VkImageView[1]")
    assert(vk.vkCreateImageView(device, dViewInfo, nil, pDepthView) == 0)
    local depthImageView = pDepthView[0]

    -- ========================================================
    -- 4. Load Shader Modules
    -- ========================================================
    -- Read the binary files
    local vertCode = ReadShaderFile("render_vert.spv")
    local fragCode = ReadShaderFile("render_frag.spv")

    -- To pass a Lua string as a raw byte array to C, we cast it to a const uint32_t pointer
    local vertCodePtr = ffi.cast("const uint32_t*", vertCode)
    local fragCodePtr = ffi.cast("const uint32_t*", fragCode)

    local vertInfo = ffi.new("VkShaderModuleCreateInfo")
    ffi.fill(vertInfo, ffi.sizeof(vertInfo))
    vertInfo.sType = 16 -- VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
    vertInfo.codeSize = string.len(vertCode)
    vertInfo.pCode = vertCodePtr

    local fragInfo = ffi.new("VkShaderModuleCreateInfo")
    ffi.fill(fragInfo, ffi.sizeof(fragInfo))
    fragInfo.sType = 16
    fragInfo.codeSize = string.len(fragCode)
    fragInfo.pCode = fragCodePtr

    local pVertModule = ffi.new("VkShaderModule[1]")
    local pFragModule = ffi.new("VkShaderModule[1]")

    assert(vk.vkCreateShaderModule(device, vertInfo, nil, pVertModule) == 0)
    assert(vk.vkCreateShaderModule(device, fragInfo, nil, pFragModule) == 0)

    print("[GRAPHICS] Depth Buffer and Shader Modules Ready.")
    -- ========================================================
    -- 5. SHADER STAGES
    -- ========================================================
    local shaderStages = ffi.new("VkPipelineShaderStageCreateInfo[2]")
    ffi.fill(shaderStages, ffi.sizeof(shaderStages))

    shaderStages[0].sType = 18 -- VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
    shaderStages[0].stage = 1 -- VK_SHADER_STAGE_VERTEX_BIT
    shaderStages[0].module = pVertModule[0]
    shaderStages[0].pName = "main"

    shaderStages[1].sType = 18
    shaderStages[1].stage = 16 -- VK_SHADER_STAGE_FRAGMENT_BIT
    shaderStages[1].module = pFragModule[0]
    shaderStages[1].pName = "main"

    -- ========================================================
    -- 6. VERTEX INPUT (Instanced Rendering of the Swarm!)
    -- ========================================================
    local bindingDesc = ffi.new("VkVertexInputBindingDescription[1]")
    ffi.fill(bindingDesc, ffi.sizeof(bindingDesc))
    bindingDesc[0].binding = 0
    bindingDesc[0].stride = 16 -- sizeof(GPU_VertexAoS) is 16 bytes (x, y, z, padding)
    bindingDesc[0].inputRate = 1 -- VK_VERTEX_INPUT_RATE_INSTANCE

    local attrDesc = ffi.new("VkVertexInputAttributeDescription[1]")
    ffi.fill(attrDesc, ffi.sizeof(attrDesc))
    attrDesc[0].binding = 0
    attrDesc[0].location = 0
    attrDesc[0].format = 106 -- VK_FORMAT_R32G32B32A32_SFLOAT
    attrDesc[0].offset = 0

    local vertexInputInfo = ffi.new("VkPipelineVertexInputStateCreateInfo")
    ffi.fill(vertexInputInfo, ffi.sizeof(vertexInputInfo))
    vertexInputInfo.sType = 19 -- VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
    vertexInputInfo.vertexBindingDescriptionCount = 1
    vertexInputInfo.pVertexBindingDescriptions = bindingDesc
    vertexInputInfo.vertexAttributeDescriptionCount = 1
    vertexInputInfo.pVertexAttributeDescriptions = attrDesc

    -- ========================================================
    -- 7. FIXED FUNCTION STATES
    -- ========================================================
    local inputAssembly = ffi.new("VkPipelineInputAssemblyStateCreateInfo")
    ffi.fill(inputAssembly, ffi.sizeof(inputAssembly))
    inputAssembly.sType = 20
    inputAssembly.topology = 3 -- VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST

    -- 1. Bake the Viewport dimensions natively
    local pViewports = ffi.new("VkViewport[1]")
    pViewports[0].x = 0.0
    pViewports[0].y = 0.0
    pViewports[0].width = width
    pViewports[0].height = height
    pViewports[0].minDepth = 0.0
    pViewports[0].maxDepth = 1.0

    -- 2. Bake the Scissor rectangle natively
    local pScissors = ffi.new("VkRect2D[1]")
    pScissors[0].offset.x = 0
    pScissors[0].offset.y = 0
    pScissors[0].extent.width = width
    pScissors[0].extent.height = height

    local viewportState = ffi.new("VkPipelineViewportStateCreateInfo")
    ffi.fill(viewportState, ffi.sizeof(viewportState))
    viewportState.sType = 22
    viewportState.viewportCount = 1
    viewportState.pViewports = pViewports
    viewportState.scissorCount = 1
    viewportState.pScissors = pScissors

    local rasterizer = ffi.new("VkPipelineRasterizationStateCreateInfo")
    ffi.fill(rasterizer, ffi.sizeof(rasterizer))
    rasterizer.sType = 23
    rasterizer.polygonMode = 0 -- VK_POLYGON_MODE_FILL
    rasterizer.lineWidth = 1.0
    rasterizer.cullMode = 2 -- VK_CULL_MODE_BACK_BIT
    rasterizer.cullMode = 0
    rasterizer.frontFace = 0 -- VK_FRONT_FACE_COUNTER_CLOCKWISE

    local multisampling = ffi.new("VkPipelineMultisampleStateCreateInfo")
    ffi.fill(multisampling, ffi.sizeof(multisampling))
    multisampling.sType = 24
    multisampling.rasterizationSamples = 1

    local depthStencil = ffi.new("VkPipelineDepthStencilStateCreateInfo")
    ffi.fill(depthStencil, ffi.sizeof(depthStencil))
    depthStencil.sType = 25
    depthStencil.depthTestEnable = 1 -- VK_TRUE
    depthStencil.depthWriteEnable = 1 -- VK_TRUE
    depthStencil.depthCompareOp = 4 -- VK_COMPARE_OP_GREATER (Reverse-Z!)

    local colorBlendAttachment = ffi.new("VkPipelineColorBlendAttachmentState[1]")
    ffi.fill(colorBlendAttachment, ffi.sizeof(colorBlendAttachment))
    colorBlendAttachment[0].colorWriteMask = 15 -- R|G|B|A
    colorBlendAttachment[0].blendEnable = 1 -- VK_TRUE
    colorBlendAttachment[0].srcColorBlendFactor = 6 -- SRC_ALPHA
    colorBlendAttachment[0].dstColorBlendFactor = 1 -- ONE
    colorBlendAttachment[0].colorBlendOp = 0 -- ADD
    colorBlendAttachment[0].srcAlphaBlendFactor = 1 -- ONE
    colorBlendAttachment[0].dstAlphaBlendFactor = 0 -- ZERO
    colorBlendAttachment[0].alphaBlendOp = 0 -- ADD

    local colorBlending = ffi.new("VkPipelineColorBlendStateCreateInfo")
    ffi.fill(colorBlending, ffi.sizeof(colorBlending))
    colorBlending.sType = 26
    colorBlending.attachmentCount = 1
    colorBlending.pAttachments = colorBlendAttachment

    -- ========================================================
    -- 8. PIPELINE LAYOUT & PUSH CONSTANTS (The Bridge)
    -- ========================================================
    local pushRange = ffi.new("VkPushConstantRange[1]")
    ffi.fill(pushRange, ffi.sizeof(pushRange))
    pushRange[0].stageFlags = 1 -- VK_SHADER_STAGE_VERTEX_BIT
    pushRange[0].offset = 0
    pushRange[0].size = 64 -- sizeof(float) * 16 (Camera ViewProj Matrix)

    local layoutInfo = ffi.new("VkPipelineLayoutCreateInfo")
    ffi.fill(layoutInfo, ffi.sizeof(layoutInfo))
    layoutInfo.sType = 30
    layoutInfo.pushConstantRangeCount = 1
    layoutInfo.pPushConstantRanges = pushRange

    local pPipelineLayout = ffi.new("VkPipelineLayout[1]")
    assert(vk.vkCreatePipelineLayout(device, layoutInfo, nil, pPipelineLayout) == 0)

    -- ========================================================
    -- 9. DYNAMIC RENDERING LINK & FINAL BUILD
    -- ========================================================
    local colorFormats = ffi.new("int32_t[1]", {50}) -- VK_FORMAT_B8G8R8A8_SRGB

    -- [NEW] The Ghost Buster: Tell Vulkan we will resize things later
    local dynamicStates = ffi.new("int32_t[2]", {
        0, -- VK_DYNAMIC_STATE_VIEWPORT
        1  -- VK_DYNAMIC_STATE_SCISSOR
    })

    local dynamicStateInfo = ffi.new("VkPipelineDynamicStateCreateInfo", {
        sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        dynamicStateCount = 2,
        pDynamicStates = dynamicStates
    })

    local pipelineRenderingInfo = ffi.new("VkPipelineRenderingCreateInfo")
    ffi.fill(pipelineRenderingInfo, ffi.sizeof(pipelineRenderingInfo))
    pipelineRenderingInfo.sType = 1000044002 -- VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO
    pipelineRenderingInfo.colorAttachmentCount = 1
    pipelineRenderingInfo.pColorAttachmentFormats = colorFormats
    pipelineRenderingInfo.depthAttachmentFormat = 126 -- VK_FORMAT_D32_SFLOAT

    local pipelineInfo = ffi.new("VkGraphicsPipelineCreateInfo[1]")
    ffi.fill(pipelineInfo, ffi.sizeof(pipelineInfo))
    pipelineInfo[0].sType = 28
    pipelineInfo[0].pNext = pipelineRenderingInfo
    pipelineInfo[0].stageCount = 2
    pipelineInfo[0].pStages = shaderStages
    pipelineInfo[0].pVertexInputState = vertexInputInfo
    pipelineInfo[0].pInputAssemblyState = inputAssembly
    pipelineInfo[0].pViewportState = viewportState
    pipelineInfo[0].pRasterizationState = rasterizer
    pipelineInfo[0].pMultisampleState = multisampling
    pipelineInfo[0].pDepthStencilState = depthStencil
    pipelineInfo[0].pColorBlendState = colorBlending

    pipelineInfo[0].pDynamicState = dynamicStateInfo -- <--- THE PATCH! No more nil!
    pipelineInfo[0].layout = pPipelineLayout[0]

    local pPipeline = ffi.new("VkPipeline[1]")
    assert(vk.vkCreateGraphicsPipelines(device, nil, 1, pipelineInfo, nil, pPipeline) == 0)

    print("[GRAPHICS] Graphics Pipeline Successfully Compiled!")

    return {
        depthImage = depthImage,
        depthMemory = depthMemory,
        depthImageView = depthImageView,
        vertModule = pVertModule[0],
        fragModule = pFragModule[0],
        pipelineLayout = pPipelineLayout[0],
        pipeline = pPipeline[0]
    }
end
function GraphicsPipeline.Destroy(vk, core_state, gfx_state)
    print("[TEARDOWN] Destroying Graphics Pipeline & Depth Buffer...")
    if not gfx_state then return end

    -- If core_state is a table, get .device. If it's already a cdata pointer, use it.
    local device = type(core_state) == "table" and core_state.device or core_state

    vk.vkDestroyPipeline(device, gfx_state.pipeline, nil)
    vk.vkDestroyPipelineLayout(device, gfx_state.pipelineLayout, nil)
    vk.vkDestroyShaderModule(device, gfx_state.vertModule, nil)
    vk.vkDestroyShaderModule(device, gfx_state.fragModule, nil)

    vk.vkDestroyImageView(device, gfx_state.depthImageView, nil)
    vk.vkDestroyImage(device, gfx_state.depthImage, nil)
    vk.vkFreeMemory(device, gfx_state.depthMemory, nil)
end
return GraphicsPipeline

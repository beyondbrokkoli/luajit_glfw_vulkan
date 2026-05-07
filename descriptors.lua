local ffi = require("ffi")

local Descriptors = {}

function Descriptors.Init(vk, device, bufA, bufB)
    print("[DESCRIPTORS] Wiring Ping-Pong Compute Descriptors...")

    -- ========================================================
    -- 1. The Descriptor Set Layout (Binding 0 = Read, Binding 1 = Write)
    -- ========================================================
    local ssboBindings = ffi.new("VkDescriptorSetLayoutBinding[2]")
    ffi.fill(ssboBindings, ffi.sizeof(ssboBindings))
    
    ssboBindings[0].binding = 0
    ssboBindings[0].descriptorType = 7 -- VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
    ssboBindings[0].descriptorCount = 1
    ssboBindings[0].stageFlags = 32 -- VK_SHADER_STAGE_COMPUTE_BIT

    ssboBindings[1].binding = 1
    ssboBindings[1].descriptorType = 7
    ssboBindings[1].descriptorCount = 1
    ssboBindings[1].stageFlags = 32

    local layoutInfo = ffi.new("VkDescriptorSetLayoutCreateInfo")
    ffi.fill(layoutInfo, ffi.sizeof(layoutInfo))
    layoutInfo.sType = 32 -- VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
    layoutInfo.bindingCount = 2
    layoutInfo.pBindings = ssboBindings

    local pLayout = ffi.new("VkDescriptorSetLayout[1]")
    assert(vk.vkCreateDescriptorSetLayout(device, layoutInfo, nil, pLayout) == 0)
    local computeDescriptorSetLayout = pLayout[0]

    -- ========================================================
    -- 2. Push Constants (dt, time, state)
    -- ========================================================
    local computePushRange = ffi.new("VkPushConstantRange[1]")
    ffi.fill(computePushRange, ffi.sizeof(computePushRange))
    computePushRange[0].stageFlags = 32 -- VK_SHADER_STAGE_COMPUTE_BIT
    computePushRange[0].offset = 0
    computePushRange[0].size = 12 -- sizeof(float)*2 + sizeof(int)

    -- ========================================================
    -- 3. Pipeline Layout
    -- ========================================================
    local computeLayoutInfo = ffi.new("VkPipelineLayoutCreateInfo")
    ffi.fill(computeLayoutInfo, ffi.sizeof(computeLayoutInfo))
    computeLayoutInfo.sType = 30 -- VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
    computeLayoutInfo.setLayoutCount = 1
    
    local pSetLayouts = ffi.new("VkDescriptorSetLayout[1]", {computeDescriptorSetLayout})
    computeLayoutInfo.pSetLayouts = pSetLayouts
    computeLayoutInfo.pushConstantRangeCount = 1
    computeLayoutInfo.pPushConstantRanges = computePushRange

    local pPipeLayout = ffi.new("VkPipelineLayout[1]")
    assert(vk.vkCreatePipelineLayout(device, computeLayoutInfo, nil, pPipeLayout) == 0)
    local computePipelineLayout = pPipeLayout[0]

    -- ========================================================
    -- 4. Descriptor Pool
    -- ========================================================
    local poolSize = ffi.new("VkDescriptorPoolSize[1]")
    ffi.fill(poolSize, ffi.sizeof(poolSize))
    poolSize[0].type = 7 -- VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
    poolSize[0].descriptorCount = 4

    local poolInfo = ffi.new("VkDescriptorPoolCreateInfo")
    ffi.fill(poolInfo, ffi.sizeof(poolInfo))
    poolInfo.sType = 33 -- VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
    poolInfo.poolSizeCount = 1
    poolInfo.pPoolSizes = poolSize
    poolInfo.maxSets = 2 -- Two Sets!

    local pPool = ffi.new("VkDescriptorPool[1]")
    assert(vk.vkCreateDescriptorPool(device, poolInfo, nil, pPool) == 0)
    local descriptorPool = pPool[0]

    -- ========================================================
    -- 5. Allocate TWO Descriptor Sets
    -- ========================================================
    local layouts = ffi.new("VkDescriptorSetLayout[2]", {computeDescriptorSetLayout, computeDescriptorSetLayout})
    local allocSetInfo = ffi.new("VkDescriptorSetAllocateInfo")
    ffi.fill(allocSetInfo, ffi.sizeof(allocSetInfo))
    allocSetInfo.sType = 34 -- VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
    allocSetInfo.descriptorPool = descriptorPool
    allocSetInfo.descriptorSetCount = 2
    allocSetInfo.pSetLayouts = layouts

    local pSets = ffi.new("VkDescriptorSet[2]")
    assert(vk.vkAllocateDescriptorSets(device, allocSetInfo, pSets) == 0)

    -- ========================================================
    -- 6. Cross-Wire the Buffers into the Sets
    -- ========================================================
    local VK_WHOLE_SIZE = ffi.cast("uint64_t", -1) -- The LuaJIT way to write ~0ULL

    local bufInfoA = ffi.new("VkDescriptorBufferInfo[1]")
    bufInfoA[0].buffer = bufA
    bufInfoA[0].offset = 0
    bufInfoA[0].range = VK_WHOLE_SIZE

    local bufInfoB = ffi.new("VkDescriptorBufferInfo[1]")
    bufInfoB[0].buffer = bufB
    bufInfoB[0].offset = 0
    bufInfoB[0].range = VK_WHOLE_SIZE

    local writes = ffi.new("VkWriteDescriptorSet[4]")
    ffi.fill(writes, ffi.sizeof(writes))

    -- Set 0: Read A (Binding 0), Write B (Binding 1)
    writes[0].sType = 35 -- VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
    writes[0].dstSet = pSets[0]
    writes[0].dstBinding = 0
    writes[0].descriptorType = 7
    writes[0].descriptorCount = 1
    writes[0].pBufferInfo = bufInfoA

    writes[1].sType = 35
    writes[1].dstSet = pSets[0]
    writes[1].dstBinding = 1
    writes[1].descriptorType = 7
    writes[1].descriptorCount = 1
    writes[1].pBufferInfo = bufInfoB

    -- Set 1: Read B (Binding 0), Write A (Binding 1)
    writes[2].sType = 35
    writes[2].dstSet = pSets[1]
    writes[2].dstBinding = 0
    writes[2].descriptorType = 7
    writes[2].descriptorCount = 1
    writes[2].pBufferInfo = bufInfoB

    writes[3].sType = 35
    writes[3].dstSet = pSets[1]
    writes[3].dstBinding = 1
    writes[3].descriptorType = 7
    writes[3].descriptorCount = 1
    writes[3].pBufferInfo = bufInfoA

    vk.vkUpdateDescriptorSets(device, 4, writes, 0, nil)

    print("[DESCRIPTORS] Ping-Pong Sets successfully wired!")

    return {
        setLayout = computeDescriptorSetLayout,
        pipelineLayout = computePipelineLayout,
        pool = descriptorPool,
        set0 = pSets[0],
        set1 = pSets[1]
    }
end
function Descriptors.Destroy(vk, device, desc_state)
    print("[TEARDOWN] Deconstructing Descriptors...")
    if not desc_state then return end

    -- 1. Destroying the Pool automatically frees all allocated Sets (set0, set1)
    if desc_state.pool ~= nil then
        vk.vkDestroyDescriptorPool(device, desc_state.pool, nil)
    end

    -- 2. Destroy the Descriptor Set Layout
    if desc_state.setLayout ~= nil then
        vk.vkDestroyDescriptorSetLayout(device, desc_state.setLayout, nil)
    end

    -- 3. Destroy the Pipeline Layout (The blueprint for the compute shader)
    if desc_state.pipelineLayout ~= nil then
        vk.vkDestroyPipelineLayout(device, desc_state.pipelineLayout, nil)
    end
end

return Descriptors

-- ========================================================================
-- memory.lua (VibeEngine Hybrid Architecture)
-- Manages both VRAM (Compute) and 64-byte aligned SoA CPU RAM (AVX2)
-- ========================================================================
local ffi = require("ffi")
local bit = require("bit")
local vk = nil 

local Memory = {
    Buffers = {},
    DeviceMemory = {},
    Mapped = {},
    Arrays = {},  -- For CPU SoA
    Anchors = {},  -- GC Lifesavers
    RenderStruct = nil -- <--- ADD THIS SO THE PROXY SEES IT!
}

-- ========================================================================
-- [1] THE UNIVERSE BOUNDARIES
-- ========================================================
local MAX_OBJS = 2500000

-- ========================================================================
-- [2] THE FFI SCHEMA (GPU Structs + CPU Structs + C Signatures)
-- ========================================================================
ffi.cdef[[
    // --- VRAM Structs ---
    typedef struct {
        float minX, minY, minZ; float _pad0;
        float maxX, maxY, maxZ; float _pad1;
        uint32_t isActive;      uint32_t _pad2[3];
    } GPU_GlobalCage;

    typedef struct {
        float x, y, z;
        float padding;
    } GPU_VertexAoS;

    // --- CPU Physics Structs ---
    typedef struct {
        float x, y, z;
        float yaw, pitch;
        float fov;
        float fwx, fwy, fwz;
        float rtx, rty, rtz;
        float upx, upy, upz;
    } CameraState;

    typedef struct {
        float *Obj_X, *Obj_Y, *Obj_Z, *Obj_Radius;
        float *Obj_FWX, *Obj_FWY, *Obj_FWZ;
        float *Obj_RTX, *Obj_RTY, *Obj_RTZ;
        float *Obj_UPX, *Obj_UPY, *Obj_UPZ;

        float *Swarm_PX[2]; float *Swarm_PY[2]; float *Swarm_PZ[2];
        float *Swarm_VX[2]; float *Swarm_VY[2]; float *Swarm_VZ[2];
        int *Swarm_Indices[2];

        float *Swarm_Seed;
        int Swarm_State;
        float Swarm_GravityBlend;
        float Swarm_MetalBlend;
        float Swarm_ParadoxBlend;

        int *Swarm_TempIndices;
        float *Swarm_Distances;
        float *Swarm_TempDistances;
    } RenderMemory;

    // --- AVX2 C-Signatures ---
    void vmath_bind_engine(RenderMemory* mem, CameraState* cam, int* queue);
    void vmath_bind_vulkan_buffers(void* v_buf, void* i_buf);
    void vmath_seed_swarm(int particle_count);
    void vmath_step_swarm(int particle_count, float time, float dt, int state, int push_active, int pull_active);
    void vmath_init_thread_pool();
    void vmath_shutdown_thread_pool();
]]

-- ========================================================================
-- [3] MEMORY ALLOCATORS
-- ========================================================================
Memory.RenderStruct = ffi.new("RenderMemory")
-- A. The Smart VRAM Locator
local function FindSmartBufferMemory(physicalDevice, typeFilter)
    local memProperties = ffi.new("VkPhysicalDeviceMemoryProperties")
    vk.vkGetPhysicalDeviceMemoryProperties(physicalDevice, memProperties)

    local rebarFlags = bit.bor(1, 2, 4) -- DEVICE_LOCAL | HOST_VISIBLE | HOST_COHERENT
    for i = 0, memProperties.memoryTypeCount - 1 do
        local isTypeSupported = bit.band(typeFilter, bit.lshift(1, i)) ~= 0
        local hasProperties = bit.band(memProperties.memoryTypes[i].propertyFlags, rebarFlags) == rebarFlags
        if isTypeSupported and hasProperties then
            print("[MEMORY] ReBAR Supported! Streaming directly to VRAM.")
            return i
        end
    end

    local stdFlags = bit.bor(2, 4) -- HOST_VISIBLE | HOST_COHERENT
    for i = 0, memProperties.memoryTypeCount - 1 do
        local isTypeSupported = bit.band(typeFilter, bit.lshift(1, i)) ~= 0
        local hasProperties = bit.band(memProperties.memoryTypes[i].propertyFlags, stdFlags) == stdFlags
        if isTypeSupported and hasProperties then
            print("[MEMORY] ReBAR NOT found. Falling back to System RAM.")
            return i
        end
    end
    error("FATAL: Failed to find suitable buffer memory!")
end

-- B. The God-Tier Lua VRAM Allocator
function Memory.CreateHostVisibleBuffer(name, cdef_type, element_count, usage_flags, core_state)
    local byte_size = ffi.sizeof(cdef_type) * element_count

    local bufInfo = ffi.new("VkBufferCreateInfo")
    ffi.fill(bufInfo, ffi.sizeof(bufInfo))
    bufInfo.sType = 12 
    bufInfo.size = byte_size
    bufInfo.usage = usage_flags
    bufInfo.sharingMode = 0 

    local pBuffer = ffi.new("VkBuffer[1]")
    local res = vk.vkCreateBuffer(core_state.device, bufInfo, nil, pBuffer)
    assert(res == 0, "FATAL: vkCreateBuffer failed")
    Memory.Buffers[name] = pBuffer[0]

    local memReqs = ffi.new("VkMemoryRequirements")
    vk.vkGetBufferMemoryRequirements(core_state.device, Memory.Buffers[name], memReqs)

    local allocInfo = ffi.new("VkMemoryAllocateInfo", {
        sType = 5,
        allocationSize = memReqs.size,
        memoryTypeIndex = FindSmartBufferMemory(core_state.physicalDevice, memReqs.memoryTypeBits)
    })

    local pMemory = ffi.new("VkDeviceMemory[1]")
    assert(vk.vkAllocateMemory(core_state.device, allocInfo, nil, pMemory) == 0)
    Memory.DeviceMemory[name] = pMemory[0]
    assert(vk.vkBindBufferMemory(core_state.device, Memory.Buffers[name], Memory.DeviceMemory[name], 0) == 0)

    local ppData = ffi.new("void*[1]")
    assert(vk.vkMapMemory(core_state.device, Memory.DeviceMemory[name], 0, byte_size, 0, ppData) == 0)
    Memory.Mapped[name] = ffi.cast(cdef_type .. "*", ppData[0])

    print("[MEMORY] Allocated & Mapped VRAM Buffer: " .. name)
end

-- C. The Pro-Level CPU Allocator (64-Byte Aligned for AVX2)
local function AllocateSoA(type_str, count, names)
    local base_type = string.gsub(type_str, "%[.-%]", "")
    local bytes_needed = ffi.sizeof(base_type) * count
    local alloc_size = bytes_needed + 64 

    for i = 1, #names do
        local name = names[i]
        local raw_bytes = ffi.new("uint8_t[?]", alloc_size)
        Memory.Anchors[name] = raw_bytes 

        local ptr_num = tonumber(ffi.cast("uintptr_t", raw_bytes))
        local offset = (64 - (ptr_num % 64)) % 64
        Memory.Arrays[name] = ffi.cast(base_type .. "*", raw_bytes + offset)
    end
end
-- ========================================================================
-- [4] INITIALIZATION (The Hybrid Boot)
-- ========================================================================
function Memory.Init(vulkan_lib, core_state, use_avx2)
    vk = vulkan_lib
    print("[MEMORY] Initializing Unified Memory Manager...")

    -- A. ALLOCATE VRAM (The Quad-Buffer Assembly Line)
    -- CPU Ping-Pong Buffers
    Memory.CreateHostVisibleBuffer("SwarmCPU_A", "GPU_VertexAoS", MAX_OBJS, 160, core_state)
    Memory.CreateHostVisibleBuffer("SwarmCPU_B", "GPU_VertexAoS", MAX_OBJS, 160, core_state)
    
    -- GPU Ping-Pong Buffers
    Memory.CreateHostVisibleBuffer("SwarmPing", "GPU_VertexAoS", MAX_OBJS, 160, core_state) 
    Memory.CreateHostVisibleBuffer("SwarmPong", "GPU_VertexAoS", MAX_OBJS, 160, core_state) 
    
    Memory.CreateHostVisibleBuffer("Cage", "GPU_GlobalCage", 1, 16, core_state)

    -- B. ALLOCATE CPU RAM (Always required for seeding the universe!)
    print("[MEMORY] Allocating 64-byte Aligned SoA CPU Memory...")

    AllocateSoA("float[?]", MAX_OBJS, {
        "Swarm_PX_0", "Swarm_PY_0", "Swarm_PZ_0",
        "Swarm_VX_0", "Swarm_VY_0", "Swarm_VZ_0",
        "Swarm_Seed"
    })

    -- Manual Double-Buffer Assignments
    Memory.RenderStruct.Swarm_PX[0] = Memory.Arrays.Swarm_PX_0
    Memory.RenderStruct.Swarm_PY[0] = Memory.Arrays.Swarm_PY_0
    Memory.RenderStruct.Swarm_PZ[0] = Memory.Arrays.Swarm_PZ_0
    Memory.RenderStruct.Swarm_VX[0] = Memory.Arrays.Swarm_VX_0
    Memory.RenderStruct.Swarm_VY[0] = Memory.Arrays.Swarm_VY_0
    Memory.RenderStruct.Swarm_VZ[0] = Memory.Arrays.Swarm_VZ_0

    -- The Automatic Binding Loop
    for array_name, array_ptr in pairs(Memory.Arrays) do
        pcall(function() Memory.RenderStruct[array_name] = array_ptr end)
    end
end
function Memory.Destroy(vk, core_state)
    print("[TEARDOWN] Deconstructing VRAM Buffers...")
    for name, buffer in pairs(Memory.Buffers) do
        local mem = Memory.DeviceMemory[name]
        if mem ~= nil then
            vk.vkUnmapMemory(core_state.device, mem)
            vk.vkDestroyBuffer(core_state.device, buffer, nil)
            vk.vkFreeMemory(core_state.device, mem, nil)
        end
    end
    Memory.Buffers = {}
    Memory.DeviceMemory = {}
    Memory.Mapped = {}
    Memory.Arrays = {}
    Memory.Anchors = {}
end

return Memory

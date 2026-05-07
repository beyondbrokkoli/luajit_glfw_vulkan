local ffi = require("ffi")
local DebugProxy = require("debug_proxy")
local vk_core = require("vulkan_core")
local camera_math = require("camera")

-- The Engine table holds all Lua-side state.
Engine = {
    Resize = { is_resizing = false, timer = 0.0, cooldown = 0.25, new_width = 0, new_height = 0 },
    vk_context = nil, vk_swapchain = nil, vk_graphics = nil, vk_compute = nil, vk_descriptors = nil,
    Time = 0.0,
    DrawCount = 1000000,
    SwarmState = 0,
    GravityBlend = 1.0,
    MetalBlend = 0.0,
    ParadoxBlend = 0.0,
    SpacePressedLast = false
}

-- ========================================================
-- PILLAR 2: THE AVX2 MATH LIBRARY (VibeMath)
-- ========================================================
-- Loaded dynamically. Handles purely CPU-side physics and ReBAR streaming.
VibeMath = ffi.load(jit.os == "Windows" and "vibemath" or "./libvibemath.so")
Config = {
    physics_mode = "HYBRID" -- We have ascended.
}

-- ========================================================
-- PILLAR 3: THE C-BRIDGE (Injected by main.c)
-- ========================================================
-- C_Bridge already exists in global space. It handles Vulkan, GLFW, and Windowing.
-- We mock the LÖVE API here to route inputs safely into the C_Bridge.
love = {
    keyboard = {
        isDown = function(key)
            local keymap = { w = 87, a = 65, s = 83, d = 68, q = 81, e = 69, space = 32 }
            if not keymap[key] then return false end
            return C_Bridge.isKeyDown(keymap[key])
        end
    },
    mouse = {
        getRelativeMode = function() return true end,
        isDown = function(button) return C_Bridge.isMouseDown(button) end
    }
}

-- ========================================================
-- MODULE INFECTION & SETUP
-- ========================================================
local EngineModules = {}
local modules_to_load = {"memory", "descriptors", "swapchain", "graphics_pipeline", "compute_pipeline"}
for _, mod_name in ipairs(modules_to_load) do
    EngineModules[mod_name] = DebugProxy.Infect(mod_name, require(mod_name))
end

local memory = EngineModules.memory
local descriptors = EngineModules.descriptors
local swapchain = EngineModules.swapchain
local graphics_pipeline = EngineModules.graphics_pipeline
local compute_pipeline = EngineModules.compute_pipeline

local cam_state = camera_math.create_state()
local success, vk = pcall(ffi.load, "vulkan-1")
if not success then success, vk = pcall(ffi.load, "vulkan") end

-- THE 64-BIT CONVERTER
local function ptr2str(ptr)
    if ptr == nil then return "0" end
    local cdata_num = ffi.cast("uint64_t", ffi.cast("uintptr_t", ptr))
    return string.match(tostring(cdata_num), "%d+")
end

-- ========================================================
-- 4. THE REBUILD ORCHESTRATOR (Boot & Resize)
-- ========================================================
local function ExecuteVulkanRebuild(width, height, is_boot)
    if not is_boot then
        print("\n[REBUILD] Halting GPU and Destroying old Swapchain/Pipelines...")
        vk.vkDeviceWaitIdle(Engine.vk_context.device)
        graphics_pipeline.Destroy(vk, Engine.vk_context, Engine.vk_graphics)
        compute_pipeline.Destroy(vk, Engine.vk_context, Engine.vk_compute)
        swapchain.Destroy(vk, Engine.vk_context, Engine.vk_swapchain)
    end

    print("[REBUILD] Building Swapchain and Pipelines...")
    Engine.vk_swapchain = swapchain.Init(vk, Engine.vk_context, width, height)
    Engine.vk_graphics = graphics_pipeline.Init(vk, Engine.vk_context, width, height)
    Engine.vk_compute = compute_pipeline.Init(vk, Engine.vk_context.device, Engine.vk_descriptors.pipelineLayout)

    -- THE CRITICAL HANDOFF TO C99
    C_Bridge.set_core_handles(
        ptr2str(Engine.vk_context.device), ptr2str(Engine.vk_context.queue), Engine.vk_context.qIndex,
        ptr2str(Engine.vk_swapchain.handle), Engine.vk_swapchain.imageCount, width, height
    )

    C_Bridge.set_pipeline_handles(
        ptr2str(Engine.vk_graphics.pipeline), ptr2str(Engine.vk_graphics.pipelineLayout),
        ptr2str(Engine.vk_compute.pipeline), ptr2str(Engine.vk_descriptors.pipelineLayout),
        ptr2str(Engine.vk_graphics.depthImage), ptr2str(Engine.vk_graphics.depthImageView),
        ptr2str(Engine.vk_descriptors.set0), ptr2str(Engine.vk_descriptors.set1)
    )

    for i = 0, Engine.vk_swapchain.imageCount - 1 do
        C_Bridge.set_swapchain_asset(i, ptr2str(Engine.vk_swapchain.images[i]), ptr2str(Engine.vk_swapchain.imageViews[i]))
    end
end


-- ========================================================
-- 5. STANDARD BOOT SEQUENCE
-- ========================================================
function love_load()
    print("[LUA] Booting VibeEngine...")
    Engine.vk_context = vk_core.init()

    -- Tell the unified memory manager which reality we are in
    local use_avx2 = (Config.physics_mode == "CPU_AVX2" or Config.physics_mode == "HYBRID")
    memory.Init(vk, Engine.vk_context, use_avx2)

    -- Setup Descriptors with the Quad-Buffer layout
    Engine.vk_descriptors = descriptors.Init(
        vk, Engine.vk_context.device,
        memory.Buffers["SwarmCPU_A"],
        memory.Buffers["SwarmCPU_B"],
        memory.Buffers["SwarmPing"],
        memory.Buffers["SwarmPong"]
    )

    -- Build Pipelines & Hand to C
    local win_width, win_height = C_Bridge.getWindowSize()
    ExecuteVulkanRebuild(win_width, win_height, true)

    -- Handoff 8 GPU Pointers to C
    C_Bridge.submit_buffers(
        ptr2str(memory.Buffers["SwarmCPU_A"]), ptr2str(memory.Buffers["SwarmCPU_B"]),
        ptr2str(memory.Buffers["SwarmPing"]), ptr2str(memory.Buffers["SwarmPong"]),
        ptr2str(memory.Mapped["SwarmCPU_A"]), ptr2str(memory.Mapped["SwarmCPU_B"]),
        ptr2str(memory.Mapped["SwarmPing"]), ptr2str(memory.Mapped["SwarmPong"])
    )

    -- Bind Buffer A initially to give C a valid target before the first frame
    VibeMath.vmath_bind_vulkan_buffers(memory.Mapped["SwarmCPU_A"], nil)
    VibeMath.vmath_bind_engine(memory.RenderStruct, nil, nil)

    -- Scatter the particles across the 20,000x20,000 universe
    VibeMath.vmath_seed_swarm(1000000)
    print("[INIT] VRAM Seeded with 2.5M Particles.")

    if use_avx2 then
        VibeMath.vmath_init_thread_pool()
        print("[INIT] AVX2 Thread Pool Online.")
    end

    C_Bridge.setRelativeMode(true)
    print("[INIT] Mouse Captured. Delta-reporting active.")
end

-- ========================================================
-- 6. OS EVENTS & UPDATE LOOP
-- ========================================================
function love_resize_trigger(w, h)
    Engine.Resize.is_resizing = true
    Engine.Resize.timer = 0.0
    Engine.Resize.new_width = w
    Engine.Resize.new_height = h
end

local frame_count = 0
function love_update(dt)
    if Engine.Resize.is_resizing then
        Engine.Resize.timer = Engine.Resize.timer + dt
        if Engine.Resize.timer >= Engine.Resize.cooldown then
            ExecuteVulkanRebuild(Engine.Resize.new_width, Engine.Resize.new_height, false)
            Engine.Resize.is_resizing = false
        end
        return false
    end

    dt = math.min(dt, 0.033)
    Engine.Time = Engine.Time + dt
    frame_count = frame_count + 1

    -- ====================================================
    -- THE SWARM LOGIC (Restored from Legacy swarm.lua)
    -- ====================================================
    local space_down = love.keyboard.isDown("space")
    if space_down and not Engine.SpacePressedLast then
        Engine.SwarmState = Engine.SwarmState + 1
        if Engine.SwarmState > 6 then Engine.SwarmState = 0 end
        print("[STATE] Swarm Matrix Shifted to State: " .. Engine.SwarmState)
    end
    Engine.SpacePressedLast = space_down

    -- Smooth Morphing Blends
    if Engine.SwarmState == 0 then Engine.GravityBlend = math.min(1.0, Engine.GravityBlend + dt * 2.0)
    else Engine.GravityBlend = math.max(0.0, Engine.GravityBlend - dt * 2.0) end

    if Engine.SwarmState == 5 then Engine.MetalBlend = math.min(1.0, Engine.MetalBlend + dt * 0.5)
    else Engine.MetalBlend = math.max(0.0, Engine.MetalBlend - dt * 2.0) end

    if Engine.SwarmState == 6 then Engine.ParadoxBlend = math.min(1.0, Engine.ParadoxBlend + dt * 0.5)
    else Engine.ParadoxBlend = math.max(0.0, Engine.ParadoxBlend - dt * 2.0) end

    -- Mouse Inputs
    local push_active = love.mouse.isDown(1) and 1 or 0
    local pull_active = love.mouse.isDown(2) and 1 or 0

    -- ====================================================
    -- THE QUAD-BUFFER TRAFFIC COP
    -- ====================================================
    local mem = memory.RenderStruct
    mem.Swarm_State = Engine.SwarmState
    mem.Swarm_GravityBlend = Engine.GravityBlend
    mem.Swarm_MetalBlend = Engine.MetalBlend
    mem.Swarm_ParadoxBlend = Engine.ParadoxBlend

    -- 1. Flip the CPU Pointer! (Even frame = A, Odd frame = B)
    local active_cpu_idx = frame_count % 2
    local target_cpu_mapped = (active_cpu_idx == 0) and memory.Mapped["SwarmCPU_A"] or memory.Mapped["SwarmCPU_B"]
    
    -- 2. Inject the active ReBAR pointer into C
    VibeMath.vmath_bind_vulkan_buffers(target_cpu_mapped, nil)

    -- 3. AVX2 Computes the base physics into the active pointer
    VibeMath.vmath_step_swarm(Engine.DrawCount, Engine.Time, dt, Engine.SwarmState, push_active, pull_active)

    if Config.physics_mode == "HYBRID" then
        -- Tell Compute Shader to read CPU data, add noise, and write to Ping/Pong
        C_Bridge.set_compute_push_constants(dt, Engine.Time, Engine.SwarmState, push_active, pull_active)

        -- Tell Rasterizer to draw the GPU's finished Ping/Pong buffer (-1)
        C_Bridge.set_active_buffer(-1)

    elseif Config.physics_mode == "CPU_AVX2" then
        -- Tell Rasterizer to draw the raw ReBAR CPU buffer directly (2)
        -- main.c uses frameIndex to natively pick SwarmCPU_A or SwarmCPU_B!
        C_Bridge.set_active_buffer(2)
    end

    -- Update Camera & Matrices (Cleaned up duplicate calls!)
    camera_math.apply_movement(cam_state, dt)
    camera_math.build_matrix(cam_state, Engine.vk_swapchain.extent.width, Engine.vk_swapchain.extent.height)

    -- The clean, stable way!
    C_Bridge.setCameraMatrix(unpack(cam_state.mat))

    C_Bridge.set_draw_count(Engine.DrawCount)
    C_Bridge.set_vertex_count(8)
    return true
end

function love_mousemoved(x, y, dx, dy)
    camera_math.apply_look(cam_state, dx, dy)
end

function love_keypressed(key)
    if key == 256 then -- Escape
        print("[LUA] Escape detected. Signaling C to stop the loop...")
        C_Bridge.signal_quit()
    elseif key == 72 then -- 'H' Key
        if Config.physics_mode == "HYBRID" then
            Config.physics_mode = "CPU_AVX2"
            print("[ENGINE] Mode Swapped: PURE CPU (Raw Smale's Paradox)")
        else
            Config.physics_mode = "HYBRID"
            print("[ENGINE] Mode Swapped: HYBRID (CPU Paradox + GPU Turbulence)")
        end
    end
end

function love_quit()
    print("\n[SHUTDOWN] Initiating Safe Teardown...")
    local device = Engine.vk_context.device
    vk.vkDeviceWaitIdle(device)

    -- 1. Pipelines & Swapchain first
    graphics_pipeline.Destroy(vk, Engine.vk_context, Engine.vk_graphics)
    compute_pipeline.Destroy(vk, Engine.vk_context, Engine.vk_compute)
    swapchain.Destroy(vk, Engine.vk_context, Engine.vk_swapchain)

    -- 2. Descriptors 
    if descriptors.Destroy then
        descriptors.Destroy(vk, device, Engine.vk_descriptors)
    end

    -- 3. Memory (VRAM Buffers)
    memory.Destroy(vk, Engine.vk_context)

    -- 4. Core (The Device and Instance must be last!)
    vk_core.Destroy(vk, Engine.vk_context)
end

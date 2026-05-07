local ffi = require("ffi")
local bit = require("bit")
require("vulkan_header") -- The Python script handles everything now!

local vk
-- 1. Try Windows/Wine standard (vulkan-1.dll)
local success, lib = pcall(ffi.load, "vulkan-1")

-- 2. Try Linux standard (libvulkan.so)
if not success then
    success, lib = pcall(ffi.load, "vulkan")
end

-- 3. Try Linux strict versioning (libvulkan.so.1)
if not success then
    success, lib = pcall(ffi.load, "libvulkan.so.1")
end

assert(success, "FATAL: Could not load the Vulkan dynamic library! Is the Vulkan runtime installed?\nError: " .. tostring(lib))
vk = lib

local core = {}

function core.init()
    print("[LUA] Initializing Vulkan Core...")

    -- 1. Ask C for the OS Extensions needed for the Window
    local exts_ptr, exts_count = C_Bridge.get_glfw_extensions()
    -- Cast the raw pointer to something the FFI understands
    local glfwExtensions = ffi.cast("const char* const*", exts_ptr)

-- [NEW] 1.5. Splice the arrays: GLFW Extensions + Debug Utils + Physical Device Props
    local total_exts = exts_count + 2 -- <--- MAKE SURE THIS IS +2
    local instanceExtensions = ffi.new("const char*[?]", total_exts)

    for i = 0, exts_count - 1 do
        instanceExtensions[i] = glfwExtensions[i]
    end

    -- Append the TWO Instance extensions
    instanceExtensions[exts_count] = "VK_EXT_debug_utils"
    instanceExtensions[exts_count + 1] = "VK_KHR_get_physical_device_properties2" -- <--- It lives here now!

    -- 2. Build the Application Info
    local appInfo = ffi.new("VkApplicationInfo", {
        sType = 0, -- VK_STRUCTURE_TYPE_APPLICATION_INFO
        pApplicationName = "VibeEngine Cooking Dish",
        apiVersion = 4194304 -- VK_API_VERSION_1_0
    })

    -- 2.5 Define the Validation Layers
    local validationLayers = ffi.new("const char*[1]", {"VK_LAYER_KHRONOS_validation"})

    -- 3. Build the Instance Info
    local createInfo = ffi.new("VkInstanceCreateInfo", {
        sType = 1, -- VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
        pApplicationInfo = appInfo,
        enabledExtensionCount = total_exts,           -- [UPDATED] Use new count
        ppEnabledExtensionNames = instanceExtensions, -- [UPDATED] Use merged array
        enabledLayerCount = 1,                        -- [UPDATED] Enable the layer
        ppEnabledLayerNames = validationLayers        -- [UPDATED] Pass the layer name
    })

    -- 4. Create the Instance
    local pInstance = ffi.new("VkInstance[1]")
    local res = vk.vkCreateInstance(createInfo, nil, pInstance)
    assert(res == 0, "FATAL: vkCreateInstance failed!")
    local instance = pInstance[0]
    print("[LUA] Vulkan Instance Created!")

    -- [NEW] 4.5. Wire up the C-side Silencer
    -- Convert the pointer to a string so our C bridge's strtoull can parse it
    local instance_address_str = tostring(tonumber(ffi.cast("uintptr_t", instance)))
    C_Bridge.inject_validation_layers(instance_address_str)

    -- 5. Ask C to create the Window Surface using our new Instance
    -- We cast the pointer to a raw number so C can read it safely without FFI metadata
    local instance_address = tonumber(ffi.cast("uintptr_t", instance))
    local surface = C_Bridge.create_surface(instance_address)
    -- The surface comes back as a number, so we cast it back to a Vulkan handle
    surface = ffi.cast("VkSurfaceKHR", surface)
    print("[LUA] Window Surface Linked!")

    -- 6. Find the GPU
    local pDeviceCount = ffi.new("uint32_t[1]")
    vk.vkEnumeratePhysicalDevices(instance, pDeviceCount, nil)
    local pDevices = ffi.new("VkPhysicalDevice[?]", pDeviceCount[0])
    vk.vkEnumeratePhysicalDevices(instance, pDeviceCount, pDevices)

    local physicalDevice = pDevices[0] -- Just grab the first GPU for now
    print("[LUA] Hardware GPU Selected!")

    -- =========================================================
    -- 7. Find the Graphics/Compute Queue Family
    -- =========================================================
    local pQueueFamilyCount = ffi.new("uint32_t[1]")
    vk.vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, pQueueFamilyCount, nil)
    local queueFamilies = ffi.new("VkQueueFamilyProperties[?]", pQueueFamilyCount[0])
    vk.vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice, pQueueFamilyCount, queueFamilies)

    local qIndex = -1
    for i = 0, pQueueFamilyCount[0] - 1 do
        -- VK_QUEUE_GRAPHICS_BIT is 1. (It guarantees Compute support too!)
        if bit.band(queueFamilies[i].queueFlags, 1) ~= 0 then
            qIndex = i
            break
        end
    end
    assert(qIndex ~= -1, "FATAL: Could not find a Graphics/Compute queue!")

    -- =========================================================
    -- 8. Create the Logical Device
    -- =========================================================
    local queuePriority = ffi.new("float[1]", 1.0)
    local queueCreateInfo = ffi.new("VkDeviceQueueCreateInfo", {
        sType = 2, -- VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
        queueFamilyIndex = qIndex,
        queueCount = 1,
        pQueuePriorities = queuePriority
    })

    -- Enable Swapchain, Dynamic Rendering, and the entire dependency tree!
    local deviceExtensions = ffi.new("const char*[6]", { -- <--- 6 Pointers!
        "VK_KHR_swapchain",
        "VK_KHR_dynamic_rendering",
        "VK_KHR_depth_stencil_resolve",
        "VK_KHR_create_renderpass2",
        "VK_KHR_multiview",                              -- <--- Brick 5!
        "VK_KHR_maintenance2"                            -- <--- Brick 6!
    })

    -- Enable Dynamic Rendering Feature struct
    local dynamicRendering = ffi.new("VkPhysicalDeviceDynamicRenderingFeatures", {
        sType = 1000044003, -- VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES
        dynamicRendering = 1 -- VK_TRUE
    })

    local deviceCreateInfo = ffi.new("VkDeviceCreateInfo", {
        sType = 3, -- VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
        pNext = dynamicRendering,
        queueCreateInfoCount = 1,
        pQueueCreateInfos = queueCreateInfo,
        enabledExtensionCount = 6, -- <--- BUMP THIS BACK TO 4!
        ppEnabledExtensionNames = deviceExtensions
    })

    local pDevice = ffi.new("VkDevice[1]")
    local res = vk.vkCreateDevice(physicalDevice, deviceCreateInfo, nil, pDevice)
    assert(res == 0, "FATAL: Failed to create Logical Device! Error: " .. tonumber(res))
    local device = pDevice[0]
    print("[LUA] Logical Device Created!")

    -- =========================================================
    -- 9. Grab the Command Queue
    -- =========================================================
    local pQueue = ffi.new("VkQueue[1]")
    vk.vkGetDeviceQueue(device, qIndex, 0, pQueue)
    local queue = pQueue[0]

    print("[DEBUG] Device Pointer in core: ", device)
    return {
        instance = instance,
        physicalDevice = physicalDevice,
        surface = surface,
        device = device,         -- ADD THIS! (The Logical Device)
        queue = queue,           -- ADD THIS! (The Command Queue)
        qIndex = qIndex          -- ADD THIS! (The Queue Family Index)
    }
end
function core.Destroy(vk, core_state)
    print("[TEARDOWN] Shutting down Vulkan Core...")

    -- 1. Destroy Logical Device First
    if core_state.device ~= nil then
        vk.vkDestroyDevice(core_state.device, nil)
    end

    -- 2. Destroy the Window Surface
    if core_state.surface ~= nil then
        vk.vkDestroySurfaceKHR(core_state.instance, core_state.surface, nil)
    end

    -- 3. Destroy the Instance Last
    if core_state.instance ~= nil then
        vk.vkDestroyInstance(core_state.instance, nil)
    end
end
return core

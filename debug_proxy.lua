local ffi = require("ffi")

local DebugProxy = {}

-- The Global Debug Toggle
DebugProxy.IS_ACTIVE = true

function DebugProxy.Infect(module_name, target_module)
    -- If debugging is off, return the raw, unadulterated module (Zero Overhead)
    if not DebugProxy.IS_ACTIVE then
        return target_module
    end

    print("[DEBUG PROXY] Infecting module: " .. module_name)
    local proxy = {}

    -- Iterate through everything in the target module
    for key, value in pairs(target_module) do
        if type(value) == "function" then
            -- Wrap the function in our spy closure
            proxy[key] = function(...)
                -- 1. Pre-execution interception
                -- print("[SPY] Executing: " .. module_name .. "." .. key)
                local start_time = os.clock()

                -- 2. Execute the original function and capture ALL return values
                local results = { value(...) }

                -- 3. Post-execution interception (Profiling)
                local end_time = os.clock()
                local elapsed_ms = (end_time - start_time) * 1000

                -- Only print if it actually took noticeable time, keeping logs clean
                if elapsed_ms > 0.1 then
                    print(string.format("[PROFILER] %s.%s took %.3f ms", module_name, key, elapsed_ms))
                end
                -- 4. Return exactly what the original function returned
                return unpack(results)
            end
        else
            -- If it's a table or variable (like a struct), just pass it through
            proxy[key] = value
        end
    end

    -- Return the infected proxy instead of the real module
    return proxy
end

return DebugProxy

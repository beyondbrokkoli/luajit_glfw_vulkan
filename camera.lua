-- camera.lua
local math_rad, math_sin, math_cos, math_tan = math.rad, math.sin, math.cos, math.tan

-- 1. THE SPAWN POINT
local function create_state()
    return {
        x = 0.0, y = 7000.0, z = 25000.0,
        yaw = -90.0, pitch = 0.0,

        -- Bumped speed to 10000.0 for massive universe traversal!
        fov = 60.0, zNear = 0.1, sensitivity = 0.1, speed = 200000.0,
        mat = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1}
    }
end

-- 2. THE INVERTED MOUSE FIX
local function apply_look(state, dx, dy)
    state.yaw = state.yaw - (dx * state.sensitivity)
    state.pitch = state.pitch + (dy * state.sensitivity)

    if state.pitch > 89.0 then state.pitch = 89.0 end
    if state.pitch < -89.0 then state.pitch = -89.0 end
end

-- 3. PURE FUNCTION: Transforms position data based on input
local function apply_movement(state, dt)
    local moveSpeed = state.speed * dt
    local radYaw = math_rad(state.yaw)

    -- Planar movement vectors
    local fx, fz = math_cos(radYaw), math_sin(radYaw)
    local rx, rz = math_cos(radYaw - 1.5708), math_sin(radYaw - 1.5708)

    -- Horizontal Plane (XZ)
    if love.keyboard.isDown("w") then
        state.x = state.x + fx * moveSpeed; state.z = state.z + fz * moveSpeed
    end
    if love.keyboard.isDown("s") then
        state.x = state.x - fx * moveSpeed; state.z = state.z - fz * moveSpeed
    end
    if love.keyboard.isDown("a") then
        state.x = state.x - rx * moveSpeed; state.z = state.z - rz * moveSpeed
    end
    if love.keyboard.isDown("d") then
        state.x = state.x + rx * moveSpeed; state.z = state.z + rz * moveSpeed
    end
    
    -- Vertical Axis (Y)
    if love.keyboard.isDown("q") then
        state.y = state.y - moveSpeed -- Descend
    end
    if love.keyboard.isDown("e") then
        state.y = state.y + moveSpeed -- Ascend
    end
end

-- 4. THE TRUE EUCLIDEAN MATRIX
local function build_matrix(state, width, height)
    local aspect = width / height
    local f = 1.0 / math_tan(math_rad(state.fov) * 0.5)

    local p00 = f / aspect
    local p11 = -f

    local radPitch = math_rad(state.pitch)
    local radYaw = math_rad(state.yaw)

    local cp, sp = math_cos(radPitch), math_sin(radPitch)
    local cy, sy = math_cos(radYaw), math_sin(radYaw)

    -- Forward (Looking down -Z)
    local fx = cp * cy;  local fy = sp;  local fz = cp * sy

    -- Right (Cross Forward with Vulkan World Up (0, -1, 0))
    local rx = sy;       local ry = 0.0; local rz = -cy

    -- Up (Cross Right with Forward)
    local ux = ry*fz - rz*fy
    local uy = rz*fx - rx*fz
    local uz = rx*fy - ry*fx

    local cx, cy_pos, cz = state.x, state.y, state.z

    -- Translation Dots
    local tx = -(rx*cx + ry*cy_pos + rz*cz)
    local ty = -(ux*cx + uy*cy_pos + uz*cz)
    local tz =  (fx*cx + fy*cy_pos + fz*cz)

    -- Multiply Proj * View directly into the 16-float array
    local mat = state.mat
    mat[1] = p00 * rx; mat[5] = p00 * ry; mat[9]  = p00 * rz; mat[13] = p00 * tx
    mat[2] = p11 * ux; mat[6] = p11 * uy; mat[10] = p11 * uz; mat[14] = p11 * ty
    mat[3] = 0.0;      mat[7] = 0.0;      mat[11] = 0.0;      mat[15] = state.zNear
    mat[4] = fx;       mat[8] = fy;       mat[12] = fz;       mat[16] = -tz
end

-- Export purely functional namespace
return {
    create_state = create_state,
    apply_movement = apply_movement,
    apply_look = apply_look,
    build_matrix = build_matrix
}

local Helpers = require("Modules/Helpers")

local NativeCameraSampler = {}

local OUTPUT_PATH = "native-camera-samples.json"
local CAPTURE_DURATION = 14.0
local SAMPLE_INTERVAL = 1.0 / 60.0

local state = {
    active = false,
    elapsed = 0.0,
    sampleAccumulator = 0.0,
    samples = {},
    status = "idle",
}

local function matrixTranslation(matrix)
    local ok, value = pcall(function()
        return Matrix.GetTranslation(matrix)
    end)
    if ok and value then
        return value
    end

    return GetSingleton("Matrix"):GetTranslation(matrix)
end

local function playerLocalPoint(player, worldPoint)
    local transform = player:GetWorldTransform()
    local ok, value = pcall(function()
        return WorldTransform.TransformInvPoint(transform, worldPoint)
    end)
    if ok and value then
        return value
    end

    return GetSingleton("WorldTransform"):TransformInvPoint(transform, worldPoint)
end

local function writeCapture(reason)
    local payload = {
        version = 1,
        reason = reason,
        duration = state.elapsed,
        coordinateSpace = "player-local: x=right, y=forward, z=up",
        instructions = "stationary, native vertical sweep up-down-up",
        samples = state.samples,
    }
    local encoded = json.encode(payload)
    local file, openError = io.open(OUTPUT_PATH, "w")
    if not file then
        state.status = "write failed: " .. tostring(openError)
        Helpers.Log("native camera capture " .. state.status)
        return false
    end

    file:write(encoded)
    file:close()
    state.status = ("saved %d samples to %s"):format(#state.samples, OUTPUT_PATH)
    Helpers.Log("native camera capture " .. state.status)
    return true
end

function NativeCameraSampler.Arm()
    state.active = true
    state.elapsed = 0.0
    state.sampleAccumulator = SAMPLE_INTERVAL
    state.samples = {}
    state.status = "armed; close CET and sweep vertically"
    Helpers.Log("native camera capture armed for 14 seconds")
end

function NativeCameraSampler.Cancel()
    state.active = false
    state.status = "cancelled"
    state.samples = {}
    Helpers.Log("native camera capture cancelled")
end

function NativeCameraSampler.IsActive()
    return state.active
end

function NativeCameraSampler.GetStatus()
    if state.active then
        return ("recording %.1f / %.1f seconds (%d samples)"):format(
            state.elapsed,
            CAPTURE_DURATION,
            #state.samples
        )
    end
    return state.status
end

function NativeCameraSampler.Update(delta, nativePitch)
    if not state.active then
        return false
    end

    local player = Game.GetPlayer()
    local fpp = Helpers.GetFPP()
    if not player or not fpp or type(nativePitch) ~= "number" then
        state.status = "waiting for the native FPP camera"
        return true
    end

    delta = math.max(0.0, math.min(tonumber(delta) or 0.0, 0.10))
    state.elapsed = state.elapsed + delta
    state.sampleAccumulator = state.sampleAccumulator + delta

    if state.sampleAccumulator >= SAMPLE_INTERVAL then
        state.sampleAccumulator = state.sampleAccumulator - SAMPLE_INTERVAL
        local ok, sample = pcall(function()
            local worldPosition = matrixTranslation(fpp:GetLocalToWorld())
            local relativePosition = playerLocalPoint(player, worldPosition)
            local componentPosition = fpp:GetLocalPosition()
            return {
                time = state.elapsed,
                pitch = nativePitch,
                x = relativePosition.x,
                y = relativePosition.y,
                z = relativePosition.z,
                componentX = componentPosition.x,
                componentY = componentPosition.y,
                componentZ = componentPosition.z,
            }
        end)

        if ok and sample then
            state.samples[#state.samples + 1] = sample
        else
            state.status = "sample failed: " .. tostring(sample)
        end
    end

    if state.elapsed >= CAPTURE_DURATION then
        state.active = false
        writeCapture("completed")
    end
    return true
end

return NativeCameraSampler

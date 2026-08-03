local NativeCameraCurve = {}

local MIN_PITCH = -80.0
local MAX_PITCH = 80.0

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

function NativeCameraCurve.Evaluate(pitch)
    pitch = clamp(pitch, MIN_PITCH, MAX_PITCH)
    if pitch <= 0.0 then
        local normalized = pitch / 80.0
        return {
            forward = -0.00429768 * normalized
                + 0.00763932 * normalized ^ 2
                - 0.17765878 * normalized ^ 3,
            vertical = -0.01104677 * normalized
                - 0.01364154 * normalized ^ 2,
        }
    end

    local normalized = pitch / 80.0
    return {
        forward = -0.35655461 * normalized,
        vertical = 0.16416325 * (1.0 - math.exp(-pitch / 17.05))
            + 0.0001897246 * pitch,
    }
end

function NativeCameraCurve.Delta(entryPitch, currentPitch)
    local entry = NativeCameraCurve.Evaluate(entryPitch)
    local current = NativeCameraCurve.Evaluate(currentPitch)
    return {
        forward = current.forward - entry.forward,
        vertical = current.vertical - entry.vertical,
    }
end

return NativeCameraCurve

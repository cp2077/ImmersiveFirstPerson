local NativeCameraCurve = {}

local MIN_PITCH = -80.0
local MAX_PITCH = 80.0
-- FPPCameraComponent reports vertical FOV, while the settings slider is
-- horizontal. These correspond to slider values 70 and 100 in the calibrated
-- 16:9 setup; 68.23 is also the original mod's known-good FOV reference.
local MIN_CALIBRATED_FOV = 43.4072366
local REFERENCE_FOV = 68.23

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function evaluateReference(pitch)
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

local function evaluateFov70(pitch)
    pitch = clamp(pitch, MIN_PITCH, MAX_PITCH)
    if pitch >= 0.0 then
        -- The second capture showed no material FOV dependency while looking up.
        return evaluateReference(pitch)
    end

    local normalized = pitch / 80.0
    return {
        forward = -0.010391657 * normalized
            - 0.013748585 * normalized ^ 2
            - 0.037616403 * normalized ^ 3,
        vertical = 0.002250879 * normalized
            - 0.013009273 * normalized ^ 2
            - 0.024464473 * normalized ^ 3,
    }
end

function NativeCameraCurve.Evaluate(pitch, fov)
    local reference = evaluateReference(pitch)
    local fovBlend = clamp(
        ((tonumber(fov) or REFERENCE_FOV) - MIN_CALIBRATED_FOV)
            / (REFERENCE_FOV - MIN_CALIBRATED_FOV),
        0.0,
        1.0
    )
    if fovBlend >= 1.0 or pitch >= 0.0 then
        return reference
    end

    local lowFov = evaluateFov70(pitch)
    return {
        forward = lowFov.forward + (reference.forward - lowFov.forward) * fovBlend,
        vertical = lowFov.vertical + (reference.vertical - lowFov.vertical) * fovBlend,
    }
end

function NativeCameraCurve.Delta(entryPitch, currentPitch, fov)
    local entry = NativeCameraCurve.Evaluate(entryPitch, fov)
    local current = NativeCameraCurve.Evaluate(currentPitch, fov)
    return {
        forward = current.forward - entry.forward,
        vertical = current.vertical - entry.vertical,
    }
end

-- Return the body-space offset which makes the current native parent behave as
-- though it were using the known-good FOV 100 curve at the effective gaze.
function NativeCameraCurve.OffsetToReference(nativePitch, effectivePitch, fov)
    local actual = NativeCameraCurve.Evaluate(nativePitch, fov)
    local desired = evaluateReference(effectivePitch)
    return {
        forward = desired.forward - actual.forward,
        vertical = desired.vertical - actual.vertical,
    }
end

return NativeCameraCurve

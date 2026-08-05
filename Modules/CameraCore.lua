local Config = require("Modules/Config")
local Helpers = require("Modules/Helpers")
local NativeCameraCurve = require("Modules/NativeCameraCurve")
local Vars = require("Modules/Vars")

local CameraCore = {}

local MODE = {
    NATIVE = "native",
    BODY = "body_correction",
    FREELOOK = "freelook",
    RETURNING = "returning",
    SUSPENDED = "suspended",
}

local BODY_WEAPON_FADE_OUT_DURATION = 0.00
local BODY_WEAPON_FADE_IN_DURATION = 0.15
-- Empty-hands state arrives before the outgoing weapon camera has necessarily
-- stopped rewriting the component-local transform. A neutral write is not a
-- useful ownership test because the weapon camera can replace it with the same
-- value. Apply an imperceptible but distinguishable local pitch, require it to
-- survive twice, then continue verifying every visible fade frame. Otherwise the
-- 250 ms holster fade can elapse behind the weapon camera and appear as one jump.
local BODY_HOLSTER_PROBE_PITCH = -0.10
local BODY_HOLSTER_PROBE_STABLE_FRAMES = 2
local BODY_HOLSTER_PROBE_POSITION_TOLERANCE = 0.0005
local BODY_HOLSTER_PROBE_ORIENTATION_DOT = 0.9999998
local BODY_HOLSTER_PROBE_LOG_DELAY = 0.50
local FIXED_FOV_POSITION_COMPENSATION = 0.70

local runtime = {
    mode = MODE.SUSPENDED,
    ownsCamera = false,
    baseline = nil,
    lastApplied = nil,
    nativePitch = 0,
    bodyProgress = 0,
    bodyPitch = 0,
    bodyBlend = nil,
    bodyContextEligible = nil,
    bodyWeaponBlocked = nil,
    bodyTransition = {
        active = false,
        elapsed = 0.0,
        from = 0.0,
        target = 0.0,
        waitingForCamera = false,
        probeWritten = false,
        probeStableFrames = 0,
        probeElapsed = 0.0,
        probeWaitLogged = false,
        probeRejectedWrites = 0,
    },
    freeYaw = 0,
    freePitch = 0,
    rawYaw = 0,
    rawPitch = 0,
    freeFollowSpeedLimit = 0,
    pitchFloor = nil,
    pitchCeiling = nil,
    entryNativePitch = 0.0,
    entryNativeOrientation = nil,
    pendingFreeLook = false,
    returnElapsed = 0,
    returnDuration = 0,
    returnFromYaw = 0,
    returnFromPitch = 0,
    invertX = false,
    invertY = false,
    input = {
        mouseX = 0,
        mouseY = 0,
        stickX = 0,
        stickY = 0,
    },
    inputSeen = {
        mouseX = false,
        mouseY = false,
        stickX = false,
        stickY = false,
    },
    inputStats = {
        mouseXCount = 0,
        mouseYCount = 0,
        mouseXSum = 0.0,
        mouseYSum = 0.0,
        mouseXAbsolute = 0.0,
        mouseYAbsolute = 0.0,
        mouseXMaximum = 0.0,
        mouseYMaximum = 0.0,
        mouseSpeedMaximum = 0.0,
        cameraSpeedMaximum = 0.0,
        speedLimitMaximum = 0.0,
    },
    lock = {
        active = false,
        consumerActions = true,
    },
    interferenceFrames = 0,
    interferenceLogged = false,
    freeLookParentDriftLogged = false,
    freeLookParentOrientationDriftLogged = false,
    freeLookLocalWriterLogged = false,
}

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function setMode(mode, reason)
    if runtime.mode == mode then
        return
    end

    local previous = runtime.mode
    runtime.mode = mode
    Helpers.Log(("camera state: %s -> %s (%s)"):format(previous, mode, reason or "update"))
end

local function clearInput()
    runtime.input.mouseX = 0
    runtime.input.mouseY = 0
    runtime.input.stickX = 0
    runtime.input.stickY = 0
end

local function resetFreeLookMotion()
    runtime.freeFollowSpeedLimit = 0
end

local function clearInputStats()
    local stats = runtime.inputStats
    stats.mouseXCount = 0
    stats.mouseYCount = 0
    stats.mouseXSum = 0.0
    stats.mouseYSum = 0.0
    stats.mouseXAbsolute = 0.0
    stats.mouseYAbsolute = 0.0
    stats.mouseXMaximum = 0.0
    stats.mouseYMaximum = 0.0
    stats.mouseSpeedMaximum = 0.0
    stats.cameraSpeedMaximum = 0.0
    stats.speedLimitMaximum = 0.0
end

local function vectorCopy(value)
    return {
        x = value.x,
        y = value.y,
        z = value.z,
        w = value.w or 1.0,
    }
end

local function quaternionCopy(value)
    return {
        i = value.i,
        j = value.j,
        k = value.k,
        r = value.r,
    }
end

local function toVector(value)
    return Vector4.new(value.x, value.y, value.z, value.w or 1.0)
end

local function toQuaternion(value)
    return Quaternion.new(value.i, value.j, value.k, value.r)
end

local function quaternionConjugate(value)
    return Quaternion.new(-value.i, -value.j, -value.k, value.r)
end

local function quaternionMultiplyFallback(a, b)
    return Quaternion.new(
        a.r * b.i + a.i * b.r + a.j * b.k - a.k * b.j,
        a.r * b.j - a.i * b.k + a.j * b.r + a.k * b.i,
        a.r * b.k + a.i * b.j - a.j * b.i + a.k * b.r,
        a.r * b.r - a.i * b.i - a.j * b.j - a.k * b.k
    )
end

local function quaternionMultiply(a, b)
    local ok, value = pcall(function()
        return Game['OperatorMultiply;QuaternionQuaternion;Quaternion'](a, b)
    end)
    if ok and value then
        return value
    end

    return quaternionMultiplyFallback(a, b)
end

local function quaternionMulInverse(a, b)
    local ok, value = pcall(function()
        return Quaternion.MulInverse(a, b)
    end)
    if ok and value then
        return value
    end

    return quaternionMultiply(a, quaternionConjugate(b))
end

local function quaternionFromEuler(roll, pitch, yaw)
    local angles = EulerAngles.new(roll, pitch, yaw)
    local ok, value = pcall(function()
        return angles:ToQuat()
    end)
    if ok and value then
        return value
    end

    return GetSingleton("EulerAngles"):ToQuat(angles)
end

local function quaternionAxisAngle(x, y, z, degrees)
    local radians = math.rad(degrees)
    local ok, value = pcall(function()
        return Quaternion.SetAxisAngle(Vector4.new(x, y, z, 0.0), radians)
    end)
    if ok and value then
        return value
    end

    -- The axes used below are unit vectors, so the direct construction is also
    -- useful in Lua-only tests where REDengine's static helper is unavailable.
    local halfAngle = radians * 0.5
    local sine = math.sin(halfAngle)
    return Quaternion.new(x * sine, y * sine, z * sine, math.cos(halfAngle))
end

local function headLocalOrientation(
    nativePitch,
    bodyPitch,
    freePitch,
    freeYaw,
    freeRoll,
    baselineOrientation
)
    -- Native pitch belongs to the component's parent. Cancel it locally before
    -- head yaw, then put native + local corrections + head pitch back after yaw.
    -- This gives:
    --
    --   world = bodyYaw * headYaw * combinedPitch * headRoll * baseline
    --
    -- without ResetPitch() and without yaw inheriting the current view tilt.
    local cancelNativePitch = quaternionAxisAngle(1.0, 0.0, 0.0, -nativePitch)
    local yaw = quaternionAxisAngle(0.0, 0.0, 1.0, freeYaw)
    local pitch = quaternionAxisAngle(
        1.0,
        0.0,
        0.0,
        nativePitch + bodyPitch + freePitch
    )
    local roll = quaternionAxisAngle(0.0, 1.0, 0.0, freeRoll)
    local orientation = quaternionMultiply(cancelNativePitch, yaw)
    orientation = quaternionMultiply(orientation, pitch)
    orientation = quaternionMultiply(orientation, roll)
    return quaternionMultiply(orientation, toQuaternion(baselineOrientation))
end

local function quaternionToEuler(value)
    local ok, angles = pcall(function()
        return value:ToEulerAngles()
    end)
    if ok and angles then
        return angles
    end

    return GetSingleton("Quaternion"):ToEulerAngles(value)
end

local function matrixToQuaternion(matrix)
    local ok, value = pcall(function()
        return matrix:ToQuat()
    end)
    if ok and value then
        return value
    end

    local rotation = matrix:GetRotation()
    return quaternionFromEuler(rotation.roll, rotation.pitch, rotation.yaw)
end

local function quaternionForward(value)
    local ok, forward = pcall(function()
        return value:GetForward()
    end)
    if ok and forward then
        return forward
    end

    return GetSingleton("Quaternion"):GetForward(value)
end

local function getNativeOrientation(fpp, actualLocalOrientation)
    local ok, orientation = pcall(function()
        local worldMatrix = fpp:GetLocalToWorld()
        if not worldMatrix then
            return nil
        end

        local worldOrientation = matrixToQuaternion(worldMatrix)
        return quaternionMulInverse(worldOrientation, actualLocalOrientation)
    end)

    if ok and orientation then
        return orientation
    end
    return nil
end

local function nativePitchFromOrientation(nativeOrientation)
    local ok, pitch = pcall(function()
        local forward = quaternionForward(nativeOrientation)
        if not forward or not finite(forward.z) then
            return nil
        end

        local fromForward = math.deg(math.asin(clamp(forward.z, -1.0, 1.0)))

        -- REDengine's forward-axis sign has changed in tooling representations before.
        -- Choose the forward-derived sign that agrees with the recovered quaternion.
        local euler = quaternionToEuler(nativeOrientation)
        local eulerPitch = euler and (euler.pitch or euler.Pitch)
        if finite(eulerPitch)
            and math.abs(-fromForward - eulerPitch) < math.abs(fromForward - eulerPitch) then
            fromForward = -fromForward
        end

        return fromForward
    end)

    if ok and finite(pitch) then
        return pitch
    end
    return nil
end

local function getNativePitch(fpp, actualLocalOrientation)
    local nativeOrientation = getNativeOrientation(fpp, actualLocalOrientation)
    return nativeOrientation and nativePitchFromOrientation(nativeOrientation) or nil
end

local function readNumberProperty(object, property, fallback)
    local ok, value = pcall(function()
        return object[property]
    end)
    if ok and finite(value) then
        return value
    end
    return fallback
end

local function getCameraZoom(fpp)
    -- The live aim/scanner zoom is exposed through GetZoom(). Reading the Lua
    -- wrapper field only returns a stale/default value on current CET builds.
    local ok, zoom = pcall(function()
        return fpp:GetZoom()
    end)
    if ok and finite(zoom) and zoom > 0.05 then
        return zoom
    end

    zoom = readNumberProperty(fpp, "zoom", 1.0)
    return zoom > 0.05 and zoom or 1.0
end

local function lockNativeInput()
    if runtime.lock.active then
        return
    end

    runtime.lock.active = true
    Helpers.Log("native camera lock: consuming camera actions")
end

local function maintainNativeInputLock()
end

local function unlockNativeInput()
    if not runtime.lock.active then
        return
    end

    runtime.lock.active = false
end

local function maintainInputUnlock()
end

local function captureBaseline(fpp)
    if runtime.ownsCamera then
        return true
    end

    local position = fpp:GetLocalPosition()
    local orientation = fpp:GetLocalOrientation()
    if not position or not orientation then
        return false
    end

    runtime.baseline = {
        position = vectorCopy(position),
        orientation = quaternionCopy(orientation),
        fov = Helpers.GetFOV(fpp) or 68,
    }
    runtime.ownsCamera = true
    runtime.lastApplied = nil
    runtime.interferenceFrames = 0
    runtime.interferenceLogged = false
    return true
end

local function releaseCamera(fpp)
    if not runtime.ownsCamera or not runtime.baseline then
        runtime.ownsCamera = false
        runtime.baseline = nil
        runtime.lastApplied = nil
        return
    end

    if fpp then
        pcall(function()
            fpp:SetLocalTransform(
                toVector(runtime.baseline.position),
                toQuaternion(runtime.baseline.orientation)
            )
        end)
    end

    runtime.ownsCamera = false
    runtime.baseline = nil
    runtime.lastApplied = nil
    runtime.bodyProgress = 0
    runtime.bodyPitch = 0
end

local function easeOutCubic(t)
    return 1.0 - (1.0 - t) ^ 3
end

local function smoothstep(t)
    t = clamp(t, 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)
end

local function setBodyBlendImmediate(target)
    local transition = runtime.bodyTransition
    runtime.bodyBlend = target
    transition.active = false
    transition.elapsed = 0.0
    transition.from = target
    transition.target = target
    transition.waitingForCamera = false
    transition.probeWritten = false
    transition.probeStableFrames = 0
    transition.probeElapsed = 0.0
    transition.probeWaitLogged = false
    transition.probeRejectedWrites = 0
end

local function resetBodyBlendTracking()
    runtime.bodyBlend = nil
    runtime.bodyContextEligible = nil
    runtime.bodyWeaponBlocked = nil
    runtime.bodyTransition.active = false
    runtime.bodyTransition.elapsed = 0.0
    runtime.bodyTransition.waitingForCamera = false
    runtime.bodyTransition.probeWritten = false
    runtime.bodyTransition.probeStableFrames = 0
    runtime.bodyTransition.probeElapsed = 0.0
    runtime.bodyTransition.probeWaitLogged = false
    runtime.bodyTransition.probeRejectedWrites = 0
end

local function rebaseBodyProbeToLiveCamera(fpp, position, orientation)
    if not runtime.ownsCamera or not runtime.baseline then
        return
    end

    runtime.baseline.position = vectorCopy(position)
    runtime.baseline.orientation = quaternionCopy(orientation)
    runtime.baseline.fov = Helpers.GetFOV(fpp) or runtime.baseline.fov
    runtime.lastApplied = nil
end

local function updateBodyBlend(fpp, context, delta)
    local contextEligible = context.bodyContextEligible == true
    local weaponBlocked = context.bodyWeaponBlocked == true
    local target = context.bodyEligible and 1.0 or 0.0
    local transition = runtime.bodyTransition

    if runtime.bodyBlend == nil then
        setBodyBlendImmediate(target)
    elseif target ~= transition.target then
        -- Only weapon edges inside one continuously valid FPP context receive a
        -- blend. Returning from scenes, vehicles, death, or another camera owner
        -- must adopt the live camera immediately rather than replay this handoff.
        local weaponEdge = contextEligible
            and runtime.bodyContextEligible == true
            and weaponBlocked ~= runtime.bodyWeaponBlocked
        if weaponEdge then
            transition.active = true
            transition.elapsed = 0.0
            transition.from = runtime.bodyBlend
            transition.target = target
            -- A normal holster starts from fully native camera state. Probe only
            -- that edge; a rapid reversal while a fade is already visible should
            -- continue smoothly from its current blend instead of pausing.
            transition.waitingForCamera = target > transition.from
                and transition.from <= 0.0001
            transition.probeWritten = false
            transition.probeStableFrames = 0
            transition.probeElapsed = 0.0
            transition.probeWaitLogged = false
            transition.probeRejectedWrites = 0
            Helpers.Log((
                "body weapon fade started: %.2f -> %.2f over %.0f ms"
            ):format(
                transition.from,
                transition.target,
                (target > transition.from
                    and BODY_WEAPON_FADE_IN_DURATION
                    or BODY_WEAPON_FADE_OUT_DURATION) * 1000.0
            ))
        else
            setBodyBlendImmediate(target)
        end
    end

    local fadeInWriteRetained = false
    if transition.active
        and transition.target > transition.from
        and transition.probeWritten
        and runtime.lastApplied then
        local position = fpp:GetLocalPosition()
        local orientation = fpp:GetLocalOrientation()
        if position and orientation then
            local appliedPosition = runtime.lastApplied.position
            local positionDelta = math.abs(position.x - appliedPosition.x)
                + math.abs(position.y - appliedPosition.y)
                + math.abs(position.z - appliedPosition.z)
            local appliedOrientation = runtime.lastApplied.orientation
            local retainedDot = math.abs(
                orientation.i * appliedOrientation.i
                    + orientation.j * appliedOrientation.j
                    + orientation.k * appliedOrientation.k
                    + orientation.r * appliedOrientation.r
            )
            if positionDelta <= BODY_HOLSTER_PROBE_POSITION_TOLERANCE
                and retainedDot >= BODY_HOLSTER_PROBE_ORIENTATION_DOT then
                fadeInWriteRetained = true
                if transition.waitingForCamera then
                    transition.probeStableFrames = transition.probeStableFrames + 1
                end
            else
                -- The outgoing profile replaced either the fixed probe or a
                -- visible fade step. Adopt that live native pose, return to the
                -- tiny probe, and restart the complete fade only after it sticks.
                transition.probeRejectedWrites = transition.probeRejectedWrites + 1
                transition.waitingForCamera = true
                transition.probeStableFrames = 0
                transition.elapsed = 0.0
                runtime.bodyBlend = transition.from
                rebaseBodyProbeToLiveCamera(fpp, position, orientation)
            end
        end
        transition.probeWritten = false
    end

    if transition.active and transition.waitingForCamera then
        transition.probeElapsed = transition.probeElapsed
            + math.max(tonumber(delta) or 0.0, 0.0)
        if transition.probeStableFrames >= BODY_HOLSTER_PROBE_STABLE_FRAMES then
            transition.waitingForCamera = false
            transition.elapsed = 0.0
            Helpers.Log((
                "body holster camera ownership confirmed after %d overwritten writes; "
                    .. "250 ms fade started"
            ):format(transition.probeRejectedWrites))
        else
            if transition.probeElapsed >= BODY_HOLSTER_PROBE_LOG_DELAY
                and not transition.probeWaitLogged then
                transition.probeWaitLogged = true
                Helpers.Log("body holster fade is waiting for the weapon camera to release")
            end
        end
    end

    local canAdvance = transition.target < transition.from
        or fadeInWriteRetained
    if transition.active and not transition.waitingForCamera and canAdvance then
        local duration = transition.target > transition.from
            and BODY_WEAPON_FADE_IN_DURATION
            or BODY_WEAPON_FADE_OUT_DURATION
        transition.elapsed = math.min(
            transition.elapsed + math.max(tonumber(delta) or 0.0, 0.0),
            duration
        )
        local progress = duration <= 0.0
            and 1.0
            or transition.elapsed / duration
        runtime.bodyBlend = transition.from
            + (transition.target - transition.from) * smoothstep(progress)
        if progress >= 1.0 then
            Helpers.Log((
                "body weapon fade completed at %.2f"
            ):format(transition.target))
            setBodyBlendImmediate(transition.target)
        end
    end

    runtime.bodyContextEligible = contextEligible
    runtime.bodyWeaponBlocked = weaponBlocked
end

local function bodyRestorationPending(context)
    local transition = runtime.bodyTransition
    if transition.active and transition.target > transition.from then
        return true
    end

    return context
        and not context.hasWeapon
        and (context.bodyWeaponBlocked or runtime.bodyWeaponBlocked == true)
end

local function normalizeBodyPitch(nativePitch)
    local body = Vars.BODY
    local pitchDown = -nativePitch
    return clamp(
        (pitchDown - body.START_PITCH_DOWN) / (body.FULL_PITCH_DOWN - body.START_PITCH_DOWN),
        0.0,
        1.0
    )
end

function CameraCore.EvaluateBody(nativePitch, crouching)
    local body = Vars.BODY
    local progress = normalizeBodyPitch(nativePitch)

    local verticalRamp = math.min(1.0, progress * 4.0)
        * math.min(1.0, progress / body.VERTICAL_RAMP_END)
    local vertical = verticalRamp * body.VERTICAL_OFFSET

    local forwardShape = math.max(
        -0.16,
        5.0 * progress - math.max(0.0, (progress - body.FORWARD_CURVE_TURN) * 8.5)
    )
    local forward = progress * body.FORWARD_OFFSET * forwardShape
    local pitchCorrection = progress * body.PITCH_CORRECTION

    if crouching then
        vertical = vertical * body.CROUCH_VERTICAL_MULTIPLIER
        forward = progress * body.FORWARD_OFFSET * body.CROUCH_FORWARD_MULTIPLIER
        pitchCorrection = pitchCorrection * body.CROUCH_PITCH_MULTIPLIER
    end

    return {
        progress = progress,
        lateral = 0.0,
        forward = forward,
        vertical = vertical,
        pitch = pitchCorrection,
    }
end

local function getFreeLookLimits(hasWeapon)
    local free = Vars.FREELOOK
    if hasWeapon then
        return free.COMBAT_MAX_YAW, free.COMBAT_MAX_PITCH_DOWN, free.COMBAT_MAX_PITCH_UP
    end
    return free.MAX_YAW, free.MAX_PITCH_DOWN, free.MAX_PITCH_UP
end

local function getAvailablePitchLimits(hasWeapon, basePitch)
    local _, relativeDown, relativeUp = getFreeLookLimits(hasWeapon)
    local floor = runtime.pitchFloor or Vars.FREELOOK.DEFAULT_PITCH_FLOOR
    local ceiling = runtime.pitchCeiling or Vars.FREELOOK.DEFAULT_PITCH_CEILING
    local availableDown = math.max(0.0, basePitch - floor)
    local availableUp = math.max(0.0, ceiling - basePitch)

    -- Outside combat, freelook owns the complete absolute vertical camera range.
    -- A relative +/-85 degree cap strands a view that starts at one pole near
    -- the centre before it can reach the opposite pole.
    if not hasWeapon then
        return availableDown, availableUp
    end

    return math.min(relativeDown, availableDown), math.min(relativeUp, availableUp)
end

local function signedPitchLimit(pitch, maxPitchDown, maxPitchUp)
    return pitch < 0.0 and maxPitchDown or maxPitchUp
end

local function normalizePitch(pitch, maxPitchDown, maxPitchUp)
    local limit = signedPitchLimit(pitch, maxPitchDown, maxPitchUp)
    return limit > 0.0001 and pitch / limit or 0.0
end

local function coneRadius(yaw, pitch, power)
    return (math.abs(yaw) ^ power + math.abs(pitch) ^ power) ^ (1.0 / power)
end

local function getPitchFloor(yaw, maxYaw, basePitch)
    local rearProgress = smoothstep(
        (math.abs(yaw) / maxYaw
            - Vars.FREELOOK.REAR_PITCH_CLAMP_START_YAW_PROGRESS)
            / (1.0 - Vars.FREELOOK.REAR_PITCH_CLAMP_START_YAW_PROGRESS)
    )
    local visualFloor = runtime.pitchFloor
        or Vars.FREELOOK.DEFAULT_PITCH_FLOOR
    visualFloor = visualFloor
        + (Vars.FREELOOK.REAR_PITCH_FLOOR - visualFloor) * rearProgress
    return visualFloor - basePitch
end

local function stepHeadCone(
    yaw,
    pitch,
    yawDelta,
    pitchDelta,
    hasWeapon,
    basePitch
)
    local maxYaw, maxPitchDown, maxPitchUp = getFreeLookLimits(hasWeapon)
    maxPitchDown, maxPitchUp = getAvailablePitchLimits(hasWeapon, basePitch)

    if maxYaw <= 0.0001 then
        return 0.0, 0.0
    end

    if not hasWeapon and pitchDelta < 0.0 then
        local prospectiveYaw = clamp(yaw + yawDelta, -maxYaw, maxYaw)
        local pitchFloor = getPitchFloor(
            prospectiveYaw,
            maxYaw,
            basePitch
        )
        -- Use a fixed angular approach rather than a percentage of the range
        -- remaining at entry. Otherwise starting low collapses the soft zone
        -- into a few degrees. Only downward input is resisted, so escaping the
        -- boundary remains immediate.
        local distance = pitch - pitchFloor
        local inputScale = smoothstep(clamp(
            distance / Vars.FREELOOK.PITCH_FLOOR_SOFT_RANGE,
            0.0,
            1.0
        ))
        pitchDelta = pitchDelta * inputScale
    end

    local normalizedYaw = yaw / maxYaw
    local normalizedPitch = normalizePitch(pitch, maxPitchDown, maxPitchUp)
    local yawStep = yawDelta / maxYaw
    local pitchStep = normalizePitch(
        pitch + pitchDelta,
        maxPitchDown,
        maxPitchUp
    ) - normalizedPitch
    -- Unarmed freelook keeps a rounded-box cone so substantial pitch and yaw
    -- can coexist. The armed camera uses a true ellipse: either axis may reach
    -- its full limit alone, but diagonal input shares one movement budget and
    -- cannot reach both weapon-rig extremes simultaneously.
    local power = hasWeapon
        and Vars.FREELOOK.COMBAT_CONE_POWER
        or Vars.FREELOOK.CONE_POWER
    local radius = coneRadius(normalizedYaw, normalizedPitch, power)

    -- Only the outward component meets resistance. Tangential motion and any
    -- movement back toward the centre retain full input speed, so the soft edge
    -- never feels sticky after the player reverses direction.
    if radius > Vars.FREELOOK.EDGE_SOFT_START then
        local yawGradient = normalizedYaw == 0.0
            and 0.0
            or (normalizedYaw < 0.0 and -1.0 or 1.0)
                * math.abs(normalizedYaw) ^ (power - 1.0)
        local pitchGradient = normalizedPitch == 0.0
            and 0.0
            or (normalizedPitch < 0.0 and -1.0 or 1.0)
                * math.abs(normalizedPitch) ^ (power - 1.0)
        local outwardStep = yawStep * yawGradient + pitchStep * pitchGradient
        local gradientLengthSquared = yawGradient * yawGradient
            + pitchGradient * pitchGradient

        if outwardStep > 0.0 and gradientLengthSquared > 0.000001 then
            local edgeProgress = smoothstep(
                (radius - Vars.FREELOOK.EDGE_SOFT_START)
                    / (1.0 - Vars.FREELOOK.EDGE_SOFT_START)
            )
            local removedScale = outwardStep / gradientLengthSquared * edgeProgress
            yawStep = yawStep - yawGradient * removedScale
            pitchStep = pitchStep - pitchGradient * removedScale
        end
    end

    normalizedYaw = normalizedYaw + yawStep
    normalizedPitch = normalizedPitch + pitchStep
    radius = coneRadius(normalizedYaw, normalizedPitch, power)

    -- Normalize overshoot back onto the selected continuous boundary.
    if radius > 1.0 then
        normalizedYaw = normalizedYaw / radius
        normalizedPitch = normalizedPitch / radius
    end

    local pitchLimit = signedPitchLimit(normalizedPitch, maxPitchDown, maxPitchUp)
    local resultYaw = normalizedYaw * maxYaw
    local resultPitch = normalizedPitch * pitchLimit
    if not hasWeapon then
        -- Looking behind while retaining the full downward native range puts the
        -- camera through the open neck. Tighten the absolute visible floor only
        -- after the shoulder turn begins; because the floor itself follows a
        -- smooth yaw curve, continuing rearward gently guides the gaze upward.
        local pitchFloor = getPitchFloor(
            resultYaw,
            maxYaw,
            basePitch
        )
        resultPitch = math.max(resultPitch, pitchFloor)
    end
    return resultYaw, resultPitch
end

local function constrainHeadCone(yaw, pitch, hasWeapon, basePitch)
    local maxYaw, maxPitchDown, maxPitchUp = getFreeLookLimits(hasWeapon)
    maxPitchDown, maxPitchUp = getAvailablePitchLimits(hasWeapon, basePitch)
    if maxYaw <= 0.0001 then
        return 0.0, 0.0
    end

    local normalizedYaw = yaw / maxYaw
    local normalizedPitch = normalizePitch(pitch, maxPitchDown, maxPitchUp)
    local power = hasWeapon
        and Vars.FREELOOK.COMBAT_CONE_POWER
        or Vars.FREELOOK.CONE_POWER
    local radius = coneRadius(normalizedYaw, normalizedPitch, power)
    if radius > 1.0 then
        normalizedYaw = normalizedYaw / radius
        normalizedPitch = normalizedPitch / radius
    end

    local resultYaw = normalizedYaw * maxYaw
    local resultPitch = normalizedPitch
        * signedPitchLimit(normalizedPitch, maxPitchDown, maxPitchUp)
    if not hasWeapon then
        resultPitch = math.max(resultPitch, getPitchFloor(resultYaw, maxYaw, basePitch))
    end
    return resultYaw, resultPitch
end

function CameraCore.EvaluateFreeLook(yaw, _, hasWeapon)
    local free = Vars.FREELOOK
    local maxYaw = getFreeLookLimits(hasWeapon)
    local absoluteYawProgress = clamp(math.abs(yaw) / maxYaw, 0.0, 1.0)
    local sideSign = yaw < 0 and 1.0 or -1.0

    if hasWeapon then
        -- The weapon and arms remain attached to REDengine's frozen native
        -- camera. Positional head choreography moves only our view and exposes
        -- the inside of that rig, especially when freelook starts downward.
        -- Keep combat freelook deliberately simple: rotate in place.
        return {
            yaw = yaw,
            pitch = 0.0,
            sideProgress = 0.0,
            backProgress = 0.0,
            lateral = 0.0,
            forward = 0.0,
            vertical = 0.0,
            roll = 0.0,
        }
    end

    local lateralYawProgress = math.min(
        absoluteYawProgress,
        free.LATERAL_STOP_YAW_PROGRESS
    )
    local lateralProgress = smoothstep(
        (lateralYawProgress - free.LATERAL_START)
            / (free.LATERAL_STOP_YAW_PROGRESS - free.LATERAL_START)
    )
    local sideCorrectionProgress = smoothstep(
        (absoluteYawProgress - free.BODY_FADE_START_YAW_PROGRESS)
            / (free.BODY_FADE_FULL_YAW_PROGRESS
                - free.BODY_FADE_START_YAW_PROGRESS)
    )
    local backProgress = smoothstep(
        (absoluteYawProgress - free.BACK_START_YAW_PROGRESS)
            / (free.BACK_FULL_YAW_PROGRESS - free.BACK_START_YAW_PROGRESS)
    )
    local roll = -sideSign
        * free.MAX_ROLL
        * smoothstep(
            (absoluteYawProgress - free.ROLL_START_YAW_PROGRESS)
                / (1.0 - free.ROLL_START_YAW_PROGRESS)
        )

    return {
        yaw = yaw,
        pitch = 0.0,
        sideProgress = sideCorrectionProgress,
        backProgress = backProgress,
        lateral = free.MAX_LATERAL_OFFSET * lateralProgress * sideSign,
        forward = -free.MAX_BACK_OFFSET * backProgress,
        vertical = 0.0,
        roll = roll,
    }
end

local function rotatePitchVector(pitch, motion)
    local radians = math.rad(pitch)
    local cosine = math.cos(radians)
    local sine = math.sin(radians)
    return {
        forward = cosine * motion.forward - sine * motion.vertical,
        vertical = sine * motion.forward + cosine * motion.vertical,
    }
end

local function nativeMotionToCameraLocal(nativePitch, motion)
    return rotatePitchVector(-nativePitch, motion)
end

local function inputAxis(value)
    local deadzone = Vars.FREELOOK.CONTROLLER_DEADZONE
    local magnitude = math.abs(value)
    if magnitude <= deadzone then
        return 0.0
    end

    local normalized = (magnitude - deadzone) / (1.0 - deadzone)
    return value < 0 and -normalized or normalized
end

local function applyFreeLookInput(delta, fpp, hasWeapon, basePitch)
    local free = Vars.FREELOOK
    local previousYaw = runtime.freeYaw
    local previousPitch = runtime.freePitch
    local sensitivity = Config.inner.freeLookSensitivity / free.DEFAULT_SENSITIVITY
    local zoom = getCameraZoom(fpp)

    local invertX = runtime.invertX and -1.0 or 1.0
    local invertY = runtime.invertY and -1.0 or 1.0
    local mouseScale = free.MOUSE_DEGREES_PER_UNIT * sensitivity / zoom
    local mouseYawDelta = -runtime.input.mouseX * invertX * mouseScale
    local mousePitchDelta = runtime.input.mouseY * invertY * mouseScale
    local mouseDegrees = math.sqrt(
        mouseYawDelta * mouseYawDelta + mousePitchDelta * mousePitchDelta
    )
    local mouseSpeed = delta > 0.0001 and mouseDegrees / delta or 0.0
    runtime.inputStats.mouseSpeedMaximum = math.max(
        runtime.inputStats.mouseSpeedMaximum,
        mouseSpeed
    )
    local controllerScale = free.CONTROLLER_DEGREES_PER_SECOND * sensitivity * delta
    local controllerYawDelta = -inputAxis(runtime.input.stickX)
        * invertX
        * controllerScale
    local controllerPitchDelta = inputAxis(runtime.input.stickY)
        * invertY
        * controllerScale
    local yawDelta = mouseYawDelta + controllerYawDelta
    local pitchDelta = mousePitchDelta + controllerPitchDelta

    local smoothness = clamp(
        tonumber(Config.inner.freeLookSmoothness) or 0,
        0,
        100
    )
    if smoothness <= 0 then
        -- This is deliberately a separate direct-input path. Do not route zero
        -- through the target follower or retain any acceleration/catch-up state.
        runtime.freeYaw, runtime.freePitch = stepHeadCone(
            runtime.freeYaw,
            runtime.freePitch,
            yawDelta,
            pitchDelta,
            hasWeapon,
            basePitch
        )
        runtime.rawYaw = runtime.freeYaw
        runtime.rawPitch = runtime.freePitch
        resetFreeLookMotion()
    else
        runtime.rawYaw, runtime.rawPitch = stepHeadCone(
            runtime.rawYaw,
            runtime.rawPitch,
            yawDelta,
            pitchDelta,
            hasWeapon,
            basePitch
        )

        local sliderProgress = smoothness / 100.0
        -- A linear blend feels almost direct until the final tenth because each
        -- frame immediately consumes most of the target gap. This ease-out curve
        -- gives the middle of the UI range a visible amount of smoothing while
        -- preserving an exact direct-input state at zero.
        local smoothingAmount = 1.0 - (1.0 - sliderProgress) ^ 3
        local smoothingRange = 100.0 * smoothingAmount
        runtime.freeFollowSpeedLimit = math.max(
            runtime.freeFollowSpeedLimit,
            free.SMOOTH_BASE_MAX_SPEED + mouseSpeed * free.SMOOTH_MOUSE_ACCELERATION
        )
        runtime.inputStats.speedLimitMaximum = math.max(
            runtime.inputStats.speedLimitMaximum,
            runtime.freeFollowSpeedLimit
        )

        local yawGap = runtime.rawYaw - runtime.freeYaw
        local pitchGap = runtime.rawPitch - runtime.freePitch
        local gap = math.sqrt(yawGap * yawGap + pitchGap * pitchGap)
        if gap > 0.0001 then
            -- Smoothness blends the complete follower from direct input to the
            -- fully speed-limited/eased response. Small nonzero values therefore
            -- stay close to direct input instead of inheriting the full catch-up.
            local directSpeed = gap / math.max(delta, 0.0001)
            local limitedSpeed = math.min(directSpeed, runtime.freeFollowSpeedLimit)
            local followSpeed = directSpeed
                + (limitedSpeed - directSpeed) * smoothingAmount
            local easedProgress = clamp(gap / smoothingRange, 0.0, 1.0)
            local followProgress = 1.0
                + (easedProgress - 1.0) * smoothingAmount
            local step = math.min(
                gap,
                followSpeed * followProgress * delta
            )
            local scale = step / gap
            runtime.freeYaw = runtime.freeYaw + yawGap * scale
            runtime.freePitch = runtime.freePitch + pitchGap * scale
            runtime.freeYaw, runtime.freePitch = constrainHeadCone(
                runtime.freeYaw,
                runtime.freePitch,
                hasWeapon,
                basePitch
            )
        end

        local remainingYaw = runtime.rawYaw - runtime.freeYaw
        local remainingPitch = runtime.rawPitch - runtime.freePitch
        if remainingYaw * remainingYaw + remainingPitch * remainingPitch < 0.0001 then
            runtime.freeYaw = runtime.rawYaw
            runtime.freePitch = runtime.rawPitch
            resetFreeLookMotion()
        end
    end
    local cameraDegrees = math.sqrt(
        (runtime.freeYaw - previousYaw) ^ 2
            + (runtime.freePitch - previousPitch) ^ 2
    )
    local cameraSpeed = delta > 0.0001 and cameraDegrees / delta or 0.0
    runtime.inputStats.cameraSpeedMaximum = math.max(
        runtime.inputStats.cameraSpeedMaximum,
        cameraSpeed
    )
    runtime.input.mouseX = 0
    runtime.input.mouseY = 0
end

local function updateReturn(delta)
    runtime.returnElapsed = math.min(runtime.returnElapsed + delta, runtime.returnDuration)
    local progress = runtime.returnDuration <= 0
        and 1.0
        or clamp(runtime.returnElapsed / runtime.returnDuration, 0.0, 1.0)
    local remaining = 1.0 - easeOutCubic(progress)
    runtime.freeYaw = runtime.returnFromYaw * remaining
    runtime.freePitch = runtime.returnFromPitch * remaining

    if progress >= 1.0 then
        runtime.freeYaw = 0
        runtime.freePitch = 0
        runtime.rawYaw = 0
        runtime.rawPitch = 0
        runtime.pitchFloor = nil
        runtime.pitchCeiling = nil
        runtime.entryNativePitch = 0.0
        runtime.entryNativeOrientation = nil
        setMode(MODE.BODY, "freelook return complete")
        unlockNativeInput()
    end
end

local function quaternionDot(a, b)
    return a.i * b.i + a.j * b.j + a.k * b.k + a.r * b.r
end

local function detectCompetingWriter(actualPosition, actualOrientation)
    -- Diagnostic only. CET can return fresh Lua wrappers for one native object,
    -- while REDengine legitimately
    -- rewrites FPP transforms and pitch limits during camera-profile evaluation.
    -- Wrapper identity, transform drift, or a changed limit therefore does not by
    -- itself prove that another mod owns the camera. Keep logging bounded here;
    -- any future yield policy needs a stable native identity/profile signal.
    if not runtime.lastApplied then
        return
    end

    local positionDelta = math.abs(actualPosition.x - runtime.lastApplied.position.x)
        + math.abs(actualPosition.y - runtime.lastApplied.position.y)
        + math.abs(actualPosition.z - runtime.lastApplied.position.z)
    local orientationDot = math.abs(quaternionDot(actualOrientation, runtime.lastApplied.orientation))
    local disturbed = positionDelta > 0.002 or orientationDot < 0.9995

    if runtime.mode == MODE.FREELOOK
        and not runtime.freeLookLocalWriterLogged
        and (positionDelta > 0.0005 or orientationDot < 0.99999) then
        runtime.freeLookLocalWriterLogged = true
        Helpers.Log((
            "freelook local transform changed between composer updates: position=%.5f orientationDot=%.7f"
        ):format(positionDelta, orientationDot))
    end

    if runtime.interferenceLogged then
        return
    end

    if disturbed then
        runtime.interferenceFrames = runtime.interferenceFrames + 1
    else
        runtime.interferenceFrames = 0
    end

    if runtime.interferenceFrames >= 30 then
        runtime.interferenceLogged = true
        Helpers.Log("another system is repeatedly writing the FPP local transform; camera mods may be competing")
    end
end

local function composeAndWrite(fpp, context)
    if not captureBaseline(fpp) or not runtime.baseline then
        return false
    end

    local actualPosition = fpp:GetLocalPosition()
    local actualOrientation = fpp:GetLocalOrientation()
    if not actualPosition or not actualOrientation then
        return false
    end
    detectCompetingWriter(actualPosition, actualOrientation)

    local nativeOrientation = getNativeOrientation(fpp, actualOrientation)
    local nativePitch = nativeOrientation
        and nativePitchFromOrientation(nativeOrientation)
        or nil
    if not nativePitch then
        return false
    end
    runtime.nativePitch = nativePitch

    if runtime.mode == MODE.FREELOOK
        and not runtime.freeLookParentDriftLogged
        and math.abs(nativePitch - runtime.entryNativePitch) > 0.05 then
        runtime.freeLookParentDriftLogged = true
        Helpers.Log((
            "freelook native parent moved while locked: entry=%.2f actual=%.2f delta=%.2f"
        ):format(
            runtime.entryNativePitch,
            nativePitch,
            nativePitch - runtime.entryNativePitch
        ))
    end
    if runtime.mode == MODE.FREELOOK
        and runtime.entryNativeOrientation
        and not runtime.freeLookParentOrientationDriftLogged then
        local parentDot = clamp(math.abs(quaternionDot(
            nativeOrientation,
            runtime.entryNativeOrientation
        )), 0.0, 1.0)
        local parentAngle = math.deg(2.0 * math.acos(parentDot))
        if parentAngle > 0.25 then
            runtime.freeLookParentOrientationDriftLogged = true
            Helpers.Log((
                "freelook native parent orientation moved by %.2f degrees; compensating"
            ):format(parentAngle))
        end
    end

    local compositionNativePitch = nativePitch
    local effectiveNativePitch = compositionNativePitch
    if runtime.mode == MODE.FREELOOK or runtime.mode == MODE.RETURNING then
        local floor = runtime.pitchFloor or Vars.FREELOOK.DEFAULT_PITCH_FLOOR
        local ceiling = runtime.pitchCeiling or Vars.FREELOOK.DEFAULT_PITCH_CEILING
        -- While the key is held, keep the virtual gaze anchored to the native
        -- pitch captured at entry. Action consumption normally freezes the real
        -- parent, but REDengine can still update it for a single frame. Mixing
        -- that slipped parent into the stored head offset caused the occasional
        -- apparent reset. Returning intentionally follows the live parent again.
        local virtualBasePitch = runtime.mode == MODE.FREELOOK
            and runtime.entryNativePitch
            or compositionNativePitch
        runtime.freePitch = clamp(
            runtime.freePitch,
            floor - virtualBasePitch,
            ceiling - virtualBasePitch
        )
        effectiveNativePitch = virtualBasePitch + runtime.freePitch
    end

    local bodyDriverPitch = effectiveNativePitch
    local body = CameraCore.EvaluateBody(
        bodyDriverPitch,
        context.crouching
    )
    local bodyBlend = clamp(tonumber(runtime.bodyBlend) or 0.0, 0.0, 1.0)

    local freeOffset = {
        yaw = 0.0,
        pitch = 0.0,
        sideProgress = 0.0,
        backProgress = 0.0,
        lateral = 0.0,
        forward = 0.0,
        vertical = 0.0,
        roll = 0.0,
    }
    if runtime.mode == MODE.FREELOOK or runtime.mode == MODE.RETURNING then
        freeOffset = CameraCore.EvaluateFreeLook(
            runtime.freeYaw,
            effectiveNativePitch,
            context.hasWeapon
        )
    end
    local bodyInfluence = (runtime.mode == MODE.FREELOOK or runtime.mode == MODE.RETURNING)
        and (1.0 - freeOffset.sideProgress)
        or 1.0
    bodyInfluence = bodyInfluence * bodyBlend
    runtime.bodyProgress = body.progress * bodyInfluence
    runtime.bodyPitch = body.pitch * bodyInfluence

    local bodyCurveMotion = NativeCameraCurve.OffsetToReference(
        compositionNativePitch,
        compositionNativePitch,
        runtime.baseline.fov
    )
    local bodySpaceMotion = NativeCameraCurve.OffsetToReference(
        compositionNativePitch,
        effectiveNativePitch,
        runtime.baseline.fov
    )
    -- OffsetToReference also contains virtual freelook pitch motion. Fade its
    -- ordinary body component during weapon changes. The camera FOV always
    -- remains native, so use the corresponding positional compensation.
    local bodyCurveInfluence = bodyBlend * FIXED_FOV_POSITION_COMPENSATION
    bodySpaceMotion.forward = bodySpaceMotion.forward
        - bodyCurveMotion.forward * (1.0 - bodyCurveInfluence)
    bodySpaceMotion.vertical = bodySpaceMotion.vertical
        - bodyCurveMotion.vertical * (1.0 - bodyCurveInfluence)

    if context.hasWeapon
        and (runtime.mode == MODE.FREELOOK or runtime.mode == MODE.RETURNING) then
        -- Emulating the native pitch translation is useful for an unarmed head,
        -- but the armed body and weapon do not follow our local camera. Pin the
        -- view to its entry position and apply orientation only.
        bodySpaceMotion.forward = 0.0
        bodySpaceMotion.vertical = 0.0
    end

    if not context.hasWeapon and freeOffset.sideProgress > 0.0 then
        -- At the shoulder, target a neutral body-forward camera position instead
        -- of scaling the entry-relative delta. This cancels the physical native
        -- offset from any entry pitch and gives every route to the side one pose.
        local actualNativePosition = NativeCameraCurve.Evaluate(
            compositionNativePitch,
            runtime.baseline.fov
        )
        local targetForward = actualNativePosition.forward + bodySpaceMotion.forward
        targetForward = targetForward * (1.0 - freeOffset.sideProgress)
        bodySpaceMotion.forward = targetForward - actualNativePosition.forward
    end
    local nativeMotion = nativeMotionToCameraLocal(compositionNativePitch, bodySpaceMotion)
    local bodyPosition = {
        lateral = body.lateral * bodyInfluence,
        forward = body.forward * bodyInfluence,
        vertical = body.vertical * bodyInfluence,
    }
    local bodySpacePitch = 0.0
    if runtime.mode == MODE.FREELOOK or runtime.mode == MODE.RETURNING then
        -- This is usually identical to freePitch. Expressing it as the virtual
        -- minus actual parent pitch also cancels any native movement that escaped
        -- the input consumer without changing the visible pose.
        bodySpacePitch = effectiveNativePitch - compositionNativePitch
    end
    if math.abs(bodySpacePitch) > 0.0001 then
        -- The body-presence offset is authored in the local frame the native
        -- camera would have at the visual pitch. Rotate it through freelook pitch.
        local rotatedBody = rotatePitchVector(bodySpacePitch, bodyPosition)
        bodyPosition.forward = rotatedBody.forward
        bodyPosition.vertical = rotatedBody.vertical
    end
    -- Shoulder setback is authored relative to the body too. Convert it through
    -- the live native parent pitch instead of adding it as an entry-local vector.
    local freeMotion = nativeMotionToCameraLocal(compositionNativePitch, {
        forward = freeOffset.forward,
        vertical = freeOffset.vertical,
    })

    local position = {
        x = runtime.baseline.position.x + bodyPosition.lateral + freeOffset.lateral,
        y = runtime.baseline.position.y + bodyPosition.forward + freeMotion.forward
            + nativeMotion.forward,
        z = runtime.baseline.position.z + bodyPosition.vertical + freeMotion.vertical
            + nativeMotion.vertical,
        w = runtime.baseline.position.w,
    }
    local orientationNativePitch = compositionNativePitch
    if runtime.mode == MODE.FREELOOK and runtime.entryNativeOrientation then
        orientationNativePitch = runtime.entryNativePitch
    end
    local holsterProbePitch = runtime.bodyTransition.active
        and runtime.bodyTransition.waitingForCamera
        and BODY_HOLSTER_PROBE_PITCH
        or 0.0
    local orientation = headLocalOrientation(
        orientationNativePitch,
        runtime.bodyPitch + freeOffset.pitch + holsterProbePitch,
        effectiveNativePitch - orientationNativePitch,
        freeOffset.yaw,
        freeOffset.roll,
        runtime.baseline.orientation
    )
    if runtime.mode == MODE.FREELOOK and runtime.entryNativeOrientation then
        -- Input consumption normally freezes the parent camera, but REDengine
        -- can recenter its yaw/roll without touching our local transform or the
        -- pitch value we previously monitored. Author the head pose under the
        -- entry parent, then convert it back into the live parent's local space.
        -- This keeps a held freelook pose continuous through those engine moves.
        local targetWorldOrientation = quaternionMultiply(
            toQuaternion(runtime.entryNativeOrientation),
            orientation
        )
        orientation = quaternionMultiply(
            quaternionConjugate(nativeOrientation),
            targetWorldOrientation
        )
    end

    local ok = pcall(function()
        fpp:SetLocalTransform(toVector(position), orientation)
    end)
    if not ok then
        return false
    end

    runtime.lastApplied = {
        position = position,
        orientation = quaternionCopy(orientation),
    }
    if runtime.bodyTransition.active
        and runtime.bodyTransition.target > runtime.bodyTransition.from then
        runtime.bodyTransition.probeWritten = true
    end
    return true
end

function CameraCore.SetInputInversion(invertX, invertY)
    runtime.invertX = invertX == true
    runtime.invertY = invertY == true
end

function CameraCore.OnAction(actionName, value)
    if runtime.mode ~= MODE.FREELOOK or not finite(value) then
        return
    end

    if actionName == "CameraMouseX" then
        runtime.input.mouseX = runtime.input.mouseX + value
        runtime.inputSeen.mouseX = true
        runtime.inputStats.mouseXCount = runtime.inputStats.mouseXCount + 1
        runtime.inputStats.mouseXSum = runtime.inputStats.mouseXSum + value
        runtime.inputStats.mouseXAbsolute = runtime.inputStats.mouseXAbsolute + math.abs(value)
        runtime.inputStats.mouseXMaximum = math.max(runtime.inputStats.mouseXMaximum, math.abs(value))
    elseif actionName == "CameraMouseY" then
        runtime.input.mouseY = runtime.input.mouseY + value
        runtime.inputSeen.mouseY = true
        runtime.inputStats.mouseYCount = runtime.inputStats.mouseYCount + 1
        runtime.inputStats.mouseYSum = runtime.inputStats.mouseYSum + value
        runtime.inputStats.mouseYAbsolute = runtime.inputStats.mouseYAbsolute + math.abs(value)
        runtime.inputStats.mouseYMaximum = math.max(runtime.inputStats.mouseYMaximum, math.abs(value))
    elseif actionName == "CameraX" or actionName == "right_stick_x" then
        runtime.input.stickX = value
        runtime.inputSeen.stickX = true
    elseif actionName == "CameraY" or actionName == "right_stick_y" then
        runtime.input.stickY = value
        runtime.inputSeen.stickY = true
    end
end

function CameraCore.BeginFreeLook(context)
    if runtime.mode == MODE.FREELOOK then
        return true
    end
    if bodyRestorationPending(context) then
        runtime.pendingFreeLook = true
        Helpers.Log("freelook deferred until body restoration completes")
        return true
    end

    local fpp = Helpers.GetFPP()
    if not fpp or not captureBaseline(fpp) then
        return false
    end

    runtime.pendingFreeLook = false
    if runtime.mode ~= MODE.RETURNING and context then
        -- Input callbacks can run after native mouse input but before our next
        -- onUpdate. Bring the local transform up to the newly sampled parent
        -- pitch before freezing it, otherwise the first freelook frame repairs a
        -- stale parent/local pair and appears to jump backward.
        local previousNativePitch = runtime.nativePitch
        if not composeAndWrite(fpp, context) then
            return false
        end
        local synchronizedDelta = runtime.nativePitch - previousNativePitch
        if math.abs(synchronizedDelta) > 0.05 then
            Helpers.Log((
                "freelook entry synchronized native pitch by %.2f degrees"
            ):format(synchronizedDelta))
        end
    end

    if runtime.mode ~= MODE.RETURNING then
        runtime.freeYaw = 0
        runtime.freePitch = 0
        runtime.rawYaw = 0
        runtime.rawPitch = 0
        local actualOrientation = fpp:GetLocalOrientation()
        local entryNativeOrientation = actualOrientation
            and getNativeOrientation(fpp, actualOrientation)
            or nil
        local entryNativePitch = entryNativeOrientation
            and nativePitchFromOrientation(entryNativeOrientation)
            or runtime.nativePitch
        runtime.nativePitch = entryNativePitch
        runtime.entryNativePitch = entryNativePitch
        runtime.entryNativeOrientation = entryNativeOrientation
        local componentFloor = readNumberProperty(
            fpp,
            "pitchMin",
            Vars.FREELOOK.DEFAULT_PITCH_FLOOR
        )
        local componentCeiling = readNumberProperty(
            fpp,
            "pitchMax",
            Vars.FREELOOK.DEFAULT_PITCH_CEILING
        )
        if componentFloor >= componentCeiling then
            componentFloor = Vars.FREELOOK.DEFAULT_PITCH_FLOOR
            componentCeiling = Vars.FREELOOK.DEFAULT_PITCH_CEILING
        end
        -- Preserve a native entry pose that is fractionally outside a reported
        -- limit, but do not let the additive body correction consume native range.
        runtime.pitchFloor = math.min(componentFloor, runtime.nativePitch)
        runtime.pitchCeiling = math.max(componentCeiling, runtime.nativePitch)
    else
        -- Returning follows the live native parent because input is already
        -- unlocked. If freelook is pressed again mid-return, freeze that current
        -- parent as the new virtual base so the mode change remains continuous.
        local actualOrientation = fpp:GetLocalOrientation()
        local resumedNativeOrientation = actualOrientation
            and getNativeOrientation(fpp, actualOrientation)
            or nil
        local resumedNativePitch = resumedNativeOrientation
            and nativePitchFromOrientation(resumedNativeOrientation)
            or runtime.nativePitch
        runtime.nativePitch = resumedNativePitch
        runtime.entryNativePitch = resumedNativePitch
        runtime.entryNativeOrientation = resumedNativeOrientation
        runtime.rawYaw = runtime.freeYaw
        runtime.rawPitch = runtime.freePitch
    end

    runtime.returnElapsed = 0
    resetFreeLookMotion()
    clearInput()
    runtime.inputSeen.mouseX = false
    runtime.inputSeen.mouseY = false
    runtime.inputSeen.stickX = false
    runtime.inputSeen.stickY = false
    clearInputStats()
    runtime.freeLookParentDriftLogged = false
    runtime.freeLookParentOrientationDriftLogged = false
    runtime.freeLookLocalWriterLogged = false
    lockNativeInput()
    setMode(MODE.FREELOOK, "input pressed")
    return true
end

function CameraCore.EndFreeLook(fast)
    runtime.pendingFreeLook = false
    if runtime.mode ~= MODE.FREELOOK and runtime.mode ~= MODE.RETURNING then
        return
    end

    clearInput()
    resetFreeLookMotion()
    if runtime.mode == MODE.FREELOOK then
        local fpp = Helpers.GetFPP()
        local actualOrientation = fpp and fpp:GetLocalOrientation()
        local exitNativePitch = actualOrientation
            and getNativePitch(fpp, actualOrientation)
            or nil
        if exitNativePitch then
            -- Freelook's held virtual pitch may differ from the real parent if an
            -- engine update slipped through the action consumer. Rebase the same
            -- visible gaze onto the live parent before returning; otherwise the
            -- first unlocked frame would expose that hidden difference as a jump.
            local virtualPitch = runtime.entryNativePitch + runtime.freePitch
            runtime.freePitch = virtualPitch - exitNativePitch
            runtime.rawPitch = runtime.freePitch
            runtime.nativePitch = exitNativePitch
            runtime.entryNativePitch = exitNativePitch
        end
    end
    Helpers.Log((
        "freelook input: X[n=%d sum=%.2f abs=%.2f max=%.2f] "
            .. "Y[n=%d sum=%.2f abs=%.2f max=%.2f] "
            .. "mouseMax=%.0fdeg/s limitMax=%.0fdeg/s cameraMax=%.0fdeg/s; "
            .. "yaw=%.2f pitch=%.2f"
    ):format(
        runtime.inputStats.mouseXCount,
        runtime.inputStats.mouseXSum,
        runtime.inputStats.mouseXAbsolute,
        runtime.inputStats.mouseXMaximum,
        runtime.inputStats.mouseYCount,
        runtime.inputStats.mouseYSum,
        runtime.inputStats.mouseYAbsolute,
        runtime.inputStats.mouseYMaximum,
        runtime.inputStats.mouseSpeedMaximum,
        runtime.inputStats.speedLimitMaximum,
        runtime.inputStats.cameraSpeedMaximum,
        runtime.freeYaw,
        runtime.freePitch
    ))
    -- Native camera input belongs to the player again as soon as the key is
    -- released. Any visual return animation continues without holding input.
    unlockNativeInput()

    local returnSmoothness = clamp(
        tonumber(Config.inner.freeLookReturnSmoothness) or 0,
        0,
        100
    )
    local immediate = fast == true or returnSmoothness <= 0
    if immediate
        or (math.abs(runtime.freeYaw) < 0.001 and math.abs(runtime.freePitch) < 0.001) then
        runtime.freeYaw = 0
        runtime.freePitch = 0
        runtime.rawYaw = 0
        runtime.rawPitch = 0
        runtime.pitchFloor = nil
        runtime.pitchCeiling = nil
        runtime.entryNativePitch = 0.0
        runtime.entryNativeOrientation = nil
        setMode(MODE.BODY, "freelook ended")
        return
    end

    local free = Vars.FREELOOK
    runtime.returnDuration = free.MIN_RETURN_DURATION
        + (free.MAX_RETURN_DURATION - free.MIN_RETURN_DURATION)
            * ((returnSmoothness - 1.0) / 99.0)
    runtime.returnElapsed = 0
    runtime.returnFromYaw = runtime.freeYaw
    runtime.returnFromPitch = runtime.freePitch
    setMode(MODE.RETURNING, "input released")
end

function CameraCore.AbortFreeLook()
    CameraCore.EndFreeLook(true)
end

function CameraCore.Update(delta, context)
    local fpp = Helpers.GetFPP()
    if not fpp then
        runtime.pendingFreeLook = false
        resetBodyBlendTracking()
        clearInput()
        resetFreeLookMotion()
        runtime.freeYaw = 0
        runtime.freePitch = 0
        runtime.rawYaw = 0
        runtime.rawPitch = 0
        runtime.pitchFloor = nil
        runtime.pitchCeiling = nil
        runtime.entryNativePitch = 0.0
        runtime.entryNativeOrientation = nil
        runtime.ownsCamera = false
        runtime.baseline = nil
        runtime.lastApplied = nil
        runtime.lock.active = false
        setMode(MODE.SUSPENDED, "FPP camera unavailable")
        return
    end

    local elapsedDelta = math.max(tonumber(delta) or 0.0, 0.0)
    local inputDelta = math.min(elapsedDelta, 0.10)
    maintainInputUnlock()
    updateBodyBlend(fpp, context, elapsedDelta)

    local restorationPending = bodyRestorationPending(context)
    if restorationPending and runtime.mode == MODE.FREELOOK then
        CameraCore.EndFreeLook(true)
        runtime.pendingFreeLook = true
    elseif restorationPending and runtime.mode == MODE.RETURNING then
        CameraCore.EndFreeLook(true)
    end

    if runtime.pendingFreeLook then
        if not context.freeEligible then
            runtime.pendingFreeLook = false
        elseif not restorationPending then
            runtime.pendingFreeLook = false
            CameraCore.BeginFreeLook(context)
        end
    end

    if (runtime.mode == MODE.FREELOOK or runtime.mode == MODE.RETURNING)
        and not context.freeEligible then
        CameraCore.EndFreeLook(true)
    end

    if runtime.mode == MODE.FREELOOK or runtime.mode == MODE.RETURNING then
        maintainNativeInputLock()
        if runtime.mode == MODE.FREELOOK then
            applyFreeLookInput(
                inputDelta,
                fpp,
                context.hasWeapon,
                runtime.entryNativePitch
            )
        else
            updateReturn(elapsedDelta)
        end
        composeAndWrite(fpp, context)
        return
    end

    if not context.bodyContextEligible then
        CameraCore.Suspend("camera context invalid")
        return
    end

    local bodyManaged = context.bodyEligible
        or runtime.bodyTransition.active
        or (tonumber(runtime.bodyBlend) or 0.0) > 0.0001
    if not bodyManaged then
        releaseCamera(fpp)
        setMode(MODE.SUSPENDED, "camera context invalid")
        return
    end

    local actualOrientation = fpp:GetLocalOrientation()
    local nativePitch = actualOrientation and getNativePitch(fpp, actualOrientation) or nil
    if not nativePitch then
        return
    end

    runtime.nativePitch = nativePitch
    runtime.bodyProgress = normalizeBodyPitch(nativePitch)
    if runtime.bodyProgress <= 0.0001 then
        releaseCamera(fpp)
        setMode(MODE.NATIVE, "camera corrections inactive")
        return
    end

    if not captureBaseline(fpp) then
        return
    end
    setMode(MODE.BODY, "camera correction active")
    composeAndWrite(fpp, context)
end

function CameraCore.Suspend(reason)
    local fpp = Helpers.GetFPP()
    runtime.pendingFreeLook = false
    clearInput()
    resetFreeLookMotion()
    runtime.freeYaw = 0
    runtime.freePitch = 0
    runtime.rawYaw = 0
    runtime.rawPitch = 0
    resetBodyBlendTracking()
    runtime.pitchFloor = nil
    runtime.pitchCeiling = nil
    runtime.entryNativePitch = 0.0
    runtime.entryNativeOrientation = nil
    runtime.returnElapsed = 0
    unlockNativeInput()
    releaseCamera(fpp)
    setMode(MODE.SUSPENDED, reason or "suspended")
end

function CameraCore.Pause(reason)
    local fpp = Helpers.GetFPP()
    runtime.pendingFreeLook = false
    clearInput()
    resetFreeLookMotion()
    runtime.freeYaw = 0
    runtime.freePitch = 0
    runtime.rawYaw = 0
    runtime.rawPitch = 0
    runtime.pitchFloor = nil
    runtime.pitchCeiling = nil
    runtime.entryNativePitch = 0.0
    runtime.entryNativeOrientation = nil
    runtime.returnElapsed = 0
    unlockNativeInput()

    -- Escape pauses CET updates, but REDengine renders another gameplay frame
    -- while closing the menu. Keep our already-composed transform and baseline
    -- alive so that frame cannot expose the raw neck/body camera. The next
    -- onUpdate resumes composition from the same ownership state.
    setMode(MODE.SUSPENDED, reason or "game paused")
end

function CameraCore.IsFreeLooking()
    return runtime.mode == MODE.FREELOOK
end

function CameraCore.IsReturning()
    return runtime.mode == MODE.RETURNING
end

function CameraCore.GetMode()
    return runtime.mode
end

function CameraCore.ReadNativePitch()
    local fpp = Helpers.GetFPP()
    if not fpp then
        return nil
    end

    local orientation = fpp:GetLocalOrientation()
    if not orientation then
        return nil
    end
    return getNativePitch(fpp, orientation)
end

function CameraCore.GetDebugState()
    return {
        mode = runtime.mode,
        nativePitch = runtime.nativePitch,
        bodyProgress = runtime.bodyProgress,
        bodyPitch = runtime.bodyPitch,
        bodyBlend = runtime.bodyBlend,
        bodyTransitionActive = runtime.bodyTransition.active,
        freeYaw = runtime.freeYaw,
        freePitch = runtime.freePitch,
        rawYaw = runtime.rawYaw,
        rawPitch = runtime.rawPitch,
        pitchFloor = runtime.pitchFloor,
        pitchCeiling = runtime.pitchCeiling,
        entryNativePitch = runtime.entryNativePitch,
        ownsCamera = runtime.ownsCamera,
        inputLocked = runtime.lock.active,
        inputLockMechanism = "action consumer",
    }
end

return CameraCore

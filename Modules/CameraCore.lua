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

local runtime = {
    mode = MODE.SUSPENDED,
    ownsCamera = false,
    baseline = nil,
    lastApplied = nil,
    nativePitch = 0,
    bodyProgress = 0,
    bodyPitch = 0,
    freeYaw = 0,
    freePitch = 0,
    rawYaw = 0,
    rawPitch = 0,
    pitchFloor = nil,
    pitchCeiling = nil,
    entryNativePitch = 0.0,
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
    },
    lock = {
        active = false,
        consumerActions = true,
    },
    interferenceFrames = 0,
    interferenceLogged = false,
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
    -- head yaw, then put native + body + head pitch back after yaw. This gives:
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

local function getNativePitch(fpp, actualLocalOrientation)
    local ok, pitch = pcall(function()
        local worldMatrix = fpp:GetLocalToWorld()
        if not worldMatrix then
            return nil
        end

        local worldOrientation = matrixToQuaternion(worldMatrix)
        local nativeOrientation = quaternionMulInverse(worldOrientation, actualLocalOrientation)
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

local function readNumberProperty(object, property, fallback)
    local ok, value = pcall(function()
        return object[property]
    end)
    if ok and finite(value) then
        return value
    end
    return fallback
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
            fpp:SetFOV(runtime.baseline.fov)
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

local function normalizeBodyPitch(nativePitch)
    local body = Vars.BODY
    local pitchDown = -nativePitch
    return clamp(
        (pitchDown - body.START_PITCH_DOWN) / (body.FULL_PITCH_DOWN - body.START_PITCH_DOWN),
        0.0,
        1.0
    )
end

function CameraCore.EvaluateBody(nativePitch, crouching, baselineFov)
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

    local fov = baselineFov
        + (body.FOV_REFERENCE - baselineFov) * math.min(1.0, progress * 2.0)
        + body.FOV_CORRECTION * progress

    return {
        progress = progress,
        lateral = 0.0,
        forward = forward,
        vertical = vertical,
        pitch = pitchCorrection,
        fov = fov,
    }
end

local function getFreeLookLimits(hasWeapon)
    local free = Vars.FREELOOK
    if hasWeapon then
        return free.COMBAT_MAX_YAW, free.COMBAT_MAX_PITCH_DOWN, free.COMBAT_MAX_PITCH_UP
    end
    return free.MAX_YAW, free.MAX_PITCH_DOWN, free.MAX_PITCH_UP
end

local function softAxisLimit(value, limit)
    if limit <= 0.0001 then
        return 0.0
    end

    local start = limit * Vars.FREELOOK.EDGE_SOFT_START
    local magnitude = math.abs(value)
    if magnitude <= start then
        return value
    end

    local remaining = limit - start
    local softened = start + remaining * (1.0 - math.exp(-(magnitude - start) / remaining))
    return value < 0.0 and -softened or softened
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

local function mapHeadCone(rawYaw, rawPitch, hasWeapon, basePitch)
    local maxYaw, maxPitchDown, maxPitchUp = getFreeLookLimits(hasWeapon)
    maxPitchDown, maxPitchUp = getAvailablePitchLimits(hasWeapon, basePitch)
    local pitchLimit = rawPitch < 0.0 and maxPitchDown or maxPitchUp
    local yaw = softAxisLimit(rawYaw, maxYaw)
    local pitch = softAxisLimit(rawPitch, pitchLimit)
    local normalizedYaw = yaw / maxYaw
    local normalizedPitch = pitchLimit > 0.0001 and pitch / pitchLimit or 0.0
    local power = Vars.FREELOOK.CONE_POWER
    local radius = (
        math.abs(normalizedYaw) ^ power + math.abs(normalizedPitch) ^ power
    ) ^ (1.0 / power)

    -- A superellipse behaves like a rounded head-look box: full shoulder turns
    -- and substantial vertical motion can coexist, while diagonal extremes are
    -- normalized smoothly back onto one continuous boundary.
    if radius > 1.0 then
        normalizedYaw = normalizedYaw / radius
        normalizedPitch = normalizedPitch / radius
    end

    return normalizedYaw * maxYaw, normalizedPitch * pitchLimit
end

function CameraCore.EvaluateFreeLook(yaw, composedPitch, hasWeapon)
    local free = Vars.FREELOOK
    local maxYaw, maxPitchDown, maxPitchUp = getFreeLookLimits(hasWeapon)
    local absoluteYawProgress = clamp(math.abs(yaw) / maxYaw, 0.0, 1.0)
    local pitchLimit = composedPitch < 0.0 and maxPitchDown or maxPitchUp
    local absolutePitchProgress = clamp(math.abs(composedPitch) / pitchLimit, 0.0, 1.0)
    local sideSign = yaw < 0 and 1.0 or -1.0
    local shoulderProgress = smoothstep(
        (absoluteYawProgress - free.SHOULDER_START) / (1.0 - free.SHOULDER_START)
    )

    local lateralMax = hasWeapon and free.COMBAT_MAX_LATERAL_OFFSET or free.MAX_LATERAL_OFFSET
    local lateralProgress = 0.20 * absoluteYawProgress + 0.80 * shoulderProgress
    local lateral = lateralMax * lateralProgress * sideSign

    local maxRoll = hasWeapon and free.COMBAT_MAX_ROLL or free.MAX_ROLL
    local roll = -sideSign
        * maxRoll
        * shoulderProgress
        * (0.20 + 0.80 * absolutePitchProgress)
        * easeOutCubic(absoluteYawProgress)

    return {
        lateral = lateral,
        forward = -0.012 * shoulderProgress,
        vertical = 0.0,
        roll = roll,
        fovDelta = 0.0,
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
    local sensitivity = Config.inner.freeLookSensitivity / free.DEFAULT_SENSITIVITY
    local zoom = readNumberProperty(fpp, "zoom", 1.0)
    if zoom <= 0.05 then
        zoom = 1.0
    end

    local invertX = runtime.invertX and -1.0 or 1.0
    local invertY = runtime.invertY and -1.0 or 1.0
    local mouseScale = free.MOUSE_DEGREES_PER_UNIT * sensitivity / zoom
    runtime.rawYaw = runtime.rawYaw - runtime.input.mouseX * invertX * mouseScale
    runtime.rawPitch = runtime.rawPitch + runtime.input.mouseY * invertY * mouseScale

    local controllerScale = free.CONTROLLER_DEGREES_PER_SECOND * sensitivity * delta
    runtime.rawYaw = runtime.rawYaw - inputAxis(runtime.input.stickX) * invertX * controllerScale
    runtime.rawPitch = runtime.rawPitch + inputAxis(runtime.input.stickY) * invertY * controllerScale

    local maxYaw, maxPitchDown, maxPitchUp = getFreeLookLimits(hasWeapon)
    maxPitchDown, maxPitchUp = getAvailablePitchLimits(hasWeapon, basePitch)
    local overshoot = free.RAW_OVERSHOOT
    runtime.rawYaw = clamp(runtime.rawYaw, -maxYaw * overshoot, maxYaw * overshoot)
    runtime.rawPitch = clamp(
        runtime.rawPitch,
        -maxPitchDown * overshoot,
        maxPitchUp * overshoot
    )
    runtime.freeYaw, runtime.freePitch = mapHeadCone(
        runtime.rawYaw,
        runtime.rawPitch,
        hasWeapon,
        basePitch
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
        setMode(MODE.BODY, "freelook return complete")
        unlockNativeInput(Helpers.GetFPP())
    end
end

local function quaternionDot(a, b)
    return a.i * b.i + a.j * b.j + a.k * b.k + a.r * b.r
end

local function detectCompetingWriter(actualPosition, actualOrientation)
    if not runtime.lastApplied or runtime.interferenceLogged then
        return
    end

    local positionDelta = math.abs(actualPosition.x - runtime.lastApplied.position.x)
        + math.abs(actualPosition.y - runtime.lastApplied.position.y)
        + math.abs(actualPosition.z - runtime.lastApplied.position.z)
    local orientationDot = math.abs(quaternionDot(actualOrientation, runtime.lastApplied.orientation))

    if positionDelta > 0.002 or orientationDot < 0.9995 then
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

    local nativePitch = getNativePitch(fpp, actualOrientation)
    if not nativePitch then
        return false
    end
    runtime.nativePitch = nativePitch

    local bodyDriverPitch = nativePitch
    if runtime.mode == MODE.FREELOOK or runtime.mode == MODE.RETURNING then
        bodyDriverPitch = nativePitch + runtime.freePitch
    end
    local body = CameraCore.EvaluateBody(
        bodyDriverPitch,
        context.crouching,
        runtime.baseline.fov
    )
    if not context.bodyEligible then
        body = CameraCore.EvaluateBody(0.0, false, runtime.baseline.fov)
    end
    runtime.bodyProgress = body.progress
    runtime.bodyPitch = body.pitch

    if runtime.mode == MODE.FREELOOK or runtime.mode == MODE.RETURNING then
        local floor = runtime.pitchFloor or Vars.FREELOOK.DEFAULT_PITCH_FLOOR
        local ceiling = runtime.pitchCeiling or Vars.FREELOOK.DEFAULT_PITCH_CEILING
        -- Clamp the emulated native pitch, not the final composed pitch. The
        -- immersive body correction is additive and normally extends the native
        -- downward view by another few degrees.
        runtime.freePitch = clamp(
            runtime.freePitch,
            floor - nativePitch,
            ceiling - nativePitch
        )
        -- Body pitch correction is itself driven by the effective gaze. If the
        -- absolute guard changed freelook pitch, refresh all body channels once.
        local correctedDriverPitch = nativePitch + runtime.freePitch
        if math.abs(correctedDriverPitch - bodyDriverPitch) > 0.0001 then
            body = CameraCore.EvaluateBody(
                correctedDriverPitch,
                context.crouching,
                runtime.baseline.fov
            )
            if not context.bodyEligible then
                body = CameraCore.EvaluateBody(0.0, false, runtime.baseline.fov)
            end
            runtime.bodyProgress = body.progress
            runtime.bodyPitch = body.pitch
        end
    end

    local freeOffset = {
        lateral = 0.0,
        forward = 0.0,
        vertical = 0.0,
        roll = 0.0,
        fovDelta = 0.0,
    }
    local nativeMotion = {
        forward = 0.0,
        vertical = 0.0,
    }
    local bodyPosition = {
        lateral = body.lateral,
        forward = body.forward,
        vertical = body.vertical,
    }
    if runtime.mode == MODE.FREELOOK or runtime.mode == MODE.RETURNING then
        local effectiveNativePitch = nativePitch + runtime.freePitch
        local bodySpaceMotion = NativeCameraCurve.Delta(
            runtime.entryNativePitch,
            effectiveNativePitch
        )
        nativeMotion = nativeMotionToCameraLocal(nativePitch, bodySpaceMotion)

        -- The body-presence offset is authored in the local frame the native
        -- camera would have at the effective pitch. Rotate it into the frozen
        -- entry parent's frame before writing the component transform.
        local rotatedBody = rotatePitchVector(runtime.freePitch, body)
        bodyPosition.forward = rotatedBody.forward
        bodyPosition.vertical = rotatedBody.vertical

        local composedPitch = effectiveNativePitch + body.pitch
        freeOffset = CameraCore.EvaluateFreeLook(
            runtime.freeYaw,
            composedPitch,
            context.hasWeapon
        )
    end

    local position = {
        x = runtime.baseline.position.x + bodyPosition.lateral + freeOffset.lateral,
        y = runtime.baseline.position.y + bodyPosition.forward + freeOffset.forward
            + nativeMotion.forward,
        z = runtime.baseline.position.z + bodyPosition.vertical + freeOffset.vertical
            + nativeMotion.vertical,
        w = runtime.baseline.position.w,
    }
    local orientation = headLocalOrientation(
        nativePitch,
        body.pitch,
        runtime.freePitch,
        runtime.freeYaw,
        freeOffset.roll,
        runtime.baseline.orientation
    )

    local ok = pcall(function()
        fpp:SetLocalTransform(toVector(position), orientation)
        if not Config.inner.dontChangeFov then
            fpp:SetFOV(body.fov + freeOffset.fovDelta)
        end
    end)
    if not ok then
        return false
    end

    runtime.lastApplied = {
        position = position,
        orientation = quaternionCopy(orientation),
    }
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

function CameraCore.BeginFreeLook()
    local fpp = Helpers.GetFPP()
    if not fpp or not captureBaseline(fpp) then
        return false
    end

    if runtime.mode ~= MODE.RETURNING then
        runtime.freeYaw = 0
        runtime.freePitch = 0
        runtime.rawYaw = 0
        runtime.rawPitch = 0
        local actualOrientation = fpp:GetLocalOrientation()
        local entryNativePitch = actualOrientation
            and getNativePitch(fpp, actualOrientation)
            or runtime.nativePitch
        runtime.nativePitch = entryNativePitch
        runtime.entryNativePitch = entryNativePitch
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
        runtime.rawYaw = runtime.freeYaw
        runtime.rawPitch = runtime.freePitch
    end
    runtime.returnElapsed = 0
    clearInput()
    runtime.inputSeen.mouseX = false
    runtime.inputSeen.mouseY = false
    runtime.inputSeen.stickX = false
    runtime.inputSeen.stickY = false
    clearInputStats()
    lockNativeInput(fpp)
    setMode(MODE.FREELOOK, "input pressed")
    return true
end

function CameraCore.EndFreeLook(fast)
    if runtime.mode ~= MODE.FREELOOK and runtime.mode ~= MODE.RETURNING then
        return
    end

    clearInput()
    Helpers.Log((
        "freelook input: X[n=%d sum=%.2f abs=%.2f max=%.2f] "
            .. "Y[n=%d sum=%.2f abs=%.2f max=%.2f]; yaw=%.2f pitch=%.2f"
    ):format(
        runtime.inputStats.mouseXCount,
        runtime.inputStats.mouseXSum,
        runtime.inputStats.mouseXAbsolute,
        runtime.inputStats.mouseXMaximum,
        runtime.inputStats.mouseYCount,
        runtime.inputStats.mouseYSum,
        runtime.inputStats.mouseYAbsolute,
        runtime.inputStats.mouseYMaximum,
        runtime.freeYaw,
        runtime.freePitch
    ))
    local immediate = fast == true or not Config.inner.smoothRestore
    if immediate or (math.abs(runtime.freeYaw) < 0.001 and math.abs(runtime.freePitch) < 0.001) then
        runtime.freeYaw = 0
        runtime.freePitch = 0
        runtime.rawYaw = 0
        runtime.rawPitch = 0
        runtime.pitchFloor = nil
        runtime.pitchCeiling = nil
        runtime.entryNativePitch = 0.0
        setMode(MODE.BODY, "freelook ended")
        unlockNativeInput(Helpers.GetFPP())
        return
    end

    local speed = clamp(Config.inner.smoothRestoreSpeed, 1, 200)
    local free = Vars.FREELOOK
    runtime.returnDuration = clamp(
        free.DEFAULT_RETURN_DURATION * 15.0 / speed,
        free.MIN_RETURN_DURATION,
        free.MAX_RETURN_DURATION
    )
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
        clearInput()
        runtime.freeYaw = 0
        runtime.freePitch = 0
        runtime.rawYaw = 0
        runtime.rawPitch = 0
        runtime.pitchFloor = nil
        runtime.pitchCeiling = nil
        runtime.entryNativePitch = 0.0
        runtime.ownsCamera = false
        runtime.baseline = nil
        runtime.lastApplied = nil
        runtime.lock.active = false
        setMode(MODE.SUSPENDED, "FPP camera unavailable")
        return
    end

    delta = clamp(tonumber(delta) or 0.0, 0.0, 0.10)
    maintainInputUnlock(fpp)

    if runtime.mode == MODE.FREELOOK or runtime.mode == MODE.RETURNING then
        if not context.freeEligible then
            CameraCore.Suspend("freelook context invalid")
            return
        end

        maintainNativeInputLock(fpp)
        if runtime.mode == MODE.FREELOOK then
            applyFreeLookInput(
                delta,
                fpp,
                context.hasWeapon,
                runtime.nativePitch
            )
        else
            updateReturn(delta)
        end
        composeAndWrite(fpp, context)
        return
    end

    if not context.bodyEligible then
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
        setMode(MODE.NATIVE, "look-down correction inactive")
        return
    end

    if not captureBaseline(fpp) then
        return
    end
    setMode(MODE.BODY, "look-down correction active")
    composeAndWrite(fpp, context)
end

function CameraCore.RestoreBaselineFOV()
    local fpp = Helpers.GetFPP()
    if fpp and runtime.baseline then
        fpp:SetFOV(runtime.baseline.fov)
    end
end

function CameraCore.Suspend(reason)
    local fpp = Helpers.GetFPP()
    clearInput()
    runtime.freeYaw = 0
    runtime.freePitch = 0
    runtime.rawYaw = 0
    runtime.rawPitch = 0
    runtime.pitchFloor = nil
    runtime.pitchCeiling = nil
    runtime.entryNativePitch = 0.0
    runtime.returnElapsed = 0
    unlockNativeInput(fpp)
    releaseCamera(fpp)
    setMode(MODE.SUSPENDED, reason or "suspended")
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

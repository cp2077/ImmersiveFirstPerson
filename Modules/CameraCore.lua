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
    CONFLICT = "conflict_suspended",
}

-- Experimental height adjustment. Keep its angular bias constant while looking
-- downward so the visible camera remains exactly 1:1 with native input. Only the
-- resulting positional lift fades out across this look-down window.
local HEIGHT_POSITION_RESTORE_FULL = -40.0
local HEIGHT_POSITION_RESTORE_OFF = 0.0
local HEIGHT_BIAS_UP_FULL = 40.0
local HEIGHT_BIAS_UP_OFF = 80.0
local HEIGHT_TRANSFER_DURATION = 0.08
local HEIGHT_TRANSFER_TIMEOUT = HEIGHT_TRANSFER_DURATION + 0.30
local HEIGHT_TRANSFER_TOLERANCE = 0.15
local HEIGHT_ENABLE_SETTLE_DURATION = 0.25
local HEIGHT_TRANSFER_RETRY_DELAY = 0.75
local BODY_WEAPON_FADE_OUT_DURATION = 0.08
local BODY_WEAPON_FADE_IN_DURATION = 0.25
local FIXED_FOV_POSITION_COMPENSATION = 0.70
local CAMERA_INTERFERENCE_DURATION = 0.50
local CAMERA_REACQUIRE_DURATION = 0.25
local CAMERA_POSITION_TOLERANCE = 0.002
local CAMERA_ORIENTATION_DOT_TOLERANCE = 0.9995
local CAMERA_FOV_TOLERANCE = 0.05
local NATIVE_PROPERTY_TOLERANCE = 0.01

local runtime = {
    mode = MODE.SUSPENDED,
    ownsCamera = false,
    ownerComponentToken = nil,
    baseline = nil,
    lastApplied = nil,
    frozen = false,
    reacquireRemaining = 0.0,
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
    },
    heightPitch = 0,
    heightApplied = nil,
    heightEligibilityElapsed = 0.0,
    pendingFreeLook = false,
    heightPitchFloor = {
        active = false,
        original = nil,
        applied = nil,
        componentToken = nil,
        failureLogged = false,
    },
    heightTransfer = {
        active = false,
        targetApplied = false,
        targetNativePitch = 0.0,
        commandedNativePitch = 0.0,
        heldVisualPitch = 0.0,
        easedProgress = 0.0,
        boundProperty = nil,
        originalPitchMin = nil,
        originalPitchMax = nil,
        elapsed = 0.0,
        retryRemaining = 0.0,
        heldVisualOverride = nil,
        componentToken = nil,
    },
    freeYaw = 0,
    freePitch = 0,
    rawYaw = 0,
    rawPitch = 0,
    pitchFloor = nil,
    pitchCeiling = nil,
    entryNativePitch = 0.0,
    entryNativeOrientation = nil,
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
    interferenceElapsed = 0.0,
    conflict = {
        active = false,
        reason = nil,
        positionDelta = 0.0,
        orientationDot = 1.0,
        fovDelta = 0.0,
    },
    freeLookParentDriftLogged = false,
    freeLookParentOrientationDriftLogged = false,
    freeLookLocalWriterLogged = false,
}

local clearTransientCameraState

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function getComponentToken(fpp)
    if not fpp then
        return nil
    end

    local ok, token = pcall(tostring, fpp)
    if not ok or type(token) ~= "string" or token == "" then
        return nil
    end
    return token
end

local function isSameComponent(fpp, token)
    local currentToken = getComponentToken(fpp)
    return currentToken ~= nil and token ~= nil and currentToken == token
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

local function quaternionDot(a, b)
    return a.i * b.i + a.j * b.j + a.k * b.k + a.r * b.r
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
    -- `bodyPitch` includes both immersive look-down pitch and the experimental
    -- height-adjustment counter-pitch. This gives:
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

local function clearCameraOwnership()
    runtime.ownsCamera = false
    runtime.ownerComponentToken = nil
    runtime.baseline = nil
    runtime.lastApplied = nil
    runtime.bodyProgress = 0
    runtime.bodyPitch = 0
    runtime.heightPitch = 0
end

local function dropCameraOwnership()
    clearCameraOwnership()
end

local function captureBaseline(fpp)
    local componentToken = getComponentToken(fpp)
    if not componentToken then
        return false
    end

    if runtime.ownsCamera then
        if runtime.ownerComponentToken == componentToken then
            return true
        end

        -- The previous component is no longer the active camera owner. Never
        -- apply its baseline to the replacement component, and do not adopt the
        -- replacement in the same callback. A short clean-frame window keeps a
        -- component swap from looking like uninterrupted ownership.
        dropCameraOwnership()
        runtime.reacquireRemaining = CAMERA_REACQUIRE_DURATION
        setMode(MODE.SUSPENDED, "FPP camera component changed")
        return false
    end

    local position = fpp:GetLocalPosition()
    local orientation = fpp:GetLocalOrientation()
    if not position or not orientation then
        return false
    end

    local baselineFov = Helpers.GetFOV(fpp)
    if not finite(baselineFov) and not Config.inner.dontChangeFov then
        return false
    end

    runtime.baseline = {
        position = vectorCopy(position),
        orientation = quaternionCopy(orientation),
        -- A fallback is only used for position-curve evaluation when FOV writes
        -- are disabled. It can never become a value that releaseCamera restores.
        fov = finite(baselineFov) and baselineFov or 68,
    }
    runtime.ownsCamera = true
    runtime.ownerComponentToken = componentToken
    runtime.lastApplied = nil
    runtime.interferenceElapsed = 0.0
    return true
end

local function releaseCamera(fpp)
    if not runtime.ownsCamera or not runtime.baseline then
        clearCameraOwnership()
        return
    end

    if not fpp
        or not isSameComponent(fpp, runtime.ownerComponentToken)
        or not runtime.lastApplied then
        clearCameraOwnership()
        return
    end

    local actualPosition = fpp:GetLocalPosition()
    local actualOrientation = fpp:GetLocalOrientation()
    if actualPosition and actualOrientation then
        local positionDelta = math.abs(actualPosition.x - runtime.lastApplied.position.x)
            + math.abs(actualPosition.y - runtime.lastApplied.position.y)
            + math.abs(actualPosition.z - runtime.lastApplied.position.z)
        local orientationDot = math.abs(quaternionDot(
            actualOrientation,
            runtime.lastApplied.orientation
        ))
        if positionDelta <= CAMERA_POSITION_TOLERANCE
            and orientationDot >= CAMERA_ORIENTATION_DOT_TOLERANCE then
            pcall(function()
                fpp:SetLocalTransform(
                    toVector(runtime.baseline.position),
                    toQuaternion(runtime.baseline.orientation)
                )
            end)
        end
    end

    if finite(runtime.lastApplied.fov) then
        local ok, actualFov = pcall(function()
            return fpp:GetFOV()
        end)
        if ok and finite(actualFov)
            and math.abs(actualFov - runtime.lastApplied.fov) <= CAMERA_FOV_TOLERANCE then
            pcall(function()
                fpp:SetFOV(runtime.baseline.fov)
            end)
        end
    end

    clearCameraOwnership()
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
end

local function resetBodyBlendTracking()
    runtime.bodyBlend = nil
    runtime.bodyContextEligible = nil
    runtime.bodyWeaponBlocked = nil
    runtime.bodyTransition.active = false
    runtime.bodyTransition.elapsed = 0.0
end

local function updateBodyBlend(context, delta)
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
        else
            setBodyBlendImmediate(target)
        end
    end

    if transition.active then
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
            setBodyBlendImmediate(transition.target)
        end
    end

    runtime.bodyContextEligible = contextEligible
    runtime.bodyWeaponBlocked = weaponBlocked
end

function CameraCore.EvaluateHeightPitch(nativePitch, maximumBias)
    maximumBias = clamp(tonumber(maximumBias) or 0.0, 0.0, 30.0)
    if maximumBias <= 0.0 then
        return 0.0
    end

    local upActivation = 1.0 - smoothstep(
        (nativePitch - HEIGHT_BIAS_UP_FULL)
            / (HEIGHT_BIAS_UP_OFF - HEIGHT_BIAS_UP_FULL)
    )
    return -maximumBias * upActivation
end

local function evaluateHeightPositionRestore(visualPitch)
    return 1.0 - smoothstep(
        (visualPitch - HEIGHT_POSITION_RESTORE_FULL)
            / (HEIGHT_POSITION_RESTORE_OFF - HEIGHT_POSITION_RESTORE_FULL)
    )
end

local function nativePitchForVisualPitch(visualPitch, maximumBias)
    local lower = Vars.FREELOOK.DEFAULT_PITCH_FLOOR - 40.0
    local upper = Vars.FREELOOK.DEFAULT_PITCH_CEILING + 40.0
    for _ = 1, 24 do
        local middle = (lower + upper) * 0.5
        local middleVisual = middle
            + CameraCore.EvaluateHeightPitch(middle, maximumBias)
        if middleVisual < visualPitch then
            lower = middle
        else
            upper = middle
        end
    end
    return (lower + upper) * 0.5
end

local function clearHeightPitchFloorState()
    local floor = runtime.heightPitchFloor
    floor.active = false
    floor.original = nil
    floor.applied = nil
    floor.componentToken = nil
    floor.failureLogged = false
end

local function restoreHeightPitchFloor(fpp)
    local floor = runtime.heightPitchFloor
    if not floor.active then
        return true
    end
    if not fpp or not finite(floor.original) then
        return false
    end

    if not isSameComponent(fpp, floor.componentToken) then
        -- The old component is gone. Its limits must never be copied to the new
        -- camera, and there is no live target left to restore here.
        clearHeightPitchFloorState()
        return true
    end

    local current = readNumberProperty(fpp, "pitchMin", nil)
    if not finite(current) then
        return false
    end
    if finite(floor.applied)
        and math.abs(current - floor.applied) > NATIVE_PROPERTY_TOLERANCE then
        -- Another owner has already replaced our value. Treat that as a clean
        -- handoff instead of overwriting its camera profile with our baseline.
        clearHeightPitchFloorState()
        return true
    end

    local restored = pcall(function()
        fpp.pitchMin = floor.original
    end)
    local readback = readNumberProperty(fpp, "pitchMin", nil)
    if not restored or not finite(readback)
        or math.abs(readback - floor.original) > NATIVE_PROPERTY_TOLERANCE then
        if not floor.failureLogged then
            Helpers.Log("failed to restore native pitch floor")
            floor.failureLogged = true
        end
        return false
    end

    clearHeightPitchFloorState()
    return true
end

local function applyHeightPitchFloor(fpp, maximumBias)
    local floor = runtime.heightPitchFloor
    local componentToken = getComponentToken(fpp)
    if not componentToken then
        return false
    end

    if floor.active then
        local current = readNumberProperty(fpp, "pitchMin", nil)
        if floor.componentToken ~= componentToken
            or not finite(current)
            or (finite(floor.applied)
                and math.abs(current - floor.applied) > NATIVE_PROPERTY_TOLERANCE) then
            clearHeightPitchFloorState()
            runtime.reacquireRemaining = CAMERA_REACQUIRE_DURATION
            return false
        end
    end

    if not floor.active then
        floor.original = readNumberProperty(fpp, "pitchMin", nil)
    end
    if not finite(floor.original) then
        return false
    end

    local pitchMax = readNumberProperty(
        fpp,
        "pitchMax",
        Vars.FREELOOK.DEFAULT_PITCH_CEILING
    )
    local adjusted = nativePitchForVisualPitch(floor.original, maximumBias)
    adjusted = clamp(adjusted, floor.original, pitchMax - HEIGHT_TRANSFER_TOLERANCE)

    local wrote = pcall(function()
        fpp.pitchMin = adjusted
    end)
    local readback = readNumberProperty(fpp, "pitchMin", nil)
    if not wrote or not finite(readback)
        or math.abs(readback - adjusted) > NATIVE_PROPERTY_TOLERANCE then
        if not floor.failureLogged then
            Helpers.Log("failed to constrain native pitch floor for height bias")
            floor.failureLogged = true
        end
        return false
    end

    -- The visible pitch is native pitch plus the local counter-pitch. Raising
    -- the native floor by the inverse bias keeps their sum at the game's real
    -- downward limit instead of exposing another 1-30 degrees below the body.
    floor.active = true
    floor.applied = adjusted
    floor.componentToken = componentToken
    floor.failureLogged = false
    return true
end

local function updateHeightPitchFloor(fpp, maximumBias)
    if runtime.heightTransfer.active or runtime.heightTransfer.boundProperty then
        return true
    end
    if runtime.heightApplied then
        return applyHeightPitchFloor(fpp, maximumBias)
    end
    return restoreHeightPitchFloor(fpp)
end

local function clearHeightTransferLimitState()
    local transfer = runtime.heightTransfer
    transfer.originalPitchMin = nil
    transfer.originalPitchMax = nil
    transfer.boundProperty = nil
    transfer.componentToken = nil
end

local function restoreHeightTransferLimits(fpp)
    local transfer = runtime.heightTransfer
    local property = transfer.boundProperty
    if property ~= "pitchMin" and property ~= "pitchMax" then
        clearHeightTransferLimitState()
        return true
    end

    if not fpp then
        return false
    end
    if not isSameComponent(fpp, transfer.componentToken) then
        -- The old component cannot be restored and its limits must not be
        -- copied onto the replacement camera.
        clearHeightTransferLimitState()
        return true
    end

    local current = readNumberProperty(fpp, property, nil)
    if not finite(current) then
        return false
    end
    if math.abs(current - transfer.commandedNativePitch) > NATIVE_PROPERTY_TOLERANCE then
        -- A camera profile or another writer already replaced the temporary
        -- limit. Relinquish it without restoring stale values.
        clearHeightTransferLimitState()
        return true
    end

    local original = property == "pitchMin"
        and transfer.originalPitchMin
        or transfer.originalPitchMax
    if not finite(original) then
        return false
    end

    local restored = pcall(function()
        fpp[property] = original
    end)
    local readback = readNumberProperty(fpp, property, nil)
    if not restored or not finite(readback)
        or math.abs(readback - original) > NATIVE_PROPERTY_TOLERANCE then
        return false
    end

    clearHeightTransferLimitState()
    return true
end

local function abortHeightTransfer(fpp, reason, rememberFailure)
    local transfer = runtime.heightTransfer
    if not transfer.active then
        if transfer.boundProperty and not restoreHeightTransferLimits(fpp) then
            Helpers.Log("temporary native pitch limit is still pending restoration")
        end
        return
    end

    local sameComponent = isSameComponent(fpp, transfer.componentToken)
    local limitsRestored = restoreHeightTransferLimits(fpp)
    transfer.heldVisualOverride = nil
    if rememberFailure and not transfer.targetApplied then
        -- Weapon contexts cannot safely retain the height counter-pitch.
        -- If REDengine refuses the cosmetic handoff, prefer a possible snap back
        -- to the vanilla weapon camera over stranding the height hack in combat.
        runtime.heightApplied = false
        transfer.retryRemaining = 0.0
    elseif rememberFailure then
        -- A failed enable can leave native pitch partway through the handoff.
        -- Reset that partial state and retry only after normal gameplay has
        -- remained valid; never latch the feature off for the rest of the session.
        runtime.heightApplied = false
        transfer.retryRemaining = HEIGHT_TRANSFER_RETRY_DELAY
        if fpp and sameComponent then
            pcall(function()
                fpp:ResetPitch()
            end)
        end
    else
        transfer.retryRemaining = 0.0
    end
    transfer.active = false
    transfer.elapsed = 0.0
    if not limitsRestored then
        Helpers.Log("temporary native pitch limit is still pending restoration")
    end
    Helpers.Log("native pitch handoff aborted: " .. tostring(reason))
end

local function writeHeightTransferBound(fpp, nativePitch, requireOwnership)
    local transfer = runtime.heightTransfer
    local property = transfer.boundProperty
    if property ~= "pitchMin" and property ~= "pitchMax" then
        return false, "temporary pitch bound is missing"
    end
    if not isSameComponent(fpp, transfer.componentToken) then
        return false, "FPP camera changed during native pitch handoff"
    end
    if requireOwnership then
        local current = readNumberProperty(fpp, property, nil)
        if not finite(current)
            or math.abs(current - transfer.commandedNativePitch)
                > NATIVE_PROPERTY_TOLERANCE then
            return false, "temporary pitch bound changed by another system", true
        end
    end

    local wrote = pcall(function()
        fpp[property] = nativePitch
    end)
    local readback = readNumberProperty(fpp, property, nil)
    if not wrote or not finite(readback)
        or math.abs(readback - nativePitch) > NATIVE_PROPERTY_TOLERANCE then
        return false, property .. " rejected the temporary limit"
    end

    transfer.commandedNativePitch = nativePitch
    return true
end

local function beginHeightTransfer(fpp, nativePitch, desiredApplied, maximumBias)
    local transfer = runtime.heightTransfer
    if transfer.boundProperty and not restoreHeightTransferLimits(fpp) then
        return false, "previous temporary pitch limit is not restored"
    end

    local componentToken = getComponentToken(fpp)
    if not componentToken then
        return false, "FPP camera identity is unavailable"
    end
    local heldVisualOverride = transfer.heldVisualOverride
    transfer.heldVisualOverride = nil
    if not desiredApplied and not restoreHeightPitchFloor(fpp) then
        return false, "native pitch floor could not be restored"
    end

    local originalPitchMin = readNumberProperty(fpp, "pitchMin", nil)
    local originalPitchMax = readNumberProperty(fpp, "pitchMax", nil)
    if not finite(originalPitchMin) or not finite(originalPitchMax) then
        return false, "native pitch limits are unavailable"
    end
    if originalPitchMin >= originalPitchMax then
        return false, "invalid native pitch limits"
    end

    local currentHeightPitch = runtime.heightApplied
        and CameraCore.EvaluateHeightPitch(nativePitch, maximumBias)
        or 0.0
    local heldVisualPitch = finite(heldVisualOverride)
        and heldVisualOverride
        or nativePitch + currentHeightPitch
    local targetNativePitch = desiredApplied
        and nativePitchForVisualPitch(heldVisualPitch, maximumBias)
        or heldVisualPitch

    if math.abs(targetNativePitch - nativePitch) <= HEIGHT_TRANSFER_TOLERANCE then
        runtime.heightApplied = desiredApplied
        transfer.retryRemaining = 0.0
        return true
    end

    -- At an absolute pole there may be no native range into which the local
    -- correction can be transferred. Enabling the experiment can safely wait;
    -- disabling it for a weapon must still reach a valid vanilla camera pitch.
    local targetPitchMin = desiredApplied
        and nativePitchForVisualPitch(originalPitchMin, maximumBias)
        or originalPitchMin
    if targetNativePitch < targetPitchMin + HEIGHT_TRANSFER_TOLERANCE then
        targetNativePitch = targetPitchMin + HEIGHT_TRANSFER_TOLERANCE
    elseif targetNativePitch > originalPitchMax - HEIGHT_TRANSFER_TOLERANCE then
        if desiredApplied then
            return false, "target lies outside native pitch range"
        end
        targetNativePitch = originalPitchMax - HEIGHT_TRANSFER_TOLERANCE
    end

    transfer.active = true
    transfer.targetApplied = desiredApplied
    transfer.targetNativePitch = targetNativePitch
    transfer.commandedNativePitch = nativePitch
    transfer.heldVisualPitch = heldVisualPitch
    transfer.easedProgress = 0.0
    transfer.originalPitchMin = originalPitchMin
    transfer.originalPitchMax = originalPitchMax
    transfer.componentToken = componentToken
    transfer.elapsed = 0.0

    local property = targetNativePitch < nativePitch and "pitchMax" or "pitchMin"
    transfer.boundProperty = property
    local wrote, reason = writeHeightTransferBound(fpp, nativePitch, false)
    if not wrote then
        restoreHeightTransferLimits(fpp)
        transfer.active = false
        return false, reason
    end

    Helpers.Log((
        "native pitch handoff started: %.2f -> %.2f via %s"
    ):format(nativePitch, targetNativePitch, property))
    return true
end

local function updateHeightTransfer(fpp, nativePitch, context, delta)
    local transfer = runtime.heightTransfer
    local desiredApplied = context.heightDesiredApplied == true

    if not transfer.active and transfer.boundProperty then
        if not restoreHeightTransferLimits(fpp) then
            return
        end
    end

    if transfer.retryRemaining > 0.0 then
        transfer.retryRemaining = math.max(
            0.0,
            transfer.retryRemaining - math.max(tonumber(delta) or 0.0, 0.0)
        )
    end

    if runtime.heightApplied == nil then
        runtime.heightApplied = desiredApplied
        return
    end

    if transfer.active then
        if desiredApplied ~= transfer.targetApplied then
            -- Reverse an in-flight handoff around the exact visual pitch it was
            -- holding. Traversal and weapon state can change faster than the
            -- 80 ms transfer; dropping the local counter-pitch here exposes the
            -- partially moved native parent as an upward camera jump.
            local heldVisualPitch = transfer.heldVisualPitch
            abortHeightTransfer(fpp, "desired state changed", false)
            runtime.heightApplied = not desiredApplied
            transfer.heldVisualOverride = heldVisualPitch
        else
            -- A pitch bound only blocks motion on one side. Any motion that made
            -- it through since our previous command is real player input, so move
            -- the held visual pitch with it instead of mistaking it for handoff
            -- error or completing at an unrelated absolute angle.
            transfer.heldVisualPitch = transfer.heldVisualPitch
                + nativePitch - transfer.commandedNativePitch
            local targetNativePitch = transfer.targetApplied
                and nativePitchForVisualPitch(
                    transfer.heldVisualPitch,
                    context.heightPitch
                )
                or transfer.heldVisualPitch
            local targetPitchMin = transfer.targetApplied
                and nativePitchForVisualPitch(
                    transfer.originalPitchMin,
                    context.heightPitch
                )
                or transfer.originalPitchMin
            targetNativePitch = clamp(
                targetNativePitch,
                targetPitchMin + HEIGHT_TRANSFER_TOLERANCE,
                transfer.originalPitchMax - HEIGHT_TRANSFER_TOLERANCE
            )
            transfer.targetNativePitch = targetNativePitch

            transfer.elapsed = transfer.elapsed + math.max(tonumber(delta) or 0.0, 0.0)
            local progress = clamp(
                transfer.elapsed / HEIGHT_TRANSFER_DURATION,
                0.0,
                1.0
            )
            local eased = smoothstep(progress)
            local remainingBlend = 1.0
            if transfer.easedProgress < 1.0 then
                remainingBlend = clamp(
                    (eased - transfer.easedProgress)
                        / (1.0 - transfer.easedProgress),
                    0.0,
                    1.0
                )
            end
            local commandedNativePitch = nativePitch
                + (targetNativePitch - nativePitch) * remainingBlend
            local wrote, reason, ownershipLost = writeHeightTransferBound(
                fpp,
                commandedNativePitch,
                true
            )
            if not wrote then
                abortHeightTransfer(fpp, reason, not ownershipLost)
                if ownershipLost then
                    CameraCore.Yield(reason)
                    return false
                end
                return true
            end
            transfer.easedProgress = eased

            local reachedTarget = math.abs(nativePitch - targetNativePitch)
                <= HEIGHT_TRANSFER_TOLERANCE

            if progress >= 1.0 and reachedTarget then
                local limitsRestored = restoreHeightTransferLimits(fpp)
                transfer.active = false
                transfer.elapsed = 0.0
                runtime.heightApplied = transfer.targetApplied
                transfer.retryRemaining = 0.0
                if not limitsRestored then
                    Helpers.Log("temporary native pitch limit is still pending restoration")
                end
                Helpers.Log((
                    "native pitch handoff completed at %.2f"
                ):format(nativePitch))
                return
            elseif transfer.elapsed >= HEIGHT_TRANSFER_TIMEOUT then
                abortHeightTransfer(fpp, "native camera did not reach temporary limit", true)
                return
            end
        end
    end

    if not transfer.active
        and desiredApplied ~= runtime.heightApplied
        and transfer.retryRemaining <= 0.0 then
        local started, reason = beginHeightTransfer(
            fpp,
            nativePitch,
            desiredApplied,
            context.heightPitch
        )
        if not started then
            if desiredApplied then
                transfer.retryRemaining = HEIGHT_TRANSFER_RETRY_DELAY
                Helpers.Log(
                    "native pitch handoff unavailable; retry scheduled: "
                        .. tostring(reason)
                )
            else
                -- Never leave the experimental local counter-pitch on a weapon
                -- camera merely because a seamless native transfer was impossible.
                runtime.heightApplied = false
                transfer.retryRemaining = 0.0
                if fpp then
                    pcall(function()
                        fpp:ResetPitch()
                    end)
                end
                Helpers.Log(
                    "native pitch handoff unavailable; height forced off: "
                        .. tostring(reason)
                )
            end
        end
    end
end

local function updateHeightEligibility(context, delta)
    if context.heightEligible then
        runtime.heightEligibilityElapsed = math.min(
            HEIGHT_ENABLE_SETTLE_DURATION,
            runtime.heightEligibilityElapsed
                + math.max(tonumber(delta) or 0.0, 0.0)
        )
    else
        runtime.heightEligibilityElapsed = 0.0
        runtime.heightTransfer.retryRemaining = 0.0
    end

    -- Turning height off remains immediate for weapons and special camera
    -- contexts. Turning it back on waits through brief scene-tier, workspot, and
    -- weapon-slot flicker so traversal cannot start a doomed native handoff.
    context.heightDesiredApplied = context.heightEligible == true
        and runtime.heightEligibilityElapsed >= HEIGHT_ENABLE_SETTLE_DURATION
end

local function evaluateAppliedHeightPitch(nativePitch, context)
    local transfer = runtime.heightTransfer
    if transfer.active then
        return transfer.heldVisualPitch - nativePitch
    end
    if runtime.heightApplied then
        return CameraCore.EvaluateHeightPitch(nativePitch, context.heightPitch)
    end
    return 0.0
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

local function getAvailablePitchLimits(hasWeapon, basePitch, maximumHeightBias)
    local _, relativeDown, relativeUp = getFreeLookLimits(hasWeapon)
    local floor = runtime.pitchFloor or Vars.FREELOOK.DEFAULT_PITCH_FLOOR
    local ceiling = runtime.pitchCeiling or Vars.FREELOOK.DEFAULT_PITCH_CEILING
    local nativeFloor = nativePitchForVisualPitch(floor, maximumHeightBias)
    local nativeCeiling = nativePitchForVisualPitch(ceiling, maximumHeightBias)
    local availableDown = math.max(0.0, basePitch - nativeFloor)
    local availableUp = math.max(0.0, nativeCeiling - basePitch)

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

local function getPitchFloor(yaw, maxYaw, basePitch, maximumHeightBias)
    local rearProgress = smoothstep(
        (math.abs(yaw) / maxYaw
            - Vars.FREELOOK.REAR_PITCH_CLAMP_START_YAW_PROGRESS)
            / (1.0 - Vars.FREELOOK.REAR_PITCH_CLAMP_START_YAW_PROGRESS)
    )
    local visualFloor = runtime.pitchFloor
        or Vars.FREELOOK.DEFAULT_PITCH_FLOOR
    visualFloor = visualFloor
        + (Vars.FREELOOK.REAR_PITCH_FLOOR - visualFloor) * rearProgress
    local nativeFloor = nativePitchForVisualPitch(
        visualFloor,
        maximumHeightBias
    )
    return nativeFloor - basePitch
end

local function stepHeadCone(
    yaw,
    pitch,
    yawDelta,
    pitchDelta,
    hasWeapon,
    basePitch,
    maximumHeightBias
)
    local maxYaw, maxPitchDown, maxPitchUp = getFreeLookLimits(hasWeapon)
    maxPitchDown, maxPitchUp = getAvailablePitchLimits(
        hasWeapon,
        basePitch,
        maximumHeightBias
    )

    if maxYaw <= 0.0001 then
        return 0.0, 0.0
    end

    if not hasWeapon and pitchDelta < 0.0 then
        local prospectiveYaw = clamp(yaw + yawDelta, -maxYaw, maxYaw)
        local pitchFloor = getPitchFloor(
            prospectiveYaw,
            maxYaw,
            basePitch,
            maximumHeightBias
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
            basePitch,
            maximumHeightBias
        )
        resultPitch = math.max(resultPitch, pitchFloor)
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
            fovDelta = 0.0,
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

local function applyFreeLookInput(delta, fpp, hasWeapon, basePitch, maximumHeightBias)
    local free = Vars.FREELOOK
    local sensitivity = Config.inner.freeLookSensitivity / free.DEFAULT_SENSITIVITY
    local zoom = readNumberProperty(fpp, "zoom", 1.0)
    if zoom <= 0.05 then
        zoom = 1.0
    end

    local invertX = runtime.invertX and -1.0 or 1.0
    local invertY = runtime.invertY and -1.0 or 1.0
    local mouseScale = free.MOUSE_DEGREES_PER_UNIT * sensitivity / zoom
    local yawDelta = -runtime.input.mouseX * invertX * mouseScale
    local pitchDelta = runtime.input.mouseY * invertY * mouseScale

    local controllerScale = free.CONTROLLER_DEGREES_PER_SECOND * sensitivity * delta
    yawDelta = yawDelta
        - inputAxis(runtime.input.stickX) * invertX * controllerScale
    pitchDelta = pitchDelta
        + inputAxis(runtime.input.stickY) * invertY * controllerScale

    runtime.freeYaw, runtime.freePitch = stepHeadCone(
        runtime.freeYaw,
        runtime.freePitch,
        yawDelta,
        pitchDelta,
        hasWeapon,
        basePitch,
        maximumHeightBias
    )
    runtime.rawYaw = runtime.freeYaw
    runtime.rawPitch = runtime.freePitch
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
        unlockNativeInput(Helpers.GetFPP())
    end
end

local function suspendForConflict(fpp, positionDelta, orientationDot, fovDelta)
    abortHeightTransfer(fpp, "camera conflict", false)
    if not restoreHeightPitchFloor(fpp) then
        Helpers.Log("native pitch floor is still pending restoration after camera conflict")
    end

    runtime.heightApplied = nil
    runtime.heightEligibilityElapsed = 0.0
    runtime.heightTransfer.retryRemaining = 0.0
    runtime.pendingFreeLook = false
    runtime.frozen = false
    clearInput()
    runtime.freeYaw = 0
    runtime.freePitch = 0
    runtime.rawYaw = 0
    runtime.rawPitch = 0
    runtime.pitchFloor = nil
    runtime.pitchCeiling = nil
    runtime.entryNativePitch = 0.0
    runtime.entryNativeOrientation = nil
    runtime.returnElapsed = 0
    resetBodyBlendTracking()
    unlockNativeInput(fpp)
    dropCameraOwnership()

    local conflict = runtime.conflict
    conflict.active = true
    conflict.reason = "another system is modifying the first-person camera"
    conflict.positionDelta = positionDelta
    conflict.orientationDot = orientationDot
    conflict.fovDelta = fovDelta
    Helpers.Log((
        "camera conflict detected; camera changes suspended for this session: "
            .. "position=%.5f orientationDot=%.7f fov=%.3f"
    ):format(positionDelta, orientationDot, fovDelta))
    setMode(MODE.CONFLICT, "another camera writer detected")
end

local function detectCompetingWriter(fpp, actualPosition, actualOrientation, actualFov, delta)
    if not runtime.lastApplied then
        return false
    end

    local positionDelta = math.abs(actualPosition.x - runtime.lastApplied.position.x)
        + math.abs(actualPosition.y - runtime.lastApplied.position.y)
        + math.abs(actualPosition.z - runtime.lastApplied.position.z)
    local orientationDot = math.abs(quaternionDot(actualOrientation, runtime.lastApplied.orientation))
    local fovDelta = finite(actualFov) and finite(runtime.lastApplied.fov)
        and math.abs(actualFov - runtime.lastApplied.fov)
        or 0.0
    local disturbed = positionDelta > CAMERA_POSITION_TOLERANCE
        or orientationDot < CAMERA_ORIENTATION_DOT_TOLERANCE
        or fovDelta > CAMERA_FOV_TOLERANCE

    if runtime.mode == MODE.FREELOOK
        and not runtime.freeLookLocalWriterLogged
        and (positionDelta > 0.0005 or orientationDot < 0.99999) then
        runtime.freeLookLocalWriterLogged = true
        Helpers.Log((
            "freelook local transform changed between composer updates: position=%.5f orientationDot=%.7f"
        ):format(positionDelta, orientationDot))
    end

    if disturbed then
        runtime.interferenceElapsed = runtime.interferenceElapsed
            + math.min(math.max(tonumber(delta) or 0.0, 0.0), 0.10)
    else
        runtime.interferenceElapsed = 0.0
    end

    if runtime.interferenceElapsed >= CAMERA_INTERFERENCE_DURATION then
        suspendForConflict(fpp, positionDelta, orientationDot, fovDelta)
        return true
    end
    return false
end

local function composeAndWrite(fpp, context, delta)
    if not captureBaseline(fpp) or not runtime.baseline then
        return false
    end

    local actualPosition = fpp:GetLocalPosition()
    local actualOrientation = fpp:GetLocalOrientation()
    if not actualPosition or not actualOrientation then
        return false
    end
    local actualFov = nil
    if runtime.lastApplied and finite(runtime.lastApplied.fov) then
        local ok, value = pcall(function()
            return fpp:GetFOV()
        end)
        if ok and finite(value) then
            actualFov = value
        end
    end
    if detectCompetingWriter(
        fpp,
        actualPosition,
        actualOrientation,
        actualFov,
        delta
    ) then
        return false
    end

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
    if runtime.heightTransfer.active
        and runtime.mode ~= MODE.FREELOOK
        and runtime.mode ~= MODE.RETURNING then
        local transfer = runtime.heightTransfer
        -- CET's onUpdate observes the old parent pitch, then REDengine applies
        -- our moving temporary bound before rendering. Predict the clamped
        -- parent for this frame so each brief handoff step receives the matching
        -- local counter-pitch instead of lagging behind by one rendered frame.
        if transfer.boundProperty == "pitchMax" then
            compositionNativePitch = math.min(
                nativePitch,
                transfer.commandedNativePitch
            )
        elseif transfer.boundProperty == "pitchMin" then
            compositionNativePitch = math.max(
                nativePitch,
                transfer.commandedNativePitch
            )
        end
    elseif runtime.heightPitchFloor.active
        and finite(runtime.heightPitchFloor.applied) then
        -- A newly raised persistent floor is clamped after CET's onUpdate just
        -- like the temporary handoff bounds. Precompose that first clamped frame
        -- so enabling/reloading the experiment at full look-down cannot flash.
        compositionNativePitch = math.max(
            nativePitch,
            runtime.heightPitchFloor.applied
        )
    end

    local effectiveNativePitch = compositionNativePitch
    if runtime.mode == MODE.FREELOOK or runtime.mode == MODE.RETURNING then
        local floor = runtime.pitchFloor or Vars.FREELOOK.DEFAULT_PITCH_FLOOR
        local ceiling = runtime.pitchCeiling or Vars.FREELOOK.DEFAULT_PITCH_CEILING
        local appliedHeightBias = runtime.heightApplied and context.heightPitch or 0.0
        local effectiveFloor = nativePitchForVisualPitch(floor, appliedHeightBias)
        local effectiveCeiling = nativePitchForVisualPitch(ceiling, appliedHeightBias)
        -- `freePitch` emulates native parent pitch, but the limits belong to the
        -- final visible camera. Invert the experimental pitch mapping so its
        -- constant downward bias cannot extend freelook below the native floor.
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
            effectiveFloor - virtualBasePitch,
            effectiveCeiling - virtualBasePitch
        )
        effectiveNativePitch = virtualBasePitch + runtime.freePitch
    end

    -- During freelook the real parent is frozen, so drive the height adjustment
    -- from the emulated native pitch as well.
    runtime.heightPitch = evaluateAppliedHeightPitch(effectiveNativePitch, context)
    local visualEffectivePitch = effectiveNativePitch + runtime.heightPitch
    local bodyDriverPitch = visualEffectivePitch
    local body = CameraCore.EvaluateBody(
        bodyDriverPitch,
        context.crouching,
        runtime.baseline.fov
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
        fovDelta = 0.0,
    }
    if runtime.mode == MODE.FREELOOK or runtime.mode == MODE.RETURNING then
        freeOffset = CameraCore.EvaluateFreeLook(
            runtime.freeYaw,
            visualEffectivePitch,
            context.hasWeapon
        )
    end
    local bodyInfluence = (runtime.mode == MODE.FREELOOK or runtime.mode == MODE.RETURNING)
        and (1.0 - freeOffset.sideProgress)
        or 1.0
    bodyInfluence = bodyInfluence * bodyBlend
    runtime.bodyProgress = body.progress * bodyInfluence
    runtime.bodyPitch = body.pitch * bodyInfluence
    body.fov = runtime.baseline.fov
        + (body.fov - runtime.baseline.fov) * bodyInfluence

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
    -- OffsetToReference also contains virtual pitch motion used by height and
    -- freelook. Fade only its ordinary FOV/body component during weapon changes;
    -- the independent height handoff must continue holding the visible gaze.
    -- Full physical FOV compensation was calibrated alongside the mod's FOV
    -- correction. At a deliberately fixed narrow FOV it looks too far forward,
    -- so retain a reduced amount without weakening any other camera channel.
    local bodyCurveInfluence = bodyBlend
    if Config.inner.dontChangeFov then
        bodyCurveInfluence = bodyCurveInfluence * FIXED_FOV_POSITION_COMPENSATION
    end
    bodySpaceMotion.forward = bodySpaceMotion.forward
        - bodyCurveMotion.forward * (1.0 - bodyCurveInfluence)
    bodySpaceMotion.vertical = bodySpaceMotion.vertical
        - bodyCurveMotion.vertical * (1.0 - bodyCurveInfluence)

    -- Looking upward moves the native parent both up and backward. Always cancel
    -- the unwanted backward drift. Keep its vertical lift near level view, but
    -- progressively return the *local* camera to the recorded visual position
    -- while looking down. The native parent remains elevated, and no opposing
    -- angular fade is needed, so vertical input stays 1:1.
    local nativePosition = NativeCameraCurve.Evaluate(effectiveNativePitch)
    local visualPosition = NativeCameraCurve.Evaluate(visualEffectivePitch)
    bodySpaceMotion.forward = bodySpaceMotion.forward
        + visualPosition.forward - nativePosition.forward
    local positionRestore = evaluateHeightPositionRestore(visualEffectivePitch)
    bodySpaceMotion.vertical = bodySpaceMotion.vertical
        + (visualPosition.vertical - nativePosition.vertical) * positionRestore

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
    local bodySpacePitch = runtime.heightPitch
    if runtime.mode == MODE.FREELOOK or runtime.mode == MODE.RETURNING then
        -- This is usually identical to freePitch. Expressing it as the virtual
        -- minus actual parent pitch also cancels any native movement that escaped
        -- the input consumer without changing the visible pose.
        bodySpacePitch = bodySpacePitch
            + effectiveNativePitch - compositionNativePitch
    end
    if math.abs(bodySpacePitch) > 0.0001 then
        -- The body-presence offset is authored in the local frame the native
        -- camera would have at the visual pitch. Rotate it through both the
        -- experimental height counter-pitch and any freelook pitch.
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
    local orientation = headLocalOrientation(
        orientationNativePitch,
        runtime.heightPitch + runtime.bodyPitch + freeOffset.pitch,
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

    local transformOk = pcall(function()
        fpp:SetLocalTransform(toVector(position), orientation)
    end)
    if not transformOk then
        return false
    end

    local appliedFov = nil
    local fovOk = true
    if not Config.inner.dontChangeFov then
        appliedFov = body.fov + freeOffset.fovDelta
        fovOk = pcall(function()
            fpp:SetFOV(appliedFov)
        end)
    end
    runtime.lastApplied = {
        position = position,
        orientation = quaternionCopy(orientation),
        fov = fovOk and appliedFov or nil,
    }
    return fovOk
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
    if runtime.conflict.active or runtime.frozen or runtime.reacquireRemaining > 0.0 then
        return false
    end
    if runtime.mode == MODE.FREELOOK then
        return true
    end
    if runtime.heightTransfer.active then
        runtime.pendingFreeLook = true
        Helpers.Log("freelook entry deferred until native pitch handoff completes")
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

    if runtime.heightPitchFloor.active then
        -- The experimental height feature normally raises pitchMin to keep the
        -- native camera out of the neck. Leaving REDengine parked directly on
        -- that artificial bound during freelook causes hidden positional clamp
        -- corrections even when its recovered pitch barely changes. Freelook
        -- owns the visible clamp itself, so use the original component range
        -- until normal camera composition resumes after the return.
        if not restoreHeightPitchFloor(fpp) then
            Helpers.Log("freelook could not suspend experimental native pitch floor")
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
        if runtime.heightPitchFloor.active
            and finite(runtime.heightPitchFloor.original) then
            -- The component currently exposes our raised *native* floor. The
            -- freelook clamp below works in final visible space and performs its
            -- own inverse height mapping, so seed it with the untouched game
            -- floor or the experimental bias would be counted twice.
            componentFloor = runtime.heightPitchFloor.original
        end
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
    clearInput()
    runtime.inputSeen.mouseX = false
    runtime.inputSeen.mouseY = false
    runtime.inputSeen.stickX = false
    runtime.inputSeen.stickY = false
    clearInputStats()
    runtime.freeLookParentDriftLogged = false
    runtime.freeLookParentOrientationDriftLogged = false
    runtime.freeLookLocalWriterLogged = false
    lockNativeInput(fpp)
    setMode(MODE.FREELOOK, "input pressed")
    return true
end

function CameraCore.EndFreeLook(fast)
    runtime.pendingFreeLook = false
    if runtime.mode ~= MODE.FREELOOK and runtime.mode ~= MODE.RETURNING then
        return
    end

    clearInput()
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
    -- Native camera input belongs to the player again as soon as the key is
    -- released. Any visual return animation continues without holding input.
    unlockNativeInput(Helpers.GetFPP())

    local immediate = fast == true or not Config.inner.smoothRestore
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
    if runtime.conflict.active or runtime.frozen then
        return
    end

    local elapsedDelta = math.max(tonumber(delta) or 0.0, 0.0)
    if runtime.reacquireRemaining > 0.0 then
        runtime.reacquireRemaining = math.max(
            0.0,
            runtime.reacquireRemaining - elapsedDelta
        )
        return
    end

    local fpp = Helpers.GetFPP()
    if not fpp then
        abortHeightTransfer(nil, "FPP camera unavailable", false)
        restoreHeightPitchFloor(nil)
        runtime.heightApplied = nil
        runtime.heightEligibilityElapsed = 0.0
        runtime.reacquireRemaining = CAMERA_REACQUIRE_DURATION
        clearTransientCameraState(nil)
        dropCameraOwnership()
        setMode(MODE.SUSPENDED, "FPP camera unavailable")
        return
    end

    if runtime.ownsCamera
        and not isSameComponent(fpp, runtime.ownerComponentToken) then
        CameraCore.Yield("FPP camera component changed")
        return
    end

    local inputDelta = math.min(elapsedDelta, 0.10)
    maintainInputUnlock(fpp)
    updateHeightEligibility(context, elapsedDelta)
    updateBodyBlend(context, elapsedDelta)

    if not context.heightCanPreserveTransition
        and (runtime.heightApplied == true
            or runtime.heightTransfer.active
            or runtime.heightPitchFloor.active) then
        -- Truly incompatible cameras must never inherit the height offset. The
        -- less destructive held-pitch exit below is reserved for ordinary
        -- on-foot transitions where the FPP parent remains meaningful.
        CameraCore.Yield("height context invalid")
        return
    end

    if (runtime.mode == MODE.FREELOOK or runtime.mode == MODE.RETURNING)
        and not context.freeEligible then
        -- End the local head offset first, then let the normal context handling
        -- below decide whether body/height composition can continue. A hard
        -- Suspend here used to reset an otherwise valid traversal camera.
        CameraCore.EndFreeLook(true)
    end

    if runtime.mode == MODE.FREELOOK or runtime.mode == MODE.RETURNING then
        maintainNativeInputLock(fpp)
        if runtime.mode == MODE.FREELOOK then
            applyFreeLookInput(
                inputDelta,
                fpp,
                context.hasWeapon,
                runtime.entryNativePitch,
                runtime.heightApplied and context.heightPitch or 0.0
            )
        else
            updateReturn(elapsedDelta)
        end
        composeAndWrite(fpp, context, elapsedDelta)
        return
    end

    local preservingHeightTransition = context.heightCanPreserveTransition
        and not context.heightCanTransfer
        and (runtime.heightApplied == true
            or runtime.heightTransfer.active
            or runtime.heightPitchFloor.active)
    if not context.bodyContextEligible
        and not context.heightCanTransfer
        and not preservingHeightTransition then
        CameraCore.Yield("camera context invalid")
        return
    end

    if runtime.heightApplied == nil and not context.heightEligible then
        runtime.heightApplied = false
    end

    local bodyManaged = context.bodyEligible
        or runtime.bodyTransition.active
        or (tonumber(runtime.bodyBlend) or 0.0) > 0.0001
    local heightManaged = context.heightEligible
        or runtime.heightApplied == true
        or runtime.heightTransfer.active
        or runtime.heightTransfer.boundProperty ~= nil
    if not bodyManaged and not heightManaged then
        restoreHeightPitchFloor(fpp)
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
    if updateHeightTransfer(fpp, nativePitch, context, elapsedDelta) == false then
        return
    end
    if not updateHeightPitchFloor(fpp, context.heightPitch) then
        CameraCore.Yield("native pitch floor ownership unavailable")
        return
    end
    if not context.bodyEligible
        and not context.heightCanTransfer
        and runtime.heightApplied ~= true
        and not runtime.heightTransfer.active
        and runtime.heightTransfer.boundProperty == nil
        and not bodyManaged then
        -- The transition-safe height exit has completed. Release ownership now;
        -- unlike Suspend(), this does not reset the native pitch we just moved
        -- into the held visual orientation.
        restoreHeightPitchFloor(fpp)
        releaseCamera(fpp)
        setMode(MODE.SUSPENDED, "height transition preserved")
        return
    end
    if runtime.pendingFreeLook and not runtime.heightTransfer.active then
        runtime.pendingFreeLook = false
        if context.freeEligible and CameraCore.BeginFreeLook(context) then
            composeAndWrite(fpp, context, elapsedDelta)
            return
        end
    end
    runtime.heightPitch = evaluateAppliedHeightPitch(nativePitch, context)
    local visualPitch = nativePitch + runtime.heightPitch
    runtime.bodyProgress = normalizeBodyPitch(visualPitch)
    -- While the experiment is enabled, retain one baseline even where the bias
    -- reaches zero. Releasing and recapturing around that boundary causes visible
    -- one-frame transform chatter as native pitch fluctuates across the threshold.
    heightManaged = context.heightEligible
        or runtime.heightApplied == true
        or runtime.heightTransfer.active
        or runtime.heightTransfer.boundProperty ~= nil
    if runtime.bodyProgress <= 0.0001 and not heightManaged then
        releaseCamera(fpp)
        setMode(MODE.NATIVE, "camera corrections inactive")
        return
    end

    if not captureBaseline(fpp) then
        return
    end
    setMode(MODE.BODY, "camera correction active")
    composeAndWrite(fpp, context, elapsedDelta)
end

function CameraCore.RestoreBaselineFOV()
    local fpp = Helpers.GetFPP()
    if not fpp or not runtime.baseline or not runtime.lastApplied
        or not isSameComponent(fpp, runtime.ownerComponentToken)
        or not finite(runtime.lastApplied.fov) then
        return
    end

    local ok, currentFov = pcall(function()
        return fpp:GetFOV()
    end)
    if ok and finite(currentFov)
        and math.abs(currentFov - runtime.lastApplied.fov) <= CAMERA_FOV_TOLERANCE then
        local restored = pcall(function()
            fpp:SetFOV(runtime.baseline.fov)
        end)
        if restored then
            runtime.lastApplied.fov = nil
        end
    end
end

clearTransientCameraState = function(fpp)
    runtime.pendingFreeLook = false
    clearInput()
    runtime.freeYaw = 0
    runtime.freePitch = 0
    runtime.rawYaw = 0
    runtime.rawPitch = 0
    runtime.heightPitch = 0
    resetBodyBlendTracking()
    runtime.pitchFloor = nil
    runtime.pitchCeiling = nil
    runtime.entryNativePitch = 0.0
    runtime.entryNativeOrientation = nil
    runtime.returnElapsed = 0
    unlockNativeInput(fpp)
end

local function clearConflictState()
    local conflict = runtime.conflict
    conflict.active = false
    conflict.reason = nil
    conflict.positionDelta = 0.0
    conflict.orientationDot = 1.0
    conflict.fovDelta = 0.0
    runtime.interferenceElapsed = 0.0
end

function CameraCore.Yield(reason)
    local fpp = Helpers.GetFPP()
    abortHeightTransfer(fpp, reason or "camera ownership yielded", false)
    if not restoreHeightPitchFloor(fpp) then
        Helpers.Log("native pitch floor is still pending restoration while yielding camera ownership")
    end
    runtime.heightApplied = nil
    runtime.heightEligibilityElapsed = 0.0
    runtime.heightTransfer.retryRemaining = 0.0
    runtime.frozen = false
    runtime.reacquireRemaining = CAMERA_REACQUIRE_DURATION
    clearTransientCameraState(fpp)
    dropCameraOwnership()
    if runtime.conflict.active then
        setMode(MODE.CONFLICT, reason or "camera ownership yielded")
    else
        setMode(MODE.SUSPENDED, reason or "camera ownership yielded")
    end
end

function CameraCore.Suspend(reason)
    local fpp = Helpers.GetFPP()
    local heightComponentToken = runtime.heightTransfer.componentToken
        or runtime.heightPitchFloor.componentToken
        or runtime.ownerComponentToken
    local resetNativePitch = runtime.heightApplied == true
        or runtime.heightTransfer.active
        or runtime.heightPitchFloor.active
    local canResetNativePitch = resetNativePitch
        and isSameComponent(fpp, heightComponentToken)
    abortHeightTransfer(fpp, reason or "suspended", false)
    restoreHeightPitchFloor(fpp)
    runtime.heightApplied = resetNativePitch and false or nil
    runtime.heightEligibilityElapsed = 0.0
    runtime.heightTransfer.retryRemaining = 0.0
    runtime.frozen = false
    runtime.reacquireRemaining = 0.0
    clearTransientCameraState(fpp)
    releaseCamera(fpp)
    if canResetNativePitch and fpp then
        pcall(function()
            fpp:ResetPitch()
        end)
    end
    if runtime.conflict.active then
        setMode(MODE.CONFLICT, reason or "suspended")
    else
        setMode(MODE.SUSPENDED, reason or "suspended")
    end
end

function CameraCore.ResetHeightAdjustment(reason)
    -- UI changes deliberately return the visible camera to level first. The
    -- regular height handoff then transfers the new amount into native pitch,
    -- producing vertical movement without visibly pitching the view up or down.
    CameraCore.Suspend(reason or "height adjustment changed")
    runtime.heightApplied = false
end

function CameraCore.Pause(reason)
    if runtime.conflict.active then
        return
    end

    local fpp = Helpers.GetFPP()
    clearInput()
    runtime.pendingFreeLook = false
    runtime.freeYaw = 0
    runtime.freePitch = 0
    runtime.rawYaw = 0
    runtime.rawPitch = 0
    runtime.pitchFloor = nil
    runtime.pitchCeiling = nil
    runtime.entryNativePitch = 0.0
    runtime.entryNativeOrientation = nil
    runtime.returnElapsed = 0
    unlockNativeInput(fpp)
    runtime.frozen = true

    -- Escape pauses CET updates, but REDengine renders another gameplay frame
    -- while closing the menu. Keep our already-composed transform and baseline
    -- alive so that frame cannot expose the raw neck/body camera. The next
    -- onUpdate resumes composition from the same ownership state.
    setMode(MODE.SUSPENDED, reason or "game paused")
end

function CameraCore.Resume(reason)
    if runtime.conflict.active then
        runtime.frozen = false
        return false
    end
    if not runtime.frozen then
        return true
    end

    runtime.frozen = false
    local fpp = Helpers.GetFPP()
    if not runtime.ownsCamera then
        return true
    end
    if not fpp or not isSameComponent(fpp, runtime.ownerComponentToken) then
        CameraCore.Yield("FPP camera changed while paused")
        return false
    end

    local transfer = runtime.heightTransfer
    if transfer.boundProperty then
        if not isSameComponent(fpp, transfer.componentToken) then
            CameraCore.Yield("native pitch handoff component changed while paused")
            return false
        end
        local currentBound = readNumberProperty(fpp, transfer.boundProperty, nil)
        if not finite(currentBound)
            or math.abs(currentBound - transfer.commandedNativePitch)
                > NATIVE_PROPERTY_TOLERANCE then
            Helpers.Log("native pitch bound changed while paused; stale handoff discarded")
            CameraCore.Yield("native pitch handoff owner changed while paused")
            return false
        end
    end

    if runtime.lastApplied then
        local actualPosition = fpp:GetLocalPosition()
        local actualOrientation = fpp:GetLocalOrientation()
        if not actualPosition or not actualOrientation then
            CameraCore.Yield("FPP camera unavailable after pause")
            return false
        end

        local positionDelta = math.abs(actualPosition.x - runtime.lastApplied.position.x)
            + math.abs(actualPosition.y - runtime.lastApplied.position.y)
            + math.abs(actualPosition.z - runtime.lastApplied.position.z)
        local orientationDot = math.abs(quaternionDot(
            actualOrientation,
            runtime.lastApplied.orientation
        ))
        local fovChanged = false
        if finite(runtime.lastApplied.fov) then
            local ok, actualFov = pcall(function()
                return fpp:GetFOV()
            end)
            fovChanged = not ok or not finite(actualFov)
                or math.abs(actualFov - runtime.lastApplied.fov) > CAMERA_FOV_TOLERANCE
        end

        if positionDelta > CAMERA_POSITION_TOLERANCE
            or orientationDot < CAMERA_ORIENTATION_DOT_TOLERANCE
            or fovChanged then
            Helpers.Log("camera changed while paused; stale baseline discarded")
            CameraCore.Yield("camera owner changed while paused")
            return false
        end
    end

    runtime.reacquireRemaining = 0.0
    setMode(MODE.SUSPENDED, reason or "game resumed")
    return true
end

function CameraCore.RetryConflict()
    if not runtime.conflict.active then
        return false
    end

    local fpp = Helpers.GetFPP()
    abortHeightTransfer(fpp, "camera conflict retry", false)
    restoreHeightPitchFloor(fpp)
    clearConflictState()
    runtime.frozen = false
    runtime.reacquireRemaining = CAMERA_REACQUIRE_DURATION
    setMode(MODE.SUSPENDED, "camera conflict retry requested")
    Helpers.Log("camera conflict cleared; camera ownership retry armed")
    return true
end

function CameraCore.OnSessionStart()
    CameraCore.Yield("new session")
    local hadConflict = runtime.conflict.active
    clearConflictState()
    if hadConflict then
        Helpers.Log("camera conflict cleared for new session")
    end
    runtime.reacquireRemaining = CAMERA_REACQUIRE_DURATION
    setMode(MODE.SUSPENDED, "new session")
end

function CameraCore.HasConflict()
    return runtime.conflict.active
end

function CameraCore.GetConflictState()
    return {
        active = runtime.conflict.active,
        reason = runtime.conflict.reason,
        positionDelta = runtime.conflict.positionDelta,
        orientationDot = runtime.conflict.orientationDot,
        fovDelta = runtime.conflict.fovDelta,
    }
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
        heightPitch = runtime.heightPitch,
        heightApplied = runtime.heightApplied,
        heightEligibilityElapsed = runtime.heightEligibilityElapsed,
        heightTransferActive = runtime.heightTransfer.active,
        heightTransferTarget = runtime.heightTransfer.targetNativePitch,
        heightTransferRetryRemaining = runtime.heightTransfer.retryRemaining,
        freeYaw = runtime.freeYaw,
        freePitch = runtime.freePitch,
        rawYaw = runtime.rawYaw,
        rawPitch = runtime.rawPitch,
        pitchFloor = runtime.pitchFloor,
        pitchCeiling = runtime.pitchCeiling,
        entryNativePitch = runtime.entryNativePitch,
        ownsCamera = runtime.ownsCamera,
        ownerComponentToken = runtime.ownerComponentToken,
        frozen = runtime.frozen,
        reacquireRemaining = runtime.reacquireRemaining,
        conflictActive = runtime.conflict.active,
        conflictReason = runtime.conflict.reason,
        conflictPositionDelta = runtime.conflict.positionDelta,
        conflictOrientationDot = runtime.conflict.orientationDot,
        conflictFovDelta = runtime.conflict.fovDelta,
        inputLocked = runtime.lock.active,
        inputLockMechanism = "action consumer",
    }
end

return CameraCore

local LessUnimmersiveFirstPerson = { version = "1.0.0" }
local Cron = require("Modules/Cron")
local GameSettings = require("Modules/GameSettings")

-- States
local inited = false
local isLoaded = false
local defaultFOV = 68
local initialFOV = 68
local isOverlayOpen = false
local isEnabled = true

-- Helpers
local fpp = nil
function GetPitch()
    local ok, res = pcall(function()
        -- local player = Game.GetPlayer()
        -- if not player then
        --     return
        -- end
        -- local fpp = player:GetFPPCameraComponent()
        if not fpp then
            return
        end
        local matrix = fpp:GetLocalToWorld()
        if not matrix then
            return
        end
        local rotation = matrix:GetRotation(matrix)
        if not rotation then
            return
        end

        return rotation.pitch
    end)

    if ok then
        return res
    end
end

local defaultSensitivityX = 1
local defaultSensitivityY = 1
local isFreeObservation = false
function LockMovement()
    defaultSensitivityX = GameSettings.Get('/controls/fppcameramouse/FPP_MouseX')
    defaultSensitivityY = GameSettings.Get('/controls/fppcameramouse/FPP_MouseY')
    GameSettings.Set('/controls/fppcameramouse/FPP_MouseX', 0)
    GameSettings.Set('/controls/fppcameramouse/FPP_MouseY', 0)
    isFreeObservation = true
end
function UnlockMovement()
    GameSettings.Set('/controls/fppcameramouse/FPP_MouseX', defaultSensitivityX)
    GameSettings.Set('/controls/fppcameramouse/FPP_MouseY', defaultSensitivityY)
    isFreeObservation = false
end

function GetFOV()
    if not fpp then
        return
    end

    local fov = fpp:GetFOV()
    if fov < 10 then
        fov = 68
    end
    return fov
end

local wasReset = true
function ResetCamera(force)
    if not fpp then
        return
    end

    if not wasReset or force then
        fpp:SetLocalPosition(Vector4.new(0.0, 0.0, 0, 1.0))
        fpp:SetLocalOrientation(Quaternion.new(0.0, 0.0, 0, 1.0))
        fpp:SetFOV(defaultFOV)
        wasReset = true
    end
end
function SetCamera(shift, height, lean, fov)
    if not fpp then
        return
    end

    if lean ~= nil then
        fpp:SetLocalOrientation(GetSingleton('EulerAngles'):ToQuat(EulerAngles.new(0, lean, 0)))
    end

    fpp:SetLocalPosition(Vector4.new(0, height, shift, 1.0))
    fpp:SetFOV(fov)
end

function SetRelativeCamera(roll, pitch, yaw, x, y, z, fov)
    if not fpp then
        return
    end
    fpp:SetLocalOrientation(GetSingleton('EulerAngles'):ToQuat(EulerAngles.new(roll, pitch, yaw)))

    if x and y and z then
        fpp:SetLocalPosition(Vector4.new(x, y, z, 1.0))
    end

    fpp:SetFOV(fov)
end

function HasBetterVehicleFirstPerson()
    local bvfp = GetMod("BetterVehicleFirstPerson")
    return bvfp ~= nil
end

function HasMountedVehicle()
    return not not Game['GetMountedVehicle;GameObject'](Game.GetPlayer())
end
function IsPlayerDriver()
    local veh = Game['GetMountedVehicle;GameObject'](Game.GetPlayer())
    if veh then
        return veh:IsPlayerDriver()
    end
end
function IsInVehicle()
    return Game.GetWorkspotSystem():IsActorInWorkspot(Game.GetPlayer())
            and Game.GetWorkspotSystem():GetExtendedInfo(Game.GetPlayer()).isActive
            and HasMountedVehicle()
end
function GetSceneTier()
    local blackboardDefs = Game.GetAllBlackboardDefs()
    local blackboardPSM = Game.GetBlackboardSystem():GetLocalInstanced(Game.GetPlayer():GetEntityID(), blackboardDefs.PlayerStateMachine)
    return blackboardPSM:GetInt(blackboardDefs.PlayerStateMachine.SceneTier)
end

function IsCarryingBody()
    local blackboardDefs = Game.GetAllBlackboardDefs()
    local blackboardPSM = Game.GetBlackboardSystem():GetLocalInstanced(Game.GetPlayer():GetEntityID(), blackboardDefs.PlayerStateMachine)
    -- .Carrying
    return blackboardPSM:GetInt(blackboardDefs.PlayerStateMachine.BodyCarrying) > 0
end
function IsCarrying()
    local blackboardDefs = Game.GetAllBlackboardDefs()
    local blackboardPSM = Game.GetBlackboardSystem():GetLocalInstanced(Game.GetPlayer():GetEntityID(), blackboardDefs.PlayerStateMachine)
    print(blackboardPSM:GetInt(blackboardDefs.PlayerStateMachine.Carrying))
    return blackboardPSM:GetInt(blackboardDefs.PlayerStateMachine.Carrying) > 0
end

function HasWeapon()
    local ts = Game.GetTransactionSystem()
    return ts:GetItemInSlot(Game.GetPlayer(), TweakDBID.new("AttachmentSlots.WeaponRight")) ~= nil
end

local lastPitch = 0
function ShouldSetCamera()
    -- TODO: needs further investigation as to which tiers are allowed.
    -- But for now it seems that every time camera is locked, scene tier is 4+.
    -- When you can move camera around it's 1-3
    local isCutScene = GetSceneTier() >= 4
    return not isCutScene and not IsInVehicle() and not HasWeapon() and not IsCarryingBody()
end
function IsCrouching()
    return Game.GetPlayer():GetPS():IsCrouch()
end

-- Handlers
local wasCrouching = false
function LessUnimmersiveFirstPerson.HandleCamera(force)
    if force == nil then force = false end

    if isFreeObservation then
        return
    end

    if not ShouldSetCamera() then
        -- BVFP wil set camera automatically
        if HasBetterVehicleFirstPerson() then
            return
        end

        ResetCamera()
        return
    end

    local pitchValue = GetPitch()
    if not pitchValue then
        return
    end

    local isCrouching = IsCrouching()

    -- The bigger value, the more you need to move camera down to apply changes
    local OFFSET = 30
    local curPitch = math.floor(math.min(pitchValue + OFFSET, 0) * 1000) / 1000
    local maxPitch = -80 + OFFSET

    local PITCH_CHANGE_STEP = 0.1
    local hasPitchNotablyChanged = math.abs(lastPitch - curPitch) >= PITCH_CHANGE_STEP
    local hasCrouchingChanged = isCrouching ~= wasCrouching
    if not hasPitchNotablyChanged and not force and not hasCrouchingChanged then
        return
    end
    wasCrouching = isCrouching
    lastPitch = curPitch

    if not isEnabled then
        return
    end

    local progress = math.min(1, curPitch / maxPitch)

    if progress <= 0 then
        ResetCamera()
        return
    end

    -- we set defaultFOV every time in case user has changed it.
    -- TODO: detect settings change
    if wasReset then
        defaultFOV = GetFOV()
    end
    wasReset = false

    local shiftBaseValue = -0.125
    local heightBaseValue = -0.10
    local leanBaseValue = -9
    local fovBaseValue = -8

    -- crouch-specific multipilers
    local crouchMultShift = isCrouching and 1.35 or 1
    local crouchMultLean = isCrouching and 1.5 or 1
    local crouchMultHeight = isCrouching and 1.17 or 1

    -- shift changes based on FOV, so we take this into account
    local fovShiftCorrection = GetFOV()/68.23

    -- at the beginning camera goes way too hard down and can clip through stuff like nomad goggles.
    -- we try to minimize this effect with these multipliers
    local STOP_SHIFT_BOOST_AT = 0.80
    local shiftInitialSlowDown = math.min(1, (progress/STOP_SHIFT_BOOST_AT))
    local shift = math.min(1, progress * 4.0) * shiftBaseValue * fovShiftCorrection * crouchMultShift * shiftInitialSlowDown

    -- Height goes gradually from 0 to N to -N
    local HEIGHT_INCREASE_KEY_POINT = 0.37
    local heightInitialBoost = math.max(-0.16, 5*progress - math.max(0, (progress-HEIGHT_INCREASE_KEY_POINT)*8.5))

    -- we don't need a boost if we crouch since the camera is fine as it is
    local height = math.min(1, progress * 1.0) * heightBaseValue * (isCrouching and 1 or heightInitialBoost) * crouchMultHeight

    local lean = math.min(1, progress * 1.0) * leanBaseValue * crouchMultLean
    if isFreeObservation then
        lean = nil
    end

    local fov = math.floor(68.23 + ((math.min(1, progress * 2)) * fovBaseValue))
    SetCamera(shift, height, lean, fov)
end

local lastNativePitch = 0
local lastNativePitchUsed = false

local PreFreeObservation = {
    roll = 0,
    pitch = 0,
    yaw = 0,
    x = 0,
    y = 0,
    z = 0,
}
function LessUnimmersiveFirstPerson.SavePreFreeObservationCam()
    local curEuler = GetSingleton('Quaternion'):ToEulerAngles(Game.GetPlayer():GetFPPCameraComponent():GetLocalOrientation())
    local curPos = Game.GetPlayer():GetFPPCameraComponent():GetLocalPosition()
    PreFreeObservation.x = curPos.x
    PreFreeObservation.y = curPos.y
    PreFreeObservation.z = curPos.z
    PreFreeObservation.pitch = curEuler.pitch
    PreFreeObservation.roll = curEuler.roll
    PreFreeObservation.yaw = curEuler.yaw
    print(PreFreeObservation)
end
function LessUnimmersiveFirstPerson.RestorePreFreeObservationCam()
    SetRelativeCamera(
        PreFreeObservation.roll,
        PreFreeObservation.pitch,
        PreFreeObservation.yaw,
        PreFreeObservation.x,
        PreFreeObservation.y,
        PreFreeObservation.z
    )
end

local function curve(t, a, b, c)
    -- local x = (1-t)^2 * 0 + 2*(1-t)*t * 13 + t^2 * 15
    local y = (1-t)^2 * a + 2*(1-t)*t * b + t^2 * c
    return y
end

function LessUnimmersiveFirstPerson.HandleFreeObservation(relX, relY)
    local MAX_YAW = 115
    local MAX_PITCH = 80

    local MAX_Y = 0.060
    local MIN_Z = -0.100

    local MAX_X_SHIFT = 0.085
    local MAX_ROLL = 25

    local curEuler = GetSingleton('Quaternion'):ToEulerAngles(Game.GetPlayer():GetFPPCameraComponent():GetLocalOrientation())
    local curPos = Game.GetPlayer():GetFPPCameraComponent():GetLocalPosition()

    local curX = curPos.x
    local curY = curPos.y
    local curZ = curPos.z

    local curRoll = curEuler.roll
    local curPitch = curEuler.pitch
    local curYaw = curEuler.yaw

    local zoom = fpp:GetZoom()
    local xSensitivity = 0.1 / zoom
    local ySensitivity = 0.1 / zoom

    local yaw = math.min(MAX_YAW, math.max(-MAX_YAW, curYaw - (relX*xSensitivity)))
    -- yawCorrection need to higher up pitch when approaching high yaw (when looking over shoulder)
    -- local yawCorrection = math.min(1, 1 - math.abs(math.max(0, (math.abs(yaw) - 80) /  (MAX_YAW - 80))) + 0)*1000
    local pitch = (not lastNativePitchUsed and lastNativePitch or math.min(MAX_PITCH, math.max(-MAX_PITCH, curPitch + (relY*ySensitivity))))
    -- print(yawCorrection, pitch)
    lastNativePitchUsed = true

    -- -1(left) +1(right)
    local delta = (yaw < 0) and 1 or -1
    local xShiftMultiplier = math.abs(yaw) / MAX_YAW * 2
    local x = MAX_X_SHIFT * xShiftMultiplier * delta
    local roll = MAX_ROLL * (xShiftMultiplier/10) * -delta

    -- as we look down we need to move camera sligthly forwards
    local pitchProgress = -math.min(0, curPitch / MAX_PITCH)

    local xShiftMultiplierReduction = 1 - (xShiftMultiplier/ 2)
    -- the closer we are to looking behind our shoulders the less should be visible X and Y modificators
    local y = -curve(pitchProgress, 0, MAX_Y*3, -MAX_Y/20) -0.007*xShiftMultiplier
    local z = curve(pitchProgress, 0, (-MIN_Z), MIN_Z/4) * xShiftMultiplierReduction

    local fov = math.floor(68.23 + ((math.min(1, pitchProgress)) * -8))

    -- print(roll, pitch, yaw)
    SetRelativeCamera(roll, pitch, yaw, x, y, z, fov)
end

function SetFPP()
    local player = Game.GetPlayer()
    if player then
        fpp = player:GetFPPCameraComponent()
    end
end

-- INIT
function LessUnimmersiveFirstPerson.Init()
    registerForEvent("onShutdown", function()
        ResetCamera()
        if fpp then
            fpp:ResetPitch()
            LessUnimmersiveFirstPerson.RestorePreFreeObservationCam()
            UnlockMovement()
            fpp:SetFOV(defaultFOV)
        end
    end)
    registerForEvent("onInit", function()
        inited = true
        SetFPP()
        defaultFOV = GetFOV()

        Observe('RadialWheelController', 'RegisterBlackboards', function(_, loaded)
            isLoaded = loaded
            if loaded then
                SetFPP()
                defaultFOV = GetFOV()
            else
                ResetCamera(true)
            end
        end)

        Observe('PlayerPuppet', 'OnAction', function(action)
            -- TODO: we could make a free observable camera, like in day-z or some shit
            local ListenerAction = GetSingleton('gameinputScriptListenerAction')
            local actionName = Game.NameToString(ListenerAction:GetName(action))
            local actionType = ListenerAction:GetType(action).value -- gameinputActionType
            local actionValue = ListenerAction:GetValue(action)
            if isFreeObservation then
                if actionName == "CameraMouseY" then
                    LessUnimmersiveFirstPerson.HandleFreeObservation(0, actionValue)
                end
                if actionName == "CameraMouseX" then
                    LessUnimmersiveFirstPerson.HandleFreeObservation(actionValue, 0)
                end
                return
            end


            -- TODO: Test it!
            -- if actionName == "CameraAim" or actionName == "SwitchItem" or actionName == "WeaponWheel" then
            --     Cron.After(0.20, function ()
            --         LessUnimmersiveFirstPerson.HandleCamera()
            --     end)
            -- end

            if actionName == "CameraMouseY" or
                actionName == "right_stick_y" or
                actionName == "CameraY" or
                actionName == "UI_MoveY_Axis" or
                actionName == "MeleeBlock" or
                actionName == "RangedADS" or
                actionName == "CameraAim" or
                actionName == "MeleeAttack" or
                actionName == "RangedAttack" or
                actionName == "mouse_left" or
                actionName == "click" or
                actionName == "SwitchItem" or
                actionName == "WeaponWheel" then
                LessUnimmersiveFirstPerson.HandleCamera()
            end
        end)

        Cron.Every(0.65, function ()
            LessUnimmersiveFirstPerson.HandleCamera()
        end)

    end)

    registerForEvent("onUpdate", function(delta)
        Cron.Update(delta)

        if not inited then
            return
        end
    end)

    registerForEvent("onDraw", function()
        if not isOverlayOpen then
            return
        end

        ImGui.Begin("LessUnimmersiveFirstPerson", ImGuiWindowFlags.AlwaysAutoResize)

        isEnabled, IsEnabledToggled = ImGui.Checkbox("Enabled", isEnabled)
        if IsEnabledToggled then
            if isEnabled and ShouldSetCamera() then
                LessUnimmersiveFirstPerson.HandleCamera(true)
            elseif not IsInVehicle() or (IsInVehicle() and not HasBetterVehicleFirstPerson()) then
                ResetCamera()
            end
        end
        ImGui.End()
    end)

    registerHotkey("LessUnimmersiveFirstPerson_ToggleEnabled", "Toggle Enabled", function()
        isEnabled = not isEnabled
        if isEnabled and ShouldSetCamera() then
            LessUnimmersiveFirstPerson.HandleCamera(true)
        elseif not IsInVehicle() or (IsInVehicle() and not HasBetterVehicleFirstPerson()) then
            ResetCamera()
        end
    end)
    registerInput("peek", "Peek Through Window", function(keydown)
        if keydown then
            LessUnimmersiveFirstPerson.SavePreFreeObservationCam()
            lastNativePitch = GetPitch()
            fpp:ResetPitch()
            LockMovement()
            LessUnimmersiveFirstPerson.HandleFreeObservation(0, 0)
        else
            LessUnimmersiveFirstPerson.RestorePreFreeObservationCam()
            UnlockMovement()
            fpp:SetFOV(defaultFOV)

            -- LessUnimmersiveFirstPerson.HandleCamera(true)
            lastNativePitchUsed = false
        end
    end)


    registerForEvent("onOverlayOpen", function()
        isOverlayOpen = true
    end)
    registerForEvent("onOverlayClose", function()
        isOverlayOpen = false
    end)

    return { ["version"] = LessUnimmersiveFirstPerson.version }
end

return LessUnimmersiveFirstPerson.Init()

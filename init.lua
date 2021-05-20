local Camera = {}

-- States
local inited = false
local isLoaded = false
local defaultFOV = 68
local initialFOV = 68
local isOverlayOpen = false
local isEnabled = true

-- Helpers
function GetPitch()
    local ok, res = pcall(function()
        local player = Game.GetPlayer()
        if not player then
            return
        end
        local fpp = player:GetFPPCameraComponent()
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

function GetFOV()
    local player = Game.GetPlayer()
    if not player then
        return
    end
    return player:GetFPPCameraComponent():GetFOV()
end

local wasReset = false
function ResetCamera(force)
    if not wasReset or force then
        local fpp = Game.GetPlayer():GetFPPCameraComponent()
        fpp:SetLocalPosition(Vector4.new(0.0, 0.0, 0, 1.0))
        fpp:SetLocalOrientation(Quaternion.new(0.0, 0.0, 0, 1.0))
        fpp:SetFOV(defaultFOV)
        wasReset = true
    end
end
function SetCamera(shift, height, lean, fov)
    shift = tonumber(string.format("%.4f", shift))
    height = tonumber(string.format("%.4f", height))
    lean = tonumber(string.format("%.4f", lean))
    fov = math.floor(fov)

    local fpp = Game.GetPlayer():GetFPPCameraComponent()
    fpp:SetFOV(fov)
    fpp:SetLocalOrientation(GetSingleton('EulerAngles'):ToQuat(EulerAngles.new(0, lean, 0)))
    fpp:SetLocalPosition(Vector4.new(0, height, shift, 1.0))
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
            and IsPlayerDriver()
end
function GetSceneTier()
    local blackboardDefs = Game.GetAllBlackboardDefs()
    local blackboardPSM = Game.GetBlackboardSystem():GetLocalInstanced(Game.GetPlayer():GetEntityID(), blackboardDefs.PlayerStateMachine)
    return blackboardPSM:GetInt(blackboardDefs.PlayerStateMachine.SceneTier)
end

function IsCarryingBody()
    local blackboardDefs = Game.GetAllBlackboardDefs()
    local blackboardPSM = Game.GetBlackboardSystem():GetLocalInstanced(Game.GetPlayer():GetEntityID(), blackboardDefs.PlayerStateMachine)
    return blackboardPSM:GetInt(blackboardDefs.PlayerStateMachine.BodyCarrying) > 0
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
function Camera.HandleCamera(force)
    if force == nil then force = false end

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
    local curPitch = math.floor(math.min(pitchValue + OFFSET, 0) * 100) / 100
    local maxPitch = -80 + OFFSET

    local PITCH_CHANGE_STEP = 0.17
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

    local fov = math.floor(68.23 + ((math.min(1, progress * 2)) * fovBaseValue))
    SetCamera(shift, height, lean, fov)
end

-- INIT
function Camera.Init()
    registerForEvent("onInit", function()
        inited = true
        defaultFOV = GetFOV()

        Observe('RadialWheelController', 'RegisterBlackboards', function(_, loaded)
            isLoaded = loaded
            if loaded then
                defaultFOV = GetFOV()
            else
                ResetCamera(true)
            end
        end)

        -- TODO: we could make a free observable camera, like in day-z
        -- Observe('PlayerPuppet', 'OnAction', function(action)
        --     local ListenerAction = GetSingleton('gameinputScriptListenerAction')
        --     local actionName = Game.NameToString(ListenerAction:GetName(action))
        --     local actionType = ListenerAction:GetType(action).value -- gameinputActionType
        --     local actionValue = ListenerAction:GetValue(action)
        --     if actionName == "mouse_y" or actionName == "mouse_x" then
        --         print(actionName, actionValue)
        --     end
        -- end)
    end)

    registerForEvent("onUpdate", function ()
        if not inited then
            return
        end

        Camera.HandleCamera()
    end)

    registerForEvent("onDraw", function()
        if not isOverlayOpen then
            return
        end

        ImGui.Begin("BFC", ImGuiWindowFlags.AlwaysAutoResize)

        isEnabled, IsEnabledToggled = ImGui.Checkbox("Enabled", isEnabled)
        if IsEnabledToggled then
            if isEnabled and ShouldSetCamera() then
                Camera.HandleCamera(true)
            elseif not IsInVehicle() or (IsInVehicle() and not HasBetterVehicleFirstPerson()) then
                ResetCamera()
            end
        end
        ImGui.End()
    end)

    registerHotkey("BetterFirstPerson", "Toggle Enabled", function()
        isEnabled = not isEnabled
        if isEnabled and ShouldSetCamera() then
            Camera.HandleCamera(true)
        elseif not IsInVehicle() or (IsInVehicle() and not HasBetterVehicleFirstPerson()) then
            ResetCamera()
        end
    end)


    registerForEvent("onOverlayOpen", function()
        isOverlayOpen = true
    end)
    registerForEvent("onOverlayClose", function()
        isOverlayOpen = false
    end)
end

return Camera.Init()

local ImmersiveFirstPerson = { version = "1.0.0" }
local Cron = require("Modules/Cron")
local GameSettings = require("Modules/GameSettings")
local Vars = require("Modules/Vars")
local Easings = require("Modules/Easings")
local Helpers = require("Modules/Helpers")
local Config = require("Modules/Config")

-- States
local inited = false
local isLoaded = false
local defaultFOV = 68
local initialFOV = 68
local isOverlayOpen = false
local isEnabled = true

function CombatFreeLook()
    return Config.inner.freeLookInCombat
end

-- Helpers

local wasReset = true
function ResetCamera(force)
    if not wasReset or force then
        Helpers.ResetCamera(defaultFOV)
        wasReset = true
    end
end

local lastPitch = 0
function ShouldSetCamera(ignoreWeapon)
    if ignoreWeapon == nil then ignoreWeapon = false end
    local isCutScene = Helpers.GetSceneTier() >= 4
    return not isCutScene and not Helpers.IsInVehicle() and (not Helpers.HasWeapon() or ignoreWeapon) and not Helpers.IsCarryingBody()
end
function IsCrouching()
    return Game.GetPlayer():GetPS():IsCrouch()
end

-- Handlers
local wasCrouching = false
function ImmersiveFirstPerson.HandleCamera(force)
    if force == nil then force = false end

    if Helpers.IsFreeObservation() then
        return
    end

    if not ShouldSetCamera() then
        -- BVFP wil set camera automatically
        if Helpers.IsInVehicle() and Helpers.HasBVFP() then
            return
        end

        ResetCamera()
        return
    end

    local pitchValue = Helpers.GetPitch()
    if not pitchValue then
        return
    end

    local isCrouching = IsCrouching()

    local curPitch = math.floor(math.min(pitchValue + Vars.OFFSET, 0) * 1000) / 1000
    local maxPitch = -80 + Vars.OFFSET

    local hasPitchNotablyChanged = math.abs(lastPitch - curPitch) >= Vars.PITCH_CHANGE_STEP
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
        defaultFOV = Helpers.GetFOV()
    end
    wasReset = false

    -- crouch-specific multipilers
    local crouchMultShift = isCrouching and Vars.CROUCH_MULT_SHIFT or 1
    local crouchMultLean = isCrouching and Vars.CROUCH_MULT_LEAN or 1
    local crouchMultHeight = isCrouching and Vars.CROUCH_MULT_HEIGHT or 1

    -- shift changes based on FOV, so we take this into account
    local fovShiftCorrection = Helpers.GetFOV()/68.23

    -- at the beginning camera goes way too hard down and can clip through stuff like nomad goggles.
    -- we try to minimize this effect with these multipliers
    local shiftInitialSlowDown = math.min(1, (progress/Vars.STOP_SHIFT_BOOST_AT))
    local shift = math.min(1, progress * 4.0) * Vars.SHIFT_BASE_VALUE * fovShiftCorrection * crouchMultShift * shiftInitialSlowDown

    -- Height goes gradually from 0 to N to -N
    local heightInitialBoost = math.max(-0.16, 5*progress - math.max(0, (progress-Vars.HEIGHT_INCREASE_KEY_POINT)*8.5))

    -- we don't need a boost if we crouch since the camera is fine as it is
    local height = math.min(1, progress * 1.0) * Vars.HEIGHT_BASE_VALUE * (isCrouching and 1 or heightInitialBoost) * crouchMultHeight

    local lean = math.min(1, progress * 1.0) * Vars.LEAN_BASE_VALUE * crouchMultLean
    if Helpers.IsFreeObservation() then
        lean = nil
    end

    local f = 68.23 - defaultFOV
    local fov = math.floor(defaultFOV + f*math.min(1, progress * 2) + ((math.min(1, progress * 1)) * Vars.FOV_BASE_VALUE))
    Helpers.SetCamera(nil, height, shift, nil, lean, nil, fov)
end

local lastNativePitch = 0
local lastNativePitchUsed = false

local freeLookRestore = { progress = 0 }
function ImmersiveFirstPerson.RestoreFreeCam()
    local fpp = Helpers.GetFPP()
    local curEuler = GetSingleton('Quaternion'):ToEulerAngles(fpp:GetLocalOrientation())
    local curPos = fpp:GetLocalPosition()

    if not Config.inner.smoothRestore then
        freeLookRestore.progress = 0
        Helpers.SetRestoringCamera(false)
        Helpers.SetFreeObservation(false)
        ResetCamera(true)
        return
    end

    if curEuler.pitch == 0 and curEuler.roll == 0 and curEuler.yaw == 0 and curPos.x == 0 and curPos.y == 0 and curPos.z == 0 then
        freeLookRestore.progress = 0
        Helpers.SetRestoringCamera(false)
        Helpers.SetFreeObservation(false)
        return
    end

    local itersWithSpeed = Vars.FREELOOK_SMOOTH_RESTORE_ITERS / Config.inner.smoothRestoreSpeed * Vars.FREELOOK_SMOOTH_RESTORE_ITERS

    -- local progressEased = Easings.EaseOutCubic(freeLookRestore.progress / itersWithSpeed)
    local progressEased = (freeLookRestore.progress / itersWithSpeed)
    local roll = math.floor((curEuler.roll - progressEased * curEuler.roll) * 10) / 10
    local pitch = math.floor((curEuler.pitch - progressEased * curEuler.pitch) * 10) / 10
    local yaw = math.floor((curEuler.yaw - progressEased * curEuler.yaw) * 10) / 10
    local x = math.floor((curPos.x - progressEased * curPos.x) * 1000) / 1000
    local y = math.floor((curPos.y - progressEased * curPos.y) * 1000) / 1000
    local z = math.floor((curPos.z - progressEased * curPos.z) * 1000) / 1000

    if freeLookRestore.progress >= itersWithSpeed then
        roll = 0
        pitch = 0
        yaw = 0
        x = 0
        y = 0
        z = 0
        freeLookRestore.progress = 0
        Helpers.SetRestoringCamera(false)
        Helpers.SetFreeObservation(false)
    end

    Helpers.SetCamera(x, y, z, roll, pitch, yaw)
    freeLookRestore.progress = freeLookRestore.progress + 1
end


local function curve(t, a, b, c)
    local y = (1-t)^2 * a + 2*(1-t)*t * b + t^2 * c
    return y
end

function ImmersiveFirstPerson.HandleFreeLook(relX, relY)
    if Helpers.IsRestoringCamera() then
        return
    end

    if not ShouldSetCamera(Config.inner.freeLookInCombat) then
        -- BVFP wil set camera automatically
        if Helpers.IsInVehicle() and Helpers.HasBVFP() then
            return
        end

        ResetFreeLook()
        return
    end

    local fpp = Helpers.GetFPP()

    local curEuler = GetSingleton('Quaternion'):ToEulerAngles(fpp:GetLocalOrientation())
    local curPos = fpp:GetLocalPosition()

    local curX = curPos.x
    local curY = curPos.y
    local curZ = curPos.z

    local curRoll = curEuler.roll
    local curPitch = not lastNativePitchUsed and math.max(-Vars.FREELOOK_MAX_PITCH, lastNativePitch) or curEuler.pitch
    local curYaw = curEuler.yaw

    local zoom = fpp:GetZoom()
    local xSensitivity = 0.07 / zoom * Config.inner.freeLookSensitivity/20
    local ySensitivity = 0.07 / zoom * Config.inner.freeLookSensitivity/20

    local yaw = math.min(Vars.FREELOOK_MAX_YAW, math.max( -Vars.FREELOOK_MAX_YAW, (curYaw - (relX*xSensitivity))))

    -- yawCorrection need to higher up pitch when approaching high yaw (when looking over shoulder)
    local pitch = math.min(Vars.FREELOOK_MAX_PITCH, math.max(-Vars.FREELOOK_MAX_PITCH, (curPitch) + (relY*ySensitivity)))
    lastNativePitchUsed = true

    -- -1(left) +1(right)
    local delta = (yaw < 0) and 1 or -1
    local xShiftMultiplier = math.abs(yaw) / Vars.FREELOOK_MAX_YAW * 2

    local x = Vars.FREELOOK_MAX_X_SHIFT * xShiftMultiplier * delta
    local roll = Vars.FREELOOK_MAX_ROLL * (xShiftMultiplier/10) * -delta

    -- as we look down we need to move camera sligthly forwards
    local pitchProgress = -math.min(0, curPitch / Vars.FREELOOK_MAX_PITCH)

    local xShiftMultiplierReduction = 1 - (xShiftMultiplier/ 2)
    -- the closer we are to looking behind our shoulders the less prominent should be X and Y axises
    local y = -curve(pitchProgress, 0, Vars.FREELOOK_MAX_Y*3, -Vars.FREELOOK_MAX_Y/20) -0.005*xShiftMultiplier
    local z = curve(pitchProgress, 0, (-Vars.FREELOOK_MIN_Z), Vars.FREELOOK_MIN_Z/2) * xShiftMultiplierReduction

    local defaultFOVFixed = defaultFOV + 2
    local f = 68.23 - defaultFOVFixed

    local fov = math.floor(defaultFOVFixed + f*math.min(1, pitchProgress * 2) + ((math.min(1, pitchProgress)) * -8))

    Helpers.SetCamera(x, y, z, roll, pitch, yaw, fov)
end

function ResetFreeLook()
    Helpers.SetCamera(nil, nil, nil, nil, nil, nil, defaultFOV)
    Helpers.SetRestoringCamera(true)
    Helpers.UnlockMovement()
    lastNativePitchUsed = false
    ImmersiveFirstPerson.RestoreFreeCam()
end

function SaveNativeSens()
    if not Config.isReady then
        return
    end
    Config.inner.mouseNativeSensX = GameSettings.Get('/controls/fppcameramouse/FPP_MouseX')
    Config.inner.mouseNativeSensY = GameSettings.Get('/controls/fppcameramouse/FPP_MouseY')
    Config.SaveConfig()
end

-- INIT
function ImmersiveFirstPerson.Init()
    registerForEvent("onShutdown", function()
        Helpers.UnlockMovement()
        local fpp = Helpers.GetFPP()
        if fpp then
            fpp:ResetPitch()
            ImmersiveFirstPerson.RestoreFreeCam()
            Helpers.SetCamera(nil, nil, nil, nil, nil, nil, defaultFOV)
        end
        ResetCamera()
    end)
    registerForEvent("onInit", function()
        inited = true
        Config.InitConfig()
        defaultFOV = Helpers.GetFOV()

        if Config.inner.mouseNativeSensX == -1 or Config.inner.mouseNativeSensX == nil then
            SaveNativeSens()
        end

        if GameSettings.Get('/controls/fppcameramouse/FPP_MouseX') == 0 then
            Helpers.UnlockMovement()
        end

        Observe("SettingsMainGameController", "OnUninitialize", function()
            SaveNativeSens()
        end)

        Observe('RadialWheelController', 'RegisterBlackboards', function(_, loaded)
            isLoaded = loaded
            if loaded then
                defaultFOV = Helpers.GetFOV()
            else
                ResetCamera(true)
            end
        end)

        Observe('ScriptedPuppet', 'GetPuppetPS', function()
            if Helpers.IsRestoringCamera() then
                ImmersiveFirstPerson.RestoreFreeCam()
            end
        end)

        Observe('PlayerPuppet', 'OnAction', function(action)
            -- TODO: we could make a free observable camera, like in day-z or some shit
            local ListenerAction = GetSingleton('gameinputScriptListenerAction')
            local actionName = Game.NameToString(ListenerAction:GetName(action))
            local actionType = ListenerAction:GetType(action).value -- gameinputActionType
            local actionValue = ListenerAction:GetValue(action)
            if Helpers.IsFreeObservation() then
                if actionName == "CameraMouseY" then
                    ImmersiveFirstPerson.HandleFreeLook(0, actionValue)
                end
                if actionName == "CameraMouseX" then
                    ImmersiveFirstPerson.HandleFreeLook(actionValue, 0)
                end
                return
            end


            -- TODO: Test it!
            -- if actionName == "CameraAim" or actionName == "SwitchItem" or actionName == "WeaponWheel" then
            --     Cron.After(0.20, function ()
            --         ImmersiveFirstPerson.HandleCamera()
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
                ImmersiveFirstPerson.HandleCamera()
            end
        end)

        Cron.Every(0.65, function ()
            ImmersiveFirstPerson.HandleCamera()
        end)
    end)

    registerForEvent("onUpdate", function(delta)
        Cron.Update(delta)

        --     for var=1,300 do
        --         Game.GetPlayer():GetFPPCameraComponent():SetLocalOrientation(GetSingleton('EulerAngles'):ToQuat(EulerAngles.new(0, -5.6, 0)))
        --         -- Game.GetPlayer():GetFPPCameraComponent():SetLocalOrientationAlt(EulerAngles.new(0, -5.6, 0))
        --     end


        if not inited then
            return
        end
        if Helpers.IsFreeObservation() and not ShouldSetCamera(Config.inner.freeLookInCombat) and not Helpers.IsRestoringCamera() then
            if Helpers.IsInVehicle() and Helpers.HasBVFP() then
                return
            end

            ResetFreeLook()
            return
        end
    end)

    function TooltipIfHovered(text)
        if ImGui.IsItemHovered() then
            ImGui.BeginTooltip()
            ImGui.SetTooltip(text)
            ImGui.EndTooltip()
        end
    end

    registerForEvent("onDraw", function()
        -- print("-", Game.GetSimTime():ToFloat(Game.GetSimTime()))
        -- for var=1,1000000 do
        --     if var == 1000000 then
        --         for var=1,900 do
        --             Game.GetPlayer():GetFPPCameraComponent():SetLocalOrientation(GetSingleton('EulerAngles'):ToQuat(EulerAngles.new(0, -5.6, 0)))
        --         end
        --     end
        -- end
        --
        if not isOverlayOpen then
            return
        end

        ImGui.PushStyleVar(ImGuiStyleVar.WindowMinSize, 300, 40)
        ImGui.Begin("ImmersiveFirstPerson", ImGuiWindowFlags.AlwaysAutoResize)

        -- IS ENABLED
        isEnabled, IsEnabledToggled = ImGui.Checkbox("Enabled", isEnabled)
        if IsEnabledToggled then
            if isEnabled and ShouldSetCamera(Config.inner.freeLookInCombat) then
                ImmersiveFirstPerson.HandleCamera(true)
            elseif not Helpers.IsInVehicle() or (Helpers.IsInVehicle() and not Helpers.HasBVFP()) then
                ResetCamera()
            end
        end
        ImGui.Text("")

        -- WARNING ABOUT TRANSITION
        ImGui.PushStyleColor(ImGuiCol.Button, 0.60, 0.20, 0.30, 0.8)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.60, 0.20, 0.30, 0.8)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.60, 0.20, 0.30, 0.8)
        ImGui.SmallButton("WARNING!")
        ImGui.PopStyleColor(3)
        local msg = "If your character stuck during transition,\nload the latest save file and"
        msg = msg .. " turn off this option (or try increaing the speed).\nThis is caused by some internal game bug and for now is unfixable."
        TooltipIfHovered(msg)

        -- to supress linter
        local changed = false

        -- SMOOTH TRANSITION
        Config.inner.smoothRestore, changed = ImGui.Checkbox("Smooth Transition From FreeLook", Config.inner.smoothRestore)
        TooltipIfHovered(msg)
        if changed then
            Config.SaveConfig()
            if isEnabled and ShouldSetCamera(Config.inner.freeLookInCombat) then
                ImmersiveFirstPerson.HandleCamera(true)
            elseif not Helpers.IsInVehicle() or (Helpers.IsInVehicle() and not Helpers.HasBVFP()) then
                ResetCamera()
            end
        end
        if Config.inner.smoothRestore then
        -- smoothRestore speed
            Config.inner.smoothRestoreSpeed, changed = ImGui.SliderInt("Transition Speed", math.floor(Config.inner.smoothRestoreSpeed), 1, 100)
            if changed then
                Config.SaveConfig()
            end
        end
        ImGui.Text("")

        -- freelook sensitivity
        Config.inner.freeLookSensitivity, changed = ImGui.SliderInt("FreeLook sensitivity", math.floor(Config.inner.freeLookSensitivity), 1, 100)
        if changed then
            Config.SaveConfig()
        end

        -- freelook in combat
        -- Config.inner.freeLookInCombat, changed = ImGui.Checkbox("Enable FreeLook in combat", Config.inner.freeLookInCombat)
        -- if changed then
        --     Config.SaveConfig()
        -- end

        ImGui.End()
        ImGui.PopStyleVar(1)

    end)

    registerHotkey("ifp_toggle_enabled", "Toggle Enabled", function()
        isEnabled = not isEnabled
        if isEnabled and ShouldSetCamera() then
            ImmersiveFirstPerson.HandleCamera(true)
        elseif not Helpers.IsInVehicle() or (Helpers.IsInVehicle() and not Helpers.HasBVFP()) then
            ResetCamera()
        end
    end)
    registerInput("ifp_freelook", "FreeLook", function(keydown)
        if not ShouldSetCamera(Config.inner.freeLookInCombat) then
            return
        end
        local fpp = Helpers.GetFPP()
        if fpp == nil then
            return
        end

        if keydown then
            -- if we started free look when we haven't finished restoring then just reset it immediately
            if Helpers.IsRestoringCamera() then
                -- TODO: test if we need to reset camera
                -- Helpers.ResetCamera()
                freeLookRestore.progress = 0
                Helpers.SetRestoringCamera(false)
                Helpers.SetFreeObservation(false)
            end

            lastNativePitch = Helpers.GetPitch()
            if not Config.inner.freeLookInCombat then
                fpp:ResetPitch()
            end
            Helpers.SetFreeObservation(true)
            Helpers.LockMovement()
            ImmersiveFirstPerson.HandleFreeLook(0, 0)
        else
            ResetFreeLook()
        end
    end)


    registerForEvent("onOverlayOpen", function()
        isOverlayOpen = true
    end)
    registerForEvent("onOverlayClose", function()
        isOverlayOpen = false
    end)

    return { ["version"] = ImmersiveFirstPerson.version }
end

return ImmersiveFirstPerson.Init()

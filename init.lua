local ImmersiveFirstPerson = { version = "1.2.1" }
local Cron = require("Modules/Cron")
local GameSession = require("Modules/GameSession")
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
local isDisabledByApi = false
local isYInverted = false
local isXInverted = false
local freeLookInCombat = true

local API = {}

function API.Enable()
    isDisabledByApi = false
    isEnabled = true
    if ShouldSetCamera(freeLookInCombat) then
        ImmersiveFirstPerson.HandleCamera(true)
    end
end

function API.Disable()
    isEnabled = false
    isDisabledByApi = true
    ResetCamera()
    ResetFreeLook()
end

function API.IsEnabled()
  return isEnabled
end

function CombatFreeLook()
    return freeLookInCombat
end

-- Helpers

function defaultFovOrNil()
    if not Config.inner.dontChangeFov then
      return defaultFOV
    end
    return nil
end

local wasReset = true
function ResetCamera(force)
    if not wasReset or force then
        Helpers.ResetCamera(defaultFovOrNil())
        wasReset = true
    end
end

--- Check third party mods
function blockingThirdPartyMods()
    -- local gtaTravel = GetMod("gtaTravel")
    -- if gtaTravel and gtaTravel.api and not gtaTravel.api.done then
    --     return true
    -- end

    return false
end

local lastPitch = 0
function ShouldSetCamera(ignoreWeapon)
    if ignoreWeapon == nil then ignoreWeapon = false end
    local sceneTier = Helpers.GetSceneTier()
    local isFullGameplayScene = sceneTier > 0 and sceneTier < 3
    return isFullGameplayScene
        and (not Helpers.HasWeapon() or ignoreWeapon)
        and not Helpers.IsInVehicle()
        and not Helpers.IsSwimming()
        and Helpers.IsTakingDown() <= 0
        and not blockingThirdPartyMods()
        and not Helpers.IsCarryingBody()
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

    local f = Helpers.GetFOV()
    -- TODO: fuck you
    local poopshit = (68 / f- 1) * 0.22

    -- at the beginning camera goes way too hard down and can clip through stuff like nomad goggles.
    -- we try to minimize this effect with these multipliers
    local shiftInitialSlowDown = math.min(1, (progress/Vars.STOP_SHIFT_BOOST_AT))
    local shift = math.min(1, progress * 4.0) * Vars.SHIFT_BASE_VALUE * crouchMultShift * shiftInitialSlowDown + poopshit

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
    if Config.inner.dontChangeFov then
        fov = nil
    end

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

    if not ShouldSetCamera(freeLookInCombat) then
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

    local weapon = Helpers.HasWeapon()

    local curYaw = curEuler.yaw
    local curRoll = curEuler.roll
    
    local zoom = fpp:GetZoom()
    local xSensitivity = 0.07 / zoom * Config.inner.freeLookSensitivity/20
    local ySensitivity = 0.07 / zoom * Config.inner.freeLookSensitivity/20
    
    local sensXMult = 1
    local sensYMult = 1
    
    local yawingOut = curYaw > 0 and relX > 0 or curYaw < 0 and relX < 0
    
    local function easeOutCubic(x)
        return 1 - (1-x)^3
    end
    
    local function easeOutExp(x)
        -- return x == 1 and 1 or 1 - 2^(-10*x)
        return x == 0 and 0 or 2 ^ (5 * x - 5)
    end
    
    
    -- print(math.abs(curYaw / Vars.FREELOOK_MAX_YAW), easeOutExp(math.abs(curYaw / Vars.FREELOOK_MAX_YAW)))
    local yawProgress = (yawingOut and easeOutExp(math.abs(curYaw / Vars.FREELOOK_MAX_YAW)) or 0) + (1 - easeOutExp(math.abs(curYaw / Vars.FREELOOK_MAX_YAW)))
    
    local yaw = math.min(Vars.FREELOOK_MAX_YAW, math.max( -Vars.FREELOOK_MAX_YAW, (curYaw - (relX*xSensitivity * yawProgress))))
    
    local r = (math.abs(curYaw) + 100) / Vars.FREELOOK_MAX_YAW

    local maxPitch = weapon and Vars.FREELOOK_MAX_PITCH_COMBAT_UP or Vars.FREELOOK_MAX_PITCH

    local maxPitchOnYaw = (weapon and curEuler.pitch < 0) and math.min(Vars.FREELOOK_MAX_PITCH_COMBAT, Vars.FREELOOK_MAX_PITCH_COMBAT * r) or maxPitch

    local curPitch = (not weapon and not lastNativePitchUsed) and math.max(-maxPitchOnYaw, lastNativePitch) or curEuler.pitch
    -- local yaw = -Vars.FREELOOK_MAX_YAW * yawProgress

    local pitchingOut = curPitch > 0 and relY < 0 or curPitch < 0 and relY > 0

    -- yawCorrection need to higher up pitch when approaching high yaw (when looking over shoulder)
    local pitchSmoothing = ((pitchingOut and easeOutExp(-math.min(0, curPitch / maxPitchOnYaw)) or 0) + (1 - easeOutExp(-math.min(0, curPitch / maxPitchOnYaw))))

    -- local maxPitchOnYawOnYaw = weapon and (Vars.FREELOOK_MAX_PITCH_COMBAT_UP * (0.3 + math.abs((curYaw) / Vars.FREELOOK_MAX_YAW))) or maxPitchOnYaw
    local pitch = math.min(maxPitchOnYaw, math.max(-maxPitchOnYaw, (curPitch) + (relY*ySensitivity * pitchSmoothing)))
    lastNativePitchUsed = true

    -- -1(left) +1(right)
    local delta = (yaw < 0) and 1 or -1
    local xShiftMultiplier = math.abs(yaw) / Vars.FREELOOK_MAX_YAW * 2

    local freelookMaxXShift = weapon and Vars.FREELOOK_MAX_X_SHIFT_COMBAT or Vars.FREELOOK_MAX_X_SHIFT
    local x = freelookMaxXShift * xShiftMultiplier * delta
    
    -- as we look down we need to move camera sligthly forwards
    local pitchProgress = -math.min(0, curPitch / maxPitchOnYaw)

    -- local pitchProgress = -math.min(0, curPitch / maxPitch) * (1 - easeOutExp(-math.min(0, curPitch / maxPitch)))

    local rollSmoothMult = easeOutCubic(pitchProgress)
    local maxRoll = weapon and Vars.FREELOOK_MAX_COMBAT_ROLL or Vars.FREELOOK_MAX_ROLL
    local roll = maxRoll * (pitchProgress) * (xShiftMultiplier/10) * -delta * rollSmoothMult

    local f = Helpers.GetFOV()
    -- TODO: fuck you
    local poopshit = (68 / f - 1) * 0.01
    local xShiftMultiplierReduction = 1 - (xShiftMultiplier/ 2)
    -- the closer we are to looking behind our shoulders the less prominent should be X and Y axises

    local endForwardMult = weapon and 40 or 20
    local startForwardMult = weapon and 0 or 3
    local y = -curve(pitchProgress, 0, Vars.FREELOOK_MAX_Y*startForwardMult, -Vars.FREELOOK_MAX_Y/endForwardMult-0.05) -0.005*xShiftMultiplier

    local startUpMult = weapon and 0.2 or 1
    local endUpMult = weapon and 0.001 or 1

    local z = curve(pitchProgress, 0, (-Vars.FREELOOK_MIN_Z * startUpMult), Vars.FREELOOK_MIN_Z/2 * endUpMult  + 0.02 + poopshit*30 * endUpMult) * xShiftMultiplierReduction

    local defaultFOVFixed = defaultFOV + 2
    local f = 68.23 - defaultFOVFixed

    local fov = math.floor(defaultFOVFixed + f*math.min(1, pitchProgress * 2) + ((math.min(1, pitchProgress)) * -8))
    if Config.inner.dontChangeFov then
        fov = nil
    end


    Helpers.SetCamera(x, y, z, roll, pitch, yaw, fov)
end

function ResetFreeLook()
    Helpers.SetCamera(nil, nil, nil, nil, nil, nil, defaultFovOrNil())
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
-- gamestateMachineGameScriptInterface
-- StateGameScriptInterface extends StateScriptInterface
-- ublic final native func GetObjectFromComponent(targetingComponent: ref<IPlacedComponent>) -> ref<GameObject>
-- public final native func Teleport(objectToTeleport: ref<GameObject>, position: Vector4, orientation: EulerAngles) -> Void
-- Game.GetTeleportationFacility():Teleport(playerPuppet, position, rotation)

-- fpp = Game.GetPlayer():GetFPPCameraComponent()

-- c = GetSingleton("gamestateMachineGameScriptInterface"):TestCam(-10)
-- c = GetSingleton("gamestateMachineGameScriptInterface"):TestCam(EulerAngles.new(0, -15.6, 0))
-- c:SetOrientationEuler(EulerAngles.new(0, -15.6, 0))
-- Game.GetPlayer():TestCam(GetSingleton("gamestateMachineGameScriptInterface"):GetCameraWorldTransform(), -10)
-- INIT
function ImmersiveFirstPerson.Init()
    registerForEvent("onShutdown", function()
        Helpers.UnlockMovement()
        local fpp = Helpers.GetFPP()
        if fpp then
            fpp:ResetPitch()
            ImmersiveFirstPerson.RestoreFreeCam()
            Helpers.SetCamera(nil, nil, nil, nil, nil, nil, defaultFovOrNil())
        end
        ResetCamera()
    end)
    registerForEvent("onInit", function()
        inited = true
        Config.InitConfig()
        defaultFOV = Helpers.GetFOV()
        isYInverted = Helpers.IsYInverted()
        isXInverted = Helpers.IsXInverted()

        if Config.inner.mouseNativeSensX == -1 or Config.inner.mouseNativeSensX == nil then
            SaveNativeSens()
        end

        if GameSettings.Get('/controls/fppcameramouse/FPP_MouseX') == 0 then
            Helpers.UnlockMovement()
        end

        -- Observe("DefaultTransition", "IsPlayerInCombat", function(_, scr)
            -- print("c:", (Game.GetTimeSystem():GetSimTime():ToFloat(Game.GetTimeSystem():GetSimTime())))
        --     for var=1,200 do
        --         Game.GetPlayer():GetFPPCameraComponent():SetLocalOrientation(GetSingleton('EulerAngles'):ToQuat(EulerAngles.new(0, -5.6, 0)))
        --         Game.GetPlayer():GetFPPCameraComponent():SetLocalOrientation(GetSingleton('EulerAngles'):ToQuat(EulerAngles.new(0, math.random(-800000, 800000)/10000, 0)))
        --     end
        -- end)

        Observe("SettingsMainGameController", "OnUninitialize", function()
            SaveNativeSens()
            isYInverted = Helpers.IsYInverted()
            isXInverted = Helpers.IsXInverted()
        end)

        GameSession.OnStart(function()
          isLoaded = true
          defaultFOV = Helpers.GetFOV()
        end)
        GameSession.OnResume(function()
          isLoaded = true
          defaultFOV = Helpers.GetFOV()
        end)

        GameSession.OnEnd(function()
          isLoaded = false
          ResetCamera(true)
        end)
        GameSession.OnDeath(function()
          isLoaded = false
          ResetCamera()
        end)
        GameSession.OnPause(function()
          isLoaded = false
          ResetCamera()
        end)

        local cetVer = tonumber((GetVersion():gsub('^v(%d+)%.(%d+)%.(%d+)(.*)', function(major, minor, patch, wip)
            return ('%d.%02d%02d%d'):format(major, minor, patch, (wip == '' and 0 or 1))
        end))) or 1.12

        Observe('PlayerPuppet', 'OnGameAttached', function(self, b)
          self:RegisterInputListener(self, "CameraMouseY")
          self:RegisterInputListener(self, "CameraMouseX")
          self:RegisterInputListener(self, "CameraMouseY")
          self:RegisterInputListener(self, "right_stick_y")
          self:RegisterInputListener(self, "CameraY")
          self:RegisterInputListener(self, "UI_MoveY_Axis")
          self:RegisterInputListener(self, "MeleeBlock")
          self:RegisterInputListener(self, "RangedADS")
          self:RegisterInputListener(self, "CameraAim")
          self:RegisterInputListener(self, "MeleeAttack")
          self:RegisterInputListener(self, "RangedAttack")
          self:RegisterInputListener(self, "mouse_left")
          self:RegisterInputListener(self, "click")
          self:RegisterInputListener(self, "SwitchItem")
          self:RegisterInputListener(self, "WeaponWheel")
        end)

        Observe('PlayerPuppet', 'OnAction', function(a, b)
            if not isLoaded then
              return
            end

            -- TODO: not sure if this is redundant
            local action = a
            if cetVer >= 1.14 then
                action = b
            end

            -- print("a:", (Game.GetTimeSystem():GetSimTime():ToFloat(Game.GetTimeSystem():GetSimTime())))
            local ListenerAction = GetSingleton('gameinputScriptListenerAction')
            local actionName = Game.NameToString(ListenerAction:GetName(action))
            -- local actionType = ListenerAction:GetType(action).value -- gameinputActionType
            local actionValue = ListenerAction:GetValue(action)
            if Helpers.IsFreeObservation() then
                if actionName == "CameraMouseY" then
                    ImmersiveFirstPerson.HandleFreeLook(0, actionValue * (isYInverted and -1 or 1))
                end
                if actionName == "CameraMouseX" then
                    ImmersiveFirstPerson.HandleFreeLook(actionValue * (isXInverted and -1 or 1), 0)
                end
                return
            end

            if actionName == "CameraMouseY"
               or actionName == "right_stick_y"
               or actionName == "CameraY"
               or actionName == "UI_MoveY_Axis"
               or actionName == "MeleeBlock"
               or actionName == "RangedADS"
               or actionName == "CameraAim"
               or actionName == "MeleeAttack"
               or actionName == "RangedAttack"
               or actionName == "mouse_left"
               or actionName == "click"
               or actionName == "SwitchItem"
               or actionName == "WeaponWheel"
               then
                 ImmersiveFirstPerson.HandleCamera()
            end
        end)

        Cron.Every(0.65, function ()
            if isLoaded then
              ImmersiveFirstPerson.HandleCamera()
            end
        end)
    end)

    registerForEvent("onUpdate", function(delta)
        Cron.Update(delta)

        if not isLoaded then
          return
        end

        if Helpers.IsRestoringCamera() then
            ImmersiveFirstPerson.RestoreFreeCam()
        end

        --     for var=1,300 do
        --         Game.GetPlayer():GetFPPCameraComponent():SetLocalOrientation(GetSingleton('EulerAngles'):ToQuat(EulerAngles.new(0, -5.6, 0)))
        --         -- Game.GetPlayer():GetFPPCameraComponent():SetLocalOrientationAlt(EulerAngles.new(0, -5.6, 0))
        --     end


        if not inited then
            return
        end

        if Helpers.IsFreeObservation() and not ShouldSetCamera(freeLookInCombat) and not Helpers.IsRestoringCamera() then
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
        -- print("u:", (Game.GetTimeSystem():GetSimTime():ToFloat(Game.GetTimeSystem():GetSimTime())))
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
            if isEnabled and ShouldSetCamera(freeLookInCombat) then
                ImmersiveFirstPerson.HandleCamera(true)
            elseif not Helpers.IsInVehicle() or (Helpers.IsInVehicle() and not Helpers.HasBVFP()) then
                ResetCamera()
            end
        end
        ImGui.Text("")

        -- dont change fov
        Config.inner.dontChangeFov, changed = ImGui.Checkbox("Don't change FOV (may cause clipping)", Config.inner.dontChangeFov)
        if changed then
            Config.SaveConfig()
            if isEnabled and isLoaded then
                if Config.inner.dontChangeFov then
                  Helpers.ResetFOV(defaultFOV)
                end
            end
        end

        -- WARNING ABOUT TRANSITION
        ImGui.PushStyleColor(ImGuiCol.Button, 0.60, 0.20, 0.30, 0.8)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.60, 0.20, 0.30, 0.8)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.60, 0.20, 0.30, 0.8)
        ImGui.SmallButton("WARNING!")
        ImGui.PopStyleColor(3)
        local msg = "If your character stuck during transition,\nload the latest save file and"
        msg = msg .. " then either turn this option off or increase the transition speed.\nThis is caused by internal game bug and for now is unfixable."
        TooltipIfHovered(msg)

        -- to supress linter
        local changed = false

        -- SMOOTH TRANSITION
        Config.inner.smoothRestore, changed = ImGui.Checkbox("Smooth transition for FreeLook", Config.inner.smoothRestore)
        TooltipIfHovered(msg)
        if changed then
            Config.SaveConfig()
            if isEnabled and ShouldSetCamera(freeLookInCombat) then
                ImmersiveFirstPerson.HandleCamera(true)
            elseif not Helpers.IsInVehicle() or (Helpers.IsInVehicle() and not Helpers.HasBVFP()) then
                ResetCamera()
            end
        end
        if Config.inner.smoothRestore then
        -- smoothRestore speed
            Config.inner.smoothRestoreSpeed, changed = ImGui.SliderInt("Transition speed", math.floor(Config.inner.smoothRestoreSpeed), 1, 200)
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
        -- freeLookInCombat, changed = ImGui.Checkbox("Enable FreeLook in combat", freeLookInCombat)
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
        if isDisabledByApi then
          return
        end

        if not ShouldSetCamera(freeLookInCombat) then
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
            if not Helpers.HasWeapon() then
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

    return {
      version = ImmersiveFirstPerson.version,
      api = API,
    }
end

return ImmersiveFirstPerson.Init()

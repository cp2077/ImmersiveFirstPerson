local ImmersiveFirstPerson = { version = "2.0.0" }
local CameraCore = require("Modules/CameraCore")
local Config = require("Modules/Config")
local GameSession = require("Modules/GameSession")
local Helpers = require("Modules/Helpers")
local NativeCameraSampler = require("Modules/NativeCameraSampler")

local initialized = false
local isLoaded = false
local isOverlayOpen = false
local isEnabled = true
local isDisabledByApi = false
local heightResetPending = false

local API = {}

function API.StartNativeCameraCapture()
    CameraCore.Suspend("native camera capture armed")
    NativeCameraSampler.Arm()
end

function API.CancelNativeCameraCapture()
    NativeCameraSampler.Cancel()
end
local freeLookCameraActions = {
    CameraMouseX = true,
    CameraMouseY = true,
    CameraX = true,
    CameraY = true,
    right_stick_x = true,
    right_stick_y = true,
}

local function blockingThirdPartyMods()
    return false
end

local function commonCameraContextAllowed(sceneTier)
    return sceneTier > 0
        and sceneTier < 3
        and not Helpers.IsInVehicle()
        and not Helpers.IsSwimming()
        and Helpers.IsTakingDown() <= 0
        and not Helpers.IsCarryingBody()
        and not Helpers.IsKnockedDown()
        and not blockingThirdPartyMods()
end

local function buildCameraContext()
    local sceneTier = Helpers.GetSceneTier()
    local hasWeapon = Helpers.HasWeapon()
    local commonEligible = isEnabled and commonCameraContextAllowed(sceneTier)
    local heightContextEligible = commonEligible
        and sceneTier == 1
        and (not Helpers.IsInWorkspot() or Helpers.IsOnLadder())
    local heightEligible = heightContextEligible
        and Config.inner.heightAdjustmentEnabled
        and not hasWeapon
    return {
        bodyEligible = commonEligible and not hasWeapon,
        freeEligible = commonEligible and (not hasWeapon or Config.inner.freeLookInCombat),
        heightEligible = heightEligible,
        heightCanTransfer = heightContextEligible,
        heightResetAllowed = heightContextEligible and not hasWeapon,
        -- Keep the requested bias available while ineligible so CameraCore can
        -- transfer it into/out of native pitch during weapon transitions.
        heightPitch = Config.inner.heightAdjustmentAmount,
        crouching = Helpers.IsCrouching(),
        hasWeapon = hasWeapon,
    }
end

local function refreshInputSettings()
    CameraCore.SetInputInversion(Helpers.IsXInverted(), Helpers.IsYInverted())
end

local function setSessionLoaded(loaded, reason)
    isLoaded = loaded
    if loaded then
        refreshInputSettings()
    else
        if reason == "game paused" then
            CameraCore.Pause(reason)
        else
            CameraCore.Suspend(reason)
        end
    end
end

function API.Enable()
    isDisabledByApi = false
    isEnabled = true
end

function API.Disable()
    isDisabledByApi = true
    isEnabled = false
    CameraCore.Suspend("disabled by API")
end

function API.IsEnabled()
    return isEnabled
end

function API.GetCameraState()
    return CameraCore.GetDebugState()
end

local function tooltipIfHovered(text)
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        ImGui.SetTooltip(text)
        ImGui.EndTooltip()
    end
end

local function registerPlayerInput(cetVersion)
    local function registerInputListeners(player)
        if not player then
            return
        end

        player:RegisterInputListener(player, "CameraMouseX")
        player:RegisterInputListener(player, "CameraMouseY")
        player:RegisterInputListener(player, "CameraX")
        player:RegisterInputListener(player, "CameraY")
        player:RegisterInputListener(player, "right_stick_x")
        player:RegisterInputListener(player, "right_stick_y")
        player:RegisterInputListener(player, "mouse_left")
    end

    Observe('PlayerPuppet', 'OnGameAttached', function(player)
        registerInputListeners(player)
    end)

    Observe('PlayerPuppet', 'OnAction', function(first, second, third)
        if not isLoaded then
            return
        end

        local action = cetVersion >= 1.14 and second or first
        local consumer = cetVersion >= 1.14 and third or second
        if not action then
            return
        end

        local listenerAction = GetSingleton('gameinputScriptListenerAction')
        local ok, actionName, actionValue = pcall(function()
            return Game.NameToString(listenerAction:GetName(action)), listenerAction:GetValue(action)
        end)
        if not ok or not actionName then
            return
        end

        if CameraCore.IsFreeLooking() and actionName == "mouse_left" and actionValue > 0 then
            CameraCore.AbortFreeLook()
            return
        end

        CameraCore.OnAction(actionName, actionValue)
        if CameraCore.IsFreeLooking()
            and freeLookCameraActions[actionName]
            and consumer then
            -- Continuous camera axes need the full consumer flag. REDengine's
            -- own scripts use Consume() for blocked input; ConsumeSingleAction()
            -- is never used by the shipped scripts and can let later native
            -- camera listeners see intermittent mouse updates.
            local consumed = pcall(function()
                consumer:Consume()
            end)
            if not consumed then
                pcall(function()
                    consumer:ConsumeSingleAction()
                end)
            end
        end
    end)

    -- Reload All Mods can happen after OnGameAttached. Register the current player too.
    registerInputListeners(Game.GetPlayer())
end

function ImmersiveFirstPerson.Init()
    registerForEvent("onShutdown", function()
        isLoaded = false
        if NativeCameraSampler.IsActive() then
            NativeCameraSampler.Cancel()
        end
        CameraCore.Suspend("CET shutdown")
    end)

    registerForEvent("onInit", function()
        initialized = true
        Config.InitConfig()
        refreshInputSettings()

        local cetVersion = tonumber((GetVersion():gsub('^v(%d+)%.(%d+)%.(%d+)(.*)', function(major, minor, patch, wip)
            return ('%d.%02d%02d%d'):format(major, minor, patch, (wip == '' and 0 or 1))
        end))) or 1.14
        registerPlayerInput(cetVersion)

        Observe("SettingsMainGameController", "OnUninitialize", function()
            refreshInputSettings()
        end)

        Observe("DeathDecisionsWithResurrection", "ToResurrect", function()
            setSessionLoaded(true, "resurrected")
        end)

        GameSession.OnStart(function()
            setSessionLoaded(true, "session started")
        end)
        GameSession.OnResume(function()
            setSessionLoaded(true, "session resumed")
        end)
        GameSession.OnEnd(function()
            setSessionLoaded(false, "session ended")
        end)
        GameSession.OnDeath(function()
            setSessionLoaded(false, "player died")
        end)
        GameSession.OnPause(function()
            setSessionLoaded(false, "game paused")
        end)

        -- GameSession callbacks describe transitions. On a hot reload there may be no
        -- transition, so adopt the state that GameSession discovered during registration.
        local sessionActive = GameSession.IsLoaded()
            and not GameSession.IsPaused()
            and not GameSession.IsDead()
        setSessionLoaded(sessionActive, sessionActive and "CET initialized" or "no active session")
    end)

    registerForEvent("onUpdate", function(delta)
        if not initialized or not isLoaded then
            return
        end

        if NativeCameraSampler.IsActive() then
            CameraCore.Suspend("recording native camera")
            NativeCameraSampler.Update(delta, CameraCore.ReadNativePitch())
            return
        end

        local context = buildCameraContext()
        if heightResetPending and context.heightResetAllowed then
            CameraCore.ResetHeightAdjustment("height setting changed")
            heightResetPending = false
            context = buildCameraContext()
        end
        CameraCore.Update(delta, context)
    end)

    registerForEvent("onDraw", function()
        if not isOverlayOpen then
            return
        end

        ImGui.PushStyleVar(ImGuiStyleVar.WindowMinSize, 310, 40)
        ImGui.Begin("Immersive First Person")

        local changed
        isEnabled, changed = ImGui.Checkbox("Enabled", isEnabled)
        if changed then
            if isEnabled then
                isDisabledByApi = false
            else
                CameraCore.Suspend("disabled in overlay")
            end
        end

        Config.inner.dontChangeFov, changed = ImGui.Checkbox(
            "Don't change FOV (may cause clipping)",
            Config.inner.dontChangeFov
        )
        if changed then
            Config.SaveConfig()
            if Config.inner.dontChangeFov then
                CameraCore.RestoreBaselineFOV()
            end
        end

        Config.inner.smoothRestore, changed = ImGui.Checkbox(
            "Smooth FreeLook return",
            Config.inner.smoothRestore
        )
        if changed then
            Config.SaveConfig()
        end

        if Config.inner.smoothRestore then
            Config.inner.smoothRestoreSpeed, changed = ImGui.SliderInt(
                "Return speed",
                math.floor(Config.inner.smoothRestoreSpeed),
                1,
                200
            )
            tooltipIfHovered("Higher values return to native view faster.")
            if changed then
                Config.SaveConfig()
            end
        end

        Config.inner.freeLookSensitivity, changed = ImGui.SliderInt(
            "FreeLook sensitivity",
            math.floor(Config.inner.freeLookSensitivity),
            1,
            100
        )
        if changed then
            Config.SaveConfig()
        end

        Config.inner.freeLookInCombat, changed = ImGui.Checkbox(
            "Enable FreeLook with a weapon",
            Config.inner.freeLookInCombat
        )
        if changed then
            Config.SaveConfig()
        end

        ImGui.Separator()
        ImGui.Text("Experimental")
        Config.inner.heightAdjustmentEnabled, changed = ImGui.Checkbox(
            "Enable height adjustment",
            Config.inner.heightAdjustmentEnabled
        )
        tooltipIfHovered("Experimental apparent player-height adjustment.")
        if changed then
            Config.SaveConfig()
            heightResetPending = true
        end
        if Config.inner.heightAdjustmentEnabled then
            Config.inner.heightAdjustmentAmount, changed = ImGui.SliderInt(
                "Height amount",
                math.floor(Config.inner.heightAdjustmentAmount),
                1,
                30
            )
            tooltipIfHovered("Higher values increase height and the chance of camera artifacts.")
            if changed then
                Config.SaveConfig()
                heightResetPending = true
            end
            ImGui.TextWrapped(
                "Experimental: active only during normal on-foot gameplay with weapons "
                    .. "holstered. Larger values may cause clipping, visual artifacts, "
                    .. "or unusual mouse/camera movement."
            )
        end

        ImGui.Text("Camera state: " .. CameraCore.GetMode())
        --[[ Native camera sampling UI is retained for future curve captures.
        ImGui.Text("Native camera sampler: " .. NativeCameraSampler.GetStatus())
        if NativeCameraSampler.IsActive() then
            if ImGui.Button("Cancel native camera recording") then
                NativeCameraSampler.Cancel()
            end
        else
            ImGui.Text("Stand still, holster weapon, and look fully up before recording.")
            ImGui.Text("After closing CET, sweep fully down and back up over 14 seconds.")
            if ImGui.Button("Record native vertical camera curve") then
                API.StartNativeCameraCapture()
            end
        end
        ]]
        ImGui.End()
        ImGui.PopStyleVar(1)
    end)

    registerHotkey("ifp_toggle_enabled", "Toggle Enabled", function()
        isEnabled = not isEnabled
        if isEnabled then
            isDisabledByApi = false
        else
            CameraCore.Suspend("disabled by hotkey")
        end
    end)

    registerInput("ifp_freelook", "FreeLook", function(keydown)
        if isDisabledByApi or not isLoaded or not isEnabled then
            return
        end

        if keydown then
            local context = buildCameraContext()
            if context.freeEligible then
                CameraCore.BeginFreeLook(context)
            end
        else
            CameraCore.EndFreeLook(false)
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

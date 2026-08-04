local ImmersiveFirstPerson = { version = "0.0.0-dev" }
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
local weaponCameraBlocked = false
local weaponCameraClearElapsed = 0.0
local lastCameraBlockReason = nil

local HEIGHT_WEAPON_CLEAR_GRACE = 0.20

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

local function getCameraBlockReason(state)
    if state.sceneTier <= 0 or state.sceneTier >= 3 then
        return "scene tier " .. tostring(state.sceneTier)
    elseif state.vitalsState ~= 0 then
        return "player not alive"
    elseif state.inVehicle or state.remoteVehicle then
        return state.remoteVehicle and "remote vehicle camera" or "vehicle camera"
    elseif state.deviceCamera then
        return "device camera"
    elseif state.inMinigame then
        return "minigame camera"
    elseif state.inspecting then
        return "inspection camera"
    elseif state.forceOpeningDoor then
        return "forced-door animation"
    elseif state.swimming then
        return "swimming camera"
    elseif state.takingDown then
        return "takedown camera"
    elseif state.carryingBody then
        return "body-carry camera"
    elseif state.felled then
        return "felled camera"
    elseif state.onLadder then
        return "ladder camera"
    elseif state.consumableState ~= 0 then
        return "consumable camera"
    elseif state.inWorkspot and not state.traversal then
        -- Workspot locomotion reports itself as Stand, so the workspot signal
        -- must win over the otherwise ordinary detailed locomotion value.
        return "scripted workspot camera"
    elseif state.knockedDown then
        return "knockdown camera"
    elseif blockingThirdPartyMods() then
        return "third-party camera mod"
    end
    return nil
end

local function logCameraBlockTransition(reason)
    if reason == lastCameraBlockReason then
        return
    end

    if reason then
        Helpers.Log("camera ownership blocked: " .. reason)
    elseif lastCameraBlockReason then
        Helpers.Log("camera ownership restored after: " .. lastCameraBlockReason)
    end
    lastCameraBlockReason = reason
end

local function updateWeaponCameraBlock(hasWeapon, delta)
    if hasWeapon then
        weaponCameraBlocked = true
        weaponCameraClearElapsed = 0.0
    elseif weaponCameraBlocked then
        if Helpers.GetUpperBodyState() ~= 0 then
            -- Weapon slots disappear during switch, reload, forced-empty-hands,
            -- and traversal animations. Keep the armed block until that state
            -- ends instead of treating the temporary empty slot as a holster.
            weaponCameraClearElapsed = 0.0
        else
            weaponCameraClearElapsed = weaponCameraClearElapsed
                + math.max(tonumber(delta) or 0.0, 0.0)
            if weaponCameraClearElapsed >= HEIGHT_WEAPON_CLEAR_GRACE then
                weaponCameraBlocked = false
                weaponCameraClearElapsed = 0.0
            end
        end
    end

    return weaponCameraBlocked
end

local function buildCameraContext(delta)
    local sceneTier = Helpers.GetSceneTier()
    local hasWeapon = Helpers.HasWeapon()
    local isTakingDown = Helpers.IsTakingDown() > 0
    local state = {
        sceneTier = sceneTier,
        vitalsState = Helpers.GetVitalsState(),
        inVehicle = Helpers.GetVehicleState() ~= 0 or Helpers.IsInVehicle(),
        remoteVehicle = Helpers.HasRemoteControlledVehicle(),
        deviceCamera = Helpers.IsDeviceCameraActive(),
        inMinigame = Helpers.IsInMinigame(),
        inspecting = Helpers.IsInspecting(),
        forceOpeningDoor = Helpers.IsForceOpeningDoor(),
        swimming = Helpers.IsSwimming(),
        takingDown = isTakingDown,
        carryingBody = Helpers.IsCarryingBody(),
        felled = Helpers.IsFelled(),
        onLadder = Helpers.IsOnLadder(),
        consumableState = Helpers.GetConsumableState(),
        traversal = Helpers.IsTraversalLocomotion(),
        inWorkspot = Helpers.IsInWorkspot(),
        knockedDown = Helpers.IsKnockedDown(),
    }
    local cameraBlockReason = getCameraBlockReason(state)
    logCameraBlockTransition(cameraBlockReason)
    -- The attachment slot can disappear while the ranged-weapon state machine
    -- still owns the arms/camera. Treat either signal as armed, then keep a short
    -- clear grace for the frame gap at the end of those animations.
    local reportsArmed = hasWeapon or Helpers.GetWeaponState() ~= 0
    local blocksCameraForWeapon = updateWeaponCameraBlock(reportsArmed, delta)
    local commonEligible = isEnabled
        and cameraBlockReason == nil
    -- Height has narrower incompatibilities than the body/freelook camera. Base
    -- locomotion keeps the same FPP parent through jumps, falls, hard landings,
    -- ordinary knockdowns, climbing, and vaulting, so retaining the correction
    -- is safer than repeatedly transferring it out and back in. Explicit Felled
    -- and external-camera states are excluded because they replace that owner.
    local heightCameraCompatible = isEnabled
        and sceneTier == 1
        and state.vitalsState == 0
        and not state.inVehicle
        and not state.remoteVehicle
        and not state.deviceCamera
        and not state.inMinigame
        and not state.inspecting
        and not state.forceOpeningDoor
        and not state.carryingBody
        and not state.felled
        and not blockingThirdPartyMods()
    -- A takedown remains "compatible" only long enough to fade the local height
    -- offset; actual height composition is disabled before the authored camera
    -- takes ownership.
    -- Keep height disabled for the complete swimming high-level state so the
    -- local offset never carries into its pitch-driven authored camera.
    -- Ladders are also excluded because their Enter/Default/Reset/Exit profiles
    -- author their own view position. Vault and non-ladder climb states remain
    -- supported.
    local heightContextEligible = heightCameraCompatible
        and not isTakingDown
        and not state.swimming
        and not state.onLadder
        and state.consumableState == 0
        and (not state.inWorkspot or state.traversal)
    local heightEligible = heightContextEligible
        and Config.inner.heightAdjustmentEnabled
        and not blocksCameraForWeapon
    return {
        -- Weapon draw/holster retains the ordinary FPP parent, so CameraCore may
        -- crossfade the additive body correction. Truly incompatible contexts
        -- still suspend immediately instead of inheriting this transition.
        bodyContextEligible = commonEligible,
        bodyWeaponBlocked = blocksCameraForWeapon,
        bodyEligible = commonEligible and not blocksCameraForWeapon,
        -- Ladder locomotion swaps among several native camera profiles while
        -- moving, including a forced recenter profile. Freezing that parent for
        -- freelook can strand REDengine's pitch floor at the centre afterward.
        freeEligible = commonEligible
            and (not hasWeapon or Config.inner.freeLookInCombat),
        heightEligible = heightEligible,
        heightCanTransfer = heightContextEligible,
        heightCanPreserveTransition = heightCameraCompatible,
        heightResetAllowed = heightContextEligible and not blocksCameraForWeapon,
        -- Keep the requested amount available while ineligible so CameraCore can
        -- blend the local vertical offset through weapon transitions.
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
        CameraCore.Resume(reason)
        refreshInputSettings()
    else
        lastCameraBlockReason = nil
        if reason == "game paused" then
            CameraCore.Pause(reason)
        else
            CameraCore.Yield(reason)
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

function API.RetryCameraOwnership()
    return CameraCore.RetryConflict()
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
            -- Camera X and Y share an input bundle. Consume() on X suppresses
            -- the later Y callback entirely, so only consume this one action.
            local consumed = pcall(function()
                consumer:ConsumeSingleAction()
            end)
            if not consumed then
                pcall(function()
                    consumer:Consume()
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
            CameraCore.OnSessionStart()
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

        if CameraCore.HasConflict() then
            return
        end

        local context = buildCameraContext(delta)
        if heightResetPending and context.heightResetAllowed then
            CameraCore.ResetHeightAdjustment("height setting changed")
            heightResetPending = false
            context = buildCameraContext(0.0)
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

        local conflict = CameraCore.GetConflictState()
        if conflict.active then
            ImGui.Separator()
            ImGui.Text("Camera conflict detected")
            ImGui.TextWrapped(
                "Immersive First Person has suspended its camera changes because "
                    .. "another system is modifying the first-person camera."
            )
            if ImGui.Button("Retry camera ownership") then
                CameraCore.RetryConflict()
            end
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

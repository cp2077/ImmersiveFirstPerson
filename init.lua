local ImmersiveFirstPerson = { version = "0.0.0-dev" }
local CameraCore = require("Modules/CameraCore")
local Config = require("Modules/Config")
local GameSession = require("Modules/GameSession")
local Helpers = require("Modules/Helpers")
local NativeCameraSampler = require("Modules/NativeCameraSampler")
local RuntimeHeight = require("Modules/RuntimeHeight")

local initialized = false
local isLoaded = false
local isPaused = false
local isOverlayOpen = false
local isEnabled = true
local isDisabledByApi = false
local weaponCameraBlocked = false
local weaponCameraClearElapsed = 0.0
local lastCameraBlockReason = nil

local BODY_WEAPON_CLEAR_GRACE = 0.0

local cachedPlayerState = {}
local cachedCameraContext = {}

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

local function readListenerAction(listener, action)
    return Game.NameToString(listener:GetName(action)), listener:GetValue(action)
end

local function consumeSingleAction(consumer)
    consumer:ConsumeSingleAction()
end

local function consumeAction(consumer)
    consumer:Consume()
end

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

local function getHeightSuppressionReason(state)
    if state.sceneTier <= 0 or state.sceneTier >= 3 then
        return "scripted scene"
    elseif state.vitalsState ~= 0 then
        return "player not alive"
    elseif state.inVehicle or state.remoteVehicle then
        return state.remoteVehicle and "remote vehicle" or "vehicle occupancy"
    elseif state.deviceCamera then
        return "device camera"
    elseif state.inMinigame then
        return "minigame"
    elseif state.inspecting then
        return "inspection"
    elseif state.forceOpeningDoor then
        return "forced-door interaction"
    elseif state.takingDown then
        return "takedown or grapple"
    elseif state.carryingBody then
        return "body carrying"
    elseif state.felled or state.knockedDown then
        return "knockdown or forced reaction"
    elseif state.traversal then
        return "climb, vault, or ladder"
    elseif state.inWorkspot then
        return "authored workspot"
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

local function updateWeaponCameraBlock(hasWeapon, upperBodyState, delta)
    if hasWeapon then
        weaponCameraBlocked = true
        weaponCameraClearElapsed = 0.0
    elseif weaponCameraBlocked then
        if upperBodyState ~= 0 then
            -- Weapon slots disappear during switch, reload, forced-empty-hands,
            -- and traversal animations. Keep the armed block until that state
            -- ends instead of treating the temporary empty slot as a holster.
            weaponCameraClearElapsed = 0.0
        else
            weaponCameraClearElapsed = weaponCameraClearElapsed
                + math.max(tonumber(delta) or 0.0, 0.0)
            if weaponCameraClearElapsed >= BODY_WEAPON_CLEAR_GRACE then
                weaponCameraBlocked = false
                weaponCameraClearElapsed = 0.0
            end
        end
    end

    return weaponCameraBlocked
end

local function bindPlayer(player)
    Helpers.AttachPlayer(player)
    RuntimeHeight.ResetPlayer()
end

local function collectPlayerState()
    return Helpers.RefreshPlayerState(cachedPlayerState)
end

local function buildCameraContext(delta, state)
    state = state or collectPlayerState()
    if not state then
        return nil
    end
    local hasWeapon = state.hasWeapon
    local cameraBlockReason = getCameraBlockReason(state)
    logCameraBlockTransition(cameraBlockReason)
    -- The attachment slot can disappear while the ranged-weapon state machine
    -- still owns the arms/camera. Treat either signal as armed, then keep a short
    -- clear grace for the frame gap at the end of those animations.
    local reportsArmed = hasWeapon or state.weaponState ~= 0
    local blocksCameraForWeapon = updateWeaponCameraBlock(
        reportsArmed,
        state.upperBodyState,
        delta
    )
    local commonEligible = isEnabled and cameraBlockReason == nil
    local immersiveEligible = commonEligible
        and Config.inner.immersiveViewEnabled
    -- Weapon draw/holster retains the ordinary FPP parent, so CameraCore may
    -- crossfade the additive body correction. Truly incompatible contexts
    -- still suspend immediately instead of inheriting this transition.
    cachedCameraContext.bodyContextEligible = immersiveEligible
    cachedCameraContext.bodyWeaponBlocked = blocksCameraForWeapon
    cachedCameraContext.bodyEligible = immersiveEligible and not blocksCameraForWeapon
    -- Ladder locomotion swaps among several native camera profiles while
    -- moving, including a forced recenter profile. Freezing that parent for
    -- freelook can strand REDengine's pitch floor at the centre afterward.
    cachedCameraContext.freeEligible = commonEligible and Config.inner.freeLookEnabled
    cachedCameraContext.crouching = state.crouching
    cachedCameraContext.hasWeapon = hasWeapon
    return cachedCameraContext
end

local function refreshInputSettings()
    CameraCore.SetInputInversion(Helpers.IsXInverted(), Helpers.IsYInverted())
end

local function setSessionLoaded(loaded, reason)
    isLoaded = loaded
    if loaded then
        isPaused = false
        bindPlayer(Game.GetPlayer())
        refreshInputSettings()
        RuntimeHeight.MarkDirty()
    else
        isPaused = false
        local player = Helpers.GetPlayer()
        if initialized then
            RuntimeHeight.Shutdown(player)
        end
        lastCameraBlockReason = nil
        CameraCore.Suspend(reason)
        Helpers.DetachPlayer()
    end
end

local function setSessionPaused(paused, reason)
    isPaused = paused == true
    if isPaused then
        -- A menu pauses camera ownership, but it is not a player/session exit.
        -- Preserve the current animgraph height instead of blending it to zero.
        CameraCore.Pause(reason or "game paused")
    else
        refreshInputSettings()
        RuntimeHeight.MarkDirty()
    end
end

function API.Enable()
    isDisabledByApi = false
    isEnabled = true
    RuntimeHeight.MarkDirty()
end

function API.Disable()
    isDisabledByApi = true
    isEnabled = false
    RuntimeHeight.Shutdown(Helpers.GetPlayer())
    CameraCore.Suspend("disabled by API")
end

function API.IsEnabled()
    return isEnabled
end

function API.GetCameraState()
    return CameraCore.GetDebugState()
end

function API.GetHeightState()
    return {
        available = RuntimeHeight.IsAvailable(),
        status = RuntimeHeight.GetStatus(),
        suppressedBy = RuntimeHeight.GetSuppressionReason(),
        effectiveCentimeters = RuntimeHeight.GetEffectiveHeightCentimeters(),
    }
end

local function tooltipIfHovered(text)
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        ImGui.SetTooltip(text)
        ImGui.EndTooltip()
    end
end

local function isShiftEnabled()
    if type(GetMod) ~= "function" then
        return false
    end

    local found, shift = pcall(GetMod, "Shift")
    local api = found and type(shift) == "table" and shift.api or nil
    if type(api) ~= "table" or type(api.IsEnabled) ~= "function" then
        return false
    end

    local checked, enabled = pcall(api.IsEnabled)
    return checked and enabled == true
end

local function drawCompatibilityWarnings()
    if not isShiftEnabled() then
        return
    end

    ImGui.Separator()
    ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.65, 0.15, 1.0)
    ImGui.Text("Shift compatibility warning")
    ImGui.PopStyleColor(1)
    ImGui.TextWrapped(
        "Shift can reset the first-person camera while holstering. "
        .. "Disable Shift with its global power toggle; its individual camera toggles do not prevent this conflict."
    )
    ImGui.Separator()
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
        if player:IsReplacer() then
            return
        end
        bindPlayer(player)
        registerInputListeners(player)
    end)

    Observe('PlayerPuppet', 'OnDetach', function(player)
        if player:IsReplacer() then
            return
        end
        Helpers.DetachPlayer()
        RuntimeHeight.ResetPlayer()
        CameraCore.Suspend("player detached")
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
        local ok, actionName, actionValue = pcall(readListenerAction, listenerAction, action)
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
            local consumed = pcall(consumeSingleAction, consumer)
            if not consumed then
                pcall(consumeAction, consumer)
            end
        end
    end)

    -- Reload All Mods can happen after OnGameAttached. Register the current player too.
    registerInputListeners(Game.GetPlayer())
end

function ImmersiveFirstPerson.Init()
    registerForEvent("onShutdown", function()
        isLoaded = false
        isPaused = false
        RuntimeHeight.Shutdown(Helpers.GetPlayer())
        if NativeCameraSampler.IsActive() then
            NativeCameraSampler.Cancel()
        end
        CameraCore.Suspend("CET shutdown")
        Helpers.DetachPlayer()
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
            setSessionPaused(false, "session resumed")
        end)
        GameSession.OnEnd(function()
            setSessionLoaded(false, "session ended")
        end)
        GameSession.OnDeath(function()
            setSessionLoaded(false, "player died")
        end)
        GameSession.OnPause(function()
            setSessionPaused(true, "game paused")
        end)

        -- GameSession callbacks describe transitions. On a hot reload there may be no
        -- transition, so adopt the state that GameSession discovered during registration.
        local sessionActive = GameSession.IsLoaded() and not GameSession.IsDead()
        setSessionLoaded(sessionActive, sessionActive and "CET initialized" or "no active session")
        if sessionActive and GameSession.IsPaused() then
            setSessionPaused(true, "game paused")
        end
    end)

    registerForEvent("onUpdate", function(delta)
        if not initialized or not isLoaded or not isEnabled or isDisabledByApi then
            return
        end

        local player = Helpers.GetPlayer()
        local playerState = isPaused and nil or collectPlayerState()
        if not isPaused and not playerState then
            RuntimeHeight.ResetPlayer()
            CameraCore.Suspend("player state unavailable")
            return
        end
        local heightSuppressionReason
        if isPaused then
            heightSuppressionReason = RuntimeHeight.GetSuppressionReason()
        else
            heightSuppressionReason = getHeightSuppressionReason(playerState)
        end
        RuntimeHeight.Update(
            delta,
            player,
            isEnabled and Config.inner.immersiveViewEnabled,
            isEnabled and Config.inner.heightAdjustmentEnabled,
            Config.inner.heightAdjustmentAmount,
            heightSuppressionReason
        )

        if isPaused then
            return
        end

        if NativeCameraSampler.IsActive() then
            CameraCore.Suspend("recording native camera")
            NativeCameraSampler.Update(delta, CameraCore.ReadNativePitch())
            return
        end

        local context = buildCameraContext(delta, playerState)
        if context then
            CameraCore.Update(delta, context)
        end
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
                RuntimeHeight.MarkDirty()
            else
                RuntimeHeight.Shutdown(Helpers.GetPlayer())
                CameraCore.Suspend("disabled in overlay")
            end
        end

        Config.inner.immersiveViewEnabled, changed = ImGui.Checkbox(
            "Enable immersive view",
            Config.inner.immersiveViewEnabled
        )
        if changed then
            Config.SaveConfig()
        end

        Config.inner.freeLookEnabled, changed = ImGui.Checkbox(
            "Enable FreeLook",
            Config.inner.freeLookEnabled
        )
        if changed then
            Config.SaveConfig()
            if not Config.inner.freeLookEnabled then
                CameraCore.AbortFreeLook()
            end
        end

        Config.inner.heightAdjustmentEnabled, changed = ImGui.Checkbox(
            "Enable height adjustment",
            Config.inner.heightAdjustmentEnabled
        )
        if changed then
            Config.SaveConfig()
            RuntimeHeight.MarkDirty()
        end

        drawCompatibilityWarnings()

        ImGui.Separator()
        ImGui.Text("FreeLook")

        Config.inner.freeLookSmoothness, changed = ImGui.SliderInt(
            "Smoothness",
            math.floor(Config.inner.freeLookSmoothness),
            0,
            100
        )
        tooltipIfHovered(
            "0 disables smoothing. Higher values ease more gradually near the target."
        )
        if changed then
            Config.SaveConfig()
        end

        Config.inner.freeLookReturnSmoothness, changed = ImGui.SliderInt(
            "Return smoothness",
            math.floor(Config.inner.freeLookReturnSmoothness),
            0,
            100
        )
        tooltipIfHovered(
            "0 returns instantly. Higher values return more gradually."
        )
        if changed then
            Config.SaveConfig()
        end

        Config.inner.freeLookSensitivity, changed = ImGui.SliderInt(
            "Sensitivity",
            math.floor(Config.inner.freeLookSensitivity),
            1,
            100
        )
        if changed then
            Config.SaveConfig()
        end

        ImGui.Separator()
        ImGui.Text("Height")
        if not GameSession.IsLoaded() then
            ImGui.TextWrapped(
                "Load a save to check height compatibility and adjust height."
            )
        elseif RuntimeHeight.IsCompatibilityPending() then
            ImGui.TextDisabled("Checking height compatibility...")
        elseif RuntimeHeight.IsAvailable() then
            Config.inner.heightAdjustmentAmount, changed = ImGui.SliderInt(
                "Adjustment",
                math.floor(Config.inner.heightAdjustmentAmount),
                RuntimeHeight.GetMinimumHeightCentimeters(),
                RuntimeHeight.GetMaximumHeightCentimeters(),
                "%+d cm"
            )
            if changed then
                Config.SaveConfig()
                RuntimeHeight.MarkDirty()
            end

            local heightAmount = Config.inner.heightAdjustmentAmount
            if heightAmount < 0 then
                ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.25, 0.25, 1.0)
                ImGui.TextWrapped(
                    "Negative values are experimental: legs, knees, authored contacts, and transitions may look wrong."
                )
                ImGui.PopStyleColor(1)
            elseif heightAmount > 30 then
                ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.25, 0.25, 1.0)
                ImGui.TextWrapped(
                    "Above +30 cm is extremely unstable: expect severe animation and contact distortion."
                )
                ImGui.PopStyleColor(1)
            elseif heightAmount > 14 then
                ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.25, 0.25, 1.0)
                ImGui.TextWrapped(
                    "Above +14 cm is experimental: knees, authored contacts, and transitions may look wrong."
                )
                ImGui.PopStyleColor(1)
            end
            local suppressionReason = RuntimeHeight.GetSuppressionReason()
            if Config.inner.heightAdjustmentEnabled
                and heightAmount ~= 0
                and suppressionReason then
                ImGui.TextWrapped("Temporarily disabled: " .. suppressionReason)
            end
            ImGui.Text(("Estimated height: ~%.0f cm"):format(
                RuntimeHeight.GetEstimatedHeightCentimeters()
            ))
        else
            ImGui.TextDisabled("Controls unavailable")
            ImGui.TextWrapped(
                "ImmersiveFirstPersonHeight.archive is missing or overridden by another mod modifying player animgraph."
            )
        end

        ImGui.Separator()
        ImGui.Text("Debug")
        Config.inner.debugLogging, changed = ImGui.Checkbox(
            "Logging",
            Config.inner.debugLogging
        )
        tooltipIfHovered(
            "Controls routine diagnostic logs. Errors are still reported when disabled."
        )
        if changed then
            Config.SaveConfig()
        end

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
            RuntimeHeight.MarkDirty()
        else
            RuntimeHeight.Shutdown(Helpers.GetPlayer())
            CameraCore.Suspend("disabled by hotkey")
        end
    end)

    registerInput("ifp_freelook", "FreeLook", function(keydown)
        if isDisabledByApi or not isLoaded or not isEnabled then
            return
        end

        if keydown then
            local context = buildCameraContext(nil, collectPlayerState())
            if context and context.freeEligible then
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

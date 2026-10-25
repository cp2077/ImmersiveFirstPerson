local ImmersiveFirstPerson = { version = "0.0.0-dev" }
local CameraCore = require("Modules/CameraCore")
local Config = require("Modules/Config")
local GameSession = require("Modules/GameSession")
local Helpers = require("Modules/Helpers")
local HeightControl = require("Modules/HeightControl")
local NativeCameraSampler = require("Modules/NativeCameraSampler")
local RuntimeHeight = require("Modules/RuntimeHeight")
local Vars = require("Modules/Vars")

local initialized = false
local isLoaded = false
local isPaused = false
local isOverlayOpen = false
local userEnabled = true
local apiSuspensions = {}
local weaponCameraBlocked = false
local weaponCameraClearElapsed = 0.0
local lastCameraBlockReason = nil
local playerStateSourceRefreshElapsed = 0.0

local BODY_WEAPON_CLEAR_GRACE = 0.0
local PLAYER_STATE_SOURCE_REFRESH_INTERVAL = 1.0
local UPPER_BODY_FORCE_EMPTY_HANDS = 5

local cachedPlayerState = {}
local cachedCameraContext = {}
local lastSceneContext = {}

local API = {}

local function isModEnabled()
    return userEnabled and next(apiSuspensions) == nil
end

local function updateEnabledState(wasEnabled, reason)
    local enabled = isModEnabled()
    if enabled == wasEnabled then
        return
    end

    if enabled then
        RuntimeHeight.MarkDirty()
    else
        RuntimeHeight.Shutdown(Helpers.GetPlayer())
        CameraCore.Suspend(reason)
    end
end

local function setUserEnabled(enabled, reason)
    local wasEnabled = isModEnabled()
    userEnabled = enabled
    updateEnabledState(wasEnabled, reason)
end

local function setApiSuspension(modName, suspended)
    if modName == nil then
        modName = "Unnamed mod (legacy API)"
    end
    if not Helpers.IsValidModName(modName) then
        return false, "invalid_mod_name"
    end

    local wasEnabled = isModEnabled()
    apiSuspensions[modName] = suspended and true or nil
    updateEnabledState(wasEnabled, "disabled by " .. modName)
    return true
end

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

local function logSceneContext(state)
    if not Helpers.IsDebugLoggingEnabled() then
        return
    end
    if lastSceneContext.sceneTier == state.sceneTier
        and lastSceneContext.inVehicle == state.inVehicle
        and lastSceneContext.remoteVehicle == state.remoteVehicle
        and lastSceneContext.inWorkspot == state.inWorkspot then
        return
    end

    lastSceneContext.sceneTier = state.sceneTier
    lastSceneContext.inVehicle = state.inVehicle
    lastSceneContext.remoteVehicle = state.remoteVehicle
    lastSceneContext.inWorkspot = state.inWorkspot
    local camera = CameraCore.GetDebugState()
    Helpers.Log(("scene context: tier=%s vehicle=%s remote=%s workspot=%s "
        .. "camera=%s ownsCamera=%s immersive=%s freelook=%s heightEnabled=%s heightCm=%s"):format(
        tostring(state.sceneTier), tostring(state.inVehicle),
        tostring(state.remoteVehicle), tostring(state.inWorkspot),
        camera.mode, tostring(camera.ownsCamera),
        tostring(Config.inner.immersiveViewEnabled), tostring(Config.inner.freeLookEnabled),
        tostring(Config.inner.heightAdjustmentEnabled), tostring(Config.inner.heightAdjustmentAmount)
    ), true)
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
        if upperBodyState ~= 0 and upperBodyState ~= UPPER_BODY_FORCE_EMPTY_HANDS then
            -- Keep the armed block through temporary weapon-slot gaps. Forced
            -- empty hands can persist throughout scenes and safe zones after
            -- unequipping, so it must not retain a weapon block.
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
    playerStateSourceRefreshElapsed = 0.0
    RuntimeHeight.ResetPlayer()
end

local function ensurePlayerBound()
    local player = Helpers.GetPlayer()
    if player then
        return player
    end

    bindPlayer(Game.GetPlayer())
    return Helpers.GetPlayer()
end

local function collectPlayerState(delta)
    local state = Helpers.RefreshPlayerState(cachedPlayerState)
    if not state then
        return nil
    end

    playerStateSourceRefreshElapsed = playerStateSourceRefreshElapsed
        + math.max(tonumber(delta) or 0.0, 0.0)
    if playerStateSourceRefreshElapsed >= PLAYER_STATE_SOURCE_REFRESH_INTERVAL then
        playerStateSourceRefreshElapsed = 0.0
        if not Helpers.RefreshPlayerStateSource() then
            return nil
        end
        state = Helpers.RefreshPlayerState(cachedPlayerState)
    end

    return state
end

local function buildCameraContext(delta, state)
    state = state or collectPlayerState(delta)
    if not state then
        return nil
    end
    local hasWeapon = state.hasWeapon
    local cameraBlockReason = getCameraBlockReason(state)
    -- The attachment slot can disappear while the ranged-weapon state machine
    -- still owns the arms/camera. Treat either signal as armed, then keep a short
    -- clear grace for the frame gap at the end of those animations.
    local reportsArmed = hasWeapon or state.weaponState ~= 0
    local blocksCameraForWeapon = updateWeaponCameraBlock(
        reportsArmed,
        state.upperBodyState,
        delta
    )
    logCameraBlockTransition(cameraBlockReason or (blocksCameraForWeapon and "weapon camera" or nil))
    local commonEligible = isModEnabled() and cameraBlockReason == nil
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
    lastSceneContext = {}
    Helpers.Log("session loaded=" .. tostring(loaded) .. " (" .. tostring(reason) .. ")", true)
    isLoaded = loaded
    weaponCameraBlocked = false
    weaponCameraClearElapsed = 0.0
    if loaded then
        isPaused = false
        bindPlayer(Game.GetPlayer())
        refreshInputSettings()
        RuntimeHeight.MarkDirty()
    else
        isPaused = false
        apiSuspensions = {}
        HeightControl.ClearExternalChanges()
        local player = Helpers.GetPlayer()
        if initialized then
            RuntimeHeight.Shutdown(player)
        else
            RuntimeHeight.ResetPlayer()
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

function API.Enable(modName)
    return setApiSuspension(modName, false)
end

function API.Disable(modName)
    return setApiSuspension(modName, true)
end

function API.IsEnabled()
    return isModEnabled()
end

function API.GetCameraState()
    return CameraCore.GetDebugState()
end

function API.GetHeightState()
    return HeightControl.GetState(isModEnabled())
end

API.SetHeightOffset = HeightControl.SetHeightOffset
API.SetHeightEnabled = HeightControl.SetHeightEnabled

local function tooltipIfHovered(text)
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        ImGui.SetTooltip(text)
        ImGui.EndTooltip()
    end
end

local heightUnavailableMessages = {
    ["RED4ext native plugin unavailable"] = "Install or enable IFP's native plugin and RED4ext, then restart the game.",
    ["height graph is incompatible"] = "Install the height archive from this IFP release, then restart the game.",
    ["height archive missing or overridden"] = "Install or enable IFP's height archive, then restart the game. Another animation mod may be overriding it.",
    ["interaction height compatibility check failed"] = "Height adjustment does not support this game build. Install a compatible IFP release.",
    ["height controls could not be written"] = "Height adjustment could not be applied. Restart the game; if it persists, check ImmersiveFirstPerson.log.",
}

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
        if not player or not IsDefined(player) or player:IsReplacer() then
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

    Observe('PlayerPuppet', 'OnTakeControl', function(player)
        if player:IsReplacer() then
            return
        end
        bindPlayer(player)
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
        if not isLoaded or not CameraCore.IsFreeLooking() then
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

        if actionName == "mouse_left" and actionValue > 0 then
            CameraCore.AbortFreeLook()
            return
        end

        CameraCore.OnAction(actionName, actionValue)
        if freeLookCameraActions[actionName]
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
        Helpers.Log("startup: IFP=" .. ImmersiveFirstPerson.version .. " CET=" .. GetVersion(), true)
        refreshInputSettings()

        local cetVersion = tonumber((GetVersion():gsub('^v(%d+)%.(%d+)%.(%d+)(.*)', function(major, minor, patch, wip)
            return ('%d.%02d%02d%d'):format(major, minor, patch, (wip == '' and 0 or 1))
        end))) or 1.14
        registerPlayerInput(cetVersion)

        Observe("SettingsMainGameController", "OnUninitialize", function()
            refreshInputSettings()
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
        GameSession.OnResurrect(function()
            setSessionLoaded(true, "resurrected")
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
        if not initialized or not isLoaded or not isModEnabled() then
            return
        end

        local player = ensurePlayerBound()
        local playerState = isPaused and nil or collectPlayerState(delta)
        if not isPaused and not playerState then
            RuntimeHeight.ResetPlayer()
            CameraCore.Suspend("player state unavailable")
            return
        end
        if playerState then
            logSceneContext(playerState)
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
            isModEnabled() and Config.inner.immersiveViewEnabled,
            isModEnabled() and HeightControl.IsEnabled(),
            HeightControl.GetTargetCentimeters(),
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

        local enabled, changed = ImGui.Checkbox("Enabled", userEnabled)
        if changed then
            setUserEnabled(enabled, "disabled in overlay")
        end

        local disablingMods = {}
        for modName in pairs(apiSuspensions) do
            disablingMods[#disablingMods + 1] = modName
        end
        table.sort(disablingMods)
        if #disablingMods > 0 then
            ImGui.TextWrapped("Disabled by mods: " .. table.concat(disablingMods, ", "))
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
        Config.inner.gigaVEnabled, changed = ImGui.Checkbox(
            "GigaV",
            Config.inner.gigaVEnabled
        )
        tooltipIfHovered("Unlocks adjustments from -100 to +200 cm.")
        if changed then
            Config.SaveConfig()
        end

        Config.inner.externalHeightControlEnabled, changed = ImGui.Checkbox(
            "Allow other mods to control height",
            Config.inner.externalHeightControlEnabled
        )
        tooltipIfHovered("Other mods can add temporary offsets or disable height adjustment. Turning this off restores your settings.")
        if changed then
            Config.SaveConfig()
            if not Config.inner.externalHeightControlEnabled then
                HeightControl.ClearExternalChanges()
            end
        end

        if not GameSession.IsLoaded() then
            ImGui.TextWrapped(
                "Load a save to check height compatibility and adjust height."
            )
        elseif RuntimeHeight.IsCompatibilityPending() then
            ImGui.TextDisabled("Checking height compatibility...")
        elseif RuntimeHeight.IsAvailable() then
            local minimumHeight, maximumHeight = HeightControl.GetLimits()
            Config.inner.heightAdjustmentAmount, changed = ImGui.SliderInt(
                "Your adjustment",
                math.floor(Config.inner.heightAdjustmentAmount),
                minimumHeight,
                maximumHeight,
                "%+d cm"
            )
            if changed then
                Config.SaveConfig()
            end

            local heightState = HeightControl.GetState(isModEnabled())
            local disablingHeightMods = HeightControl.GetDisablingMods()
            if #heightState.contributions > 0 then
                local clamped = HeightControl.GetRequestedCentimeters() ~= heightState.targetCentimeters
                if clamped then
                    ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.65, 0.15, 1.0)
                end
                ImGui.Text(("Combined adjustment: %+.1f cm"):format(heightState.targetCentimeters))
                if clamped then
                    ImGui.PopStyleColor(1)
                end
            end
            if #disablingHeightMods > 0 then
                ImGui.TextDisabled("Height suspended by mods")
            end
            if (#heightState.contributions > 0 or #disablingHeightMods > 0)
                and ImGui.TreeNode("Mod height control") then
                for _, contribution in ipairs(heightState.contributions) do
                    ImGui.TextWrapped(("%s: %+.1f cm"):format(
                        contribution.modName,
                        contribution.centimeters
                    ))
                end
                for _, modName in ipairs(disablingHeightMods) do
                    ImGui.TextWrapped(modName .. ": height suspended")
                end
                ImGui.TreePop()
            end

            local heightAmount = heightState.targetCentimeters
            if heightAmount < Vars.HEIGHT.MINIMUM_CM or heightAmount > Vars.HEIGHT.MAXIMUM_CM then
                ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.25, 0.25, 1.0)
                ImGui.TextWrapped(
                    "Experimental height: expect body clipping and animation distortion."
                )
                ImGui.PopStyleColor(1)
            end
            local suppressionReason = RuntimeHeight.GetSuppressionReason()
            if heightState.enabled
                and heightAmount ~= 0
                and suppressionReason then
                ImGui.TextWrapped("Temporarily disabled: " .. suppressionReason)
            end
            ImGui.Text(("Estimated height: ~%.0f cm"):format(
                RuntimeHeight.GetEstimatedHeightCentimeters()
            ))
        else
            ImGui.TextDisabled("Controls unavailable")
            ImGui.TextWrapped(heightUnavailableMessages[RuntimeHeight.GetStatus()]
                or "Height adjustment is unavailable. Restart the game and check ImmersiveFirstPerson.log if it persists.")
        end

        ImGui.Separator()
        ImGui.Text("Debug")
        Config.inner.debugLogging, changed = ImGui.Checkbox(
            "Logging",
            Config.inner.debugLogging
        )
        tooltipIfHovered(
            "Writes diagnostics to ImmersiveFirstPerson.log in the mod folder. "
            .. "Enabled by default. Errors are still reported when disabled."
        )
        if changed then
            Config.SaveConfig()
            lastSceneContext = {}
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
        setUserEnabled(not userEnabled, "disabled by hotkey")
    end)

    registerInput("ifp_freelook", "FreeLook", function(keydown)
        if not isLoaded or not isModEnabled() then
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

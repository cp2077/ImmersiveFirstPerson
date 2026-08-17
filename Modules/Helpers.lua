local Helpers = {}
local debugLoggingEnabled = true

local session = {
    player = nil,
    blackboard = nil,
    definition = nil,
    workspotSystem = nil,
    transactionSystem = nil,
    weaponSlot = nil,
}

local function clearSession()
    session.player = nil
    session.blackboard = nil
    session.definition = nil
    session.workspotSystem = nil
    session.transactionSystem = nil
    session.weaponSlot = nil
end

local function getFPPComponent(player)
    return player:GetFPPCameraComponent()
end

local function attachPlayer(player)
    clearSession()
    session.player = player
    if not player then
        return false
    end

    local definitions = Game.GetAllBlackboardDefs()
    local blackboardSystem = Game.GetBlackboardSystem()
    session.definition = definitions and definitions.PlayerStateMachine or nil
    if session.definition and blackboardSystem then
        session.blackboard = blackboardSystem:GetLocalInstanced(
            player:GetEntityID(),
            session.definition
        )
    end
    session.workspotSystem = Game.GetWorkspotSystem()
    session.transactionSystem = Game.GetTransactionSystem()
    session.weaponSlot = TweakDBID.new("AttachmentSlots.WeaponRight")
    return session.blackboard ~= nil
end

function Helpers.AttachPlayer(player)
    local ok, attached = pcall(attachPlayer, player)
    if not ok then
        clearSession()
        return false
    end
    return attached
end

function Helpers.DetachPlayer()
    clearSession()
end

function Helpers.GetPlayer()
    return session.player
end

function Helpers.PrintMsg(message)
    print("[ImmersiveFirstPerson] " .. tostring(message))
end

function Helpers.SetDebugLoggingEnabled(enabled)
    debugLoggingEnabled = enabled == true
end

function Helpers.IsDebugLoggingEnabled()
    return debugLoggingEnabled
end

function Helpers.Log(message)
    if not debugLoggingEnabled then
        return
    end

    local text = "[ImmersiveFirstPerson] " .. tostring(message)
    -- CET release builds flush warnings immediately. Routine diagnostics should
    -- stay at info level so camera-state transitions do not force disk flushes.
    if spdlog and spdlog.info then
        spdlog.info(text)
    end
end

function Helpers.RaiseError(message)
    local text = "[ImmersiveFirstPerson] " .. tostring(message)
    print(text)
    error(text, 2)
end

function Helpers.GetFPP()
    local player = Helpers.GetPlayer()
    if not player then
        return nil
    end

    local ok, fpp = pcall(getFPPComponent, player)
    if not ok then
        clearSession()
        return nil
    end
    return fpp
end

function Helpers.GetFOV(fpp)
    fpp = fpp or Helpers.GetFPP()
    if not fpp then
        return nil
    end

    local fov = fpp:GetFOV()
    if type(fov) ~= "number" or fov < 10 or fov > 120 then
        return 68
    end
    return fov
end

function Helpers.HasBVFP()
    return GetMod("BetterVehicleFirstPerson") ~= nil
end

local function blackboardInt(blackboard, definition, fieldName, fallback)
    local field = definition[fieldName]
    return field and blackboard:GetInt(field) or fallback
end

local function blackboardBool(blackboard, definition, fieldName, fallback)
    local field = definition[fieldName]
    return field and blackboard:GetBool(field) or fallback
end

local function refreshPlayerState(target)
    local player = session.player
    local blackboard = session.blackboard
    local definition = session.definition
    if not player or not blackboard or not definition then
        return nil
    end

    local detailedLocomotion = blackboardInt(blackboard, definition, "LocomotionDetailed", 0)
    local highLevel = blackboardInt(blackboard, definition, "HighLevel", 0)
    local vehicleState = blackboardInt(blackboard, definition, "Vehicle", 0)
    local landingState = blackboardInt(blackboard, definition, "Landing", 0)
    local remoteVehicleID = definition.EntityIDVehicleRemoteControlled
        and blackboard:GetEntityID(definition.EntityIDVehicleRemoteControlled)
        or nil
    local remoteVehicleHash = remoteVehicleID and remoteVehicleID.hash or nil
    local inspectionComponent = player:GetInspectionComponent()
    local playerState = player:GetPS()
    local mountedVehicle = vehicleState == 0
        and Game['GetMountedVehicle;GameObject'](player)
        or nil
    local knockedDown = detailedLocomotion == 29
        or detailedLocomotion == 31
        or landingState > 1
        or StatusEffectSystem.ObjectHasStatusEffectOfType(player, "VehicleKnockdown")
        or StatusEffectSystem.ObjectHasStatusEffectOfType(player, "BikeKnockdown")

    target.sceneTier = blackboardInt(blackboard, definition, "SceneTier", 0)
    target.hasWeapon = session.transactionSystem ~= nil
        and session.transactionSystem:GetItemInSlot(player, session.weaponSlot) ~= nil
    target.weaponState = blackboardInt(blackboard, definition, "Weapon", 0)
    target.upperBodyState = blackboardInt(blackboard, definition, "UpperBody", 0)
    target.vitalsState = blackboardInt(blackboard, definition, "Vitals", 0)
    target.inVehicle = vehicleState ~= 0 or mountedVehicle ~= nil
    target.remoteVehicle = remoteVehicleHash ~= nil and remoteVehicleHash ~= 0ULL
    target.deviceCamera = blackboardBool(blackboard, definition, "IsControllingDevice", false)
        or blackboardBool(blackboard, definition, "IsControllingCamera", false)
        or blackboardBool(blackboard, definition, "IsUIZoomDevice", false)
    target.inMinigame = blackboardBool(blackboard, definition, "IsInMinigame", false)
    target.inspecting = inspectionComponent ~= nil
        and inspectionComponent:GetIsPlayerInspecting() == true
    target.forceOpeningDoor = blackboardBool(
        blackboard,
        definition,
        "IsForceOpeningDoor",
        false
    )
    target.swimming = highLevel == 6
        or blackboardInt(blackboard, definition, "Swimming", 0) > 0
    target.takingDown = blackboardInt(blackboard, definition, "Takedown", 0) > 0
    target.carryingBody = blackboardInt(blackboard, definition, "BodyCarrying", 0) > 0
    target.felled = detailedLocomotion == 31
    target.onLadder = detailedLocomotion >= 10 and detailedLocomotion <= 13
    target.consumableState = blackboardInt(blackboard, definition, "Consumable", 0)
    target.traversal = detailedLocomotion >= 8 and detailedLocomotion <= 13
    target.inWorkspot = session.workspotSystem ~= nil
        and session.workspotSystem:IsActorInWorkspot(player) == true
    target.knockedDown = knockedDown == true
    target.crouching = playerState ~= nil and playerState:IsCrouch() == true
    return target
end

local function refreshPlayerStateSource()
    local player = Game.GetPlayer()
    local definition = session.definition
    local blackboardSystem = Game.GetBlackboardSystem()
    if not player or not definition or not blackboardSystem then
        return false
    end

    local blackboard = blackboardSystem:GetLocalInstanced(
        player:GetEntityID(),
        definition
    )
    if not blackboard then
        return false
    end

    -- Scripted transitions can replace this local instance without detaching
    -- the player. Keep ordinary state reads cached, but periodically rebind so
    -- a readable, frozen handle cannot survive indefinitely.
    session.player = player
    session.blackboard = blackboard
    return true
end

function Helpers.RefreshPlayerStateSource()
    local ok, refreshed = pcall(refreshPlayerStateSource)
    return ok and refreshed == true
end

function Helpers.RefreshPlayerState(target)
    target = target or {}
    local ok, refreshed = pcall(refreshPlayerState, target)
    if ok and refreshed then
        return refreshed
    end

    -- Do not retry against a possibly stale native object. Drop every retained
    -- session reference and let the next update bind the current player cleanly.
    clearSession()
    return nil
end

local function getGameSetting(path)
    local groupPath, variableName = path:match('^(/.+)/([A-Za-z0-9_]+)$')
    local settingsSystem = Game.GetSettingsSystem()
    if not groupPath or not variableName or not settingsSystem then
        return nil
    end

    local variable = settingsSystem:GetVar(groupPath, variableName)
    return variable and variable:GetValue() or nil
end

function Helpers.IsYInverted()
    return getGameSetting('/controls/fppcameramouse/FPP_MouseInvertY') == true
end

function Helpers.IsXInverted()
    return getGameSetting('/controls/fppcameramouse/FPP_MouseInvertX') == true
end

return Helpers

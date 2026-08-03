local Helpers = {}

function Helpers.PrintMsg(message)
    print("[ImmersiveFirstPerson] " .. tostring(message))
end

function Helpers.Log(message)
    local text = "[ImmersiveFirstPerson] " .. tostring(message)
    print(text)
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
    local player = Game.GetPlayer()
    if not player then
        return nil
    end

    return player:GetFPPCameraComponent()
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

local function getPlayerBlackboard()
    local player = Game.GetPlayer()
    if not player then
        return nil, nil
    end

    local definitions = Game.GetAllBlackboardDefs()
    local system = Game.GetBlackboardSystem()
    if not definitions or not definitions.PlayerStateMachine or not system then
        return nil, nil
    end

    local blackboard = system:GetLocalInstanced(player:GetEntityID(), definitions.PlayerStateMachine)
    if not blackboard then
        return nil, nil
    end

    return blackboard, definitions.PlayerStateMachine
end

local function readPlayerStateInt(fieldName, fallback)
    local ok, value = pcall(function()
        local blackboard, definition = getPlayerBlackboard()
        local field = definition and definition[fieldName]
        if not blackboard or not field then
            return fallback
        end
        return blackboard:GetInt(field)
    end)

    if ok then
        return value
    end
    return fallback
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

function Helpers.GetSceneTier()
    return readPlayerStateInt("SceneTier", 0)
end

function Helpers.GetHighLevelState()
    return readPlayerStateInt("HighLevel", 0)
end

function Helpers.GetDetailedLocomotionState()
    return readPlayerStateInt("LocomotionDetailed", 0)
end

function Helpers.GetUpperBodyState()
    return readPlayerStateInt("UpperBody", 0)
end

function Helpers.GetWeaponState()
    return readPlayerStateInt("Weapon", 0)
end

function Helpers.IsTraversalLocomotion()
    local state = Helpers.GetDetailedLocomotionState()
    -- gamePSMDetailedLocomotionStates: Climb, Vault, and the four ladder states.
    return state >= 8 and state <= 13
end

function Helpers.IsOnLadder()
    local state = Helpers.GetDetailedLocomotionState()
    -- gamePSMDetailedLocomotionStates: Ladder through LadderJump.
    return state >= 10 and state <= 13
end

function Helpers.IsTakingDown()
    return readPlayerStateInt("Takedown", 0)
end

function Helpers.IsCarryingBody()
    return readPlayerStateInt("BodyCarrying", 0) > 0
end

function Helpers.IsSwimming()
    -- Surface, dive, and swim-climb are separate locomotion states. Their
    -- low-level Swimming value is cleared between transitions, sometimes long
    -- enough for CET to observe a false "left the water" frame. HighLevel stays
    -- at gamePSMHighLevel.Swimming (6) for the complete water session.
    return Helpers.GetHighLevelState() == 6
        or readPlayerStateInt("Swimming", 0) > 0
end

function Helpers.IsKnockedDown()
    if readPlayerStateInt("Landing", 0) > 1 then
        return true
    end

    local player = Game.GetPlayer()
    if not player then
        return false
    end

    local ok, knockedDown = pcall(function()
        return StatusEffectSystem.ObjectHasStatusEffectOfType(player, "VehicleKnockdown")
            or StatusEffectSystem.ObjectHasStatusEffectOfType(player, "BikeKnockdown")
    end)
    return ok and knockedDown or false
end

function Helpers.HasMountedVehicle()
    local player = Game.GetPlayer()
    return player ~= nil and Game['GetMountedVehicle;GameObject'](player) ~= nil
end

function Helpers.IsInWorkspot()
    local player = Game.GetPlayer()
    local workspotSystem = Game.GetWorkspotSystem()
    if not player or not workspotSystem then
        return false
    end

    local ok, active = pcall(function()
        return workspotSystem:IsActorInWorkspot(player)
    end)
    return ok and active == true
end

function Helpers.IsInVehicle()
    local player = Game.GetPlayer()
    if not player then
        return false
    end

    local workspotSystem = Game.GetWorkspotSystem()
    if not workspotSystem or not workspotSystem:IsActorInWorkspot(player) then
        return false
    end

    local ok, isInVehicle = pcall(function()
        local info = workspotSystem:GetExtendedInfo(player)
        return info and info.isActive and Helpers.HasMountedVehicle()
    end)
    return ok and isInVehicle or false
end

function Helpers.HasWeapon()
    local player = Game.GetPlayer()
    if not player then
        return false
    end

    local transactionSystem = Game.GetTransactionSystem()
    return transactionSystem ~= nil
        and transactionSystem:GetItemInSlot(player, TweakDBID.new("AttachmentSlots.WeaponRight")) ~= nil
end

function Helpers.IsCrouching()
    local player = Game.GetPlayer()
    if not player then
        return false
    end

    local playerState = player:GetPS()
    return playerState ~= nil and playerState:IsCrouch() or false
end

function Helpers.IsYInverted()
    return getGameSetting('/controls/fppcameramouse/FPP_MouseInvertY') == true
end

function Helpers.IsXInverted()
    return getGameSetting('/controls/fppcameramouse/FPP_MouseInvertX') == true
end

return Helpers

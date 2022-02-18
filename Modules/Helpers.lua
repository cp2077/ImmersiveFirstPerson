local GameSettings = require("Modules/GameSettings")
local Config = require("Modules/Config")

local Helpers = {}

--------------------
-- UTILS
--------------------

function Helpers.PrintMsg(msg)
    msg = ('[ImmersiveFirstPerson] ' .. msg)
    print(msg)
end

function Helpers.RaiseError(msg)
    msg = ('[ImmersiveFirstPerson] ' .. msg)
    print(msg)
    error(msg, 2)
end


----------------
-- THE REST
----------------

function Helpers.HasBVFP()
    local bvfp = GetMod("BetterVehicleFirstPerson")
    return bvfp ~= nil
end

-----------------
-- CAMERA
-----------------

function Helpers.GetFPP()
    local player = Game.GetPlayer()
    if player == nil then
        return
    end

    local fpp = player:GetFPPCameraComponent()
    if fpp == nil then
    end

    return fpp
end

function Helpers.ResetCamera(defaultFOV)
    local fpp = Helpers.GetFPP()
    if fpp == nil then
        return
    end

    fpp:SetLocalPosition(Vector4.new(0.0, 0.0, 0, 1.0))
    fpp:SetLocalOrientation(Quaternion.new(0.0, 0.0, 0, 1.0))
    if defaultFOV then
        fpp:SetFOV(defaultFOV)
    end
end

function Helpers.ResetFOV(fov)
    local fpp = Helpers.GetFPP()
    if fpp == nil then
        return
    end

    if fov then
        fpp:SetFOV(fov)
    end
end

function Helpers.SetCamera(x, y, z, roll, pitch, yaw, fov)
    local fpp = Helpers.GetFPP()
    if not fpp then
        return
    end

    if roll ~= nil or pitch ~= nil or yaw ~= nil then
        if roll == nil then roll = 0 end
        if pitch == nil then pitch = 0 end
        if yaw == nil then yaw = 0 end
        fpp:SetLocalOrientation(GetSingleton('EulerAngles'):ToQuat(EulerAngles.new(roll, pitch, yaw)))
    end

    if x ~= nil or y ~= nil or z ~= nil then
        if x == nil then x = 0 end
        if y == nil then y = 0 end
        if z == nil then z = 0 end
        fpp:SetLocalPosition(Vector4.new(x, y, z, 1.0))
    end

    if fov ~= nil and fov > 1 and fov < 120 then
        fpp:SetFOV(fov)
    end
end

function Helpers.GetPitch()
    local ok, res = pcall(function()
        local fpp = Helpers.GetFPP()
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

function Helpers.GetFOV()
    local fpp = Helpers.GetFPP()
    if not fpp then
        return
    end

    local fov = fpp:GetFOV()

    -- TODO: fix
    if fov < 10 then
        fov = 68
    end

    return fov
end


Helpers._protected = {
    isFreeObservation = false,
    isRestoringCamera = false,
}
function Helpers.IsFreeObservation() return Helpers._protected.isFreeObservation end
function Helpers.IsRestoringCamera() return Helpers._protected.isRestoringCamera end
function Helpers.SetFreeObservation(val) Helpers._protected.isFreeObservation = val end
function Helpers.SetRestoringCamera(val) Helpers._protected.isRestoringCamera = val end

function Helpers.LockMovement()
    GameSettings.Set('/controls/fppcameramouse/FPP_MouseX', 0)
    GameSettings.Set('/controls/fppcameramouse/FPP_MouseY', 0)
end
function Helpers.UnlockMovement()
    local x = Config.inner.mouseNativeSensX
    local y = Config.inner.mouseNativeSensY
    if x == nil or x < 1 then x = 5 end
    if x == nil or y < 1 then y = 5 end

    GameSettings.Set('/controls/fppcameramouse/FPP_MouseX', x)
    GameSettings.Set('/controls/fppcameramouse/FPP_MouseY', y)
end

------------------
-- Context detection
------------------

function Helpers.HasMountedVehicle()
    local player = Game.GetPlayer()
    return player and (not not Game['GetMountedVehicle;GameObject'](player))
end

function Helpers.IsPlayerDriver()
    local player = Game.GetPlayer()
    if player then
        local veh = Game['GetMountedVehicle;GameObject'](player)
        if veh then
            return veh:IsPlayerDriver()
        end
    end
end

-- return Player, blackboardDefs and blackboardSystem if all of them are present, otherwise nil
function GetPlayerBlackboardDefsAndBlackboardSystemIfAll()
    local player = Game.GetPlayer()
    if player then
        local blackboardDefs = Game.GetAllBlackboardDefs()
        if blackboardDefs then
            local blackboardSystem = Game.GetBlackboardSystem()
            if blackboardSystem then
                return player, blackboardDefs, blackboardSystem
            end
        end
    end
end

function Helpers.IsInVehicle()
    local player = Game.GetPlayer()
    if player then
        local workspotSystem = Game.GetWorkspotSystem()
        return workspotSystem and workspotSystem:IsActorInWorkspot(player)
            and workspotSystem:GetExtendedInfo(player).isActive
            and Helpers.HasMountedVehicle()
    end
    return false
end

function Helpers.IsSwimming()
    local player, blackboardDefs, blackboardSystem = GetPlayerBlackboardDefsAndBlackboardSystemIfAll()
    if player then
        local blackboardPSM = blackboardSystem:GetLocalInstanced(player:GetEntityID(), blackboardDefs.PlayerStateMachine)
        return blackboardPSM:GetInt(blackboardDefs.PlayerStateMachine.Swimming) > 0
    end
    return false
end

function Helpers.IsYInverted()
    return GameSettings.Get('/controls/fppcameramouse/FPP_MouseInvertY')
end
function Helpers.IsXInverted()
    return GameSettings.Get('/controls/fppcameramouse/FPP_MouseInvertX')
end

-- Undefined = 0
-- Tier1_FullGameplay = 1
-- Tier2_StagedGameplay = 2
-- Tier3_LimitedGameplay = 3
-- Tier4_FPPCinematic = 4
-- Tier5_Cinematic = 5
function Helpers.GetSceneTier()
    local player, blackboardDefs, blackboardSystem = GetPlayerBlackboardDefsAndBlackboardSystemIfAll()
    if player then
        local blackboardPSM = blackboardSystem:GetLocalInstanced(player:GetEntityID(), blackboardDefs.PlayerStateMachine)
        return blackboardPSM:GetInt(blackboardDefs.PlayerStateMachine.SceneTier)
    end
    return 0
end

function Helpers.IsCarryingBody()
    local player, blackboardDefs, blackboardSystem = GetPlayerBlackboardDefsAndBlackboardSystemIfAll()
    if player then
        local blackboardPSM = blackboardSystem:GetLocalInstanced(player:GetEntityID(), blackboardDefs.PlayerStateMachine)
        return blackboardPSM:GetInt(blackboardDefs.PlayerStateMachine.BodyCarrying) > 0
    end

    return false
end

-- TODO: implement fully?
function Helpers.IsCarrying()
    local player, blackboardDefs, blackboardSystem = GetPlayerBlackboardDefsAndBlackboardSystemIfAll()
    if player then
        local blackboardPSM = blackboardSystem:GetLocalInstanced(player:GetEntityID(), blackboardDefs.PlayerStateMachine)
        return blackboardPSM:GetInt(blackboardDefs.PlayerStateMachine.Carrying) > 0
    end
end

function Helpers.HasWeapon()
    local player = Game.GetPlayer()
    if player then
        local ts = Game.GetTransactionSystem()
        return ts and ts:GetItemInSlot(player, TweakDBID.new("AttachmentSlots.WeaponRight")) ~= nil
    end
    return false
end

return Helpers

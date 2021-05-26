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
        Helpers.PrintMsg("couldn't get Player")
        return
    end

    local fpp = player:GetFPPCameraComponent()
    if fpp == nil then
        return Helpers.PrintMsg("couldn't get FPP")
    end

    return fpp
end

function Helpers.ResetCamera(defaultFOV)
    local fpp = Helpers.GetFPP()
    if fpp == nil then
        Helpers.PrintMsg("Helpers.ResetCamera: couldn't get FPP")
        return
    end

    fpp:SetLocalPosition(Vector4.new(0.0, 0.0, 0, 1.0))
    fpp:SetLocalOrientation(Quaternion.new(0.0, 0.0, 0, 1.0))
    if defaultFOV then
        fpp:SetFOV(defaultFOV)
    end
end

function Helpers.SetCamera(x, y, z, roll, pitch, yaw, fov)
    local fpp = Helpers.GetFPP()
    if not fpp then
        Helpers.PrintMsg("Helpers.SetCamera: couldn't get FPP")
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
            Helpers.PrintMsg("Helpers.SetCamera: couldn't get FPP")
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
        Helpers.PrintMsg("Helpers.SetCamera: couldn't get FPP")
        return
    end

    local fov = fpp:GetFOV()

    -- TODO: fix
    if fov < 10 then
        Helpers.PrintMsg("Helpers.GetFOV: received invalid invalid fov (<10)")
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
    return not not Game['GetMountedVehicle;GameObject'](Game.GetPlayer())
end
function Helpers.IsPlayerDriver()
    local veh = Game['GetMountedVehicle;GameObject'](Game.GetPlayer())
    if veh then
        return veh:IsPlayerDriver()
    end
end
function Helpers.IsInVehicle()
    return Game.GetWorkspotSystem():IsActorInWorkspot(Game.GetPlayer())
            and Game.GetWorkspotSystem():GetExtendedInfo(Game.GetPlayer()).isActive
            and Helpers.HasMountedVehicle()
end

function Helpers.GetSceneTier()
    local blackboardDefs = Game.GetAllBlackboardDefs()
    local blackboardPSM = Game.GetBlackboardSystem():GetLocalInstanced(Game.GetPlayer():GetEntityID(), blackboardDefs.PlayerStateMachine)
    return blackboardPSM:GetInt(blackboardDefs.PlayerStateMachine.SceneTier)
end

function Helpers.IsCarryingBody()
    local blackboardDefs = Game.GetAllBlackboardDefs()
    local blackboardPSM = Game.GetBlackboardSystem():GetLocalInstanced(Game.GetPlayer():GetEntityID(), blackboardDefs.PlayerStateMachine)
    -- .Carrying
    return blackboardPSM:GetInt(blackboardDefs.PlayerStateMachine.BodyCarrying) > 0
end
function Helpers.IsCarrying()
    local blackboardDefs = Game.GetAllBlackboardDefs()
    local blackboardPSM = Game.GetBlackboardSystem():GetLocalInstanced(Game.GetPlayer():GetEntityID(), blackboardDefs.PlayerStateMachine)
    print(blackboardPSM:GetInt(blackboardDefs.PlayerStateMachine.Carrying))
    return blackboardPSM:GetInt(blackboardDefs.PlayerStateMachine.Carrying) > 0
end

function Helpers.HasWeapon()
    local ts = Game.GetTransactionSystem()
    return ts:GetItemInSlot(Game.GetPlayer(), TweakDBID.new("AttachmentSlots.WeaponRight")) ~= nil
end

return Helpers

package.path = "./?.lua;./?/init.lua;" .. package.path

local calls = {
    getPlayer = 0,
    definitions = 0,
    blackboardSystem = 0,
    localBlackboard = 0,
    workspotSystem = 0,
    transactionSystem = 0,
    weaponSlot = 0,
    entityID = 0,
    detailedLocomotion = 0,
    mountedVehicle = 0,
}

local values = {
    SceneTier = 1,
    LocomotionDetailed = 10,
    HighLevel = 0,
    Vehicle = 0,
    Landing = 0,
    Weapon = 0,
    UpperBody = 0,
    Vitals = 0,
    Swimming = 0,
    Takedown = 0,
    BodyCarrying = 0,
    Consumable = 0,
}
local blackboardFails = false
local currentBlackboard

local definition = setmetatable({}, {
    __index = function(_, key)
        return key
    end,
})

local blackboard = {
    GetInt = function(_, field)
        if blackboardFails then
            error("stale blackboard")
        end
        if field == "LocomotionDetailed" then
            calls.detailedLocomotion = calls.detailedLocomotion + 1
        end
        return values[field] or 0
    end,
    GetBool = function()
        return false
    end,
    GetEntityID = function()
        return { hash = 0ULL }
    end,
}
currentBlackboard = blackboard

local player = {
    GetEntityID = function()
        calls.entityID = calls.entityID + 1
        return { hash = 42ULL }
    end,
    GetFPPCameraComponent = function()
        return "fpp"
    end,
    GetInspectionComponent = function()
        return nil
    end,
    GetPS = function()
        return { IsCrouch = function() return false end }
    end,
}

local workspotSystem = {
    IsActorInWorkspot = function()
        return false
    end,
}

local transactionSystem = {
    GetItemInSlot = function()
        return nil
    end,
}

Game = {
    GetPlayer = function()
        calls.getPlayer = calls.getPlayer + 1
        return player
    end,
    GetAllBlackboardDefs = function()
        calls.definitions = calls.definitions + 1
        return { PlayerStateMachine = definition }
    end,
    GetBlackboardSystem = function()
        calls.blackboardSystem = calls.blackboardSystem + 1
        return {
            GetLocalInstanced = function()
                calls.localBlackboard = calls.localBlackboard + 1
                return currentBlackboard
            end,
        }
    end,
    GetWorkspotSystem = function()
        calls.workspotSystem = calls.workspotSystem + 1
        return workspotSystem
    end,
    GetTransactionSystem = function()
        calls.transactionSystem = calls.transactionSystem + 1
        return transactionSystem
    end,
    ['GetMountedVehicle;GameObject'] = function()
        calls.mountedVehicle = calls.mountedVehicle + 1
        return nil
    end,
}

TweakDBID = {
    new = function(value)
        calls.weaponSlot = calls.weaponSlot + 1
        return value
    end,
}

StatusEffectSystem = {
    ObjectHasStatusEffectOfType = function()
        return false
    end,
}

local Helpers = require("Modules/Helpers")

assert(Helpers.AttachPlayer(player), "player cache should attach")
assert(calls.definitions == 1, "definitions should be acquired once")
assert(calls.blackboardSystem == 1, "blackboard system should be acquired once")
assert(calls.localBlackboard == 1, "player blackboard should be acquired once")
assert(calls.workspotSystem == 1, "workspot system should be acquired once")
assert(calls.transactionSystem == 1, "transaction system should be acquired once")
assert(calls.weaponSlot == 1, "weapon slot ID should be created once")
assert(calls.entityID == 1, "entity ID should only be read while attaching")

local snapshot = {}
assert(Helpers.RefreshPlayerState(snapshot) == snapshot, "snapshot table should be reused")
assert(Helpers.RefreshPlayerState(snapshot) == snapshot, "snapshot table should stay reusable")
assert(snapshot.sceneTier == 1, "scene tier should be captured")
assert(snapshot.onLadder and snapshot.traversal, "locomotion flags should share one read")
assert(calls.detailedLocomotion == 2, "detailed locomotion should be read once per batch")
assert(calls.mountedVehicle == 2, "mounted vehicle should be checked while vehicle state is clear")
assert(calls.getPlayer == 0, "healthy cache should not reacquire the player")
assert(calls.definitions == 1, "healthy cache should not reacquire definitions")
assert(Helpers.GetFPP() == "fpp", "FPP component should use the cached player")
assert(calls.getPlayer == 0, "FPP lookup should not reacquire the player")

local replacementValues = { SceneTier = 1 }
currentBlackboard = {
    GetInt = function(_, field)
        return replacementValues[field] or 0
    end,
    GetBool = function()
        return false
    end,
    GetEntityID = function()
        return { hash = 0ULL }
    end,
}
values.SceneTier = 5
assert(Helpers.RefreshPlayerStateSource(), "player-state source should refresh at a transition")
assert(Helpers.RefreshPlayerState(snapshot) == snapshot, "replacement blackboard should refresh")
assert(snapshot.sceneTier == 1, "replacement blackboard should replace a readable stale tier")
currentBlackboard = blackboard
assert(Helpers.RefreshPlayerStateSource(), "player-state source should refresh again")

values.Vehicle = 1
assert(Helpers.RefreshPlayerState(snapshot) == snapshot, "vehicle state should refresh")
values.Vehicle = 0
assert(snapshot.inVehicle, "vehicle blackboard state should mark the player in a vehicle")
assert(calls.mountedVehicle == 3, "mounted vehicle lookup should be skipped in a known vehicle")

blackboardFails = true
assert(Helpers.RefreshPlayerState(snapshot) == nil, "failed batch should be rejected")
blackboardFails = false
assert(Helpers.GetPlayer() == nil, "cached access should not reacquire a dropped player")
assert(calls.getPlayer == 2, "only explicit source refreshes should reacquire the player")
assert(Helpers.AttachPlayer(Game.GetPlayer()), "later root acquisition should recover the player")
assert(Helpers.GetPlayer() == player, "explicitly recovered player should be cached")
assert(calls.getPlayer == 3, "later root acquisition should acquire the player once")

print("Player-state cache tests passed")

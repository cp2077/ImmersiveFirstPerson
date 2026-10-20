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

-- Model CET's non-owning wrapper with a Lua weak-value table. This lets GC
-- assertions detect accidental strong ownership in the session cache.
ImmersiveFirstPersonRef = {
    Weak = function(object)
        if object == nil then
            return nil
        end
        local target = setmetatable({ object }, { __mode = "v" })
        return setmetatable({}, {
            target = target,
            __index = function(_, key)
                assert(target[1], "expired weak handle was dereferenced")
                return target[1][key]
            end,
        })
    end,
}

IsDefined = function(object)
    if object == nil then
        return false
    end
    local metadata = getmetatable(object)
    if metadata and metadata.target then
        object = metadata.target[1]
    end
    return object ~= nil and rawget(object, "expired") ~= true
end

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
    IsReplacer = function()
        return false
    end,
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

local currentPlayer = player
local currentDefinition = definition
local currentWorkspotSystem = workspotSystem
local currentTransactionSystem = transactionSystem

Game = {
    GetPlayer = function()
        calls.getPlayer = calls.getPlayer + 1
        return currentPlayer
    end,
    GetAllBlackboardDefs = function()
        calls.definitions = calls.definitions + 1
        return { PlayerStateMachine = currentDefinition }
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
        return currentWorkspotSystem
    end,
    GetTransactionSystem = function()
        calls.transactionSystem = calls.transactionSystem + 1
        return currentTransactionSystem
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
assert(Helpers.GetPlayer():GetEntityID().hash == 42ULL, "explicitly recovered player should be cached")
assert(calls.getPlayer == 3, "later root acquisition should acquire the player once")

for _, object in ipairs({ player, blackboard, definition, workspotSystem, transactionSystem }) do
    assert(Helpers.AttachPlayer(player), "valid session should attach before expiry")
    object.expired = true
    assert(Helpers.RefreshPlayerState(snapshot) == nil, "expired session handle must block state reads")
    assert(Helpers.GetPlayer() == nil, "expired session handle must invalidate the whole cache")
    object.expired = nil
end

local replacer = setmetatable({ IsReplacer = function() return true end }, { __index = player })
assert(not Helpers.AttachPlayer(replacer), "replacer puppets must not enter the cache")
assert(Helpers.GetPlayer() == nil, "rejected replacer must not leave a partial cache")
assert(Helpers.AttachPlayer(player), "normal player should bind after a replacer")
currentPlayer = replacer
assert(not Helpers.RefreshPlayerStateSource(), "refresh must reject a controlled replacer")
assert(Helpers.GetPlayer() == nil, "replacer refresh must drop the previous player")
currentPlayer = player

assert(Helpers.AttachPlayer(player), "normal player should rebind")
currentPlayer = setmetatable({
    GetEntityID = function() return { hash = 43ULL } end,
}, { __index = player })
assert(not Helpers.RefreshPlayerStateSource(), "a different player must require a full rebind")
assert(Helpers.GetPlayer() == nil, "player replacement must invalidate dependent handles")
currentPlayer = player

currentWorkspotSystem = nil
assert(not Helpers.AttachPlayer(player), "missing session objects must reject attachment")
assert(Helpers.GetPlayer() == nil, "failed attachment must not retain partial state")
currentWorkspotSystem = workspotSystem

local bridge = ImmersiveFirstPersonRef
ImmersiveFirstPersonRef = nil
assert(not Helpers.AttachPlayer(player), "missing weak-reference bridge must fail closed")
assert(Helpers.GetPlayer() == nil, "missing bridge must not fall back to strong ownership")
ImmersiveFirstPersonRef = bridge

local released
do
    local temporaryPlayer = setmetatable({}, { __index = player })
    local temporaryBlackboard = setmetatable({}, { __index = blackboard })
    local temporaryDefinition = setmetatable({}, getmetatable(definition))
    local temporaryWorkspot = setmetatable({}, { __index = workspotSystem })
    local temporaryTransaction = setmetatable({}, { __index = transactionSystem })
    released = setmetatable({
        temporaryPlayer, temporaryBlackboard, temporaryDefinition,
        temporaryWorkspot, temporaryTransaction,
    }, { __mode = "v" })
    currentPlayer = temporaryPlayer
    currentBlackboard = temporaryBlackboard
    currentDefinition = temporaryDefinition
    currentWorkspotSystem = temporaryWorkspot
    currentTransactionSystem = temporaryTransaction
    assert(Helpers.AttachPlayer(temporaryPlayer), "temporary session should bind")
end
currentPlayer = nil
currentBlackboard = nil
currentDefinition = nil
currentWorkspotSystem = nil
currentTransactionSystem = nil
collectgarbage("collect")
for index = 1, 5 do
    assert(released[index] == nil, "cache must not own any of its five engine objects")
end
assert(Helpers.GetPlayer() == nil, "released player must be rejected without dereferencing it")

print("Player-state cache tests passed")

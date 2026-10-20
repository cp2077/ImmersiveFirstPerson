local events = {}
local lifecycle = {}
local lastContext
local player = { RegisterInputListener = function() end }
local state = {
    sceneTier = 1,
    vitalsState = 0,
    weaponState = 0,
    upperBodyState = 0,
    consumableState = 0,
    hasWeapon = false,
}

local function noop() end

local session = {
    IsLoaded = function() return true end,
    IsDead = function() return false end,
    IsPaused = function() return false end,
}
for _, name in ipairs({ "Start", "End", "Pause", "Resume", "Death" }) do
    session["On" .. name] = function(callback)
        lifecycle[name] = callback
    end
end

local modules = {
    ["Modules/CameraCore"] = {
        SetInputInversion = noop,
        Suspend = noop,
        Update = function(_, context)
            lastContext = context
        end,
    },
    ["Modules/Helpers"] = {
        AttachPlayer = noop,
        DetachPlayer = noop,
        GetPlayer = function() return player end,
        RefreshPlayerStateSource = function() return true end,
        RefreshPlayerState = function(target)
            for key, value in pairs(state) do
                target[key] = value
            end
            return target
        end,
        IsXInverted = function() return false end,
        IsYInverted = function() return false end,
        Log = noop,
    },
    ["Modules/GameSession"] = session,
    ["Modules/Config"] = {
        InitConfig = noop,
        inner = { immersiveViewEnabled = true, freeLookEnabled = true },
    },
    ["Modules/RuntimeHeight"] = {
        ResetPlayer = noop,
        MarkDirty = noop,
        Shutdown = noop,
        Update = noop,
    },
    ["Modules/NativeCameraSampler"] = { IsActive = function() return false end },
}

local environment = setmetatable({
    require = function(name) return assert(modules[name], name) end,
    Game = { GetPlayer = function() return player end },
    GetVersion = function() return "v1.37.1" end,
    Observe = noop,
    registerForEvent = function(name, callback) events[name] = callback end,
    registerHotkey = noop,
    registerInput = noop,
}, { __index = _G })
local init = assert(loadfile("init.lua"))
setfenv(init, environment)
local api = init().api
events.onInit()

local function frame(label, bodyEligible, freeEligible)
    lastContext = nil
    events.onUpdate(1 / 60)
    assert(lastContext, label .. ": camera context missing")
    assert(lastContext.bodyEligible == bodyEligible, label .. ": wrong body eligibility")
    assert(lastContext.freeEligible == freeEligible, label .. ": wrong freelook eligibility")
end

frame("empty hands", true, true)
state.hasWeapon, state.weaponState = true, 2
frame("weapon drawn", false, true)
state.hasWeapon, state.weaponState = false, 0
for _, upperBody in ipairs({ 1, 3, 4 }) do
    state.upperBodyState = upperBody
    frame("temporary weapon-slot gap", false, true)
end
state.upperBodyState = 5
frame("weapon unequipped, forced empty hands persists", true, true)

state.hasWeapon, state.weaponState = true, 2
frame("weapon still equipped during forced unequip", false, true)
state.hasWeapon = false
frame("weapon state still active during forced unequip", false, true)
state.weaponState, state.sceneTier = 0, 5
frame("authored scene", false, false)
state.sceneTier = 2
frame("scene ended, forced empty hands persists", true, true)
state.inWorkspot = true
frame("scripted workspot", false, false)
state.inWorkspot, state.inVehicle = false, true
frame("vehicle", false, false)
state.inVehicle = false
frame("vehicle exited, forced empty hands persists", true, true)

state.hasWeapon, state.weaponState = true, 2
frame("weapon before toggle", false, true)
api.Disable()
api.Enable()
frame("toggle cannot bypass equipped weapon", false, true)
state.hasWeapon, state.weaponState = false, 0
frame("forced empty hands after toggle", true, true)

state.hasWeapon, state.weaponState, state.upperBodyState = true, 2, 0
frame("weapon in previous session", false, true)
state.hasWeapon, state.weaponState, state.upperBodyState = false, 0, 4
frame("transition in previous session", false, true)
lifecycle.End()
lifecycle.Start()
frame("new session does not inherit weapon transition", true, true)

print("Camera eligibility tests passed")

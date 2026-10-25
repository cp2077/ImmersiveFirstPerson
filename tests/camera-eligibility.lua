package.path = "./?.lua;./?/init.lua;" .. package.path

local fixture = require("tests/support/ifp")()
local api = fixture.api
local state = fixture.state
local lifecycle = fixture.lifecycle

local function frame(label, bodyEligible, freeEligible)
    fixture.context = nil
    fixture.events.onUpdate(1 / 60)
    local context = fixture.context
    assert(context, label .. ": camera context missing")
    assert(context.bodyEligible == bodyEligible, label .. ": wrong body eligibility")
    assert(context.freeEligible == freeEligible, label .. ": wrong freelook eligibility")
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
api.Disable("Camera eligibility test")
api.Enable("Camera eligibility test")
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

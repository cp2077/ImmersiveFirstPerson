package.path = "./?.lua;./?/init.lua;" .. package.path

local newIfp = require("tests/support/ifp")
local fixture = newIfp()
local api = fixture.api
local events = fixture.events
local lifecycle = fixture.lifecycle
local hotkeys = fixture.hotkeys

events.onUpdate(1 / 60)

for _, endSession in ipairs({ lifecycle.End, lifecycle.Death }) do
    assert(api.GetHeightState().available, "height must be verified before testing session cleanup")
    assert(api.SetHeightOffset("Before exit", 10))
    assert(api.SetHeightEnabled("Before exit", false))
    endSession()

    local ok, reason = api.SetHeightOffset("Late request", 10)
    assert(not ok and reason == "unavailable", "height requests after session exit must be refused")
    assert(not api.GetHeightState().available, "session exit must invalidate height compatibility")
    assert(not api.SetHeightEnabled("Late suspension", false), "late height suspensions must be refused")
    assert(api.SetHeightOffset("Before exit", 0), "clearing offsets must remain allowed after exit")
    assert(api.SetHeightEnabled("Late suspension", true), "releasing suspensions must remain allowed after exit")

    lifecycle.Start()
    assert(not api.SetHeightOffset("Before verification", 10), "new sessions must verify height before accepting requests")
    events.onUpdate(1 / 60)
    local height = api.GetHeightState()
    assert(height.available, "height should become available after verification")
    assert(#height.contributions == 0 and height.enabled, "new sessions must not inherit external height changes")
    assert(height.targetCentimeters == 0, "late offsets must not leak into a new session")
    assert(api.SetHeightOffset("After verification", 10))
    assert(api.SetHeightOffset("After verification", 0))
end

api.Disable("Mod A")
api.Disable("Mod B")
api.Enable("Mod A")
assert(not api.IsEnabled(), "one mod must not release another mod's suspension")
api.Enable("Unrelated mod")
assert(not api.IsEnabled(), "a caller without a suspension must not enable the mod")
fixture.context = nil
events.onUpdate(1 / 60)
assert(not fixture.context, "a suspended mod must not update the camera")
assert(api.Disable("Mod B"), "repeated suspension should succeed without stacking")
assert(api.Enable("Mod B"))
assert(api.IsEnabled(), "releasing the last suspension should resume the mod")
events.onUpdate(1 / 60)

assert(api.Disable(), "legacy disable without a name must remain supported")
assert(not api.IsEnabled())
assert(api.Disable("Named caller"))
assert(api.Enable("Named caller"))
assert(not api.IsEnabled(), "named callers must not release the legacy suspension")
assert(api.Disable("Named caller"))
assert(api.Enable())
assert(not api.IsEnabled(), "legacy enable must not release a named suspension")
assert(api.Enable("Named caller"))
assert(api.IsEnabled(), "all named and legacy suspensions should be released")
local ok, reason = api.Disable(" ")
assert(not ok and reason == "invalid_mod_name", "invalid names must be refused")
assert(not api.Enable(" "), "enable must validate the caller too")
assert(api.IsEnabled(), "invalid requests must not change the effective state")

api.Disable("Mod A")
hotkeys.ifp_toggle_enabled()
api.Enable("Mod A")
assert(not api.IsEnabled(), "releasing a suspension must preserve the user's off choice")
hotkeys.ifp_toggle_enabled()
assert(api.IsEnabled(), "the user should be able to enable the mod after release")

api.Disable("Mod A")
lifecycle.End()
lifecycle.Start()
assert(api.IsEnabled(), "session end must clear mod suspensions")
events.onUpdate(1 / 60)
api.Disable("Mod B")
lifecycle.Death()
lifecycle.Resurrect()
assert(api.IsEnabled(), "death must clear mod suspensions")
events.onUpdate(1 / 60)
assert(api.GetHeightState().available, "resurrection must reverify height support")
api.Disable("Mod A")
events.onShutdown()
assert(not api.GetHeightState().available, "CET shutdown must invalidate height compatibility")
assert(not api.SetHeightOffset("After shutdown", 10), "height requests after CET shutdown must be refused")
local reloadedApi = newIfp().api
assert(reloadedApi.IsEnabled(), "CET reload must not inherit suspensions")

print("API and session tests passed")

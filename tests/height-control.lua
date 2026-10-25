package.path = "./?.lua;./?/init.lua;" .. package.path

local config = {
    isReady = true,
    inner = {
        heightAdjustmentEnabled = true,
        heightAdjustmentAmount = 8,
        gigaVEnabled = false,
        externalHeightControlEnabled = false,
    },
}
local available = true
package.loaded["Modules/Config"] = config
package.loaded["Modules/RuntimeHeight"] = {
    IsAvailable = function() return available end,
    IsCompatibilityPending = function() return false end,
    GetSuppressionReason = function() return nil end,
    GetEffectiveHeightCentimeters = function() return 8 end,
}
local HeightControl = require("Modules/HeightControl")

local function refused(name, offset, reason)
    local ok, failure = HeightControl.SetHeightOffset(name, offset)
    assert(not ok and failure == reason, "request should fail for " .. reason)
end

refused("Heels", 5, "access_disabled")
config.inner.externalHeightControlEnabled = true
config.isReady = false
refused("Heels", 5, "not_ready")
config.isReady = true
available = false
refused("Heels", 5, "unavailable")
available = true

assert(HeightControl.SetHeightOffset("Heels", 5))
assert(HeightControl.GetTargetCentimeters() == 13, "offset should add to the user's height")
assert(HeightControl.SetHeightOffset("Heels", 6.5))
assert(HeightControl.GetTargetCentimeters() == 14.5, "update should replace, not accumulate")
assert(HeightControl.SetHeightOffset("Other", 2))
assert(HeightControl.GetTargetCentimeters() == 16.5, "independent contributions should combine")
refused("Other", math.huge, "invalid_offset")
assert(HeightControl.GetTargetCentimeters() == 16.5, "refused write should preserve contributions")
assert(config.inner.heightAdjustmentAmount == 8, "external changes must not overwrite user settings")

assert(HeightControl.SetHeightEnabled("Heels", false))
assert(not HeightControl.GetState(true).enabled, "external toggle should disable height")
assert(HeightControl.GetTargetCentimeters() == 16.5, "external toggle should retain the adjustment")
assert(HeightControl.SetHeightEnabled("Other", false))
assert(HeightControl.SetHeightEnabled("Heels", true))
assert(not HeightControl.GetState(true).enabled, "one mod must not cancel another mod's disable request")
assert(HeightControl.SetHeightEnabled("Other", true))
assert(HeightControl.GetState(true).enabled, "releasing disable requests should restore height")
assert(config.inner.heightAdjustmentEnabled, "external toggle must not overwrite user settings")

assert(HeightControl.SetHeightOffset("Heels", 0))
assert(HeightControl.GetTargetCentimeters() == 10, "clearing one mod should retain another")
refused(" ", 1, "invalid_mod_name")
local ok, reason = HeightControl.SetHeightEnabled("Heels", "false")
assert(not ok and reason == "invalid_enabled", "height toggle must require a boolean")

config.inner.gigaVEnabled = true
assert(HeightControl.SetHeightOffset("Giant", 190))
assert(HeightControl.GetTargetCentimeters() == 200, "GigaV should allow the combined upper endpoint")
assert(HeightControl.SetHeightOffset("Giant", 191))
assert(HeightControl.GetTargetCentimeters() == 200, "GigaV should clamp the combined upper endpoint")
config.inner.gigaVEnabled = false
assert(HeightControl.GetTargetCentimeters() == 20, "turning GigaV off should limit existing contributions")
config.inner.externalHeightControlEnabled = false
assert(HeightControl.GetTargetCentimeters() == 8, "revoking access should immediately restore user height")
HeightControl.ClearExternalChanges()
config.inner.externalHeightControlEnabled = true
assert(HeightControl.GetTargetCentimeters() == 8, "re-enabling access must not resurrect cleared offsets")

assert(HeightControl.SetHeightOffset("Heels", 2))
config.inner.heightAdjustmentEnabled = false
assert(not HeightControl.GetState(true).enabled, "height toggle should be visible to callers")
config.inner.heightAdjustmentEnabled = true
assert(HeightControl.GetTargetCentimeters() == 10, "height toggle should retain contributions")
HeightControl.ClearExternalChanges()
assert(HeightControl.GetTargetCentimeters() == 8, "session end should clear temporary contributions")

config.inner.heightAdjustmentAmount = 0
assert(HeightControl.SetHeightOffset("Heels", 10))
config.inner.heightAdjustmentAmount = 20
assert(HeightControl.GetTargetCentimeters() == 20, "user adjustments should clamp the combined height")
assert(HeightControl.SetHeightOffset("Heels", 5), "reducing an offset while the sum is clamped must succeed")
assert(HeightControl.GetTargetCentimeters() == 20, "external updates should obey the same aggregate clamp")
config.inner.heightAdjustmentAmount = 0
assert(HeightControl.GetTargetCentimeters() == 5, "moving back into range should reveal the updated contribution")

print("External height control tests passed")

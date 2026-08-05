package.path = "./?.lua;./?/init.lua;" .. package.path

local logs = {}
package.loaded["Modules/Helpers"] = {
    Log = function(message)
        logs[#logs + 1] = message
    end,
}

local writes = {}
AnimationControllerComponent = {
    SetInputFloat = function(player, name, value)
        writes[#writes + 1] = { player = player, name = name, value = value }
    end,
}
CName = {
    new = function(value)
        return value
    end,
}

local lookAtWrites = {}
local function playerWrapper(entityHash, graphStatus)
    return {
        GetEntityID = function()
            return { hash = entityHash }
        end,
        ImmersiveFirstPersonGetHeightGraphStatus = function()
            return graphStatus
        end,
        ImmersiveFirstPersonSetHeadLookAtEnabled = function(_, enabled)
            lookAtWrites[#lookAtWrites + 1] = enabled
            return true
        end,
    }
end

local function near(actual, expected, tolerance, label)
    if math.abs(actual - expected) > tolerance then
        error(("%s: expected %.6f, got %.6f"):format(label, expected, actual))
    end
end

local RuntimeHeight = require("Modules/RuntimeHeight")

assert(RuntimeHeight.IsCompatibilityPending(), "graph check should begin pending")
near(RuntimeHeight.GetEffectiveHeightCentimeters(), 0, 0.001, "initial neutral height")
near(RuntimeHeight.GetMinimumHeightCentimeters(), -50, 0.001, "minimum height")
near(RuntimeHeight.GetMaximumHeightCentimeters(), 50, 0.001, "maximum height")

-- CET may return a fresh Lua wrapper for the same native player every call.
-- The transition must still finish instead of restarting from zero.
for _ = 1, 10 do
    RuntimeHeight.Update(0.016, playerWrapper(42, 1), true, true, 50, nil)
end
near(RuntimeHeight.GetEffectiveHeightCentimeters(), 50, 0.001, "same-player wrapper transition")
near(writes[#writes].value, 1, 0.0001, "maximum graph input")
assert(RuntimeHeight.IsAvailable(), "compatible graph should be available")
assert(not RuntimeHeight.IsCompatibilityPending(), "compatible graph should not be pending")
near(RuntimeHeight.GetEstimatedHeightCentimeters(), 221, 0.001, "estimated maximum height")

-- Suppression and restoration each complete through the same 100 ms blend.
for _ = 1, 10 do
    RuntimeHeight.Update(0.016, playerWrapper(42, 1), true, true, 50, "vehicle occupancy")
end
near(RuntimeHeight.GetEffectiveHeightCentimeters(), 0, 0.001, "suppressed height")
near(writes[#writes].value, 0.5, 0.0001, "suppressed graph input")

for _ = 1, 10 do
    RuntimeHeight.Update(0.016, playerWrapper(42, 1), true, true, 50, nil)
end
near(RuntimeHeight.GetEffectiveHeightCentimeters(), 50, 0.001, "restored height")

for _ = 1, 10 do
    RuntimeHeight.Update(0.016, playerWrapper(42, 1), true, true, -50, nil)
end
near(RuntimeHeight.GetEffectiveHeightCentimeters(), -50, 0.001, "minimum height")
near(RuntimeHeight.GetEstimatedHeightCentimeters(), 121, 0.001, "estimated minimum height")
near(writes[#writes].value, 0, 0.0001, "minimum graph input")

-- Look-at redirection follows immersive view while the graph height has its
-- own switch; neither feature should implicitly disable the other.
for _ = 1, 10 do
    RuntimeHeight.Update(0.016, playerWrapper(42, 1), true, false, 14, nil)
end
near(RuntimeHeight.GetEffectiveHeightCentimeters(), 0, 0.001, "independently disabled height")
assert(lookAtWrites[#lookAtWrites] == true, "height toggle should preserve look-at redirection")

for _ = 1, 10 do
    RuntimeHeight.Update(0.016, playerWrapper(42, 1), false, true, 14, nil)
end
near(RuntimeHeight.GetEffectiveHeightCentimeters(), 14, 0.001, "preserved +14 cm height")
near(writes[#writes].value, 0.64, 0.0001, "preserved +14 cm graph input")
assert(lookAtWrites[#lookAtWrites] == false, "immersive toggle should disable look-at redirection")

RuntimeHeight.Shutdown(playerWrapper(42, 1))
near(writes[#writes].value, 0.5, 0.0001, "shutdown graph input")
assert(lookAtWrites[#lookAtWrites] == false, "shutdown should disable look-at redirection")

print(("RuntimeHeight tests passed (%d graph writes, %d log messages)"):format(#writes, #logs))

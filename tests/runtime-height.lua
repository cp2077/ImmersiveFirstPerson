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

-- CET may return a fresh Lua wrapper for the same native player every call.
-- The transition must still finish instead of restarting from zero.
for _ = 1, 10 do
    RuntimeHeight.Update(0.016, playerWrapper(42, 1), true, 30, nil)
end
near(RuntimeHeight.GetEffectiveHeightCentimeters(), 30, 0.001, "same-player wrapper transition")
assert(RuntimeHeight.IsAvailable(), "compatible graph should be available")
near(RuntimeHeight.GetEstimatedHeightCentimeters(), 201, 0.001, "estimated maximum height")

-- Suppression and restoration each complete through the same 100 ms blend.
for _ = 1, 10 do
    RuntimeHeight.Update(0.016, playerWrapper(42, 1), true, 30, "vehicle occupancy")
end
near(RuntimeHeight.GetEffectiveHeightCentimeters(), 0, 0.001, "suppressed height")

for _ = 1, 10 do
    RuntimeHeight.Update(0.016, playerWrapper(42, 1), true, 30, nil)
end
near(RuntimeHeight.GetEffectiveHeightCentimeters(), 30, 0.001, "restored height")

RuntimeHeight.Shutdown(playerWrapper(42, 1))
near(writes[#writes].value, 0, 0.0001, "shutdown graph input")
assert(lookAtWrites[#lookAtWrites] == false, "shutdown should disable look-at redirection")

print(("RuntimeHeight tests passed (%d graph writes, %d log messages)"):format(#writes, #logs))

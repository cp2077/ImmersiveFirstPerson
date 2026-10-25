local Config = require("Modules/Config")
local Helpers = require("Modules/Helpers")
local RuntimeHeight = require("Modules/RuntimeHeight")
local Vars = require("Modules/Vars")

local HeightControl = {}
local offsets = {}
local disabledBy = {}

function HeightControl.GetLimits()
    if Config.inner.gigaVEnabled then
        return Vars.HEIGHT.GIGAV_MINIMUM_CM, Vars.HEIGHT.GIGAV_MAXIMUM_CM
    end
    return Vars.HEIGHT.MINIMUM_CM, Vars.HEIGHT.MAXIMUM_CM
end

function HeightControl.GetRequestedCentimeters()
    local amount = Config.inner.heightAdjustmentAmount or 0
    if Config.inner.externalHeightControlEnabled then
        for _, offset in pairs(offsets) do
            amount = amount + offset
        end
    end
    return amount
end

function HeightControl.GetTargetCentimeters()
    local minimum, maximum = HeightControl.GetLimits()
    return math.max(minimum, math.min(maximum, HeightControl.GetRequestedCentimeters()))
end

local function checkAccess()
    if not Config.isReady then
        return false, "not_ready"
    end
    if not Config.inner.externalHeightControlEnabled then
        return false, "access_disabled"
    end
    if not RuntimeHeight.IsAvailable() then
        return false, "unavailable"
    end
    return true
end

function HeightControl.SetHeightOffset(modName, centimeters)
    if not Helpers.IsValidModName(modName) then
        return false, "invalid_mod_name"
    end
    if type(centimeters) ~= "number" or centimeters ~= centimeters
        or centimeters == math.huge or centimeters == -math.huge then
        return false, "invalid_offset"
    end

    -- Clearing a contribution must remain possible after access is revoked or
    -- compatibility is lost. It never changes the user's configured height.
    if centimeters ~= 0 then
        local allowed, reason = checkAccess()
        if not allowed then
            return false, reason
        end
    end

    offsets[modName] = centimeters ~= 0 and centimeters or nil
    return true
end

function HeightControl.SetHeightEnabled(modName, enabled)
    if not Helpers.IsValidModName(modName) then
        return false, "invalid_mod_name"
    end
    if type(enabled) ~= "boolean" then
        return false, "invalid_enabled"
    end
    if not enabled then
        local allowed, reason = checkAccess()
        if not allowed then
            return false, reason
        end
    end
    disabledBy[modName] = not enabled and true or nil
    return true
end

function HeightControl.IsEnabled()
    return Config.inner.heightAdjustmentEnabled == true
        and (not Config.inner.externalHeightControlEnabled or next(disabledBy) == nil)
end

function HeightControl.ClearExternalChanges()
    offsets = {}
    disabledBy = {}
end

function HeightControl.GetDisablingMods()
    local disablingMods = {}
    if Config.inner.externalHeightControlEnabled then
        for name in pairs(disabledBy) do
            disablingMods[#disablingMods + 1] = name
        end
    end
    table.sort(disablingMods)
    return disablingMods
end

function HeightControl.GetState(modEnabled)
    local contributions = {}
    if Config.inner.externalHeightControlEnabled then
        for name, offset in pairs(offsets) do
            contributions[#contributions + 1] = { modName = name, centimeters = offset }
        end
    end
    table.sort(contributions, function(first, second)
        return first.modName < second.modName
    end)
    return {
        available = RuntimeHeight.IsAvailable(),
        pending = RuntimeHeight.IsCompatibilityPending(),
        enabled = modEnabled == true and HeightControl.IsEnabled(),
        targetCentimeters = HeightControl.GetTargetCentimeters(),
        effectiveCentimeters = RuntimeHeight.GetEffectiveHeightCentimeters(),
        suppressedBy = RuntimeHeight.GetSuppressionReason(),
        contributions = contributions,
    }
end

return HeightControl

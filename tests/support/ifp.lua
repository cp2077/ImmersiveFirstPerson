local isValidModName = require("Modules/Helpers").IsValidModName
local Vars = require("Modules/Vars")

local function noop() end

return function()
    local fixture = {
        events = {},
        lifecycle = {},
        hotkeys = {},
        state = {
            sceneTier = 1,
            vitalsState = 0,
            weaponState = 0,
            upperBodyState = 0,
            consumableState = 0,
            hasWeapon = false,
        },
    }
    local player = {
        RegisterInputListener = noop,
        IsReplacer = function() return false end,
    }
    local available = false
    local effectiveHeight = 0
    local suppressionReason
    local runtime = {
        IsAvailable = function() return available end,
        IsCompatibilityPending = function() return not available end,
        GetEffectiveHeightCentimeters = function() return effectiveHeight end,
        GetSuppressionReason = function() return suppressionReason end,
        MarkDirty = noop,
        ResetPlayer = function()
            available = false
            effectiveHeight = 0
            suppressionReason = nil
        end,
        Update = function(_, _, _, enabled, amount, suppressedBy)
            available = true
            effectiveHeight = enabled and not suppressedBy and amount or 0
            suppressionReason = suppressedBy
        end,
    }
    runtime.Shutdown = runtime.ResetPlayer

    local session = {
        IsLoaded = function() return true end,
        IsDead = function() return false end,
        IsPaused = function() return false end,
    }
    for _, name in ipairs({ "Start", "End", "Pause", "Resume", "Death", "Resurrect" }) do
        session["On" .. name] = function(callback)
            fixture.lifecycle[name] = callback
        end
    end

    local modules = {
        ["Modules/Vars"] = Vars,
        ["Modules/RuntimeHeight"] = runtime,
        ["Modules/CameraCore"] = {
            SetInputInversion = noop,
            Suspend = noop,
            Update = function(_, context)
                fixture.context = context
            end,
        },
        ["Modules/Helpers"] = {
            IsValidModName = isValidModName,
            AttachPlayer = noop,
            DetachPlayer = noop,
            GetPlayer = function() return player end,
            RefreshPlayerStateSource = function() return true end,
            RefreshPlayerState = function(target)
                for key, value in pairs(fixture.state) do
                    target[key] = value
                end
                return target
            end,
            IsXInverted = function() return false end,
            IsYInverted = function() return false end,
            IsDebugLoggingEnabled = function() return false end,
            Log = noop,
        },
        ["Modules/GameSession"] = session,
        ["Modules/Config"] = {
            isReady = true,
            InitConfig = noop,
            inner = {
                immersiveViewEnabled = true,
                freeLookEnabled = true,
                heightAdjustmentEnabled = true,
                heightAdjustmentAmount = 0,
                externalHeightControlEnabled = true,
            },
        },
        ["Modules/NativeCameraSampler"] = { IsActive = function() return false end },
    }
    package.loaded["Modules/Helpers"] = modules["Modules/Helpers"]
    package.loaded["Modules/Config"] = modules["Modules/Config"]
    package.loaded["Modules/RuntimeHeight"] = runtime
    package.loaded["Modules/HeightControl"] = nil
    modules["Modules/HeightControl"] = require("Modules/HeightControl")

    local environment = setmetatable({
        require = function(name) return assert(modules[name], name) end,
        Game = { GetPlayer = function() return player end },
        IsDefined = function(value) return value ~= nil end,
        GetVersion = function() return "v1.38.0" end,
        Observe = noop,
        registerForEvent = function(name, callback) fixture.events[name] = callback end,
        registerHotkey = function(name, _, callback) fixture.hotkeys[name] = callback end,
        registerInput = noop,
    }, { __index = _G })
    local init = assert(loadfile("init.lua"))
    setfenv(init, environment)
    fixture.api = init().api
    fixture.events.onInit()
    return fixture
end

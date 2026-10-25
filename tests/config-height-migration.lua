package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["Modules/Helpers"] = {
    PrintMsg = function() end,
    SetDebugLoggingEnabled = function() end,
}

local decodedConfig
local savedConfig
json = {
    decode = function()
        return decodedConfig
    end,
    encode = function(config)
        savedConfig = config
        return "{}"
    end,
}

local originalOpen = io.open
io.open = function(_, mode)
    if mode == "r" then
        return {
            read = function() return "{}" end,
            close = function() return true end,
        }
    end
    return {
        write = function() return true end,
        close = function() return true end,
    }
end

local Config = require("Modules/Config")

for _, version in ipairs({ 7, 8 }) do
    for _, amount in ipairs({ -100, -50, -21, 21, 50, 200 }) do
        decodedConfig = { version = version, heightAdjustmentEnabled = true, heightAdjustmentAmount = amount }
        Config.InitConfig()
        assert(Config.inner.gigaVEnabled, "existing outlying height should enable GigaV")
        assert(savedConfig.heightAdjustmentAmount == amount, "migration should preserve outlying height")
        assert(savedConfig.gigaVEnabled, "migration should persist GigaV")
    end
end

for _, amount in ipairs({ -20, 0, 20 }) do
    decodedConfig = { version = 7, heightAdjustmentAmount = amount }
    Config.InitConfig()
    assert(not Config.inner.gigaVEnabled, "ordinary heights should not enable GigaV")
end

Config.inner.gigaVEnabled = true
Config.inner.heightAdjustmentAmount = 200
Config.SaveConfig()
Config.inner.gigaVEnabled = false
Config.SaveConfig()
assert(savedConfig.heightAdjustmentAmount == 20, "disabling GigaV should clamp the saved height")
assert(not savedConfig.gigaVEnabled, "saving should not re-enable GigaV")

decodedConfig = nil
Config.InitConfig()
assert(not Config.inner.gigaVEnabled, "GigaV should default off")
assert(Config.inner.externalHeightControlEnabled, "external access should default on")
Config.inner.externalHeightControlEnabled = false
Config.SaveConfig()
assert(not savedConfig.externalHeightControlEnabled, "disabling external permission should persist")
decodedConfig = savedConfig
Config.InitConfig()
assert(not Config.inner.externalHeightControlEnabled, "loading must preserve an explicit opt-out")

for _, version in ipairs({ 5, 7 }) do
    decodedConfig = {
        version = version,
        heightAdjustmentEnabled = true,
        heightAdjustmentAmount = 14,
    }
    Config.InitConfig()
    assert(Config.inner.heightAdjustmentAmount == 14,
        ("version %d config did not preserve +14 cm"):format(version))
    assert(Config.inner.externalHeightControlEnabled, "missing external permission should use the default")
end

io.open = originalOpen
print("Config height migration and permission tests passed")

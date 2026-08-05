package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["Modules/Helpers"] = {
    PrintMsg = function() end,
    SetDebugLoggingEnabled = function() end,
}

local decodedConfig
json = {
    decode = function()
        return decodedConfig
    end,
    encode = function(config)
        assert(config.heightAdjustmentAmount == 14, "saved height changed during migration")
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
for _, version in ipairs({ 5, 7 }) do
    decodedConfig = {
        version = version,
        heightAdjustmentEnabled = true,
        heightAdjustmentAmount = 14,
    }
    Config.InitConfig()
    assert(Config.inner.heightAdjustmentAmount == 14,
        ("version %d config did not preserve +14 cm"):format(version))
end

io.open = originalOpen
print("Config height migration tests passed (+14 cm preserved)")

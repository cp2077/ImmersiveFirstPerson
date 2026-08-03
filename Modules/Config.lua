local Helpers = require("Modules/Helpers")
local Vars = require("Modules/Vars")

local defaults = {
    version = Vars.CONFIG_VERSION,
    freeLookSensitivity = Vars.FREELOOK.DEFAULT_SENSITIVITY,
    smoothRestore = false,
    smoothRestoreSpeed = 15,
    freeLookInCombat = true,
    dontChangeFov = false,
}

local Config = {
    inner = {},
    isReady = false,
}

local function copyDefaults()
    local result = {}
    for key, value in pairs(defaults) do
        result[key] = value
    end
    return result
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function readFile(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end

    local content = file:read("*a")
    file:close()
    return content
end

local function readConfig()
    local encoded = readFile(Vars.CONFIG_FILE_NAME)
    if not encoded or encoded == "" then
        return nil
    end

    local ok, decoded = pcall(function()
        return json.decode(encoded)
    end)
    if not ok or type(decoded) ~= "table" then
        Helpers.PrintMsg(('Cannot read config file %q; defaults will be used.'):format(Vars.CONFIG_FILE_NAME))
        return nil
    end

    return decoded
end

local function migrate(config)
    local previousVersion = tonumber(config.version) or 1

    -- Version 1 persisted the user's mouse sensitivity because freelook changed the
    -- game setting. Version 2 never edits user settings, so those values are obsolete.
    config.mouseNativeSensX = nil
    config.mouseNativeSensY = nil

    if previousVersion < 2 then
        -- The old implementation always enabled weapon freelook even though its saved
        -- default said false. Preserve the behavior users actually had.
        config.freeLookInCombat = true
    end

    config.version = Vars.CONFIG_VERSION
    return config
end

local function validate(config)
    local result = copyDefaults()
    for key in pairs(defaults) do
        if config[key] ~= nil then
            result[key] = config[key]
        end
    end

    result.freeLookSensitivity = clamp(tonumber(result.freeLookSensitivity) or defaults.freeLookSensitivity, 1, 100)
    result.smoothRestoreSpeed = clamp(tonumber(result.smoothRestoreSpeed) or defaults.smoothRestoreSpeed, 1, 200)
    result.smoothRestore = result.smoothRestore == true
    result.freeLookInCombat = result.freeLookInCombat == true
    result.dontChangeFov = result.dontChangeFov == true
    result.version = Vars.CONFIG_VERSION
    return result
end

local function writeConfig()
    local file = io.open(Vars.CONFIG_FILE_NAME, "w")
    if not file then
        Helpers.RaiseError(('Cannot write config file %q.'):format(Vars.CONFIG_FILE_NAME))
        return
    end

    file:write(json.encode(Config.inner))
    file:close()
end

function Config.InitConfig()
    Config.inner = validate(migrate(readConfig() or copyDefaults()))
    Config.isReady = true
    writeConfig()
end

function Config.SaveConfig()
    if Config.isReady then
        Config.inner = validate(Config.inner)
        writeConfig()
    end
end

return Config

local Helpers = require("Modules/Helpers")
local Vars = require("Modules/Vars")

local defaults = {
    version = Vars.CONFIG_VERSION,
    debugLogging = true,
    freeLookSensitivity = Vars.FREELOOK.DEFAULT_SENSITIVITY,
    smoothRestore = false,
    smoothRestoreSpeed = 15,
    freeLookInCombat = true,
    dontChangeFov = false,
    heightAdjustmentAmount = 0,
}

local Config = {
    inner = {},
    isReady = false,
}

local writeFailureLogged = false

-- CET removes Lua's `debug` library and sandboxes relative file access to this
-- mod's directory. Keep this path relative; trying to discover the source path
-- with debug.getinfo makes the entire mod fail during require() inside CET.
local CONFIG_PATH = Vars.CONFIG_FILE_NAME

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
    local encoded = readFile(CONFIG_PATH)
    if not encoded or encoded == "" then
        return nil
    end

    local ok, decoded = pcall(function()
        return json.decode(encoded)
    end)
    if not ok or type(decoded) ~= "table" then
        Helpers.PrintMsg(('Cannot read config file %q; defaults will be used.'):format(CONFIG_PATH))
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

    if previousVersion < 4 then
        -- Version 3 stored a pitch angle, while version 4 stores centimetres and
        -- controls different native systems. Do not reinterpret a value such as
        -- 30 degrees as an unsafe 30 cm increase on first launch.
        config.heightAdjustmentEnabled = false
        config.heightAdjustmentAmount = defaults.heightAdjustmentAmount
    end

    if previousVersion < 5 then
        -- Version 5 replaces the collection of native mutation experiments with
        -- one optional, versioned animgraph whose slider value is the complete
        -- height setting. Preserve an explicitly enabled v4 amount; otherwise
        -- migrate to the safe +0 cm default.
        if config.heightAdjustmentEnabled ~= true then
            config.heightAdjustmentAmount = 0
        end
    end

    config.heightAdjustmentEnabled = nil
    config.heightAnimationEnabled = nil
    config.heightHumanoidEnabled = nil
    config.heightCapsuleEnabled = nil
    config.heightSlotFallbackEnabled = nil
    config.heightRigCameraEnabled = nil
    config.heightRigBodyEnabled = nil
    config.heightRigProportionsEnabled = nil

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
    result.debugLogging = result.debugLogging == true
    result.smoothRestore = result.smoothRestore == true
    result.freeLookInCombat = result.freeLookInCombat == true
    result.dontChangeFov = result.dontChangeFov == true
    result.heightAdjustmentAmount = math.floor(clamp(
        tonumber(result.heightAdjustmentAmount) or defaults.heightAdjustmentAmount,
        0,
        30
    ) + 0.5)
    result.version = Vars.CONFIG_VERSION
    return result
end

local function writeConfig()
    local encodedOk, encoded = pcall(json.encode, Config.inner)
    if not encodedOk then
        if not writeFailureLogged then
            Helpers.PrintMsg("Cannot encode config; using in-memory settings: " .. tostring(encoded))
            writeFailureLogged = true
        end
        return false
    end

    local file, openError = io.open(CONFIG_PATH, "w")
    if not file then
        -- Settings persistence is optional. Older builds could fail initialization
        -- here, making a missing config look as though the entire camera mod broke.
        if not writeFailureLogged then
            Helpers.PrintMsg(('Cannot write config file %q (%s); using in-memory settings.'):format(
                CONFIG_PATH,
                tostring(openError)
            ))
            writeFailureLogged = true
        end
        return false
    end

    local wrote, writeError = file:write(encoded)
    local closed, closeError = file:close()
    if not wrote or not closed then
        if not writeFailureLogged then
            Helpers.PrintMsg(('Cannot persist config file %q (%s); using in-memory settings.'):format(
                CONFIG_PATH,
                tostring(writeError or closeError)
            ))
            writeFailureLogged = true
        end
        return false
    end

    writeFailureLogged = false
    return true
end

function Config.InitConfig()
    Config.inner = validate(migrate(readConfig() or copyDefaults()))
    Helpers.SetDebugLoggingEnabled(Config.inner.debugLogging)
    Config.isReady = true
    writeConfig()
end

function Config.SaveConfig()
    if Config.isReady then
        Config.inner = validate(Config.inner)
        Helpers.SetDebugLoggingEnabled(Config.inner.debugLogging)
        writeConfig()
    end
end

return Config

local Helpers = require("Modules/Helpers")
local Vars = require("Modules/Vars")

local Config = {
    inner = {
        freeLookSensitivity = Vars.FREELOOK_DEFAULT_SENSITIVITY,
        smoothRestore = false,
        freeLookInCombat = false,
        mouseNativeSensX = -1,
        mouseNativeSensY = -1,
        smoothRestoreSpeed = 15,
        dontChangeFov = false,
    },
    isReady = false,
}

function Config.InitConfig()
    local config = ReadConfig()
    if config == nil then
        WriteConfig()
    else
        Config.inner = config
    end

    Migrate()
    Config.isReady = true
end

function Config.SaveConfig()
    WriteConfig()
end

function Migrate()
    if Config.inner.dontChangeFov == nil then
      Config.inner.dontChangeFov = false
    end
    -- ...
    WriteConfig()
end

function WriteConfig()
    local sessionPath = Vars.CONFIG_FILE_NAME
    local sessionFile = io.open(sessionPath, 'w')

    if not sessionFile then
        Helpers.RaiseError(('Cannot write config file %q.'):format(sessionPath))
    end

    sessionFile:write(json.encode(Config.inner))
    sessionFile:close()
end

local function readFile(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*a") -- *a or *all reads the whole file
    file:close()
    return content
end

function ReadConfig()
    local configPath = Vars.CONFIG_FILE_NAME

    local configStr = readFile(configPath)

    local ok, res = pcall(function() return json.decode(configStr) end)
    if not ok then
        Helpers.PrintMsg(('Cannot open config file %q. %q'):format(configPath, res))
        return
    end

    return res
end


return Config

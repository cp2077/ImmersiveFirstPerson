package.path = "./?.lua;./?/init.lua;" .. package.path

local observers = {}
local dead = false
local deaths = 0
local resurrections = 0
local blackboard = { GetBool = function() return false end }

Observe = function(class, method, callback)
    observers[class .. "." .. method] = callback
end
GetSingleton = function()
    return {
        GetSystemRequestsHandler = function()
            return { IsPreGame = function() return false end }
        end,
    }
end
Game = {
    GetPlayer = function()
        return {
            IsAttached = function() return true end,
            IsDeadNoStatPool = function() return dead end,
        }
    end,
    GetAllBlackboardDefs = function()
        return { UI_System = {}, PhotoMode = {} }
    end,
    GetBlackboardSystem = function()
        return { Get = function() return blackboard end }
    end,
    GetTimeSystem = function()
        return { IsTimeDilationActive = function() return false end }
    end,
}

local function enter(class, method)
    local callback = observers[class .. "." .. method]
    if callback then
        callback()
    end
end

local GameSession = require("Modules/GameSession")
GameSession.OnDeath(function() deaths = deaths + 1 end)
dead = true
enter("DeathEvents", "OnEnter")
assert(GameSession.IsDead(), "entering the player's death state must mark the session dead")
assert(deaths == 1, "death must reach lifecycle listeners")

GameSession.OnResurrect(function() resurrections = resurrections + 1 end)
dead = false
enter("PlayerPuppet", "OnResurrect")
assert(not GameSession.IsDead(), "completed resurrection must clear the dead state")
assert(resurrections == 1, "resurrection must reach lifecycle listeners")

dead = true
enter("DeathEvents", "OnEnter")
assert(deaths == 2, "a second death after resurrection must notify listeners again")

print("Game session death and resurrection tests passed")

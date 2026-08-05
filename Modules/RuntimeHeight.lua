local Helpers = require("Modules/Helpers")

local RuntimeHeight = {}

local BASE_PLAYER_HEIGHT_CM = 171
local MAXIMUM_HEIGHT_CM = 30
local TRANSITION_DURATION = 0.10
local CONTRACT_POLL_INTERVAL = 0.50
local INPUT_NAME = "ifp_height_blend"

local GRAPH_STATUS = {
    WAITING = 0,
    COMPATIBLE = 1,
    INCOMPATIBLE = 2,
    MISSING_OR_OVERRIDDEN = 3,
}

local state = {
    player = nil,
    playerKey = nil,
    nativeAvailable = nil,
    graphStatus = GRAPH_STATUS.WAITING,
    status = "waiting for player",
    suppressionReason = nil,
    pollElapsed = CONTRACT_POLL_INTERVAL,
    dirty = true,
    lookAtApplied = nil,
    currentBlend = 0.0,
    startBlend = 0.0,
    targetBlend = 0.0,
    transitionElapsed = TRANSITION_DURATION,
    lastSentBlend = nil,
    lastLoggedStatus = nil,
}

local function getPlayerKey(player)
    if not player then
        return nil
    end

    local ok, hash = pcall(function()
        return tostring(player:GetEntityID().hash)
    end)
    if ok and hash then
        return hash
    end

    -- There is only one local player. Falling back to a stable sentinel is
    -- safer than comparing CET userdata wrappers, whose identity can change
    -- between Game.GetPlayer() calls for the same native entity.
    return "local-player"
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function smoothstep(value)
    value = clamp(value, 0.0, 1.0)
    return value * value * (3.0 - 2.0 * value)
end

local function logStatus(value)
    if value == state.lastLoggedStatus then
        return
    end
    state.lastLoggedStatus = value
    Helpers.Log("runtime height: " .. value)
end

local function setStatus(value)
    state.status = value
    logStatus(value)
end

local function inspectGraph(player)
    local ok, result = pcall(function()
        return player:ImmersiveFirstPersonGetHeightGraphStatus()
    end)
    if not ok then
        state.nativeAvailable = false
        state.graphStatus = GRAPH_STATUS.WAITING
        setStatus("RED4ext native plugin unavailable")
        return false
    end

    state.nativeAvailable = true
    state.graphStatus = tonumber(result) or GRAPH_STATUS.WAITING
    if state.graphStatus == GRAPH_STATUS.COMPATIBLE then
        setStatus("height graph ready")
    elseif state.graphStatus == GRAPH_STATUS.INCOMPATIBLE then
        setStatus("height graph is incompatible")
    elseif state.graphStatus == GRAPH_STATUS.MISSING_OR_OVERRIDDEN then
        setStatus("height archive missing or overridden")
    else
        setStatus("waiting for player animation graph")
    end
    return true
end

local function configureLookAt(player, enabled)
    if state.lookAtApplied == enabled and not state.dirty then
        return
    end

    local ok = pcall(function()
        return player:ImmersiveFirstPersonSetHeadLookAtEnabled(enabled)
    end)
    if ok then
        state.lookAtApplied = enabled
    else
        state.nativeAvailable = false
        state.lookAtApplied = nil
    end
end

local function sendBlend(player, value, force)
    value = clamp(value, 0.0, 1.0)
    if not force and state.lastSentBlend
        and math.abs(value - state.lastSentBlend) < 0.0001 then
        return true
    end

    local ok = pcall(function()
        AnimationControllerComponent.SetInputFloat(
            player,
            CName.new(INPUT_NAME),
            value
        )
    end)
    if not ok then
        setStatus("height graph input could not be written")
        state.lastSentBlend = nil
        return false
    end

    state.lastSentBlend = value
    return true
end

local function beginTransition(targetBlend)
    targetBlend = clamp(targetBlend, 0.0, 1.0)
    if math.abs(targetBlend - state.targetBlend) < 0.0001 then
        return
    end
    state.startBlend = state.currentBlend
    state.targetBlend = targetBlend
    state.transitionElapsed = 0.0
end

local function updateTransition(delta, player)
    if state.transitionElapsed >= TRANSITION_DURATION then
        state.currentBlend = state.targetBlend
    else
        state.transitionElapsed = math.min(
            TRANSITION_DURATION,
            state.transitionElapsed + math.max(tonumber(delta) or 0.0, 0.0)
        )
        local progress = TRANSITION_DURATION <= 0.0
            and 1.0
            or state.transitionElapsed / TRANSITION_DURATION
        local eased = smoothstep(progress)
        state.currentBlend = state.startBlend
            + (state.targetBlend - state.startBlend) * eased
    end

    -- Animation-controller inputs are frame-fed values, not durable settings.
    -- Keep publishing even after the transition settles or the graph falls back
    -- toward its declared zero default between the slower contract polls.
    sendBlend(player, state.currentBlend, true)
end

function RuntimeHeight.MarkDirty()
    state.dirty = true
    state.pollElapsed = CONTRACT_POLL_INTERVAL
end

function RuntimeHeight.Update(
    delta,
    player,
    modEnabled,
    amountCentimeters,
    suppressionReason
)
    local elapsed = math.max(tonumber(delta) or 0.0, 0.0)
    if suppressionReason ~= state.suppressionReason
        and (tonumber(amountCentimeters) or 0.0) > 0.0 then
        if suppressionReason then
            Helpers.Log("runtime height suppressed: " .. suppressionReason)
        elseif state.suppressionReason then
            Helpers.Log("runtime height restored after: " .. state.suppressionReason)
        end
    end
    state.pollElapsed = state.pollElapsed + elapsed
    state.suppressionReason = suppressionReason

    local playerKey = getPlayerKey(player)
    if playerKey ~= state.playerKey then
        state.playerKey = playerKey
        state.graphStatus = GRAPH_STATUS.WAITING
        state.currentBlend = 0.0
        state.startBlend = 0.0
        state.targetBlend = 0.0
        state.transitionElapsed = TRANSITION_DURATION
        state.lastSentBlend = nil
        state.lookAtApplied = nil
        state.dirty = true
        state.pollElapsed = CONTRACT_POLL_INTERVAL
    end
    -- Keep the current wrapper for native calls, but never use wrapper identity
    -- to decide whether V changed.
    state.player = player

    if not player then
        setStatus("waiting for player")
        return
    end

    configureLookAt(player, modEnabled == true)

    local shouldPoll = state.dirty or state.pollElapsed >= CONTRACT_POLL_INTERVAL
    if shouldPoll then
        local wasCompatible = state.graphStatus == GRAPH_STATUS.COMPATIBLE
        state.pollElapsed = 0.0
        inspectGraph(player)
        local isCompatible = state.graphStatus == GRAPH_STATUS.COMPATIBLE
        if isCompatible and not wasCompatible then
            state.currentBlend = 0.0
            state.startBlend = 0.0
            state.targetBlend = 0.0
            state.transitionElapsed = TRANSITION_DURATION
            state.lastSentBlend = nil
        elseif not isCompatible then
            state.currentBlend = 0.0
            state.startBlend = 0.0
            state.targetBlend = 0.0
            state.transitionElapsed = TRANSITION_DURATION
            state.lastSentBlend = nil
        end
        state.dirty = false
    end

    if state.graphStatus ~= GRAPH_STATUS.COMPATIBLE then
        return
    end

    local amount = clamp(
        math.floor((tonumber(amountCentimeters) or 0.0) + 0.5),
        0,
        MAXIMUM_HEIGHT_CM
    )
    local targetBlend = modEnabled == true
        and amount > 0
        and suppressionReason == nil
        and amount / MAXIMUM_HEIGHT_CM
        or 0.0
    beginTransition(targetBlend)
    updateTransition(elapsed, player)

end

function RuntimeHeight.Shutdown(player)
    if player and state.graphStatus == GRAPH_STATUS.COMPATIBLE then
        sendBlend(player, 0.0, true)
    end
    if player then
        pcall(function()
            player:ImmersiveFirstPersonSetHeadLookAtEnabled(false)
        end)
    end
    state.player = nil
    state.playerKey = nil
    state.currentBlend = 0.0
    state.targetBlend = 0.0
    state.lastSentBlend = nil
    state.lookAtApplied = nil
    state.suppressionReason = nil
    state.dirty = true
end

function RuntimeHeight.IsAvailable()
    return state.nativeAvailable == true
        and state.graphStatus == GRAPH_STATUS.COMPATIBLE
end

function RuntimeHeight.GetStatus()
    return state.status
end

function RuntimeHeight.GetSuppressionReason()
    return state.suppressionReason
end

function RuntimeHeight.GetEffectiveHeightCentimeters()
    return state.currentBlend * MAXIMUM_HEIGHT_CM
end

function RuntimeHeight.GetEstimatedHeightCentimeters()
    return BASE_PLAYER_HEIGHT_CM + RuntimeHeight.GetEffectiveHeightCentimeters()
end

function RuntimeHeight.GetMaximumHeightCentimeters()
    return MAXIMUM_HEIGHT_CM
end

return RuntimeHeight

local Helpers = require("Modules/Helpers")

local RuntimeHeight = {}

local BASE_PLAYER_HEIGHT_CM = 171
local MINIMUM_HEIGHT_CM = -50
local MAXIMUM_HEIGHT_CM = 50
local HEIGHT_RANGE_CM = MAXIMUM_HEIGHT_CM - MINIMUM_HEIGHT_CM
local NEUTRAL_BLEND = (0 - MINIMUM_HEIGHT_CM) / HEIGHT_RANGE_CM
local TRANSITION_DURATION = 0.10
local CONTRACT_POLL_INTERVAL = 1.00
local INPUT_NAME = "ifp_height_blend"
local inputName = nil

local GRAPH_STATUS = {
    WAITING = 0,
    COMPATIBLE = 1,
    INCOMPATIBLE = 2,
    MISSING_OR_OVERRIDDEN = 3,
}

local state = {
    nativeAvailable = nil,
    graphStatus = GRAPH_STATUS.WAITING,
    status = "waiting for player",
    suppressionReason = nil,
    pollElapsed = CONTRACT_POLL_INTERVAL,
    dirty = true,
    lookAtApplied = nil,
    currentBlend = NEUTRAL_BLEND,
    startBlend = NEUTRAL_BLEND,
    targetBlend = NEUTRAL_BLEND,
    transitionElapsed = TRANSITION_DURATION,
    lastSentBlend = nil,
    lastLoggedStatus = nil,
}

local function getInputName()
    if not inputName then
        inputName = CName.new(INPUT_NAME)
    end
    return inputName
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

local function getGraphStatus(player)
    return player:ImmersiveFirstPersonGetHeightGraphStatus()
end

local function inspectGraph(player)
    local ok, result = pcall(getGraphStatus, player)
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

local function setLookAtEnabled(player, enabled)
    return player:ImmersiveFirstPersonSetHeadLookAtEnabled(enabled)
end

local function configureLookAt(player, enabled)
    if state.lookAtApplied == enabled and not state.dirty then
        return
    end

    local ok = pcall(setLookAtEnabled, player, enabled)
    if ok then
        state.lookAtApplied = enabled
    else
        state.nativeAvailable = false
        state.graphStatus = GRAPH_STATUS.WAITING
        state.lookAtApplied = nil
        setStatus("RED4ext native plugin unavailable")
    end
end

local function setBlendInput(player, name, value)
    AnimationControllerComponent.SetInputFloat(player, name, value)
end

local function sendBlend(player, value, force)
    value = clamp(value, 0.0, 1.0)
    if not force and state.lastSentBlend
        and math.abs(value - state.lastSentBlend) < 0.0001 then
        return true
    end

    local ok = pcall(setBlendInput, player, getInputName(), value)
    if not ok then
        setStatus("height graph input could not be written")
        state.graphStatus = GRAPH_STATUS.WAITING
        state.pollElapsed = CONTRACT_POLL_INTERVAL
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
    -- toward its declared neutral default between the slower contract polls.
    sendBlend(player, state.currentBlend, true)
end

function RuntimeHeight.ResetPlayer()
    state.nativeAvailable = nil
    state.graphStatus = GRAPH_STATUS.WAITING
    state.currentBlend = NEUTRAL_BLEND
    state.startBlend = NEUTRAL_BLEND
    state.targetBlend = NEUTRAL_BLEND
    state.transitionElapsed = TRANSITION_DURATION
    state.lastSentBlend = nil
    state.lookAtApplied = nil
    state.suppressionReason = nil
    state.dirty = true
    state.pollElapsed = CONTRACT_POLL_INTERVAL
    setStatus("waiting for player")
end

function RuntimeHeight.MarkDirty()
    state.dirty = true
end

function RuntimeHeight.Update(
    delta,
    player,
    lookAtEnabled,
    heightEnabled,
    amountCentimeters,
    suppressionReason
)
    local elapsed = math.max(tonumber(delta) or 0.0, 0.0)
    if suppressionReason ~= state.suppressionReason
        and (tonumber(amountCentimeters) or 0.0) ~= 0.0 then
        if suppressionReason then
            Helpers.Log("runtime height suppressed: " .. suppressionReason)
        elseif state.suppressionReason then
            Helpers.Log("runtime height restored after: " .. state.suppressionReason)
        end
    end
    state.pollElapsed = state.pollElapsed + elapsed
    state.suppressionReason = suppressionReason

    if not player then
        setStatus("waiting for player")
        return
    end

    configureLookAt(player, lookAtEnabled == true)
    state.dirty = false

    local shouldPoll = state.nativeAvailable ~= false
        and state.graphStatus == GRAPH_STATUS.WAITING
        and state.pollElapsed >= CONTRACT_POLL_INTERVAL
    if shouldPoll then
        local wasCompatible = state.graphStatus == GRAPH_STATUS.COMPATIBLE
        state.pollElapsed = 0.0
        inspectGraph(player)
        local isCompatible = state.graphStatus == GRAPH_STATUS.COMPATIBLE
        if isCompatible and not wasCompatible then
            state.currentBlend = NEUTRAL_BLEND
            state.startBlend = NEUTRAL_BLEND
            state.targetBlend = NEUTRAL_BLEND
            state.transitionElapsed = TRANSITION_DURATION
            state.lastSentBlend = nil
        elseif not isCompatible then
            state.currentBlend = NEUTRAL_BLEND
            state.startBlend = NEUTRAL_BLEND
            state.targetBlend = NEUTRAL_BLEND
            state.transitionElapsed = TRANSITION_DURATION
            state.lastSentBlend = nil
        end
    end

    if state.graphStatus ~= GRAPH_STATUS.COMPATIBLE then
        return
    end

    local amount = clamp(
        math.floor((tonumber(amountCentimeters) or 0.0) + 0.5),
        MINIMUM_HEIGHT_CM,
        MAXIMUM_HEIGHT_CM
    )
    local targetBlend = heightEnabled == true
        and suppressionReason == nil
        and (amount - MINIMUM_HEIGHT_CM) / HEIGHT_RANGE_CM
        or NEUTRAL_BLEND
    beginTransition(targetBlend)
    updateTransition(elapsed, player)

end

function RuntimeHeight.Shutdown(player)
    if player and state.graphStatus == GRAPH_STATUS.COMPATIBLE then
        sendBlend(player, NEUTRAL_BLEND, true)
    end
    if player then
        pcall(setLookAtEnabled, player, false)
    end
    state.currentBlend = NEUTRAL_BLEND
    state.targetBlend = NEUTRAL_BLEND
    state.lastSentBlend = nil
    state.lookAtApplied = nil
    state.suppressionReason = nil
    state.dirty = true
end

function RuntimeHeight.IsAvailable()
    return state.nativeAvailable == true
        and state.graphStatus == GRAPH_STATUS.COMPATIBLE
end

function RuntimeHeight.IsCompatibilityPending()
    return state.nativeAvailable ~= false
        and state.graphStatus == GRAPH_STATUS.WAITING
end

function RuntimeHeight.GetStatus()
    return state.status
end

function RuntimeHeight.GetSuppressionReason()
    return state.suppressionReason
end

function RuntimeHeight.GetEffectiveHeightCentimeters()
    return MINIMUM_HEIGHT_CM + state.currentBlend * HEIGHT_RANGE_CM
end

function RuntimeHeight.GetEstimatedHeightCentimeters()
    return BASE_PLAYER_HEIGHT_CM + RuntimeHeight.GetEffectiveHeightCentimeters()
end

function RuntimeHeight.GetMaximumHeightCentimeters()
    return MAXIMUM_HEIGHT_CM
end

function RuntimeHeight.GetMinimumHeightCentimeters()
    return MINIMUM_HEIGHT_CM
end

return RuntimeHeight

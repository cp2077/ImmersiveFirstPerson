package.path = "./?.lua;./?/init.lua;" .. package.path

Vector4 = {
    new = function(x, y, z, w)
        return { x = x, y = y, z = z, w = w }
    end,
}
Quaternion = {
    new = function(i, j, k, r)
        local value = { i = i, j = j, k = k, r = r }
        function value:GetForward()
            return { x = 0, y = 1 - 2 * self.i * self.i, z = 2 * self.r * self.i }
        end
        function value:ToEulerAngles()
            return { roll = 0, pitch = math.deg(2 * math.atan2(self.i, self.r)), yaw = 0 }
        end
        return value
    end,
}
Game = {}

local function pitchRotation(degrees)
    local halfAngle = math.rad(degrees) / 2
    return Quaternion.new(math.sin(halfAngle), 0, 0, math.cos(halfAngle))
end

local localPosition = Vector4.new(0, 0, 0, 1)
local localOrientation = pitchRotation(0)
local parentPitch = 0
local orientationReadbackScale = 1
local fpp = {
    GetLocalPosition = function() return localPosition end,
    GetLocalOrientation = function() return localOrientation end,
    GetLocalToWorld = function()
        return {
            ToQuat = function()
                return pitchRotation(parentPitch + localOrientation:ToEulerAngles().pitch)
            end,
        }
    end,
    GetZoom = function() return 1 end,
    SetLocalTransform = function(_, position, orientation)
        localPosition = position
        localOrientation = Quaternion.new(
            orientation.i * orientationReadbackScale,
            orientation.j * orientationReadbackScale,
            orientation.k * orientationReadbackScale,
            orientation.r * orientationReadbackScale
        )
    end,
}

package.loaded["Modules/Helpers"] = {
    GetFPP = function() return fpp end,
    GetFOV = function() return 68.23 end,
    Log = function() end,
}
package.loaded["Modules/Config"] = { inner = {} }

local CameraCore = require("Modules/CameraCore")
local context = {
    bodyContextEligible = true,
    bodyWeaponBlocked = false,
    bodyEligible = true,
    hasWeapon = false,
    crouching = false,
}

local function update(frames)
    for _ = 1, frames or 1 do
        CameraCore.Update(1 / 60, context)
    end
end

local function armed(value)
    context.bodyWeaponBlocked = value
    context.bodyEligible = not value
    context.hasWeapon = value
    update()
end

local function expectPitch(expected, message)
    local actual = localOrientation:ToEulerAngles().pitch
    assert(math.abs(actual - expected) < 0.00001,
        ("%s: expected %.5f, got %.5f"):format(message, expected, actual))
end

local function expectPosition(expected, message)
    for _, axis in ipairs({ "x", "y", "z" }) do
        assert(math.abs(localPosition[axis] - expected[axis]) < 0.00001,
            message .. ": unexpected " .. axis .. " position")
    end
end

local function reset(pitch)
    CameraCore.Suspend("test reset")
    parentPitch = pitch or 0
    localPosition = Vector4.new(0, 0, 0, 1)
    localOrientation = pitchRotation(0)
    context.bodyWeaponBlocked = false
    context.bodyEligible = true
    context.hasWeapon = false
    update()
end

update()
for cycle = 1, 10 do
    armed(true)
    armed(false)
    -- The weapon profile updates translation while the ownership probe's
    -- rotation survives. The probe must never become the restored native pose.
    for frame = 1, 6 do
        localPosition = Vector4.new(0, cycle * 0.001 + frame * 0.002, 0, 1)
        update()
    end
    update(20)
    expectPitch(0, "upright holster cycle " .. cycle)
    expectPosition({ x = 0, y = cycle * 0.001 + 0.012, z = 0 }, "native translation retained")
end

-- The same partial overwrite can interrupt a visible body fade. Its position
-- must not become the next baseline when only rotation was replaced.
reset(-60)
armed(true)
armed(false)
update(5)
assert(CameraCore.GetDebugState().bodyPitch < 0, "test must interrupt a visible fade")
localOrientation = pitchRotation(0)
update(20)
parentPitch = 0
update()
expectPitch(0, "rotation overwrite must preserve the original orientation")
expectPosition({ x = 0, y = 0, z = 0 }, "rotation overwrite must not bake in body translation")

-- A complete native profile update still needs to replace both baseline fields.
reset()
armed(true)
armed(false)
localPosition = Vector4.new(0.01, 0.02, 0.03, 1)
localOrientation = pitchRotation(2)
update(20)
expectPitch(2, "native profile rotation adopted")
expectPosition({ x = 0.01, y = 0.02, z = 0.03 }, "native profile translation adopted")

-- Drawing again before ownership settles must restore the clean native pose.
reset()
armed(true)
armed(false)
localPosition = Vector4.new(0, 0.01, 0, 1)
update()
armed(true)
expectPitch(0, "interrupted holster must remove the probe")
expectPosition({ x = 0, y = 0.01, z = 0 }, "interrupted holster retains native translation")

-- Native quaternion round-trips can change length without changing rotation.
-- The raw dot in the live failure was about 0.99999975 for a retained write.
reset()
orientationReadbackScale = 0.99999975
for cycle = 1, 10 do
    armed(true)
    armed(false)
    update(20)
    assert(not CameraCore.GetDebugState().bodyTransitionActive,
        "quaternion length error must not stall the holster fade")
    expectPitch(0, "quaternion round-trip holster cycle " .. cycle)
end
reset(-60)
armed(true)
armed(false)
update(20)
assert(not CameraCore.GetDebugState().bodyTransitionActive,
    "quaternion length error must not restart a visible body fade")
parentPitch = 0
update()
expectPitch(0, "body fade must not accumulate rotation after a quaternion round-trip")
expectPosition({ x = 0, y = 0, z = 0 }, "body fade must not accumulate translation")
orientationReadbackScale = 1

print("Camera holster tests passed")

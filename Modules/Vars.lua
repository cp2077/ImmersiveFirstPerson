return {
    CONFIG_FILE_NAME = "config.json",
    CONFIG_VERSION = 3,

    BODY = {
        -- Native look-down angle where body-presence correction starts / reaches full strength.
        START_PITCH_DOWN = 30.0,
        FULL_PITCH_DOWN = 80.0,

        VERTICAL_OFFSET = -0.125,
        FORWARD_OFFSET = -0.100,
        PITCH_CORRECTION = -9.0,
        FOV_CORRECTION = -8.0,
        FOV_REFERENCE = 68.23,

        CROUCH_VERTICAL_MULTIPLIER = 1.35,
        CROUCH_FORWARD_MULTIPLIER = 1.17,
        CROUCH_PITCH_MULTIPLIER = 1.50,
        VERTICAL_RAMP_END = 0.80,
        FORWARD_CURVE_TURN = 0.37,
    },

    FREELOOK = {
        DEFAULT_SENSITIVITY = 20,
        MOUSE_DEGREES_PER_UNIT = 0.07,
        CONTROLLER_DEGREES_PER_SECOND = 120.0,
        CONTROLLER_DEADZONE = 0.12,
        EDGE_SOFT_START = 0.70,
        CONE_POWER = 4.0,
        LATERAL_START = 0.07,
        LATERAL_STOP_YAW_PROGRESS = 0.69,
        BODY_FADE_START_YAW_PROGRESS = 0.38,
        BODY_FADE_FULL_YAW_PROGRESS = 0.69,
        BACK_START_YAW_PROGRESS = 0.38,
        BACK_FULL_YAW_PROGRESS = 0.83,
        ROLL_START_YAW_PROGRESS = 0.41,
        REAR_PITCH_CLAMP_START_YAW_PROGRESS = 0.62,
        REAR_PITCH_FLOOR = -30.0,
        PITCH_FLOOR_SOFT_RANGE = 14.0,

        MAX_YAW = 145.0,
        MAX_PITCH_DOWN = 85.0,
        MAX_PITCH_UP = 85.0,
        -- Measured native FPP parent limits on Cyberpunk 2077 2.31.
        DEFAULT_PITCH_FLOOR = -80.0,
        DEFAULT_PITCH_CEILING = 80.0,
        COMBAT_MAX_YAW = 52.5,
        COMBAT_MAX_PITCH_DOWN = 30.0,
        COMBAT_MAX_PITCH_UP = 80.0,

        MAX_LATERAL_OFFSET = 0.230,
        MAX_BACK_OFFSET = 0.025,
        MAX_ROLL = 8.0,

        DEFAULT_RETURN_DURATION = 0.45,
        MIN_RETURN_DURATION = 0.08,
        MAX_RETURN_DURATION = 1.20,
    },

    -- This is a known camera parameter set used by the vanilla override event.
    -- All angle limits and sensitivity values are immediately overridden by the mod.
    CAMERA_OVERRIDE_PARAMS_NAME = "Tier3Scene",
}

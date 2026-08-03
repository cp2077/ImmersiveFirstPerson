# Native camera pitch curve

Captured on Cyberpunk 2077 2.31 from 841 stationary samples. Coordinates are V-local: `forward` and `vertical`, relative to neutral pitch. Lateral movement was idle noise.

For `u = clamp(pitch, -80, 80) / 80`:

- Down: `forward = -0.00429768u + 0.00763932u^2 - 0.17765878u^3`
- Down: `vertical = -0.01104677u - 0.01364154u^2`
- Up: `forward = -0.35655461u`
- Up: `vertical = 0.16416325(1 - exp(-pitch / 17.05)) + 0.0001897246pitch`

Worst fit error is about 0.0033 game units. The composer targets the FOV 100 reference position at the effective gaze, subtracts the native position expected at the active FOV and pitch, then inverse-rotates that difference into FPP-component local space. This preserves the native camera choreography without moving the weapon during freelook.

An FOV 70 sweep (620 samples) showed that downward native movement is FOV-dependent: full-down forward displacement is about `0.033`, versus `0.190` at FOV 100. A cubic fit for FOV 70 is interpolated continuously to the FOV 100 reference across the standard 70–100 range. The composer offsets the actual native position to the reference curve for both ordinary look and freelook; upward movement remains on the shared curve because the captures differed only by idle-scale noise.

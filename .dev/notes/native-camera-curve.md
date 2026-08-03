# Native camera pitch curve

Captured on Cyberpunk 2077 2.31 from 841 stationary samples. Coordinates are V-local: `forward` and `vertical`, relative to neutral pitch. Lateral movement was idle noise.

For `u = clamp(pitch, -80, 80) / 80`:

- Down: `forward = -0.00429768u + 0.00763932u^2 - 0.17765878u^3`
- Down: `vertical = -0.01104677u - 0.01364154u^2`
- Up: `forward = -0.35655461u`
- Up: `vertical = 0.16416325(1 - exp(-pitch / 17.05)) + 0.0001897246pitch`

Worst fit error is about 0.0033 game units. Freelook applies `curve(entry + freelook) - curve(entry)`, inverse-rotated through the frozen native pitch into FPP-component local space. This preserves zero displacement on activation and does not move the weapon.

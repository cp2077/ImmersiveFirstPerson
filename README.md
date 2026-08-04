# Immersive First Person

## Features

1. A pitch-aware first-person body view designed to avoid the neck opening and body clipping.
2. FreeLook for rotating V's view without rotating their body, with mouse and controller input.

Body correction runs while looking down during normal unarmed gameplay. It suspends in vehicles, swimming, takedowns, knockdowns, body carrying, and camera-controlled scenes. FreeLook can optionally remain available while a weapon is equipped.

FreeLook remains active only while its input is held and releases immediately on key-up. An optional return animation smoothly recenters the view.

If another system repeatedly writes the same first-person camera transform or FOV, the mod suspends its camera changes for the current gameplay session instead of competing. The CET Overlay reports the conflict and provides a manual retry button; starting a new session clears the suspension automatically.

## Installation

1. Install Cyber Engine Tweaks.
2. Extract the archive into the Cyberpunk 2077 directory containing the `bin` folder.

## Shortcuts

Bindings live in two CET Overlay sections:

1. **Hotkeys** → Toggle Enabled
2. **Inputs** → FreeLook

Camera and FreeLook options are available in the mod's CET Overlay window.

----

This project contains files that are parts of MIT licensed project [cp2077-cet-kit](https://github.com/psiberx/cp2077-cet-kit).  
See full license details [here](https://github.com/psiberx/cp2077-cet-kit/blob/main/LICENSE).  

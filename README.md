# Immersive First Person

## Features

1. A pitch-aware first-person body view designed to avoid the neck opening and body clipping.
2. FreeLook for rotating V's view without rotating their body, with mouse and controller input.
3. Optional runtime-adjustable physical height for V, plus an independent NPC head-look target fix.

Body correction runs while looking down during ordinary gameplay and yields to vehicles, workspots, traversal, takedowns, knockdowns, body carrying, and camera-controlled scenes. FreeLook can optionally remain available while a weapon is equipped.

The optional height file replaces `player_base.animgraph` with a versioned two-branch blend. One branch is vanilla; the other raises V's COG and lengthens both thigh and shin segments while the Root-space foot targets remain grounded. CET drives the blend over 100 ms, so the setting can change at runtime without moving `gameFPPCameraComponent`, changing camera pitch, or restarting the game.

Height remains active during ordinary roaming, combat, ADS, scanner use, dialogue, and swimming. It smoothly returns to vanilla for any vehicle occupancy, workspots, scripted scenes, ladders/climbing/vaulting, takedowns/grapples, body carrying, knockdowns, and other forced-contact states. Values above +8 cm are deliberately marked experimental because knees and authored contacts can become visibly distorted.

The main file verifies the exact loaded animgraph contract. If the optional archive is absent, incompatible, or overridden by another mod, the height slider is unavailable and the rest of Immersive First Person continues normally.

## Installation

1. Install Cyber Engine Tweaks, RED4ext, and redscript.
2. Install **Immersive First Person** into the Cyberpunk 2077 directory containing the `bin` folder.
3. Optionally install **Immersive First Person - Optional Height** into the same directory.

The optional file replaces `base\gameplay\anim_graphs\player_base.animgraph`, so another mod replacing that resource may take priority. Runtime detection handles this safely, but the two graph changes are not merged automatically.

## Configuration

Bindings live in two CET Overlay sections:

1. **Hotkeys** -> Toggle Enabled
2. **Inputs** -> FreeLook

The CET Overlay exposes camera and FreeLook settings, a `+0 cm` to `+30 cm` height slider when the compatible optional graph is loaded, and a **Debug logging** toggle. Generic NPC gaze correction is automatic while the mod is enabled. Start around +5 to +8 cm.

----

This project contains files that are parts of MIT licensed project [cp2077-cet-kit](https://github.com/psiberx/cp2077-cet-kit).  
See full license details [here](https://github.com/psiberx/cp2077-cet-kit/blob/main/LICENSE).  

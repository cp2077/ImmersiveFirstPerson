# Native height

The height archive replaces one file:

```text
base\gameplay\anim_graphs\player_base.animgraph
```

The vanilla file is in `archive\pc\content\basegame_1_engine.archive`.

The solution changes the pose immediately before the graph copies `Torso_Hips_Driver_GRP` to `Hips`. Each signed 50 cm endpoint adds five `TranslateBone` nodes:

```text
                            -50 cm      +50 cm
LeftLeg                    X -0.25 m    X +0.25 m
LeftFoot                   X -0.25 m    X +0.25 m
RightLeg                   X +0.25 m    X -0.25 m
RightFoot                  X +0.25 m    X -0.25 m
Torso_COG_Control_JNT      Z -0.50 m    Z +0.50 m
```

The leg axes are mirrored, hence the opposite signs. Each thigh and shin changes by half the endpoint amount. The COG moves the hips and everything above them by the full amount. So the body and camera move, but the feet stay on the ground.

The graph blends between the -50 cm and +50 cm poses. CET writes a value from `0.0` to `1.0` to `ifp_height_blend`; `0.5` is the vanilla pose and is used whenever height is disabled or suppressed.

The graph also has `ifp_height_contract_v2_signed_50cm`. The native plugin checks for it. If another mod replaces `player_base.animgraph`, the check fails and the height slider becomes unavailable instead of silently doing nothing.

## Rebuilding the archive

This was built with WolvenKit CLI 8.18.0 and Cyberpunk 2077 2.31:

```powershell
scripts\build-height-archive.ps1 -GameRoot C:\path\to\Cyberpunk2077 -WolvenKit C:\path\to\WolvenKit.CLI.exe
```

Output:

```text
build\height\ImmersiveFirstPersonHeight.archive
```

Add `-UpdateTrackedArchive` if the copy in `optional\ImmersiveFirstPersonHeight.archive` should be replaced too.

The script does the whole process from the original game archive. It extracts the graph, checks its hash, patches it, cooks it, packs the archive, then checks the cooked result. The extracted graph and its huge JSON file are temporary. Do not add them to the repo.

Known 2.31 files:

```text
Vanilla graph       373,435 bytes
SHA-256             DFF7C3BDEF154B9F9CCF87BDCA0FAF3EAC4565E4428714FB52D46F4C4F7D0EB3

Modified graph      376,586 bytes
SHA-256             05A0FF0C0B7D04B18BC20BF3BA69A532BB284BC00FEAC2689D3B2AABBBA795B7
```

The hash of the outer archive changes between WolvenKit builds for some reason. The graph inside it is stable, so that is what the builder checks.

## What we tried

These are the tests that gave us a useful answer. There were more small probes, but they are not worth keeping here.

### `gameHumanoidBody.baseHeight`

The native plugin changed it from 1.80 m to 2.10 m. Nothing visible changed. Apparently it does not control the live player camera or pose.

### Runtime camera and target slot offsets

This worked at runtime. The camera and target slots moved, but the body stayed at the old height. Useful fallback, but not actual height.

### NPC look-at

The height graph does not fix generic NPC look-at on its own. The separate REDscript hook changes player-targeted `Chest` requests to `Head`. It worked, and it does not depend on the height archive.

### COG before the Hips constraint

This moved the body and camera together, which was the first real success. Unfortunately it lifted the feet too. The 30 cm test made that very obvious.

### `chestSpineStretchFactor`

No useful camera height change. The camera branch does not inherit the part of the chest chain changed by this value.

### Chest translation before Spine3

Also no useful camera height change. Later parts of the graph seem to resolve the camera branch separately.

### COG at the final pose

The camera moved, but the visible body and weapons stayed below it. At 30 cm there was a very clear neck seam. Basically a more native version of moving the camera alone.

### COG plus longer legs

This is the solution we kept. The body and camera moved and the feet stayed grounded. At 30 cm the knees looked wrong and vehicle framing was completely broken, but that test proved the full chain worked. Normal values are much less noticeable. Vehicle hand IK followed the wheel too, although there was a brief mismatch while leaving the vehicle.

### Runtime blend

Writing `ifp_height_blend` from CET changed the full pose immediately. No reload needed. This lets the mod smoothly remove height for vehicles, scenes, workspots and other animations that expect V to have normal proportions.

## Main limitation

The archive replaces `player_base.animgraph`. Any other mod replacing the same resource will conflict with it. The runtime contract check makes this fail safely, but obviously it cannot merge two different versions of the graph.

# Other scripts

The scripts take explicit tool and game paths. Keep local paths in the ignored `AGENTS.md` file.

```powershell
scripts\build-native.ps1 -CMake C:\path\to\cmake.exe -Red4extSdkPath C:\path\to\RED4ext.SDK
scripts\check.ps1 -GameRoot C:\path\to\Cyberpunk2077 -CMake C:\path\to\cmake.exe -Red4extSdkPath C:\path\to\RED4ext.SDK
scripts\deploy.ps1 -GameRoot C:\path\to\Cyberpunk2077 -CMake C:\path\to\cmake.exe -Red4extSdkPath C:\path\to\RED4ext.SDK
```

`check.ps1` checks Lua, REDscript and the native plugin. It runs the runtime height test too.

`deploy.ps1 -DryRun` only shows what would be copied. `-LuaOnly` only updates the CET part. Close the game before a full deploy.

Release build:

```bash
MOD_VERSION=2.0.0 NATIVE_DLL=build/native/Release/ImmersiveFirstPerson.dll bash scripts/bundle.sh
```

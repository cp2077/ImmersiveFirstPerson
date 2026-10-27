# Immersive First Person

Immersive First Person adds a first-person body view, FreeLook, and adjustable height for V in Cyberpunk 2077.

Body correction applies while looking down with empty hands. FreeLook also works with a weapon equipped. Both yield to vehicles, workspots, scripted cameras, and forced animations. Height stays active during combat, ADS, scanner use, dialogue, and swimming; it returns to normal for vehicles, workspots, traversal, takedowns, body carrying, knockdowns, and camera-controlled scenes. FOV stays unchanged.

## Install

Supports **Cyberpunk 2077 2.5**. After an unsupported game update, remove `archive\pc\mod\ImmersiveFirstPersonHeight.archive` or its ITP compatibility replacement until a compatible mod build is available.

1. Install Cyber Engine Tweaks, RED4ext, and redscript.
2. Install **Immersive First Person** into the Cyberpunk 2077 directory containing the `bin` folder.

Mods replacing `player_base.animgraph` conflict with height support. IFP disables height adjustment if compatibility checks fail; the other features remain available.

For Immersive Third Person, also extract **Immersive First Person - ITP Compatibility.zip** into the game directory and remove `archive\pc\mod\ImmersiveFirstPersonHeight.archive`. Keep the compatibility archive's `0_` filename prefix. Repeat this after updating the main package. The compatibility package requires ITP.

## Use

In CET's **Bindings** tab, bind **FreeLook** under **Inputs** and **Toggle Enabled** under **Hotkeys**.

Height adjustment changes leg proportions rather than scaling the whole body. Extreme settings can cause clipping and animation distortion.

## API

CET mods access the API through `GetMod("ImmersiveFirstPerson").api`:

```lua
local ifp = GetMod("ImmersiveFirstPerson")
if ifp and ifp.api and ifp.api.SetHeightOffset then
    local ok, reason = ifp.api.SetHeightOffset("MyMod", 5.5)
end
```

- `Disable(modName)` suspends the whole mod for that caller. `Enable(modName)` releases only that caller's suspension. Names are optional for legacy callers, which share one unnamed suspension; provide a stable name to keep callers separate. Neither call changes the user's Enabled switch. Both return `true` or `false, reason` for an invalid name. Suspensions clear on session end or CET reload.
- `IsEnabled()` reports whether the user's switch is on and no mod is suspending IFP. The CET overlay lists blocking mods.
- `GetCameraState()` returns camera mode, ownership, and body/FreeLook diagnostics. Fields are defined in [CameraCore.lua](Modules/CameraCore.lua).
- `StartNativeCameraCapture()` suspends camera corrections and starts diagnostic transform sampling. Close CET and sweep the view up-down-up while stationary. The [sampler](Modules/NativeCameraSampler.lua) writes its samples automatically when complete.
- `CancelNativeCameraCapture()` stops sampling and discards the active capture.
- `SetHeightOffset(modName, centimeters)` replaces that name's contribution. Offsets add to the user's height within their allowed range; zero removes one. Changes blend like the height slider.
- `SetHeightEnabled(modName, false)` suspends height adjustment. Passing `true` releases only that name's suspension; the user's switch and other suspensions still apply.
- `GetHeightState()` returns `available`, `pending`, `enabled`, `targetCentimeters`, `effectiveCentimeters`, `suppressedBy`, and `contributions` (`modName`, `centimeters`).

Height setters return `true` or `false, reason`. Requests require height support and the user's permission; they cannot enable GigaV or overwrite saved height. Clearing offsets and releasing suspensions remain allowed without permission or support. Requests need no refresh calls and clear on session end, CET reload, or permission revocation.

## Build

Requires Visual Studio C++ tools, RED4ext.SDK at the [release workflow's pinned revision](.github/workflows/publish-nexus.yml), and CMake, LuaJIT, and Lua Language Server on PATH. To validate, build, and deploy with the game closed:

```powershell
$gameRoot = 'C:\path\to\Cyberpunk 2077'
$sdkRoot = 'C:\path\to\RED4ext.SDK'
$cmake = (Get-Command cmake.exe).Source
scripts\deploy.ps1 -GameRoot $gameRoot -CMake $cmake -Red4extSdkPath $sdkRoot
```

[Archive generation](scripts/build-height-archive.ps1) requires WolvenKit CLI. [Packaging](scripts/bundle.sh) runs in Git Bash.

----

This project contains files that are parts of MIT licensed project [cp2077-cet-kit](https://github.com/psiberx/cp2077-cet-kit).  
See full license details [here](https://github.com/psiberx/cp2077-cet-kit/blob/main/LICENSE).  

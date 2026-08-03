# Immersive First Person development setup

This directory contains development-only notes, type shims, and verification tools. The distributable CET mod remains `init.lua` plus `Modules/`.

## Verified local baseline (2026-08-03)

- Cyberpunk 2077: patch 2.31 (`3.0.80.51928` in the CET log)
- Cyber Engine Tweaks: 1.37.1
- CET JIT setting: enabled
- LuaJIT: 2.1.1782381659, native Windows x64
- Lua Language Server: 3.18.2
- Vortex staging and deployed `ImmersiveFirstPerson` Lua files had matching SHA-256 hashes.
- CET loaded `ImmersiveFirstPerson` successfully during the baseline launch.

Installed user tools:

- `C:\Users\bn\AppData\Local\Programs\LuaJIT\luajit.exe`
- `C:\Users\bn\AppData\Local\Programs\LuaLS\bin\lua-language-server.exe`

Both directories were added to the user `PATH`. A newly opened terminal/editor will inherit the updated path.

Install provenance:

- MSYS2 LuaJIT package SHA-256: `25F0AC55AC86FA93B481288FC77E5DE1287563D26127CEE53788C4C86D79A280`
- LuaLS 3.18.2 Windows x64 ZIP SHA-256: `A4439A8F5E8E9E6505C11F045A7BF45DB602124A1E246371C1DBE34924F3CF71`

## Validation

From this repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\.dev\check.ps1
```

The default check does not modify or require a deployed game copy. To additionally compare every source Lua file with the installed Steam/CET mod:

```powershell
powershell -ExecutionPolicy Bypass -File .\.dev\check.ps1 -LiveModRoot "C:\Program Files (x86)\Steam\steamapps\common\Cyberpunk 2077\bin\x64\plugins\cyber_engine_tweaks\mods\ImmersiveFirstPerson"
```

Use `-Strict` to include all LuaLS warnings while modernizing annotations and nil handling:

```powershell
powershell -ExecutionPolicy Bypass -File .\.dev\check.ps1 -Strict
```

The check has two layers:

1. LuaJIT compiles every mod `.lua` file without executing it. This catches syntax errors using LuaJIT/Lua 5.1 syntax, including CET-compatible literals such as `1ULL`.
2. LuaLS checks the workspace using `.dev/.luarc.json` and the CET declarations in `.dev/types/`. The default gate fails on errors; strict mode also fails on warnings.
3. When `-LiveModRoot` is supplied, SHA-256 hashes confirm that the repository source and installed mod match.

Neither local layer can emulate Cyberpunk RTTI, `Game.*`, observers, native objects, input, or camera behavior. CET reload plus the game and mod logs remain the integration test.

At setup time the normal gate was clean. Strict mode reported 31 warnings, primarily legacy nil-flow uncertainty and variables that intentionally change between table/string or number/nil forms. Treat that as modernization debt; do not silence it globally because several warnings identify real transition guards worth reviewing.

## Live-test loop

1. Edit this source checkout.
2. Run `.dev/check.ps1`.
3. Copy the changed runtime files (`init.lua` and/or `Modules/*.lua`) into the Vortex staging mod and deploy them.
4. Re-run `.dev/check.ps1 -LiveModRoot <installed-mod-path>` to confirm hashes match.
5. Use **Reload All Mods** in the CET overlay.
6. Inspect:
   - `bin\x64\plugins\cyber_engine_tweaks\mods\ImmersiveFirstPerson\ImmersiveFirstPerson.log`
   - `bin\x64\plugins\cyber_engine_tweaks\scripting.log`
   - `bin\x64\plugins\cyber_engine_tweaks\cyber_engine_tweaks.log`
7. Reproduce the exact camera/input transition and record expected versus actual behavior.

## Type/reference strategy

- LuaLS supplies the standard LuaJIT library types.
- `.dev/types/cet.lua` describes the small CET surface used by this mod. Expand it only when a concrete API is needed.
- Use the local NativeDB dump for exhaustive RTTI class, property, inheritance, and function searches. Use the [NativeDB website](https://nativedb.red4ext.com/) when its rendered type/signature view is more convenient.
- Use CET `Dump(instance, detailed)`, `DumpType(typeName, detailed)`, and `GameDump(instance)` for runtime confirmation against the installed game.
- Use the local [decompiled game scripts](https://codeberg.org/adamsmasher/cyberpunk) to understand how the game composes native calls. They are reference material, not Lua declarations.

The large references are installed outside this Vortex staging mod so they cannot leak into a release archive:

- NativeDB raw RTTI JSON: `C:\Users\bn\AppData\Local\Cyberpunk2077Modding\references\nativedb`
- Decompiled 2.31 scripts: `C:\Users\bn\AppData\Local\Cyberpunk2077Modding\references\decompiled-scripts`
- Exact snapshot provenance: `.dev/reference-lock.json`

Search both references from the mod root:

```powershell
powershell -ExecutionPolicy Bypass -File .\.dev\find-reference.ps1 -Pattern 'GetFPPCameraComponent'
```

Use `-Source NativeDB` or `-Source Scripts` to restrict the search. NativeDB results name the top-level RTTI entry containing the text; script results include file and line. The NativeDB JSON is intentionally kept in its official compact form, so the website remains the easiest way to read a complete signature after local search identifies its owner.

## Sources

- [CET mod structure](https://wiki.redmodding.org/cyber-engine-tweaks/first-steps/mod-structure)
- [CET events and `onInit`](https://wiki.redmodding.org/cyber-engine-tweaks/cet-functions/events/oninit)
- [CET upgrade guide](https://wiki.redmodding.org/cyber-engine-tweaks/upgrade-guide)
- [CET debug functions](https://wiki.redmodding.org/cyber-engine-tweaks/cet-functions/misc/debug-functions)
- [CET good practices](https://wiki.redmodding.org/cyber-engine-tweaks/first-steps/good-practices)
- [CET VS Code/LuaLS setup](https://wiki.redmodding.org/cyber-engine-tweaks/resources/vs-code)
- [NativeDB](https://nativedb.red4ext.com/)
- [LuaJIT status](https://luajit.org/status.html)
- [MSYS2 LuaJIT package](https://packages.msys2.org/packages/mingw-w64-ucrt-x86_64-luajit)
- [Lua Language Server](https://github.com/LuaLS/lua-language-server)

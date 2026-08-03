# CET-focused working practices

## Runtime boundaries

- CET 1.37.1 is built around OpenResty LuaJIT with GC64, so target LuaJIT/Lua 5.1 semantics rather than modern PUC Lua.
- Do not touch `Game`, game types, or other mods before CET's `onInit` event.
- Register observers and overrides from `onInit`. Current observer callbacks receive `self` first, followed by the function arguments.
- Treat `Reload All Mods` as a full mod lifecycle. Initialization must be idempotent and `onShutdown` must release temporary state.
- Do not retain player/native handles across session end or reload. Fetch short-lived handles when needed and guard every transition where the player or component may disappear.

## Hot paths and state

- Keep `onUpdate`, `onDraw`, and input callbacks small. Cache pure Lua constants and avoid repeated string construction in hot paths.
- Prefer early returns for invalid states. A camera mod crosses many transient states: menus, loading, death, takedowns, vehicles, swimming, workspots, and missing components.
- Separate state discovery, eligibility decisions, and camera mutation. That makes transition bugs reproducible and prevents partial resets.
- Make reset operations safe to call repeatedly. Reloads and overlapping state transitions will invoke cleanup more often than the happy path suggests.
- Keep configuration migrations explicit and versioned. Validate decoded JSON before replacing the in-memory defaults.

## Observability

- Use `spdlog.info/error(tostring(value))` for durable per-mod diagnostics; use `print` for short CET-console experiments.
- Log transitions rather than every frame: session start/end, eligibility reason changes, free-look enter/exit, reset causes, and API enable/disable.
- When debugging RTTI, copy exact signatures from NativeDB and verify uncertain types with `DumpType` or `Dump` in the installed runtime.
- Record game version, CET version, mod version, reproduction steps, and the relevant log excerpt for every bug.

## Reference precedence

- NativeDB is the broad RTTI inventory. Search it first to establish that a class, property, function, enum, or global exists and to inspect native signatures.
- Decompiled scripts show implementation and call-site patterns, but only for code that was recoverable as scripts; absence there does not mean an RTTI member does not exist.
- The running Cyberpunk/CET instance is the final authority. Use `DumpType`/`Dump` when a published dump, decompiled call site, and observed behavior disagree, or when another framework may add runtime types.
- Do not add the 10 MB NativeDB dump or the decompiled source tree to the Vortex mod payload. Their independently versioned local installations are pinned in `.dev/reference-lock.json`.

## Packaging and version control

- Keep distributable files under the expected `bin/x64/plugins/cyber_engine_tweaks/mods/ImmersiveFirstPerson` tree.
- Keep development tools and large references out of the release archive.
- The canonical source checkout is separate from Vortex staging. Commit a clean source baseline before broad refactors, and treat Vortex as a deployment/test target rather than the only copy.
- Test the exact archive users receive, preferably against a minimal mod profile as well as the author's full load order.

## Limits of local verification

LuaJIT compilation proves syntax compatibility only. LuaLS adds useful static checking but cannot prove RTTI names or native call signatures without declarations. Only the installed CET/game runtime can validate observers, native state, timing, and visual camera behavior.

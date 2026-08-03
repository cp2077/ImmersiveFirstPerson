# Camera ownership and transition audit

Research target: Cyberpunk 2077 2.31 decompiled scripts/NativeDB, CET 1.37.x, and the current 2.0 camera core. This is a risk map, not a claim that every listed state is currently broken.

## The engine's actual camera priority

`DefaultTransition.UpdateCameraParams()` selects the first matching profile in this order:

1. Tier 4 FPP cinematic
2. Tier 3 limited-gameplay scene (with per-scene pitch/yaw/sensitivity overrides)
3. Vehicle
4. Felled
5. Consumable use
6. Ladder
7. Takedown, except the grapple hold
8. Body carry/pickup variants
9. Tier 2 space-shuttle interior
10. Locomotion

Therefore `SceneTier <= 2`, no mounted vehicle, and empty hands do **not** prove that the ordinary player camera owns the component. The mod currently writes the local transform/FOV through several higher-priority profiles.

## Recommended policy vocabulary

- **Compose**: normal player FPP owns the component; body, freelook, or height may run.
- **Transfer**: the same FPP component remains visible, but a feature must leave. Preserve the visible view while moving the experimental height bias out of native pitch.
- **Freeze**: stop input/state integration briefly but retain the visible transform (ordinary pause/blur).
- **Yield**: another camera/profile owns the view. Abort freelook, restore our properties, discard the stale baseline, and do not write.
- **Reacquire**: wait for a stable eligible context, then capture a fresh baseline. Never restore a baseline captured before an external camera or profile change.

Exit should be immediate. Only re-entry should be debounced (two stable frames or roughly 100 ms is sufficient to close most one-frame gaps).

## Conflict matrix

| Context | Reliable signals | Body correction | Freelook | Height | Main risk |
|---|---|---:|---:|---:|---|
| Stand/walk/crouch/sprint | Tier 1, ordinary locomotion | Compose | Compose | Compose | Baseline case |
| Jump/double jump/fall/ordinary land | detailed locomotion 14-28 | Compose/rebase | Usually compose | Compose | Locomotion profiles may change on entry |
| Climb/vault | detailed 8-9 | Compose/rebase | Abort during authored move | Compose | Sudden parent motion while input is locked |
| Ladder enter/use/reset/exit | detailed 10-13 plus `LadderCameraParams` | Yield | Yield | Yield | Four native profiles change pitch limits and may recenter |
| Slide/dodge/air dodge | detailed 5-7/22 | Compose/rebase | Compose, abort on forced motion | Compose | State-specific FOV/bob/limits |
| Hard landing/knockdown | landing plus detailed 24-29 | Blend/yield | Abort | Transfer if stable, otherwise yield | Current helper misses generic detailed knockdown |
| Felled | detailed 31 / `FelledCameraParams` | Yield | Yield | Yield | Explicit profile outranks locomotion |
| Swimming/surface/dive/swim climb | HighLevel 6 or Swimming | Yield | Yield | Yield | Pitch drives dive behavior; transitions briefly clear low-level state |
| Cover | `UsingCover` | Compose with caution | Allow only if clearance is acceptable | Compose | Shoulder translation can clip nearby cover |
| Ranged/melee weapon draw, switch, reload, holster | Weapon, UpperBody, Melee, slot state | Existing blend | Armed cone only | Transfer out/in | Slot disappears during weapon-owned frames |
| Consumable/inhaler/injector | Consumable state / active left-hand item | Blend/yield | Abort | Transfer | `UseConsumable` is an explicit high-priority profile |
| Grenade/projectile launcher/left cyberware | CombatGadget, LeftHandCyberware, UpperBody | Usually blend | Abort while animating/charging | Transfer while arms own camera | Empty right-hand slot is not truly unarmed |
| Body pickup/carry/drop; heavy carried object | BodyCarrying, Carrying, carry context, `NoCameraControl` | Yield | Yield | Transfer/yield | Explicit carry profiles and camera-control restriction |
| Takedown: enter, grapple, leap/aerial, execution | Takedown 1-4, workspot info | Yield at authored phase | Abort immediately | Existing held-view transfer, then yield | Leap/aerial is covered; grapple is the only profile exception |
| Melee/workspot finisher | `GetIsInWorkspotFinisher`, FinisherTarget/workspot tags | Yield | Yield | Yield | Direct `WorkspotLocked`, `cameraFinishers`, and scripted LookAt |
| Generic workspot/synced animation | `IsInWorkspot`, extended info, tags | Yield unless explicitly whitelisted | Yield | Yield unless traversal whitelist | Workspot forces detailed locomotion back to Stand, hiding its identity |
| Door force/open, inspection, arcade/access-point minigame | force/interact flags, inspection API, `IsInMinigame` | Yield | Yield | Yield | Can remain Tier 1 with empty hands and an inactive/animated FPP camera |
| Tier 2 staged dialogue/gameplay | SceneTier 2 | Optional body-only policy | Off by default | Transfer out | Player control exists, but scene direction may still own framing |
| Tier 3/4/5 scenes and cinematics | SceneTier 3-5 | Yield | Yield | Yield | Explicit scene profiles or an external camera |
| Braindance | Braindance system/controls state | Yield | Yield | Yield/reset offscreen | Braindance resets player FPP pitch and blends to a separate camera |
| Vehicle enter/drive/combat/passenger/exit | Vehicle != 0, mounted flag/link, workspot info | Yield | Yield | Yield | Workspot and mount-link signals do not become valid on the same frame |
| Remote vehicle control | remote vehicle entity ID / remote TPP flag | Yield | Yield | Yield | Player is physically on foot while another camera is authoritative |
| Device takeover/security camera/UI zoom | controlling-device/camera/UI-zoom flags | Yield | Yield | Yield | Player FPP may stay present but inactive, so writes corrupt the return pose |
| Focus/scanner/zoom | Vision, ZoomLevel, UI zoom | Rebase or avoid FOV ownership | Usually abort | Avoid fixed FOV ownership | Current composer can overwrite dynamic FOV every frame |
| Sandevistan/Kerenzikov/Berserk/time dilation | TimeDilation, Berserk, ActiveCyberware | Compose | Compose unless another action owns the camera | Compose | Verify whether return/transfer timing should use real or dilated delta |
| Recoil, explosions, scripted shakes/LookAt | transform drift with otherwise stable PSM state | Compose additively | Policy decision: preserve or intentionally suppress | Compose if profile is stable | Freelook's parent-drift cancellation also cancels legitimate camera motion |
| Hit stagger/reaction | Reaction, detailed knockdown, status effects | Compose for light hit; yield for forced state | Abort | Preserve only if player FPP remains stable | Scripted impulses/LookAt can be cancelled by freelook compensation |
| Death/resurrection | Vitals 1/2, player death | Yield | Yield | Yield/reset | resurrection callback occurs before authored recovery is necessarily done |
| Fast travel/teleport/load | fast-travel request/loading/session events | Yield and discard baseline | Yield | Reset/yield | Fast travel directly calls player FPP `ResetPitch()` |
| Quest teleport, player/replacer swap (including Johnny) | player/FPP identity, replacer state | Yield/reacquire | Yield | Yield/reacquire | Tier can remain ordinary while the controlled puppet/component changes |
| Escape menu | menu pause only | Freeze | Clear input/freeze | Freeze | Releasing immediately caused the known one-frame body flash |
| Photo mode/tutorial/long pause | explicit photo/tutorial state | Yield | Yield | Yield | These should not share Escape's retain-baseline behavior |
| Phone/radial/radio/message blur | GameSession Blur | Freeze | Abort/clear input | Freeze | Blur is tracked by GameSession but the mod does not subscribe to it |
| CET reload/session end/player replacement | lifecycle/player identity | Yield | Yield | Yield | Native handles and baselines are invalid across player/component changes |
| Another camera mod | transform/profile fingerprint | Automatic yield | Automatic yield | Automatic yield | Current detector only logs repeated writes and continues fighting |

## Concrete gaps in the current implementation

1. `commonCameraContextAllowed()` only checks scene tier, mounted workspot, swimming, takedown, body carry, and a partial knockdown test. It misses explicit camera owners above.
2. `IsInVehicle()` requires an active workspot **and** a mounted vehicle link. Vehicle entry/exit and remote-control windows can fall between those signals.
3. `IsKnockedDown()` misses detailed locomotion Knockdown (29) and Felled (31) unless a landing value or vehicle/bike status happens to match.
4. Body correction remains active on ladders, consumables, generic workspots, inspection/minigames, and device control.
5. Freelook compensates native-parent drift by design. During a scripted LookAt or authored camera motion, that correct mechanism becomes a conflict and cancels the game's movement.
6. Height owns one baseline continuously while enabled, including where its visible correction is zero. That extends FOV/local-transform ownership into zoom and transient profiles.
7. `GameSession` distinguishes Pause and Blur, but the mod only handles Pause. Pause also groups Escape, photo mode, tutorials, and fast travel even though they require different cleanup.
8. `DeathDecisionsWithResurrection.ToResurrect` marks the camera session active too early; `Vitals == Alive` plus stable context is safer.
9. The competing-writer detector warns but never relinquishes ownership.

## Implementation direction

Build one read-only `CameraContextSnapshot` per frame, then derive separate decisions for body, freelook, and height. Suggested snapshot fields:

`sceneTier`, `highLevel`, `vitals`, `detailedLocomotion`, `landing`, `reaction`, `vehicle`, mounted/link/workspot extended flags, remote vehicle ID, `ladderCameraParams`, `takedown`, finisher, body/carry states, `consumable`, gadget/cyberware/melee/upper-body/weapon states, device/camera/UI-zoom control, minigame, inspection, braindance, vision/zoom, no-camera-control restriction, pause/blur/photo/fast-travel, player identity, and FPP identity/profile fingerprint.

Derive an ownership class before applying feature rules:

1. session unavailable / player or FPP changed
2. external camera (vehicle, device, braindance, photo, cinematic)
3. scripted player FPP (workspot, finisher, takedown, ladder, felled, consumable)
4. transient player FPP (weapon, hard landing, Tier 2, zoom/profile transition)
5. stable player FPP

The result should carry a reason and independent actions such as `body=compose`, `free=abort`, `height=transfer`. This is safer than growing one shared eligibility boolean.

Track a camera-profile fingerprint while the mod owns the component: component identity, `pitchMin`, `pitchMax`, yaw limits, sensitivity multipliers, and native FOV. If it changes unexpectedly, abort freelook and rebase or yield; never later restore the pre-change values. A repeated unexplained local-transform write should similarly force a temporary yield rather than only produce a warning.

## Focused live test sweep

Test every entry and exit while looking center, fully up, and fully down; repeat with height off/on at 5 and 30 and with freelook held where allowed.

1. Sprint, slide, dodge, all jumps, vault, climb, ladder, long fall, hard landing, knockdown, felled.
2. Surface swim, dive, ascend, leave water.
3. Draw/holster, switch, reload, melee, grenade, projectile launcher, healing item, optical camo/arm cyberware.
4. Rear/front/aerial takedown, melee finisher, body pickup/carry/drop.
5. Cover, force door, generic interaction/workspot, access-point/minigame, inspection.
6. Tier 2 dialogue, Tier 3 scene, Tier 4 cinematic, braindance.
7. Vehicle enter/exit from every seat, passenger/combat, remote vehicle, security camera/device takeover.
8. Scanner/focus/zoom at several FOVs.
9. Escape, radial wheel, phone, photo mode, tutorial popup, fast travel, death/reload/resurrection.
10. CET reload and one known competing camera mod.

Log only transitions: timestamp, ownership class/reason, relevant state values, FPP identity, profile fingerprint, baseline capture/release, and height transfer start/end. This will make one-frame gaps visible without returning to per-frame log spam.

## Primary references

- `cyberpunk/player/psm/defaultTransition.swift`: camera-profile priority and Tier 3 overrides.
- `cyberpunk/player/psm/locomotionTransitions.swift`: ladder, workspot, knockdown, and felled transitions.
- `cyberpunk/player/player.swift`: finisher workspot camera context.
- `cyberpunk/player/psm/braindanceControlsTransitions.swift`: direct FPP pitch reset.
- `cyberpunk/player/psm/zoomTransitions.swift`: device control and focus/zoom ownership.
- NativeDB `PlayerStateMachineDef`: the blackboard fields listed above.
- CET docs: `onUpdate`, observer ordering, and lifecycle guidance.

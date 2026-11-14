# Repository Instructions

This repository stores the Black Myth Wukong LiveSplit auto splitter and its
comment-free runtime distribution.

## Runtime contract

- Editable ASL and settings XML live under `Source/Runtime`.
- Repository `Components`, repository-root ASL/XML mirrors, release
  archives, and the local LiveSplit `Components` directory are generated
  outputs and must contain no comments.
- `Components/uhara10-PBZ` is the required binary runtime dependency.
- `Components/asl-help` is retained as a legacy runtime dependency and is
  still synchronized for compatibility.
- Do not edit generated runtime ASL or XML under `Components`; regenerate
  them from `Source/Runtime`.
- Preserve user-selected `State="true"` / `State="false"` values in
  `BMWukong.Settings.xml` unless the requested change explicitly covers them.

## Source map

- `Source/Runtime/BlackMythWukong.asl`: editable UGuid actor/hook-based auto
  splitter source.
- `Source/Runtime/BMWukong.Settings.xml`: editable Simplified Chinese Boss
  split settings.
- `Source/Runtime/BMWukong.Settings.en.xml`: editable English Boss split
  settings.
- `Source/build_wukong_runtime.ps1`: comment stripping, generation, and
  LiveSplit synchronization.
- `Source/test_wukong_runtime.ps1`: comment/XML checks and LiveSplit ASL parse
  verification.
- `Source/comment_tools.ps1`: shared comment removal and verification helpers.
- `Source/AslParseProbe.cs`: loads LiveSplit's ASL parser for tests.
- `Components/*.asl` and `Components/*.xml`: generated runtime files. Do not
  edit them directly. `Components/asl-help` is the fixed binary dependency.
- Root `BlackMythWukong.asl`, `BMWukong.Settings.xml`, and
  `BMWukong.Settings.en.xml`: generated mirrors that must match `Components`.
- `TECHNICAL_NOTES.md`: maintenance notes for the UGuid, montage, slow-motion,
  Despawn, and Dual signal model.

## Runtime synchronization

Run from the repository root after editing `Source/Runtime`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\build_wukong_runtime.ps1 -SyncLiveSplit
```

The command regenerates comment-free files in `Components` and the repository
root, then synchronizes
`BlackMythWukong.asl`, both settings XML files, `uhara10-PBZ`, and legacy
`asl-help` to
`D:\soft\e-game\LiveSplit_1.8.37\Components`.

Before overwriting a local runtime file, the script compares SHA-256 and
`LastWriteTime`. A newer differing local file must be inspected and merged back
into `Source/Runtime` first. After copying, SHA-256 equality is verified.

## Verification

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\test_wukong_runtime.ps1
```

The test must report `ASL_PARSE_OK` and `WUKONG_RUNTIME_TEST_OK`.

## Behavior notes

- The splitter observes all `UGuid___*` actors for appearance/despawn logs but
  performs split logic only for configured Boss settings through `uhara10-PBZ`.
- Split signals are death montage and global boss-kill slow motion.
  Boss-kill slow motion requires `0.001 < timeDilation < 0.16`; this excludes
  perfect dodge, See-Through, and Thrust attacks. It is ignored when more than
  one enabled Boss Actor is present.
- `Dead_UGuid.*` settings use the normal split signals. `Montage_UGuid.*`
  only accepts death-montage. `Despawn_UGuid.*` only splits when the Actor
  disappears, for bosses whose health bar hides mid-fight before the real kill.
- `Dual_UGuid.A+UGuid.B` requires death-montage edges from both Actors before
  queueing. Dual settings ignore slow-motion signals; the list is parsed once
  during init. Actor `bHidden` is not observed for split logic.
- Each chapter wraps Main Bosses, All Yaoguai Kings, and Yaoguai Chiefs. The
  user-maintained Main Boss list is preserved; remaining entries follow the
  ArtBook CardDesc `UnitType` classification (`0` = king, `2` = chief).
  Unmapped `Boss_*` entries are retained for manual maintenance and do not
  trigger the UGuid-only runtime yet.
- All Boss settings default to `State="true"`. Production logging includes all
  UGuid appearance/despawn edges plus loading/cutscene transitions, queued and
  actual splits, and exceptions.
- `AutoSplitEnabled` is the master automatic-split switch and defaults to false.
- `RemoveCutscenes` defaults to true. Cutscene state is captured through uHara
  `UnrealEngine/Events` hooks on `PlayLevelSequence`, `LevelSequencePlayer`,
  and `BinkMediaPlayer`; `isLoading` reads only the cached hook state. Do not use
  CameraManager view-target classes or periodic GUObjectArray scans as the
  loading decision.
- Settings resolve by full culture, then base language, then the Simplified
  Chinese default.
- Keep logs under the local LiveSplit `Logs` directory out of this repository.

## Change rules

- Make behavior changes only in `Source/Runtime`, then regenerate.
- Do not commit game binaries, save files, logs, crash dumps, release archives,
  or machine-specific generated output.
- Do not commit or push unless the user explicitly asks.

## Loading removal (2026-11-14)

The production model is:

```csharp
isLoading = WorldPending
         || NativeLoadingPending
         || (RemoveCutscenes && CutscenePending);
```

`isLoading` only pauses LiveSplit Game Time. A Real Time timer keeps advancing by design.

### Native loading state

Fast travel and title-to-game loading cannot be identified reliably from the world
name alone. `GWorld` may still point at the old gameplay world during the
loading window.

The verified native path is:

```text
GetCurLoadingScreenState UFunction
  -> native accessor
  -> module static slot
  -> root pointer + 0x240
  -> EGSLoadingScreenState byte
```

Current enum values:

```text
0 = Idle
1 = SlateThreadUpdating
2 = GameThreadWaitingMovieFinish
3 = MainThreadUpdating
```

Therefore `NativeLoadingPending` is simply `state != 0`.

The current build resolves the static slot with this unique AOB:

```text
48 8B 05 ?? ?? ?? ?? C3 CC CC CC CC CC CC CC CC 48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 48 8B 81 E8 00 00 00
```

`ScanRel` uses offset `3`. In the tested build the slot resolved to
`0x15D1763A0` (module RVA `0x1D1763A0`); the AOB is the production anchor.

Expected diagnostic transitions:

```text
isLoading=True world=old_world native=True cutscene=False
isLoading=False world=new_world native=False cutscene=False
```

Important failures from earlier attempts:

- `BGWGameInstance.OpenLoadingScreen` / `CloseLoadingScreen` were not reliable
  loading events. uHara class filters match exact runtime class names, and the
  actual subclass is `BGW_GameInstance_B1`.
- Do not copy PBZ's `GEngine + 0x12E0 + 0x7A2`; BMW uses its own accessor and
  field.
- Do not use `GWorld == None` as the primary fast-travel signal.
- Treat `WXLogin_P` and `SetConfig_P` as non-gameplay worlds. After a game restart their native loading can be zero while the login/setup flow is still active; without both worlds in `WorldPending`, Game Time leaks for several seconds.
- `onStart` unconditionally pauses Game Time like PBZ; the next `isLoading` evaluation restores it. This prevents the first-tick leak when starting from a menu.
- Auto-start from the menu by arming when the world starts with `Startup`.
  When the current world reaches `MGD_PersistentLevel`, return true even
  if native loading is still active; Game Time remains paused until loading ends.

### Cutscene / Bink state

Reference implementations:

- `D:\code\b1-mod\mods\TeleportRecall\CutsceneSpeed.cs`
- `D:\code\b1-mod\mods\TeleportRecall\BinkMediaSpeed.cs`
- The installed `PhantomBladeZero.asl` uses `uhara10-PBZ`
  `UnrealEngine/Events`, not `asl-help`.

Runtime hooks:

- Create `vars.Events = vars.Uhara.CreateTool("UnrealEngine", "Events")`.
- Register `PlayLevelSequence*` notification hooks as an optional coarse signal.
- Register `*LevelSequencePlayer*` `Play` and `Stop` hooks; this is the working
  primary signal for BMW camera/story sequences.
- Register `BinkMediaPlayer` `Play` and `Stop` hooks for pre-rendered video.
- Capture `CalliopeLevelSequenceActor` and `BGULevelSequenceActor` instances as
  a fallback source for the active SequencePlayer.
- Read the sequence name from:
  `LevelSequencePlayer + 0x290 -> LevelSequence`, then `LevelSequence + 0x18`.
- Read playback state from `LevelSequencePlayer + 0x288`.
- Read the Bink URL from `BinkMediaPlayer + 0x98`.
- `CutscenePending` is latched and cleared 500 ms after the matching Stop/status
  transition. Do not measure the hold from Play.
- A matching Bink Stop within 200 ms of Play is ignored. Chapter-end Bink has an
  early/fixed Stop followed later by the real Stop.
- Do not use generic `CineCameraActor`, CameraManager targets,
  `BGUChapterCameraActor`, periodic `GUObjectArray` scans, or fixed 5-second
  holds as loading signals.

Observed chapter-end pattern:

```text
bink play: player=0x... name=BinkMoviePlayer_Chapter
bink stop: player=0x... match=True elapsedMs=1 earlyStop=True
bink stop: player=0x... match=True elapsedMs=18799 earlyStop=False
```

The first Stop is ignored; the second Stop ends the Bink state.

### Validation matrix

1. Title -> Continue.
2. Normal fast travel and combat teleport.
3. Map-to-map loading.
4. Boss intro and post-boss CG.
5. Bink-only CG.
6. Pause page, inventory, and ordinary gameplay LevelSequence.
7. Death reload.
8. Fresh process launch and AOB re-resolution.

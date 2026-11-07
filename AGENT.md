# Repository Instructions

This repository stores the Black Myth Wukong LiveSplit auto splitter and its
comment-free runtime distribution.

## Runtime contract

- Editable ASL and settings XML live under `Source/Runtime`.
- Repository `Components`, release archives, and the local LiveSplit
  `Components` directory are generated outputs and must contain no comments.
- `Components/asl-help` is the required binary runtime dependency.
- Do not edit generated runtime ASL or XML under `Components`; regenerate
  them from `Source/Runtime`.
- Preserve user-selected `State="true"` / `State="false"` values in
  `BMWukong.Settings.xml` unless the requested change explicitly covers them.

## Source map

- `Source/Runtime/BlackMythWukong.asl`: editable save-file auto splitter source.
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
- `Components/*.asl` and `Components/*.xml`: generated runtime files. Do not edit them directly. `Components/asl-help` is the fixed binary dependency.

## Runtime synchronization

Run from the repository root after editing `Source/Runtime`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\build_wukong_runtime.ps1 -SyncLiveSplit
```

The command regenerates comment-free files in `Components`, then synchronizes
`BlackMythWukong.asl`, both settings XML files, and `asl-help` to
`D:\soft\e-game\LiveSplit_1.8.29\Components`.

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

- The splitter is save-file driven and also keeps the original memory-based
  start/load/game-time behavior.
- `AutoSplitEnabled` is the master automatic-split switch and defaults to false.
- Settings resolve by full culture, then base language, then the Simplified
  Chinese default.
- King splits use internal achievement `7403`; elite/chief splits use `7402`.
- `DeadUnitData` handling currently accepts `Destroy` and `Status` reset types.
- The abandoned Great Sage Remains node must not be restored without an explicit
  user request.
- The save file must be selected from the newest `ArchiveSaveFile.*.sav`.
- Keep logs under the local LiveSplit `Logs` directory out of this repository.

## Change rules

- Make behavior changes only in `Source/Runtime`, then regenerate.
- Do not commit game binaries, save files, logs, crash dumps, release archives,
  or machine-specific generated output.
- Do not commit or push unless the user explicitly asks.
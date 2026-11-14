# Black Myth Wukong LiveSplit Auto Splitter

《黑神话：悟空》LiveSplit 自动打点脚本。

## 安装

将 `Components` 目录中的以下文件复制到 LiveSplit 安装目录的 `Components`：

- `BlackMythWukong.asl`
- `BMWukong.Settings.xml`
- `BMWukong.Settings.en.xml`
- `uhara10-PBZ`
- `asl-help`

在 LiveSplit 中添加 `Scriptable Auto Splitter`，选择 `BlackMythWukong.asl`，然后确认设置面板中的 `AutoSplitEnabled` 和需要的 Boss 项已开启。

## 运行时文件

`Components` 中是可安装到 LiveSplit `Components` 目录的文件：

- `BlackMythWukong.asl`
- `BMWukong.Settings.xml`
- `BMWukong.Settings.en.xml`
- `uhara10-PBZ`
- `asl-help`

ASL 和 XML 由 `Source/Runtime` 生成，不直接编辑；`uhara10-PBZ` 是新的必需二进制运行时依赖，`asl-help` 作为旧依赖继续保留同步。ASL 会按当前系统语言优先加载完整区域名，再尝试基础语言名，最后回退到中文默认设置。

当前打点由配置中的 `UGuid___*` Boss Actor 驱动，支持死亡 montage 和全局击杀慢放；击杀慢放仅使用 `0.001 < timeDilation < 0.16`，避免完美闪避、识破和退寸误触发。普通配置使用 `Dead_UGuid.*`；只希望死亡 Montage 触发时使用 `Montage_UGuid.*`，它会跳过慢放；如果 Boss 中途会消失，可用 `Despawn_UGuid.*`，该前缀会跳过 Montage 和慢放，只在 Actor 消失时打点。双 Boss 使用 `Dual_UGuid.A+UGuid.B`，两个 Actor 都出现死亡 Montage 后才打点，且不会使用慢放信号；配置在 `init` 中解析一次，逐帧只做字典查询。每章设置先包一层章节分类，再分为“主线 Boss”“全妖王 Boss”和“头目 Boss”；主线按用户维护的列表保留，非主线按影神图的妖王/头目类型归类，所有 Boss 默认开启。尚未找到可靠 UGuid 映射的 `Boss_*` 项会原样保留。脚本会为所有 UGuid Actor 记录出现和消失日志，并为已配置 Boss 记录死亡 Montage 检测日志；只有实际入队时才进行自动打点判定。

`RemoveCutscenes` 默认开启，通过 `uhara10-PBZ` 的 `UnrealEngine/Events` 注册 `PlayLevelSequence`、`LevelSequencePlayer` 和 `BinkMediaPlayer` 事件，缓存过场播放状态后由 `isLoading` 暂停 Game Time。不再使用 CameraManager、GUObjectArray 扫描或相机类名做判据。该逻辑只影响 Game Time，布局必须使用 Game Time 才能观察去加载效果。

## 根目录镜像

生成时还会把以下无注释文件同步到仓库根目录，方便直接引用：

- `BlackMythWukong.asl`
- `BMWukong.Settings.xml`
- `BMWukong.Settings.en.xml`

根目录副本是生成输出，不要直接编辑；请修改 `Source/Runtime` 后重新生成。

## 开发

可编辑源码：

- `Source/Runtime/BlackMythWukong.asl`
- `Source/Runtime/BMWukong.Settings.xml`
- `Source/Runtime/BMWukong.Settings.en.xml`

生成无注释运行时文件：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\build_wukong_runtime.ps1
```

生成并同步到本机 LiveSplit：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\build_wukong_runtime.ps1 -SyncLiveSplit
```

验证：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\test_wukong_runtime.ps1
```

`AutoSplitEnabled` 是自动打点总开关，默认关闭。同步前脚本会比较 `LastWriteTime` 和 SHA-256。若本机 LiveSplit 中的文件更新且内容不同，会停止并提示先合并回 `Source/Runtime`，避免覆盖手动修改。

维护和调试经验见 [TECHNICAL_NOTES.md](TECHNICAL_NOTES.md)。

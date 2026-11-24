# Black Myth Wukong LiveSplit Auto Splitter

《黑神话：悟空》LiveSplit 自动打点脚本。

## 安装

1. 关闭 LiveSplit。
2. 将压缩包内 `Components` 文件夹中的以下文件复制到 LiveSplit 安装目录的 `Components` 文件夹；遇到同名文件选择覆盖：
   - `BlackMythWukong.asl`
   - `BMWukong.Settings.xml`
   - `BMWukong.Settings.en.xml`
   - `uhara10-BMW`
3. 启动 LiveSplit，编辑布局(edit layout)并添加 `脚本自动打点器(Scriptable Auto Splitter)`，然后选择刚才复制过去的 `Components\BlackMythWukong.asl` 即可。

## 注意事项

若自动打点生效但去动画不生效，请检查：

1. 是否安装了 Mod。有些 Mod 也会 Hook，和去动画原理冲突；移除 Mod 即可。
2. 检查编辑节点（Edit splits）里的去加载是否处于激活状态（能点 Setting 按钮就是激活了）。若是，则取消激活，然后保存节点（Save splits），再重启计时器软件。

## 分段文件

`lss` 目录提供两份内容等价的 42 段主线计时文件：

- 中文：`黑猴-主线-分章节.lss`
- 英文：`Black Myth Wukong - Main Bosses - By Chapter.lss`

在 LiveSplit 中通过“打开分段”选择对应语言的文件。两份文件的章节、顺序、图标、时间和自动打点设置相同，只翻译分类名和分段名。

## 运行时文件

`Components` 中是可安装到 LiveSplit `Components` 目录的文件：

- `BlackMythWukong.asl`
- `BMWukong.Settings.xml`
- `BMWukong.Settings.en.xml`
- `uhara10-BMW`

ASL 和 XML 由 `Source/Runtime` 生成，不直接编辑；`uhara10-BMW` 是黑猴专用的必需二进制运行时依赖，与影之刃的 `uhara10-PBZ` 分开命名，避免互相覆盖。ASL 会按当前系统语言优先加载完整区域名，再尝试基础语言名，最后回退到中文默认设置。

当前打点由配置中的 `UGuid___*` Boss Actor 驱动，支持死亡 montage 和全局击杀慢放；击杀慢放仅使用 `0.001 < timeDilation < 0.16`，避免完美闪避、识破和退寸误触发。`Montage_UGuid.*` 只接受死亡 Montage，适合绝大多数 Boss；`Slow_UGuid.*` 只接受单 Boss 击杀慢动作，当前仅用于不白一阶段；如果 Boss 中途会消失，可用 `Despawn_UGuid.*`，该前缀会跳过 Montage 和慢放，只在 Actor 消失时打点。需要按指定动作 Montage 触发时使用 `Action_UGuid.*@动作名`，同一 UGuid 可同时配置多个不同动作或与其他触发类型并存。需要按过场序列触发时使用 `Seq_<sequenceName>`，脚本在 `LevelSequencePlayer.Play` 回调中按序列名精确匹配并立即入队。双 Boss 使用 `Dual_UGuid.A+UGuid.B`，两个 Actor 都出现死亡 Montage 后才打点，且不会使用慢放信号；配置在 `init` 中解析一次，逐帧只做字典查询。设置先按“主线”“全妖王”“其余头目”三个大类分组，每个大类下再按六章展开，主线大类另含序章；主线按用户维护的列表保留，非主线按影神图的妖王/头目类型归类，所有 Boss 默认开启。脚本会为所有 UGuid Actor 记录出现和消失日志，并为已配置 Boss 记录死亡 Montage 检测日志；只有实际入队时才进行自动打点判定。打开“记录日志”后，日志会同时追加到 LiveSplit 目录的 `Logs\BlackMythWukong.log`。

“CG 动画去加载”默认开启，通过 `uhara10-BMW` 的 `UnrealEngine/Events` 注册 `LevelSequencePlayer` 和 `BinkMediaPlayer` 事件。Sequence 的 `SetDisableCameraCuts` 控制权交还会提前结束加载判断，避免人物已恢复操作后仍等待 Sequence `Stop`；Bink 只有对象名为 `BinkMoviePlayer_Chapter` 的章节末尾视频参与加载，并保留 200ms 提前 Stop 保护；其他 Bink 只打印诊断日志。不再使用 `PlayLevelSequence` 粗通知、CameraManager、GUObjectArray 扫描或相机类名做判据。该逻辑只影响游戏时间，布局必须使用“游戏时间”才能观察去加载效果。

## 发布规则

运行时文件只放在 `Components` 目录，发布包中的 `Components` 只包含：

- `BlackMythWukong.asl`
- `BMWukong.Settings.xml`
- `BMWukong.Settings.en.xml`
- `uhara10-BMW`

仓库根目录不得保留 ASL/XML 镜像，`Components` 和发布包不得包含旧版 `asl-help`。黑猴脚本只依赖 `uhara10-BMW`；修改脚本或设置时编辑 `Source/Runtime`，再重新生成。

`lss` 目录只保留中英文两份主线分段文件。发布包需要同时包含 `Components` 和这两份 `.lss`，并在 Release 中提供两份 `.lss` 的独立下载。

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

“自动打点总开关”默认开启。同步前脚本会比较 `LastWriteTime` 和 SHA-256。若本机 LiveSplit 中的文件更新且内容不同，会停止并提示先合并回 `Source/Runtime`，避免覆盖手动修改。

维护和调试经验见 [TECHNICAL_NOTES.md](TECHNICAL_NOTES.md)。

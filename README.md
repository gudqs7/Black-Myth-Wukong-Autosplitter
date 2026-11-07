# Black Myth Wukong LiveSplit Auto Splitter

《黑神话：悟空》LiveSplit 自动打点脚本。

## 运行时文件

`Components` 中是可安装到 LiveSplit `Components` 目录的文件：

- `BlackMythWukong.asl`
- `BMWukong.Settings.xml`
- `BMWukong.Settings.en.xml`
- `asl-help`

ASL 和 XML 由 `Source/Runtime` 生成，不直接编辑；`asl-help` 是同步用的固定二进制依赖。ASL 会按当前系统语言优先加载完整区域名，再尝试基础语言名，最后回退到中文默认设置。

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
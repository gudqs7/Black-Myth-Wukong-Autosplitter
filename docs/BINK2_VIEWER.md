# Bink2 视频查看与排查

本机保留了 RAD Video Tools，用于直接播放或转码 Black Myth: Wukong 的
`.bk2` 视频。它不参与 AutoSplitter 运行时，也不应打包进 LiveSplit 发布目录。

## 本机工具

```text
D:\soft\e-game\LiveSplit_AutoSplitter\_tools\radtools\installed\radvideo64.exe
D:\soft\e-game\LiveSplit_AutoSplitter\_tools\radtools\installed\binkplay.exe
```

来源：https://www.radgametools.com/bnkdown.htm

RAD 下载包为 `RADTools.7z`，解压密码为 `RAD`。解压和安装步骤已在本机完成。

## 直接播放

```powershell
& "D:\soft\e-game\LiveSplit_AutoSplitter\_tools\radtools\installed\radvideo64.exe" `
  BinkPlay "D:\path\to\video.bk2"
```

也可以双击 `binkplay.exe`，再选择 `.bk2` 文件。

## 转换为 MP4

```powershell
& "D:\soft\e-game\LiveSplit_AutoSplitter\_tools\radtools\installed\radvideo64.exe" `
  BinkConv "D:\path\to\video.bk2" "D:\path\to\video.mp4" /AutoClose
```

转换窗口会显示进度；完成后可用普通播放器检查画面、时长和音频。

## 从游戏 pak 提取

当前工作区已有 `Cue4Parse` 提取工具：

```text
D:\soft\e-game\LiveSplit_AutoSplitter\_analysis\Cue4List\bin\Debug\net8.0\Cue4List.exe
```

列出匹配资产：

```powershell
Cue4List.exe list "LS_hys_cpt070_seq015" "D:\soft\e-game\LiveSplit_AutoSplitter\_analysis\Cue4List\exports_movie"
```

提取匹配资产：

```powershell
Cue4List.exe extract "LS_hys_cpt070_seq015" "D:\soft\e-game\LiveSplit_AutoSplitter\_analysis\Cue4List\exports_movie"
```

提取工具已配置 `GAME_BlackMythWukong`、AES key 和 Oodle/Zlib 运行库。

## 已检查样片

`LS_hys_cpt070_seq015.bk2`：

- 原始 Bink2：1,421,779,852 字节
- 转码 MP4：4 分 44.44 秒，3440x1440，60 FPS，H.264 + AAC
- 内容为暗色罗刹宫/洞府场景的剧情 CG，结尾出现猪八戒本相
- 完整 MP4、32 秒节选和时间线图位于：

```text
D:\soft\e-game\LiveSplit_AutoSplitter\_analysis\Cue4List\exports_movie\b1\Content\Movies\Seq\
```

## 对 Bink Play/Stop 判断的影响

`BinkMediaPlayer.Stop` 不能单独视为视频真正结束：

- 过场刚开始时可能立即收到一次 `Stop`；
- 实际 `LS_hys_cpt070_seq015.bk2` 仍有 4 分 44 秒内容；
- 游戏跳过过场的调用链为：
  `EDMovieIgnore -> EDMovieStop -> BinkMediaPlayer.Stop -> EDMovieDoEnd`；
- 因此跳过会额外产生一个真实 Stop，不能只靠固定时长判断结束。

当前 ASL 只用对象名 `BinkMoviePlayer_Chapter` 识别章节末尾视频，不读取
Bink URL。章节末尾 Bink 参与 `CutscenePending` / `isLoading`，并保留
200ms 的提前 Stop 保护；其他 Bink 的 `Play` / `Stop` 只打印详细诊断日志。

### 已排除的 Hook

以下信号实测均没有打印，已从 ASL 中移除：

1. `FOnBinkMediaPlayerMediaReachedEndWrapper:Callback`；
2. `UISeqMediaPlayer.OnUIPageConstructImpl` / `OnUIPageDestructImpl`；
3. `UISeqMediaPlayer.EDMovieDoEnd`。

当前 `GSWithBink` 路径没有绑定 `OnMediaReachedEnd` 委托，而
`BinkMediaPlayState`、`IsEnding`、`EDMovieDoEnd` 属于托管私有状态/方法，
现有 uHara `FunctionFlag` 无法直接观察。

后续应优先给 uHara 增加专用 UFunction 调用器，轮询：

1. `BinkMediaPlayer.IsPlaying()` / `IsStopped()`；
2. `BinkMediaPlayer.GSGetCurFrame()` / `GSGetTotalFrames()`；
3. 只在活动 Bink 存在时低频轮询，避免每帧创建远程线程。

不要使用 Bink 文件固定时长作为结束依据，因为用户可以直接跳过。

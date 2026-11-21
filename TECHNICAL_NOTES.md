# 技术总结

本文记录黑神话：悟空 LiveSplit 自动打点脚本的有效信号、性能约束和已排除方案，供后续维护与回归测试使用。

## Boss 识别模型

- 以场景中的 `UGuid___*` Actor 作为主要 Boss 唯一键。
- Actor 名会转换为形如 `UGuid.HFS.GuangZhi` 的 UID，再映射到设置 ID。
- 部分 Boss 的运行时 Actor 名不是 `UGuid___*`，而是 `GUID-TAMER_xxx_C_n@_n`。这类 Boss 直接使用 `Montage_TAMER_*`、`Slow_TAMER_*` 或 `Despawn_TAMER_*` 设置，不维护运行时别名表；出现日志同时记录解析后的 `uid` 和原始 `name`。
- Actor 扫描间隔为 50 ms，只跟踪配置中存在的 Boss Actor。
- 每个 Actor 的缓存只保留 Actor 指针、首次观察时间和死亡 Montage 是否已触发。
- 世界切换、计时器重置和双 Boss 进度重置都走同一套清理流程。

GUID-TAMER Actor 的完整查找、名称确认和 setting 转换流程见
[docs/TAMER_ACTOR_LOOKUP.md](docs/TAMER_ACTOR_LOOKUP.md)。

## 打点信号

### 死亡 Montage

- 从 AnimInstance 的 Montage 数组中读取 Montage 名称。
- 名称包含 `_die`、`_dead`、`death` 或 `suicide` 时视为死亡 Montage。
- 检测到后按 Actor 锁存，避免同一死亡事件重复入队。
- `Montage_UGuid.*` 只接受该信号。

### 指定动作 Montage

- 读取 AnimInstance 当前活动 Montage 名称，按名称精确匹配（不区分大小写）。
- 当前构建需合并读取 `AnimInstance+0x88`、`+0x128`、`+0x138` 三组活动 Montage 数组；灵虚子的攻击和 `BIdle` 会进入后两组，只读主数组会在初见战斗阶段漏掉 action。
- Montage 数组 item 的指针位置存在版本/实例差异：需同时尝试 `item+0` 和 `item+0x18`，并用对象类名必须包含 `AnimMontage` 做校验。
- 配置格式为 `Action_<UID>@动作名`；`<UID>` 可为 `UGuid.*` 或直接 Tamer 名。动作模式支持精确匹配、`foo*` 前缀、`*foo` 后缀、`*foo*` 包含，单独的 `*` 匹配任意非空动作。
- `Action_` 设置独立于 `Montage_`/`Slow_`/`Despawn_` 解析，因此同一 UGuid 或 GUID-TAMER Actor 可以配置多个事件。
- 逐动作变化日志当前直接开启，只输出 `uid`、`action` 和 `deathAction`；不再输出 AnimInstance、数组头或 item 指针详情。
- Actor 消失日志和死亡 Montage 日志仍会输出当前/最终动作与可复制设置键。

### 击杀慢动作

读取：

```text
UWorldSettings + 0x3A8
```

生产阈值为：

```text
0.001 < timeDilation < 0.16
```

实测参考：

- 识破、退寸：约 `0.5`。
- 完美闪避：连续变化，但最低不低于 `0.3`。
- Boss 击杀：约 `0.14x`，最低观察到 `0.125`。

因此不能使用 `< 0.5`，否则玩家动作会产生误打点。`Slow_UGuid.*` 只接受该信号。全局慢动作还要求场上恰好有一个已启用 `Slow_` Boss 候选，避免双 Boss 或召唤物场景把同一事件分配给多个设置。

### Actor 消失

- `Despawn_UGuid.*` 只在 Actor 从当前世界真正消失时打点。
- 最短观察时间为 500 ms，避免加载过程中的瞬态 Actor 误触发。
- 这是死亡 Montage 不可靠时的显式回退，不依赖 `bHidden`。

### 双 Boss

设置格式：

```text
Dual_UGuid.A+UGuid.B
```

- 配置只在 `init` 阶段读取一次，逐帧只做 Dictionary/HashSet 查询。
- 两个 Actor 都出现死亡 Montage 后才入队。
- 双 Boss 设置不使用慢动作或隐藏信号。
- 重置时必须保留设置键并清空每个设置的命中集合。不能把命中字典替换成空字典，否则后续 `[setting]` 会触发 `KeyNotFoundException`。
- 读取设置状态时优先使用 `TryGetValue`，避免一次状态异常中断整个 `update`。

## 已排除信号

### bHidden

`bHidden` 表示 Boss 在特定招式或演出中暂时消失，不代表死亡。它会产生大量副作用和误打点，已从运行时完全移除。除非同时获取可靠的死亡状态或生命值数据，否则不要恢复。

### 通用低时间膨胀

所有 `< 1` 的时间膨胀日志和 `< 0.5` 阈值均已删除。当前只保留击杀慢动作会进入的极低区间。

## 性能与可靠性

- Boss Actor 扫描固定在 50 ms，避免逐帧遍历全部 Actor。
- 不做逐帧文件 I/O。
- 双 Boss 结构只在初始化时解析 XML。
- 日志只记录 Actor 出现/消失、死亡 Montage、入队、实际打点和异常。
- `split` 每轮最多消费一个待定设置，避免同一帧连打多个点。
- 运行时文件必须由 `Source/build_wukong_runtime.ps1` 去注释生成，并通过 `Source/test_wukong_runtime.ps1` 的 ASL 解析和 XML 一致性检查。
- 发布目录包含 `Components` 中的 ASL、两份设置 XML、`uhara10-BMW`，以及 `lss` 中的中英文两份主线分段文件。仓库根目录不得保留 ASL/XML 镜像，`Components` 和发布包不得包含旧版 `asl-help`。

## 验证清单

- 普通 Boss 的死亡 Montage。
- 百目真人与其他 `GUID-TAMER` 命名的 Boss 能产生 actor appeared 日志并命中对应 `Montage_TAMER_*` 设置。
- 高闪避频率下的完美闪避、识破和退寸均不触发慢动作打点。
- Boss 击杀慢动作能正常触发。
- `Montage_UGuid.*` 不被慢动作或消失信号触发。
- `Slow_UGuid.*` 不被死亡 Montage 或消失信号触发。
- `Despawn_UGuid.*` 不被 Montage 或慢动作触发。
- 双 Boss 只击杀一个时不打点，两个都出现 Montage 后只打一次。
- 世界切换、计时器重置和 Actor 重建后不保留旧双 Boss 进度。

## 维护与发布经验

- 新增 ASL `vars` 字段或委托后，必须完全退出并重启 LiveSplit 再验证；LiveSplit
  热重载可能留下空字段并产生 `NullReferenceException`。
- Montage 数组 `count > 0` 不代表一定读到了动作：需检查 item 内候选指针并校验
  对象类名包含 `AnimMontage`。当前已验证兼容 `item+0` 与 `item+0x18`。
- 动作诊断只用于定位阶段。生产日志保留 `uid`、`action`、`deathAction` 即可；
  不要恢复周期 Montage-state、AnimInstance、数组头或 item 指针输出。
- 修改中英文设置或 LSS 时，四处必须同步：中英文 XML、两份 LSS、生成目录和
  本机 LiveSplit 目录；发布前必须跑完整三组测试。
- 更新 Release 时替换现有资源并同步更新 release notes、`SHA256SUMS.txt` 和
  `dist`。`dist` 只保留当前版本，避免旧包混入。
- GitHub Release asset 文件名会把中文字符净化成连字符（例如 `-.-.lss`）。
  中文展示名应使用 asset `label`，文件名使用稳定 ASCII，并在发布说明和校验
  文件中写明实际下载文件名。
- 用户遇到“自动打点生效但去动画不生效”时，优先排查 Mod Hook 冲突和
  Edit splits 中仍激活的去加载设置；按安装说明取消后保存并重启。
## Bink2 视频检查

本机保留了 RAD Video Tools，用于直接播放 `.bk2` 或转成 MP4；提取、查看命令和
`BinkMediaPlayer.Stop` 的已知行为记录在 [docs/BINK2_VIEWER.md](docs/BINK2_VIEWER.md)。

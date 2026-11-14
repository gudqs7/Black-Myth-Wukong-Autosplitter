# 技术总结

本文记录黑神话：悟空 LiveSplit 自动打点脚本的有效信号、性能约束和已排除方案，供后续维护与回归测试使用。

## Boss 识别模型

- 以场景中的 `UGuid___*` Actor 作为 Boss 唯一键。
- Actor 名会转换为形如 `UGuid.HFS.GuangZhi` 的 UID，再映射到设置 ID。
- Actor 扫描间隔为 50 ms，只跟踪配置中存在的 Boss Actor。
- 每个 Actor 的缓存只保留 Actor 指针、首次观察时间和死亡 Montage 是否已触发。
- 世界切换、计时器重置和双 Boss 进度重置都走同一套清理流程。

## 打点信号

### 死亡 Montage

- 从 AnimInstance 的 Montage 数组中读取 Montage 名称。
- 名称包含 `_die`、`_dead`、`death` 或 `suicide` 时视为死亡 Montage。
- 检测到后按 Actor 锁存，避免同一死亡事件重复入队。
- `Montage_UGuid.*` 只接受该信号。

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

因此不能使用 `< 0.5`，否则玩家动作会产生误打点。全局慢动作还要求场上恰好有一个已启用 Boss 候选，避免双 Boss 或召唤物场景把同一事件分配给多个设置。

### Actor 消失

- `Despawn_UGuid.*` 只在 Actor 从当前世界真正消失时打点。
- 最短观察时间为 1500 ms，避免加载过程中的瞬态 Actor 误触发。
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

## 验证清单

- 普通 Boss 的死亡 Montage。
- 高闪避频率下的完美闪避、识破和退寸均不触发慢动作打点。
- Boss 击杀慢动作能正常触发。
- `Montage_UGuid.*` 不被慢动作或消失信号触发。
- `Despawn_UGuid.*` 不被 Montage 或慢动作触发。
- 双 Boss 只击杀一个时不打点，两个都出现 Montage 后只打一次。
- 世界切换、计时器重置和 Actor 重建后不保留旧双 Boss 进度。

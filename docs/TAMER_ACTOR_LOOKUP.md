# 查找 TAMER Actor 与配置打点

本文记录在《黑神话：悟空》中定位 `GUID-TAMER_*` Actor、确认敌人名称并转换为
LiveSplit setting 的实用流程。运行时不再维护 `BossActorAliases`；Actor 与配置的
关系由 setting id 本身承担。

## 1. 先确认当前世界和 Actor

本机工作区保留了只读诊断工具：

```powershell
D:\soft\e-game\LiveSplit_AutoSplitter\_analysis\LiveMontageInspect\bin\Release\net9.0\LiveMontageInspect.exe --world
D:\soft\e-game\LiveSplit_AutoSplitter\_analysis\LiveMontageInspect\bin\Release\net9.0\LiveMontageInspect.exe --all-actors
```

需要重点看三类信息：

```text
World=..._PersistentLevel
ACTOR ... name=GUID-TAMER_xxx_C_n@_m class=Unit_xxx_C
```

- `@_1`、`@_2` 是运行时实例后缀，不稳定，不能写进 setting。
- 前面的时间戳和哈希是场景 Actor GUID，普通 Boss 应忽略。
- `_C_n` 是场景放置/蓝图变体后缀，通常先去掉得到基础 Tamer 名。
- 同一 Tamer 在同一流程中存在多个需要区分的战斗时，才保留完整的 `_C_n`。

常用过滤命令：

```powershell
LiveMontageInspect.exe --all-actors |
  Select-String -Pattern 'class=Unit_|class=UNIT_|class=TAMER_'
```

当前运行时只会记录已经存在对应 `Montage_TAMER_*`、`Slow_TAMER_*`、
`Despawn_TAMER_*` 或 `Action_TAMER_*` 设置的 GUID-TAMER Actor。未配置的普通小怪不会进入生产日志，
因此找新小怪时必须使用上述独立诊断工具，或先临时添加 setting。

## 2. 从资源表补充名称和 ID

`GMMapStaticData.json` 可以确认场景 Actor GUID、资源类别和资源 ID：

```text
D:\soft\e-game\LiveSplit_AutoSplitter\_analysis\wukong_pbtable_full\b1\Content\00Main\PBTable\GMMapStaticData\GMMapStaticData.json
```

搜索：

```powershell
rg -n -i 'TAMER_hys_huijingtitan_01|TAMER_psd_renshenjing_02a' `
  D:\soft\e-game\LiveSplit_AutoSplitter\_analysis\wukong_pbtable_full\b1\Content\00Main\PBTable\GMMapStaticData\GMMapStaticData.json
```

重点记录：

- `Guid`：完整场景 Actor 名，可与运行时 `name` 前缀对应。
- `CategoryName`：通常包含 Tamer 资源名。
- `ResId`：单位资源 ID。
- `ExtendId`：实际战斗单位扩展 ID。

敌人中文名可从以下 protobuf 数据确认：

```text
...\PBTable\Runtime\SceneMonsterNameplateDesc.data
...\PBTable\NoneRuntime\FUStUnitBattleInfoExtendDesc-*.data
```

`FUStUnitBattleInfoExtendDesc` 的记录字段中，常见映射为：

```text
field 1 = 单位/扩展 ID
field 2 = 名称
```

`SceneMonsterNameplateDesc` 常用于确认地图/Boss 名称，不一定包含普通小怪名。
如果本地化记录为空，可结合 `ExtendId`、资源文件名和当前画面确认。

## 3. 转换为 setting id

运行时匹配规则：

```text
GUID-TAMER_xxx_C_n@_m
  -> 先查受支持前缀 + TAMER_xxx_C_n
  -> 未命中再去掉 _C_n，查受支持前缀 + TAMER_xxx
```

因此普通 Boss 使用基础名：

```text
Montage_TAMER_<资源名>
```

例如：

```text
GUID-TAMER_hfm_hou_01a_C_1@_1
  -> Montage_TAMER_hfm_hou_01a
```

只有没有稳定 UGuid、但同一基础 Tamer 对应多个独立战斗时，才考虑完整后缀。
当前黑手道人以用户确认的 UGuid/死亡 Montage 设置为准：

```text
Montage_UGuid.PSD.WuLong      # 黑手道人(初见)
Montage_UGuid.PSD.WuLong.4H   # 黑手道人(进紫云山前)
```

前缀语义仍与其他 Boss 一致：

```text
Montage_TAMER_*    只接受死亡 Montage
Slow_TAMER_*       只接受击杀慢动作
Despawn_TAMER_*    只接受 Actor 消失
Action_TAMER_*@*   只接受匹配的当前动作 Montage
```

## 4. 已确认案例

| 敌人 | 运行时 Actor 示例 | Setting id |
|---|---|---|
| 百目真人 | `GUID-TAMER_hfm_hou_01a_C_1@_1` | `Montage_TAMER_hfm_hou_01a` |
| 老人参精 | `GUID-TAMER_psd_renshenjing_02a_C_1@_1` | `Montage_TAMER_psd_renshenjing_02a` |
| 黑手道人·初见 | `GUID-TAMER_psd_wulong_C_4@_1` | `Montage_UGuid.PSD.WuLong` |
| 黑手道人·进紫云山前 | `GUID-TAMER_psd_wulong_C_3@_1` | `Montage_UGuid.PSD.WuLong.4H` |
| 燧统领 | `GUID-TAMER_HFM_ShiTongLing_02a_C_3@_1` | `Montage_TAMER_HFM_ShiTongLing_02a` |
| 燧先锋 | `GUID-TAMER_hys_shixianfeng_02_C_8@_1` | `Montage_TAMER_hys_shixianfeng_02` |
| 火灵元母 | `GUID-TAMER_hys_huolingsha_01_C_1@_1` | `Montage_TAMER_hys_huolingsha_01` |
| 金妞（用户确认） | `GUID-TAMER_hys_huijingtitan_01_C_4@_2` | `Montage_TAMER_hys_huijingtitan_01` 或精确 `_C_4` |
| 牾提辖 | `GUID-TAMER_hys_niu_02_C_0@_2` | `Montage_TAMER_hys_niu_02` |

## 5. 添加和验证

1. 同时修改 `Source/Runtime/BMWukong.Settings.xml` 与
   `Source/Runtime/BMWukong.Settings.en.xml`，保持 Id 一致、只改标签语言。
2. 同步修改 `lss` 目录下中英文两份设置列表，保持 Setting id 一致。
3. 运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\build_wukong_runtime.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\test_wukong_runtime.ps1
```

4. 确认 `WUKONG_LSS_TEST_OK`、`ASL_PARSE_OK`、`WUKONG_RUNTIME_TEST_OK`。
5. 使用 `-SyncLiveSplit` 同步，随后核对 SHA-256。
6. LiveSplit 会自动重新加载修改后的 ASL；无需完全退出并重启 LiveSplit。

## 6. 注意事项

- 不要用完整运行时名称作为普通 setting；时间戳/GUID 和 `@_n` 后缀会变化。
- 不要在 ASL 中恢复 `BossActorAliases` 或类似硬编码映射表。
- `Action_TAMER_*` 同样参与 Tamer 解析；动作模式支持精确匹配、`foo*`、`*foo` 和 `*foo*`。
- 只有当 setting 已经存在时，GUID-TAMER Actor 才会进入生产日志。
- 发现新小怪时先记录 `raw name + class + world + ResId/ExtendId`，再决定使用基础名还是完整 `_C_n`。
- 不要仅凭 Actor 类名判定敌人身份；以当前场景实例、资源表和画面共同确认。

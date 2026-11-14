/*
 * Black Myth: Wukong LiveSplit 自动打点脚本（可编辑源码）。
 *
 * 源码规则:
 * - 本文件是唯一保留注释的位置；Components、仓库根目录、发布包和本地
 *   LiveSplit Components 均由 build_wukong_runtime.ps1 去除注释后生成。
 * - 生命周期钩子和每个委托都要说明作用、入参、返回值和大致原理；
 *   较长的状态处理段要说明数据来源、判定顺序和失败时的行为。
 * - 注释必须描述当前实现，不能把计划、猜测或已经删除的旧方案写成事实。
 *
 * 运行时约定:
 * - UGuid 是唯一可靠的 Boss 观察键；Boss_* 只保留给尚未完成 UGuid 映射的项。
 * - Dual_UGuid.A+UGuid.B 只在两个 Boss 都出现死亡 Montage 后打点。
 * - Montage_* 只接受死亡 Montage，Despawn_* 只接受 Actor 消失。
 * - isLoading 只暂停 Game Time，Real Time 始终由 LiveSplit 正常推进。
 */
state("b1-Win64-Shipping") {}
state("b1-WinGDK-Shipping") {}

// LiveSplit 生命周期钩子：startup
// 作用：初始化文件日志、加载 uHara 运行时，并读取当前语言的 Boss 设置 XML。
// 入参：没有显式参数；LiveSplit 通过 ASL 注入设置构建器和 vars 容器。
// 返回：null。
// 原理：startup 在游戏进程出现前即可运行，因此设置必须在这里读取，才能让
// LiveSplit 设置面板立即出现；uHara 加载失败则直接抛出，避免后续用未初始化对象。
startup
{
    string componentDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Components");

    // Log 委托。
    // 入参：message，已经格式化好的一行日志。
    // 返回：void；所有目录和文件异常都在内部吞掉。
    // 原理：日志追加到 LiveSplit\Logs，带本地时间戳；写日志失败不能中断计时。
    vars.LogPath = Path.Combine(
        AppDomain.CurrentDomain.BaseDirectory,
        "Logs",
        "BMW-Hook-AutoSplitter.log");
    vars.Log = (Action<string>)(message =>
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName((string)vars.LogPath));
            File.AppendAllText(
                (string)vars.LogPath,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + message + Environment.NewLine);
        }
        catch {}
    });

    // 从组件目录加载独立的 uHara 副本。使用绝对组件路径，避免依赖当前工作目录；
    // 抛出的异常会先写入本脚本日志，再继续向上传播以阻止半初始化状态。
    try
    {
        Assembly.Load(File.ReadAllBytes(Path.Combine(componentDir, "uhara10-BMW"))).CreateInstance("Main");
    }
    catch (Exception ex)
    {
        ((Action<string>)vars.Log)("[BMW-loading] uhara load failed: " + ex.ToString());
        throw;
    }

    // 设置解析顺序：
    // 1. 完整区域名，例如 BMWukong.Settings.zh-CN.xml。
    // 2. 基础语言名，例如 BMWukong.Settings.en.xml。
    // 3. 默认 BMWukong.Settings.xml。
    // 使用 CurrentCulture 而不是 CurrentUICulture，因此跟随 Windows 区域格式；
    // 只做 File.Exists 判断，不在这里解析 XML 内容。
    string culture = System.Globalization.CultureInfo.CurrentCulture.Name;
    string settingsPath = Path.Combine(componentDir, "BMWukong.Settings." + culture + ".xml");
    if (!File.Exists(settingsPath))
    {
        string language = culture.Split('-')[0];
        settingsPath = Path.Combine(componentDir, "BMWukong.Settings." + language + ".xml");
    }
    if (!File.Exists(settingsPath))
        settingsPath = Path.Combine(componentDir, "BMWukong.Settings.xml");

    vars.SettingsPath = settingsPath;
    vars.Uhara.Settings.CreateFromXml(settingsPath);
    ((Action<string>)vars.Log)("[BMW-loading] settings loaded: " + settingsPath);
}

// LiveSplit 生命周期钩子：init
// 作用：解析 UE 基础对象、创建内存读取和打点委托、注册过场 Hook，并初始化
// 所有跨 update 的缓存与队列。
// 入参：没有显式参数；ASL 运行时已绑定 state 声明的黑猴进程并刷新初始状态。
// 返回：null；关键工具解析失败时抛出异常，阻止使用不完整偏移继续运行。
// 原理：固定偏移只对当前游戏构建有效；ASL 委托每轮可能重新编译，因此可变状态
// 必须保存在 vars，current/old 只承载 LiveSplit 生命周期之间的小型状态。
init
{
    // 初始化顺序：
    // 1. 解析 GWorld/GEngine/FNamePool、Events 和原生加载状态槽。
    // 2. 建立通用对象、FString、Sequence 状态和镜头节点读取委托。
    // 3. 建立 Boss 动画与死亡 Montage 读取委托。
    // 4. 解析设置和 Dual_ 配置，建立去重、队列与双 Boss 状态。
    // 5. 初始化扫描节流、过场判断窗口和本会话状态。

    // 1. UE 基础对象和原生加载状态。
    // Utilities 负责解析 GWorld、GEngine 和 FNamePool；三者任一缺失都说明 AOB
    // 或 uHara 版本不匹配，必须中止 init，不能用零指针继续运行。
    vars.Utils = vars.Uhara.CreateTool("UnrealEngine", "Utilities");
    if (vars.Utils.GWorld == IntPtr.Zero
        || vars.Utils.GEngine == IntPtr.Zero
        || vars.Utils.FNames == IntPtr.Zero)
    {
        throw new Exception("Unreal utilities could not resolve GWorld/GEngine/FNames");
    }

    // Events 负责 ProcessEvent Hook、UObject 实例捕获和 FName 解码支持。
    vars.Events = vars.Uhara.CreateTool("UnrealEngine", "Events");
    if (vars.Events == null)
        throw new Exception("Unreal events tool could not be created");

    // ScanRel 的第 1 个参数 3 表示从匹配地址向后取 RIP 相对位移。
    // AOB 命中 GetCurLoadingScreenState 的访问器，返回值指向保存根对象的静态槽。
    vars.LoadingStateSlot = vars.Uhara.ScanRel(
        3,
        "48 8B 05 ?? ?? ?? ?? C3 CC CC CC CC CC CC CC CC 48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 48 8B 81 E8 00 00 00");
    if (vars.LoadingStateSlot == IntPtr.Zero)
        throw new Exception("BGWGameInstance loading state slot was not found");

    // 2. 通用读取委托。
    // ReadClassName 委托。
    // 入参：obj，UObject 地址，可为 IntPtr.Zero。
    // 返回：类名；对象、UClass 或 FName 无效时返回空字符串。
    // 原理：UObject+0x10 是 UClass 指针，UClass+0x18 是类名 FName id，
    // 最后通过 uHara 的 FName 解码器转换为字符串。
    vars.ReadClassName = (Func<IntPtr, string>)(obj =>
    {
        if (obj == IntPtr.Zero) return "";
        IntPtr classPtr = vars.Resolver.Read<IntPtr>((IntPtr)((long)obj + 0x10));
        if (classPtr == IntPtr.Zero) return "";
        return vars.Utils.FNameToString(
            vars.Resolver.Read<ulong>((IntPtr)((long)classPtr + 0x18)));
    });

    // ReadUnrealFString 委托。
    // 入参：address，UE FString 结构地址。
    // 返回：UTF-16 字符串；指针、长度或数据无效时返回空字符串。
    // 原理：FString 在 +0x00 保存字符数据指针，在 +0x08 保存字符数量；
    // 这里把长度限制为 512，按 UTF-16 一次读取后去掉尾部 NUL。
    vars.ReadUnrealFString = (Func<IntPtr, string>)(address =>
    {
        if (address == IntPtr.Zero) return "";
        IntPtr data = vars.Resolver.Read<IntPtr>(address);
        int length = vars.Resolver.Read<int>((IntPtr)((long)address + 8));
        if (data == IntPtr.Zero || length <= 0 || length > 512) return "";
        byte[] raw = (byte[])vars.Resolver.ReadBytes(data, length * 2);
        if (raw == null || raw.Length == 0) return "";
        return System.Text.Encoding.Unicode.GetString(raw).TrimEnd('\0');
    });

    // ReadSequenceStatus 委托。
    // 入参：player，LevelSequencePlayer 地址。
    // 返回：player+0x288 的状态字节；指针为空时返回 0。
    // 原理：当前构建中 1 表示正在播放；其他值由调用方按“未播放”处理。
    vars.ReadSequenceStatus = (Func<IntPtr, byte>)(player =>
    {
        if (player == IntPtr.Zero) return 0;
        return vars.Resolver.Read<byte>((IntPtr)((long)player + 0x288));
    });

    // ReadCutsceneDisableCameraCuts 委托。
    // 入参：node，PlayLevelSequence 任务节点地址。
    // 返回：已知节点对应标志位的布尔值；未知类返回 true。
    // 原理：只有三个已经验证过的节点类可以安全换算标志位；未知节点返回 true，
    // 让上层忽略它，避免普通交互节点被误认为过场。
    vars.ReadCutsceneDisableCameraCuts = (Func<IntPtr, bool>)(node =>
    {
        string nodeClass = ((Func<IntPtr, string>)vars.ReadClassName)(node);
        if (nodeClass == "BAN_GSPlayLevelSequence")
            return (vars.Resolver.Read<byte>((IntPtr)((long)node + 0x62)) & 1) != 0;
        if (nodeClass == "BED_ProcessStateNode_PlayLevelSequence")
            return (vars.Resolver.Read<byte>((IntPtr)((long)node + 0x2B4)) & 1) != 0;
        if (nodeClass == "BED_QuestNode_PlayLevelSequence")
            return (vars.Resolver.Read<byte>((IntPtr)((long)node + 0x2C0)) & 1) != 0;

        // 未知类不主动暂停，避免普通交互节点造成误判。
        return true;
    });

    // 3. Boss Actor 读取委托。
    // ActorSeen 的 long[] 值布局：
    // [0] Actor 指针，[1] 首次观察时间，[2] 死亡 Montage 是否已触发。
    // FindAnimation 委托。
    // 入参：actor，Boss Actor 地址。
    // 返回：AnimInstance 地址；Actor、Mesh 或 AnimInstance 无效时返回 IntPtr.Zero。
    // 原理：先尝试 Actor+0x308 的直连 Mesh，再尝试 Actor+0x620 的
    // ACharacterComponent 组件数组；两种路径最终都从 Mesh+0x850 读取 AnimInstance。
    vars.FindAnimation = (Func<IntPtr, IntPtr>)(actor =>
    {
        IntPtr mesh = vars.Resolver.Read<IntPtr>((IntPtr)((long)actor + 0x308));
        IntPtr anim = mesh == IntPtr.Zero
            ? IntPtr.Zero
            : vars.Resolver.Read<IntPtr>((IntPtr)((long)mesh + 0x850));
        if (anim != IntPtr.Zero) return anim;

        // 部分 Boss 的 Mesh 挂在 ACharacterComponent 上，而不是 Actor 直连字段。
        IntPtr dataComp = vars.Resolver.Read<IntPtr>((IntPtr)((long)actor + 0x620));
        if (dataComp == IntPtr.Zero) return IntPtr.Zero;
        IntPtr componentItems = vars.Resolver.Read<IntPtr>((IntPtr)((long)dataComp + 0xC0));
        int componentCount = vars.Resolver.Read<int>((IntPtr)((long)dataComp + 0xC8));
        if (componentItems == IntPtr.Zero || componentCount <= 0 || componentCount > 64)
            return IntPtr.Zero;

        for (int index = 0; index < componentCount; index++)
        {
            IntPtr component = vars.Resolver.Read<IntPtr>(
                (IntPtr)((long)componentItems + index * 8));
            if (component == IntPtr.Zero) continue;
            string componentClass = ((Func<IntPtr, string>)vars.ReadClassName)(component);
            if (!componentClass.Contains("ACharacterComponent")) continue;

            mesh = vars.Resolver.Read<IntPtr>((IntPtr)((long)component + 0x40));
            anim = mesh == IntPtr.Zero
                ? IntPtr.Zero
                : vars.Resolver.Read<IntPtr>((IntPtr)((long)mesh + 0x850));
            if (anim != IntPtr.Zero) return anim;
        }
        return IntPtr.Zero;
    });

    // HasDeathMontage 委托。
    // 入参：anim，AnimInstance 地址。
    // 返回：当前 Montage 数组中是否存在死亡类 Montage。
    // 原理：AnimInstance+0x88 是 Montage 指针数组，+0x90 是数量；每个元素
    // 按 0x1C8 步长读取，再从 Montage+0x18 解出 FName。名称包含 _die、
    // _dead、death 或 suicide 时视为死亡 Montage。
    vars.HasDeathMontage = (Func<IntPtr, bool>)(anim =>
    {
        if (anim == IntPtr.Zero) return false;
        IntPtr montages = vars.Resolver.Read<IntPtr>((IntPtr)((long)anim + 0x88));
        int montageCount = vars.Resolver.Read<int>((IntPtr)((long)anim + 0x90));
        if (montages == IntPtr.Zero || montageCount <= 0 || montageCount > 16)
            return false;

        for (int index = 0; index < montageCount; index++)
        {
            IntPtr montage = vars.Resolver.Read<IntPtr>(
                (IntPtr)((long)montages + index * 0x1C8));
            if (montage == IntPtr.Zero) continue;
            string montageName = vars.Utils.FNameToString(
                vars.Resolver.Read<ulong>((IntPtr)((long)montage + 0x18)));
            if (string.IsNullOrEmpty(montageName)) continue;

            string lowerName = montageName.ToLowerInvariant();
            if (lowerName.Contains("_die")
                || lowerName.Contains("_dead")
                || lowerName.Contains("death")
                || lowerName.Contains("suicide"))
            {
                return true;
            }
        }
        return false;
    });

    // 4. 设置读取、双 Boss 配置和打点队列。
    // 这些集合和字典在 init 创建，之后只修改内容，避免 update 中反复分配容器。
    // CompletedSplits：已完成/已入队的设置 id；保证单次尝试最多打一次。
    // ActorSeen：uid -> [Actor 指针, 首次观察 ticks, 死亡 Montage 是否已触发]。
    // PendingSplits：等待 split 钩子消费的设置 id 队列。
    // ObservedActors：上一轮扫描到的 UGuid Actor 集合，用于生成出现/消失边沿。
    // DualSplits：Dual_ 设置 id -> 两个 UGuid。
    // DualSettingsByActor：UGuid -> 包含该 Actor 的 Dual_ 设置列表。
    // DualMontageHits：Dual_ 设置 id -> 已出现死亡 Montage 的 UGuid 集合。
    vars.CompletedSplits = new HashSet<string>();
    vars.ActorSeen = new Dictionary<string, long[]>();
    vars.PendingSplits = new Queue<string>();
    vars.ObservedActors = new HashSet<string>();
    vars.DualSplits = new Dictionary<string, string[]>();
    vars.DualSettingsByActor = new Dictionary<string, List<string>>();
    vars.DualMontageHits = new Dictionary<string, HashSet<string>>();

    // IsSettingEnabled 委托。
    // 入参：id 是设置键，defaultValue 是键缺失或读取异常时的回退值。
    // 返回：最终布尔值；不会把异常抛给 update。
    // 原理：ASL 设置由 LiveSplit 动态字典提供，使用 ContainsKey 区分缺失和 false。
    vars.IsSettingEnabled = (Func<string, bool, bool>)((id, defaultValue) =>
    {
        try
        {
            return settings.ContainsKey(id) ? (bool)settings[id] : defaultValue;
        }
        catch
        {
            return defaultValue;
        }
    });

    // IsAutoSplitEnabled 委托。
    // 入参：无。
    // 返回：AutoSplitEnabled 的设置值；缺失时返回 false。
    // 原理：自动打点总开关必须默认关闭，避免首次安装后无意打点。
    vars.IsAutoSplitEnabled = (Func<bool>)(() =>
        ((Func<string, bool, bool>)vars.IsSettingEnabled)("AutoSplitEnabled", false));

    // GetActorSetting 委托。
    // 入参：uid，由 UGuid Actor 名称转换出的 Boss 唯一键。
    // 返回：优先存在的 Despawn_ 或 Montage_ 设置；两者都不存在时返回 Dead_ 键。
    // 原理：同一 Actor 只能使用一种打点语义，因此优先级固定为
    // Despawn_ > Montage_ > Dead_。返回的 Dead_ 键仍可能不在 XML 中，
    // 调用方必须再用 settings.ContainsKey 判断是否跟踪。
    vars.GetActorSetting = (Func<string, string>)(uid =>
    {
        string despawnSetting = "Despawn_" + uid;
        if (settings.ContainsKey(despawnSetting)) return despawnSetting;

        string montageSetting = "Montage_" + uid;
        if (settings.ContainsKey(montageSetting)) return montageSetting;

        return "Dead_" + uid;
    });

    // LoadDualSplits 委托。
    // 入参：无，使用 startup 保存的 vars.SettingsPath。
    // 返回：void；非法 Dual_ 项只记录日志并跳过，不中断其余配置。
    // 原理：配置格式固定为 Dual_UGuid.A+UGuid.B，只在 init 读取 XML 一次。
    // 解析时校验两段 UID、拒绝重复和自身组合，再同时填充：
    // DualSplits、DualMontageHits 和 DualSettingsByActor。
    vars.LoadDualSplits = (Action)(() =>
    {
        System.Xml.XmlDocument document = new System.Xml.XmlDocument();
        document.Load((string)vars.SettingsPath);
        foreach (System.Xml.XmlNode node in document.SelectNodes(
            "//Setting[starts-with(@Id, 'Dual_')]"))
        {
            string setting = node.Attributes["Id"].Value;
            string[] uids = setting.Substring("Dual_".Length).Split('+');
            if (uids.Length != 2)
            {
                ((Action<string>)vars.Log)(
                    "[BMW-splitter] invalid dual setting: " + setting);
                continue;
            }

            uids[0] = uids[0].Trim();
            uids[1] = uids[1].Trim();
            if (uids[0] == uids[1]
                || !uids[0].StartsWith("UGuid.", StringComparison.Ordinal)
                || !uids[1].StartsWith("UGuid.", StringComparison.Ordinal))
            {
                ((Action<string>)vars.Log)(
                    "[BMW-splitter] invalid dual setting: " + setting);
                continue;
            }

            Dictionary<string, string[]> dualSplits =
                (Dictionary<string, string[]>)vars.DualSplits;
            if (dualSplits.ContainsKey(setting)) continue;
            dualSplits[setting] = uids;
            ((Dictionary<string, HashSet<string>>)vars.DualMontageHits)[setting] =
                new HashSet<string>();

            foreach (string uid in uids)
            {
                Dictionary<string, List<string>> settingsByActor =
                    (Dictionary<string, List<string>>)vars.DualSettingsByActor;
                List<string> settingIds;
                if (!settingsByActor.TryGetValue(uid, out settingIds))
                {
                    settingIds = new List<string>();
                    settingsByActor[uid] = settingIds;
                }
                settingIds.Add(setting);
            }
        }
    });
    vars.LoadDualSplits();

    // TryQueueSetting 委托。
    // 入参：setting 是最终设置 id，source 是 death-montage/slow-motion/despawn/
    // dual-montage 等打点来源文本。
    // 返回：成功入队时 true；总开关关闭、计时器未 Running、单项关闭或已处理时 false。
    // 原理：先通过所有启用条件，再把设置 id 加入 CompletedSplits，最后放入
    // PendingSplits。CompletedSplits 在入队前更新，因此同一设置不会重复排队。
    vars.TryQueueSetting = (Func<string, string, bool>)((setting, source) =>
    {
        if (!((Func<bool>)vars.IsAutoSplitEnabled)()) return false;
        if (timer.CurrentPhase != TimerPhase.Running) return false;
        if (!((Func<string, bool, bool>)vars.IsSettingEnabled)(setting, false))
            return false;
        if (!((HashSet<string>)vars.CompletedSplits).Add(setting)) return false;

        ((Queue<string>)vars.PendingSplits).Enqueue(setting);
        ((Action<string>)vars.Log)(
            "[BMW-splitter] split queued: setting=" + setting + " source=" + source);
        return true;
    });

    // TryQueueSplit 委托。
    // 入参：uid 是 Boss 唯一键，source 是本次打点来源文本。
    // 返回：映射后的设置成功交给 TryQueueSetting 时为 true，否则 false。
    // 原理：先按 Despawn_ > Montage_ > Dead_ 映射设置，再按前缀过滤来源：
    // Dead_* 接受死亡 Montage 和单 Boss 慢动作；Montage_* 只接受死亡 Montage；
    // Despawn_* 只接受 despawn。Dual_* 不经过这里，避免单个 Boss 提前触发。
    vars.TryQueueSplit = (Func<string, string, bool>)((uid, source) =>
    {
        string setting = ((Func<string, string>)vars.GetActorSetting)(uid);
        if (!((Func<string, bool, bool>)vars.IsSettingEnabled)(setting, false))
            return false;
        if (source != "despawn"
            && setting.StartsWith("Despawn_", StringComparison.Ordinal))
            return false;
        if (source != "death-montage"
            && setting.StartsWith("Montage_", StringComparison.Ordinal))
            return false;

        return ((Func<string, string, bool>)vars.TryQueueSetting)(setting, source);
    });

    // RegisterDualMontage 委托。
    // 入参：uid，刚刚出现死亡 Montage 的 Boss 唯一键。
    // 返回：该 uid 是否属于至少一个 Dual_ 配置；与最终是否成功入队无关。
    // 原理：把 uid 写入每个相关 Dual_ 设置的命中集合，两个指定 UID 都命中后
    // 才调用 TryQueueSetting。一个 Actor 可同时参与多个 Dual_ 配置。
    vars.RegisterDualMontage = (Func<string, bool>)(uid =>
    {
        List<string> dualSettings;
        if (!((Dictionary<string, List<string>>)vars.DualSettingsByActor)
            .TryGetValue(uid, out dualSettings))
        {
            return false;
        }

        foreach (string setting in dualSettings)
        {
            if (((HashSet<string>)vars.CompletedSplits).Contains(setting)) continue;

            string[] pair;
            if (!((Dictionary<string, string[]>)vars.DualSplits)
                .TryGetValue(setting, out pair))
            {
                continue;
            }

            Dictionary<string, HashSet<string>> dualHits =
                (Dictionary<string, HashSet<string>>)vars.DualMontageHits;
            HashSet<string> hits;
            if (!dualHits.TryGetValue(setting, out hits))
            {
                hits = new HashSet<string>();
                dualHits[setting] = hits;
            }
            hits.Add(uid);
            if (hits.Contains(pair[0]) && hits.Contains(pair[1]))
            {
                ((Func<string, string, bool>)vars.TryQueueSetting)(
                    setting,
                    "dual-montage");
            }
        }
        return true;
    });

    // ResetDualActor 委托。
    // 入参：uid，需要清除双 Boss 进度的 Boss 唯一键。
    // 返回：void。
    // 原理：同一 UID 的 Actor 指针变化说明实例已重建，旧实例的 Montage 命中
    // 不能沿用到新实例；只删除该 UID 在相关 Dual_ 集合中的记录。
    vars.ResetDualActor = (Action<string>)(uid =>
    {
        List<string> dualSettings;
        if (((Dictionary<string, List<string>>)vars.DualSettingsByActor)
            .TryGetValue(uid, out dualSettings))
        {
            foreach (string setting in dualSettings)
            {
                HashSet<string> hits;
                if (((Dictionary<string, HashSet<string>>)vars.DualMontageHits)
                    .TryGetValue(setting, out hits))
                {
                    hits.Remove(uid);
                }
            }
        }
    });

    // ClearActorTracking 委托。
    // 入参：无。
    // 返回：void。
    // 原理：世界切换或 GWorld 失效时，所有 Actor 指针和出现边沿都已失去意义；
    // 这里替换 ActorSeen/ObservedActors，并为每个 Dual_ 设置重建空命中集合。
    vars.ClearActorTracking = (Action)(() =>
    {
        vars.ActorSeen = new Dictionary<string, long[]>();
        vars.ObservedActors = new HashSet<string>();
        Dictionary<string, HashSet<string>> dualHits =
            (Dictionary<string, HashSet<string>>)vars.DualMontageHits;
        foreach (string setting in ((Dictionary<string, string[]>)vars.DualSplits).Keys)
            dualHits[setting] = new HashSet<string>();
        vars.LastSlowMotion = false;
    });

    // ResetSession 委托。
    // 入参：无。
    // 返回：void。
    // 原理：一次计时尝试的状态必须全部归零，包括已完成设置、Actor 观测、
    // 双 Boss 命中、待处理队列和扫描节流；StartArmed 也在这里清除。
    vars.ResetSession = (Action)(() =>
    {
        ((HashSet<string>)vars.CompletedSplits).Clear();
        ((Action)vars.ClearActorTracking)();
        vars.PendingSplits = new Queue<string>();
        vars.NextActorScanTicks = 0L;
        vars.StartArmed = false;
    });

    // 5. 扫描节流和判定窗口。
    // ScanIntervalTicks：Actor 扫描的最小间隔，固定 50ms，避免逐帧遍历世界。
    // MinBossActorSeenTicks：Actor 必须持续存在 1500ms 才允许死亡/慢动作判定。
    // NextActorScanTicks：下一次允许扫描的 UTC ticks；0 表示立即可扫描。
    // LastUpdateErrorTicks：update 异常日志限频，最多每秒一条。
    // LastSlowMotion：上一轮慢动作布尔值，用于只处理 false -> true 边沿。
    // LastLoading / NativeLoadingPending：缓存 loading 状态并驱动状态切换日志。
    // StartArmed：从 Startup 菜单世界进入 MGD 时自动开始的武装位。
    // LastWorld / LastWorldPtr：上一轮世界名和地址，用于识别世界代际变化。
    vars.ScanIntervalTicks = TimeSpan.TicksPerMillisecond * 50;
    vars.MinBossActorSeenTicks = TimeSpan.TicksPerMillisecond * 1500;
    vars.NextActorScanTicks = 0L;
    vars.LastUpdateErrorTicks = 0L;
    vars.LastSlowMotion = false;
    vars.LastLoading = false;
    vars.NativeLoadingPending = false;
    vars.StartArmed = false;
    vars.LastWorld = "";
    vars.LastWorldPtr = IntPtr.Zero;

    // current.World 是 update 生成的当前世界名；WorldPending 表示该世界不能用于
    // Boss 扫描或尚未完成原生加载。初始值按“仍在加载”处理，失败时保持暂停。
    current.World = "";
    current.WorldPending = true;

    // 6. 过场和 Bink 状态。
    // FunctionFlag 记录事件边沿，FunctionParentPtr 暴露触发函数所属对象；
    // InstancePtr 捕获没有稳定 Play/Stop 边沿时仍可轮询的 Sequence Actor。
    vars.Events.FunctionFlag("CutsceneNotifyFlag", "*PlayLevelSequence*", null, null);
    vars.Events.FunctionParentPtr<IntPtr>("CutsceneNotify", "*PlayLevelSequence*", null, null);

    vars.Events.FunctionFlag("SeqPlayerPlayFlag", "*LevelSequencePlayer*", null, "Play");
    vars.Events.FunctionParentPtr<IntPtr>("SeqPlayerPlayInstance", "*LevelSequencePlayer*", null, "Play");
    vars.Events.FunctionFlag("SeqPlayerStopFlag", "*LevelSequencePlayer*", null, "Stop");
    vars.Events.FunctionParentPtr<IntPtr>("SeqPlayerStopInstance", "*LevelSequencePlayer*", null, "Stop");

    vars.Events.FunctionFlag("BinkPlayFlag", "BinkMediaPlayer", null, "Play");
    vars.Events.FunctionParentPtr<IntPtr>("BinkPlayInstance", "BinkMediaPlayer", null, "Play");
    vars.Events.FunctionFlag("BinkStopFlag", "BinkMediaPlayer", null, "Stop");
    vars.Events.FunctionParentPtr<IntPtr>("BinkStopInstance", "BinkMediaPlayer", null, "Stop");

    IntPtr cutsceneActorSlot = vars.Events.InstancePtr("CalliopeLevelSequenceActor", null);
    if (cutsceneActorSlot != IntPtr.Zero)
        vars.Resolver.Watch<IntPtr>("CutsceneActor", cutsceneActorSlot);

    IntPtr bguSequenceActorSlot = vars.Events.InstancePtr("BGULevelSequenceActor", null);
    if (bguSequenceActorSlot != IntPtr.Zero)
        vars.Resolver.Watch<IntPtr>("BguSequenceActor", bguSequenceActorSlot);

    // CutscenePending：过场/视频正在播放，供 isLoading 暂停 Game Time。
    // CutsceneLastSignalTicks：最后一个有效的播放或结束信号时间。
    // CutsceneHoldTicks：所有播放器都结束后仍保持过场状态的 500ms 容错窗。
    // BinkEarlyStopGuardTicks：忽略 Bink Play 后 200ms 内的提前 Stop。
    // BinkPlayTicks：当前 Bink 的 Play 时间，用于识别章末提前 Stop。
    // ActiveSequencePlayer / ActiveBinkPlayer：当前正在跟踪的播放器指针。
    vars.CutscenePending = false;
    vars.CutsceneLastSignalTicks = 0L;
    vars.CutsceneHoldTicks = TimeSpan.TicksPerMillisecond * 500;
    vars.BinkEarlyStopGuardTicks = TimeSpan.TicksPerMillisecond * 200;
    vars.BinkPlayTicks = 0L;
    vars.ActiveSequencePlayer = IntPtr.Zero;
    vars.ActiveBinkPlayer = IntPtr.Zero;

    // current 中的 Hook 结果是 uHara 每轮写入的边沿/对象快照；每轮读取前先给出
    // 明确的空值，避免 ASL 动态对象在首次调用时缺少字段。
    current.CutsceneNotify = IntPtr.Zero;
    current.SeqPlayerPlayInstance = IntPtr.Zero;
    current.SeqPlayerStopInstance = IntPtr.Zero;
    current.BinkPlayInstance = IntPtr.Zero;
    current.BinkStopInstance = IntPtr.Zero;
    current.CutsceneActor = IntPtr.Zero;
    current.BguSequenceActor = IntPtr.Zero;

    // UpdateCutsceneHooks 委托。
    // 入参：无，读取 vars.Events 的 Hook 标志和 current 中的对象快照。
    // 返回：void。
    // 原理：只处理真正的 Play/Stop/状态变化；Sequence 状态和 Actor 备用路径
    // 持续续期当前信号，所有播放器结束后再由 CutsceneHoldTicks 延迟清除。
    vars.UpdateCutsceneHooks = (Action)(() =>
    {
        long nowTicks = DateTime.UtcNow.Ticks;
        bool wasPending = (bool)vars.CutscenePending;

        // PlayLevelSequence 通知只作为粗信号；已知节点还要通过类相关标志位过滤，
        // 未知节点会在 ReadCutsceneDisableCameraCuts 中返回 true 并被忽略。
        if (vars.Resolver.CheckFlag("CutsceneNotifyFlag"))
        {
            IntPtr node = (IntPtr)current.CutsceneNotify;
            if (node != IntPtr.Zero
                && !((Func<IntPtr, bool>)vars.ReadCutsceneDisableCameraCuts)(node))
            {
                vars.CutscenePending = true;
                vars.CutsceneLastSignalTicks = nowTicks;
            }
        }

        // SequencePlayer.Play 是主过场信号：状态字节为 1，且名称包含 LS_/cpt/CG/Seq
        // 时才锁存。名称过滤避免暂停页或普通动画序列被误当成剧情过场。
        if (vars.Resolver.CheckFlag("SeqPlayerPlayFlag"))
        {
            IntPtr player = (IntPtr)current.SeqPlayerPlayInstance;
            if (player != IntPtr.Zero)
            {
                byte status = ((Func<IntPtr, byte>)vars.ReadSequenceStatus)(player);
                IntPtr sequenceAsset = vars.Resolver.Read<IntPtr>(
                    (IntPtr)((long)player + 0x290));
                string sequenceName = sequenceAsset == IntPtr.Zero
                    ? ""
                    : vars.Utils.FNameToString(
                        vars.Resolver.Read<ulong>((IntPtr)((long)sequenceAsset + 0x18)));
                bool cutsceneSequence = sequenceName.IndexOf(
                        "LS_", StringComparison.OrdinalIgnoreCase) >= 0
                    || sequenceName.IndexOf("cpt", StringComparison.OrdinalIgnoreCase) >= 0
                    || sequenceName.IndexOf("CG", StringComparison.OrdinalIgnoreCase) >= 0
                    || sequenceName.IndexOf("Seq", StringComparison.OrdinalIgnoreCase) >= 0;

                vars.ActiveSequencePlayer = player;
                if (status == 1 && cutsceneSequence)
                {
                    vars.CutscenePending = true;
                    vars.CutsceneLastSignalTicks = nowTicks;
                }
            }
        }

        // SequencePlayer.Stop 只能结束同一个活动播放器，防止旧播放器的延迟 Stop
        // 清掉新一轮过场；结束时间用于启动 500ms 容错窗。
        if (vars.Resolver.CheckFlag("SeqPlayerStopFlag"))
        {
            IntPtr player = (IntPtr)current.SeqPlayerStopInstance;
            IntPtr activePlayer = (IntPtr)vars.ActiveSequencePlayer;
            if (player != IntPtr.Zero && player == activePlayer)
            {
                vars.ActiveSequencePlayer = IntPtr.Zero;
                vars.CutsceneLastSignalTicks = nowTicks;
            }
        }

        // Bink Play 同时读取 URL 和对象名。只要 URL 非空或名称包含 _Seq，就按
        // 过场视频处理；记录播放器指针和 Play 时间供 Stop 去重与提前 Stop 判断。
        if (vars.Resolver.CheckFlag("BinkPlayFlag"))
        {
            IntPtr bink = (IntPtr)current.BinkPlayInstance;
            if (bink != IntPtr.Zero)
            {
                string binkName = vars.Utils.FNameToString(
                    vars.Resolver.Read<ulong>((IntPtr)((long)bink + 0x18)));
                string binkUrl = ((Func<IntPtr, string>)vars.ReadUnrealFString)(
                    (IntPtr)((long)bink + 0x98));
                bool sequenceVideo = !string.IsNullOrEmpty(binkUrl)
                    || binkName.IndexOf("_Seq", StringComparison.OrdinalIgnoreCase) >= 0;
                if (sequenceVideo)
                {
                    vars.CutscenePending = true;
                    vars.CutsceneLastSignalTicks = nowTicks;
                    vars.ActiveBinkPlayer = bink;
                    vars.BinkPlayTicks = nowTicks;
                }
            }
        }

        // 章末 Bink 会先发一个固定/提前 Stop，视频真正结束后再发第二次 Stop。
        // 只接受匹配当前活动 Bink 且超过 BinkEarlyStopGuardTicks 的 Stop。
        if (vars.Resolver.CheckFlag("BinkStopFlag"))
        {
            IntPtr bink = (IntPtr)current.BinkStopInstance;
            IntPtr activeBink = (IntPtr)vars.ActiveBinkPlayer;
            bool matchesActive = bink != IntPtr.Zero && bink == activeBink;
            long stopElapsed = matchesActive
                ? nowTicks - (long)vars.BinkPlayTicks
                : 0L;
            bool earlyStop = matchesActive
                && stopElapsed <= (long)vars.BinkEarlyStopGuardTicks;

            // 章末 Bink 会先发一个固定 Stop，真正的 Stop 在视频结束后。
            if (matchesActive && !earlyStop)
            {
                vars.ActiveBinkPlayer = IntPtr.Zero;
                vars.CutsceneLastSignalTicks = nowTicks;
            }
        }

        // Hook 边沿之间仍轮询活动 SequencePlayer 的状态：1 表示继续播放并续期，
        // 其他值立即结束活动播放器。这样可以覆盖没有可靠 Stop 回调的序列。
        IntPtr activeSequence = (IntPtr)vars.ActiveSequencePlayer;
        if (activeSequence != IntPtr.Zero)
        {
            byte status = ((Func<IntPtr, byte>)vars.ReadSequenceStatus)(activeSequence);
            if (status == 1)
            {
                vars.CutsceneLastSignalTicks = nowTicks;
            }
            else
            {
                vars.ActiveSequencePlayer = IntPtr.Zero;
                vars.CutsceneLastSignalTicks = nowTicks;
            }
        }

        // 部分任务过场只暴露 SequenceActor，没有可靠的 Play/Stop 事件。
        // 此时从 Actor+0x2B8 取其 SequencePlayer，状态为 1 时持续续期。
        IntPtr sequenceActor = (IntPtr)current.CutsceneActor;
        if (sequenceActor == IntPtr.Zero)
            sequenceActor = (IntPtr)current.BguSequenceActor;
        if (sequenceActor != IntPtr.Zero && (bool)vars.CutscenePending)
        {
            IntPtr player = vars.Resolver.Read<IntPtr>(
                (IntPtr)((long)sequenceActor + 0x2B8));
            if (player != IntPtr.Zero
                && ((Func<IntPtr, byte>)vars.ReadSequenceStatus)(player) == 1)
            {
                vars.ActiveSequencePlayer = player;
                vars.CutsceneLastSignalTicks = nowTicks;
            }
        }

        // 只有 SequencePlayer 和 BinkPlayer 都为空，且超过最后一个结束信号
        // 的容错窗时才清除 CutscenePending；这避免片段切换时短暂闪烁。
        if ((bool)vars.CutscenePending
            && (IntPtr)vars.ActiveSequencePlayer == IntPtr.Zero
            && (IntPtr)vars.ActiveBinkPlayer == IntPtr.Zero
            && nowTicks - (long)vars.CutsceneLastSignalTicks
                > (long)vars.CutsceneHoldTicks)
        {
            vars.CutscenePending = false;
        }

        if ((bool)vars.CutscenePending != wasPending)
        {
            ((Action<string>)vars.Log)(
                "[BMW-loading] cutscene loading: " + ((bool)vars.CutscenePending ? "playing" : "ended"));
        }
    });
}

// LiveSplit 生命周期钩子：update
// 作用：更新原生加载、过场状态和 50ms 一次的 Boss Actor 扫描，并把死亡
// Montage、单 Boss 慢动作和 Actor 消失边沿送入打点队列。
// 入参：current/old 状态字典、vars、timer 以及当前已绑定的游戏进程。
// 返回：正常路径返回 null；内部异常被捕获并限频记录，不会把异常抛给 LiveSplit。
// 原理：先读取不会失效的加载状态，再按节流门控解析世界和 Actor；所有空指针、
// 世界切换和非 gameplay 世界都以“本轮不做 Boss 打点”处理，失败时保持暂停。
update
{
    try
    {
        // uHara.Update 刷新 Hook 结果和解析委托状态；必须在读取 current 快照前调用。
        vars.Uhara.Update();

        // 原生加载状态通过 GetCurLoadingScreenState 的静态槽解析：
        // slot -> root，root+0x240 为 EGSLoadingScreenState，非 0 即仍在加载。
        // root 为空时按 Idle 处理，世界门控和 WorldPending 仍会兜底。
        IntPtr loadingRoot = vars.Resolver.Read<IntPtr>(vars.LoadingStateSlot);
        byte nativeLoadingState = loadingRoot == IntPtr.Zero
            ? (byte)0
            : vars.Resolver.Read<byte>((IntPtr)((long)loadingRoot + 0x240));
        vars.NativeLoadingPending = nativeLoadingState != 0;

        // 过场 Hook 和原生加载状态每轮都更新；Actor 扫描则严格限制为 50ms 一次。
        ((Action)vars.UpdateCutsceneHooks)();

        long nowTicks = DateTime.UtcNow.Ticks;
        if (nowTicks < (long)vars.NextActorScanTicks) return;
        vars.NextActorScanTicks = nowTicks + (long)vars.ScanIntervalTicks;

        // 世界解析失败时无法证明 Actor 指针仍属于同一世界，必须清空观测和缓存，
        // 并把 WorldPending 置为 true，让 isLoading 继续暂停 Game Time。
        IntPtr worldPtr = vars.Resolver.Read<IntPtr>(vars.Utils.GWorld);
        if (worldPtr == IntPtr.Zero)
        {
            current.World = "";
            current.WorldPending = true;
            ((Action)vars.ClearActorTracking)();
            vars.LastWorld = "";
            vars.LastWorldPtr = IntPtr.Zero;
            return;
        }

        string worldName = vars.Utils.FNameToString(
            vars.Resolver.Read<ulong>((IntPtr)((long)worldPtr + 0x18)));
        if (string.IsNullOrEmpty(worldName))
        {
            current.World = "";
            current.WorldPending = true;
            ((Action)vars.ClearActorTracking)();
            vars.LastWorld = "";
            vars.LastWorldPtr = IntPtr.Zero;
            return;
        }

        // 这些世界即使原生加载状态归零也不是可打点的 gameplay：
        // Startup 菜单、登录、设置、服务器检查和空世界都保持 WorldPending。
        bool worldPending = worldName.StartsWith("Startup", StringComparison.Ordinal)
            || worldName == "WXLogin_P"
            || worldName == "SetConfig_P"
            || worldName == "ServerCheck"
            || worldName == "None";

        // 世界名或 GWorld 地址变化代表对象代际已更换；清空 Actor 缓存和待处理点，
        // 但保留当前 Dual_ 配置。Startup 世界同时设置自动开始武装位。
        IntPtr previousWorldPtr = (IntPtr)vars.LastWorldPtr;
        string previousWorld = (string)vars.LastWorld;
        if (worldName != previousWorld || worldPtr != previousWorldPtr)
        {
            if (!string.IsNullOrEmpty(previousWorld))
            {
                ((Action<string>)vars.Log)(
                    "[BMW-loading] world changed: " + previousWorld + " -> " + worldName);
            }
            ((Action)vars.ClearActorTracking)();
            vars.PendingSplits = new Queue<string>();
            vars.LastWorld = worldName;
            vars.LastWorldPtr = worldPtr;
        }

        current.World = worldName;
        current.WorldPending = worldPending;
        if (worldName.StartsWith("Startup", StringComparison.Ordinal))
            vars.StartArmed = true;
        if (worldPending) return;

        // UWorld+0x30 -> ULevel；ULevel+0x98/+0xA0 是 Actor TArray 的指针/数量。
        // 数量上限 20000 是防损坏保护：异常值直接跳过本轮，避免越界读取。
        IntPtr levelPtr = vars.Resolver.Read<IntPtr>((IntPtr)((long)worldPtr + 0x30));
        if (levelPtr == IntPtr.Zero) return;

        IntPtr actors = vars.Resolver.Read<IntPtr>((IntPtr)((long)levelPtr + 0x98));
        int actorCount = vars.Resolver.Read<int>((IntPtr)((long)levelPtr + 0xA0));
        if (actors == IntPtr.Zero || actorCount <= 0 || actorCount > 20000) return;

        // 本轮扫描先把结果写入临时容器，扫描成功后再整体替换上一轮状态：
        // nextSeen 保存新的 ActorSeen，deathMontageSplits 保存本轮刚出现的死亡边沿，
        // slowMotionCandidates 保存允许使用慢动作信号的已启用普通 Boss。
        Dictionary<string, long[]> nextSeen = new Dictionary<string, long[]>();
        List<string> deathMontageSplits = new List<string>();
        List<string> slowMotionCandidates = new List<string>();
        HashSet<string> previousObservedActors = (HashSet<string>)vars.ObservedActors;
        HashSet<string> observedActors = new HashSet<string>();

        // 逐个读取 Actor 指针和对象名，只处理名称以 UGuid___ 开头的实体。
        // UID 规则：取 @ 前的名称，并把三个下划线替换为一个点。
        for (int index = 0; index < actorCount; index++)
        {
            IntPtr actor = vars.Resolver.Read<IntPtr>(
                (IntPtr)((long)actors + index * 8));
            if (actor == IntPtr.Zero) continue;

            string actorName = vars.Utils.FNameToString(
                vars.Resolver.Read<ulong>((IntPtr)((long)actor + 0x18)));
            if (string.IsNullOrEmpty(actorName)) continue;
            if (!actorName.StartsWith("UGuid___", StringComparison.Ordinal)) continue;

            string uid = actorName.Split('@')[0].Replace("___", ".");
            observedActors.Add(uid);

            if (!previousObservedActors.Contains(uid))
            {
                ((Action<string>)vars.Log)(
                    "[BMW-splitter] actor appeared: uid=" + uid
                    + " class=" + ((Func<IntPtr, string>)vars.ReadClassName)(actor)
                    + " actor=0x" + actor.ToString("X")
                    + " world=" + worldName);
            }

            // 出现/消失日志覆盖所有 UGuid；后续分割状态只跟踪已配置 Actor。
            // GetActorSetting 返回的是语义优先级，最终仍要检查 settings 中是否真实存在；
            // Dual_ 只通过 DualSettingsByActor 判断，不需要单 Actor 的 Dead_ 设置。
            string setting = ((Func<string, string>)vars.GetActorSetting)(uid);
            bool hasDualSetting = ((Dictionary<string, List<string>>)
                vars.DualSettingsByActor).ContainsKey(uid);
            if (!settings.ContainsKey(setting) && !hasDualSetting) continue;

            long[] previous;
            if (((Dictionary<string, long[]>)vars.ActorSeen).TryGetValue(uid, out previous)
                && previous[0] == (long)actor)
            {
                long previousDeathMontage = previous[2];
                long seenTicks = nowTicks - previous[1];

                // 同一 Actor 指针才复用上一轮缓存。死亡 Montage 一旦观测到就锁存，
                // 且只有持续存在超过 MinBossActorSeenTicks 后才允许检测，
                // 避免 Actor 刚生成时动画状态未就绪造成误判。
                IntPtr anim = ((Func<IntPtr, IntPtr>)vars.FindAnimation)(actor);
                long deathMontage = previousDeathMontage;
                if (deathMontage == 0L
                    && seenTicks >= (long)vars.MinBossActorSeenTicks
                    && ((Func<IntPtr, bool>)vars.HasDeathMontage)(anim))
                {
                    deathMontage = 1L;
                    deathMontageSplits.Add(uid);
                    ((Action<string>)vars.Log)(
                        "[BMW-splitter] death montage visible: uid=" + uid
                        + " setting=" + setting
                        + " enabled=" + ((Func<string, bool, bool>)vars.IsSettingEnabled)(setting, false)
                        + " dual=" + hasDualSetting
                        + " world=" + worldName);
                }

                // 只有已启用、非 Dual_、非 Despawn_、非 Montage_ 的普通 Boss
                // 才能成为单 Boss 慢动作候选；Dual_ 和专用前缀必须忽略该信号。
                if (seenTicks >= (long)vars.MinBossActorSeenTicks
                    && ((Func<string, bool, bool>)vars.IsSettingEnabled)(setting, false)
                    && !hasDualSetting
                    && !setting.StartsWith("Despawn_", StringComparison.Ordinal)
                    && !setting.StartsWith("Montage_", StringComparison.Ordinal))
                {
                    slowMotionCandidates.Add(uid);
                }

                nextSeen[uid] = new long[]
                {
                    (long)actor,
                    previous[1],
                    deathMontage
                };
            }
            else
            {
                // Actor 指针变化说明同一 UID 换成了新实例；清除旧实例的双 Boss
                // Montage 命中，并以当前时间重新开始 1500ms 观察窗口。
                ((Action<string>)vars.ResetDualActor)(uid);
                nextSeen[uid] = new long[]
                {
                    (long)actor,
                    nowTicks,
                    0L
                };
            }
        }

        foreach (string previousUid in previousObservedActors)
        {
            if (!observedActors.Contains(previousUid))
            {
                ((Action<string>)vars.Log)(
                    "[BMW-splitter] actor despawn observed: uid=" + previousUid
                    + " world=" + worldName);
            }
        }
        vars.ObservedActors = observedActors;

        // 读取世界设置和时间膨胀：ULevel+0x2A0 -> WorldSettings，
        // WorldSettings+0x3A8 读取 timeDilation（时间膨胀）。
        // 读取失败时按 1.0 处理，宁可漏掉一次慢动作边沿，也不把未知状态当击杀。
        IntPtr worldSettings = vars.Resolver.Read<IntPtr>(
            (IntPtr)((long)levelPtr + 0x2A0));
        float timeDilation = worldSettings == IntPtr.Zero
            ? 1.0f
            : vars.Resolver.Read<float>((IntPtr)((long)worldSettings + 0x3A8));
        // 识破/退寸约为 0.5，完美闪避不低于 0.3；击杀慢动作最低约 0.125。
        bool slowMotion = timeDilation > 0.001f && timeDilation < 0.16f;

        // 同周期先处理死亡 Montage，再处理极低时间膨胀的击杀慢动作。
        // Dual_ Actor 在这里只登记命中，不直接调用 TryQueueSplit；普通 Boss 才走
        // death-montage 来源。顺序固定可避免同一事件同时被两条路径重复入队。
        foreach (string uid in deathMontageSplits)
        {
            if (!((Dictionary<string, List<string>>)vars.DualSettingsByActor)
                .ContainsKey(uid))
            {
                ((Func<string, string, bool>)vars.TryQueueSplit)(
                    uid,
                    "death-montage");
            }
            ((Func<string, bool>)vars.RegisterDualMontage)(uid);
        }

        // 全局慢动作只在场上恰好有一个已启用 Boss 时使用，防止双 Boss 或
        // 召唤物同时在场时把同一死亡事件打给多个设置。
        if (slowMotion
            && !(bool)vars.LastSlowMotion
            && slowMotionCandidates.Count == 1)
        {
            ((Func<string, string, bool>)vars.TryQueueSplit)(
                slowMotionCandidates[0],
                "slow-motion");
        }
        vars.LastSlowMotion = slowMotion;

        // Despawn_* 只在已配置 Actor 真正从当前世界消失时打点。
        // 仅比较上一轮 ActorSeen 和本轮 nextSeen；仍要求观察满 1500ms，
        // 且只接受 Despawn_ 前缀，防止加载瞬态或旧实例被误打点。
        foreach (KeyValuePair<string, long[]> pair
            in (Dictionary<string, long[]>)vars.ActorSeen)
        {
            if (nextSeen.ContainsKey(pair.Key)) continue;

            long seenTicks = nowTicks - pair.Value[1];
            if (seenTicks < (long)vars.MinBossActorSeenTicks) continue;

            string setting = ((Func<string, string>)vars.GetActorSetting)(pair.Key);
            if (!setting.StartsWith("Despawn_", StringComparison.Ordinal)) continue;
            if (!((Func<string, bool, bool>)vars.IsSettingEnabled)(setting, false))
                continue;

            ((Func<string, string, bool>)vars.TryQueueSplit)(pair.Key, "despawn");
        }
        // 整轮 Actor 扫描和边沿收集成功后才提交新的观测快照；中途失败不会
        // 只更新一部分 ActorSeen，从而避免下一轮生成假的消失边沿。
        vars.ActorSeen = nextSeen;
    }
    // update 是全帧热路径：任何异常都只记录并结束本轮，不能传播到 LiveSplit
    // 的计时器线程；日志限频为每秒最多一条，避免持续坏指针刷盘。
    catch (Exception ex)
    {
        long errorTicks = DateTime.UtcNow.Ticks;
        if (errorTicks - (long)vars.LastUpdateErrorTicks >= TimeSpan.TicksPerSecond)
        {
            vars.LastUpdateErrorTicks = errorTicks;
            ((Action<string>)vars.Log)("[BMW-splitter] update error: " + ex.ToString());
        }
    }
}

// LiveSplit 生命周期钩子：start
// 作用：在 Startup 菜单已经出现后，首次进入 MGD_PersistentLevel 时自动开始计时。
// 入参：无；读取 update 维护的 vars.StartArmed 和 current.World。
// 返回：满足自动开始条件时 true，否则 false。
// 原理：StartArmed 只由 Startup 世界置位；命中 MGD 后立即消费武装位。
// 手动开始和 reset 都会清除它，因此同一菜单流程不会重复自动开始。
start
{
    if (!(bool)vars.StartArmed || current.World != "MGD_PersistentLevel")
        return false;

    vars.StartArmed = false;
    ((Action<string>)vars.Log)("[BMW-splitter] auto start: world=" + (string)current.World);
    return true;
}

// LiveSplit 生命周期钩子：split
// 作用：从 PendingSplits 中消费至多一个仍然启用的设置并触发打点。
// 入参：无；读取 timer、AutoSplitEnabled、PendingSplits 和单项设置。
// 返回：本次实际打点时为 true；总开关关闭、计时器未 Running 或队列无有效项时为 false。
// 原理：总开关关闭时清空整个队列；否则逐项出队并跳过已关闭设置，
// 一次调用最多返回一次 true，避免同一轮连续打多个点。
split
{
    if (!((Func<bool>)vars.IsAutoSplitEnabled)())
    {
        ((Queue<string>)vars.PendingSplits).Clear();
        return false;
    }
    if (timer.CurrentPhase != TimerPhase.Running) return false;

    Queue<string> pending = (Queue<string>)vars.PendingSplits;
    while (pending.Count > 0)
    {
        string setting = pending.Dequeue();
        if (((Func<string, bool, bool>)vars.IsSettingEnabled)(setting, false))
        {
            ((Action<string>)vars.Log)("[BMW-splitter] split: " + setting);
            return true;
        }
    }
    return false;
}

// LiveSplit 生命周期钩子：isLoading
// 作用：汇总世界切换、原生加载和过场状态，决定是否暂停 Game Time。
// 入参：无；读取 current.WorldPending、vars.NativeLoadingPending、
// RemoveCutscenes 设置和 vars.CutscenePending。
// 返回：任一加载来源有效时为 true，否则 false。
// 原理：只暂停 Game Time，不修改 Real Time；状态变化时记录一次日志，
// 便于区分世界加载、原生加载和过场加载。
isLoading
{
    bool worldLoading = (bool)current.WorldPending;
    bool nativeLoading = (bool)vars.NativeLoadingPending;
    bool cutsceneLoading =
        ((Func<string, bool, bool>)vars.IsSettingEnabled)("RemoveCutscenes", true)
        && (bool)vars.CutscenePending;
    bool loading = worldLoading || nativeLoading || cutsceneLoading;

    if (loading != (bool)vars.LastLoading)
    {
        vars.LastLoading = loading;
        ((Action<string>)vars.Log)(
            "[BMW-loading] isLoading=" + loading
            + " world=" + (string)current.World
            + " native=" + nativeLoading
            + " cutscene=" + cutsceneLoading);
    }
    return loading;
}

// LiveSplit 生命周期钩子：onStart
// 作用：开始新计时尝试时先暂停 Game Time，并清空上一轮的 Boss/双 Boss/队列状态。
// 入参：无。
// 返回：null。
// 原理：LiveSplit 会在 onStart 后继续调用 update/isLoading；先暂停可封住首拍漏计时，
// 后续由 isLoading 根据真实加载状态恢复。
onStart
{
    timer.IsGameTimePaused = true;
    ((Action)vars.ResetSession)();
}

// LiveSplit 生命周期钩子：onReset
// 作用：计时器重置时清空本次尝试的全部运行时打点状态。
// 入参：无。
// 返回：null。
// 原理：只重置状态，不主动改变启动前世界的暂停状态；下一次 isLoading 会重新计算。
onReset
{
    ((Action)vars.ResetSession)();
}

// LiveSplit 生命周期钩子：exit
// 作用：游戏进程退出时确保 Game Time 暂停，并记录退出事件。
// 入参：无。
// 返回：null。
// 原理：进程消失后 update 不再运行，先暂停可避免 LiveSplit 在错误状态下继续计时。
exit
{
    timer.IsGameTimePaused = true;
    ((Action<string>)vars.Log)("[BMW-splitter] game process exit");
}

// LiveSplit 生命周期钩子：shutdown
// 作用：脚本卸载时尽力清理本次尝试状态。
// 入参：无。
// 返回：null。
// 原理：shutdown 期间 LiveSplit 或 uHara 可能已经开始释放对象，因此用 try/catch
// 包住 ResetSession，避免清理异常阻止 LiveSplit 正常卸载脚本。
shutdown
{
    try { ((Action)vars.ResetSession)(); } catch {}
}

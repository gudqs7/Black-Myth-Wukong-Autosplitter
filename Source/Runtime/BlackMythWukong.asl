/*
 * Black Myth: Wukong LiveSplit 自动打点脚本（可编辑源码）。
 *
 * 源码规则:
 * - 本文件是唯一保留注释的位置；Components、发布包和本地 LiveSplit
 *   Components 均由 build_wukong_runtime.ps1 去除注释后生成。
 * - 生命周期钩子和每个委托都要说明作用、入参、返回值和大致原理；
 *   较长的状态处理段要说明数据来源、判定顺序和失败时的行为。
 * - 注释必须描述当前实现，不能把计划、猜测或已经删除的旧方案写成事实。
 *
 * 运行时约定:
 * - UGuid 是唯一可靠的 Boss 观察键；Boss_* 只保留给尚未完成 UGuid 映射的项。
 * - Dual_UGuid.A+UGuid.B 只在两个 Boss 都出现死亡 Montage 后打点。
 * - Montage_* 只接受死亡 Montage，Despawn_* 只接受 Actor 消失。
 * - Action_<UGuid>@<动作名> 只接受匹配的动作 Montage；动作名和可复制配置键来自 [BMW-action] 日志。
 * - isLoading 只暂停 Game Time，Real Time 始终由 LiveSplit 正常推进。
 */
state("b1-Win64-Shipping") {}
state("b1-WinGDK-Shipping") {}

// LiveSplit 生命周期钩子：startup
// 作用：加载 uHara 运行时、建立统一日志委托，并读取当前语言的 Boss 设置 XML。
// 入参：没有显式参数；LiveSplit 通过 ASL 注入设置构建器和 vars 容器。
// 返回：null。
// 原理：startup 在游戏进程出现前即可运行，因此设置必须在这里读取，才能让
// LiveSplit 设置面板立即出现；uHara 加载失败则直接抛出，避免后续用未初始化对象。
startup
{
    string componentDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Components");

    // 从组件目录加载独立的 uHara 副本。必须在创建 Log 委托前完成，因为所有
    // 黑猴日志统一交给 vars.Uhara.Log，避免再维护第二套文件日志路径。
    Assembly.Load(File.ReadAllBytes(Path.Combine(componentDir, "uhara10-BMW"))).CreateInstance("Main");

    // Log 委托。
    // 入参：message，已经格式化好的一行日志。
    // 返回：void；uHara 日志异常在内部吞掉。
    // 原理：日志统一写入 uHara 的日志目标；写日志失败不能中断计时。
    vars.Log = (Action<string>)(message =>
    {
        try
        {
            vars.Uhara.Log(
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff")
                + " " + message);
        }
        catch {}
    });

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

    // ReadSequenceStatus 委托。
    // 入参：player，LevelSequencePlayer 地址。
    // 返回：player+0x288 的状态字节；指针为空时返回 0。
    // 原理：当前构建中 1 表示正在播放；其他值由调用方按“未播放”处理。
    vars.ReadSequenceStatus = (Func<IntPtr, byte>)(player =>
    {
        if (player == IntPtr.Zero) return 0;
        return vars.Resolver.Read<byte>((IntPtr)((long)player + 0x288));
    });

    // ReadSequenceName 委托。
    // 入参：player，LevelSequencePlayer 地址。
    // 返回：player+0x290 指向的 Sequence 资产名称；失败时返回空字符串。
    vars.ReadSequenceName = (Func<IntPtr, string>)(player =>
    {
        if (player == IntPtr.Zero) return "";
        IntPtr sequenceAsset = vars.Resolver.Read<IntPtr>(
            (IntPtr)((long)player + 0x290));
        if (sequenceAsset == IntPtr.Zero) return "";
        return vars.Utils.FNameToString(
            vars.Resolver.Read<ulong>((IntPtr)((long)sequenceAsset + 0x18)));
    });

    // 3. Boss Actor 动作读取委托。
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

    // ReadActionNames 委托。
    // 入参：anim，AnimInstance 地址。
    // 返回：当前全部 Montage 数组中的动作名，按名称排序后用 | 连接；没有动作时为空串。
    // 原理：+0x88、+0x128、+0x138 各是一组活动 Montage 实例数组；每个元素
    // 按 0x1C8 步长读取，并兼容 item+0/item+0x18 两种 Montage 指针位置；
    // 再从 Montage+0x18 解出 FName。合并、去重和排序保证比较键稳定。
    vars.ReadActionNames = (Func<IntPtr, string>)(anim =>
    {
        if (anim == IntPtr.Zero) return "";

        // 当前构建有三组活动 Montage 实例数组：
        // +0x88 是常规主数组；灵虚子的攻击、BIdle 等动作会落在
        // +0x128/+0x138 的次级数组中。只读 +0x88 会在初见战斗阶段漏动作。
        int[] arrayOffsets = new int[] { 0x88, 0x128, 0x138 };
        int[] montagePointerOffsets = new int[] { 0x0, 0x18 };
        List<string> names = new List<string>();
        for (int arrayIndex = 0; arrayIndex < arrayOffsets.Length; arrayIndex++)
        {
            int arrayOffset = arrayOffsets[arrayIndex];
            IntPtr montages = vars.Resolver.Read<IntPtr>(
                (IntPtr)((long)anim + arrayOffset));
            int montageCount = vars.Resolver.Read<int>(
                (IntPtr)((long)anim + arrayOffset + 8));
            int montageCapacity = vars.Resolver.Read<int>(
                (IntPtr)((long)anim + arrayOffset + 12));
            if (montages == IntPtr.Zero
                || montageCount <= 0
                || montageCount > 16
                || montageCapacity < montageCount
                || montageCapacity > montageCount + 64)
                continue;

            for (int index = 0; index < montageCount; index++)
            {
                IntPtr item = (IntPtr)((long)montages + index * 0x1C8);
                IntPtr montage = IntPtr.Zero;
                string montageName = "";
                for (int pointerIndex = 0;
                    pointerIndex < montagePointerOffsets.Length;
                    pointerIndex++)
                {
                    int pointerOffset = montagePointerOffsets[pointerIndex];
                    IntPtr candidate = vars.Resolver.Read<IntPtr>(
                        (IntPtr)((long)item + pointerOffset));
                    if (candidate == IntPtr.Zero) continue;
                    string candidateClass =
                        ((Func<IntPtr, string>)vars.ReadClassName)(candidate);
                    if (string.IsNullOrEmpty(candidateClass)
                        || !candidateClass.Contains("AnimMontage"))
                        continue;
                    string candidateName = vars.Utils.FNameToString(
                        vars.Resolver.Read<ulong>((IntPtr)((long)candidate + 0x18)));
                    if (string.IsNullOrEmpty(candidateName)
                        || candidateName.Equals("None", StringComparison.OrdinalIgnoreCase))
                        continue;
                    montage = candidate;
                    montageName = candidateName;
                    break;
                }
                if (montage == IntPtr.Zero) continue;

                bool duplicate = false;
                for (int nameIndex = 0; nameIndex < names.Count; nameIndex++)
                {
                    if (names[nameIndex].Equals(montageName, StringComparison.OrdinalIgnoreCase))
                    {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) names.Add(montageName);
            }
        }

        names.Sort(StringComparer.OrdinalIgnoreCase);
        string result = "";
        for (int nameIndex = 0; nameIndex < names.Count; nameIndex++)
        {
            if (result.Length > 0) result += "|";
            result += names[nameIndex];
        }
        return result;
    });

    // IsDeathAction 委托。
    // 入参：actionNames，ReadActionNames 返回的当前动作集合。
    // 返回：动作集合中是否包含死亡类名称。
    // 原理：名称包含 _die、_dead、death 或 suicide 时视为死亡动作。
    vars.IsDeathAction = (Func<string, bool>)(actionNames =>
    {
        if (string.IsNullOrEmpty(actionNames)) return false;
        string lowerName = actionNames.ToLowerInvariant();
        return lowerName.Contains("_die")
            || lowerName.Contains("_dead")
            || lowerName.Contains("death")
            || lowerName.Contains("suicide");
    });

    // MatchAction 委托。
    // 入参：actionNames 是当前动作集合，pattern 是 Action_ 设置 @ 后面的动作名。
    // 返回：任一动作精确匹配（不区分大小写）时为 true；pattern 末尾 * 时按前缀匹配。
    // 原理：当前动作可能同时包含多个 Montage，因此逐个拆分比较；单独的 * 匹配
    // 任意非空动作，便于只观察某个 Actor 的第一个动作。
    vars.MatchAction = (Func<string, string, bool>)((actionNames, pattern) =>
    {
        if (string.IsNullOrEmpty(actionNames) || string.IsNullOrEmpty(pattern))
            return false;

        string[] actions = actionNames.Split('|');
        bool prefixMatch = pattern.EndsWith("*", StringComparison.Ordinal);
        string prefix = prefixMatch ? pattern.Substring(0, pattern.Length - 1) : pattern;
        for (int index = 0; index < actions.Length; index++)
        {
            if (pattern == "*") return true;
            if (prefixMatch
                && actions[index].StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
            if (!prefixMatch
                && actions[index].Equals(pattern, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        return false;
    });

    // BuildActionSettingList 委托。
    // 入参：uid 是 Actor 唯一键，actionNames 是当前动作集合。
    // 返回：可直接粘贴到 XML 的 Action_ 配置键，多个动作以逗号分隔。
    // 原理：Actor 消失日志和死亡 Montage 日志输出该字符串，用户无需手工拼接 UID 和动作名。
    vars.BuildActionSettingList = (Func<string, string, string>)((uid, actionNames) =>
    {
        if (string.IsNullOrEmpty(actionNames)) return "";
        string[] actions = actionNames.Split('|');
        string result = "";
        for (int index = 0; index < actions.Length; index++)
        {
            if (string.IsNullOrEmpty(actions[index])) continue;
            if (result.Length > 0) result += ",";
            result += "Action_" + uid + "@" + actions[index];
        }
        return result;
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
    // ActionSplitsByActor：UGuid -> 该 Actor 的 Action_ 设置 id 列表。
    // ActionSplitPatterns：Action_ 设置 id -> @ 后面的动作匹配模式。
    // ActorActionState：所有已见 UGuid -> [Actor 指针, 当前动作, 最后非空动作, 类名, 死亡动作已见]。
    vars.CompletedSplits = new HashSet<string>();
    vars.ActorSeen = new Dictionary<string, long[]>();
    vars.PendingSplits = new Queue<string>();
    vars.ObservedActors = new HashSet<string>();
    vars.DualSplits = new Dictionary<string, string[]>();
    vars.DualSettingsByActor = new Dictionary<string, List<string>>();
    vars.DualMontageHits = new Dictionary<string, HashSet<string>>();
    vars.ActionSplitsByActor = new Dictionary<string, List<string>>();
    vars.ActionSplitPatterns = new Dictionary<string, string>();
    vars.ActorActionState = new Dictionary<string, string[]>();

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

    // LoadActionSplits 委托。
    // 入参：无，使用 startup 保存的 vars.SettingsPath。
    // 返回：void；非法 Action_ 项只记录日志并跳过，不中断其余配置。
    // 原理：配置格式固定为 Action_UGuid.<Boss>@<动作名>；@ 后面也可使用末尾 *
    // 做前缀匹配，单独的 * 表示该 Actor 的任意非空动作。这里只解析一次 XML，
    // 同时建立 Actor -> 设置列表和设置 -> 动作模式两个索引供 update 使用。
    vars.LoadActionSplits = (Action)(() =>
    {
        System.Xml.XmlDocument document = new System.Xml.XmlDocument();
        document.Load((string)vars.SettingsPath);
        foreach (System.Xml.XmlNode node in document.SelectNodes(
            "//Setting[starts-with(@Id, 'Action_')]"))
        {
            string setting = node.Attributes["Id"].Value;
            int separator = setting.IndexOf('@', "Action_".Length);
            if (separator <= "Action_".Length
                || separator >= setting.Length - 1
                || setting.IndexOf('@', separator + 1) >= 0)
            {
                ((Action<string>)vars.Log)(
                    "[BMW-action] invalid action setting: " + setting);
                continue;
            }

            string uid = setting.Substring("Action_".Length, separator - "Action_".Length);
            string pattern = setting.Substring(separator + 1);
            if (!uid.StartsWith("UGuid.", StringComparison.Ordinal)
                || string.IsNullOrEmpty(pattern))
            {
                ((Action<string>)vars.Log)(
                    "[BMW-action] invalid action setting: " + setting);
                continue;
            }

            Dictionary<string, string> patterns =
                (Dictionary<string, string>)vars.ActionSplitPatterns;
            if (patterns.ContainsKey(setting)) continue;
            patterns[setting] = pattern;

            Dictionary<string, List<string>> settingsByActor =
                (Dictionary<string, List<string>>)vars.ActionSplitsByActor;
            List<string> settingIds;
            if (!settingsByActor.TryGetValue(uid, out settingIds))
            {
                settingIds = new List<string>();
                settingsByActor[uid] = settingIds;
            }
            settingIds.Add(setting);
        }
    });
    vars.LoadActionSplits();
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

    // TryQueueActionSplits 委托。
    // 入参：uid 是 Actor 唯一键，actionNames 是当前动作集合。
    // 返回：至少一个 Action_ 设置成功入队时为 true。
    // 原理：每个配置只匹配自己的动作模式；CompletedSplits 去重后同一个自定义
    // 动作打点在单次计时尝试中最多触发一次。
    vars.TryQueueActionSplits = (Func<string, string, bool>)((uid, actionNames) =>
    {
        List<string> settingIds;
        if (!((Dictionary<string, List<string>>)vars.ActionSplitsByActor)
            .TryGetValue(uid, out settingIds))
        {
            return false;
        }

        bool queued = false;
        foreach (string setting in settingIds)
        {
            if (((HashSet<string>)vars.CompletedSplits).Contains(setting)) continue;

            string pattern;
            if (!((Dictionary<string, string>)vars.ActionSplitPatterns)
                .TryGetValue(setting, out pattern))
            {
                continue;
            }
            if (!((Func<string, string, bool>)vars.MatchAction)(actionNames, pattern))
                continue;

            if (((Func<string, string, bool>)vars.TryQueueSetting)(
                setting,
                "action:" + pattern))
            {
                queued = true;
            }
        }
        return queued;
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
        vars.ActorActionState = new Dictionary<string, string[]>();
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

    // 6. 过场状态与 Bink 诊断日志。
    // FunctionFlag 记录事件边沿，FunctionParentPtr 暴露触发函数所属对象。
    // 只有 name=BinkMoviePlayer_Chapter 的章节末尾 Bink 参与 isLoading。
    vars.Events.FunctionFlag("SeqPlayerPlayFlag", "*LevelSequencePlayer*", null, "Play");
    vars.Events.FunctionParentPtr<IntPtr>("SeqPlayerPlayInstance", "*LevelSequencePlayer*", null, "Play");
    vars.Events.FunctionFlag("SeqPlayerStopFlag", "*LevelSequencePlayer*", null, "Stop");
    vars.Events.FunctionParentPtr<IntPtr>("SeqPlayerStopInstance", "*LevelSequencePlayer*", null, "Stop");
    vars.Events.FunctionFlag("SeqCameraCutsFlag", "*LevelSequencePlayer*", null, "SetDisableCameraCuts");
    vars.Events.FunctionParentPtr<IntPtr>("SeqCameraCutsInstance", "*LevelSequencePlayer*", null, "SetDisableCameraCuts");

    vars.Events.FunctionFlag("BinkPlayFlag", "BinkMediaPlayer", null, "Play");
    vars.Events.FunctionParentPtr<IntPtr>("BinkPlayInstance", "BinkMediaPlayer", null, "Play");
    vars.Events.FunctionFlag("BinkStopFlag", "BinkMediaPlayer", null, "Stop");
    vars.Events.FunctionParentPtr<IntPtr>("BinkStopInstance", "BinkMediaPlayer", null, "Stop");

    // CutscenePending：Sequence 或章节末尾 Bink 正在播放，供 isLoading 暂停
    // Game Time。章节末尾只按 name=BinkMoviePlayer_Chapter 判断。
    // BinkEarlyStopGuardTicks / BinkPlayTicks：识别章节末尾 Bink 的提前 Stop。
    // SeqCameraCutsGuardTicks：避免 Play 前同一帧的 SetDisableCameraCuts 立即结束。
    // ActiveSequencePlayTicks：当前 Sequence 的 Play 时间，用于 camera-cuts 去抖。
    // ActiveSequencePlayer / ActiveBinkPlayer：当前正在跟踪的播放器指针。
    vars.CutscenePending = false;
    vars.BinkEarlyStopGuardTicks = TimeSpan.TicksPerMillisecond * 200;
    vars.BinkPlayTicks = 0L;
    vars.SeqCameraCutsGuardTicks = TimeSpan.TicksPerMillisecond * 200;
    vars.ActiveSequencePlayTicks = 0L;
    vars.ActiveSequencePlayer = IntPtr.Zero;
    vars.ActiveBinkPlayer = IntPtr.Zero;

    // current 中的 Hook 结果是 uHara 每轮写入的边沿/对象快照；每轮读取前先给出
    // 明确的空值，避免 ASL 动态对象在首次调用时缺少字段。
    current.SeqPlayerPlayInstance = IntPtr.Zero;
    current.SeqPlayerStopInstance = IntPtr.Zero;
    current.SeqCameraCutsInstance = IntPtr.Zero;
    current.BinkPlayInstance = IntPtr.Zero;
    current.BinkStopInstance = IntPtr.Zero;

    // UpdateCutsceneHooks 委托。
    // 入参：无，读取 vars.Events 的 Hook 标志和 current 中的对象快照。
    // 返回：void。
    // 原理：Sequence 状态和 Actor 备用路径参与 CutscenePending；只有
    // BinkMoviePlayer_Chapter 会额外参与加载判断，其他 Bink 仅记录日志。
    vars.UpdateCutsceneHooks = (Action)(() =>
    {
        long nowTicks = DateTime.UtcNow.Ticks;
        // SequencePlayer.Play 是主过场信号：状态字节为 1，且名称包含 LS_/cpt/CG/Seq
        // 时才锁存。名称过滤避免暂停页或普通动画序列被误当成剧情过场。
        if (vars.Resolver.CheckFlag("SeqPlayerPlayFlag"))
        {
            IntPtr player = (IntPtr)current.SeqPlayerPlayInstance;
            if (player != IntPtr.Zero)
            {
                byte status = ((Func<IntPtr, byte>)vars.ReadSequenceStatus)(player);
                string sequenceName = ((Func<IntPtr, string>)vars.ReadSequenceName)(player);
                bool cutsceneSequence = sequenceName.IndexOf(
                        "LS_", StringComparison.OrdinalIgnoreCase) >= 0
                    || sequenceName.IndexOf("cpt", StringComparison.OrdinalIgnoreCase) >= 0
                    || sequenceName.IndexOf("CG", StringComparison.OrdinalIgnoreCase) >= 0
                    || sequenceName.IndexOf("Seq", StringComparison.OrdinalIgnoreCase) >= 0;
                bool participates = status == 1 && cutsceneSequence;

                vars.ActiveSequencePlayer = player;
                if (participates)
                {
                    vars.ActiveSequencePlayTicks = nowTicks;
                    vars.CutscenePending = true;
                }
                ((Action<string>)vars.Log)(
                    "[BMW-seq] play player=0x" + player.ToInt64().ToString("X")
                    + " status=" + status
                    + " cutscene=" + cutsceneSequence
                    + " participates=" + participates
                    + " name=" + sequenceName);
            }
        }

        // SequencePlayer.Stop 只能结束同一个活动播放器，防止旧播放器的延迟 Stop
        // 清掉新一轮过场；日志保留 player/active/match/status/name 便于排查。
        if (vars.Resolver.CheckFlag("SeqPlayerStopFlag"))
        {
            IntPtr player = (IntPtr)current.SeqPlayerStopInstance;
            IntPtr activePlayer = (IntPtr)vars.ActiveSequencePlayer;
            bool matchesActive = player != IntPtr.Zero && player == activePlayer;
            byte status = player == IntPtr.Zero
                ? (byte)0
                : ((Func<IntPtr, byte>)vars.ReadSequenceStatus)(player);
            string sequenceName = player == IntPtr.Zero
                ? ""
                : ((Func<IntPtr, string>)vars.ReadSequenceName)(player);
            ((Action<string>)vars.Log)(
                "[BMW-seq] stop player=0x" + player.ToInt64().ToString("X")
                + " active=0x" + activePlayer.ToInt64().ToString("X")
                + " match=" + matchesActive
                + " status=" + status
                + " name=" + sequenceName);
            if (matchesActive)
            {
                vars.ActiveSequencePlayer = IntPtr.Zero;
                ((Action<string>)vars.Log)(
                    "[BMW-seq] end reason=stop player=0x"
                    + player.ToInt64().ToString("X")
                    + " name=" + sequenceName);
            }
        }

        // DisableCameraCutsWithBlendOut 会在播放器真正 Stop 前把摄像机控制权交还玩家。
        // 同一活动中收到 SetDisableCameraCuts，并超过 Play 后的 200ms 去抖窗，即结束加载状态。
        if (vars.Resolver.CheckFlag("SeqCameraCutsFlag"))
        {
            IntPtr player = (IntPtr)current.SeqCameraCutsInstance;
            IntPtr activePlayer = (IntPtr)vars.ActiveSequencePlayer;
            bool matchesActive = player != IntPtr.Zero && player == activePlayer;
            long cameraCutsElapsed = matchesActive
                ? nowTicks - (long)vars.ActiveSequencePlayTicks
                : -1L;
            bool controlReturned = matchesActive
                && cameraCutsElapsed > (long)vars.SeqCameraCutsGuardTicks;
            string sequenceName = player == IntPtr.Zero
                ? ""
                : ((Func<IntPtr, string>)vars.ReadSequenceName)(player);
            ((Action<string>)vars.Log)(
                "[BMW-seq] camera-cuts player=0x" + player.ToInt64().ToString("X")
                + " active=0x" + activePlayer.ToInt64().ToString("X")
                + " match=" + matchesActive
                + " elapsedMs=" + cameraCutsElapsed
                + " controlReturned=" + controlReturned
                + " name=" + sequenceName);
            if (controlReturned)
            {
                vars.ActiveSequencePlayer = IntPtr.Zero;
                ((Action<string>)vars.Log)(
                    "[BMW-seq] end reason=camera-cuts player=0x"
                    + player.ToInt64().ToString("X")
                    + " elapsedMs=" + cameraCutsElapsed
                    + " name=" + sequenceName);
            }
        }

        // Bink 只有 name=BinkMoviePlayer_Chapter 的章节末尾才参与加载判断。
        // 普通 Bink 仍记录详细日志，但不修改 CutscenePending 或活动播放器。
        if (vars.Resolver.CheckFlag("BinkPlayFlag"))
        {
            IntPtr bink = (IntPtr)current.BinkPlayInstance;
            string binkName = "";
            if (bink != IntPtr.Zero)
            {
                binkName = vars.Utils.FNameToString(
                    vars.Resolver.Read<ulong>((IntPtr)((long)bink + 0x18)));
            }
            bool chapterEndBink = binkName == "BinkMoviePlayer_Chapter";
            ((Action<string>)vars.Log)(
                "[BMW-bink] play player=0x" + bink.ToInt64().ToString("X")
                + " chapter=" + chapterEndBink
                + " participates=" + chapterEndBink
                + " name=" + binkName);
            if (chapterEndBink)
            {
                vars.CutscenePending = true;
                vars.ActiveBinkPlayer = bink;
                vars.BinkPlayTicks = nowTicks;
            }
        }

        if (vars.Resolver.CheckFlag("BinkStopFlag"))
        {
            IntPtr bink = (IntPtr)current.BinkStopInstance;
            IntPtr activeBink = (IntPtr)vars.ActiveBinkPlayer;
            string binkName = "";
            if (bink != IntPtr.Zero)
            {
                binkName = vars.Utils.FNameToString(
                    vars.Resolver.Read<ulong>((IntPtr)((long)bink + 0x18)));
            }
            bool chapterEndBink = binkName == "BinkMoviePlayer_Chapter";
            bool matchesActive = bink != IntPtr.Zero && bink == activeBink;
            long stopElapsed = matchesActive
                ? nowTicks - (long)vars.BinkPlayTicks
                : -1L;
            bool earlyStop = matchesActive
                && chapterEndBink
                && stopElapsed >= 0
                && stopElapsed <= (long)vars.BinkEarlyStopGuardTicks;
            ((Action<string>)vars.Log)(
                "[BMW-bink] stop player=0x" + bink.ToInt64().ToString("X")
                + " active=0x" + activeBink.ToInt64().ToString("X")
                + " chapter=" + chapterEndBink
                + " match=" + matchesActive
                + " elapsedMs=" + stopElapsed
                + " earlyStop=" + earlyStop
                + " name=" + binkName);
            if (matchesActive && !earlyStop)
            {
                vars.ActiveBinkPlayer = IntPtr.Zero;
                ((Action<string>)vars.Log)(
                    "[BMW-bink] end reason=stop player=0x"
                    + bink.ToInt64().ToString("X")
                    + " elapsedMs=" + stopElapsed
                    + " name=" + binkName);
            }
        }

        // Hook 边沿之间仍轮询活动 SequencePlayer 的状态：1 表示继续播放，
        // 其他值立即结束活动播放器。这样可以覆盖没有可靠 Stop 回调的序列。
        IntPtr activeSequence = (IntPtr)vars.ActiveSequencePlayer;
        if (activeSequence != IntPtr.Zero)
        {
            byte status = ((Func<IntPtr, byte>)vars.ReadSequenceStatus)(activeSequence);
            if (status != 1)
            {
                string sequenceName = ((Func<IntPtr, string>)vars.ReadSequenceName)(
                    activeSequence);
                vars.ActiveSequencePlayer = IntPtr.Zero;
                ((Action<string>)vars.Log)(
                    "[BMW-seq] end reason=status player=0x"
                    + activeSequence.ToInt64().ToString("X")
                    + " status=" + status
                    + " name=" + sequenceName);
            }
        }

        // SequencePlayer 和章节末尾 BinkPlayer 都结束后立即清除 CutscenePending。
        // 普通 Bink 从未进入 ActiveBinkPlayer，因此不会影响此判定。
        if ((bool)vars.CutscenePending
            && (IntPtr)vars.ActiveSequencePlayer == IntPtr.Zero
            && (IntPtr)vars.ActiveBinkPlayer == IntPtr.Zero)
        {
            vars.CutscenePending = false;
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

            bool firstObserved = !previousObservedActors.Contains(uid);
            string actorClass = "";
            if (firstObserved)
            {
                actorClass = ((Func<IntPtr, string>)vars.ReadClassName)(actor);
                ((Action<string>)vars.Log)(
                    "[BMW-splitter] actor appeared: uid=" + uid
                    + " class=" + actorClass
                    + " actor=0x" + actor.ToString("X")
                    + " world=" + worldName);
            }

            // 动作观测覆盖所有 UGuid，不受 Dead_/Montage_/Despawn_ 配置限制。
            // ActorActionState 用 Actor 指针区分同 UID 的新实例；动作集合只在发生
            // 变化时写日志，但每个扫描周期仍用当前动作检查 Action_ 自定义打点。
            IntPtr anim = ((Func<IntPtr, IntPtr>)vars.FindAnimation)(actor);
            string actionNames = ((Func<IntPtr, string>)vars.ReadActionNames)(anim);
            bool deathAction = ((Func<string, bool>)vars.IsDeathAction)(actionNames);
            string actorKey = actor.ToString("X");
            Dictionary<string, string[]> actionStates =
                (Dictionary<string, string[]>)vars.ActorActionState;
            string[] actionState;
            bool sameActor = actionStates.TryGetValue(uid, out actionState)
                && actionState[0] == actorKey;
            string previousAction = sameActor ? actionState[1] : "";
            string lastNonEmptyAction = sameActor ? actionState[2] : "";
            bool deathActionSeen = sameActor && actionState[4] == "1";
            if (sameActor && string.IsNullOrEmpty(actorClass) && actionState.Length > 3)
                actorClass = actionState[3];

            if (!string.IsNullOrEmpty(actionNames))
                lastNonEmptyAction = actionNames;
            if (deathAction)
                deathActionSeen = true;

            // 只在动作集合变化时记录当前动作，避免每帧输出指针和数组详情。
            bool actionChanged = sameActor
                ? actionNames != previousAction
                : !string.IsNullOrEmpty(actionNames);
            if (actionChanged)
            {
                if (string.IsNullOrEmpty(actorClass))
                    actorClass = ((Func<IntPtr, string>)vars.ReadClassName)(actor);

                string currentAction = string.IsNullOrEmpty(actionNames)
                    ? "<none>" : actionNames;
                ((Action<string>)vars.Log)(
                    "[BMW-action] actor action changed: uid=" + uid
                    + " action=" + currentAction
                    + " deathAction=" + deathAction);
            }

            actionStates[uid] = new string[]
            {
                actorKey,
                actionNames,
                lastNonEmptyAction,
                actorClass,
                deathActionSeen ? "1" : "0"
            };

            ((Func<string, string, bool>)vars.TryQueueActionSplits)(uid, actionNames);
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
                long deathMontage = previousDeathMontage;
                if (deathMontage == 0L
                    && seenTicks >= (long)vars.MinBossActorSeenTicks
                    && deathAction)
                {
                    deathMontage = 1L;
                    deathMontageSplits.Add(uid);
                    ((Action<string>)vars.Log)(
                        "[BMW-splitter] death montage visible: uid=" + uid
                        + " setting=" + setting
                        + " enabled=" + ((Func<string, bool, bool>)vars.IsSettingEnabled)(setting, false)
                        + " dual=" + hasDualSetting
                        + " action=" + actionNames
                        + " custom=" + ((Func<string, string, string>)
                            vars.BuildActionSettingList)(uid, actionNames)
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
                string lastName = "<unknown>";
                string lastCurrent = "<unknown>";
                string lastClass = "<unknown>";
                string lastDeathAction = "unknown";
                string[] previousActionState;
                if (((Dictionary<string, string[]>)vars.ActorActionState)
                    .TryGetValue(previousUid, out previousActionState))
                {
                    lastCurrent = string.IsNullOrEmpty(previousActionState[1])
                        ? "<none>" : previousActionState[1];
                    lastName = string.IsNullOrEmpty(previousActionState[2])
                        ? "<none>" : previousActionState[2];
                    lastClass = string.IsNullOrEmpty(previousActionState[3])
                        ? "<none>" : previousActionState[3];
                    lastDeathAction = previousActionState[4] == "1" ? "true" : "false";
                }

                string lastActionNames = lastName == "<none>" ? "" : lastName;
                string lastCustomSettings = ((Func<string, string, string>)
                    vars.BuildActionSettingList)(previousUid, lastActionNames);
                if (string.IsNullOrEmpty(lastCustomSettings))
                    lastCustomSettings = "<none>";
                ((Action<string>)vars.Log)(
                    "[BMW-action] actor despawn: uid=" + previousUid
                    + " class=" + lastClass
                    + " current=" + lastCurrent
                    + " lastAction=" + lastName
                    + " deathActionSeen=" + lastDeathAction
                    + " custom=" + lastCustomSettings
                    + " world=" + worldName);
                ((Action<string>)vars.Log)(
                    "[BMW-splitter] actor despawn observed: uid=" + previousUid
                    + " world=" + worldName);
                ((Dictionary<string, string[]>)vars.ActorActionState).Remove(previousUid);
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

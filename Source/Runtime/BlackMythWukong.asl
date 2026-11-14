/*
 * Black Myth: Wukong LiveSplit 自动打点脚本（可编辑源码）。
 *
 * 源码规则:
 * - 本文件保留注释；Components、仓库根目录和本地 LiveSplit 中的运行时文件
 *   均由 build_wukong_runtime.ps1 去除注释后生成。
 * - UGuid 是唯一可靠的 Boss 观察键。Boss_* 设置暂时保留给尚未完成 UGuid
 *   映射的可选 Boss，运行时不会根据 Boss_* 直接打点。
 * - Dual_UGuid.A+UGuid.B 只在两个 Boss 都出现死亡 Montage 后打点。
 * - isLoading 只暂停 Game Time，不影响 Real Time。
 */
state("b1-Win64-Shipping") {}
state("b1-WinGDK-Shipping") {}

// LiveSplit 生命周期钩子：startup
// 作用：加载 uHara、日志和本地化设置。
// 原理：设置与游戏进程无关，脚本重载后立即读取，保证 ASL 设置面板可用。
startup
{
    string componentDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Components");

    // 日志只记录初始化、状态切换、实际打点和异常，避免逐帧写盘。
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

    try
    {
        Assembly.Load(File.ReadAllBytes(Path.Combine(componentDir, "uhara10-PBZ"))).CreateInstance("Main");
    }
    catch (Exception ex)
    {
        ((Action<string>)vars.Log)("[BMW-loading] uhara load failed: " + ex.ToString());
        throw;
    }

    // 设置解析顺序：完整区域名 -> 基础语言名 -> 简体中文默认文件。
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
// 作用：绑定游戏对象、创建读取委托、注册过场钩子，并初始化本次运行状态。
// 原理：固定偏移只对当前游戏构建有效；所有跨 update 的状态都放在 vars 中。
init
{
    // 1. UE 基础对象和原生加载状态。
    vars.Utils = vars.Uhara.CreateTool("UnrealEngine", "Utilities");
    if (vars.Utils.GWorld == IntPtr.Zero
        || vars.Utils.GEngine == IntPtr.Zero
        || vars.Utils.FNames == IntPtr.Zero)
    {
        throw new Exception("Unreal utilities could not resolve GWorld/GEngine/FNames");
    }

    vars.Events = vars.Uhara.CreateTool("UnrealEngine", "Events");
    if (vars.Events == null)
        throw new Exception("Unreal events tool could not be created");

    vars.LoadingStateSlot = vars.Uhara.ScanRel(
        3,
        "48 8B 05 ?? ?? ?? ?? C3 CC CC CC CC CC CC CC CC 48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 20 48 8B 81 E8 00 00 00");
    if (vars.LoadingStateSlot == IntPtr.Zero)
        throw new Exception("BGWGameInstance loading state slot was not found");

    // 2. 通用读取委托。
    vars.ReadClassName = (Func<IntPtr, string>)(obj =>
    {
        if (obj == IntPtr.Zero) return "";
        IntPtr classPtr = vars.Resolver.Read<IntPtr>((IntPtr)((long)obj + 0x10));
        if (classPtr == IntPtr.Zero) return "";
        return vars.Utils.FNameToString(
            vars.Resolver.Read<ulong>((IntPtr)((long)classPtr + 0x18)));
    });

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

    vars.ReadSequenceStatus = (Func<IntPtr, byte>)(player =>
    {
        if (player == IntPtr.Zero) return 0;
        return vars.Resolver.Read<byte>((IntPtr)((long)player + 0x288));
    });

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
    // long[] 字段布局：
    // [0] Actor 指针，[1] 首次观察时间，[2] 死亡 Montage 已触发。
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
    vars.CompletedSplits = new HashSet<string>();
    vars.ActorSeen = new Dictionary<string, long[]>();
    vars.PendingSplits = new Queue<string>();
    vars.ObservedActors = new HashSet<string>();
    vars.DualSplits = new Dictionary<string, string[]>();
    vars.DualSettingsByActor = new Dictionary<string, List<string>>();
    vars.DualMontageHits = new Dictionary<string, HashSet<string>>();

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

    vars.IsAutoSplitEnabled = (Func<bool>)(() =>
        ((Func<string, bool, bool>)vars.IsSettingEnabled)("AutoSplitEnabled", false));

    vars.GetActorSetting = (Func<string, string>)(uid =>
    {
        string despawnSetting = "Despawn_" + uid;
        if (settings.ContainsKey(despawnSetting)) return despawnSetting;

        string montageSetting = "Montage_" + uid;
        if (settings.ContainsKey(montageSetting)) return montageSetting;

        return "Dead_" + uid;
    });

    // Dual_ 配置格式：Dual_UGuid.A+UGuid.B。
    // 只在 init 解析一次；update 仅做字典查询，不产生 XML/文件 I/O。
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

    // TryQueueSplit:
    // - Dead_* 接受死亡 Montage 和单 Boss 慢动作。
    // - Montage_* 只接受死亡 Montage。
    // - Despawn_* 只在 Actor 真正消失时打点。
    // - Dual_* 不经过本函数，避免单个 Boss 提前触发。
    // - CompletedSplits 保证同一设置每次尝试只打一次。
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

    // 双 Boss 只在两个 Actor 都出现过死亡 Montage 后入队。
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

    // 同一 UID 重新生成 Actor 时清除旧实例的 montage 进度。
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

    vars.ResetSession = (Action)(() =>
    {
        ((HashSet<string>)vars.CompletedSplits).Clear();
        ((Action)vars.ClearActorTracking)();
        vars.PendingSplits = new Queue<string>();
        vars.NextActorScanTicks = 0L;
        vars.StartArmed = false;
    });

    // 5. 扫描节流和判定窗口。
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

    current.World = "";
    current.WorldPending = true;

    // 6. 过场和 Bink 状态。
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

    vars.CutscenePending = false;
    vars.CutsceneLastSignalTicks = 0L;
    vars.CutsceneHoldTicks = TimeSpan.TicksPerMillisecond * 500;
    vars.BinkEarlyStopGuardTicks = TimeSpan.TicksPerMillisecond * 200;
    vars.BinkPlayTicks = 0L;
    vars.ActiveSequencePlayer = IntPtr.Zero;
    vars.ActiveBinkPlayer = IntPtr.Zero;

    current.CutsceneNotify = IntPtr.Zero;
    current.SeqPlayerPlayInstance = IntPtr.Zero;
    current.SeqPlayerStopInstance = IntPtr.Zero;
    current.BinkPlayInstance = IntPtr.Zero;
    current.BinkStopInstance = IntPtr.Zero;
    current.CutsceneActor = IntPtr.Zero;
    current.BguSequenceActor = IntPtr.Zero;

    // 只在真正的 Play/Stop/状态变化时更新 CutscenePending；
    // 结束后的 500ms 容错窗从最后一个结束信号开始计算。
    vars.UpdateCutsceneHooks = (Action)(() =>
    {
        long nowTicks = DateTime.UtcNow.Ticks;
        bool wasPending = (bool)vars.CutscenePending;

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
// 作用：更新原生加载、过场状态和 50ms 一次的 Boss Actor 扫描。
// 原理：打点来源按死亡 Montage -> 单 Boss 慢动作 -> 消失回退进入队列；
// Montage_* 仅使用死亡 Montage，Despawn_* 仅使用消失信号，
// Dual_* 需要两个配置的 Boss 都出现死亡 Montage。
update
{
    try
    {
        vars.Uhara.Update();

        IntPtr loadingRoot = vars.Resolver.Read<IntPtr>(vars.LoadingStateSlot);
        byte nativeLoadingState = loadingRoot == IntPtr.Zero
            ? (byte)0
            : vars.Resolver.Read<byte>((IntPtr)((long)loadingRoot + 0x240));
        vars.NativeLoadingPending = nativeLoadingState != 0;

        ((Action)vars.UpdateCutsceneHooks)();

        long nowTicks = DateTime.UtcNow.Ticks;
        if (nowTicks < (long)vars.NextActorScanTicks) return;
        vars.NextActorScanTicks = nowTicks + (long)vars.ScanIntervalTicks;

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

        bool worldPending = worldName.StartsWith("Startup", StringComparison.Ordinal)
            || worldName == "WXLogin_P"
            || worldName == "SetConfig_P"
            || worldName == "ServerCheck"
            || worldName == "None";

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

        IntPtr levelPtr = vars.Resolver.Read<IntPtr>((IntPtr)((long)worldPtr + 0x30));
        if (levelPtr == IntPtr.Zero) return;

        IntPtr actors = vars.Resolver.Read<IntPtr>((IntPtr)((long)levelPtr + 0x98));
        int actorCount = vars.Resolver.Read<int>((IntPtr)((long)levelPtr + 0xA0));
        if (actors == IntPtr.Zero || actorCount <= 0 || actorCount > 20000) return;

        Dictionary<string, long[]> nextSeen = new Dictionary<string, long[]>();
        List<string> deathMontageSplits = new List<string>();
        List<string> slowMotionCandidates = new List<string>();
        HashSet<string> previousObservedActors = (HashSet<string>)vars.ObservedActors;
        HashSet<string> observedActors = new HashSet<string>();

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

        IntPtr worldSettings = vars.Resolver.Read<IntPtr>(
            (IntPtr)((long)levelPtr + 0x2A0));
        float timeDilation = worldSettings == IntPtr.Zero
            ? 1.0f
            : vars.Resolver.Read<float>((IntPtr)((long)worldSettings + 0x3A8));
        // 识破/退寸约为 0.5，完美闪避不低于 0.3；击杀慢动作最低约 0.125。
        bool slowMotion = timeDilation > 0.001f && timeDilation < 0.16f;

        // 同周期先处理死亡 Montage，再处理极低时间膨胀的击杀慢动作。
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
        vars.ActorSeen = nextSeen;
    }
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

// 从菜单进入首个 MGD 场景时自动开始。
// StartArmed 仅由 Startup 世界置位，手动开始和重置都会清除。
start
{
    if (!(bool)vars.StartArmed || current.World != "MGD_PersistentLevel")
        return false;

    vars.StartArmed = false;
    ((Action<string>)vars.Log)("[BMW-splitter] auto start: world=" + (string)current.World);
    return true;
}

// 每次只消费一个有效设置，避免一次 update 连续打多个点。
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

// 只控制 Game Time，Real Time 始终由 LiveSplit 正常推进。
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

onStart
{
    timer.IsGameTimePaused = true;
    ((Action)vars.ResetSession)();
}

onReset
{
    ((Action)vars.ResetSession)();
}

exit
{
    timer.IsGameTimePaused = true;
    ((Action<string>)vars.Log)("[BMW-splitter] game process exit");
}

shutdown
{
    try { ((Action)vars.ResetSession)(); } catch {}
}

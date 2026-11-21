state("b1-Win64-Shipping") {}
state("b1-WinGDK-Shipping") {}

startup
{
    string componentDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Components");

    Assembly.Load(File.ReadAllBytes(Path.Combine(componentDir, "uhara10-BMW"))).CreateInstance("Main");

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
    vars.Log("[BMW-loading] settings loaded: " + settingsPath);
}

init
{

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

    vars.ReadClassName = (Func<IntPtr, string>)(obj =>
    {
        if (obj == IntPtr.Zero) return "";
        IntPtr classPtr = vars.Resolver.Read<IntPtr>((IntPtr)((long)obj + 0x10));
        if (classPtr == IntPtr.Zero) return "";
        return vars.Utils.FNameToString(
            vars.Resolver.Read<ulong>((IntPtr)((long)classPtr + 0x18)));
    });

    vars.ReadSequenceStatus = (Func<IntPtr, byte>)(player =>
    {
        if (player == IntPtr.Zero) return 0;
        return vars.Resolver.Read<byte>((IntPtr)((long)player + 0x288));
    });

    vars.ReadSequenceName = (Func<IntPtr, string>)(player =>
    {
        if (player == IntPtr.Zero) return "";
        IntPtr sequenceAsset = vars.Resolver.Read<IntPtr>(
            (IntPtr)((long)player + 0x290));
        if (sequenceAsset == IntPtr.Zero) return "";
        return vars.Utils.FNameToString(
            vars.Resolver.Read<ulong>((IntPtr)((long)sequenceAsset + 0x18)));
    });

    vars.FindAnimation = (Func<IntPtr, IntPtr>)(actor =>
    {
        IntPtr mesh = vars.Resolver.Read<IntPtr>((IntPtr)((long)actor + 0x308));
        IntPtr anim = mesh == IntPtr.Zero
            ? IntPtr.Zero
            : vars.Resolver.Read<IntPtr>((IntPtr)((long)mesh + 0x850));
        if (anim != IntPtr.Zero) return anim;

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
            string componentClass = vars.ReadClassName(component);
            if (!componentClass.Contains("ACharacterComponent")) continue;

            mesh = vars.Resolver.Read<IntPtr>((IntPtr)((long)component + 0x40));
            anim = mesh == IntPtr.Zero
                ? IntPtr.Zero
                : vars.Resolver.Read<IntPtr>((IntPtr)((long)mesh + 0x850));
            if (anim != IntPtr.Zero) return anim;
        }
        return IntPtr.Zero;
    });

    vars.ReadActionNames = (Func<IntPtr, string>)(anim =>
    {
        if (anim == IntPtr.Zero) return "";

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
                        vars.ReadClassName(candidate);
                    if (string.IsNullOrEmpty(candidateClass)
                        || !candidateClass.Contains("AnimMontage"))
                        continue;
                    string candidateName = vars.Utils.FNameToString(
                        vars.Resolver.Read<ulong>((IntPtr)((long)candidate + 0x18)));
                    if (string.IsNullOrEmpty(candidateName)
                        || candidateName.Equals("None", StringComparison.OrdinalIgnoreCase))
                        continue;
                    montageName = candidateName;
                    break;
                }
                if (string.IsNullOrEmpty(montageName)) continue;

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

    vars.IsDeathAction = (Func<string, bool>)(actionNames =>
    {
        if (string.IsNullOrEmpty(actionNames)) return false;
        string lowerName = actionNames.ToLowerInvariant();
        return lowerName.Contains("_die")
            || lowerName.Contains("_dead")
            || lowerName.Contains("death")
            || lowerName.Contains("suicide");
    });

    vars.MatchAction = (Func<string, string, bool>)((actionNames, pattern) =>
    {
        if (string.IsNullOrEmpty(actionNames) || string.IsNullOrEmpty(pattern))
            return false;
        if (pattern == "*") return true;

        string[] actions = actionNames.Split('|');
        bool startsWithWildcard = pattern.StartsWith("*", StringComparison.Ordinal);
        bool endsWithWildcard = pattern.EndsWith("*", StringComparison.Ordinal);
        string value = pattern;
        if (startsWithWildcard)
            value = value.Substring(1);
        if (endsWithWildcard && value.Length > 0)
            value = value.Substring(0, value.Length - 1);
        if (string.IsNullOrEmpty(value)) return true;

        for (int index = 0; index < actions.Length; index++)
        {
            string action = actions[index];
            if (startsWithWildcard && endsWithWildcard)
            {
                if (action.IndexOf(value, StringComparison.OrdinalIgnoreCase) >= 0)
                    return true;
            }
            else if (startsWithWildcard)
            {
                if (action.EndsWith(value, StringComparison.OrdinalIgnoreCase))
                    return true;
            }
            else if (endsWithWildcard)
            {
                if (action.StartsWith(value, StringComparison.OrdinalIgnoreCase))
                    return true;
            }
            else if (action.Equals(value, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        return false;
    });

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

    vars.StripActorInstanceSuffix = (Func<string, string>)(token =>
    {
        int marker = token.LastIndexOf("_C_", StringComparison.OrdinalIgnoreCase);
        if (marker < 0 || marker + 3 >= token.Length) return token;
        for (int index = marker + 3; index < token.Length; index++)
        {
            if (!char.IsDigit(token[index])) return token;
        }
        return token.Substring(0, marker);
    });

    vars.ResolveActorUid = (Func<string, string>)(actorName =>
    {
        if (string.IsNullOrEmpty(actorName)) return "";
        if (actorName.StartsWith("UGuid___", StringComparison.Ordinal))
            return actorName.Split('@')[0].Replace("___", ".");

        int tokenStart = actorName.IndexOf("-TAMER_", StringComparison.OrdinalIgnoreCase);
        if (tokenStart < 0) return "";
        tokenStart += 1;
        int at = actorName.IndexOf('@', tokenStart);
        string token = at < 0
            ? actorName.Substring(tokenStart)
            : actorName.Substring(tokenStart, at - tokenStart);
        if (string.IsNullOrEmpty(token)) return "";

        bool fullTracked = settings.ContainsKey("Montage_" + token)
            || settings.ContainsKey("Slow_" + token)
            || settings.ContainsKey("Despawn_" + token)
            || vars.ActionSplitsByActor.ContainsKey(token);
        if (fullTracked) return token;

        string baseToken = vars.StripActorInstanceSuffix(token);
        bool baseTracked = settings.ContainsKey("Montage_" + baseToken)
            || settings.ContainsKey("Slow_" + baseToken)
            || settings.ContainsKey("Despawn_" + baseToken)
            || vars.ActionSplitsByActor.ContainsKey(baseToken);
        return baseTracked ? baseToken : "";
    });

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
        vars.IsSettingEnabled("AutoSplitEnabled", false));

    vars.GetActorSetting = (Func<string, string>)(uid =>
    {
        string despawnSetting = "Despawn_" + uid;
        if (settings.ContainsKey(despawnSetting)) return despawnSetting;

        string montageSetting = "Montage_" + uid;
        if (settings.ContainsKey(montageSetting)) return montageSetting;

        string slowSetting = "Slow_" + uid;
        if (settings.ContainsKey(slowSetting)) return slowSetting;

        return "";
    });

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
                vars.Log(
                    "[BMW-splitter] invalid dual setting: " + setting);
                continue;
            }

            uids[0] = uids[0].Trim();
            uids[1] = uids[1].Trim();
            if (uids[0] == uids[1]
                || !uids[0].StartsWith("UGuid.", StringComparison.Ordinal)
                || !uids[1].StartsWith("UGuid.", StringComparison.Ordinal))
            {
                vars.Log(
                    "[BMW-splitter] invalid dual setting: " + setting);
                continue;
            }

            Dictionary<string, string[]> dualSplits =
                (Dictionary<string, string[]>)vars.DualSplits;
            if (dualSplits.ContainsKey(setting)) continue;
            dualSplits[setting] = uids;
            vars.DualMontageHits[setting] =
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
                vars.Log(
                    "[BMW-action] invalid action setting: " + setting);
                continue;
            }

            string uid = setting.Substring("Action_".Length, separator - "Action_".Length);
            string pattern = setting.Substring(separator + 1);
            if ((!uid.StartsWith("UGuid.", StringComparison.Ordinal)
                    && !uid.StartsWith("TAMER_", StringComparison.OrdinalIgnoreCase))
                || string.IsNullOrEmpty(pattern))
            {
                vars.Log(
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

    vars.TryQueueSetting = (Func<string, string, bool>)((setting, source) =>
    {
        if (!vars.IsAutoSplitEnabled()) return false;
        if (timer.CurrentPhase != TimerPhase.Running) return false;
        if (!vars.IsSettingEnabled(setting, false)) return false;
        if (!vars.CompletedSplits.Add(setting)) return false;

        vars.PendingSplits.Enqueue(setting);
        vars.Log(
            "[BMW-splitter] split queued: setting=" + setting + " source=" + source);
        return true;
    });

    vars.TryQueueActionSplits = (Func<string, string, bool>)((uid, actionNames) =>
    {
        List<string> settingIds;
        if (!vars.ActionSplitsByActor
            .TryGetValue(uid, out settingIds))
        {
            return false;
        }

        bool queued = false;
        foreach (string setting in settingIds)
        {
            if (vars.CompletedSplits.Contains(setting)) continue;

            string pattern;
            if (!vars.ActionSplitPatterns
                .TryGetValue(setting, out pattern))
            {
                continue;
            }
            if (!vars.MatchAction(actionNames, pattern))
                continue;

            if (vars.TryQueueSetting(
                setting,
                "action:" + pattern))
            {
                queued = true;
            }
        }
        return queued;
    });

    vars.TryQueueSplit = (Func<string, string, bool>)((uid, source) =>
    {
        string setting = vars.GetActorSetting(uid);
        if (!vars.IsSettingEnabled(setting, false)) return false;
        if (source != "despawn"
            && setting.StartsWith("Despawn_", StringComparison.Ordinal)) return false;
        if (source != "death-montage"
            && setting.StartsWith("Montage_", StringComparison.Ordinal)) return false;
        if (source != "slow-motion"
            && setting.StartsWith("Slow_", StringComparison.Ordinal)) return false;

        return vars.TryQueueSetting(setting, source);
    });

    vars.RegisterDualMontage = (Func<string, bool>)(uid =>
    {
        List<string> dualSettings;
        if (!vars.DualSettingsByActor
            .TryGetValue(uid, out dualSettings))
        {
            return false;
        }

        foreach (string setting in dualSettings)
        {
            if (vars.CompletedSplits.Contains(setting)) continue;

            string[] pair;
            if (!vars.DualSplits
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
                vars.TryQueueSetting(
                    setting,
                    "dual-montage");
            }
        }
        return true;
    });

    vars.ResetDualActor = (Action<string>)(uid =>
    {
        List<string> dualSettings;
        if (vars.DualSettingsByActor
            .TryGetValue(uid, out dualSettings))
        {
            foreach (string setting in dualSettings)
            {
                HashSet<string> hits;
                if (vars.DualMontageHits
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
        vars.ActorActionState = new Dictionary<string, string[]>();
        Dictionary<string, HashSet<string>> dualHits =
            (Dictionary<string, HashSet<string>>)vars.DualMontageHits;
        foreach (string setting in vars.DualSplits.Keys)
            dualHits[setting] = new HashSet<string>();
        vars.LastSlowMotion = false;
    });

    vars.ResetSession = (Action)(() =>
    {
        vars.CompletedSplits.Clear();
        vars.ClearActorTracking();
        vars.PendingSplits = new Queue<string>();
        vars.NextActorScanTicks = 0L;
        vars.StartArmed = false;
    });

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

    vars.CutscenePending = false;
    vars.BinkEarlyStopGuardTicks = TimeSpan.TicksPerMillisecond * 200;
    vars.BinkPlayTicks = 0L;
    vars.SeqCameraCutsGuardTicks = TimeSpan.TicksPerMillisecond * 200;
    vars.ActiveSequencePlayTicks = 0L;
    vars.ActiveSequencePlayer = IntPtr.Zero;
    vars.ActiveBinkPlayer = IntPtr.Zero;

    current.SeqPlayerPlayInstance = IntPtr.Zero;
    current.SeqPlayerStopInstance = IntPtr.Zero;
    current.SeqCameraCutsInstance = IntPtr.Zero;
    current.BinkPlayInstance = IntPtr.Zero;
    current.BinkStopInstance = IntPtr.Zero;

    vars.UpdateCutsceneHooks = (Action)(() =>
    {
        long nowTicks = DateTime.UtcNow.Ticks;

        if (vars.Resolver.CheckFlag("SeqPlayerPlayFlag"))
        {
            IntPtr player = (IntPtr)current.SeqPlayerPlayInstance;
            if (player != IntPtr.Zero)
            {
                byte status = vars.ReadSequenceStatus(player);
                string sequenceName = vars.ReadSequenceName(player);
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
                vars.Log(
                    "[BMW-seq] play player=0x" + player.ToInt64().ToString("X")
                    + " status=" + status
                    + " cutscene=" + cutsceneSequence
                    + " participates=" + participates
                    + " name=" + sequenceName);
            }
        }

        if (vars.Resolver.CheckFlag("SeqPlayerStopFlag"))
        {
            IntPtr player = (IntPtr)current.SeqPlayerStopInstance;
            IntPtr activePlayer = (IntPtr)vars.ActiveSequencePlayer;
            bool matchesActive = player != IntPtr.Zero && player == activePlayer;
            byte status = player == IntPtr.Zero
                ? (byte)0
                : vars.ReadSequenceStatus(player);
            string sequenceName = player == IntPtr.Zero
                ? ""
                : vars.ReadSequenceName(player);
            vars.Log(
                "[BMW-seq] stop player=0x" + player.ToInt64().ToString("X")
                + " active=0x" + activePlayer.ToInt64().ToString("X")
                + " match=" + matchesActive
                + " status=" + status
                + " name=" + sequenceName);
            if (matchesActive)
            {
                vars.ActiveSequencePlayer = IntPtr.Zero;
                vars.Log(
                    "[BMW-seq] end reason=stop player=0x"
                    + player.ToInt64().ToString("X")
                    + " name=" + sequenceName);
            }
        }

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
                : vars.ReadSequenceName(player);
            vars.Log(
                "[BMW-seq] camera-cuts player=0x" + player.ToInt64().ToString("X")
                + " active=0x" + activePlayer.ToInt64().ToString("X")
                + " match=" + matchesActive
                + " elapsedMs=" + cameraCutsElapsed
                + " controlReturned=" + controlReturned
                + " name=" + sequenceName);
            if (controlReturned)
            {
                vars.ActiveSequencePlayer = IntPtr.Zero;
                vars.Log(
                    "[BMW-seq] end reason=camera-cuts player=0x"
                    + player.ToInt64().ToString("X")
                    + " elapsedMs=" + cameraCutsElapsed
                    + " name=" + sequenceName);
            }
        }

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
            vars.Log(
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
            vars.Log(
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
                vars.Log(
                    "[BMW-bink] end reason=stop player=0x"
                    + bink.ToInt64().ToString("X")
                    + " elapsedMs=" + stopElapsed
                    + " name=" + binkName);
            }
        }

        IntPtr activeSequence = (IntPtr)vars.ActiveSequencePlayer;
        if (activeSequence != IntPtr.Zero)
        {
            byte status = vars.ReadSequenceStatus(activeSequence);
            if (status != 1)
            {
                string sequenceName = vars.ReadSequenceName(
                    activeSequence);
                vars.ActiveSequencePlayer = IntPtr.Zero;
                vars.Log(
                    "[BMW-seq] end reason=status player=0x"
                    + activeSequence.ToInt64().ToString("X")
                    + " status=" + status
                    + " name=" + sequenceName);
            }
        }

        if ((bool)vars.CutscenePending
            && (IntPtr)vars.ActiveSequencePlayer == IntPtr.Zero
            && (IntPtr)vars.ActiveBinkPlayer == IntPtr.Zero)
        {
            vars.CutscenePending = false;
        }
    });
}

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

        vars.UpdateCutsceneHooks();

        long nowTicks = DateTime.UtcNow.Ticks;
        if (nowTicks < (long)vars.NextActorScanTicks) return;
        vars.NextActorScanTicks = nowTicks + (long)vars.ScanIntervalTicks;

        IntPtr worldPtr = vars.Resolver.Read<IntPtr>(vars.Utils.GWorld);
        if (worldPtr == IntPtr.Zero)
        {
            current.World = "";
            current.WorldPending = true;
            vars.ClearActorTracking();
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
            vars.ClearActorTracking();
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
                vars.Log(
                    "[BMW-loading] world changed: " + previousWorld + " -> " + worldName);
            }
            vars.ClearActorTracking();
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

            string uid = vars.ResolveActorUid(actorName);
            if (string.IsNullOrEmpty(uid)) continue;
            observedActors.Add(uid);

            bool firstObserved = !previousObservedActors.Contains(uid);
            if (firstObserved)
            {
                string actorClass = vars.ReadClassName(actor);
                vars.Log(
                    "[BMW-splitter] actor appeared: uid=" + uid
                    + " class=" + actorClass
                    + " name=" + actorName
                    + " actor=0x" + actor.ToString("X")
                    + " world=" + worldName);
            }

            IntPtr anim = vars.FindAnimation(actor);
            string actionNames = vars.ReadActionNames(anim);
            bool deathAction = vars.IsDeathAction(actionNames);
            string actorKey = actor.ToString("X");
            Dictionary<string, string[]> actionStates =
                (Dictionary<string, string[]>)vars.ActorActionState;
            string[] actionState;
            bool sameActor = actionStates.TryGetValue(uid, out actionState)
                && actionState[0] == actorKey;
            string previousAction = sameActor ? actionState[1] : "";

            bool actionChanged = sameActor
                ? actionNames != previousAction
                : !string.IsNullOrEmpty(actionNames);
            if (actionChanged)
            {
                string currentAction = string.IsNullOrEmpty(actionNames)
                    ? "<none>" : actionNames;
                vars.Log(
                    "[BMW-action] actor action changed: uid=" + uid
                    + " action=" + currentAction
                    + " deathAction=" + deathAction);
            }

            actionStates[uid] = new string[]
            {
                actorKey,
                actionNames
            };

            vars.TryQueueActionSplits(uid, actionNames);

            string setting = vars.GetActorSetting(uid);
            bool hasDualSetting = ((Dictionary<string, List<string>>)
                vars.DualSettingsByActor).ContainsKey(uid);
            if (!settings.ContainsKey(setting) && !hasDualSetting) continue;
            long[] previous;
            if (vars.ActorSeen.TryGetValue(uid, out previous)
                && previous[0] == (long)actor)
            {
                long previousDeathMontage = previous[2];
                long seenTicks = nowTicks - previous[1];

                long deathMontage = previousDeathMontage;
                if (deathMontage == 0L
                    && seenTicks >= (long)vars.MinBossActorSeenTicks
                    && deathAction)
                {
                    deathMontage = 1L;
                    deathMontageSplits.Add(uid);
                    vars.Log(
                        "[BMW-splitter] death montage visible: uid=" + uid
                        + " setting=" + setting
                        + " enabled=" + vars.IsSettingEnabled(setting, false)
                        + " dual=" + hasDualSetting
                        + " action=" + actionNames
                        + " custom=" + ((Func<string, string, string>)
                            vars.BuildActionSettingList)(uid, actionNames)
                        + " world=" + worldName);
                }

                if (seenTicks >= (long)vars.MinBossActorSeenTicks
                    && vars.IsSettingEnabled(setting, false)
                    && !hasDualSetting
                    && setting.StartsWith("Slow_", StringComparison.Ordinal))
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

                vars.ResetDualActor(uid);
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
                vars.Log(
                    "[BMW-splitter] actor despawn observed: uid=" + previousUid
                    + " world=" + worldName);
                vars.ActorActionState.Remove(previousUid);
            }
        }
        vars.ObservedActors = observedActors;

        IntPtr worldSettings = vars.Resolver.Read<IntPtr>(
            (IntPtr)((long)levelPtr + 0x2A0));
        float timeDilation = worldSettings == IntPtr.Zero
            ? 1.0f
            : vars.Resolver.Read<float>((IntPtr)((long)worldSettings + 0x3A8));

        bool slowMotion = timeDilation > 0.001f && timeDilation < 0.16f;

        foreach (string uid in deathMontageSplits)
        {
            if (!vars.DualSettingsByActor
                .ContainsKey(uid))
            {
                vars.TryQueueSplit(
                    uid,
                    "death-montage");
            }
            vars.RegisterDualMontage(uid);
        }

        if (slowMotion
            && !(bool)vars.LastSlowMotion
            && slowMotionCandidates.Count == 1)
        {
            vars.TryQueueSplit(
                slowMotionCandidates[0],
                "slow-motion");
        }
        vars.LastSlowMotion = slowMotion;

        foreach (KeyValuePair<string, long[]> pair
            in (Dictionary<string, long[]>)vars.ActorSeen)
        {
            if (nextSeen.ContainsKey(pair.Key)) continue;

            long seenTicks = nowTicks - pair.Value[1];
            if (seenTicks < (long)vars.MinBossActorSeenTicks) continue;

            string setting = vars.GetActorSetting(pair.Key);
            if (!setting.StartsWith("Despawn_", StringComparison.Ordinal)) continue;
            if (!vars.IsSettingEnabled(setting, false))
                continue;

            vars.TryQueueSplit(pair.Key, "despawn");
        }

        vars.ActorSeen = nextSeen;
    }

    catch (Exception ex)
    {
        long errorTicks = DateTime.UtcNow.Ticks;
        if (errorTicks - (long)vars.LastUpdateErrorTicks >= TimeSpan.TicksPerSecond)
        {
            vars.LastUpdateErrorTicks = errorTicks;
            vars.Log("[BMW-splitter] update error: " + ex.ToString());
        }
    }
}

start
{
    if (!(bool)vars.StartArmed || current.World != "MGD_PersistentLevel")
        return false;

    vars.StartArmed = false;
    vars.Log("[BMW-splitter] auto start: world=" + (string)current.World);
    return true;
}

split
{
    if (!vars.IsAutoSplitEnabled())
    {
        vars.PendingSplits.Clear();
        return false;
    }
    if (timer.CurrentPhase != TimerPhase.Running) return false;

    Queue<string> pending = (Queue<string>)vars.PendingSplits;
    while (pending.Count > 0)
    {
        string setting = pending.Dequeue();
        if (vars.IsSettingEnabled(setting, false))
        {
            vars.Log("[BMW-splitter] split: " + setting);
            return true;
        }
    }
    return false;
}

isLoading
{
    bool worldLoading = (bool)current.WorldPending;
    bool nativeLoading = (bool)vars.NativeLoadingPending;
    bool cutsceneLoading =
        vars.IsSettingEnabled("RemoveCutscenes", true)
        && (bool)vars.CutscenePending;
    bool loading = worldLoading || nativeLoading || cutsceneLoading;

    if (loading != (bool)vars.LastLoading)
    {
        vars.LastLoading = loading;
        vars.Log(
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
    vars.ResetSession();
}

onReset
{
    vars.ResetSession();
}

exit
{
    timer.IsGameTimePaused = true;
    vars.Log("[BMW-splitter] game process exit");
}

shutdown
{
    try { vars.ResetSession(); } catch {}
}

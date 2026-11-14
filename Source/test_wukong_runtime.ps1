<#
.SYNOPSIS
验证生成的黑神话：悟空运行时文件没有注释，并编译解析 ASL。

.PARAMETER RepositoryRoot
BMW_AutoSplitter 仓库根目录，默认是本脚本目录的上级目录。

.PARAMETER LiveSplitRoot
包含 LiveSplit.Core.dll 和 Scriptable Auto Splitter 组件的 LiveSplit
安装目录，默认是 D:\soft\e-game\LiveSplit_1.8.37。

.OUTPUTS
输出 ASL_PARSE_OK 行，最后输出 WUKONG_RUNTIME_TEST_OK。
#>
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$LiveSplitRoot = "D:\soft\e-game\LiveSplit_1.8.37"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "comment_tools.ps1")

$components = Join-Path $RepositoryRoot "Components"
$aslPath = Join-Path $components "BlackMythWukong.asl"
$xmlPaths = @(
    (Join-Path $components "BMWukong.Settings.xml"),
    (Join-Path $components "BMWukong.Settings.en.xml")
)
$uharaPath = Join-Path $components "uhara10-PBZ"
$repositoryAslPath = Join-Path $RepositoryRoot "BlackMythWukong.asl"
$repositoryXmlPaths = @(
    (Join-Path $RepositoryRoot "BMWukong.Settings.xml"),
    (Join-Path $RepositoryRoot "BMWukong.Settings.en.xml")
)

Assert-CSharpCommentsRemoved -Path $aslPath
foreach ($xmlPath in $xmlPaths) {
    Assert-XmlCommentsRemoved -Path $xmlPath
}
Assert-CSharpCommentsRemoved -Path $repositoryAslPath
foreach ($xmlPath in $repositoryXmlPaths) {
    Assert-XmlCommentsRemoved -Path $xmlPath
}

$mirrorPairs = @(
    @($aslPath, $repositoryAslPath),
    @($xmlPaths[0], $repositoryXmlPaths[0]),
    @($xmlPaths[1], $repositoryXmlPaths[1])
)
foreach ($pair in $mirrorPairs) {
    $componentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $pair[0]).Hash
    $repositoryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $pair[1]).Hash
    if ($componentHash -ne $repositoryHash) {
        throw "Repository-root mirror differs from Components: $($pair[1])"
    }
}

if (-not (Test-Path -LiteralPath $uharaPath -PathType Leaf)) {
    throw "uhara10-PBZ dependency is missing: $uharaPath"
}

$documents = foreach ($xmlPath in $xmlPaths) {
    $document = New-Object System.Xml.XmlDocument
    $document.Load($xmlPath)
    if ($document.DocumentElement.Name -ne "Settings") {
        throw "Unexpected settings XML root: $($document.DocumentElement.Name)"
    }
    $document
}

$defaultDocument = $documents[0]
$englishDocument = $documents[1]
$defaultAutoSplit = $defaultDocument.SelectSingleNode('//Setting[@Id="AutoSplitEnabled"]')
$englishAutoSplit = $englishDocument.SelectSingleNode('//Setting[@Id="AutoSplitEnabled"]')
if ($null -eq $defaultAutoSplit -or $defaultAutoSplit.State -ne "true") {
    throw "AutoSplitEnabled must exist and default to true in BMWukong.Settings.xml"
}
if ($null -eq $englishAutoSplit -or $englishAutoSplit.State -ne "true") {
    throw "AutoSplitEnabled must exist and default to true in BMWukong.Settings.en.xml"
}

$defaultSettings = @($defaultDocument.SelectNodes('//Setting'))
$englishSettings = @($englishDocument.SelectNodes('//Setting'))
if ($defaultSettings.Count -ne $englishSettings.Count) {
    throw "Chinese and English settings have different item counts."
}

$expectedMain = @{
    1 = @('Dead_UGuid.HFS.Niu.Teacher','Dead_UGuid.HFS.GuangZhi','Dead_UGuid.HFS.TongChi01','Dead_UGuid.HFS.DBL0','Dead_UGuid.HFS.GuangM0','Dead_UGuid.HFS.Baiyi0','Montage_UGuid.HFS.BaiyiT2','Dead_UGuid.HFS.XiongR0','Dead_UGuid.HFS.XiongX0')
    2 = @('Dead_UGuid.HFM.FuZiShu.ZS0','Dead_UGuid.HFM.ShiXianFeng','Dead_UGuid.HFM.HuXianFeng.Hu0','Dead_UGuid.HFM.HFDS.H0')
    3 = @('Dead_UGuid.LYS.XueHou.NM','Montage_UGuid.LYS.KJL.Long','Dead_UGuid.LYS.Mo_01','Montage_UGuid.LYS.XueHou.AnShen','Dead_UGuid.LYS.KJL.Women','Dead_UGuid.LYS.SengMian','Dead_UGuid.LYS.SengMian02','Dead_UGuid.LYS.Mo2','Dead_UGuid.LYS.HuangMei.Big','Dead_UGuid.LYS.RBM','Dead_UGuid.LYS.HuangMei.Small')
    4 = @('Dead_UGuid.PSD.Erjie.Village','Dead_UGuid.PSD.FSC01.foshouchong','Dead_UGuid.PSD.Wa.01','Dead_UGuid.PSD.BaJie.Mo','Montage_UGuid.PSD.BaJie.Ye','Dead_UGuid.PSD.LaoZhiZhu','Dead_UGuid.PSD.BaiYanMoJun')
    5 = @('Dual_UGuid.HYS.JiRuHuo01+UGuid.HYS.KuaiRuFeng01','Dual_UGuid.HYS.WuLiYun+UGuid.HYS.YunLiWu','Dead_UGuid.HYS.HongHaiEr','Dead_UGuid.HYS.YeChaWang')
    6 = @('Dead_UGuid.BYS.WLG.01','Dead_UGuid.BYS.Xiniu','Dead_UGuid.BYS.Xuelu','Montage_UGuid.BYS.TangLang','Dead_UGuid.MGD.Yuan','Dead_UGuid.MGD.JSDS.P2')
}
foreach ($chapter in 1..6) {
    $chapterId = "Chapter${chapter}Bosses"
    $chapterNode = $defaultDocument.SelectSingleNode("//Setting[@Id='$chapterId']")
    if ($null -eq $chapterNode -or $chapterNode.State -ne 'true') {
        throw "Missing or disabled chapter wrapper: $chapterId"
    }
    foreach ($groupSuffix in @('MainBosses','YaoguaiKingBosses','ChiefBosses')) {
        $groupId = "Chapter${chapter}${groupSuffix}"
        $group = $chapterNode.SelectSingleNode("./Setting[@Id='$groupId']")
        if ($null -eq $group -or $group.State -ne 'true') {
            throw "Missing or disabled chapter boss category: $groupId"
        }
        if ($group.SelectNodes('./Setting').Count -eq 0) {
            throw "Chapter boss category is empty: $groupId"
        }
    }
    $actualMain = @($chapterNode.SelectSingleNode("./Setting[@Id='Chapter${chapter}MainBosses']").SelectNodes('./Setting') | ForEach-Object { $_.Id -replace '^(Dead_|Montage_|Despawn_|Dual_)', '' })
    $expectedMainIds = @($expectedMain[$chapter] | ForEach-Object { $_ -replace '^(Dead_|Montage_|Despawn_|Dual_)', '' })
    if (($actualMain -join '|') -ne ($expectedMainIds -join '|')) {
        throw "Main Boss classification changed unexpectedly for chapter $chapter"
    }
}

$bossSettings = @($defaultDocument.SelectNodes('//Setting[not(Setting) and (starts-with(@Id,"Dead_") or starts-with(@Id,"Dual_") or starts-with(@Id,"Despawn_") or starts-with(@Id,"Montage_") or starts-with(@Id,"Boss_"))]'))
$disabledBossSettings = @($bossSettings | Where-Object { $_.State -ne 'true' })
if ($disabledBossSettings.Count -gt 0) {
    throw "Boss settings must all default to enabled: $($disabledBossSettings.Id -join ', ')"
}

$expectedParents = @{
    'Dead_UGuid.HFS.TongChi01' = 'Chapter1MainBosses'
    'Montage_UGuid.HFS.BaiyiT2' = 'Chapter1MainBosses'
    'Dead_UGuid.HFS.JCZL' = 'Chapter1YaoguaiKingBosses'
    'Boss_202001' = 'Chapter1ChiefBosses'
    'Dead_UGuid.LYS.Mo4' = 'Chapter3ChiefBosses'
    'Boss_302014' = 'Chapter3ChiefBosses'
    'Boss_603001' = 'Chapter6YaoguaiKingBosses'
}
foreach ($expected in $expectedParents.GetEnumerator()) {
    $node = $defaultDocument.SelectSingleNode("//Setting[@Id='$($expected.Key)']")
    if ($null -eq $node -or $node.ParentNode.Id -ne $expected.Value) {
        throw "Unexpected boss category for $($expected.Key): expected $($expected.Value)"
    }
}

$expectedMappings = @{
    'Boss_103006' = 'Dead_UGuid.HFS.JCZL'
    'Boss_103007' = 'Dead_UGuid.HFS.WoodDragon'
    'Boss_203002' = 'Dead_UGuid.HFM.ShuWang_01a.SW0'
    'Boss_302003' = 'Dead_UGuid.LYS.Mo3.Fly'
    'Boss_302013' = 'Dead_UGuid.LYS.Mo4'
    'Boss_302004' = 'Dead_UGuid.LYS.JianLong.Fight'
    'Boss_402012' = 'Dead_UGuid.PSD.WuLong.4H'
    'Boss_502005' = 'Dual_UGuid.HYS.XingGongXian+UGuid.HYS.XianGongXing'
    'Boss_703001' = 'Dead_UGuid.BSD.JJS'
    'Boss_803001' = 'Dead_UGuid.ZYS.XieZi.MRXG'
    'Boss_803002' = 'Dead_UGuid.ZYS.MRXG'
}
foreach ($mapping in $expectedMappings.GetEnumerator()) {
    if ($null -ne $defaultDocument.SelectSingleNode("//Setting[@Id='$($mapping.Key)']")) {
        throw "Legacy Boss_* setting still exists: $($mapping.Key)"
    }
    if ($null -eq $defaultDocument.SelectSingleNode("//Setting[@Id='$($mapping.Value)']")) {
        throw "Mapped UGuid setting is missing: $($mapping.Value)"
    }
}

$dualSettings = @($defaultDocument.SelectNodes('//Setting[starts-with(@Id,"Dual_")]'))
if ($dualSettings.Count -eq 0) {
    throw "At least one Dual_UGuid setting is required."
}
foreach ($setting in $dualSettings) {
    $parts = $setting.Id.Substring(5).Split('+')
    if ($parts.Count -ne 2 -or
        [string]::IsNullOrWhiteSpace($parts[0]) -or
        [string]::IsNullOrWhiteSpace($parts[1]) -or
        $parts[0] -ceq $parts[1] -or
        $parts[0] -cnotmatch '^UGuid\.' -or
        $parts[1] -cnotmatch '^UGuid\.') {
        throw "Invalid Dual_UGuid setting: $($setting.Id)"
    }
}

$optionalBossSettings = @($defaultDocument.SelectNodes('//Setting[starts-with(@Id,"Boss_")]'))
if ($optionalBossSettings.Count -eq 0) {
    throw "Unmapped optional Boss_* settings must be retained for manual maintenance."
}

$englishById = @{}
foreach ($setting in $englishSettings) {
    $englishById[$setting.Id] = $setting
}
foreach ($setting in $defaultSettings) {
    if (-not $englishById.ContainsKey($setting.Id)) {
        throw "English settings are missing: $($setting.Id)"
    }
    if ($englishById[$setting.Id].State -ne $setting.State) {
        throw "Setting state differs between languages: $($setting.Id)"
    }
}
$untranslated = @($englishSettings | Where-Object { $_.Label -match '[\u4e00-\u9fff]' })
if ($untranslated.Count -gt 0) {
    throw "English settings still contain Chinese labels: $($untranslated.Id -join ', ')"
}

$defaultYangjian = $defaultDocument.SelectSingleNode('//Setting[@Id="Despawn_UGuid.MGD.yangjian.start"]')
$englishYangjian = $englishDocument.SelectSingleNode('//Setting[@Id="Despawn_UGuid.MGD.yangjian.start"]')
$legacyYangjian = $defaultDocument.SelectSingleNode('//Setting[@Id="Dead_UGuid.MGD.yangjian.start"]')
if ($null -eq $defaultYangjian -or $null -eq $englishYangjian) {
    throw "Erlang must use the Despawn_UGuid setting prefix."
}
if ($null -ne $legacyYangjian) {
    throw "Erlang must not keep the legacy Dead_UGuid setting."
}
if ($defaultYangjian.Label -match '推荐|Recommended|Fight Manually' -or
    $englishYangjian.Label -match 'Recommended|Fight Manually') {
    throw "Erlang recommendation text must be removed."
}
if ($defaultYangjian.State -ne 'true' -or $englishYangjian.State -ne 'true') {
    throw "Erlang Boss setting must default to enabled."
}

$aslText = [IO.File]::ReadAllText($aslPath)
if (-not $aslText.Contains('vars.LoadingStateSlot = vars.Uhara.ScanRel(')) {
    throw "Generated ASL does not resolve the BGWGameInstance loading state slot."
}
if (-not $aslText.Contains('0x240')) {
    throw "Generated ASL does not read the BGWGameInstance loading screen state."
}
if (-not $aslText.Contains('timer.IsGameTimePaused = true;')) {
    throw "Generated ASL does not guard the first Game Time tick after start."
}
if (-not $aslText.Contains('worldName == "WXLogin_P"')) {
    throw "Generated ASL does not treat the login world as loading."
}
if (-not $aslText.Contains('worldName == "SetConfig_P"')) {
    throw "Generated ASL does not treat the setup world as loading."
}
if (-not $aslText.Contains('vars.StartArmed')) {
    throw "Generated ASL does not arm auto-start from the Startup/menu world."
}
if (-not $aslText.Contains('current.World != "MGD_PersistentLevel"')) {
    throw "Generated ASL does not restrict auto-start to the MGD start world."
}
if (-not $aslText.Contains('bool nativeLoading = (bool)vars.NativeLoadingPending;')) {
    throw "Generated ASL does not include native loading in isLoading."
}
if (-not $aslText.Contains('vars.Events = vars.Uhara.CreateTool("UnrealEngine", "Events");')) {
    throw "Generated ASL does not create the uHara Events tool."
}
if (-not $aslText.Contains('FunctionFlag("CutsceneNotifyFlag", "*PlayLevelSequence*", null, null);')) {
    throw "Generated ASL does not hook PlayLevelSequence notifications."
}
if (-not $aslText.Contains('FunctionParentPtr<IntPtr>("SeqPlayerPlayInstance", "*LevelSequencePlayer*", null, "Play");')) {
    throw "Generated ASL does not capture the sequence player Play event."
}
if (-not $aslText.Contains('FunctionFlag("BinkPlayFlag", "BinkMediaPlayer", null, "Play");')) {
    throw "Generated ASL does not hook BinkMediaPlayer Play."
}
if (-not $aslText.Contains('"[BMW-loading] isLoading=" + loading')) {
    throw "Generated ASL does not expose the cutscene loading signal."
}
if (-not $aslText.Contains('cutsceneSequence')) {
    throw "Generated ASL does not classify LevelSequencePlayer playback by sequence name."
}

if (-not $aslText.Contains('BinkEarlyStopGuardTicks')) {
    throw "Generated ASL does not ignore the early Bink stop edge."
}
if (-not $aslText.Contains('vars.CutscenePending')) {
    throw "Generated ASL does not track cutscene state."
}
if (-not $aslText.Contains('RemoveCutscenes')) {
    throw "Generated ASL does not use the RemoveCutscenes setting."
}
if ($aslText.Contains('BinkScan') -or $aslText.Contains('GUObjectArray') -or $aslText.Contains('CinematicPending')) {
    throw "Generated ASL still contains the legacy scan/camera loading implementation."
}
if ($aslText.Contains('time dilation below 1') -or
    $aslText.Contains('time dilation sample') -or
    $aslText.Contains('time dilation restored')) {
    throw "Generated ASL still contains temporary time-dilation diagnostics: $aslPath"
}
if (-not $aslText.Contains('timeDilation > 0.001f && timeDilation < 0.16f')) {
    throw "Generated ASL does not use the boss-kill-only slow-motion threshold: $aslPath"
}
if (-not $aslText.Contains('Assembly.Load(File.ReadAllBytes(Path.Combine(componentDir, "uhara10-PBZ"))).CreateInstance("Main");')) {
    throw "Generated ASL does not load uHara: $aslPath"
}
if (-not $aslText.Contains('System.Globalization.CultureInfo.CurrentCulture.Name')) {
    throw "Generated ASL does not detect the current culture: $aslPath"
}
if (-not $aslText.Contains('"BMWukong.Settings." + culture + ".xml"')) {
    throw "Generated ASL does not try a full-culture settings file: $aslPath"
}
if (-not $aslText.Contains('"BMWukong.Settings." + language + ".xml"')) {
    throw "Generated ASL does not try a base-language settings file: $aslPath"
}
if (-not $aslText.Contains('settingsPath = Path.Combine(componentDir, "BMWukong.Settings.xml");')) {
    throw "Generated ASL does not fall back to the default settings file: $aslPath"
}
if (-not $aslText.Contains('vars.IsAutoSplitEnabled = (Func<bool>)')) {
    throw "Generated ASL does not centralize AutoSplitEnabled: $aslPath"
}
if (-not $aslText.Contains('"AutoSplitEnabled", false')) {
    throw "Generated ASL does not default AutoSplitEnabled to false: $aslPath"
}
if (-not $aslText.Contains('vars.TryQueueSplit = (Func<string, string, bool>)')) {
    throw "Generated ASL does not centralize split queueing: $aslPath"
}
if (-not $aslText.Contains('vars.TryQueueSetting = (Func<string, string, bool>)')) {
    throw "Generated ASL does not centralize setting queueing for dual Bosses: $aslPath"
}
if (-not $aslText.Contains('"[BMW-splitter] split queued: setting="')) {
    throw "Generated ASL does not log actual queued splits: $aslPath"
}
foreach ($sourceName in @('"death-montage"', '"dual-montage"', '"slow-motion"', '"despawn"')) {
    if (-not $aslText.Contains($sourceName)) {
        throw "Generated ASL is missing split source ${sourceName}: $aslPath"
    }
}
if (-not $aslText.Contains('slowMotionCandidates.Count == 1')) {
    throw "Generated ASL must avoid ambiguous multi-Boss slow-motion splits: $aslPath"
}
if (-not $aslText.Contains('"Dead_" + uid')) {
    throw "Generated ASL does not map UGuid actors to Dead_UGuid settings: $aslPath"
}
if (-not $aslText.Contains('string despawnSetting = "Despawn_" + uid;')) {
    throw "Generated ASL does not resolve Despawn_UGuid settings: $aslPath"
}
if (-not $aslText.Contains('setting.StartsWith("Despawn_", StringComparison.Ordinal)')) {
    throw "Generated ASL does not gate split sources by the Despawn_ prefix: $aslPath"
}
if (-not $aslText.Contains('if (source != "despawn"')) {
    throw "Generated ASL does not restrict Despawn_ settings to the despawn source: $aslPath"
}
if (-not $aslText.Contains('"[BMW-splitter] actor appeared: uid="') -or -not $aslText.Contains('"[BMW-splitter] actor despawn observed: uid="') -or -not $aslText.Contains('vars.ObservedActors')) {
    throw "Generated ASL must retain appearance/despawn logs for all UGuid actors: $aslPath"
}

if (-not $aslText.Contains('"[BMW-splitter] death montage visible: uid="')) {
    throw "Generated ASL must log every detected death montage edge: $aslPath"
}
$deathQueueIndex = $aslText.IndexOf('foreach (string uid in deathMontageSplits)', [StringComparison]::Ordinal)
$slowMotionIndex = $aslText.IndexOf('if (slowMotion', $deathQueueIndex, [StringComparison]::Ordinal)
if ($deathQueueIndex -lt 0 -or $slowMotionIndex -lt 0 -or $deathQueueIndex -gt $slowMotionIndex) {
    throw "Generated ASL must queue death-montage before slow-motion: $aslPath"
}
if (-not $aslText.Contains('string montageSetting = "Montage_" + uid;')) {
    throw "Generated ASL does not resolve Montage_UGuid settings: $aslPath"
}
if (-not $aslText.Contains('if (source != "death-montage"') -or -not $aslText.Contains('setting.StartsWith("Montage_", StringComparison.Ordinal)')) {
    throw "Generated ASL does not restrict Montage_ settings to death-montage: $aslPath"
}
if (-not $aslText.Contains('!setting.StartsWith("Montage_", StringComparison.Ordinal)')) {
    throw "Generated ASL does not exclude Montage_ settings from slow-motion: $aslPath"
}
if (-not $aslText.Contains('vars.LoadDualSplits = (Action)') -or
    -not $aslText.Contains('//Setting[starts-with(@Id, ''Dual_'')]') -or
    -not $aslText.Contains('.Split(''+'')')) {
    throw "Generated ASL does not parse Dual_UGuid settings at init: $aslPath"
}
if (-not $aslText.Contains('vars.RegisterDualMontage = (Func<string, bool>)') -or
    -not $aslText.Contains('.TryGetValue(setting, out pair)') -or
    -not $aslText.Contains('hits.Contains(pair[0]) && hits.Contains(pair[1])') -or
    -not $aslText.Contains('"dual-montage"')) {
    throw "Generated ASL does not require both Boss montages before a dual split: $aslPath"
}
if (-not $aslText.Contains('&& !hasDualSetting')) {
    throw "Generated ASL does not exclude dual Boss Actors from single-Boss slow motion: $aslPath"
}
if (-not $aslText.Contains('((Func<string, bool>)vars.RegisterDualMontage)(uid);')) {
    throw "Generated ASL does not feed death-montage edges into dual Boss tracking: $aslPath"
}
if ($aslText.Contains('"hidden"') -or
    $aslText.Contains('hiddenSplits') -or
    $aslText.Contains('previousHidden') -or
    $aslText.Contains('bHidden')) {
    throw "Generated ASL still contains hidden-based split logic: $aslPath"
}
if (-not $aslText.Contains('vars.ResetDualActor = (Action<string>)') -or
    -not $aslText.Contains('foreach (string setting in ((Dictionary<string, string[]>)vars.DualSplits).Keys)') -or
    -not $aslText.Contains('dualHits[setting] = new HashSet<string>();')) {
    throw "Generated ASL does not reset stale dual Boss montage progress: $aslPath"
}
$removedVerboseLogs = @(
    'startup begin',
    'combat feedback changed',
    'tracked UGuid actors',
    'removal candidate',
    'removal canceled',
    'sequence player play: player=',
    'sequence player stop: player=',
    'bink play: player=',
    'bink stop: player=',
    'boss hidden edge: uid=',
    'boss kill slow motion: uid='
)
foreach ($logText in $removedVerboseLogs) {
    if ($aslText.Contains($logText)) {
        throw "Generated ASL still contains removed verbose log: $logText"
    }
}
if ($aslText.Contains('"removed"')) {
    throw "Generated ASL still contains the removed split source: $aslPath"
}
$removedFields = @('LastLoggedTrackedCount', 'TrackedActorCount', 'feedbackComponent', 'LastNativeLoadingState', 'PendingRemoval', 'ReadAttackFeedbackValue', 'RemovalConfirmTicks', 'RecentCombatFeedbackTicks', 'hiddenSplits', 'previousHidden')
foreach ($fieldName in $removedFields) {
    if ($aslText.Contains($fieldName)) {
        throw "Generated ASL still contains removed field: $fieldName"
    }
}

$startupIndex = $aslText.IndexOf("`nstartup", [StringComparison]::Ordinal)
$initIndex = $aslText.IndexOf("`ninit", [StringComparison]::Ordinal)
if ($startupIndex -lt 0 -or $initIndex -le $startupIndex) {
    throw "Could not locate startup/init lifecycle blocks: $aslPath"
}
$startupText = $aslText.Substring($startupIndex, $initIndex - $startupIndex)
$initText = $aslText.Substring($initIndex)
$settingsLoadInvocation = "vars.Uhara.Settings.CreateFromXml(settingsPath);"
if (-not $startupText.Contains($settingsLoadInvocation)) {
    throw "Settings are not loaded during startup: $aslPath"
}
if ($initText.Contains($settingsLoadInvocation)) {
    throw "Settings must not be loaded during init: $aslPath"
}
if ($startupText.Contains('vars.GetActorSetting = (Func<string, string>)')) {
    throw "Actor setting resolution must not capture ASLSettingsBuilder during startup: $aslPath"
}
if (-not $initText.Contains('vars.GetActorSetting = (Func<string, string>)')) {
    throw "Actor setting resolution must be created during init from ASLSettingsReader: $aslPath"
}

$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
    throw "C# compiler was not found: $csc"
}

$probeName = "_wukong_asl_parse_probe_" + [Guid]::NewGuid().ToString("N") + ".exe"
$probePath = Join-Path $LiveSplitRoot $probeName

try {
    & $csc /nologo /optimize+ "/out:$probePath" (Join-Path $PSScriptRoot "AslParseProbe.cs")
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to compile the ASL parse probe."
    }

    & $probePath $aslPath
    if ($LASTEXITCODE -ne 0) {
        throw "Generated ASL failed to parse."
    }
}
finally {
    if (Test-Path -LiteralPath $probePath -PathType Leaf) {
        Remove-Item -LiteralPath $probePath -Force
    }
}

Write-Output "WUKONG_RUNTIME_TEST_OK"

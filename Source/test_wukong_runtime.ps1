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
$uharaPath = Join-Path $components "uhara10-BMW"
$lssDirectory = Join-Path $RepositoryRoot "lss"
$chineseLssPath = Join-Path $lssDirectory "黑猴-主线-分章节.lss"
$englishLssPath = Join-Path $lssDirectory "Black Myth Wukong - Main Bosses - By Chapter.lss"
foreach ($lssPath in @($chineseLssPath, $englishLssPath)) {
    if (-not (Test-Path -LiteralPath $lssPath -PathType Leaf)) {
        throw "LSS split file is missing: $lssPath"
    }
}

$chineseLss = New-Object System.Xml.XmlDocument
$englishLss = New-Object System.Xml.XmlDocument
$chineseLss.Load($chineseLssPath)
$englishLss.Load($englishLssPath)
if ($chineseLss.DocumentElement.Name -ne "Run" -or $englishLss.DocumentElement.Name -ne "Run") {
    throw "Unexpected LSS root element."
}
if ($chineseLss.Run.CategoryName -ne "主线 Boss - 分章节") {
    throw "Unexpected Chinese LSS category: $($chineseLss.Run.CategoryName)"
}
if ($englishLss.Run.CategoryName -ne "Main Bosses - By Chapter") {
    throw "Unexpected English LSS category: $($englishLss.Run.CategoryName)"
}
$chineseSegments = @($chineseLss.Run.Segments.Segment)
$englishSegments = @($englishLss.Run.Segments.Segment)
if ($chineseSegments.Count -ne 42 -or $englishSegments.Count -ne 42) {
    throw "Unexpected LSS segment count: CN=$($chineseSegments.Count), EN=$($englishSegments.Count)"
}
for ($i = 0; $i -lt $chineseSegments.Count; $i++) {
    $chineseData = @($chineseSegments[$i].ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -ne 'Name' } | ForEach-Object { $_.OuterXml }) -join "`n"
    $englishData = @($englishSegments[$i].ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -ne 'Name' } | ForEach-Object { $_.OuterXml }) -join "`n"
    if ($chineseData -ne $englishData) {
        throw "Chinese and English LSS segment data differ at index $($i + 1)."
    }
}
$englishLssText = [System.IO.File]::ReadAllText($englishLssPath)
if ($englishLssText -match '[\u4e00-\u9fff]') {
    throw "English LSS still contains Chinese text: $englishLssPath"
}
Write-Output "WUKONG_LSS_TEST_OK"

Assert-CSharpCommentsRemoved -Path $aslPath
foreach ($xmlPath in $xmlPaths) {
    Assert-XmlCommentsRemoved -Path $xmlPath
}

$obsoleteOutputs = @(
    (Join-Path $RepositoryRoot "BlackMythWukong.asl"),
    (Join-Path $RepositoryRoot "BMWukong.Settings.xml"),
    (Join-Path $RepositoryRoot "BMWukong.Settings.en.xml"),
    (Join-Path $components "asl-help")
)
foreach ($path in $obsoleteOutputs) {
    if (Test-Path -LiteralPath $path) {
        throw "Obsolete release output must not exist: $path"
    }
}

if (-not (Test-Path -LiteralPath $uharaPath -PathType Leaf)) {
    throw "uhara10-BMW dependency is missing: $uharaPath"
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
$obsoleteBossPrefix = 'Dead_'
foreach ($document in $documents) {
    $obsoleteBossSettings = @($document.SelectNodes("//Setting[starts-with(@Id,'$obsoleteBossPrefix')]"))
    if ($obsoleteBossSettings.Count -gt 0) {
        throw "Obsolete Boss setting prefix must be removed: $($obsoleteBossSettings.Id -join ', ')"
    }
}
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

foreach ($lssPair in @(
    @{ Name = 'Chinese'; Document = $chineseLss },
    @{ Name = 'English'; Document = $englishLss }
)) {
    $autoSplitterNodes = @($lssPair.Document.SelectNodes('/Run/AutoSplitterSettings'))
    if ($autoSplitterNodes.Count -ne 1) {
        throw "$($lssPair.Name) LSS must contain one AutoSplitterSettings node."
    }
    if ($autoSplitterNodes[0].HasChildNodes) {
        throw "$($lssPair.Name) LSS AutoSplitterSettings must be empty like bmw.lss."
    }
}

$expectedMain = @{
    1 = @('Montage_UGuid.HFS.Niu.Teacher','Montage_UGuid.HFS.GuangZhi','Montage_UGuid.HFS.TongChi01','Montage_UGuid.HFS.DBL0','Montage_UGuid.HFS.GuangM0','Montage_UGuid.HFS.Baiyi0','Montage_UGuid.HFS.BaiyiT2','Montage_UGuid.HFS.XiongR0','Montage_UGuid.HFS.XiongX0')
    2 = @('Montage_UGuid.HFM.FuZiShu.ZS0','Montage_UGuid.HFM.ShiXianFeng','Montage_UGuid.HFM.HuXianFeng.Hu0','Montage_UGuid.HFM.HFDS.H0')
    3 = @('Action_UGuid.LYS.XueHou.NM@AM_lys_xuehou_leave_01','Montage_UGuid.LYS.XueHou.NM','Montage_UGuid.LYS.KJL.Long','Montage_UGuid.LYS.Mo_01','Montage_UGuid.LYS.XueHou.AnShen','Montage_UGuid.LYS.KJL.Women','Slow_UGuid.LYS.SengMian','Montage_UGuid.LYS.SengMian02','Montage_UGuid.LYS.Mo2','Action_UGuid.LYS.HuangMei.Big@AM_LYS_HuangMei_02_FinalTWZ','Montage_UGuid.LYS.RBM','Montage_UGuid.LYS.HuangMei.Small')
    4 = @('Montage_UGuid.PSD.Erjie.Village','Montage_UGuid.PSD.FSC01.foshouchong','Montage_UGuid.PSD.BaJie.Mo','Montage_UGuid.PSD.BaJie.Ye','Montage_UGuid.PSD.LaoZhiZhu','Montage_UGuid.PSD.BaiYanMoJun')
    5 = @('Dual_UGuid.HYS.JiRuHuo01+UGuid.HYS.KuaiRuFeng01','Montage_TAMER_hys_huijingtitan_01','Dual_UGuid.HYS.WuLiYun+UGuid.HYS.YunLiWu','Montage_UGuid.HYS.HongHaiEr','Montage_UGuid.HYS.YeChaWang')
    6 = @('Montage_UGuid.BYS.WLG.01','Montage_UGuid.BYS.Xiniu','Montage_UGuid.BYS.Xuelu','Montage_UGuid.BYS.TangLang','Montage_UGuid.MGD.Yuan','Montage_UGuid.MGD.JSDS.P2')
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
    $actualMain = @($chapterNode.SelectSingleNode("./Setting[@Id='Chapter${chapter}MainBosses']").SelectNodes('./Setting') | ForEach-Object { ($_.Id -replace '^Action_(UGuid\.[^@]+)@.*$', '$1') -replace '^(Montage_|Slow_|Despawn_|Dual_)', '' })
    $expectedMainIds = @($expectedMain[$chapter] | ForEach-Object { ($_ -replace '^Action_(UGuid\.[^@]+)@.*$', '$1') -replace '^(Montage_|Slow_|Despawn_|Dual_)', '' })
    if (($actualMain -join '|') -ne ($expectedMainIds -join '|')) {
        throw "Main Boss classification changed unexpectedly for chapter $chapter"
    }
}

$bossSettings = @($defaultDocument.SelectNodes('//Setting[not(Setting) and (starts-with(@Id,"Montage_") or starts-with(@Id,"Slow_") or starts-with(@Id,"Dual_") or starts-with(@Id,"Despawn_") or starts-with(@Id,"Action_") or starts-with(@Id,"Seq_") or starts-with(@Id,"UGuid.") or starts-with(@Id,"Boss_"))]'))
$expectedDisabledBossIds = @(
    'Montage_UGuid.ZYS.XieZi.MRXG',
    'Montage_TAMER_hys_huijingtitan_01',
    'Montage_UGuid.PSD.WLG'
)
$disabledBossSettings = @($bossSettings | Where-Object { $_.State -ne 'true' })
$unexpectedDisabledBossSettings = @($disabledBossSettings | Where-Object { $_.Id -notin $expectedDisabledBossIds })
if ($unexpectedDisabledBossSettings.Count -gt 0) {
    throw "Unexpected disabled Boss settings: $($unexpectedDisabledBossSettings.Id -join ', ')"
}
foreach ($id in $expectedDisabledBossIds) {
    $setting = $defaultDocument.SelectSingleNode("//Setting[@Id='$id']")
    if ($null -eq $setting -or $setting.State -ne 'false') {
        throw "Expected disabled Boss setting is missing or enabled: $id"
    }
}

$expectedParents = @{
    'Montage_UGuid.HFS.TongChi01' = 'Chapter1MainBosses'
    'Montage_UGuid.HFS.BaiyiT2' = 'Chapter1MainBosses'
    'Montage_UGuid.HFS.JCZL' = 'Chapter1YaoguaiKingBosses'
    'Montage_UGuid.HFS.WaBig' = 'Chapter1ChiefBosses'
    'Montage_UGuid.HFM.Suoyang' = 'Chapter2ChiefBosses'
    'Montage_UGuid.HFM.LaPapesse' = 'Chapter2ChiefBosses'
    'Montage_UGuid.LYS.Mo4' = 'Chapter3ChiefBosses'
    'Montage_UGuid.LYS.RuYiLong.01' = 'Chapter3ChiefBosses'
    'Seq_LS_pw_fenghu_battlewin' = 'Chapter3ChiefBosses'
    'Montage_UGuid.EndB.YangJian' = 'Chapter3ChiefBosses'
    'Montage_UGuid.EndB.YangJian.FTXD' = 'Chapter3ChiefBosses'
    'Montage_UGuid.PSD.Wa.01' = 'Chapter4ChiefBosses'
    'Montage_UGuid.LYS.fsys' = 'Chapter3ChiefBosses'
    'Montage_UGuid.PSD.YouYan' = 'Chapter4ChiefBosses'
    'Montage_UGuid.PSD.JCZB' = 'Chapter4ChiefBosses'
    'Montage_TAMER_psd_zhusun_03' = 'Chapter4ChiefBosses'
    'Montage_UGuid.PSD.WLG' = 'Chapter4ChiefBosses'
    'Montage_UGuid.ZYS.DaoShi.Fight' = 'Chapter4ChiefBosses'
    'Montage_UGuid.ZYS.Daoshi.P2' = 'Chapter4ChiefBosses'
    'Montage_UGuid.HYS.YSCheng' = 'Chapter5ChiefBosses'
    'Montage_TAMER_pds_lingzhijing_03a' = 'Chapter5ChiefBosses'
    'Action_UGuid.HYS.JDS.01@AM_hys_niumo_quest_trans_01' = 'Chapter5YaoguaiKingBosses'
    'Montage_UGuid.BYS.HMS.02' = 'Chapter6ChiefBosses'
    'Montage_UGuid.BYS.Shitongling.03' = 'Chapter6ChiefBosses'
    'Montage_UGuid.BYS.hema.king' = 'Chapter6ChiefBosses'
    'Montage_UGuid.BYS.Baishe' = 'Chapter6ChiefBosses'
    'Action_UGuid.SL.sgd@*break*' = 'Chapter6YaoguaiKingBosses'
    'Montage_UGuid.LYS.Mo3.FM' = 'Chapter3ChiefBosses'
    'Montage_UGuid.LYS.TuiSeng.P1' = 'Chapter3ChiefBosses'
    'Montage_UGuid.LYS.TuiSeng.P2' = 'Chapter3ChiefBosses'
    'Montage_TAMER_psd_renshenjing_02a' = 'Chapter3ChiefBosses'
    'Montage_UGuid.PSD.WuLong' = 'Chapter4YaoguaiKingBosses'
    'Montage_UGuid.PSD.WuLong.4H' = 'Chapter4YaoguaiKingBosses'
    'Montage_UGuid.PSD.Dage' = 'Chapter4YaoguaiKingBosses'
    'Montage_UGuid.ZYS.XieZi.MRXG' = 'Chapter4YaoguaiKingBosses'
    'Montage_UGuid.ZYS.MRXG' = 'Chapter4YaoguaiKingBosses'
    'Montage_UGuid.HYS.TuDi.YS' = 'Chapter5YaoguaiKingBosses'
}
foreach ($expected in $expectedParents.GetEnumerator()) {
    $node = $defaultDocument.SelectSingleNode("//Setting[@Id='$($expected.Key)']")
    if ($null -eq $node -or $node.ParentNode.Id -ne $expected.Value) {
        throw "Unexpected boss category for $($expected.Key): expected $($expected.Value)"
    }
}

$expectedMappings = @{
    'Boss_103006' = 'Montage_UGuid.HFS.JCZL'
    'Boss_103007' = 'Montage_UGuid.HFS.WoodDragon'
    'Boss_203002' = 'Montage_UGuid.HFM.ShuWang_01a.SW0'
    'Boss_302003' = 'Montage_UGuid.LYS.Mo3.FM'
    'Boss_302013' = 'Montage_UGuid.LYS.Mo4'
    'Boss_302004' = 'Montage_UGuid.LYS.JianLong.Fight'
    'Boss_402012' = 'Montage_UGuid.PSD.Dage'
    'Boss_502005' = 'Dual_UGuid.HYS.XingGongXian+UGuid.HYS.XianGongXing'
    'Boss_703001' = 'Montage_UGuid.BSD.JJS'
    'Boss_803001' = 'Montage_UGuid.ZYS.XieZi.MRXG'
    'Boss_803002' = 'Montage_UGuid.ZYS.MRXG'
    'Boss_202001' = 'Montage_UGuid.HFS.WaBig'
    'Boss_202028' = 'Montage_UGuid.HFM.Suoyang'
    'Boss_202007' = 'Montage_UGuid.HFM.LaPapesse'
    'Boss_301002' = 'Montage_UGuid.LYS.fsys'
    'Boss_402001' = 'Montage_UGuid.PSD.YouYan'
    'Boss_402009' = 'Montage_UGuid.PSD.JCZB'
    'Boss_402007' = 'Montage_UGuid.ZYS.DaoShi.Fight'
    'Boss_501017' = 'Montage_UGuid.HYS.YSCheng'
    'Boss_502013' = 'Action_UGuid.HYS.JDS.01@AM_hys_niumo_quest_trans_01'
    'Boss_602007' = 'Montage_UGuid.BYS.HMS.02'
    'Boss_602006' = 'Montage_UGuid.BYS.Shitongling.03'
    'Boss_602009' = 'Montage_UGuid.BYS.hema.king'
    'Boss_103003' = 'Montage_UGuid.BYS.Baishe'
    'Boss_603001' = 'Action_UGuid.SL.sgd@*break*'
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

$legacyBossSettings = @($defaultDocument.SelectNodes('//Setting[starts-with(@Id,"Boss_")]'))
if ($legacyBossSettings.Count -gt 0) {
    throw "Legacy Boss_* settings must be replaced by direct Tamer setting ids: $($legacyBossSettings.Id -join ', ')"
}
$expectedDirectTamerSettings = @(
    'Montage_TAMER_hfm_hou_01a',
    'Montage_TAMER_HFM_ShiTongLing_02a',
    'Montage_TAMER_hys_shixianfeng_02',
    'Montage_TAMER_hys_huolingsha_01',
    'Montage_TAMER_psd_renshenjing_02a',
    'Montage_TAMER_hys_huijingtitan_01',
    'Montage_TAMER_psd_zhusun_03',
    'Montage_TAMER_pds_lingzhijing_03a'
)
foreach ($id in $expectedDirectTamerSettings) {
    if ($null -eq $defaultDocument.SelectSingleNode("//Setting[@Id='$id']")) {
        throw "Direct Tamer Boss setting is missing: $id"
    }
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
$legacyYangjian = $defaultDocument.SelectSingleNode('//Setting[@Id="Montage_UGuid.MGD.yangjian.start"]')
if ($null -eq $defaultYangjian -or $null -eq $englishYangjian) {
    throw "Erlang must use the Despawn_UGuid setting prefix."
}
if ($null -ne $legacyYangjian) {
    throw "Erlang must not keep the legacy Montage_UGuid setting."
}
if ($defaultYangjian.Label -match '推荐|Recommended|Fight Manually' -or
    $englishYangjian.Label -match 'Recommended|Fight Manually') {
    throw "Erlang recommendation text must be removed."
}
if ($defaultYangjian.State -ne 'true' -or $englishYangjian.State -ne 'true') {
    throw "Erlang Boss setting must default to enabled."
}

$aslText = [IO.File]::ReadAllText($aslPath)
if (-not $aslText.Contains('byte[] actorBytes = vars.Resolver.ReadBytes(actors, actorCount * 8);')) {
    throw "Generated ASL must bulk-read the world Actor pointer array."
}
if (-not $aslText.Contains('vars.ActorNameByPtr = new Dictionary<long, string>();') -or
    -not $aslText.Contains('Dictionary<long, string> actorNameByPtr =')) {
    throw "Generated ASL must cache Actor names by pointer in large worlds."
}
if (-not $aslText.Contains('vars.MinBossActorSeenTicks = TimeSpan.TicksPerMillisecond * 500;')) {
    throw "Generated ASL must use the 500ms Boss Actor observation window."
}
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
if ($aslText.Contains('CutsceneNotifyFlag') -or
    $aslText.Contains('ReadCutsceneDisableCameraCuts') -or
    $aslText.Contains('ReadUnrealFString')) {
    throw "Generated ASL still contains the redundant PlayLevelSequence notification path or unused FString reader."
}
if (-not $aslText.Contains('FunctionParentPtr<IntPtr>("SeqPlayerPlayInstance", "*LevelSequencePlayer*", null, "Play");')) {
    throw "Generated ASL does not capture the sequence player Play event."
}
if (-not $aslText.Contains('FunctionFlag("SeqCameraCutsFlag", "*LevelSequencePlayer*", null, "SetDisableCameraCuts");')) {
    throw "Generated ASL does not hook LevelSequencePlayer.SetDisableCameraCuts."
}
if (-not $aslText.Contains('SeqCameraCutsGuardTicks') -or
    -not $aslText.Contains('bool controlReturned = matchesActive') -or
    -not $aslText.Contains('cameraCutsElapsedTicks > (long)vars.SeqCameraCutsGuardTicks;')) {
    throw "Generated ASL does not use the camera-cuts control-return guard."
}
if ($aslText.Contains('CalliopeLevelSequenceActor') -or
    $aslText.Contains('BGULevelSequenceActor') -or
    $aslText.Contains('actor-fallback')) {
    throw "Generated ASL still contains the removed SequenceActor fallback path."
}
if (-not $aslText.Contains('FunctionFlag("BinkPlayFlag", "BinkMediaPlayer", null, "Play");')) {
    throw "Generated ASL does not hook BinkMediaPlayer Play."
}
if (-not $aslText.Contains('FunctionFlag("BinkStopFlag", "BinkMediaPlayer", null, "Stop");')) {
    throw "Generated ASL does not hook BinkMediaPlayer Stop."
}
if (-not $aslText.Contains('"[BMW-loading] isLoading=" + loading')) {
    throw "Generated ASL does not expose the overall loading signal."
}
if ($aslText.Contains('"[BMW-loading] cutscene loading:')) {
    throw "Generated ASL still contains the redundant cutscene loading transition log."
}
if (-not $aslText.Contains('cutsceneSequence')) {
    throw "Generated ASL does not classify LevelSequencePlayer playback by sequence name."
}
if (-not $aslText.Contains('sequenceName.IndexOf("LSM_", StringComparison.OrdinalIgnoreCase)')) {
    throw "Generated ASL does not recognize LSM_ movie sequences."
}
$seqPlayMatch = [regex]::Match(
    $aslText,
    'if \(vars\.Resolver\.CheckFlag\("SeqPlayerPlayFlag"\)\)(?<block>.*?)if \(vars\.Resolver\.CheckFlag\("SeqPlayerStopFlag"\)\)',
    [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $seqPlayMatch.Success) {
    throw "Generated ASL does not isolate the SequencePlayer Play block."
}
$seqPlayBlock = $seqPlayMatch.Groups['block'].Value
if (-not $seqPlayBlock.Contains('string sequenceSetting = "Seq_" + sequenceName;') -or
    -not $seqPlayBlock.Contains('vars.TryQueueSetting(sequenceSetting, "sequence");')) {
    throw "Generated ASL must queue Seq_ settings by sequenceName on Play."
}

$binkPlayMatch = [regex]::Match(
    $aslText,
    'if \(vars\.Resolver\.CheckFlag\("BinkPlayFlag"\)\)(?<block>.*?)if \(vars\.Resolver\.CheckFlag\("BinkStopFlag"\)\)',
    [Text.RegularExpressions.RegexOptions]::Singleline)
$binkStopMatch = [regex]::Match(
    $aslText,
    'if \(vars\.Resolver\.CheckFlag\("BinkStopFlag"\)\)(?<block>.*?)IntPtr activeSequence',
    [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $binkPlayMatch.Success -or -not $binkStopMatch.Success) {
    throw "Generated ASL does not isolate the Bink Play/Stop blocks."
}
$binkPlayBlock = $binkPlayMatch.Groups['block'].Value
$binkStopBlock = $binkStopMatch.Groups['block'].Value
if (-not $binkPlayBlock.Contains('bool chapterEndBink = binkName == "BinkMoviePlayer_Chapter";') -or
    -not $binkPlayBlock.Contains('if (chapterEndBink)') -or
    -not $binkPlayBlock.Contains('vars.CutscenePending = true;') -or
    -not $binkPlayBlock.Contains('vars.ActiveBinkPlayer = bink;')) {
    throw "Generated ASL must enable loading only for BinkMoviePlayer_Chapter on Play."
}
if (-not $binkStopBlock.Contains('bool chapterEndBink = binkName == "BinkMoviePlayer_Chapter";') -or
    -not $binkStopBlock.Contains('bool earlyStop = matchesActive') -or
    -not $binkStopBlock.Contains('&& stopElapsed <= (long)vars.BinkEarlyStopGuardTicks;') -or
    -not $binkStopBlock.Contains('if (matchesActive && !earlyStop)')) {
    throw "Generated ASL must keep the chapter-end Bink early Stop guard."
}
if ($binkPlayBlock.Contains('binkUrl') -or
    $binkStopBlock.Contains('binkUrl') -or
    $binkPlayBlock.Contains('0x98') -or
    $binkStopBlock.Contains('0x98')) {
    throw "Bink chapter-end detection must use only BinkMoviePlayer_Chapter and must not read the URL."
}
foreach ($eventLog in @(
    '"[BMW-bink] play player=0x"',
    '"[BMW-bink] stop player=0x"',
    '"[BMW-bink] end reason=stop player=0x"',
    '"[BMW-seq] play player=0x"',
    '"[BMW-seq] stop player=0x"',
    '"[BMW-seq] camera-cuts player=0x"',
    '"[BMW-seq] end reason=stop player=0x"',
    '"[BMW-seq] end reason=camera-cuts player=0x"',
    '"[BMW-seq] end reason=status player=0x"'
)) {
    if (-not $aslText.Contains($eventLog)) {
        throw "Generated ASL is missing detailed Bink/Sequence event log $($eventLog)."
    }
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
if (-not $aslText.Contains('Assembly.Load(File.ReadAllBytes(Path.Combine(componentDir, "uhara10-BMW"))).CreateInstance("Main");')) {
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
if (-not $aslText.Contains('vars.Uhara.Log(')) {
    throw "Generated ASL must route logs through uHara: $aslPath"
}
if (-not $aslText.Contains('DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff")')) {
    throw "Generated ASL must prefix uHara log messages with a millisecond timestamp: $aslPath"
}
if ($aslText.Contains('BMW-Hook-AutoSplitter.log') -or $aslText.Contains('vars.LogPath')) {
    throw "Generated ASL must not keep the legacy private log file: $aslPath"
}
if (-not $aslText.Contains('"[BMW-action] actor action changed: uid="')) {
    throw "Generated ASL action-change log is missing: $aslPath"
}
if ($aslText.Contains('"[BMW-action] actor despawn: uid="') -or
    $aslText.Contains('lastNonEmptyAction') -or
    $aslText.Contains('deathActionSeen') -or
    $aslText.Contains('lastCustomSettings')) {
    throw "Generated ASL still contains the removed verbose actor-despawn diagnostics: $aslPath"
}
if ($aslText.Contains('"ActionDebugLog", false')) {
    throw "Generated ASL action-change log must not depend on ActionDebugLog: $aslPath"
}
if (-not $aslText.Contains('+ " action=" + currentAction') -or
    -not $aslText.Contains('+ " deathAction=" + deathAction')) {
    throw "Generated ASL action-change log is missing action/death fields: $aslPath"
}
if ($aslText.Contains('vars.ReadActionDetails') -or
    $aslText.Contains('vars.ReadMontageArrays') -or
    $aslText.Contains('"[BMW-action] actor montage state: uid="') -or
    $aslText.Contains('MontageSampleIntervalTicks') -or
    $aslText.Contains('" details="') -or
    $aslText.Contains('" arrays="') -or
    $aslText.Contains('"itemOffset=0x"') -or
    $aslText.Contains('"[18]=0x"')) {
    throw "Generated ASL still contains verbose Montage diagnostics: $aslPath"
}
if (-not $aslText.Contains('new int[] { 0x88, 0x128, 0x138 }') -or
    -not $aslText.Contains('int[] montagePointerOffsets = new int[] { 0x0, 0x18 }')) {
    throw "Generated ASL does not retain the full Montage reader: $aslPath"
}
if (-not $aslText.Contains('vars.LoadActionSplits = (Action)') -or
    -not $aslText.Contains('//Setting[starts-with(@Id, ''Action_'')]') -or
    -not $aslText.Contains('vars.TryQueueActionSplits = (Func<string, string, bool>)') -or
    -not $aslText.Contains('"action:" + pattern')) {
    throw "Generated ASL does not parse and queue Action_UGuid@action settings: $aslPath"
}
if (-not $aslText.Contains('uid.StartsWith("TAMER_", StringComparison.OrdinalIgnoreCase)')) {
    throw "Generated ASL rejects Action_TAMER_* settings during action parsing: $aslPath"
}
if (-not $aslText.Contains('bool startsWithWildcard = pattern.StartsWith("*", StringComparison.Ordinal);') -or
    -not $aslText.Contains('action.IndexOf(value, StringComparison.OrdinalIgnoreCase) >= 0') -or
    -not $aslText.Contains('action.EndsWith(value, StringComparison.OrdinalIgnoreCase)') -or
    -not $aslText.Contains('action.StartsWith(value, StringComparison.OrdinalIgnoreCase)')) {
    throw "Generated ASL does not support leading/trailing Action wildcards such as *break*: $aslPath"
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
if (-not $aslText.Contains('"Montage_" + uid')) {
    throw "Generated ASL does not map UGuid actors to Montage_UGuid settings: $aslPath"
}
if (-not $aslText.Contains('string slowSetting = "Slow_" + uid;')) {
    throw "Generated ASL does not resolve Slow_UGuid settings: $aslPath"
}
if ($aslText.Contains($obsoleteBossPrefix)) {
    throw "Generated ASL still contains the obsolete Boss setting prefix: $aslPath"
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
    throw "Generated ASL must retain appearance/despawn logs for all tracked Boss actors: $aslPath"
}
if (-not $aslText.Contains('vars.SeenTamerTokens = new HashSet<string>(StringComparer.OrdinalIgnoreCase)') -or
    -not $aslText.Contains('if (seenTamerTokens.Add(token))') -or
    -not $aslText.Contains('"[BMW-splitter] tamer first seen: baseToken="') -or
    -not $aslText.Contains('+ " token=" + token')) {
    throw "Generated ASL does not deduplicate and log first-seen TAMER baseToken/token: $aslPath"
}
if (-not $aslText.Contains('vars.StripActorInstanceSuffix = (Func<string, string>)') -or
    -not $aslText.Contains('vars.ResolveActorUid = (Func<string, string>)') -or
    -not $aslText.Contains('actorName.IndexOf("-TAMER_", StringComparison.OrdinalIgnoreCase)') -or
    -not $aslText.Contains('settings.ContainsKey("Montage_" + token)') -or
    -not $aslText.Contains('settings.ContainsKey("Slow_" + token)') -or
    -not $aslText.Contains('vars.ActionSplitsByActor.ContainsKey(token)') -or
    -not $aslText.Contains('vars.ActionSplitsByActor.ContainsKey(baseToken)')) {
    throw "Generated ASL does not resolve GUID-TAMER Boss actors through Montage/Slow/Despawn/Action settings: $aslPath"
}
if ($aslText.Contains('BossActorAliases')) {
    throw "Generated ASL must not contain the removed BossActorAliases table: $aslPath"
}
foreach ($directId in @(
    'Montage_TAMER_hfm_hou_01a',
    'Montage_TAMER_HFM_ShiTongLing_02a',
    'Montage_TAMER_hys_shixianfeng_02',
    'Montage_TAMER_hys_huolingsha_01',
    'Montage_TAMER_psd_renshenjing_02a',
    'Montage_TAMER_hys_huijingtitan_01',
    'Montage_TAMER_psd_zhusun_03',
    'Montage_TAMER_pds_lingzhijing_03a'
)) {
    if ($null -eq $defaultDocument.SelectSingleNode("//Setting[@Id='$directId']")) {
        throw "Generated settings are missing direct Tamer Boss id ${directId}: $aslPath"
    }
}
if (-not $aslText.Contains('+ " name=" + actorName')) {
    throw "Generated ASL appearance logs do not include the raw Actor name: $aslPath"
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
if (-not $aslText.Contains('if (source != "slow-motion"') -or
    -not $aslText.Contains('setting.StartsWith("Slow_", StringComparison.Ordinal)')) {
    throw "Generated ASL does not restrict Slow_ settings to slow-motion: $aslPath"
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
if (-not $aslText.Contains('vars.RegisterDualMontage(uid);')) {
    throw "Generated ASL does not feed death-montage edges into dual Boss tracking: $aslPath"
}
if ($aslText.Contains('"hidden"') -or
    $aslText.Contains('hiddenSplits') -or
    $aslText.Contains('previousHidden') -or
    $aslText.Contains('bHidden')) {
    throw "Generated ASL still contains hidden-based split logic: $aslPath"
}
if (-not $aslText.Contains('vars.ResetDualActor = (Action<string>)') -or
    -not $aslText.Contains('foreach (string setting in vars.DualSplits.Keys)') -or
    -not $aslText.Contains('dualHits[setting] = new HashSet<string>();')) {
    throw "Generated ASL does not reset stale dual Boss montage progress: $aslPath"
}
$removedVerboseLogs = @(
    'startup begin',
    'combat feedback changed',
    'tracked UGuid actors',
    'removal candidate',
    'removal canceled',
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

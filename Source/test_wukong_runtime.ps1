<#
.SYNOPSIS
验证生成的黑神话：悟空运行时文件没有注释，并编译解析 ASL。

.PARAMETER RepositoryRoot
BMW_AutoSplitter 仓库根目录，默认是本脚本目录的上级目录。

.PARAMETER LiveSplitRoot
包含 LiveSplit.Core.dll 和 Scriptable Auto Splitter 组件的 LiveSplit
安装目录，默认是 RepositoryRoot 的上级目录。

.OUTPUTS
输出 ASL_PARSE_OK 行，最后输出 WUKONG_RUNTIME_TEST_OK。
#>
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$LiveSplitRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "comment_tools.ps1")

$components = Join-Path $RepositoryRoot "Components"
$aslPath = Join-Path $components "BlackMythWukong.asl"
$xmlPaths = @(
    (Join-Path $components "BMWukong.Settings.xml"),
    (Join-Path $components "BMWukong.Settings.en.xml")
)
$aslHelpPath = Join-Path $components "asl-help"

Assert-CSharpCommentsRemoved -Path $aslPath
foreach ($xmlPath in $xmlPaths) {
    Assert-XmlCommentsRemoved -Path $xmlPath
}

if (-not (Test-Path -LiteralPath $aslHelpPath -PathType Leaf)) {
    throw "asl-help dependency is missing: $aslHelpPath"
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
if ($null -eq $defaultAutoSplit -or $defaultAutoSplit.State -ne "false") {
    throw "AutoSplitEnabled must exist and default to false in BMWukong.Settings.xml"
}
if ($null -eq $englishAutoSplit -or $englishAutoSplit.State -ne "false") {
    throw "AutoSplitEnabled must exist and default to false in BMWukong.Settings.en.xml"
}

$defaultSettings = @($defaultDocument.SelectNodes('//Setting'))
$englishSettings = @($englishDocument.SelectNodes('//Setting'))
if ($defaultSettings.Count -ne $englishSettings.Count) {
    throw "Chinese and English settings have different item counts."
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

$aslText = [IO.File]::ReadAllText($aslPath)
if (-not $aslText.Contains('Assembly.Load(File.ReadAllBytes(Path.Combine(componentDir, "asl-help"))).CreateInstance("Basic");')) {
    throw "Generated ASL does not load asl-help: $aslPath"
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
if (-not $aslText.Contains('vars.IsAutoSplitEnabled')) {
    throw "Generated ASL does not enforce AutoSplitEnabled: $aslPath"
}
if (-not $aslText.Contains('bool autoSplitEnabled = ((Func<bool>)vars.IsAutoSplitEnabled)();')) {
    throw "Generated ASL does not gate new split events with AutoSplitEnabled: $aslPath"
}
if (-not $aslText.Contains('if (enabled && autoSplitEnabled)')) {
    throw "Generated ASL portrait splits are not gated by AutoSplitEnabled: $aslPath"
}
if (-not $aslText.Contains('if (enabled && autoSplitEnabled && vars.completedSplits.Add(settingId))')) {
    throw "Generated ASL dead-unit splits are not gated by AutoSplitEnabled: $aslPath"
}

$startupIndex = $aslText.IndexOf("`nstartup", [StringComparison]::Ordinal)
$initIndex = $aslText.IndexOf("`ninit", [StringComparison]::Ordinal)
if ($startupIndex -lt 0 -or $initIndex -le $startupIndex) {
    throw "Could not locate startup/init lifecycle blocks: $aslPath"
}
$startupText = $aslText.Substring($startupIndex, $initIndex - $startupIndex)
$initText = $aslText.Substring($initIndex)
$loadInvocation = "((Action)vars.LoadSettings)();"
if (-not $startupText.Contains($loadInvocation)) {
    throw "Settings are not loaded during startup: $aslPath"
}
if ($initText.Contains($loadInvocation)) {
    throw "Settings must not be loaded during init: $aslPath"
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
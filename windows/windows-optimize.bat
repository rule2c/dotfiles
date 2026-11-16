<# :
@echo off
net session >nul 2>&1
if errorlevel 1 (
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$f='%~f0'; iex ([IO.File]::ReadAllText($f,[Text.Encoding]::UTF8))"
pause
exit /b
#>

# ============================================================
#  Windows 一键优化：性能 + 后台内存 + 隐私
#  双击运行，自动请求管理员权限。可重复运行，已改过的项不会出问题。
#  改动前的注册表会备份到 桌面\优化前注册表备份
# ============================================================

$bk = Join-Path ([Environment]::GetFolderPath('Desktop')) '优化前注册表备份'
New-Item -ItemType Directory -Force $bk | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($k in 'HKCU\Control Panel', 'HKCU\Software\Microsoft\Windows\CurrentVersion', 'HKCU\Software\Microsoft\InputPersonalization',
               'HKCU\Software\Microsoft\Siuf', 'HKCU\Software\Microsoft\Speech_OneCore', 'HKCU\Software\Microsoft\Personalization',
               'HKCU\Software\Policies', 'HKLM\SOFTWARE\Policies', 'HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting',
               'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved') {
    reg export $k ("$bk\$stamp-" + ($k -replace '[\\ ]', '_') + '.reg') /y 2>$null | Out-Null
}
Get-Service DiagTrack, MapsBroker, Spooler, dmwappushservice, WerSvc -ErrorAction SilentlyContinue |
    Select-Object Name, StartType | Export-Csv "$bk\$stamp-services.csv" -NoTypeInformation -Encoding UTF8
"原电源模式: " + (powercfg /overlaygetactive 2>$null) | Out-File "$bk\$stamp-power.txt" -Encoding utf8

$script:ok = 0; $script:fail = @()
function S($path, $name, $val, $type = 'DWord') {
    try {
        if (-not (Test-Path $path)) { New-Item $path -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty $path $name $val -Type $type -ErrorAction Stop
        $script:ok++
    } catch { $script:fail += "$path\$name : $($_.Exception.Message)" }
}
function Svc($name) {
    if (-not (Get-Service $name -ErrorAction SilentlyContinue)) { return }
    Stop-Service $name -Force -ErrorAction SilentlyContinue
    try { Set-Service $name -StartupType Disabled -ErrorAction Stop; $script:ok++ } catch { $script:fail += "服务 $name : $($_.Exception.Message)" }
}
function Section($t) { Write-Host "`n== $t ==" -ForegroundColor Cyan }

$CV = 'HKCU:\Software\Microsoft\Windows\CurrentVersion'
$ADV = "$CV\Explorer\Advanced"
$P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
$UP = 'HKCU:\Software\Policies\Microsoft\Windows'

# ------------------------------------------------------------
Section '1. 性能：后台应用、视觉效果、电源'
S "$CV\BackgroundAccessApplications" GlobalUserDisabled 1
S "$CV\Search" BackgroundAppGlobalToggle 0
# 例外：允许这些应用在后台运行（包系列名，可自行添加）
$bgAllow = @('Claude_pzs8sxrjxfjjc')
foreach ($pfn in $bgAllow) {
    S "$CV\BackgroundAccessApplications\$pfn" Disabled 0
    S "$CV\BackgroundAccessApplications\$pfn" DisabledByUser 0
}
S "$P\AppPrivacy" LetAppsRunInBackground_ForceAllowTheseApps ([string[]]$bgAllow) 'MultiString'
S "$CV\Explorer\VisualEffects" VisualFXSetting 3
S 'HKCU:\Control Panel\Desktop' UserPreferencesMask ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) 'Binary'
S 'HKCU:\Control Panel\Desktop' FontSmoothing '2' 'String'
S 'HKCU:\Control Panel\Desktop' MenuShowDelay '100' 'String'
S 'HKCU:\Control Panel\Desktop\WindowMetrics' MinAnimate '0' 'String'
S $ADV TaskbarAnimations 0
S $ADV ListviewAlphaSelect 0
S $ADV ListviewShadow 0
S $ADV IconsOnly 0
S "$CV\Themes\Personalize" EnableTransparency 0
S 'HKCU:\Software\Microsoft\Windows\DWM' EnableAeroPeek 0
powercfg /overlaysetactive ded574b5-45a0-4f42-8737-46345c09c238 2>$null   # 最佳性能
if ($LASTEXITCODE -eq 0) { $script:ok++ } else { $script:fail += '电源模式: 设置最佳性能失败' }
# 关闭快速启动: 让"关机"真正断电, 避免关机后继续耗电
S 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' HiberbootEnabled 0

# ------------------------------------------------------------
Section '2. 服务与开机启动项'
Svc DiagTrack          # 遥测
Svc MapsBroker         # 离线地图
Svc Spooler            # 打印（要打印时改回“自动”）
Svc dmwappushservice   # WAP 推送（遥测相关）
Svc WerSvc             # 错误报告
$ap = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
foreach ($n in 'RTHDVCPL', 'RtHDVBg_WAVES_SKYLAKE', 'WavesSvc') {   # 音频托盘程序，可在任务管理器“启动应用”里恢复
    S $ap $n ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) 'Binary'
}

# ------------------------------------------------------------
Section '3. 小组件 (Widgets)'
Get-Process Widgets, WidgetService, WidgetBoard -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$wx = Get-AppxPackage MicrosoftWindows.Client.WebExperience
if ($wx) {
    try { $wx | Remove-AppxPackage -ErrorAction Stop; $script:ok++ } catch { $script:fail += "卸载小组件: $($_.Exception.Message)" }
} else { Write-Host '  已卸载，跳过' }

# ------------------------------------------------------------
Section '4. 隐私：搜索'
S "$CV\SearchSettings" IsDynamicSearchBoxEnabled 0      # 搜索要点
S "$CV\SearchSettings" IsAADCloudSearchEnabled 0
S "$CV\SearchSettings" IsMSACloudSearchEnabled 0
S "$CV\SearchSettings" IsDeviceSearchHistoryEnabled 0
S "$CV\SearchSettings" SafeSearchMode 0
S "$CV\Search" BingSearchEnabled 0
S "$CV\Search" CortanaConsent 0
S "$P\Windows Search" AllowCortana 0
S "$P\Windows Search" DisableWebSearch 1
S "$P\Windows Search" ConnectedSearchUseWeb 0
S "$P\Windows Search" EnableDynamicContentInWSB 0
S "$P\Windows Search" AllowCloudSearch 0
S "$UP\Explorer" DisableSearchBoxSuggestions 1

# ------------------------------------------------------------
Section '5. 隐私：遥测、诊断、活动历史'
S "$P\DataCollection" AllowTelemetry 0
S 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' AllowTelemetry 0
S "$P\DataCollection" DoNotShowFeedbackNotifications 1
S "$P\DataCollection" AllowDeviceNameInTelemetry 0
S "$P\DataCollection" LimitDiagnosticLogCollection 1
S "$P\DataCollection" LimitDumpCollection 1
S "$P\AppCompat" AITEnable 0
S "$P\AppCompat" DisableInventory 1
S 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' CEIPEnable 0
S 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' Disabled 1
S "$P\Windows Error Reporting" Disabled 1
S "$P\System" EnableActivityFeed 0
S "$P\System" PublishUserActivities 0
S "$P\System" UploadUserActivities 0
S 'HKCU:\Software\Microsoft\Siuf\Rules' NumberOfSIUFInPeriod 0
S 'HKCU:\Software\Microsoft\Siuf\Rules' PeriodInNanoSeconds 0 'QWord'
S "$CV\CapabilityAccessManager\ConsentStore\appDiagnostics" Value 'Deny' 'String'

# ------------------------------------------------------------
Section '6. 隐私：广告、推荐与推广内容'
S "$CV\AdvertisingInfo" Enabled 0
S "$P\AdvertisingInfo" DisabledByGroupPolicy 1
S "$CV\Privacy" TailoredExperiencesWithDiagnosticDataEnabled 0
S 'HKCU:\Control Panel\International\User Profile' HttpAcceptLanguageOptOut 1
S $ADV Start_TrackProgs 0
S $ADV Start_IrisRecommendations 0
S $ADV Start_AccountNotifications 0
S $ADV ShowSyncProviderNotifications 0
$cdm = "$CV\ContentDeliveryManager"
foreach ($n in 'ContentDeliveryAllowed', 'FeatureManagementEnabled', 'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled',
               'PreInstalledAppsEverEnabled', 'SilentInstalledAppsEnabled', 'SoftLandingEnabled', 'SystemPaneSuggestionsEnabled',
               'RotatingLockScreenOverlayEnabled', 'SubscribedContentEnabled', 'SubscribedContent-310093Enabled',
               'SubscribedContent-338387Enabled', 'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
               'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled',
               'SubscribedContent-353698Enabled', 'SubscribedContent-88000326Enabled') { S $cdm $n 0 }
S "$CV\UserProfileEngagement" ScoobeSystemSettingEnabled 0
S "$CV\Notifications\Settings\Windows.SystemToast.Suggested" Enabled 0
S "$P\CloudContent" DisableWindowsConsumerFeatures 1
S "$P\CloudContent" DisableSoftLanding 1
S "$P\CloudContent" DisableCloudOptimizedContent 1
S "$UP\CloudContent" DisableTailoredExperiencesWithDiagnosticData 1
S "$UP\CloudContent" DisableWindowsSpotlightFeatures 1
S "$UP\CloudContent" DisableThirdPartySuggestions 1

# ------------------------------------------------------------
Section '7. 隐私：输入、语音、Copilot / Recall、传递优化'
S 'HKCU:\Software\Microsoft\InputPersonalization' RestrictImplicitInkCollection 1
S 'HKCU:\Software\Microsoft\InputPersonalization' RestrictImplicitTextCollection 1
S 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore' HarvestContacts 0
S 'HKCU:\Software\Microsoft\Personalization\Settings' AcceptedPrivacyPolicy 0
S 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' HasAccepted 0
S 'HKCU:\Software\Microsoft\Input\TIPC' Enabled 0
S 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization' AllowInputPersonalization 0
S "$P\HandwritingErrorReports" PreventHandwritingErrorReports 1
S "$P\TabletPC" PreventHandwritingDataSharing 1
S "$UP\WindowsCopilot" TurnOffWindowsCopilot 1
S "$P\WindowsCopilot" TurnOffWindowsCopilot 1
S "$P\WindowsAI" DisableAIDataAnalysis 1
S "$UP\WindowsAI" DisableAIDataAnalysis 1
S "$P\DeliveryOptimization" DODownloadMode 0

# ------------------------------------------------------------
Section '8. 数据收集计划任务'
foreach ($t in '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
               '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser Exp',
               '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
               '\Microsoft\Windows\Application Experience\StartupAppTask',
               '\Microsoft\Windows\Autochk\Proxy',
               '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
               '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
               '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
               '\Microsoft\Windows\Feedback\Siuf\DmClient',
               '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
               '\Microsoft\Windows\Windows Error Reporting\QueueReporting',
               '\Microsoft\Windows\Maps\MapsUpdateTask',
               '\Microsoft\Windows\Maps\MapsToastTask') {
    $i = $t.LastIndexOf('\')
    $task = Get-ScheduledTask -TaskPath $t.Substring(0, $i + 1) -TaskName $t.Substring($i + 1) -ErrorAction SilentlyContinue
    if ($task) {
        try { Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null; $script:ok++ } catch { $script:fail += "任务 $t : $($_.Exception.Message)" }
    }
}
# 自启动 / 推广 / 遥测类任务（路径支持通配符）
foreach ($pair in @(
        @('\', 'RtHDVBg_PushButton'),                                # Realtek 音频后台程序登录自启
        @('\SoftLanding\*', 'SoftLandingCreativeManagementTask'),     # 系统推广内容
        @('\Microsoft\Office\', 'Office Performance Monitor'),        # Office 遥测
        @('\Microsoft\XblGameSave\', 'XblGameSaveTask'))) {          # Xbox 存档同步
    Get-ScheduledTask -TaskPath $pair[0] -TaskName $pair[1] -ErrorAction SilentlyContinue | ForEach-Object {
        $tk = $_
        try { Disable-ScheduledTask -InputObject $tk -ErrorAction Stop | Out-Null; $script:ok++ } catch { $script:fail += "任务 $($tk.TaskName) : $($_.Exception.Message)" }
    }
}

# ------------------------------------------------------------
Section '9. 清理临时文件'
$tmp = @($env:TEMP, "$env:windir\Temp")
$before = ($tmp | ForEach-Object { Get-ChildItem $_ -Recurse -Force -ErrorAction SilentlyContinue } | Measure-Object Length -Sum).Sum
foreach ($d in $tmp) {
    Get-ChildItem $d -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'claude' } |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}
$after = ($tmp | ForEach-Object { Get-ChildItem $_ -Recurse -Force -ErrorAction SilentlyContinue } | Measure-Object Length -Sum).Sum
Write-Host ("  释放 {0:N0} MB（正在使用的文件已跳过）" -f (($before - $after) / 1MB))

# ------------------------------------------------------------
Write-Host ''
Write-Host "完成：成功 $($script:ok) 项，失败 $($script:fail.Count) 项" -ForegroundColor Green
if ($script:fail.Count) { Write-Host '失败项：' -ForegroundColor Yellow; $script:fail | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow } }
Write-Host "备份在: $bk"
Write-Host '请重启电脑让所有设置完全生效。'

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
#  Windows 优化工具（交互式）：性能 + 后台内存 + 隐私
#  双击运行，自动请求管理员权限。
#  输入序号选择要执行的优化项（可多选，如 1 4 6 或 1,4,6；a = 全部；q = 退出）。
#  可重复运行，已改过的项不会出问题。
#  首次执行优化前，会把相关注册表备份到 桌面\优化前注册表备份
# ============================================================

$bk = Join-Path ([Environment]::GetFolderPath('Desktop')) '优化前注册表备份'
$script:backedUp = $false
$script:ok = 0; $script:fail = @()

# 把控制台字体换成等宽中文字体（新宋体），解决中英文混排错位、行距不均。
# 只对传统控制台窗口(conhost)当场生效；Windows Terminal 会忽略，不影响使用。
try {
    Add-Type -ErrorAction Stop -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ConFont {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CFI {
        public uint cbSize; public uint nFont; public short X; public short Y;
        public uint Family; public uint Weight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Face;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetStdHandle(int h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetCurrentConsoleFontEx(IntPtr h, bool max, ref CFI f);
    public static bool Set(string face, short size) {
        CFI f = new CFI();
        f.cbSize = (uint)Marshal.SizeOf(typeof(CFI));
        f.Y = size; f.Family = 54; f.Weight = 400; f.Face = face;
        return SetCurrentConsoleFontEx(GetStdHandle(-11), false, ref f);
    }
}
"@
    foreach ($face in '新宋体', 'NSimSun', 'MS Gothic') { if ([ConFont]::Set($face, 16)) { break } }   # 字号 16，想更小改这个数字
} catch {}

function Backup {
    if ($script:backedUp) { return }
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
    $script:backedUp = $true
    Write-Host "  已备份注册表到: $bk" -ForegroundColor DarkGray
}

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

$CV = 'HKCU:\Software\Microsoft\Windows\CurrentVersion'
$ADV = "$CV\Explorer\Advanced"
$P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
$UP = 'HKCU:\Software\Policies\Microsoft\Windows'

# ------------------------------------------------------------
function Opt1 {
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
}

# ------------------------------------------------------------
function Opt2 {
    Svc DiagTrack          # 遥测
    Svc MapsBroker         # 离线地图
    Svc Spooler            # 打印（要打印时改回“自动”）
    Svc dmwappushservice   # WAP 推送（遥测相关）
    Svc WerSvc             # 错误报告
    $ap = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    foreach ($n in 'RTHDVCPL', 'RtHDVBg_WAVES_SKYLAKE', 'WavesSvc') {   # 音频托盘程序，可在任务管理器“启动应用”里恢复
        S $ap $n ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) 'Binary'
    }
}

# ------------------------------------------------------------
function Opt3 {
    Get-Process Widgets, WidgetService, WidgetBoard -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $wx = Get-AppxPackage MicrosoftWindows.Client.WebExperience
    if ($wx) {
        try { $wx | Remove-AppxPackage -ErrorAction Stop; $script:ok++ } catch { $script:fail += "卸载小组件: $($_.Exception.Message)" }
    } else { Write-Host '  已卸载，跳过' }
}

# ------------------------------------------------------------
function Opt4 {
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
}

# ------------------------------------------------------------
function Opt5 {
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
}

# ------------------------------------------------------------
function Opt6 {
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
}

# ------------------------------------------------------------
function Opt7 {
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
}

# ------------------------------------------------------------
function Opt8 {
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
}

# ------------------------------------------------------------
function Opt9 {
    $tmp = @($env:TEMP, "$env:windir\Temp")
    $before = ($tmp | ForEach-Object { Get-ChildItem $_ -Recurse -Force -ErrorAction SilentlyContinue } | Measure-Object Length -Sum).Sum
    foreach ($d in $tmp) {
        Get-ChildItem $d -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'claude' } |
            ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $after = ($tmp | ForEach-Object { Get-ChildItem $_ -Recurse -Force -ErrorAction SilentlyContinue } | Measure-Object Length -Sum).Sum
    Write-Host ("  释放 {0:N0} MB（正在使用的文件已跳过）" -f (($before - $after) / 1MB))
}

# ------------------------------------------------------------
function Opt10 {
    $base = (Read-Host '  目标目录（直接回车 = D:\Users）').Trim().Trim('"')
    if (-not $base) { $base = 'D:\Users' }
    $base = $base.TrimEnd('\')
    $drive = Split-Path $base -Qualifier -ErrorAction SilentlyContinue
    if (-not $drive -or -not (Test-Path "$drive\")) { $script:fail += "移动用户文件夹: 盘符不存在 ($base)"; return }
    Write-Host "  桌面/下载/文档/图片/音乐/视频 将移到 $base 下" -ForegroundColor Yellow
    Write-Host '  如果开启了 OneDrive 的"备份桌面/文档/图片"，请先在 OneDrive 设置里关掉。' -ForegroundColor Yellow
    $mv = (Read-Host '  同时移动现有文件？(Y = 移动文件, n = 只改位置)').Trim().ToLower() -ne 'n'
    $usf = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $sf  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
    $items = @(
        @('Desktop',   'Desktop',                                 '{754AC886-DF64-4CBA-86B5-F7FBF4FBCEF5}'),
        @('Downloads', '{374DE290-123F-4565-9164-39C4925E467B}',  '{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}'),
        @('Documents', 'Personal',                                '{F42EE2D3-909F-4907-8871-4C22FC0BF756}'),
        @('Pictures',  'My Pictures',                             '{0DDD015D-B06C-45D5-8C4C-F59713854639}'),
        @('Music',     'My Music',                                '{A0C69A99-21C8-4671-8703-7934162FCF1D}'),
        @('Videos',    'My Video',                                '{35286A68-3C57-41A1-BBB1-0EAE73D76C95}'))
    foreach ($it in $items) {
        $sub, $val, $val2 = $it
        $new = "$base\$sub"
        $old = $null
        try { $old = [Environment]::ExpandEnvironmentVariables((Get-ItemPropertyValue $usf $val -ErrorAction Stop)).TrimEnd('\') } catch {}
        Write-Host "  [$sub] $old -> $new"
        New-Item -ItemType Directory -Force $new -ErrorAction SilentlyContinue | Out-Null
        if (-not (Test-Path $new)) { $script:fail += "移动用户文件夹: 无法创建 $new"; continue }
        if ($old -and ($old -ne $new) -and (Test-Path $old)) {
            if ($mv) {
                robocopy $old $new /E /MOVE /XJ /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
                if ($LASTEXITCODE -ge 8) { Write-Host "    [警告] 部分文件无法移动（可能被占用），请检查 $old" -ForegroundColor Yellow }
            } elseif (Test-Path "$old\desktop.ini") {
                # 只复制 desktop.ini，保留本地化名称和图标
                robocopy $old $new desktop.ini /COPY:DAT /R:0 /NFL /NDL /NJH /NJS /NP | Out-Null
            }
        }
        S $usf $val $new 'ExpandString'
        if ($val2) { S $usf $val2 $new 'ExpandString' }
        S $sf $val $new 'String'
        attrib +r $new 2>$null   # 只读属性让系统识别 desktop.ini（本地化名称和图标）
    }
    Write-Host '  重启资源管理器...'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue   # 系统会自动重新拉起
    Write-Host '  如有程序仍使用旧路径，请注销或重启。'
}

# ------------------------------------------------------------
# 菜单：序号 -> (名称, 说明, 函数)
$menu = [ordered]@{
    '1' = @('性能：后台应用、视觉效果、电源', '关闭后台应用(Claude 除外)、精简动画与透明效果、最佳性能电源模式、关闭快速启动', ${function:Opt1})
    '2' = @('服务与开机启动项',               '禁用遥测/地图/打印/WAP/错误报告服务，关闭 Realtek 音频托盘自启（禁用打印后要打印需改回自动）', ${function:Opt2})
    '3' = @('卸载小组件 (Widgets)',           '结束并卸载 Windows 小组件', ${function:Opt3})
    '4' = @('隐私：搜索',                     '关闭 Bing/云搜索/搜索要点/Cortana/搜索历史', ${function:Opt4})
    '5' = @('隐私：遥测、诊断、活动历史',     '遥测设为最低、关闭错误报告/CEIP/应用兼容性收集/活动历史/反馈提示', ${function:Opt5})
    '6' = @('隐私：广告、推荐与推广内容',     '关闭广告 ID、开始菜单推荐、锁屏/设置里的推广、预装应用推送', ${function:Opt6})
    '7' = @('隐私：输入、语音、Copilot、传递优化', '关闭输入/墨迹收集、在线语音、Copilot、Recall(AI 数据分析)、传递优化', ${function:Opt7})
    '8' = @('禁用数据收集计划任务',           '禁用兼容性评估、CEIP、磁盘诊断、反馈、地图、Office 遥测、Xbox 存档同步等任务', ${function:Opt8})
    '9' = @('清理临时文件',                   '清空用户与系统 Temp 目录（占用中的文件自动跳过）', ${function:Opt9})
    '10' = @('移动用户文件夹到其他盘',        '把桌面/下载/文档/图片/音乐/视频移到 D:\Users（可自定义目录，可选是否移动现有文件）', ${function:Opt10})
}

function Show-Menu {
    Clear-Host
    Write-Host '==============  Windows 优化工具  ==============' -ForegroundColor Cyan
    foreach ($k in $menu.Keys) {
        Write-Host ("  [{0}] {1}" -f $k, $menu[$k][0]) -ForegroundColor White
        Write-Host ("      {0}" -f $menu[$k][1]) -ForegroundColor DarkGray
        Write-Host ''
    }
    Write-Host '  [a] 全部执行 (1-9，不含 10)    [q] 退出' -ForegroundColor Yellow
    Write-Host '  可多选，用空格或逗号分隔，例如: 1 4 6' -ForegroundColor Yellow
}

while ($true) {
    Show-Menu
    $in = (Read-Host "`n请输入序号").Trim().ToLower()
    if ($in -in 'q', '0', 'quit', 'exit') { break }
    if ($in -eq '') { continue }

    if ($in -eq 'a') { $sel = @($menu.Keys | Where-Object { $_ -ne '10' }) }   # 10 会改动文件位置，不包含在“全部”里
    else {
        $sel = @()
        foreach ($tok in ($in -split '[\s,，]+' | Where-Object { $_ })) {
            # 键用字符串：OrderedDictionary 的整数下标会被当成位置序号而不是键
            $n = [string]$tok
            if ($menu.Contains($n)) { if ($sel -notcontains $n) { $sel += $n } }
            else { Write-Host "  忽略无效输入: $tok" -ForegroundColor Red }
        }
    }
    $sel = @($sel | Sort-Object { [int]$_ })
    if (-not $sel.Count) { Read-Host '没有有效选项，按回车返回菜单' | Out-Null; continue }

    Write-Host ''
    Write-Host ('将执行: ' + (($sel | ForEach-Object { "[$_] " + $menu[$_][0] }) -join ' / ')) -ForegroundColor Cyan
    if ((Read-Host '确认执行？(Y/n)').Trim().ToLower() -eq 'n') { continue }

    Backup
    $script:ok = 0; $script:fail = @()
    foreach ($n in $sel) {
        Write-Host "`n== $n. $($menu[$n][0]) ==" -ForegroundColor Cyan
        & $menu[$n][2]
    }

    Write-Host ''
    Write-Host "完成：成功 $($script:ok) 项，失败 $($script:fail.Count) 项" -ForegroundColor Green
    if ($script:fail.Count) { Write-Host '失败项：' -ForegroundColor Yellow; $script:fail | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow } }
    Write-Host "备份在: $bk"
    Write-Host '部分设置需要重启电脑才能完全生效。'
    Read-Host "`n按回车返回菜单" | Out-Null
}

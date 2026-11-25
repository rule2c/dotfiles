<# :
@echo off
set "F=%~f0"
rem fltmc succeeds only when elevated and, unlike net session, does not depend on the Server service
fltmc >nul 2>&1
if errorlevel 1 (
  if /i "%~1"=="--elevated" (
    echo Failed to get administrator rights.
    pause
    exit /b 1
  )
  powershell.exe -NoProfile -Command "Start-Process -FilePath $env:F -ArgumentList '--elevated' -Verb RunAs" || pause
  exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:F,[Text.Encoding]::UTF8))"
pause
exit /b
#>

# ============================================================
#  Windows 优化工具（交互式）：性能 + 后台内存 + 隐私
#  双击运行，自动请求管理员权限。
#  输入序号选择要执行的优化项（可多选，如 1 4 6 或 1,4,6；a = 1-9；c = 状态检查；r = 恢复；q = 退出）。
#  可重复运行。每项改动前的原值记录在 %LOCALAPPDATA%\WindowsOptimize\undo.json，
#  菜单 r 可按记录逐项恢复；首次执行时另建一个系统还原点（需开启系统保护）。
#  注意：代码里的字符串不要用中文弯引号，PowerShell 会把它们当成引号。
# ============================================================

# ===================== 本机配置（换电脑时只改这里） =====================
$BgAllowApps     = @('Claude_pzs8sxrjxfjjc')                           # 允许后台运行的商店/MSIX 应用，填包系列名（序号 1）
$AudioStartup    = @('RTHDVCPL', 'RtHDVBg_WAVES_SKYLAKE', 'WavesSvc')  # 要关闭的音频托盘开机启动项名称（序号 2）
$AudioTasks      = @('RtHDVBg_PushButton')                             # 要禁用的音频自启计划任务，位于任务计划程序根目录（序号 8）
$TempKeep        = @('claude')                                         # 清理 Temp 时保留的顶层文件夹（序号 9）
$TempAgeDays     = 1                                                   # 只清理多少天以前的临时文件（序号 9）
$UsersDirDefault = 'D:\Users'                                          # 移动用户文件夹的默认目标（序号 10）
# ======================================================================

$bk = Join-Path $env:LOCALAPPDATA 'WindowsOptimize'
$undoFile = Join-Path $bk 'undo.json'
$script:ok = 0; $script:fail = @()
$script:undo = New-Object System.Collections.ArrayList
$script:seen = @{}
$script:check = $false   # 状态检查模式：S/Svc/DisTask/Remove-App 只比对不修改
$script:match = 0; $script:diffN = 0

# 控制台字体：优先用更纱黑体 Term（思源黑体 + Iosevka 的等宽合成，观感接近苹方，开源可商用），
# 没装就退回新宋体。conhost 没有行距设置，行高 = 字号格高，靠字体自身的上下留白拉开行距：
# 更纱的留白比新宋体大，所以格高给到 22，字面大小和原来 16 号新宋体相近，行距明显更松。
# 只对传统控制台窗口(conhost)当场生效；Windows Terminal 会忽略，不影响使用。
try {
    Add-Type -ErrorAction Stop -TypeDefinition @'
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
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetCurrentConsoleFontEx(IntPtr h, bool max, ref CFI f);
    public static string Set(string face, short size) {
        CFI f = new CFI();
        f.cbSize = (uint)Marshal.SizeOf(typeof(CFI));
        f.Y = size; f.Family = 54; f.Weight = 400; f.Face = face;
        IntPtr h = GetStdHandle(-11);
        if (!SetCurrentConsoleFontEx(h, false, ref f)) return null;
        CFI g = new CFI();
        g.cbSize = f.cbSize;
        return GetCurrentConsoleFontEx(h, false, ref g) ? g.Face : null;
    }
}
'@
    # 字体未安装时 SetCurrentConsoleFontEx 也会返回成功并悄悄换成别的字体，所以要读回实际字体名核对
    foreach ($f in @(
            @('Sarasa Term SC', 22, '*Sarasa*|*更纱*'),     # 格高 22；嫌大改 20，嫌挤改 24
            @('Sarasa Mono SC', 22, '*Sarasa*|*更纱*'),
            @('新宋体', 16, '*新宋体*|*NSimSun*'),
            @('NSimSun', 16, '*新宋体*|*NSimSun*'),
            @('MS Gothic', 16, '*Gothic*'))) {
        $got = [ConFont]::Set($f[0], $f[1])
        if ($got -and @($f[2] -split '\|' | Where-Object { $got -like $_ }).Count) { break }
    }
} catch {}

# ------------------------------------------------------------
# 提权后必须仍是桌面登录的那个账户：标准用户在 UAC 里输入另一个管理员账户时，
# HKCU 设置、临时文件、用户文件夹都会作用到那个管理员账户上
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    $sess = (Get-Process -Id $PID).SessionId
    $exp = Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$sess" -ErrorAction Stop | Select-Object -First 1
    if ($exp) {
        $owner = (Invoke-CimMethod -InputObject $exp -MethodName GetOwnerSid -ErrorAction Stop).Sid
        if ($owner -and $owner -ne $me.User.Value) {
            Write-Host ('当前以 ' + $me.Name + ' 身份运行，但桌面登录的是另一个账户，用户级设置会写错账户。') -ForegroundColor Red
            Write-Host '请直接用管理员账户登录 Windows 后再运行本脚本。' -ForegroundColor Red
            exit 1
        }
    }
} catch {}

# 系统版本：部分策略只在企业版/教育版生效
$nt = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build = [int]$nt.CurrentBuild
$edition = [string]$nt.EditionID
$isEnt = $edition -match '^(Enterprise|Education|IoT|Server)'
$edName = @{ Core = '家庭版'; CoreCountrySpecific = '家庭中文版'; CoreSingleLanguage = '家庭单语言版'; Professional = '专业版';
             ProfessionalWorkstation = '专业工作站版'; Enterprise = '企业版'; EnterpriseS = '企业版 LTSC'; Education = '教育版' }[$edition]
if (-not $edName) { $edName = $edition }
$osInfo = ('{0} {1} {2} (Build {3}.{4})' -f $(if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }), $edName, $nt.DisplayVersion, $build, $nt.UBR)

# ------------------------------------------------------------
# 恢复记录：每个注册表值/服务/计划任务第一次被修改前记下原状态（以后再运行不覆盖），菜单 r 逆序还原
function Load-Undo {
    if (-not (Test-Path -LiteralPath $undoFile)) { return }
    try {
        $j = [IO.File]::ReadAllText($undoFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($e in @($j)) { if ($e -and $e.id) { [void]$script:undo.Add($e); $script:seen[$e.id] = $true } }
    } catch { Write-Host "  [警告] 恢复记录读取失败: $undoFile" -ForegroundColor Yellow; Start-Sleep 2 }
}
function Save-Undo {
    New-Item -ItemType Directory -Force $bk | Out-Null
    if (-not $script:undo.Count) { Remove-Item -LiteralPath $undoFile -Force -ErrorAction SilentlyContinue; return }
    $json = ConvertTo-Json -InputObject @($script:undo.ToArray()) -Depth 5
    [IO.File]::WriteAllText($undoFile, $json, (New-Object Text.UTF8Encoding $false))
}
function Add-Undo($id, $e) {
    if ($script:seen.ContainsKey($id)) { return }
    $e | Add-Member -NotePropertyName id -NotePropertyValue $id
    [void]$script:undo.Add($e); $script:seen[$id] = $true
}
function Rec-Key($path) {
    # 记录将被新建的最上层键；恢复时若整棵键里已没有任何值就删除
    $top = $path
    while ($true) {
        $parent = Split-Path $top -Parent
        if (-not $parent -or (Test-Path -LiteralPath $parent)) { break }
        $top = $parent
    }
    Add-Undo "key|$top" ([pscustomobject]@{ t = 'key'; path = $top })
}
function Rec-Reg($path, $name) {
    $id = "reg|$path|$name"
    if ($script:seen.ContainsKey($id)) { return }
    $e = [pscustomobject]@{ t = 'reg'; path = $path; name = $name; exists = $false; kind = $null; value = $null }
    $k = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($k -and ($k.GetValueNames() -contains $name)) {
        $e.exists = $true
        $e.kind = [string]$k.GetValueKind($name)
        $v = $k.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
        if ($v -is [byte[]]) { $v = [int[]]$v }
        $e.value = $v
    }
    Add-Undo $id $e
}
function Rec-Svc($name) {
    $p = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -ErrorAction SilentlyContinue
    if ($p) { Add-Undo "svc|$name" ([pscustomobject]@{ t = 'svc'; name = $name; start = $p.Start; delayed = $p.DelayedAutostart }) }
}

# ------------------------------------------------------------
function Fmt($v) {
    if ($null -eq $v) { return '(不存在)' }
    if ($v -is [array]) { return '[' + (@($v | ForEach-Object { [string]$_ }) -join ',') + ']' }
    [string]$v
}
function Chk($label, $cur, $want) {
    $c = Fmt $cur; $w = Fmt $want
    if ($c -eq $w) { $script:match++ }
    else { $script:diffN++; Write-Host "  [未生效] $label : 当前 $c，目标 $w" -ForegroundColor Yellow }
}
function S($path, $name, $val, $type = 'DWord') {
    if ($script:check) {
        $k = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        $cur = $null
        if ($k -and ($k.GetValueNames() -contains $name)) { $cur = $k.GetValue($name, $null, 'DoNotExpandEnvironmentNames') }
        Chk "$path\$name" $cur $val
        return
    }
    try {
        $isNew = -not (Test-Path -LiteralPath $path)
        if ($isNew) { Rec-Key $path }
        Rec-Reg $path $name
        if ($isNew) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $path -Name $name -Value $val -Type $type -ErrorAction Stop
        $script:ok++
    } catch { $script:fail += "$path\$name : $($_.Exception.Message)" }
}
function Svc($name) {
    if (-not (Get-Service $name -ErrorAction SilentlyContinue)) { Write-Host "  服务 $name 不存在，跳过" -ForegroundColor DarkGray; return }
    if ($script:check) { Chk "服务 $name" ([string](Get-Service $name).StartType) 'Disabled'; return }
    Rec-Svc $name
    try {
        Set-Service $name -StartupType Disabled -ErrorAction Stop   # 先禁用再停止，避免被触发器重新拉起
        Stop-Service $name -Force -ErrorAction SilentlyContinue
        $script:ok++
    } catch { $script:fail += "服务 $name : $($_.Exception.Message)" }
}
function DisTask($path, $name) {
    # $path 为空时按任务名在所有目录下查找
    $q = @{ TaskName = $name; ErrorAction = 'SilentlyContinue' }
    if ($path) { $q.TaskPath = $path }
    $tasks = @(Get-ScheduledTask @q)
    if (-not $tasks.Count) { Write-Host "  任务 $path$name 不存在，跳过" -ForegroundColor DarkGray; return }
    foreach ($tk in $tasks) {
        if ($script:check) { Chk "任务 $($tk.TaskPath)$($tk.TaskName)" ([string]$tk.State) 'Disabled'; continue }
        Add-Undo "task|$($tk.TaskPath)$($tk.TaskName)" ([pscustomobject]@{ t = 'task'; path = $tk.TaskPath; name = $tk.TaskName; enabled = ($tk.State -ne 'Disabled') })
        try { Disable-ScheduledTask -InputObject $tk -ErrorAction Stop | Out-Null; $script:ok++ }
        catch { $script:fail += "任务 $($tk.TaskPath)$($tk.TaskName) : $($_.Exception.Message)" }
    }
}
function Remove-App($pkg, $label) {
    $ap = @(Get-AppxPackage $pkg)
    if ($script:check) { Chk $label $(if ($ap.Count) { '已安装' } else { '未安装' }) '未安装'; return }
    if (-not $ap.Count) { Write-Host "  $label 未安装，跳过" -ForegroundColor DarkGray; return }
    Add-Undo "appx|$pkg" ([pscustomobject]@{ t = 'appx'; name = $label })
    try { $ap | Remove-AppxPackage -ErrorAction Stop; $script:ok++ } catch { $script:fail += "卸载 $label : $($_.Exception.Message)" }
}

$CV = 'HKCU:\Software\Microsoft\Windows\CurrentVersion'
$ADV = "$CV\Explorer\Advanced"
$P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
$UP = 'HKCU:\Software\Policies\Microsoft\Windows'

# ------------------------------------------------------------
function Get-Overlay {
    # 当前电源模式 GUID；读不到返回 $null
    $g = [regex]::Match((powercfg /overlaygetactive 2>$null | Out-String), '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
    if (-not $g) { $g = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -ErrorAction SilentlyContinue).ActiveOverlayAcPowerScheme }
    if ($g) { [string]$g } else { $null }
}
function Opt1 {
    # 后台应用：用户级总开关已从新版 Windows 11 设置中移除，可能不再生效，因此再用策略强制禁止 + 白名单放行。
    # 这两项只管商店/MSIX 应用，微信、QQ 等普通桌面程序不受影响。
    $bgAllow = @($BgAllowApps)             # 在开头「本机配置」里添加
    $bgSystem = @('Microsoft.Windows.ShellExperienceHost_cw5n1h2txyewy', 'Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy',
                  'Microsoft.Windows.Search_cw5n1h2txyewy', 'MicrosoftWindows.Client.CBS_cw5n1h2txyewy',
                  'MicrosoftWindows.Client.Core_cw5n1h2txyewy', 'Microsoft.SecHealthUI_8wekyb3d8bbwe')   # 开始菜单/搜索/通知/安全中心
    S "$CV\BackgroundAccessApplications" GlobalUserDisabled 1
    S "$CV\Search" BackgroundAppGlobalToggle 0
    foreach ($pfn in $bgAllow) {
        S "$CV\BackgroundAccessApplications\$pfn" Disabled 0
        S "$CV\BackgroundAccessApplications\$pfn" DisabledByUser 0
    }
    S "$P\AppPrivacy" LetAppsRunInBackground 2   # 2 = 强制禁止（白名单除外）
    S "$P\AppPrivacy" LetAppsRunInBackground_ForceAllowTheseApps ([string[]]($bgAllow + $bgSystem)) 'MultiString'

    # Edge：关闭窗口后不在后台常驻、开机不预加载（edge://settings 会显示「由你的组织管理」）
    S 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' BackgroundModeEnabled 0
    S 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' StartupBoostEnabled 0

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

    # 电源模式「最佳性能」：只在「平衡」电源计划下可用；笔记本用电池时跳过，免得把电池续航也牺牲掉
    if ($script:check) {
        $g = Get-Overlay
        if ($g) { Chk '电源模式' $g 'ded574b5-45a0-4f42-8737-46345c09c238' } else { Write-Host '  电源模式: 无法读取当前值' -ForegroundColor DarkGray }
        return
    }
    $onBattery = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Where-Object { $_.BatteryStatus -in 1, 4, 5, 10, 11 }).Count -gt 0
    if ($onBattery) {
        Write-Host '  正在使用电池，跳过电源模式（插上电源后再执行本项）' -ForegroundColor Yellow
    } else {
        if (-not $script:seen.ContainsKey('power')) {
            $g = Get-Overlay
            if (-not $g) { $g = '00000000-0000-0000-0000-000000000000' }   # 默认的「平衡」模式
            Add-Undo 'power' ([pscustomobject]@{ t = 'power'; value = [string]$g })
        }
        powercfg /overlaysetactive ded574b5-45a0-4f42-8737-46345c09c238 2>$null   # 最佳性能
        if ($LASTEXITCODE -eq 0) { $script:ok++ }
        else { $script:fail += '电源模式: 设置失败（只在「平衡」电源计划下可用，可在 控制面板\电源选项 里切回平衡）' }
    }
}

# ------------------------------------------------------------
function Opt2 {
    Svc DiagTrack          # 遥测
    Svc MapsBroker         # 离线地图
    Svc dmwappushservice   # WAP 推送（遥测相关；公司电脑如需 Intune/MDM 注册请跳过本项）
    # WerSvc 默认就是按需触发，禁用几乎不省资源；错误报告已在序号 5 用策略关闭
    if ($script:check) { Write-Host ('  打印服务（可选项，不计入）: ' + (Get-Service Spooler -ErrorAction SilentlyContinue).StartType) -ForegroundColor DarkGray }
    elseif ((Read-Host '  同时禁用打印服务？禁用后无法打印，也不能「打印到 PDF」(y/N)').Trim().ToLower() -eq 'y') { Svc Spooler }

    # 音频托盘程序自启：只处理确实存在的启动项，按它所在位置写对应的 StartupApproved 键
    # （可在任务管理器「启动应用」里恢复。Waves 在部分戴尔机型上负责音效/麦克风降噪，关闭后如有异常请恢复）
    $runs = @(
        @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',             'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'),
        @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'),
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',             'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'))
    foreach ($n in $AudioStartup) {
        foreach ($r in $runs) {
            $rk = Get-Item -LiteralPath $r[0] -ErrorAction SilentlyContinue
            if (-not ($rk -and ($rk.GetValueNames() -contains $n))) { continue }
            if ($script:check) {
                # 首字节为奇数即已禁用（任务管理器禁用时后面会带时间戳，不能整串比较）
                $ak = Get-Item -LiteralPath $r[1] -ErrorAction SilentlyContinue
                $b = $null; if ($ak -and ($ak.GetValueNames() -contains $n)) { $b = $ak.GetValue($n) }
                Chk "开机启动项 $n" $(if ($b -and ($b[0] % 2)) { '已禁用' } else { '已启用' }) '已禁用'
            } else { S $r[1] $n ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) 'Binary' }
        }
    }

    # 关闭快速启动：每次开机完整初始化内核和驱动，双系统下 NTFS 分区也不会被锁；代价是开机稍慢
    S 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' HiberbootEnabled 0

    # 台式机关闭休眠：删除 hiberfil.sys（约为内存的 40%）。快速启动已关，休眠文件只剩手动休眠一个用途；笔记本保留
    if ((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).PCSystemType -eq 2) {
        Write-Host '  笔记本，保留休眠功能' -ForegroundColor DarkGray; return
    }
    $hib = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue).HibernateEnabled
    if ($script:check) { Chk '休眠' $(if ($hib -eq 0) { '已关闭' } else { '已开启' }) '已关闭'; return }
    $hf = Get-Item -LiteralPath "$env:SystemDrive\hiberfil.sys" -Force -ErrorAction SilentlyContinue
    Add-Undo 'hib' ([pscustomobject]@{ t = 'hib'; value = [int]([bool]$hf -or $hib -eq 1) })
    powercfg /hibernate off 2>$null
    if ($LASTEXITCODE -eq 0) {
        $script:ok++
        if ($hf) { Write-Host ('  已关闭休眠，释放 {0:N1} GB' -f ($hf.Length / 1GB)) }
    } else { $script:fail += '关闭休眠: powercfg /hibernate off 失败' }
}

# ------------------------------------------------------------
function Opt3 {
    if (-not $script:check) { Get-Process Widgets, WidgetService, WidgetBoard -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    S 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' AllowNewsAndInterests 0   # 策略禁用小组件，防止商店更新后又装回来
    Remove-App MicrosoftWindows.Client.WebExperience 'Windows Web Experience Pack（小组件）'
}

# ------------------------------------------------------------
function Opt4 {
    S "$CV\SearchSettings" IsDynamicSearchBoxEnabled 0      # 搜索要点
    S "$CV\SearchSettings" IsAADCloudSearchEnabled 0
    S "$CV\SearchSettings" IsMSACloudSearchEnabled 0
    S "$CV\SearchSettings" IsDeviceSearchHistoryEnabled 0
    S "$CV\Search" BingSearchEnabled 0
    S "$P\Windows Search" DisableWebSearch 1
    S "$P\Windows Search" ConnectedSearchUseWeb 0
    S "$P\Windows Search" EnableDynamicContentInWSB 0
    S "$P\Windows Search" AllowCloudSearch 0
    S "$UP\Explorer" DisableSearchBoxSuggestions 1
}

# ------------------------------------------------------------
function Opt5 {
    if (-not $isEnt) { Write-Host ('  提示：' + $edName + '的遥测最低只能到「必需」级别，AllowTelemetry=0 会按 1 执行') -ForegroundColor DarkGray }
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
    if (-not $isEnt) { Write-Host '  提示：CloudContent / 聚焦类策略只在企业版、教育版生效，本机以用户设置（ContentDeliveryManager）为准' -ForegroundColor DarkGray }
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
    # TurnOffWindowsCopilot 只对旧版侧边栏 Copilot 有效；现在的 Copilot 是商店应用，需要卸载
    S "$UP\WindowsCopilot" TurnOffWindowsCopilot 1
    S "$P\WindowsCopilot" TurnOffWindowsCopilot 1
    Remove-App Microsoft.Copilot 'Copilot'
    S "$P\WindowsAI" DisableAIDataAnalysis 1      # Recall
    S "$UP\WindowsAI" DisableAIDataAnalysis 1
    S "$P\DeliveryOptimization" DODownloadMode 0  # 传递优化：只用 HTTP，不与其他电脑互传
}

# ------------------------------------------------------------
function Opt8 {
    $ae = '\Microsoft\Windows\Application Experience\'
    # 注意：兼容性评估任务关闭后，大版本功能更新前的兼容性检查会受影响
    DisTask $ae 'Microsoft Compatibility Appraiser'
    DisTask $ae 'Microsoft Compatibility Appraiser Exp'
    DisTask $ae 'ProgramDataUpdater'
    DisTask $ae 'StartupAppTask'
    DisTask '\Microsoft\Windows\Autochk\' 'Proxy'
    DisTask '\Microsoft\Windows\Customer Experience Improvement Program\' 'Consolidator'
    DisTask '\Microsoft\Windows\Customer Experience Improvement Program\' 'UsbCeip'
    DisTask '\Microsoft\Windows\DiskDiagnostic\' 'Microsoft-Windows-DiskDiagnosticDataCollector'
    DisTask '\Microsoft\Windows\Feedback\Siuf\' 'DmClient'
    DisTask '\Microsoft\Windows\Feedback\Siuf\' 'DmClientOnScenarioDownload'
    DisTask '\Microsoft\Windows\Windows Error Reporting\' 'QueueReporting'
    DisTask '\Microsoft\Windows\Maps\' 'MapsUpdateTask'
    DisTask '\Microsoft\Windows\Maps\' 'MapsToastTask'
    foreach ($t in $AudioTasks) { DisTask '\' $t }                     # 音频后台程序登录自启（本机配置）
    DisTask $null 'SoftLandingCreativeManagementTask'                  # 系统推广内容（位于 SoftLanding\<用户SID>\ 下）
    DisTask '\Microsoft\Office\' 'Office Performance Monitor'          # Office 遥测
    DisTask '\Microsoft\Office\' 'OfficeTelemetryAgentLogOn2016'
    DisTask '\Microsoft\Office\' 'OfficeTelemetryAgentFallBack2016'
    DisTask '\Microsoft\XblGameSave\' 'XblGameSaveTask'               # Xbox 存档同步
}

# ------------------------------------------------------------
function Clear-Dir($dir, $cutoff, $top = $false) {
    foreach ($it in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
        if ($top -and ($TempKeep -contains $it.Name)) { continue }
        $t = $it.LastWriteTime; if ($it.CreationTime -gt $t) { $t = $it.CreationTime }
        try {
            if ($it.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                # 目录联接/符号链接：只删链接本身，不进入目标（PS 5.1 的 Remove-Item -Recurse 会删到链接目标里去）
                if ($t -lt $cutoff -and -not $script:check) { $it.Delete() }
            } elseif ($it.PSIsContainer) {
                Clear-Dir $it.FullName $cutoff
                if ($t -lt $cutoff -and -not $script:check) { $it.Delete() }   # 非递归删除，目录里还有文件时会失败并跳过
            } elseif ($t -lt $cutoff) {
                $len = $it.Length
                if (-not $script:check) {
                    if ($it.IsReadOnly) { $it.IsReadOnly = $false }
                    $it.Delete()
                }
                $script:freed += $len
            }
        } catch {}   # 占用中的文件跳过
    }
}
function Opt9 {
    # 只删 N 天以前的内容（本机配置 $TempAgeDays），避免误删正在进行的安装或待重启更新的临时文件
    $script:freed = 0
    $cutoff = (Get-Date).AddDays(-$TempAgeDays)
    foreach ($d in (@($env:TEMP, "$env:windir\Temp") | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $d) { Clear-Dir $d $cutoff $true }
    }
    if ($script:check) { Write-Host ('  可清理约 {0:N0} MB（清理类，不计入）' -f ($script:freed / 1MB)) -ForegroundColor DarkGray; return }
    Write-Host ('  释放 {0:N0} MB（{1} 天内的文件和占用中的文件已跳过）' -f ($script:freed / 1MB), $TempAgeDays)
    $script:ok++

    # 系统组件存储（WinSxS）：清掉被新版本替换的旧组件。不加 /ResetBase，已安装的更新仍可卸载
    if ((Read-Host '  同时清理系统组件存储 (WinSxS)？需要几分钟 (y/N)').Trim().ToLower() -ne 'y') { return }
    $free0 = (New-Object IO.DriveInfo -ArgumentList $env:SystemDrive).AvailableFreeSpace
    Dism.exe /Online /Cleanup-Image /StartComponentCleanup
    if ($LASTEXITCODE -eq 0) {
        $script:ok++
        $gain = (New-Object IO.DriveInfo -ArgumentList $env:SystemDrive).AvailableFreeSpace - $free0
        Write-Host ('  组件清理完成，系统盘可用空间增加 {0:N0} MB' -f ([math]::Max(0, $gain) / 1MB))
    } else { $script:fail += "组件清理: DISM 返回 $LASTEXITCODE" }
}

# ------------------------------------------------------------
function Opt10 {
    if (-not ('KnownFolder' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KnownFolder {
    [DllImport("shell32.dll")] static extern int SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid id, uint flags, IntPtr token, out IntPtr path);
    [DllImport("shell32.dll")] static extern int SHSetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid id, uint flags, IntPtr token, [MarshalAs(UnmanagedType.LPWStr)] string path);
    public static string Get(Guid id) {
        IntPtr p;
        int hr = SHGetKnownFolderPath(id, 0x4000, IntPtr.Zero, out p);   // KF_FLAG_DONT_VERIFY
        try { return hr == 0 ? Marshal.PtrToStringUni(p) : null; }
        finally { if (p != IntPtr.Zero) Marshal.FreeCoTaskMem(p); }
    }
    public static int Set(Guid id, string path) { return SHSetKnownFolderPath(id, 0, IntPtr.Zero, path); }
}
'@
    }
    $base = (Read-Host ('  目标目录（直接回车 = ' + $UsersDirDefault + '）')).Trim().Trim('"')
    if (-not $base) { $base = $UsersDirDefault }
    $base = $base.TrimEnd('\')
    if ($base -notmatch '^[A-Za-z]:(\\|$)') { $script:fail += "移动用户文件夹: 请输入带盘符的完整路径 ($base)"; return }
    $drv = New-Object IO.DriveInfo -ArgumentList ($base.Substring(0, 1))
    if (-not $drv.IsReady) { $script:fail += "移动用户文件夹: 盘符不存在 ($base)"; return }
    if ([string]$drv.DriveType -ne 'Fixed' -or $drv.DriveFormat -notin 'NTFS', 'ReFS') {
        $script:fail += ('移动用户文件夹: 目标必须是本机 NTFS/ReFS 固定磁盘（当前 {0} / {1}）' -f $drv.DriveType, $drv.DriveFormat); return
    }
    Write-Host "  桌面/下载/文档/图片/音乐/视频 将移到 $base 下" -ForegroundColor Yellow
    $mv = (Read-Host '  同时移动现有文件？(Y = 移动文件, n = 只改位置)').Trim().ToLower() -ne 'n'
    $sid = $me.User.Value
    $usf = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $ic = [StringComparison]::OrdinalIgnoreCase
    # 子目录名, KNOWNFOLDERID, User Shell Folders 里对应的 Local* 值名
    $items = @(
        @('Desktop',   'B4BFCC3A-DB2C-424C-B029-7FE99A87C641', '{754AC886-DF64-4CBA-86B5-F7FBF4FBCEF5}'),
        @('Downloads', '374DE290-123F-4565-9164-39C4925E467B', '{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}'),
        @('Documents', 'FDD39AD0-238F-46AF-ADB4-6C85480369C7', '{F42EE2D3-909F-4907-8871-4C22FC0BF756}'),
        @('Pictures',  '33E28130-4E1E-4676-835A-98395C3BC3BB', '{0DDD015D-B06C-45D5-8C4C-F59713854639}'),
        @('Music',     '4BD8D571-6D19-48D3-BE97-422220080E43', '{A0C69A99-21C8-4671-8703-7934162FCF1D}'),
        @('Videos',    '18989B1D-99B5-455B-841C-AB7C74E4DDFC', '{35286A68-3C57-41A1-BBB1-0EAE73D76C95}'))
    $changed = 0
    foreach ($it in $items) {
        $sub, $kf, $alt = $it
        $new = "$base\$sub"
        $old = [KnownFolder]::Get([guid]$kf)
        if ($old) { $old = $old.TrimEnd('\') }
        Write-Host "  [$sub] $old -> $new"
        if ($old -and $old -eq $new) { Write-Host '    已在目标位置，跳过' -ForegroundColor DarkGray; continue }
        if ($old -and ($new.StartsWith("$old\", $ic) -or $old.StartsWith("$new\", $ic))) {
            $script:fail += "移动用户文件夹: [$sub] 新旧路径互相包含，已跳过"; continue
        }
        if ($old -and $env:OneDrive -and $old.StartsWith("$env:OneDrive\", $ic)) {
            $script:fail += "移动用户文件夹: [$sub] 正由 OneDrive 备份，请先在 OneDrive 设置里停止备份该文件夹"; continue
        }
        New-Item -ItemType Directory -Force $new -ErrorAction SilentlyContinue | Out-Null
        if (-not (Test-Path -LiteralPath $new)) { $script:fail += "移动用户文件夹: 无法创建 $new"; continue }
        # 权限只给本人、SYSTEM、管理员组（D 盘根目录默认允许所有登录用户读写）；先设权限再移动，移入的文件自动继承
        icacls $new /inheritance:r /grant:r "*${sid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { $script:fail += "移动用户文件夹: 设置 $new 的权限失败，已跳过"; continue }
        if ($old -and (Test-Path -LiteralPath $old)) {
            if ($mv) {
                robocopy $old $new /E /MOVE /XJ /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
                if ($LASTEXITCODE -ge 8) {
                    $script:fail += "移动用户文件夹: [$sub] 部分文件无法移动（可能被占用），位置未更改。已移动的在 $new，其余仍在 $old；关闭相关程序后重新执行即可"
                    continue
                }
            } elseif (Test-Path -LiteralPath "$old\desktop.ini") {
                robocopy $old $new desktop.ini /COPY:DAT /R:0 /NFL /NDL /NJH /NJS /NP | Out-Null   # 保留本地化名称和图标
            }
        }
        $hr = [KnownFolder]::Set([guid]$kf, $new)
        if ($hr -ne 0) { $script:fail += ('移动用户文件夹: [{0}] 设置位置失败 (0x{1:X8})' -f $sub, $hr); continue }
        $uk = Get-Item -LiteralPath $usf
        if ($uk.GetValueNames() -contains $alt) { Set-ItemProperty -Path $usf -Name $alt -Value $new -Type ExpandString }
        attrib +r $new 2>$null   # 只读属性让系统识别 desktop.ini（本地化名称和图标）
        $script:ok++; $changed++
    }
    if ($changed) {
        Write-Host '  重启资源管理器...'
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue   # 系统会自动重新拉起
        Write-Host '  如有程序仍使用旧路径，请注销或重启。'
    }
}

# ------------------------------------------------------------
function Restore-All {
    $list = $script:undo.ToArray(); [array]::Reverse($list)
    $failed = New-Object System.Collections.ArrayList
    $apps = @()
    foreach ($e in $list) {
        try {
            switch ($e.t) {
                'reg' {
                    if ($e.exists) {
                        $v = $e.value
                        switch ($e.kind) {
                            'Binary'      { $v = [byte[]]@($v) }
                            'MultiString' { $v = [string[]]@($v) }
                            'DWord'       { $v = [int]$v }
                            'QWord'       { $v = [long]$v }
                        }
                        if (-not (Test-Path -LiteralPath $e.path)) { New-Item -Path $e.path -Force -ErrorAction Stop | Out-Null }
                        Set-ItemProperty -Path $e.path -Name $e.name -Value $v -Type $e.kind -ErrorAction Stop
                    } else {
                        $k = Get-Item -LiteralPath $e.path -ErrorAction SilentlyContinue
                        if ($k -and ($k.GetValueNames() -contains $e.name)) { Remove-ItemProperty -Path $e.path -Name $e.name -ErrorAction Stop }
                    }
                }
                'key' {
                    if (Test-Path -LiteralPath $e.path) {
                        $keys = @(Get-Item -LiteralPath $e.path) + @(Get-ChildItem -LiteralPath $e.path -Recurse -ErrorAction SilentlyContinue)
                        if (-not ($keys | Where-Object { $_.ValueCount -gt 0 })) { Remove-Item -LiteralPath $e.path -Recurse -Force -ErrorAction Stop }
                    }
                }
                'svc' {
                    $mode = switch ([int]$e.start) { 2 { if ([int]$e.delayed -eq 1) { 'delayed-auto' } else { 'auto' } } 3 { 'demand' } 4 { 'disabled' } }
                    if ($mode) {
                        sc.exe config $e.name start= $mode | Out-Null
                        if ($LASTEXITCODE -ne 0) { throw "sc config 返回 $LASTEXITCODE" }
                        if ([int]$e.start -eq 2) { Start-Service $e.name -ErrorAction SilentlyContinue }
                    }
                }
                'task'  { if ($e.enabled) { Enable-ScheduledTask -TaskPath $e.path -TaskName $e.name -ErrorAction Stop | Out-Null } }
                'hib'   { if ([int]$e.value -eq 1) { powercfg /hibernate on 2>$null; if ($LASTEXITCODE -ne 0) { throw 'powercfg /hibernate on 失败' } } }
                'power' { powercfg /overlaysetactive $e.value 2>$null; if ($LASTEXITCODE -ne 0) { throw 'powercfg 失败' } }
                'appx'  { $apps += $e.name }
            }
            $script:ok++
        } catch {
            $script:fail += "恢复 $($e.id) : $($_.Exception.Message)"
            [void]$failed.Add($e)
        }
    }
    # 原记录归档；恢复失败的项留在记录里，下次可再试
    Copy-Item -LiteralPath $undoFile -Destination (Join-Path $bk ('undo-restored-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -ErrorAction SilentlyContinue
    $script:undo.Clear(); $script:seen.Clear()
    $arr = $failed.ToArray(); [array]::Reverse($arr)
    foreach ($e in $arr) { [void]$script:undo.Add($e); $script:seen[$e.id] = $true }
    Save-Undo
    if ($apps) { Write-Host ('  以下应用需在 Microsoft Store 搜索后手动重装: ' + ($apps -join '、')) -ForegroundColor Yellow }
    Write-Host '  用户文件夹位置（序号 10）不在恢复范围内。' -ForegroundColor DarkGray
}

# ------------------------------------------------------------
function Prepare {
    New-Item -ItemType Directory -Force $bk | Out-Null
    # 从未优化过（或已全部恢复）时，先建系统还原点兜底
    if ($script:undo.Count -or $script:rpDone) { return }
    $script:rpDone = $true
    Write-Host '  正在创建系统还原点（约需 1 分钟）...' -ForegroundColor DarkGray
    $rk = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $freq = (Get-ItemProperty $rk -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
    Set-ItemProperty $rk SystemRestorePointCreationFrequency 0 -Type DWord -ErrorAction SilentlyContinue   # 解除「24 小时只能建一个」的限制
    try {
        Checkpoint-Computer -Description 'Windows 优化前' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Host '  已创建系统还原点' -ForegroundColor DarkGray
    } catch { Write-Host '  [提示] 未能创建还原点（系统保护可能未开启），继续执行；仍可用菜单 r 恢复' -ForegroundColor Yellow }
    if ($null -eq $freq) { Remove-ItemProperty $rk SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
    else { Set-ItemProperty $rk SystemRestorePointCreationFrequency $freq -Type DWord -ErrorAction SilentlyContinue }
}
function Start-Log { try { Start-Transcript -Path (Join-Path $bk 'log.txt') -Append | Out-Null } catch {} }
function Stop-Log  { try { Stop-Transcript | Out-Null } catch {} }
function Show-Result {
    Write-Host ''
    Write-Host '  ' -NoNewline
    if ($script:fail.Count) { Chip '完成' DarkYellow Black } else { Chip '完成' DarkGreen White }
    Write-Host "  成功 $($script:ok) 项，失败 $($script:fail.Count) 项"
    if ($script:fail.Count) { $script:fail | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow } }
    Write-Host "  恢复记录与日志: $bk" -ForegroundColor DarkGray
    Write-Host '  部分设置需要注销或重启电脑才能完全生效。' -ForegroundColor DarkGray
}

# ------------------------------------------------------------
# 界面：只用 ASCII 与中日韩字符，不用制表符/圆点等「宽度不定」字符，conhost 与 Windows Terminal 下都能对齐
function TW([string]$s) {
    # 显示宽度：中日韩及全角字符占 2 列
    $n = 0
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if (($c -ge 0x1100 -and $c -le 0x115F) -or ($c -ge 0x2E80 -and $c -le 0xA4CF) -or ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or ($c -ge 0xFE30 -and $c -le 0xFE4F) -or ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $n += 2 } else { $n++ }
    }
    $n
}
function Cut([string]$s, [int]$max) {
    if ($max -le 3) { return '' }
    if ((TW $s) -le $max) { return $s }
    $out = ''; $n = 0
    foreach ($ch in $s.ToCharArray()) {
        $cw = TW ([string]$ch)
        if ($n + $cw -gt $max - 3) { break }
        $out += $ch; $n += $cw
    }
    $out + '...'
}
function Pad([string]$s, [int]$w) { $s = Cut $s $w; $s + (' ' * [math]::Max(0, $w - (TW $s))) }
function UiWidth {
    $w = 100
    try { $w = [int]$Host.UI.RawUI.WindowSize.Width } catch {}
    if ($w -lt 40) { $w = 100 }
    [math]::Min($w, 120)
}
# 带底色的文字一律 -NoNewline，换行单独用默认颜色写，避免滚屏时底色漫到整行
function Chip($t, $bg = 'DarkGray', $fg = 'White') { Write-Host " $t " -NoNewline -BackgroundColor $bg -ForegroundColor $fg }
function Bar($left, $right, $bg = 'DarkCyan', $fg = 'White') {
    $w = (UiWidth) - 4
    $gap = $w - (TW $left) - (TW $right)
    if ($gap -lt 2) { $right = ''; $gap = 0 }
    Write-Host '  ' -NoNewline
    Write-Host (Pad ($left + (' ' * $gap) + $right) $w) -NoNewline -BackgroundColor $bg -ForegroundColor $fg
    Write-Host ''
}
function Section($n) {
    Write-Host ''
    Write-Host '  ' -NoNewline
    Chip ('{0,2}' -f $n) DarkCyan White
    Write-Host (' ' + $menu[$n][0]) -ForegroundColor Cyan
}
function Ask($q) {
    Write-Host "  $q " -NoNewline -ForegroundColor Yellow
    ([string]$Host.UI.ReadLine()).Trim().ToLower()
}
function Wait-Menu { Write-Host ''; Write-Host '  按回车返回菜单' -NoNewline -ForegroundColor DarkGray; [void]$Host.UI.ReadLine() }

# ------------------------------------------------------------
# 菜单：序号 -> (名称, 简述, 函数, 分组)；详细说明见 README
$menu = [ordered]@{
    '1'  = @('后台应用、Edge、视觉效果、电源', '商店应用禁后台（白名单除外），关 Edge 常驻与预启动，精简动画，最佳性能电源', ${function:Opt1}, '性能与系统')
    '2'  = @('服务、开机启动、快速启动与休眠', '禁用遥测/地图/WAP 推送服务与音频托盘自启，关快速启动，台式机关休眠', ${function:Opt2}, '性能与系统')
    '3'  = @('卸载小组件 (Widgets)',           '卸载 Windows 小组件，策略阻止重装', ${function:Opt3}, '性能与系统')
    '4'  = @('搜索隐私',                       '关闭 Bing、云搜索、搜索要点与搜索历史', ${function:Opt4}, '隐私')
    '5'  = @('遥测、诊断与活动历史',           '遥测降到版本允许的最低级，关错误报告、CEIP、兼容性收集、活动历史', ${function:Opt5}, '隐私')
    '6'  = @('广告、推荐与推广内容',           '关广告 ID、开始菜单推荐、锁屏与设置推广、预装应用推送', ${function:Opt6}, '隐私')
    '7'  = @('输入、语音、Copilot、传递优化',  '关输入与墨迹收集、在线语音、Recall，卸载 Copilot，传递优化只用 HTTP', ${function:Opt7}, '隐私')
    '8'  = @('数据收集计划任务',               '兼容性评估、CEIP、磁盘诊断、反馈、Office 遥测等（影响大版本升级前检查）', ${function:Opt8}, '隐私')
    '9'  = @('清理临时文件与系统组件',         ('清理 {0} 天前的 Temp 文件，可选清理 WinSxS 旧组件' -f $TempAgeDays), ${function:Opt9}, '清理与存储')
    '10' = @('移动用户文件夹到其他盘',         ('桌面/下载/文档等移到 {0}，不含在 a 中，也不在 r 恢复范围' -f $UsersDirDefault), ${function:Opt10}, '清理与存储')
}

function Show-Menu {
    Clear-Host
    $w = UiWidth
    Write-Host ''
    Bar '' ''
    Bar '  Windows 优化工具' ($osInfo + '  ')
    Bar '' ''
    $tw = ($menu.Values | ForEach-Object { TW $_[0] } | Measure-Object -Maximum).Maximum
    $g = $null
    foreach ($k in $menu.Keys) {
        $m = $menu[$k]
        if ($m[3] -ne $g) {
            $g = $m[3]
            Write-Host ''
            Write-Host '  ' -NoNewline; Write-Host ' ' -NoNewline -BackgroundColor DarkCyan; Write-Host " $g" -ForegroundColor Cyan
        }
        Write-Host '    ' -NoNewline
        Chip ('{0,2}' -f $k)
        Write-Host ('  ' + (Pad $m[0] $tw) + '   ') -NoNewline -ForegroundColor White
        Write-Host (Cut $m[1] ($w - 4 - 4 - 2 - $tw - 3 - 2)) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '    ' -NoNewline
    foreach ($a in @(@('a', '全部执行 1-9'), @('c', '状态检查'), @('r', '恢复到优化前'), @('q', '退出'))) {
        Chip $a[0] DarkYellow Black
        Write-Host (' ' + $a[1] + '     ') -NoNewline
    }
    Write-Host ''
    $hint = '    可多选，空格或逗号分隔，例如 1 4 6'
    if ($script:undo.Count) { $hint += "；已记录 $($script:undo.Count) 项改动，可用 r 恢复" }
    Write-Host $hint -ForegroundColor DarkGray
}

Load-Undo
try { $Host.UI.RawUI.WindowTitle = 'Windows 优化工具' } catch {}
while ($true) {
    Show-Menu
    Write-Host ''
    Write-Host '  > ' -NoNewline -ForegroundColor Cyan
    $in = ([string]$Host.UI.ReadLine()).Trim().ToLower()
    if ($in -in 'q', '0', 'quit', 'exit') { break }
    if ($in -eq '') { continue }

    if ($in -eq 'c') {
        # 只读：逐项比对 1-9 的当前值与目标值，大版本更新后用来确认哪些设置被还原了
        $script:check = $true; $script:match = 0; $script:diffN = 0
        try {
            foreach ($n in @($menu.Keys | Where-Object { $_ -ne '10' })) {
                Section $n
                & $menu[$n][2]
            }
        } finally { $script:check = $false }
        Write-Host ''
        Write-Host '  ' -NoNewline
        if ($script:diffN) { Chip '检查' DarkYellow Black } else { Chip '检查' DarkGreen White }
        Write-Host "  已生效 $($script:match) 项，未生效 $($script:diffN) 项"
        if ($script:diffN) { Write-Host '  未生效的项重新执行对应序号即可（Windows 大版本更新后常见）。' -ForegroundColor Yellow }
        Wait-Menu
        continue
    }

    if ($in -eq 'r') {
        if (-not $script:undo.Count) { Write-Host ''; Write-Host '  没有可恢复的记录。' -ForegroundColor Yellow; Wait-Menu; continue }
        Write-Host ''
        if ((Ask "将把已记录的 $($script:undo.Count) 项改动恢复到优化前，确认？(y/N)") -ne 'y') { continue }
        Start-Log
        $script:ok = 0; $script:fail = @()
        Restore-All
        Show-Result
        Stop-Log
        Wait-Menu
        continue
    }

    Write-Host ''
    if ($in -eq 'a') { $sel = @($menu.Keys | Where-Object { $_ -ne '10' }) }   # 10 会改动文件位置，不包含在「全部」里
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
    if (-not $sel.Count) { Write-Host '  没有有效选项。' -ForegroundColor Yellow; Wait-Menu; continue }

    Write-Host '  将执行：' -ForegroundColor Cyan
    foreach ($n in $sel) { Write-Host '    ' -NoNewline; Chip ('{0,2}' -f $n); Write-Host ('  ' + $menu[$n][0]) }
    Write-Host ''
    if ((Ask '确认执行？(Y/n)') -eq 'n') { continue }

    Prepare
    Start-Log
    $script:ok = 0; $script:fail = @()
    foreach ($n in $sel) {
        Section $n
        & $menu[$n][2]
        Save-Undo   # 每项执行完立即保存，中途关窗也不丢记录
    }
    Show-Result
    Stop-Log
    Wait-Menu
}

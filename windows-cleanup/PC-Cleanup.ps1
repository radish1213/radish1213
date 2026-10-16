#Requires -Version 5.1
<#
    Windows 深度清理与优化脚本 (Windows 10 / 11)

    每一步执行前都会询问 [Y/N]，可以按需跳过。
    运行结束后会在桌面生成一份清理报告。

    步骤：
      0. 创建系统还原点（出问题可以一键回滚）
      1. 清理垃圾文件：临时文件、更新缓存、错误报告、缩略图缓存、回收站、Windows.old
      2. 查找已卸载软件的残留文件夹和失效快捷方式（由你勾选，删除到回收站）
      3. 移除微软自带的无用应用，关闭小组件 / 桌面新闻 / 开始菜单广告和网页搜索
      4. 性能优化：关闭遥测服务、电源计划、休眠文件、磁盘优化、启动项和内存占用报告
      5. 清理系统组件存储 (DISM)，比较慢，放在最后
#>

$ErrorActionPreference = 'SilentlyContinue'

# ---------------------------------------------------------------- 管理员权限
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# ---------------------------------------------------------------- 可自行修改的列表
# 要移除的微软预装应用。不想删的项目在行首加 # 注释掉即可。
$BloatApps = @(
    'Microsoft.BingNews'                    # 资讯
    'Microsoft.BingWeather'                 # 天气
    'Microsoft.BingSearch'                  # Bing 搜索
    'Microsoft.GetHelp'                     # 获取帮助
    'Microsoft.Getstarted'                  # 使用技巧
    'Microsoft.MicrosoftSolitaireCollection'# 纸牌游戏
    'Microsoft.People'                      # 人脉
    'Microsoft.WindowsFeedbackHub'          # 反馈中心
    'Microsoft.MicrosoftOfficeHub'          # Office 推广入口（不影响已安装的 Office）
    'Microsoft.SkypeApp'                    # Skype
    'Microsoft.ZuneVideo'                   # 电影和电视
    'Microsoft.WindowsMaps'                 # 地图
    'Microsoft.549981C3F5F10'               # Cortana
    'Microsoft.MixedReality.Portal'         # 混合现实门户
    'Microsoft.Microsoft3DViewer'           # 3D 查看器
    'Microsoft.PowerAutomateDesktop'        # Power Automate
    'Clipchamp.Clipchamp'                   # Clipchamp 视频编辑
    'Microsoft.MicrosoftStickyNotes'        # 便笺（常用的话请注释掉这一行）
    # 'Microsoft.XboxApp'                   # Xbox（玩游戏的话保留）
    # 'Microsoft.GamingApp'                 # Xbox（新版）
    # 'Microsoft.YourPhone'                 # 手机连接
    # 'Microsoft.Todos'                     # Microsoft To Do
)

# 查找残留时一律跳过的文件夹（系统和驱动相关）
$SkipFolders = @(
    'Microsoft*', 'Windows*', 'Common Files', 'Internet Explorer', 'Packages', 'Package Cache',
    'Temp', 'ModifiableWindowsApps', 'Reference Assemblies', 'MSBuild', 'dotnet', 'regid.*',
    'Comms', 'ConnectedDevicesPlatform', 'D3DSCache', 'PeerDistRepub', 'Publishers',
    'PlaceholderTileLogoFolder', 'VirtualStore', 'Programs', 'CrashDumps', 'USOShared',
    'USOPrivate', 'ssh', 'SoftwareDistribution', 'IsolatedStorage', 'PackageManagement',
    'ElevatedDiagnostics', 'Application Data', 'Desktop', 'Documents', 'Start Menu', 'Templates',
    'History', 'Temporary Internet Files', 'Intel*', 'NVIDIA*', 'AMD', 'ATI', 'Realtek*',
    'Dell', 'Lenovo', 'HP', 'Hewlett-Packard', 'ASUS', 'Huawei', 'Huawei*', 'Acer', 'MSI',
    'Synaptics', 'Elan', 'Killer*', 'Dolby', 'Waves', 'Conexant', 'Package Store', 'Default*'
)

# ---------------------------------------------------------------- 工具函数
Add-Type -AssemblyName Microsoft.VisualBasic

function Ask([string]$Question) {
    Write-Host ''
    $a = Read-Host "$Question [Y/N]"
    return ($a -match '^[Yy]')
}

function Section([string]$Title) {
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor Cyan
}

function Get-FreeGB { [math]::Round((Get-PSDrive -Name C).Free / 1GB, 2) }

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Get-FolderSize([string]$Path) {
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($sum) { return [double]$sum } else { return 0 }
}

# 清空文件夹里的内容（保留文件夹本身），被占用的文件自动跳过
function Clear-Folder([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $size = Get-FolderSize $Path
    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $freed = $size - (Get-FolderSize $Path)
    Write-Host ("  {0,-28} 释放 {1}" -f $Label, (Format-Size $freed))
}

function Send-ToRecycleBin([string]$Path) {
    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
        }
        return $true
    } catch {
        Write-Host "  跳过（文件被占用或无权限）：$Path" -ForegroundColor DarkYellow
        return $false
    }
}

function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# 解析 "1,3,5-8" 这样的输入
function Parse-Selection([string]$Text, [int]$Max) {
    $result = @()
    foreach ($part in ($Text -split '[,，\s]+')) {
        if ($part -match '^(\d+)-(\d+)$') { $result += [int]$Matches[1]..[int]$Matches[2] }
        elseif ($part -match '^\d+$') { $result += [int]$part }
    }
    return $result | Where-Object { $_ -ge 1 -and $_ -le $Max } | Sort-Object -Unique
}

function Normalize([string]$s) {
    if (-not $s) { return '' }
    return ($s.ToLower() -replace '[^a-z0-9\u4e00-\u9fa5]', '')
}

# 从 "C:\xx\yy.exe" /arg 之类的字符串里取出所在目录
function Get-DirFromCommand([string]$s) {
    if ($s -match '([a-zA-Z]:\\[^"]+?\.(exe|dll|ico|msi))') { return (Split-Path $Matches[1] -Parent) }
    return $null
}

# ---------------------------------------------------------------- 开始
$report = Join-Path ([Environment]::GetFolderPath('Desktop')) ("清理报告_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
Start-Transcript -Path $report | Out-Null
$freeBefore = Get-FreeGB

Write-Host ''
Write-Host '  Windows 深度清理与优化' -ForegroundColor Green
Write-Host "  当前 C 盘可用空间：$freeBefore GB"
Write-Host '  建议先关闭浏览器、微信、QQ 等正在运行的软件，清理效果更好。'

# ================================================================ 0. 还原点
Section '0. 创建系统还原点'
if (Ask '创建还原点？（强烈建议，出问题时可在「系统还原」中回滚）') {
    Enable-ComputerRestore -Drive 'C:\'
    # Windows 默认 24 小时内只允许创建一个还原点，临时放开
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
    Checkpoint-Computer -Description '深度清理前' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction SilentlyContinue
    if ($?) { Write-Host '  还原点已创建。' -ForegroundColor Green }
    else { Write-Host '  还原点创建失败（可能系统保护被组策略禁用），继续执行。' -ForegroundColor Yellow }
}

# ================================================================ 1. 垃圾文件
Section '1. 清理垃圾文件'
if (Ask '清理临时文件、更新缓存、错误报告、缩略图缓存和回收站？') {
    Clear-Folder $env:TEMP                                            '用户临时文件'
    Clear-Folder "$env:SystemRoot\Temp"                               '系统临时文件'
    Clear-Folder "$env:LOCALAPPDATA\CrashDumps"                       '程序崩溃转储'
    Clear-Folder "$env:ProgramData\Microsoft\Windows\WER"             '错误报告'
    Clear-Folder "$env:LOCALAPPDATA\Microsoft\Windows\WER"            '错误报告（用户）'
    Clear-Folder "$env:LOCALAPPDATA\Microsoft\Windows\INetCache"      'IE/系统网页缓存'
    Clear-Folder "$env:SystemRoot\Logs\CBS"                           '系统组件日志'

    # Windows 更新下载缓存（已安装的更新包，不影响系统）
    Stop-Service -Name wuauserv, bits -Force
    Clear-Folder "$env:SystemRoot\SoftwareDistribution\Download"      'Windows 更新缓存'
    Start-Service -Name wuauserv, bits

    # 传递优化缓存
    Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
    Write-Host ('  {0,-28} 已清理' -f '传递优化缓存')

    # 缩略图缓存（Windows 会自动重建）
    Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Filter 'thumbcache_*.db' -Force |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host ('  {0,-28} 已清理' -f '缩略图缓存')

    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    Write-Host ('  {0,-28} 已清空' -f '回收站')
}

# 浏览器缓存：只有浏览器关闭时才清理
$browserCaches = @{
    'Edge'   = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
    'Chrome' = "$env:LOCALAPPDATA\Google\Chrome\User Data"
}
if (Ask '清理 Edge / Chrome 浏览器缓存？（不会删除密码、书签和登录状态）') {
    foreach ($name in $browserCaches.Keys) {
        $root = $browserCaches[$name]
        if (-not (Test-Path $root)) { continue }
        $proc = if ($name -eq 'Edge') { 'msedge' } else { 'chrome' }
        if (Get-Process -Name $proc -ErrorAction SilentlyContinue) {
            Write-Host "  $name 正在运行，已跳过。请关闭后重新运行本脚本。" -ForegroundColor Yellow
            continue
        }
        Get-ChildItem $root -Directory | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } | ForEach-Object {
            foreach ($sub in 'Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage') {
                Clear-Folder (Join-Path $_.FullName $sub) "$name 缓存 ($($_.Name)\$sub)"
            }
        }
    }
}

if (Test-Path "$env:SystemDrive\Windows.old") {
    $oldSize = Format-Size (Get-FolderSize "$env:SystemDrive\Windows.old")
    if (Ask "发现旧系统文件夹 Windows.old（$oldSize）。删除后将无法回退到上一个 Windows 版本，是否删除？") {
        takeown /F "$env:SystemDrive\Windows.old" /R /A /D Y | Out-Null
        icacls "$env:SystemDrive\Windows.old" /grant '*S-1-5-32-544:F' /T /C /Q | Out-Null
        Remove-Item "$env:SystemDrive\Windows.old" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host '  Windows.old 已删除。' -ForegroundColor Green
    }
}

# ================================================================ 2. 卸载残留
Section '2. 已卸载软件的残留文件'
if (Ask '扫描已卸载软件留下的文件夹和失效快捷方式？（扫描完由你选择删哪些）') {
    Write-Host '  正在读取已安装软件列表...'
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $installed = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }

    $keywords = New-Object System.Collections.Generic.HashSet[string]
    $knownDirs = New-Object System.Collections.Generic.List[string]
    foreach ($app in $installed) {
        [void]$keywords.Add((Normalize $app.DisplayName))
        [void]$keywords.Add((Normalize $app.Publisher))
        foreach ($d in @($app.InstallLocation, (Get-DirFromCommand $app.UninstallString), (Get-DirFromCommand $app.DisplayIcon))) {
            if ($d) { $knownDirs.Add($d.Trim('"').TrimEnd('\').ToLower()) }
        }
    }
    foreach ($pkg in (Get-AppxPackage -AllUsers)) { [void]$keywords.Add((Normalize $pkg.Name)) }
    # 正在运行的程序和系统服务所在目录也视为「在用」
    foreach ($p in (Get-Process | Where-Object { $_.Path })) { $knownDirs.Add((Split-Path $p.Path -Parent).ToLower()) }
    foreach ($s in (Get-CimInstance Win32_Service)) {
        $d = Get-DirFromCommand $s.PathName
        if ($d) { $knownDirs.Add($d.ToLower()) }
    }
    # 已安装软件路径中每一级文件夹名（如 Tencent），用于识别 AppData 里同名的数据文件夹
    $knownNames = New-Object System.Collections.Generic.HashSet[string]
    foreach ($d in $knownDirs) {
        foreach ($seg in ($d -split '\\' | Select-Object -Skip 1)) { [void]$knownNames.Add((Normalize $seg)) }
    }
    [void]$keywords.Remove('')

    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:APPDATA,
               $env:LOCALAPPDATA, (Join-Path $env:USERPROFILE 'AppData\LocalLow')) |
             Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    Write-Host '  正在扫描文件夹...'
    $candidates = @()
    foreach ($root in $roots) {
        foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            $name = $dir.Name
            if ($SkipFolders | Where-Object { $name -like $_ }) { continue }
            if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }

            $n = Normalize $name
            $path = $dir.FullName.ToLower()
            if ($n.Length -lt 3) { continue }
            if ($knownNames.Contains($n)) { continue }
            if ($knownDirs | Where-Object { $_.StartsWith($path + '\') -or $_ -eq $path -or $path.StartsWith($_ + '\') }) { continue }
            $matched = $false
            foreach ($k in $keywords) {
                if ($k.Contains($n) -or ($k.Length -ge 4 -and $n.Contains($k))) { $matched = $true; break }
            }
            if ($matched) { continue }

            $candidates += [pscustomobject]@{
                Path     = $dir.FullName
                Size     = Get-FolderSize $dir.FullName
                Modified = $dir.LastWriteTime
            }
        }
    }

    # 失效的快捷方式（目标程序已不存在）
    $shell = New-Object -ComObject WScript.Shell
    $lnkRoots = @(
        [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('StartMenu'), [Environment]::GetFolderPath('CommonStartMenu')
    )
    foreach ($lr in $lnkRoots) {
        foreach ($lnk in (Get-ChildItem -LiteralPath $lr -Filter '*.lnk' -Recurse -Force -ErrorAction SilentlyContinue)) {
            $target = $shell.CreateShortcut($lnk.FullName).TargetPath
            if ($target -and $target -match '^[a-zA-Z]:\\' -and -not (Test-Path -LiteralPath $target)) {
                $candidates += [pscustomobject]@{ Path = $lnk.FullName; Size = $lnk.Length; Modified = $lnk.LastWriteTime }
            }
        }
    }

    if ($candidates.Count -eq 0) {
        Write-Host '  没有发现明显的卸载残留。' -ForegroundColor Green
    } else {
        $candidates = @($candidates | Sort-Object Size -Descending)
        Write-Host ''
        Write-Host '  以下项目找不到对应的已安装软件，可能是卸载残留。' -ForegroundColor Yellow
        Write-Host '  请逐条确认：认识的软件残留再删；不认识的、或你还在用的（例如绿色版软件）不要选。' -ForegroundColor Yellow
        Write-Host ''
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $c = $candidates[$i]
            Write-Host ('  [{0,3}] {1,10}  {2:yyyy-MM-dd}  {3}' -f ($i + 1), (Format-Size $c.Size), $c.Modified, $c.Path)
        }
        Write-Host ''
        $sel = Read-Host '  输入要删除的编号（例如 1,3,5-8；直接回车跳过）'
        $picked = Parse-Selection $sel $candidates.Count
        $freed = 0
        foreach ($idx in $picked) {
            $c = $candidates[$idx - 1]
            if (Send-ToRecycleBin $c.Path) {
                $freed += $c.Size
                Write-Host "  已移到回收站：$($c.Path)"
            }
        }
        if ($picked) {
            Write-Host ("  共 {0} 项，{1}。已放入回收站，确认电脑正常后再清空回收站。" -f @($picked).Count, (Format-Size $freed)) -ForegroundColor Green
        }
    }
}

# ================================================================ 3. 预装应用和小组件
Section '3. 移除微软自带的无用应用，关闭小组件和桌面新闻'
$present = @(Get-AppxPackage -AllUsers | Where-Object { $BloatApps -contains $_.Name } | Select-Object -ExpandProperty Name -Unique)
if ($present.Count -gt 0) {
    Write-Host '  将移除以下应用（之后可在 Microsoft Store 重新安装）：'
    $present | ForEach-Object { Write-Host "    - $_" }
    if (Ask '确认移除？') {
        foreach ($name in $present) {
            Get-AppxPackage -AllUsers -Name $name | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $name } |
                Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  已移除：$name"
        }
    }
} else {
    Write-Host '  列表中的预装应用都已不存在。'
}

if (Ask '关闭任务栏小组件 / 资讯和兴趣（桌面新闻、天气）、开始菜单广告和 Bing 网页搜索？') {
    # Windows 11 小组件
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
    # Windows 10 资讯和兴趣
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds' 'ShellFeedsTaskbarViewMode' 2
    # 开始菜单搜索里的 Bing 网页结果（同时让本地搜索更快）
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    # 开始菜单推荐、锁屏广告、自动安装推广应用
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($v in 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled',
                   'RotatingLockScreenOverlayEnabled', 'SubscribedContent-338387Enabled',
                   'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
                   'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled') {
        Set-Reg $cdm $v 0
    }
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0

    Stop-Process -Name explorer -Force
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Write-Host '  已关闭，任务栏已刷新。' -ForegroundColor Green
}

# ================================================================ 4. 性能优化
Section '4. 性能优化'

if (Ask '关闭微软遥测服务（DiagTrack，后台上传使用数据，关闭后不影响正常使用）？') {
    Stop-Service -Name DiagTrack -Force
    Set-Service -Name DiagTrack -StartupType Disabled
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    Write-Host '  已关闭。' -ForegroundColor Green
}

$isLaptop = [bool](Get-CimInstance Win32_Battery)
$planHint = if ($isLaptop) { '（检测到笔记本：插电使用更快，但用电池时会更耗电）' } else { '' }
if (Ask "切换到「高性能」电源计划？$planHint") {
    powercfg /setactive SCHEME_MIN
    Write-Host '  已切换。想恢复的话：设置 → 系统 → 电源 → 电源模式。' -ForegroundColor Green
}

$hiber = Get-Item "$env:SystemDrive\hiberfil.sys" -Force -ErrorAction SilentlyContinue
if ($hiber) {
    if (Ask ("关闭休眠，删除休眠文件 hiberfil.sys（{0}）？关闭后将不能「休眠」和「快速启动」，「睡眠」不受影响。" -f (Format-Size $hiber.Length))) {
        powercfg -h off
        Write-Host '  已关闭休眠。想恢复的话以管理员身份运行：powercfg -h on' -ForegroundColor Green
    }
}

if (Ask '优化 C 盘（固态硬盘执行 TRIM，机械硬盘执行碎片整理，系统自动判断）？') {
    Optimize-Volume -DriveLetter C -Verbose
}

Write-Host ''
Write-Host '  ---- 开机自启动的程序 ----' -ForegroundColor Cyan
Write-Host '  自启动越多开机越慢、占内存越多。不需要的请在 任务管理器 → 启动应用 里右键「禁用」。'
Get-CimInstance Win32_StartupCommand | Sort-Object Name |
    ForEach-Object { Write-Host ('    - {0}  ({1})' -f $_.Name, $_.Location) }

Write-Host ''
Write-Host '  ---- 内存占用 ----' -ForegroundColor Cyan
$os = Get-CimInstance Win32_OperatingSystem
$totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$usedGB = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
Write-Host "  已用 $usedGB GB / 共 $totalGB GB。占用最多的程序："
Get-Process | Group-Object ProcessName | ForEach-Object {
    [pscustomobject]@{ Name = $_.Name; MB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB) }
} | Sort-Object MB -Descending | Select-Object -First 10 |
    ForEach-Object { Write-Host ('    {0,-30} {1,6} MB' -f $_.Name, $_.MB) }

# ================================================================ 5. DISM
Section '5. 清理系统组件存储（WinSxS）'
if (Ask '清理已被替代的旧版系统组件？（需要 5-20 分钟，期间不要关机）') {
    Dism.exe /Online /Cleanup-Image /StartComponentCleanup
}

# ================================================================ 6. Claude 图标
Section '6. 桌面快捷方式换成 Claude 图标'
# 图标直接取自本机已安装的 Claude 桌面版程序
$claudeExe = @(
    "$env:LOCALAPPDATA\AnthropicClaude\claude.exe",
    "$env:LOCALAPPDATA\Programs\Claude\Claude.exe"
) + @(Get-ChildItem "$env:ProgramFiles\WindowsApps" -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
      ForEach-Object { Join-Path $_.FullName 'app\claude.exe' }) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not $claudeExe) {
    Write-Host '  没找到 Claude 桌面版，跳过。安装 Claude 桌面版（claude.ai/download）后重新运行即可。' -ForegroundColor Yellow
} elseif (Ask '在桌面创建「深度清理」快捷方式，并把桌面上的 Claude 快捷方式都统一成 Claude 图标？') {
    $shell = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath('Desktop')

    $lnk = $shell.CreateShortcut((Join-Path $desktop '深度清理.lnk'))
    $lnk.TargetPath = 'powershell.exe'
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $lnk.IconLocation = "$claudeExe,0"
    $lnk.Save()
    Write-Host '  已创建桌面快捷方式「深度清理」（Claude 图标），以后双击即可再次清理。' -ForegroundColor Green

    foreach ($dt in $desktop, [Environment]::GetFolderPath('CommonDesktopDirectory')) {
        foreach ($f in (Get-ChildItem -LiteralPath $dt -Filter '*Claude*.lnk' -Force -ErrorAction SilentlyContinue)) {
            $s = $shell.CreateShortcut($f.FullName)
            $s.IconLocation = "$claudeExe,0"
            $s.Save()
            Write-Host "  已更新图标：$($f.Name)"
        }
    }
    ie4uinit.exe -show   # 刷新图标缓存
}

# ================================================================ 结束
$freeAfter = Get-FreeGB
Section '完成'
Write-Host "  C 盘可用空间：$freeBefore GB  →  $freeAfter GB（多出 $([math]::Round($freeAfter - $freeBefore, 2)) GB）" -ForegroundColor Green
Write-Host "  清理报告已保存到：$report"
Write-Host '  请重启电脑，让所有设置生效并彻底释放内存。' -ForegroundColor Yellow
Stop-Transcript | Out-Null
Write-Host ''
Read-Host '按回车键退出'

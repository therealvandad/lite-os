#Requires -Version 5.1
<#
.SYNOPSIS
    Lite OS playbook - gaming-focused tweaks for Windows 11 24H2 / 25H2 (build 26100+).

.DESCRIPTION
    Without parameters an interactive menu is shown:
      1 Balanced (recommended)  2 Extreme  3 Custom  4 Install gaming apps
      5 Revert  6 View log  0 Exit

    Balanced keeps Windows Defender, Windows Update security updates, Microsoft Store,
    Xbox app / Game Pass / Gaming Services, Game Bar, Edge + WebView2, Windows Hello,
    VBS/HVCI, TPM/BitLocker and kernel anti-cheat working. Anything that endangers those
    is Extreme only.

    Every change is recorded in $env:ProgramData\LiteOS\backup and can be undone with
    Revert-LiteOS.ps1. A System Restore point is created first (unless -SkipRestorePoint).
    Logs: $env:ProgramData\LiteOS\logs.

    Lite OS is scripts only. It never ships Windows files, license keys or activators.

.PARAMETER Level
    Balanced or Extreme. Runs that level without the menu (asks for confirmation unless -Silent).

.PARAMETER Include
    Extra tweak ids to apply (exact ids, wildcards such as "gaming.*", comma separated).

.PARAMETER Exclude
    Tweak ids to skip (same format). Exclude wins over Include.

.PARAMETER Silent
    No prompts. Without -Level, Balanced is used.

.PARAMETER DryRun
    Show what would change. Nothing is changed, no restore point, no reboot.

.PARAMETER SkipRestorePoint
    Do not create a System Restore point before applying.

.PARAMETER SkipApps
    Never install apps (also ignores the apps setting of the ISO config).

.PARAMETER Apps
    Apps to install with winget after the tweaks: "default", "all" or winget ids.

.PARAMETER FirstLogon
    Used by the Lite OS ISO (autounattend FirstLogonCommands). Implies -Silent and runs once.
    On a Lite OS image (v2, tweaks already baked in by the Lite OS Builder): runs the SetupComplete
    stage first if Windows skipped it, applies the deferred per-user settings (for example
    HKCU:\Software\Classes) to the signed-in user, installs the winget apps from config.json
    ("apps"), and restarts Windows (60 seconds notice) only when one of those changes needs it.
    On an older ISO (no deferred.json / backup-image.json): reads config.json
    ({level, include, exclude, apps}), applies that level, then restarts after 60 seconds.

.PARAMETER SetupComplete
    Used by the Lite OS image: C:\Windows\Setup\Scripts\SetupComplete.cmd runs this as SYSTEM after
    Windows is installed and before the first sign-in. No UI, never restarts. It applies the machine
    actions the builder could not bake offline (C:\LiteOS\deferred.json: scheduled tasks, machine
    scripts, ...) and records them in $env:ProgramData\LiteOS\backup\backup-image.json, names the boot
    menu entry from C:\LiteOS\image\branding.json, runs the baked installers listed in
    C:\LiteOS\installers\installers.json silently (15 minute timeout each, failures are logged and
    skipped) and writes $env:ProgramData\LiteOS\setupcomplete.done. Safe to run again: a finished
    stage is not repeated and every step is idempotent.

.EXAMPLE
    Start-LiteOS.cmd
    Double-click: asks for administrator rights and opens the menu.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\LiteOS.ps1 -Level Balanced -Silent

.EXAMPLE
    .\LiteOS.ps1 -Level Extreme -Exclude "security-extreme.*" -DryRun
#>
[CmdletBinding()]
param(
    [ValidateSet('Balanced', 'Extreme')]
    [string]$Level,

    [string[]]$Include = @(),

    [string[]]$Exclude = @(),

    [switch]$Silent,

    [switch]$DryRun,

    [switch]$SkipRestorePoint,

    [switch]$SkipApps,

    [string[]]$Apps = @(),

    [switch]$FirstLogon,

    [switch]$SetupComplete
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Root = $PSScriptRoot
if ([string]::IsNullOrEmpty($script:Root)) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:EnginePath   = Join-Path $script:Root 'src\LiteOS.Engine.psm1'
$script:AppsScript   = Join-Path $script:Root 'src\Install-Apps.ps1'
$script:RevertScript = Join-Path $script:Root 'Revert-LiteOS.ps1'
$script:TweaksPath   = Join-Path $script:Root 'tweaks'
# Lite OS image (v2) payload written by the builder into C:\LiteOS
$script:DeferredPath       = Join-Path $script:Root 'deferred.json'
$script:InstallersDir      = Join-Path $script:Root 'installers'
$script:InstallersManifest = Join-Path $script:InstallersDir 'installers.json'
$script:BrandingPaths      = @((Join-Path $script:Root 'image\branding.json'), (Join-Path $script:Root 'branding.json'))
$script:Context      = $null
$script:Catalog      = $null
$script:ExitCode     = 0
$script:Interactive  = -not ($Silent -or $FirstLogon -or $SetupComplete)
$script:NoRestorePoint = [bool]$SkipRestorePoint

# =============================================================================================
# Small helpers
# =============================================================================================

function Split-ArgList {
    # powershell -File passes "a,b" as ONE string; accept arrays and comma/semicolon lists.
    param($Value)
    $list = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        foreach ($part in ([string]$item).Split(@(',', ';'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $t = $part.Trim()
            if ($t.Length -gt 0) { $list.Add($t) }
        }
    }
    return , ($list.ToArray())
}

function Read-Answer {
    param([string]$Prompt)
    $a = $null
    try { $a = Read-Host -Prompt $Prompt } catch { return $null }
    if ($null -eq $a) { return $null }
    return ([string]$a).Trim()
}

function Confirm-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $suffix = '[y/N]'
    if ($Default) { $suffix = '[Y/n]' }
    $a = Read-Answer ('  {0} {1}' -f $Prompt, $suffix)
    if ($null -eq $a) { return $false }
    if ($a -eq '') { return $Default }
    return ($a -match '^(?i)(y|yes)$')
}

function Wait-Enter {
    if (-not $script:Interactive) { return }
    Write-Host ''
    [void](Read-Answer '  Press Enter to continue')
}

function Get-ConsoleWidth {
    $w = 100
    try { $w = [Console]::WindowWidth - 2 } catch { $w = 100 }
    if ($w -lt 40) { $w = 80 }
    return $w
}

function Write-Wrapped {
    param([string]$Text, [int]$Indent = 8, [string]$Color = 'Gray')
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $max = (Get-ConsoleWidth) - $Indent
    if ($max -lt 30) { $max = 30 }
    $pad = ' ' * $Indent
    $line = ''
    foreach ($word in ($Text.Trim() -split '\s+')) {
        if ($line.Length -gt 0 -and ($line.Length + 1 + $word.Length) -gt $max) {
            Write-Host ($pad + $line) -ForegroundColor $Color
            $line = $word
        }
        elseif ($line.Length -gt 0) { $line = $line + ' ' + $word }
        else { $line = $word }
    }
    if ($line.Length -gt 0) { Write-Host ($pad + $line) -ForegroundColor $Color }
}

function ConvertFrom-NumberList {
    # "1 3 5-7" -> 1,3,5,6,7 (1..Max). Returns $null if the text is not a number list.
    param([string]$Text, [int]$Max)
    $set = New-Object -TypeName 'System.Collections.Generic.List[int]'
    foreach ($tok in ($Text -split '[\s,;]+')) {
        if ([string]::IsNullOrEmpty($tok)) { continue }
        if ($tok -match '^(\d+)-(\d+)$') {
            $a = [int]$Matches[1]
            $b = [int]$Matches[2]
            if ($a -gt $b) { $tmp = $a; $a = $b; $b = $tmp }
            for ($i = $a; $i -le $b; $i++) { if ($i -ge 1 -and $i -le $Max -and -not $set.Contains($i)) { $set.Add($i) } }
        }
        elseif ($tok -match '^\d+$') {
            $i = [int]$tok
            if ($i -ge 1 -and $i -le $Max -and -not $set.Contains($i)) { $set.Add($i) }
        }
        else { return $null }
    }
    return , ($set.ToArray())
}

function ConvertTo-LevelName {
    param($Value)
    $v = ([string]$Value).Trim()
    if ($v -match '^(?i)balanced$') { return 'Balanced' }
    if ($v -match '^(?i)extreme$') { return 'Extreme' }
    if ($v -match '^(?i)(none|custom)$') { return 'None' }
    return $null
}

function Get-ObjectValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

# =============================================================================================
# Screen pieces
# =============================================================================================

function Show-Header {
    param([string]$Subtitle)
    if ($script:Interactive) { try { Clear-Host } catch { $null = $_ } }
    $c = $script:Context
    Write-Host ''
    Write-Host '  LITE OS' -ForegroundColor Cyan -NoNewline
    Write-Host ('  v{0}  -  gaming-focused Windows 11 playbook' -f $c.Version) -ForegroundColor DarkGray
    $ver = $c.DisplayVersion
    if ([string]::IsNullOrEmpty($ver)) { $ver = '' } else { $ver = ' ' + $ver }
    Write-Host ('  {0}{1}  |  build {2}.{3}  |  {4}' -f $c.ProductName, $ver, $c.Build, $c.UBR, $c.Architecture)
    if ($c.Build -lt 22000) {
        Write-Host '  This is not Windows 11. Lite OS is made for Windows 11 24H2 / 25H2 (build 26100+).' -ForegroundColor Red
    }
    elseif ($c.Build -lt 26100) {
        Write-Host ('  WARNING: build {0} is older than 26100 (24H2). Lite OS targets 24H2 / 25H2; some tweaks' -f $c.Build) -ForegroundColor Yellow
        Write-Host '  are skipped on older builds and others are untested there. Update Windows first if you can.' -ForegroundColor Yellow
    }
    if ($DryRun) { Write-Host '  DRY RUN - nothing will be changed.' -ForegroundColor Magenta }
    Write-Host ('  ' + ('=' * 68)) -ForegroundColor DarkGray
    if ($Subtitle) {
        Write-Host ('  ' + $Subtitle) -ForegroundColor White
        Write-Host ''
    }
}

function Show-AdminHelp {
    Write-Host ''
    Write-Host '  Lite OS needs administrator rights.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Easiest: double-click Start-LiteOS.cmd in the Lite OS folder. It asks for'
    Write-Host '  administrator rights (UAC) by itself and then opens this menu.'
    Write-Host ''
    Write-Host '  Or open "Windows PowerShell" with "Run as administrator" and run:'
    Write-Host ('    powershell -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $script:Root 'LiteOS.ps1')) -ForegroundColor Cyan
    Write-Host ''
}

function Show-PlanOverview {
    param([object[]]$Tweaks)
    $list = @($Tweaks)
    $groups = [ordered]@{}
    foreach ($t in $list) {
        $k = [string]$t.categoryTitle
        if (-not $k) { $k = [string]$t.category }
        if (-not $groups.Contains($k)) { $groups[$k] = 0 }
        $groups[$k] = [int]$groups[$k] + 1
    }
    Write-Host ('  {0} tweak(s) selected:' -f $list.Count)
    foreach ($k in $groups.Keys) { Write-Host ('    {0,-54} {1,4}' -f $k, $groups[$k]) }
    $ext = @($list | Where-Object { $_.level -eq 'extreme' }).Count
    if ($ext -gt 0) { Write-Host ('  {0} of them are EXTREME tweaks.' -f $ext) -ForegroundColor Yellow }
    Write-Host ''
    if ($script:NoRestorePoint) {
        Write-Host '  A backup of every change is written first; Revert-LiteOS.ps1 undoes them.' -ForegroundColor DarkGray
    }
    else {
        Write-Host '  A System Restore point and a backup of every change are made first;' -ForegroundColor DarkGray
        Write-Host '  Revert-LiteOS.ps1 (menu option 5) undoes the changes.' -ForegroundColor DarkGray
    }
    Write-Host ''
}

function Show-ExtremeWarning {
    param([object[]]$ExtremeTweaks)
    $list = @($ExtremeTweaks)
    Write-Host ''
    Write-Host '  !!! EXTREME - READ EVERY LINE BEFORE YOU CONTINUE !!!' -ForegroundColor Red
    Write-Host ''
    Write-Wrapped -Indent 2 -Color Yellow -Text 'Extreme trades safety and compatibility for the last bit of performance. It can turn off or weaken protections that Balanced always keeps: Windows Defender / SmartScreen, automatic security updates, VBS / memory integrity (HVCI), mitigations and services some apps rely on.'
    Write-Wrapped -Indent 2 -Color Yellow -Text 'Games with kernel anti-cheat (Valorant/Vanguard, FACEIT, EA Javelin, Call of Duty Ricochet, BattlEye, EasyAntiCheat) may refuse to start when security features are disabled. Some Windows features, apps or the Microsoft Store may stop working.'
    Write-Wrapped -Indent 2 -Color Yellow -Text 'You are responsible for protecting this PC afterwards. The registry/service/task changes can be undone with Revert-LiteOS.ps1, but removed apps must be reinstalled from the Microsoft Store or winget.'
    Write-Host ''
    Write-Host ('  The following {0} EXTREME tweak(s) will be applied:' -f $list.Count) -ForegroundColor Red
    foreach ($t in $list) {
        $risk = ([string]$t.risk).ToUpperInvariant()
        Write-Host ('   [{0}] {1}' -f $risk, $t.name) -ForegroundColor Yellow
        Write-Wrapped -Indent 8 -Color Gray -Text ([string]$t.description)
    }
    Write-Host ''
}

function Get-InteractiveUserSid {
    # SID of the user who owns Explorer in this session (the person at the keyboard), or $null.
    try {
        $session = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)) {
            if ([int]$p.SessionId -ne $session) { continue }
            $r = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop
            if ($null -ne $r -and [int]$r.ReturnValue -eq 0 -and $r.Sid) { return [string]$r.Sid }
        }
    }
    catch { $null = $_ }
    return $null
}

function ConvertTo-AccountName {
    param([string]$Sid)
    try { return (New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList $Sid).Translate([System.Security.Principal.NTAccount]).Value }
    catch { return $Sid }
}

function Test-TargetUser {
    # Per-user (HKCU) tweaks follow the elevated token. If someone else's admin credentials were
    # typed at the UAC prompt (or this runs as SYSTEM), they would land in the wrong profile.
    # Returns $false when the user cancels.
    if ($FirstLogon -or $SetupComplete) { return $true }
    $runAs = [string]$script:Context.UserSid
    $who = ConvertTo-AccountName $runAs
    if ($runAs -eq 'S-1-5-18') {
        Write-LiteOSLog -Level Warn 'Lite OS is running as SYSTEM: per-user settings go to the SYSTEM profile and the Default profile (new accounts), not to any signed-in user.'
        return $true
    }
    $desk = Get-InteractiveUserSid
    if ([string]::IsNullOrEmpty($desk) -or $desk -eq $runAs) { return $true }
    $deskName = ConvertTo-AccountName $desk
    Write-LiteOSLog -Level Warn ('Lite OS runs as {0}, but {1} is signed in to this desktop. Per-user settings (mouse, Game Bar, Explorer, privacy) will change for {0} and new accounts, NOT for {1}.' -f $who, $deskName)
    if (-not $script:Interactive -or $DryRun) { return $true }
    Write-Wrapped -Indent 2 -Color Yellow -Text ('To tweak {0} instead, make {0} an administrator and start Start-LiteOS.cmd from that account.' -f $deskName)
    return (Confirm-YesNo ('Continue for {0} anyway?' -f $who) $false)
}

function Confirm-Extreme {
    $a = Read-Answer '  Type EXTREME (in capitals) to continue, anything else cancels'
    if ($null -ne $a -and $a -ceq 'EXTREME') { return $true }
    Write-Host '  Cancelled. Nothing was changed.' -ForegroundColor DarkGray
    return $false
}

# =============================================================================================
# Catalog and running
# =============================================================================================

function Import-Catalog {
    if ($null -eq $script:Catalog) {
        $script:Catalog = @(Get-LiteOSCatalog -Path $script:TweaksPath)
        if ($script:Catalog.Count -eq 0) { Write-LiteOSLog -Level Warn ('The tweak catalog in {0} is empty.' -f $script:TweaksPath) }
    }
}

function Test-PatternUsage {
    param([string[]]$Patterns, [string]$What)
    foreach ($p in @($Patterns)) {
        $hit = $false
        foreach ($t in $script:Catalog) {
            if ($t.id -eq $p) { $hit = $true; break }
            if ($p.IndexOf('*') -ge 0 -or $p.IndexOf('?') -ge 0) {
                try { if ($t.id -like $p) { $hit = $true; break } } catch { $null = $_ }
            }
        }
        if (-not $hit) { Write-LiteOSLog -Level Warn ("{0} '{1}' does not match any tweak id." -f $What, $p) }
    }
}

function Get-LevelTweaks {
    param([string]$LevelName)
    Import-Catalog
    return @(Select-LiteOSTweaks -Catalog $script:Catalog -Level $LevelName -Include $script:IncludeList -Exclude $script:ExcludeList -Build $script:Context.Build)
}

function Wait-Network {
    param([int]$TimeoutSeconds = 120)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $announced = $false
    while ($true) {
        try {
            if ([System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()) {
                $null = [System.Net.Dns]::GetHostAddresses('cdn.winget.microsoft.com')
                return $true
            }
        }
        catch { $null = $_ }
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) { return $false }
        if (-not $announced) {
            Write-LiteOSLog ('Waiting for an internet connection (up to {0} seconds)...' -f $TimeoutSeconds)
            $announced = $true
        }
        Start-Sleep -Seconds 5
    }
}

function Wait-Winget {
    param([int]$TimeoutSeconds = 90)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $announced = $false
    while ($null -eq (Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue)) {
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) { return $false }
        if (-not $announced) { Write-LiteOSLog 'Waiting for winget (App Installer) to become available...'; $announced = $true }
        Start-Sleep -Seconds 5
    }
    return $true
}

function Invoke-AppInstall {
    param([string[]]$Spec, [switch]$WaitForNetwork)
    $ids = Split-ArgList $Spec
    if ($ids.Length -eq 0) { return }
    if ($ids.Length -eq 1 -and $ids[0] -eq 'none') { return }
    if ($SkipApps) { Write-LiteOSLog 'Skipping app installs (-SkipApps).'; return }
    if (-not (Test-Path -LiteralPath $script:AppsScript -PathType Leaf)) {
        Write-LiteOSLog -Level Warn ('App installer not found ({0}); skipping apps.' -f $script:AppsScript)
        return
    }
    if ($DryRun) { Write-LiteOSLog ('Dry run: would install apps: {0}' -f ($ids -join ', ')); return }
    if ($WaitForNetwork) {
        if (-not (Wait-Network -TimeoutSeconds 120)) {
            Write-LiteOSLog -Level Warn 'No internet connection after 2 minutes - skipping app installs. Run Start-LiteOS.cmd later and choose 4.'
            return
        }
        if (-not (Wait-Winget -TimeoutSeconds 90)) {
            Write-LiteOSLog -Level Warn 'winget is not available yet; trying the app installer anyway.'
        }
    }
    Write-LiteOSLog ('Installing apps with winget: {0}' -f ($ids -join ', '))
    $failure = $null
    try {
        & $script:AppsScript -Apps $ids -Silent | Out-Host
    }
    catch {
        $failure = $_.Exception.Message
    }
    # The installer may re-import the engine (Import-Module -Force), which resets its log target.
    if ($null -eq (Get-Module -Name 'LiteOS.Engine')) { Import-Module -Name $script:EnginePath -Force -DisableNameChecking }
    [void](Initialize-LiteOS -StateRoot $script:Context.StateRoot -LogFile $script:Context.LogFile -DryRun:$DryRun)
    if ($null -ne $failure) { Write-LiteOSLog -Level Error ('App installation failed: {0}' -f $failure) }
    else { Write-LiteOSLog -NoConsole 'App installer finished.' }
}

function Invoke-Run {
    # Restore point -> plan -> summary. Returns the summary object.
    param([object[]]$Tweaks, [string]$LevelName)
    $list = @($Tweaks)
    $script:Context.Level = $LevelName
    if ($list.Count -eq 0) {
        Write-LiteOSLog -Level Warn 'Nothing selected - there are no tweaks to apply.'
        return $null
    }
    Write-LiteOSLog -NoConsole ('Run: level {0}, {1} tweak(s): {2}' -f $LevelName, $list.Count, (($list | ForEach-Object { $_.id }) -join ', '))
    if ($DryRun) {
        Write-LiteOSLog 'Dry run: no restore point, nothing will be changed.'
    }
    elseif ($script:NoRestorePoint) {
        Write-LiteOSLog 'Skipping the System Restore point (-SkipRestorePoint or config skipRestorePoint).'
    }
    else {
        [void](New-LiteOSRestorePoint -Description ('Lite OS {0} - before {1}' -f $script:Context.Version, $LevelName) -Context $script:Context)
    }
    Write-Host ''
    Write-LiteOSLog ('Applying {0} tweak(s)...' -f $list.Count)
    $results = @(Invoke-LiteOSPlan -Tweaks $list -Context $script:Context)
    $summary = Write-LiteOSSummary -Results $results -Context $script:Context
    if ($summary.Failed -gt 0 -and $script:ExitCode -eq 0) { $script:ExitCode = 2 }
    return $summary
}

function Invoke-Reboot {
    param([int]$Seconds = 60, [string]$Message)
    if ($DryRun) { Write-LiteOSLog ('Dry run: would restart Windows in {0} seconds.' -f $Seconds); return }
    $exe = Join-Path $env:SystemRoot 'System32\shutdown.exe'
    $code = -1
    $out = ''
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& $exe /r /t $Seconds /c $Message 2>&1 | ForEach-Object { [string]$_ }) -join ' '
        $code = $LASTEXITCODE
    }
    catch { $out = $_.Exception.Message }
    finally { $ErrorActionPreference = $prev }
    if ($code -eq 0) { Write-LiteOSLog -Level Warn ('Windows will restart in {0} seconds.' -f $Seconds) }
    else { Write-LiteOSLog -Level Warn ('Could not schedule the restart (shutdown.exe exit {0} {1}). Please restart Windows yourself.' -f $code, $out) }
}

function Invoke-PostRun {
    param($Summary)
    if (-not $SkipApps -and (Test-Path -LiteralPath $script:AppsScript -PathType Leaf)) {
        if (@($script:AppsList).Count -gt 0) {
            Invoke-AppInstall -Spec $script:AppsList
        }
        elseif (Confirm-YesNo 'Install gaming apps now (Steam, Discord, ...)?' $false) {
            Show-AppsMenu
        }
    }
    if (-not $DryRun -and $null -ne $Summary -and $Summary.Applied -gt 0) {
        Write-Host ''
        if (Confirm-YesNo 'Restart Windows now to finish? (recommended)' $false) {
            Invoke-Reboot -Seconds 15 -Message 'Lite OS: restarting to finish applying changes.'
        }
    }
    Wait-Enter
}

# =============================================================================================
# Menu actions
# =============================================================================================

function Invoke-MenuBalanced {
    $tw = @(Get-LevelTweaks 'Balanced')
    Show-Header 'Balanced (recommended)'
    Write-Wrapped -Indent 2 -Color Gray -Text 'Removes telemetry, ads, sponsored apps, Copilot/Recall nags and background bloat, and applies safe gaming and latency tweaks. Windows Defender, Windows Update security updates, Microsoft Store, Xbox app / Game Pass, Game Bar, Edge/WebView2, Windows Hello, VBS/HVCI and anti-cheat keep working.'
    Write-Host ''
    Show-PlanOverview $tw
    if ($tw.Count -eq 0) { Wait-Enter; return }
    if (-not (Confirm-YesNo 'Apply Balanced now?' $true)) { return }
    $sum = Invoke-Run -Tweaks $tw -LevelName 'Balanced'
    Invoke-PostRun $sum
}

function Invoke-MenuExtreme {
    $tw = @(Get-LevelTweaks 'Extreme')
    $ext = @($tw | Where-Object { $_.level -eq 'extreme' })
    Show-Header 'Extreme'
    Show-PlanOverview $tw
    if ($tw.Count -eq 0) { Wait-Enter; return }
    Show-ExtremeWarning $ext
    if (-not (Confirm-Extreme)) { Wait-Enter; return }
    $sum = Invoke-Run -Tweaks $tw -LevelName 'Extreme'
    Invoke-PostRun $sum
}

function Show-TweakDetails {
    param($Tweak)
    Write-Host ''
    Write-Host ('  {0}' -f $Tweak.name) -ForegroundColor White
    Write-Host ('  id: {0}   level: {1}   risk: {2}   default: {3}   reboot: {4}' -f $Tweak.id, $Tweak.level, $Tweak.risk, $Tweak.default, $Tweak.reboot) -ForegroundColor DarkGray
    if ($null -ne $Tweak.minBuild -or $null -ne $Tweak.maxBuild) {
        Write-Host ('  builds: {0} - {1}' -f $Tweak.minBuild, $Tweak.maxBuild) -ForegroundColor DarkGray
    }
    Write-Wrapped -Indent 2 -Color Gray -Text ([string]$Tweak.description)
    Write-Host '  Changes:' -ForegroundColor DarkGray
    foreach ($a in @($Tweak.actions)) {
        $line = [string]$a.type
        switch ([string]$a.type) {
            'registry'        { $line = 'registry  {0}\{1} = {2} ({3})' -f $a.path, $a.name, (@($a.value) -join ','), $a.kind }
            'registry-delete' { if ($null -ne $a.PSObject.Properties['name']) { $line = 'delete    {0}\{1}' -f $a.path, $a.name } else { $line = 'delete    {0} (whole key)' -f $a.path } }
            'service'         { $line = 'service   {0} -> {1}' -f $a.name, $a.startup }
            'task'            { $line = 'task      {0}{1} -> {2}' -f $a.path, $a.name, $a.state }
            'powershell'      { $line = 'script    {0}' -f (([string]$a.script -replace '\s+', ' ').Trim()) }
            'appx-remove'     { $line = 'remove    {0}' -f (@($a.packages) -join ', ') }
        }
        if ($line.Length -gt 110) { $line = $line.Substring(0, 107) + '...' }
        Write-Host ('    ' + $line) -ForegroundColor DarkGray
    }
}

function Show-CustomCategory {
    param([string]$Title, [object[]]$Tweaks, $Selected)
    $list = @($Tweaks)
    while ($true) {
        Show-Header ('Custom - ' + $Title)
        $i = 0
        foreach ($t in $list) {
            $i++
            $mark = ' '
            if ($Selected.Contains($t.id)) { $mark = 'x' }
            $color = 'Gray'
            if ($t.level -eq 'extreme') { $color = 'Yellow' }
            $name = [string]$t.name
            if ($name.Length -gt 60) { $name = $name.Substring(0, 57) + '...' }
            Write-Host ('  {0,3}  [{1}]  {2,-8} {3,-6}  {4}' -f $i, $mark, $t.level, $t.risk, $name) -ForegroundColor $color
        }
        Write-Host ''
        Write-Host '  Numbers toggle (e.g. 1 4 7-9)   A = all   N = none   D = Balanced defaults' -ForegroundColor DarkGray
        Write-Host '  ?<number> shows details (e.g. ?3)          Enter or 0 = back to categories' -ForegroundColor DarkGray
        $a = Read-Answer '  Choose'
        if ($null -eq $a -or $a -eq '' -or $a -eq '0') { return }
        if ($a -match '^\?\s*(\d+)$') {
            $n = [int]$Matches[1]
            if ($n -ge 1 -and $n -le $list.Count) { Show-TweakDetails $list[$n - 1]; Wait-Enter }
            continue
        }
        if ($a -ieq 'a') { foreach ($t in $list) { [void]$Selected.Add($t.id) }; continue }
        if ($a -ieq 'n') { foreach ($t in $list) { [void]$Selected.Remove($t.id) }; continue }
        if ($a -ieq 'd') {
            foreach ($t in $list) {
                if ($t.default -and $t.level -eq 'balanced') { [void]$Selected.Add($t.id) } else { [void]$Selected.Remove($t.id) }
            }
            continue
        }
        $nums = ConvertFrom-NumberList -Text $a -Max $list.Count
        if ($null -eq $nums) { continue }
        foreach ($n in $nums) {
            $id = $list[$n - 1].id
            if ($Selected.Contains($id)) { [void]$Selected.Remove($id) } else { [void]$Selected.Add($id) }
        }
    }
}

function Invoke-MenuCustom {
    Import-Catalog
    $eligible = @(Select-LiteOSTweaks -Catalog $script:Catalog -Level None -Include '*' -Build $script:Context.Build)
    if ($eligible.Count -eq 0) { Write-LiteOSLog -Level Warn 'No tweaks are available for this Windows build.'; Wait-Enter; return }
    $selected = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($t in @(Select-LiteOSTweaks -Catalog $eligible -Level Balanced -Include $script:IncludeList -Exclude $script:ExcludeList)) { [void]$selected.Add($t.id) }

    $cats = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($t in $eligible) {
        $found = $false
        foreach ($c in $cats) { if ($c.Id -eq $t.category) { $found = $true; break } }
        if (-not $found) {
            $title = [string]$t.categoryTitle
            if (-not $title) { $title = [string]$t.category }
            $cats.Add([pscustomobject]@{ Id = [string]$t.category; Title = $title })
        }
    }

    while ($true) {
        Show-Header 'Custom - pick a category, then toggle tweaks'
        $i = 0
        foreach ($c in $cats) {
            $i++
            $inCat = @($eligible | Where-Object { $_.category -eq $c.Id })
            $sel = @($inCat | Where-Object { $selected.Contains($_.id) }).Count
            Write-Host ('  {0,3}  [{1,3}/{2,-3}]  {3}' -f $i, $sel, $inCat.Count, $c.Title)
        }
        Write-Host ''
        Write-Host ('  {0} of {1} tweaks selected.' -f $selected.Count, $eligible.Count) -ForegroundColor White
        Write-Host '  B = reset to Balanced   E = reset to Extreme   N = select nothing' -ForegroundColor DarkGray
        Write-Host '  R = review and apply    0 = back to the main menu' -ForegroundColor DarkGray
        $a = Read-Answer '  Category number or letter'
        if ($null -eq $a -or $a -eq '0') { return }
        if ($a -ieq 'b' -or $a -ieq 'e') {
            $selected.Clear()
            $lvl = 'Balanced'
            if ($a -ieq 'e') { $lvl = 'Extreme' }
            foreach ($t in @(Select-LiteOSTweaks -Catalog $eligible -Level $lvl -Exclude $script:ExcludeList)) { [void]$selected.Add($t.id) }
            continue
        }
        if ($a -ieq 'n') { $selected.Clear(); continue }
        if ($a -ieq 'r') {
            $chosen = @($eligible | Where-Object { $selected.Contains($_.id) })
            if ($chosen.Count -eq 0) { Write-Host '  Nothing selected.' -ForegroundColor Yellow; Wait-Enter; continue }
            $ext = @($chosen | Where-Object { $_.level -eq 'extreme' })
            Show-Header 'Custom - review'
            Show-PlanOverview $chosen
            if ($ext.Count -gt 0) {
                Show-ExtremeWarning $ext
                if (-not (Confirm-Extreme)) { Wait-Enter; continue }
            }
            elseif (-not (Confirm-YesNo 'Apply the selected tweaks now?' $true)) { continue }
            $sum = Invoke-Run -Tweaks $chosen -LevelName 'Custom'
            Invoke-PostRun $sum
            return
        }
        if ($a -match '^\d+$') {
            $n = [int]$a
            if ($n -ge 1 -and $n -le $cats.Count) {
                $c = $cats[$n - 1]
                Show-CustomCategory -Title $c.Title -Tweaks @($eligible | Where-Object { $_.category -eq $c.Id }) -Selected $selected
            }
        }
    }
}

function Show-AppsMenu {
    Show-Header 'Install gaming apps (winget)'
    if (-not (Test-Path -LiteralPath $script:AppsScript -PathType Leaf)) {
        Write-LiteOSLog -Level Warn ('App installer not found: {0}' -f $script:AppsScript)
        Wait-Enter
        return
    }
    $apps = @()
    $catalogPath = Join-Path $script:TweaksPath 'apps-install.json'
    try {
        if (Test-Path -LiteralPath $catalogPath -PathType Leaf) {
            $json = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $apps = @(Get-ObjectValue $json 'apps' @())
        }
    }
    catch { Write-LiteOSLog -Level Warn ('Could not read {0}: {1}' -f $catalogPath, $_.Exception.Message) }

    $i = 0
    foreach ($app in $apps) {
        $i++
        $mark = ' '
        if ([bool](Get-ObjectValue $app 'default' $false)) { $mark = 'x' }
        Write-Host ('  {0,3}  [{1}]  {2,-30} {3,-18} {4}' -f $i, $mark, (Get-ObjectValue $app 'name' ''), (Get-ObjectValue $app 'group' ''), (Get-ObjectValue $app 'id' '')) -ForegroundColor Gray
    }
    if ($apps.Count -eq 0) { Write-Host '  (app list not found - the installer will use its own defaults)' -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host '  D = default set (marked x)   A = all   numbers (e.g. 1 3 5-7) = pick   0 = back' -ForegroundColor DarkGray
    $a = Read-Answer '  Choose'
    if ($null -eq $a -or $a -eq '' -or $a -eq '0') { return }
    $spec = @()
    if ($a -ieq 'd') { $spec = @('default') }
    elseif ($a -ieq 'a') { $spec = @('all') }
    else {
        $nums = ConvertFrom-NumberList -Text $a -Max $apps.Count
        if ($null -eq $nums -or $nums.Length -eq 0) { Write-Host '  Nothing selected.' -ForegroundColor Yellow; Wait-Enter; return }
        $spec = @($nums | ForEach-Object { [string](Get-ObjectValue $apps[$_ - 1] 'id' '') } | Where-Object { $_ })
    }
    if ($spec.Count -eq 0) { return }
    if (-not (Confirm-YesNo ('Install {0} now?' -f ($spec -join ', ')) $true)) { return }
    Invoke-AppInstall -Spec $spec
    Wait-Enter
}

function Invoke-Revert {
    if (-not (Test-Path -LiteralPath $script:RevertScript -PathType Leaf)) {
        Write-LiteOSLog -Level Warn ('Revert-LiteOS.ps1 not found: {0}' -f $script:RevertScript)
        Wait-Enter
        return
    }
    $psExe = Join-Path $PSHOME 'powershell.exe'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:RevertScript)
    if ($DryRun) { $argList += '-DryRun' }
    Write-LiteOSLog -NoConsole 'Starting Revert-LiteOS.ps1'
    & $psExe @argList
    Wait-Enter
}

function Show-Log {
    Show-Header 'View log'
    $logs = @()
    try {
        $logs = @(Get-ChildItem -LiteralPath $script:Context.LogDir -Filter '*.log' -File -ErrorAction Stop |
                Sort-Object -Property LastWriteTime -Descending | Select-Object -First 9)
    }
    catch { $logs = @() }
    if ($logs.Count -eq 0) { Write-Host '  No logs yet.'; Wait-Enter; return }
    $i = 0
    foreach ($l in $logs) {
        $i++
        $note = ''
        if ($l.FullName -eq $script:Context.LogFile) { $note = '  (this session)' }
        Write-Host ('  {0}  {1}  {2,8:N0} KB{3}' -f $i, $l.Name, ($l.Length / 1KB), $note)
    }
    $a = Read-Answer '  Log number [1]'
    if ($null -eq $a) { return }
    $n = 1
    if ($a -match '^\d+$') { $n = [int]$a }
    if ($n -lt 1 -or $n -gt $logs.Count) { return }
    $file = $logs[$n - 1].FullName
    Write-Host ''
    Write-Host ('  --- last 40 lines of {0} ---' -f $file) -ForegroundColor DarkGray
    try {
        foreach ($line in @(Get-Content -LiteralPath $file -Tail 40 -Encoding UTF8)) {
            $color = 'Gray'
            if ($line -match '\[ERROR\]') { $color = 'Red' } elseif ($line -match '\[WARN \]') { $color = 'Yellow' } elseif ($line -match '\[OK   \]') { $color = 'Green' }
            Write-Host ('  ' + $line) -ForegroundColor $color
        }
    }
    catch { Write-Host ('  Could not read the log: {0}' -f $_.Exception.Message) -ForegroundColor Red }
    Write-Host ''
    if (Confirm-YesNo 'Open the full log in Notepad?' $false) {
        try { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $file) } catch { Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Red }
    }
}

function Show-MainMenu {
    $done = $false
    while (-not $done) {
        Show-Header
        Write-Host '   1  ' -NoNewline; Write-Host 'Balanced' -ForegroundColor Green -NoNewline
        Write-Host '   (recommended) keeps Defender, Updates, Store, Xbox/Game Pass, anti-cheat'
        Write-Host '   2  ' -NoNewline; Write-Host 'Extreme' -ForegroundColor Yellow -NoNewline
        Write-Host '    maximum debloat - shows every warning first'
        Write-Host '   3  ' -NoNewline; Write-Host 'Custom' -ForegroundColor Cyan -NoNewline
        Write-Host '     pick categories and individual tweaks'
        Write-Host '   4  Install gaming apps (winget)'
        Write-Host '   5  Revert a previous run'
        Write-Host '   6  View log'
        Write-Host '   0  Exit'
        Write-Host ''
        $c = Read-Answer '  Select an option'
        if ($null -eq $c) { $done = $true; continue }
        try {
            if ($c -eq '1') { Invoke-MenuBalanced }
            elseif ($c -eq '2') { Invoke-MenuExtreme }
            elseif ($c -eq '3') { Invoke-MenuCustom }
            elseif ($c -eq '4') { Show-AppsMenu }
            elseif ($c -eq '5') { Invoke-Revert }
            elseif ($c -eq '6') { Show-Log; Wait-Enter }
            elseif ($c -eq '0' -or $c -ieq 'q' -or $c -ieq 'exit') { $done = $true }
        }
        catch {
            Write-LiteOSLog -Level Error $_.Exception.Message
            Wait-Enter
        }
    }
}

# =============================================================================================
# Non-interactive modes
# =============================================================================================

function Invoke-NonInteractive {
    Import-Catalog
    $lvl = $Level
    if ([string]::IsNullOrEmpty($lvl)) { $lvl = 'Balanced' }
    Test-PatternUsage -Patterns $script:IncludeList -What 'Include'
    Test-PatternUsage -Patterns $script:ExcludeList -What 'Exclude'
    $tw = @(Get-LevelTweaks $lvl)
    Show-Header ('{0}{1}' -f $lvl, $(if ($Silent) { ' (silent)' } else { '' }))
    Show-PlanOverview $tw
    if ($tw.Count -eq 0) { return }
    $ext = @($tw | Where-Object { $_.level -eq 'extreme' })
    if (-not $Silent) {
        if ($ext.Count -gt 0) {
            Show-ExtremeWarning $ext
            if (-not (Confirm-Extreme)) { return }
        }
        elseif (-not (Confirm-YesNo ('Apply {0} now?' -f $lvl) $true)) {
            Write-Host '  Cancelled. Nothing was changed.' -ForegroundColor DarkGray
            return
        }
    }
    $sum = Invoke-Run -Tweaks $tw -LevelName $lvl
    if (@($script:AppsList).Count -gt 0) { Invoke-AppInstall -Spec $script:AppsList }
    if ($null -ne $sum -and $sum.Applied -gt 0 -and -not $DryRun) {
        Write-LiteOSLog 'Restart Windows to finish applying the changes.'
    }
}

function Save-FirstLogonConfig {
    param($Config)
    $path = $script:Context.ConfigPath
    $json = ConvertTo-Json -InputObject $Config -Depth 10
    [System.IO.File]::WriteAllText($path, $json, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
}

# =============================================================================================
# Lite OS image (v2): SetupComplete stage (SYSTEM, before the first sign-in)
# =============================================================================================

function Read-JsonFileOrNull {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
        if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return (ConvertFrom-Json -InputObject $raw)
    }
    catch {
        Write-LiteOSLog -Level Warn ('Could not read {0}: {1}' -f $Path, $_.Exception.Message)
        return $null
    }
}

function Write-StateJson {
    # Small state files in $env:ProgramData\LiteOS (UTF-8 without BOM, temp file + move).
    param([string]$Path, $Object)
    $json = ConvertTo-Json -InputObject $Object -Depth 10
    $tmp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
    if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Delete($Path) }
    [System.IO.File]::Move($tmp, $Path)
}

function Get-SetupCompletePath { return (Join-Path $script:Context.StateRoot 'setupcomplete.done') }

function Get-SetupCompleteState {
    # Parsed setupcomplete.done, or $null when the stage has not finished yet.
    $p = Get-SetupCompletePath
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    $s = Read-JsonFileOrNull $p
    if ($null -eq $s) { $s = [pscustomobject]@{ finished = 'unknown'; rebootRequired = $false } }
    return $s
}

function Get-CurrentBootDescription {
    # Read-only: description of this installation's boot menu entry ({current}), or $null.
    $exe = Join-Path $env:SystemRoot 'System32\bcdedit.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $null }
    $text = ''
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $text = (@(& $exe /enum '{current}' 2>&1 | ForEach-Object { [string]$_ }) -join "`r`n") }
    catch { $text = '' }
    finally { $ErrorActionPreference = $prev }
    return (Get-LiteOSBcdDescription -Text $text)
}

function Get-BrandingConfig {
    foreach ($p in $script:BrandingPaths) {
        $b = Read-JsonFileOrNull $p
        if ($null -ne $b) { Write-LiteOSLog -NoConsole ('Branding: {0}' -f $p); return $b }
    }
    return $null
}

function Get-InstallerState {
    # id -> status of baked installers run earlier ($env:ProgramData\LiteOS\installers-state.json).
    $map = @{}
    $s = Read-JsonFileOrNull (Join-Path $script:Context.StateRoot 'installers-state.json')
    if ($null -ne $s) {
        foreach ($p in $s.PSObject.Properties) { $map[$p.Name] = $p.Value }
    }
    return $map
}

function Save-InstallerState {
    param([hashtable]$Map)
    try {
        $o = [ordered]@{}
        foreach ($k in @($Map.Keys | Sort-Object)) { $o[[string]$k] = $Map[$k] }
        Write-StateJson -Path (Join-Path $script:Context.StateRoot 'installers-state.json') -Object $o
    }
    catch { Write-LiteOSLog -Level Warn ('Could not save the installer state: {0}' -f $_.Exception.Message) }
}

function Stop-ProcessTree {
    param([int]$ProcessId)
    $exe = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $null = & $exe /PID $ProcessId /T /F 2>&1 }
    catch { $null = $_ }
    finally { $ErrorActionPreference = $prev }
}

function Start-InstallerProcess {
    param($Step)
    $file = [string]$Step.File
    $argText = [string]$Step.Arguments
    if ($Step.Kind -eq 'msi') {
        $msi = Join-Path $env:SystemRoot 'System32\msiexec.exe'
        $a = '/i "{0}"' -f $file
        if ($argText) { $a += (' ' + $argText) }
        if ($a -notmatch '(?i)(^|\s)/q') { $a += ' /qn' }
        if ($a -notmatch '(?i)/norestart') { $a += ' /norestart' }
        return (Start-Process -FilePath $msi -ArgumentList $a -PassThru -WindowStyle Hidden)
    }
    $wd = Split-Path -Parent $file
    if ($argText) { return (Start-Process -FilePath $file -ArgumentList $argText -WorkingDirectory $wd -PassThru -WindowStyle Hidden) }
    return (Start-Process -FilePath $file -WorkingDirectory $wd -PassThru -WindowStyle Hidden)
}

function Invoke-InstallerJob {
    # Runs one baked installer (all its steps). Never throws; returns {id, name, status, exitCode, reboot, message, seconds}.
    param($Job)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res = [ordered]@{ id = $Job.Id; name = $Job.Name; status = 'ok'; exitCode = $null; reboot = $false; message = ''; seconds = 0; time = (Get-Date).ToString('s') }
    $steps = @($Job.Steps)
    $usesExtract = ($steps.Count -gt 1)
    foreach ($s in $steps) { if ([string]$s.Arguments -and ([string]$s.Arguments).IndexOf([string]$Job.ExtractDir, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $usesExtract = $true } }
    Write-LiteOSLog ('Installing {0} ...' -f $Job.Name)
    try {
        if ($usesExtract) {
            if (Test-Path -LiteralPath $Job.ExtractDir) { Remove-Item -LiteralPath $Job.ExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
            $null = New-Item -ItemType Directory -Path $Job.ExtractDir -Force
        }
        $n = 0
        foreach ($s in $steps) {
            $n++
            $leaf = [System.IO.Path]::GetFileName([string]$s.File)
            if (-not (Test-Path -LiteralPath $s.File -PathType Leaf)) {
                $res.status = 'missing'
                $res.message = ('{0} not found' -f $s.File)
                break
            }
            $sig = Get-AuthenticodeSignature -FilePath $s.File
            $subject = ''
            if ($null -ne $sig.SignerCertificate) { $subject = [string]$sig.SignerCertificate.Subject }
            $v = Get-LiteOSSignatureVerdict -Status ([string]$sig.Status) -Subject $subject -Publisher $Job.Publisher
            if (-not $v.Allowed) {
                $res.status = 'refused'
                $res.message = ('{0}: {1}' -f $leaf, $v.Message)
                break
            }
            if ($v.Warning) { Write-LiteOSLog -Level Warn ('{0}: {1}' -f $leaf, $v.Message) }
            else { Write-LiteOSLog -NoConsole ('{0}: {1}' -f $leaf, $v.Message) }
            Write-LiteOSLog -NoConsole ('Step {0}/{1}: "{2}" {3}' -f $n, $steps.Count, $s.File, $s.Arguments)
            $p = Start-InstallerProcess -Step $s
            $null = $p.Handle  # keeps the handle so ExitCode is available after the process ends
            if (-not $p.WaitForExit([int]$Job.TimeoutSeconds * 1000)) {
                Stop-ProcessTree -ProcessId $p.Id
                $res.status = 'timeout'
                $res.message = ('{0} did not finish within {1} minutes and was stopped' -f $leaf, [int]($Job.TimeoutSeconds / 60))
                break
            }
            $p.WaitForExit()
            $code = [int]$p.ExitCode
            $res.exitCode = $code
            $ev = Get-LiteOSExitCodeVerdict -ExitCode $code -SuccessCodes $Job.SuccessCodes
            if (-not $ev.Ok) {
                $res.status = 'failed'
                $res.message = ('{0}: {1}' -f $leaf, $ev.Message)
                break
            }
            if ($ev.Reboot) { $res.reboot = $true }
            $res.message = ('{0}: {1}' -f $leaf, $ev.Message)
        }
    }
    catch {
        $res.status = 'failed'
        $res.message = $_.Exception.Message
    }
    finally {
        if ($usesExtract) { Remove-Item -LiteralPath $Job.ExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $res.seconds = [int]$sw.Elapsed.TotalSeconds
    if ($res.status -eq 'ok') { Write-LiteOSLog -Level Success ('{0} installed ({1}, {2} s)' -f $Job.Name, $res.message, $res.seconds) }
    else { Write-LiteOSLog -Level Error ('{0} was not installed: {1} [{2}]' -f $Job.Name, $res.message, $res.status) }
    return [pscustomobject]$res
}

function Invoke-BakedInstallers {
    # C:\LiteOS\installers\installers.json (written by the builder) -> run each installer in order.
    $out = [pscustomobject]@{ Items = @(); Reboot = $false; Failed = 0 }
    if (-not (Test-Path -LiteralPath $script:InstallersManifest -PathType Leaf)) {
        Write-LiteOSLog ('No baked installers ({0} not found).' -f $script:InstallersManifest)
        return $out
    }
    $man = Read-JsonFileOrNull $script:InstallersManifest
    if ($null -eq $man) { $out.Failed = 1; return $out }
    $jobs = @(Get-LiteOSInstallerJobs -Manifest $man -Directory $script:InstallersDir)
    Write-LiteOSLog ('Baked installers: {0}' -f (($jobs | ForEach-Object { $_.Name }) -join ', '))
    $state = Get-InstallerState
    $items = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $i = 0
    foreach ($j in $jobs) {
        $i++
        if ($null -ne $j.Error) {
            Write-LiteOSLog -Level Error ('Installer {0} skipped: {1}' -f $j.Id, $j.Error)
            $items.Add([pscustomobject]@{ id = $j.Id; name = $j.Name; status = 'invalid'; exitCode = $null; reboot = $false; message = $j.Error })
            $out.Failed++
            continue
        }
        $prevRun = $null
        if ($state.ContainsKey($j.Id)) { $prevRun = $state[$j.Id] }
        if ($null -ne $prevRun -and [string](Get-ObjectValue $prevRun 'status' '') -eq 'ok') {
            Write-LiteOSLog ('{0} was already installed by an earlier run.' -f $j.Name)
            $items.Add($prevRun)
            continue
        }
        if ($DryRun) {
            Write-LiteOSLog ('Dry run: would install {0} ({1} step(s), timeout {2} min).' -f $j.Name, @($j.Steps).Count, [int]($j.TimeoutSeconds / 60))
            continue
        }
        Write-Host ('  [{0}/{1}] ' -f $i, $jobs.Count) -NoNewline
        $r = Invoke-InstallerJob -Job $j
        $items.Add($r)
        if ($r.status -ne 'ok') { $out.Failed++ }
        if ($r.reboot) { $out.Reboot = $true }
        $state[$j.Id] = $r
        Save-InstallerState $state
    }
    $out.Items = $items.ToArray()
    return $out
}

function Remove-InstalledBakedInstallers {
    # After the SetupComplete stage: delete the installer files (C:\LiteOS\installers\*.exe / .msi,
    # about 200 MB) whose installer finished with status 'ok'. installers.json and
    # installers-state.json stay, so the log keeps the details and a re-run skips them cleanly.
    # Failed / missing ones stay for a manual retry. Never throws.
    if (-not (Test-Path -LiteralPath $script:InstallersManifest -PathType Leaf)) { return }
    try {
        $man = Read-JsonFileOrNull $script:InstallersManifest
        if ($null -eq $man) { return }
        $state = Get-InstallerState
        $dir = ([System.IO.Path]::GetFullPath($script:InstallersDir)).TrimEnd('\') + '\'
        $freed = [int64]0
        $n = 0
        foreach ($j in @(Get-LiteOSInstallerJobs -Manifest $man -Directory $script:InstallersDir)) {
            if ($null -ne $j.Error -or -not $state.ContainsKey($j.Id)) { continue }
            if ([string](Get-ObjectValue $state[$j.Id] 'status' '') -ne 'ok') { continue }
            $steps = @($j.Steps)
            if ($steps.Count -eq 0) { continue }
            $file = [string]$steps[0].File
            if (-not $file -or -not $file.StartsWith($dir, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($file.Substring($dir.Length).IndexOf('\') -ge 0) { continue }
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
            try {
                $len = (Get-Item -LiteralPath $file).Length
                Remove-Item -LiteralPath $file -Force -ErrorAction Stop
                $freed += $len
                $n++
                Write-LiteOSLog -NoConsole ('Deleted the installed setup file {0}.' -f $file)
            }
            catch { Write-LiteOSLog -Level Warn ('Could not delete {0}: {1}' -f $file, $_.Exception.Message) }
        }
        if ($n -gt 0) { Write-LiteOSLog ('Removed {0} installed setup file(s) from {1} ({2:N0} MB freed).' -f $n, $script:InstallersDir, ($freed / 1MB)) }
    }
    catch { Write-LiteOSLog -Level Warn ('Could not clean up the baked installers: {0}' -f $_.Exception.Message) }
}

function Invoke-SetupCompleteStage {
    # Runs as SYSTEM from SetupComplete.cmd (or from -FirstLogon when Windows skipped SetupComplete).
    # No prompts, never restarts. Returns the state written to setupcomplete.done.
    param([string]$From = 'SetupComplete')
    $c = $script:Context
    $donePath = Get-SetupCompletePath
    $existing = Get-SetupCompleteState
    if ($null -ne $existing) {
        Write-LiteOSLog ('The SetupComplete stage already finished ({0}); nothing to do.' -f (Get-ObjectValue $existing 'finished' 'earlier'))
        return $existing
    }
    $imageBackup = Join-Path $c.BackupDir 'backup-image.json'
    Write-LiteOSLog ('Lite OS SetupComplete stage (started from {0}, running as {1}).' -f $From, $c.UserName)
    $errors = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $reboot = $false
    $counts = [ordered]@{ applied = 0; skipped = 0; failed = 0; total = 0 }
    $bootName = $null

    # Image files are owned by the account that ran the builder on another PC; adopt them now (nothing
    # but the builder can have written them before the first sign-in), so the owner checks pass.
    if (-not $DryRun) {
        try { $null = Set-LiteOSImageFileOwner -Path @($imageBackup, $script:DeferredPath) -Confirm:$false }
        catch { Write-LiteOSLog -Level Warn ('Could not check the owner of the image files: {0}' -f $_.Exception.Message) }
    }

    # 1. Machine actions that could not be baked offline + the boot menu name, appended to the image backup.
    $tweaks = New-Object -TypeName 'System.Collections.Generic.List[object]'
    try {
        foreach ($t in @(Read-LiteOSDeferred -Path $script:DeferredPath -Scope Machine)) { $tweaks.Add($t) }
        Write-LiteOSLog ('Deferred machine settings: {0} tweak(s).' -f $tweaks.Count)
    }
    catch {
        $errors.Add(('deferred.json: {0}' -f $_.Exception.Message))
        Write-LiteOSLog -Level Error ('Could not read the deferred settings: {0}' -f $_.Exception.Message)
    }
    try {
        $bootName = Get-LiteOSBootDescription -Branding (Get-BrandingConfig)
        if ($bootName) { $tweaks.Add((New-LiteOSBootDescriptionTweak -Description $bootName -Previous (Get-CurrentBootDescription))) }
        else { Write-LiteOSLog 'No boot menu name in branding.json; the boot menu entry keeps its name.' }
    }
    catch {
        $errors.Add(('boot menu name: {0}' -f $_.Exception.Message))
        Write-LiteOSLog -Level Warn ('Could not prepare the boot menu name: {0}' -f $_.Exception.Message)
    }
    if ($tweaks.Count -gt 0) {
        try {
            $c.Level = 'image'
            $results = @(Invoke-LiteOSPlan -Tweaks $tweaks.ToArray() -Context $c -BackupPath $imageBackup -BackupSource 'image')
            $sum = Write-LiteOSSummary -Results $results -Context $c
            $counts.applied = $sum.Applied
            $counts.skipped = $sum.Skipped
            $counts.failed = $sum.Failed
            $counts.total = $sum.Total
            if (@($results | Where-Object { $_.reboot }).Count -gt 0) { $reboot = $true }
            foreach ($r in @($results | Where-Object { $_.status -eq 'failed' })) { $errors.Add(('{0}: {1}' -f $r.id, $r.message)) }
        }
        catch {
            $errors.Add(('deferred settings: {0}' -f $_.Exception.Message))
            Write-LiteOSLog -Level Error ('Applying the deferred settings failed: {0}' -f $_.Exception.Message)
        }
    }

    # 2. Baked installers (Steam, VC++, DirectX, .NET ...): silent, one at a time, never fatal.
    $inst = $null
    try {
        $inst = Invoke-BakedInstallers
        if ($inst.Reboot) { $reboot = $true }
        foreach ($x in @($inst.Items | Where-Object { [string](Get-ObjectValue $_ 'status' '') -ne 'ok' })) {
            $errors.Add(('installer {0}: {1}' -f (Get-ObjectValue $x 'id' '?'), (Get-ObjectValue $x 'message' '')))
        }
    }
    catch {
        $errors.Add(('installers: {0}' -f $_.Exception.Message))
        Write-LiteOSLog -Level Error ('Running the baked installers failed: {0}' -f $_.Exception.Message)
    }

    $state = [pscustomobject]([ordered]@{
            version         = 1
            finished        = (Get-Date).ToString('s')
            ranFrom         = $From
            deferred        = $counts
            bootDescription = $bootName
            installers      = $(if ($null -ne $inst) { @($inst.Items) } else { @() })
            rebootRequired  = $reboot
            errors          = $errors.ToArray()
            log             = $c.LogFile
        })
    if ($DryRun) {
        Write-LiteOSLog 'Dry run: setupcomplete.done not written.'
    }
    else {
        $doneWritten = $false
        try { Write-StateJson -Path $donePath -Object $state; Write-LiteOSLog -NoConsole ('Wrote {0}' -f $donePath); $doneWritten = $true }
        catch { Write-LiteOSLog -Level Error ('Could not write {0}: {1}' -f $donePath, $_.Exception.Message) }
        if ($doneWritten) { Remove-InstalledBakedInstallers }
    }
    if ($errors.Count -gt 0) {
        if ($script:ExitCode -eq 0) { $script:ExitCode = 2 }
        Write-LiteOSLog -Level Warn ('SetupComplete stage finished with {0} problem(s); see {1}' -f $errors.Count, $c.LogFile)
    }
    else { Write-LiteOSLog -Level Success 'SetupComplete stage finished.' }
    if ($reboot) { Write-LiteOSLog 'A restart is needed to finish; the first-logon step will schedule it.' }
    return $state
}

function Invoke-ImageFirstLogon {
    # First logon on a Lite OS image: tweaks are already in the image. Returns $true when a restart is needed.
    param([string[]]$AppSpec)
    $reboot = $false
    Show-Header 'First-logon setup - Lite OS'
    Write-Host '  Lite OS is finishing the setup of Windows. Please wait, this window closes by itself.' -ForegroundColor Cyan
    Write-Host ''
    $sc = Get-SetupCompleteState
    if ($null -eq $sc) {
        Write-LiteOSLog 'SetupComplete did not run before this sign-in (Windows skips it with some OEM product keys); running that stage now.'
        try { $sc = Invoke-SetupCompleteStage -From 'FirstLogon' }
        catch {
            $script:ExitCode = 2
            Write-LiteOSLog -Level Error ('SetupComplete stage failed: {0}' -f $_.Exception.Message)
        }
    }
    if ($null -ne $sc -and (Test-Truthy (Get-ObjectValue $sc 'rebootRequired' $false))) { $reboot = $true }

    # Per-user settings that cannot live in the Default profile (HKCU:\Software\Classes = UsrClass.dat)
    # or could not be baked offline: apply them to the signed-in user (normal backup, revertable).
    try {
        $tw = @(Read-LiteOSDeferred -Path $script:DeferredPath -Scope User)
        if ($tw.Count -gt 0) {
            Write-LiteOSLog ('Applying {0} per-user setting(s) for {1} ...' -f $tw.Count, $script:Context.UserName)
            $script:Context.Level = 'image-user'
            $results = @(Invoke-LiteOSPlan -Tweaks $tw -Context $script:Context)
            $sum = Write-LiteOSSummary -Results $results -Context $script:Context
            if ($sum.Failed -gt 0 -and $script:ExitCode -eq 0) { $script:ExitCode = 2 }
            if (@($results | Where-Object { $_.reboot }).Count -gt 0) { $reboot = $true }
        }
        else { Write-LiteOSLog -NoConsole 'No per-user settings were deferred to first logon.' }
    }
    catch {
        if ($script:ExitCode -eq 0) { $script:ExitCode = 2 }
        Write-LiteOSLog -Level Error ('Per-user settings failed: {0}' -f $_.Exception.Message)
    }

    $apps = @($AppSpec | Where-Object { $_ -and $_ -ne 'none' })
    if ($apps.Count -gt 0 -and -not $SkipApps) {
        Write-Host ''
        Invoke-AppInstall -Spec $apps -WaitForNetwork
    }
    return $reboot
}

function Test-Truthy {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    return ([string]$Value -match '^(?i)(true|1|yes)$')
}

function Invoke-FirstLogon {
    $cfgPath = $script:Context.ConfigPath
    $cfg = $null
    if (Test-Path -LiteralPath $cfgPath -PathType Leaf) {
        try { $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { Write-LiteOSLog -Level Warn ('Could not read {0}: {1}. Using Balanced.' -f $cfgPath, $_.Exception.Message) }
    }
    else {
        Write-LiteOSLog -Level Warn ('{0} not found. Using Balanced.' -f $cfgPath)
    }
    if ($null -eq $cfg) { $cfg = New-Object -TypeName PSObject }

    # Never run twice: "started" is written before any change, so even a crash or power loss
    # mid-run does not cause a second automatic run.
    if ([bool](Get-ObjectValue $cfg 'firstLogonDone' $false) -or $null -ne (Get-ObjectValue $cfg 'firstLogonStarted' $null)) {
        Write-LiteOSLog ('Lite OS first-logon setup already ran ({0}). Nothing to do. Use Start-LiteOS.cmd to change settings.' -f (Get-ObjectValue $cfg 'firstLogonStarted' 'earlier'))
        return
    }

    if (-not $DryRun) {
        $cfg | Add-Member -NotePropertyName firstLogonStarted -NotePropertyValue ((Get-Date).ToString('s')) -Force
        try { Save-FirstLogonConfig $cfg } catch { Write-LiteOSLog -Level Warn ('Could not update {0}: {1}' -f $cfgPath, $_.Exception.Message) }
    }

    $kind = Get-LiteOSInstallKind -PayloadRoot $script:Root -StateRoot $script:Context.StateRoot -Config $cfg
    if ($kind -eq 'image') {
        # Lite OS image (v2): everything else is baked in; only finish what needs the running system.
        $appSpecImg = $script:AppsList
        if ($appSpecImg.Length -eq 0) { $appSpecImg = Split-ArgList (Get-ObjectValue $cfg 'apps' @()) }
        Write-LiteOSLog ('First-logon setup (Lite OS image): mode [{0}], apps [{1}]' -f (Get-ObjectValue $cfg 'mode' ''), ($appSpecImg -join ','))
        $needReboot = $false
        try { $needReboot = Invoke-ImageFirstLogon -AppSpec $appSpecImg }
        catch {
            $script:ExitCode = 1
            Write-LiteOSLog -Level Error ('First-logon setup failed: {0}' -f $_.Exception.Message)
        }
        if ($script:Context.RebootRequired) { $needReboot = $true }
        if (-not $DryRun) {
            $cfg | Add-Member -NotePropertyName firstLogonDone -NotePropertyValue $true -Force
            $cfg | Add-Member -NotePropertyName firstLogonFinished -NotePropertyValue ((Get-Date).ToString('s')) -Force
            try { Save-FirstLogonConfig $cfg } catch { Write-LiteOSLog -Level Warn ('Could not update {0}: {1}' -f $cfgPath, $_.Exception.Message) }
        }
        if ($script:ExitCode -ne 0) {
            Write-LiteOSLog -Level Warn ('Some steps did not finish. See the log: {0}. You can run C:\LiteOS\Start-LiteOS.cmd later.' -f $script:Context.LogFile)
        }
        Write-Host ''
        if ($needReboot) {
            Invoke-Reboot -Seconds 60 -Message 'Lite OS finished setting up Windows. Your PC restarts in 60 seconds to apply the last settings. Save your work now.'
            Start-Sleep -Seconds 10
        }
        else {
            Write-LiteOSLog -Level Success 'Lite OS is ready. No restart needed.'
            Start-Sleep -Seconds 5
        }
        return
    }

    # Settings: command line wins over config.json.
    $lvl = $Level
    if ([string]::IsNullOrEmpty($lvl)) { $lvl = ConvertTo-LevelName (Get-ObjectValue $cfg 'level' 'Balanced') }
    if ([string]::IsNullOrEmpty($lvl)) {
        Write-LiteOSLog -Level Warn ("Unknown level '{0}' in config.json; using Balanced." -f (Get-ObjectValue $cfg 'level' ''))
        $lvl = 'Balanced'
    }
    if ($script:IncludeList.Length -eq 0) { $script:IncludeList = Split-ArgList (Get-ObjectValue $cfg 'include' @()) }
    if ($script:ExcludeList.Length -eq 0) { $script:ExcludeList = Split-ArgList (Get-ObjectValue $cfg 'exclude' @()) }
    $appSpec = $script:AppsList
    if ($appSpec.Length -eq 0) { $appSpec = Split-ArgList (Get-ObjectValue $cfg 'apps' @()) }
    if ([bool](Get-ObjectValue $cfg 'skipRestorePoint' $false)) { $script:NoRestorePoint = $true }

    Show-Header ('First-logon setup - {0}' -f $lvl)
    Write-LiteOSLog ('First-logon setup: level {0}, include [{1}], exclude [{2}], apps [{3}]' -f $lvl, ($script:IncludeList -join ','), ($script:ExcludeList -join ','), ($appSpec -join ','))
    Write-Host '  Lite OS is finishing the setup of Windows. Please wait, this window closes by itself.' -ForegroundColor Cyan
    Write-Host ''

    $summary = $null
    try {
        Import-Catalog
        Test-PatternUsage -Patterns $script:IncludeList -What 'Include'
        Test-PatternUsage -Patterns $script:ExcludeList -What 'Exclude'
        $tw = @(Select-LiteOSTweaks -Catalog $script:Catalog -Level $lvl -Include $script:IncludeList -Exclude $script:ExcludeList -Build $script:Context.Build)
        $summary = Invoke-Run -Tweaks $tw -LevelName $lvl
    }
    catch {
        $script:ExitCode = 1
        Write-LiteOSLog -Level Error ('First-logon tweaks failed: {0}' -f $_.Exception.Message)
    }

    $apps = @($appSpec | Where-Object { $_ -and $_ -ne 'none' })
    if ($apps.Count -gt 0 -and -not $SkipApps) {
        Write-Host ''
        Invoke-AppInstall -Spec $apps -WaitForNetwork
    }

    if (-not $DryRun) {
        $cfg | Add-Member -NotePropertyName firstLogonDone -NotePropertyValue $true -Force
        $cfg | Add-Member -NotePropertyName firstLogonFinished -NotePropertyValue ((Get-Date).ToString('s')) -Force
        try { Save-FirstLogonConfig $cfg } catch { Write-LiteOSLog -Level Warn ('Could not update {0}: {1}' -f $cfgPath, $_.Exception.Message) }
    }

    if ($script:ExitCode -eq 1 -and $null -eq $summary) {
        Write-LiteOSLog -Level Warn ('Setup did not finish. See the log: {0}. You can run C:\LiteOS\Start-LiteOS.cmd later.' -f $script:Context.LogFile)
        Start-Sleep -Seconds 30
        return
    }
    Write-Host ''
    Invoke-Reboot -Seconds 60 -Message 'Lite OS finished setting up Windows. Your PC restarts in 60 seconds to apply all changes. Save your work now.'
    Start-Sleep -Seconds 10
}

# =============================================================================================
# Main
# =============================================================================================

$script:IncludeList = Split-ArgList $Include
$script:ExcludeList = Split-ArgList $Exclude
$script:AppsList = Split-ArgList $Apps
$mutex = $null
$haveMutex = $false

try {
    if (-not (Test-Path -LiteralPath $script:EnginePath -PathType Leaf)) {
        throw ('Engine not found: {0}. Extract the complete Lite OS folder (src\ and tweaks\ next to LiteOS.ps1).' -f $script:EnginePath)
    }
    Import-Module -Name $script:EnginePath -Force -DisableNameChecking

    $isAdmin = Test-LiteOSAdmin
    if (-not $isAdmin -and -not $DryRun) {
        Show-AdminHelp
        $script:ExitCode = 1
    }
    else {
        try {
            $mutex = New-Object -TypeName System.Threading.Mutex -ArgumentList $false, 'Global\LiteOS.Playbook'
            $haveMutex = $mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] { $haveMutex = $true }
        catch { $haveMutex = $true }
        if (-not $haveMutex) {
            Write-Host '  Another Lite OS window is already running. Close it first.' -ForegroundColor Yellow
            $script:ExitCode = 1
        }
        else {
            $logName = 'liteos'
            if ($SetupComplete) { $logName = 'setupcomplete' }
            elseif ($FirstLogon) { $logName = 'firstlogon' }
            $script:Context = Initialize-LiteOS -DryRun:$DryRun -Level ([string]$Level) -LogName $logName
            Write-LiteOSLog -NoConsole ('LiteOS.ps1 started: Level={0} Include=[{1}] Exclude=[{2}] Silent={3} DryRun={4} SkipRestorePoint={5} SkipApps={6} Apps=[{7}] FirstLogon={8} SetupComplete={9}' -f $Level, ($script:IncludeList -join ','), ($script:ExcludeList -join ','), [bool]$Silent, [bool]$DryRun, [bool]$SkipRestorePoint, [bool]$SkipApps, ($script:AppsList -join ','), [bool]$FirstLogon, [bool]$SetupComplete)
            if (-not $isAdmin) { Write-LiteOSLog -Level Warn 'Not running as administrator: dry run only, some information (like installed apps) cannot be read.' }
            if (-not (Test-TargetUser)) {
                Write-Host '  Cancelled. Nothing was changed.' -ForegroundColor DarkGray
            }
            elseif ($SetupComplete) { $null = Invoke-SetupCompleteStage -From 'SetupComplete' }
            elseif ($FirstLogon) { Invoke-FirstLogon }
            elseif ($Silent -or -not [string]::IsNullOrEmpty($Level)) { Invoke-NonInteractive }
            else { Show-MainMenu }
        }
    }
}
catch {
    $script:ExitCode = 1
    Write-Host ''
    Write-Host ('  Lite OS stopped because of an error: {0}' -f $_.Exception.Message) -ForegroundColor Red
    try { Write-LiteOSLog -NoConsole -Level Error ('FATAL: {0} {1}' -f $_.Exception.Message, $_.InvocationInfo.PositionMessage) } catch { $null = $_ }
    if ($FirstLogon -and -not $SetupComplete) { Start-Sleep -Seconds 30 }
}
finally {
    if ($null -ne $mutex) {
        if ($haveMutex) { try { $mutex.ReleaseMutex() } catch { $null = $_ } }
        $mutex.Dispose()
    }
}
exit $script:ExitCode

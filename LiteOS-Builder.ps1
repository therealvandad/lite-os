<#
.SYNOPSIS
    Lite OS Builder - one-click GUI that turns the official Windows 11 ISO from Microsoft into Lite OS.

.DESCRIPTION
    Step 1 Source : download Windows 11 from Microsoft (builder\Get-WindowsIso.ps1) or use your own ISO.
    Step 2 Options: mode Lite / Core, edition, baked-in installers, first-logon apps, tweaks and image
                    removals, setup toggles, output folder.
    Step 3 Build  : runs builder\Build-LiteOS.ps1 in a child powershell.exe (-Yes -ProgressProtocol) and
                    shows its ##LITEOS-PROGRESS / ##LITEOS-RESULT protocol as a progress bar + live log.
                    The window never freezes; Cancel asks the builder to stop (Ctrl+C, so its own cleanup
                    runs); Force stop kills the process tree; "Cleanup leftovers" undoes what a killed
                    builder may have left (only when you click it).

    Start it with LiteOS-Builder.cmd (asks for administrator rights). Needs Windows PowerShell 5.1 in STA
    mode; the script restarts itself elevated / in STA when needed.

    Lite OS uses your official Windows from Microsoft and never ships Windows files, product keys or
    activators: activate Windows with your own license. The builder never writes to USB drives; flash
    the ISO with Rufus (https://rufus.ie) or a similar tool.

.PARAMETER IsoPath
    Preselect "Use my Windows 11 ISO" with this file.

.PARAMETER Mode
    Preselect Lite (default) or Core.

.PARAMETER OutputFolder
    Preselect the folder for the Lite OS ISO (default: your Downloads folder).

.NOTES
    Lite OS. Windows PowerShell 5.1 compatible, ASCII only. Binding contract: docs\ARCHITECTURE.md.
#>
[CmdletBinding()]
param(
    [string]$IsoPath,

    [ValidateSet('Lite', 'Core')]
    [string]$Mode = 'Lite',

    [string]$OutputFolder
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# =============================================================================================
# Constants
# =============================================================================================
$script:GuiVersion   = '2.0.0'
$script:Root         = $PSScriptRoot
if ([string]::IsNullOrEmpty($script:Root)) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:Paths = @{
    Build       = (Join-Path $script:Root 'builder\Build-LiteOS.ps1')
    GetIso      = (Join-Path $script:Root 'builder\Get-WindowsIso.ps1')
    Engine      = (Join-Path $script:Root 'src\LiteOS.Engine.psm1')
    Image       = (Join-Path $script:Root 'builder\LiteOS.Image.psm1')
    Tweaks      = (Join-Path $script:Root 'tweaks')
    AppsInstall = (Join-Path $script:Root 'tweaks\apps-install.json')
    Removals    = (Join-Path $script:Root 'image\removals.json')
    Installers  = (Join-Path $script:Root 'image\installers.json')
    Branding    = (Join-Path $script:Root 'image\branding.json')
}
$script:MsDownloadPage  = 'https://www.microsoft.com/software-download/windows11'
$script:RufusUrl        = 'https://rufus.ie/'
$script:BitsDisplayName = 'LiteOS-WindowsIso'
# Same thresholds as builder\Build-LiteOS.ps1 (it refuses to start with less than 30 GB free on the
# work drive); the ISO download (about 8 GB) comes on top when it lands on the same drive.
$script:WorkNeededBytes = [int64]30GB
$script:IsoNeededBytes  = [int64]8GB
$script:OutputNeededBytes = [int64]7GB
$script:DownloadShare   = 30

# Languages Microsoft offers for the Windows 11 ISO (names as on microsoft.com, en-US).
$script:IsoLanguages = @(
    'English (United States)', 'English International', 'Arabic', 'Brazilian Portuguese', 'Bulgarian',
    'Chinese Simplified', 'Chinese Traditional', 'Croatian', 'Czech', 'Danish', 'Dutch', 'Estonian',
    'Finnish', 'French', 'French Canadian', 'German', 'Greek', 'Hebrew', 'Hungarian', 'Italian', 'Japanese',
    'Korean', 'Latvian', 'Lithuanian', 'Norwegian', 'Polish', 'Portuguese', 'Romanian', 'Russian',
    'Serbian Latin', 'Slovak', 'Slovenian', 'Spanish', 'Spanish (Mexico)', 'Swedish', 'Thai', 'Turkish',
    'Ukrainian'
)

# Image names inside Microsoft's multi-edition ISO (the builder checks the one you pick).
$script:Editions = @(
    'Windows 11 Pro', 'Windows 11 Home', 'Windows 11 Education', 'Windows 11 Pro Education',
    'Windows 11 Pro for Workstations', 'Windows 11 Home Single Language', 'Windows 11 Pro N',
    'Windows 11 Home N', 'Windows 11 Education N', 'Windows 11 Pro Education N', 'Windows 11 Pro N for Workstations'
)

# =============================================================================================
# Small helpers (no UI)
# =============================================================================================
function ConvertTo-GuiArg {
    # Quotes one argument for a Windows command line (CommandLineToArgvW rules).
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq [char]'\') { $slashes++; continue }
        if ($ch -eq [char]'"') {
            [void]$sb.Append([char]'\', (2 * $slashes + 1))
            [void]$sb.Append([char]'"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$sb.Append([char]'\', $slashes); $slashes = 0 }
        [void]$sb.Append($ch)
    }
    if ($slashes -gt 0) { [void]$sb.Append([char]'\', (2 * $slashes)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Join-GuiArgs {
    param([string[]]$Arguments)
    return ((@($Arguments) | ForEach-Object { ConvertTo-GuiArg $_ }) -join ' ')
}

function ConvertTo-GuiPsLiteral {
    # Single-quoted PowerShell string literal.
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    return ("'" + $Value.Replace("'", "''") + "'")
}

function Get-GuiPowerShellExe {
    $root = $env:SystemRoot
    if ([string]::IsNullOrEmpty($root)) { $root = 'C:\Windows' }
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $native = Join-Path $root 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $native) { return $native }
    }
    $sys = Join-Path $root 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $sys) { return $sys }
    return 'powershell.exe'
}

function Test-GuiAdmin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object System.Security.Principal.WindowsPrincipal -ArgumentList $id
        return [bool]$p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Get-GuiProp {
    # StrictMode-safe property read (PSCustomObject from ConvertFrom-Json, or a dictionary).
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function ConvertTo-GuiBool {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    return ([string]$Value -match '^(?i)(true|1|yes)$')
}

function Read-GuiJson {
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding -ArgumentList $false))
    if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return (ConvertFrom-Json -InputObject $raw)
}

function New-GuiIdSet {
    param([object[]]$Items)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($i in @($Items)) {
        if ($null -eq $i) { continue }
        $id = [string](Get-GuiProp $i 'id' '')
        if ($id) { [void]$set.Add($id) }
    }
    return , $set
}

function Format-GuiBytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function Format-GuiDuration {
    param([TimeSpan]$Span)
    if ($Span.TotalHours -ge 1) { return ('{0}:{1:00}:{2:00}' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds) }
    return ('{0:00}:{1:00}' -f $Span.Minutes, $Span.Seconds)
}

function Get-GuiDownloadsFolder {
    try {
        $p = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop
        $v = Get-GuiProp $p '{374DE290-123F-4565-9164-39C4925E467B}'
        if ($v) {
            $x = [Environment]::ExpandEnvironmentVariables([string]$v)
            if ([System.IO.Directory]::Exists($x)) { return $x }
        }
    }
    catch { $null = $_ }
    $d = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
    if ([System.IO.Directory]::Exists($d)) { return $d }
    return [Environment]::GetFolderPath('Desktop')
}

function Get-GuiFreeBytes {
    param([string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return [int64]-1 }
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
        if ([string]::IsNullOrEmpty($root) -or $root.StartsWith('\\')) { return [int64]-1 }
        $di = New-Object System.IO.DriveInfo -ArgumentList $root
        if (-not $di.IsReady) { return [int64]-1 }
        return [int64]$di.AvailableFreeSpace
    }
    catch { return [int64]-1 }
}

function Get-GuiDefaultWorkDir {
    $sd = $env:SystemDrive
    if ([string]::IsNullOrEmpty($sd)) { $sd = 'C:' }
    return ($sd + '\LiteOS-Build')
}

function Test-GuiIsoFile {
    # Quick check without mounting: size, ISO 9660 / UDF volume descriptors, volume label, not ARM64.
    # Same rules as builder\Get-WindowsIso.ps1 (Test-WindowsIsoFile); Build-LiteOS.ps1 does the full check.
    param([string]$Path)
    $r = @{ Valid = $false; Text = ''; Label = ''; Size = [int64]0 }
    if ([string]::IsNullOrWhiteSpace($Path)) { $r.Text = 'Choose the Windows 11 ISO file.'; return $r }
    if (-not [System.IO.File]::Exists($Path)) { $r.Text = 'File not found.'; return $r }
    $fi = New-Object System.IO.FileInfo -ArgumentList $Path
    $r.Size = [int64]$fi.Length
    if ($fi.Length -lt 3GB) { $r.Text = ('This file is only {0}; a Windows 11 ISO is 5 GB or more.' -f (Format-GuiBytes $fi.Length)); return $r }
    $buf = New-Object byte[] (2048 * 32)
    $read = 0
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        [void]$fs.Seek(16 * 2048, [System.IO.SeekOrigin]::Begin)
        while ($read -lt $buf.Length) {
            $n = $fs.Read($buf, $read, $buf.Length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
    }
    catch { $r.Text = ('Cannot read the file: {0}' -f $_.Exception.Message); return $r }
    finally { if ($null -ne $fs) { $fs.Dispose() } }
    $ascii = [System.Text.Encoding]::ASCII
    $udf = $false
    $iso = $false
    for ($i = 0; $i -lt [int][math]::Floor($read / 2048); $i++) {
        $off = $i * 2048
        $id = $ascii.GetString($buf, $off + 1, 5)
        if ($id -eq 'CD001') {
            $iso = $true
            if ($buf[$off] -eq 1 -and -not $r.Label) { $r.Label = $ascii.GetString($buf, $off + 40, 32).Trim() }
        }
        elseif ($id -eq 'NSR02' -or $id -eq 'NSR03') { $udf = $true }
    }
    if (-not $udf) {
        if ($iso) { $r.Text = 'This is not a Windows setup ISO (no UDF file system).' }
        else { $r.Text = 'This is not an ISO image.' }
        return $r
    }
    if ($r.Label -match '(?i)(^|_)(A64|ARM64)') { $r.Text = ('This is an ARM64 ISO ({0}); Lite OS needs the x64 ISO.' -f $r.Label); return $r }
    $r.Valid = $true
    $r.Text = ('Windows ISO found: {0}, {1}. The builder checks the edition and build after mounting it.' -f $r.Label, (Format-GuiBytes $fi.Length))
    if ($r.Label -notmatch '(?i)FRE|CCCOMA|CPBA|CCSA|CENA') {
        $r.Text = ("Volume label '{0}' does not look like Microsoft's ({1}). The builder checks the image after mounting it." -f $r.Label, (Format-GuiBytes $fi.Length))
    }
    return $r
}

function Get-GuiProgressLine {
    # Parses one protocol line. Returns $null for ordinary log lines.
    param([AllowNull()][AllowEmptyString()][string]$Line)
    if ([string]::IsNullOrEmpty($Line)) { return $null }
    $m = [regex]::Match($Line, '^\s*##LITEOS-PROGRESS\s+(\d{1,3})(?:\s+(.*))?$')
    if ($m.Success) {
        $pct = [int]$m.Groups[1].Value
        if ($pct -gt 100) { $pct = 100 }
        return @{ Kind = 'progress'; Percent = $pct; Message = $m.Groups[2].Value.Trim() }
    }
    $r = [regex]::Match($Line, '^\s*##LITEOS-RESULT\s+(ok|error)\b\s*(.*)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($r.Success) {
        $rest = $r.Groups[2].Value.Trim()
        if ($r.Groups[1].Value -ieq 'ok') {
            $path = $rest
            $hash = ''
            $h = [regex]::Match($rest, '^(.*?)\s+([0-9A-Fa-f]{64})$')
            if ($h.Success) { $path = $h.Groups[1].Value.Trim(); $hash = $h.Groups[2].Value.ToUpperInvariant() }
            return @{ Kind = 'ok'; Path = $path.Trim('"'); Hash = $hash }
        }
        return @{ Kind = 'error'; Message = $rest }
    }
    return $null
}

# =============================================================================================
# Restart in STA and elevated when needed (WPF needs STA; the builder needs administrator rights)
# =============================================================================================
$script:IsSta = ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA)
$script:IsAdmin = Test-GuiAdmin
if (-not $script:IsSta -or -not $script:IsAdmin) {
    $relaunch = New-Object System.Collections.Generic.List[string]
    foreach ($x in @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Minimized', '-File', $PSCommandPath)) { $relaunch.Add($x) }
    foreach ($k in @($PSBoundParameters.Keys)) {
        $relaunch.Add('-' + $k)
        $relaunch.Add([string]$PSBoundParameters[$k])
    }
    $line = Join-GuiArgs -Arguments $relaunch.ToArray()
    try {
        if ($script:IsAdmin) {
            Start-Process -FilePath (Get-GuiPowerShellExe) -ArgumentList $line -ErrorAction Stop | Out-Null
        }
        else {
            Write-Host 'Lite OS Builder needs administrator rights (it mounts and services a Windows image). Asking for them...'
            Start-Process -FilePath (Get-GuiPowerShellExe) -ArgumentList $line -Verb RunAs -ErrorAction Stop | Out-Null
        }
        exit 0
    }
    catch {
        Write-Host ('[Lite OS Builder] Could not restart with administrator rights: {0}' -f $_.Exception.Message) -ForegroundColor Red
        Write-Host '[Lite OS Builder] Start LiteOS-Builder.cmd and accept the administrator prompt.'
        exit 1
    }
}

# =============================================================================================
# Logging (per-user, never inside the protected %ProgramData%\LiteOS state folder)
# =============================================================================================
$script:LogDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'LiteOS-Builder\logs'
$script:LogFile = $null
try {
    if (-not [System.IO.Directory]::Exists($script:LogDir)) { [void][System.IO.Directory]::CreateDirectory($script:LogDir) }
    $script:LogFile = Join-Path $script:LogDir ('builder-gui-{0}.log' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
    [System.IO.File]::AppendAllText($script:LogFile, '', (New-Object System.Text.UTF8Encoding -ArgumentList $false))
}
catch {
    $script:LogFile = $null
    Write-Host ('[Lite OS Builder] Cannot write the log file: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
}

function Write-GuiLog {
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Message,
        [Parameter(Position = 1)][ValidateSet('Info', 'Warn', 'Error', 'Child')][string]$Level = 'Info'
    )
    $tag = 'INFO '
    $color = 'Gray'
    switch ($Level) {
        'Warn'  { $tag = 'WARN '; $color = 'Yellow' }
        'Error' { $tag = 'ERROR'; $color = 'Red' }
        'Child' { $tag = '  |  '; $color = 'DarkGray' }
    }
    if ($null -ne $script:LogFile) {
        try {
            $line = '{0} [{1}] {2}{3}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $tag, $Message, [Environment]::NewLine
            [System.IO.File]::AppendAllText($script:LogFile, $line, (New-Object System.Text.UTF8Encoding -ArgumentList $false))
        }
        catch { $null = $_ }
    }
    try { Write-Host ('[{0}] {1}' -f $tag.Trim(), $Message) -ForegroundColor $color } catch { $null = $_ }
}

try { $Host.UI.RawUI.WindowTitle = 'Lite OS Builder - log (keep this window open)' } catch { $null = $_ }
Write-GuiLog ('Lite OS Builder {0} | PowerShell {1} | Windows {2} | folder {3}' -f $script:GuiVersion, $PSVersionTable.PSVersion, [Environment]::OSVersion.Version, $script:Root)
if ($script:LogFile) { Write-GuiLog ('Log file: {0}' -f $script:LogFile) }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# =============================================================================================
# Data: branding, installers, apps, tweak catalog (engine), image removals (image module)
# =============================================================================================
$script:BrandName = 'Lite OS'
try {
    $b = Read-GuiJson $script:Paths.Branding
    $n = [string](Get-GuiProp $b 'name' '')
    if ($n.Trim()) { $script:BrandName = $n.Trim() }
}
catch { Write-GuiLog ('image\branding.json: {0}' -f $_.Exception.Message) 'Warn' }

$script:Installers = @()
try {
    $j = Read-GuiJson $script:Paths.Installers
    $script:Installers = @(@(Get-GuiProp $j 'installers' @()) | Where-Object { $null -ne $_ -and (Get-GuiProp $_ 'id') })
}
catch { Write-GuiLog ('image\installers.json: {0}' -f $_.Exception.Message) 'Warn' }

$script:Apps = @()
try {
    $j = Read-GuiJson $script:Paths.AppsInstall
    $script:Apps = @(@(Get-GuiProp $j 'apps' @()) | Where-Object { $null -ne $_ -and (Get-GuiProp $_ 'id') })
}
catch { Write-GuiLog ('tweaks\apps-install.json: {0}' -f $_.Exception.Message) 'Warn' }

$script:TweakCatalog = @()
$script:TweakError = ''
$script:TweakDefaults = @{ Lite = (New-GuiIdSet @()); Core = (New-GuiIdSet @()) }
try {
    Import-Module -Name $script:Paths.Engine -Force -DisableNameChecking -ErrorAction Stop
    $script:TweakCatalog = @(Get-LiteOSCatalog -Path $script:Paths.Tweaks)
    $script:TweakDefaults = @{
        Lite = (New-GuiIdSet @(Select-LiteOSTweaks -Catalog $script:TweakCatalog -Level Balanced))
        Core = (New-GuiIdSet @(Select-LiteOSTweaks -Catalog $script:TweakCatalog -Level Extreme))
    }
    Write-GuiLog ('Tweak catalog: {0} tweaks ({1} in Lite, {2} in Core by default)' -f $script:TweakCatalog.Count, $script:TweakDefaults.Lite.Count, $script:TweakDefaults.Core.Count)
}
catch {
    $script:TweakError = $_.Exception.Message
    Write-GuiLog ('Tweak catalog could not be loaded: {0}' -f $script:TweakError) 'Error'
}

$script:Removals = @()
$script:RemovalError = ''
$script:RemovalDefaults = @{ Lite = (New-GuiIdSet @()); Core = (New-GuiIdSet @()) }
if (Test-Path -LiteralPath $script:Paths.Image) {
    try {
        Import-Module -Name $script:Paths.Image -Force -DisableNameChecking -ErrorAction Stop
        try { $script:Removals = @(Get-LiteOSRemovals) }
        catch { $script:Removals = @(Get-LiteOSRemovals -Path $script:Paths.Removals) }
        $script:Removals = @($script:Removals | Where-Object { $null -ne $_ -and (Get-GuiProp $_ 'id') })
        $script:RemovalDefaults = @{
            Lite = (New-GuiIdSet @(Select-LiteOSRemovals -Removals $script:Removals -Mode Lite))
            Core = (New-GuiIdSet @(Select-LiteOSRemovals -Removals $script:Removals -Mode Core))
        }
        Write-GuiLog ('Image removals: {0} entries ({1} in Lite, {2} in Core by default)' -f $script:Removals.Count, $script:RemovalDefaults.Lite.Count, $script:RemovalDefaults.Core.Count)
    }
    catch {
        $script:RemovalError = $_.Exception.Message
        Write-GuiLog ('Image removals could not be loaded: {0}' -f $script:RemovalError) 'Error'
    }
}
else {
    $script:RemovalError = 'builder\LiteOS.Image.psm1 was not found, so image removals cannot be customized here. The builder uses the defaults of the chosen mode.'
    Write-GuiLog $script:RemovalError 'Warn'
}

# =============================================================================================
# Window (XAML)
# =============================================================================================
$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Lite OS Builder" Width="1000" Height="790" MinWidth="860" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="#FF14161B" Foreground="#FFE8EAED"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="BgBrush" Color="#FF14161B"/>
    <SolidColorBrush x:Key="BarBrush" Color="#FF181B21"/>
    <SolidColorBrush x:Key="CardBrush" Color="#FF1D2027"/>
    <SolidColorBrush x:Key="CardBorderBrush" Color="#FF2B2F38"/>
    <SolidColorBrush x:Key="InputBrush" Color="#FF111318"/>
    <SolidColorBrush x:Key="InputBorderBrush" Color="#FF3A3F4B"/>
    <SolidColorBrush x:Key="TextBrush" Color="#FFE8EAED"/>
    <SolidColorBrush x:Key="SubTextBrush" Color="#FF9AA3B2"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#FF4C8DFF"/>
    <SolidColorBrush x:Key="AccentDimBrush" Color="#FF233A63"/>
    <SolidColorBrush x:Key="ButtonBrush" Color="#FF2A2E37"/>
    <SolidColorBrush x:Key="HoverBrush" Color="#FF323744"/>
    <SolidColorBrush x:Key="DangerBrush" Color="#FFFF6B6B"/>
    <SolidColorBrush x:Key="DangerBgBrush" Color="#FF3A1F24"/>
    <SolidColorBrush x:Key="OkBrush" Color="#FF3DDC84"/>
    <SolidColorBrush x:Key="OkBgBrush" Color="#FF15301F"/>
    <SolidColorBrush x:Key="WarnBrush" Color="#FFFFC857"/>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource CardBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource CardBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="18,16"/>
      <Setter Property="Margin" Value="0,0,0,14"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource SubTextBrush}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="StepPill" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource ButtonBrush}"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="Padding" Value="14,5"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
    </Style>

    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Background" Value="{StaticResource ButtonBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource InputBorderBrush}"/>
      <Setter Property="Padding" Value="16,7"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="MinHeight" Value="32"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6"/>
              <Border x:Name="Hover" Background="#22FFFFFF" CornerRadius="6" Opacity="0"/>
              <Border x:Name="Press" Background="#33000000" CornerRadius="6" Opacity="0"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Hover" Property="Opacity" Value="1"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Press" Property="Opacity" Value="1"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{StaticResource DangerBgBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource DangerBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource DangerBrush}"/>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Margin" Value="0,4,0,4"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border x:Name="Box" Width="18" Height="18" CornerRadius="4" VerticalAlignment="Top" Margin="0,0,10,0"
                      Background="{StaticResource InputBrush}" BorderBrush="{StaticResource InputBorderBrush}" BorderThickness="1">
                <Path x:Name="Mark" Data="M 3.5 8.5 L 7 12 L 13.5 5" Stroke="White" StrokeThickness="2" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Grid.Column="1" VerticalAlignment="Top" RecognizesAccessKey="True"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
                <Setter TargetName="Box" Property="Background" Value="{StaticResource AccentBrush}"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource AccentBrush}"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource AccentBrush}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Margin" Value="0,4,0,2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Grid Width="18" Height="18" VerticalAlignment="Top" Margin="0,0,10,0">
                <Ellipse x:Name="Ring" Fill="{StaticResource InputBrush}" Stroke="{StaticResource InputBorderBrush}" StrokeThickness="1.5"/>
                <Ellipse x:Name="Dot" Width="8" Height="8" Fill="{StaticResource AccentBrush}" Visibility="Collapsed"/>
              </Grid>
              <ContentPresenter Grid.Column="1" VerticalAlignment="Top" RecognizesAccessKey="True"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Dot" Property="Visibility" Value="Visible"/>
                <Setter TargetName="Ring" Property="Stroke" Value="{StaticResource AccentBrush}"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Ring" Property="Stroke" Value="{StaticResource AccentBrush}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource InputBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource InputBorderBrush}"/>
      <Setter Property="CaretBrush" Value="{StaticResource TextBrush}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource AccentBrush}"/>
      <Setter Property="Padding" Value="6,5"/>
      <Setter Property="MinHeight" Value="32"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>

    <ControlTemplate x:Key="ComboToggle" TargetType="ToggleButton">
      <Border x:Name="Bd" Background="{StaticResource InputBrush}" BorderBrush="{StaticResource InputBorderBrush}" BorderThickness="1" CornerRadius="6">
        <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0" Data="M 0 0 L 4.5 4.5 L 9 0"
              Stroke="{StaticResource SubTextBrush}" StrokeThickness="1.6"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/></Trigger>
        <Trigger Property="IsChecked" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="MinHeight" Value="32"/>
      <Setter Property="MaxDropDownHeight" Value="360"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="Toggle" Template="{StaticResource ComboToggle}" Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
              <ContentPresenter IsHitTestVisible="False" Margin="10,0,30,0" VerticalAlignment="Center" HorizontalAlignment="Left"
                                Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                <Border Background="{StaticResource CardBrush}" BorderBrush="{StaticResource InputBorderBrush}" BorderThickness="1" CornerRadius="6"
                        Margin="0,2,0,0" MinWidth="{TemplateBinding ActualWidth}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer Margin="2" SnapsToDevicePixels="True">
                    <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="{StaticResource HoverBrush}"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentDimBrush}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Expander">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Expander">
            <DockPanel>
              <ToggleButton DockPanel.Dock="Top" Cursor="Hand" Content="{TemplateBinding Header}" Foreground="{TemplateBinding Foreground}"
                            IsChecked="{Binding IsExpanded, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="Transparent" Padding="0,2">
                      <StackPanel Orientation="Horizontal">
                        <Path x:Name="Arrow" Data="M 0 0 L 4.5 4.5 L 0 9" Stroke="{StaticResource AccentBrush}" StrokeThickness="1.8"
                              VerticalAlignment="Center" Margin="2,0,12,0"/>
                        <ContentPresenter VerticalAlignment="Center"/>
                      </StackPanel>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsChecked" Value="True"><Setter TargetName="Arrow" Property="Data" Value="M 0 0 L 4.5 4.5 L 9 0"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter x:Name="Body" Visibility="Collapsed" Margin="0,12,0,0"/>
            </DockPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsExpanded" Value="True"><Setter TargetName="Body" Property="Visibility" Value="Visible"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="{StaticResource CardBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource InputBorderBrush}"/>
      <Setter Property="Padding" Value="10,8"/>
    </Style>

    <Style x:Key="ThumbStyle" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border Background="#FF3A404C" CornerRadius="4"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Border Background="Transparent">
              <Track x:Name="PART_Track" Orientation="{TemplateBinding Orientation}" IsDirectionReversed="True" Margin="2">
                <Track.Thumb>
                  <Thumb Style="{StaticResource ThumbStyle}"/>
                </Track.Thumb>
              </Track>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="10"/>
          <Setter Property="MinHeight" Value="10"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Border Background="Transparent">
                  <Track x:Name="PART_Track" Orientation="{TemplateBinding Orientation}" IsDirectionReversed="False" Margin="2">
                    <Track.Thumb>
                      <Thumb Style="{StaticResource ThumbStyle}"/>
                    </Track.Thumb>
                  </Track>
                </Border>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" Background="{StaticResource BarBrush}" BorderBrush="{StaticResource CardBorderBrush}" BorderThickness="0,0,0,1" Padding="24,14">
      <DockPanel LastChildFill="False">
        <StackPanel DockPanel.Dock="Left">
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="TxtTitle" Text="Lite OS" FontSize="24" FontWeight="SemiBold"/>
            <TextBlock Text=" Builder" FontSize="24" Foreground="{StaticResource SubTextBrush}"/>
            <TextBlock x:Name="TxtVersion" Margin="10,0,0,5" VerticalAlignment="Bottom" FontSize="11" Foreground="{StaticResource SubTextBrush}"/>
          </StackPanel>
          <TextBlock Margin="0,2,0,0" Foreground="{StaticResource SubTextBrush}" Text="Turns the official Windows 11 from Microsoft into a lean, ready-to-game OS."/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <Border x:Name="Step1" Style="{StaticResource StepPill}"><TextBlock Text="1  Source"/></Border>
          <Border x:Name="Step2" Style="{StaticResource StepPill}"><TextBlock Text="2  Options"/></Border>
          <Border x:Name="Step3" Style="{StaticResource StepPill}"><TextBlock Text="3  Build"/></Border>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- Pages -->
    <Grid Grid.Row="1">

      <!-- Step 1: source -->
      <ScrollViewer x:Name="PageSource" VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="24,18,24,8">
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="1. Where should Windows come from?"/>
              <RadioButton x:Name="RbDownload" GroupName="Source" IsChecked="True" FontWeight="SemiBold" Content="Download Windows 11 from Microsoft (recommended)"/>
              <StackPanel x:Name="PanelDownload" Margin="28,4,0,12">
                <TextBlock Style="{StaticResource Sub}" Text="The official multi-edition x64 ISO (about 7 GB), straight from microsoft.com. Lite OS never hosts or changes Microsoft's files."/>
                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                  <TextBlock Text="Language" Width="90" VerticalAlignment="Center"/>
                  <ComboBox x:Name="CbLanguage" Width="320"/>
                </StackPanel>
                <TextBlock x:Name="TxtDownloadInfo" Style="{StaticResource Sub}" Margin="0,8,0,0"/>
                <CheckBox x:Name="CbRedownload" Visibility="Collapsed" Margin="0,8,0,0" Content="Download again (for example after Microsoft released a newer Windows 11)"/>
              </StackPanel>
              <RadioButton x:Name="RbIso" GroupName="Source" FontWeight="SemiBold" Content="Use my Windows 11 ISO"/>
              <StackPanel x:Name="PanelIso" Margin="28,4,0,0">
                <TextBlock Style="{StaticResource Sub}" Text="An official Windows 11 24H2 or newer x64 ISO that you downloaded from microsoft.com."/>
                <DockPanel Margin="0,10,0,0">
                  <Button x:Name="BtnBrowseIso" DockPanel.Dock="Right" Content="Browse..."/>
                  <TextBox x:Name="TbIsoPath"/>
                </DockPanel>
                <TextBlock x:Name="TxtIsoInfo" Style="{StaticResource Sub}" Margin="0,8,0,0"/>
              </StackPanel>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Download blocked? (message code 715-123130)"/>
              <TextBlock Style="{StaticResource Sub}" Text="Microsoft refuses ISO downloads for some countries and networks. Then open the Microsoft page in your browser, download &quot;Windows 11 (multi-edition ISO for x64 devices)&quot; there, and choose &quot;Use my Windows 11 ISO&quot; above."/>
              <Button x:Name="BtnOpenMsPage" HorizontalAlignment="Left" Margin="0,10,0,0" Content="Open the Microsoft download page"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="What you get"/>
              <TextBlock Style="{StaticResource Sub}" Text="- One bootable Lite OS ISO with everything baked in: no bloat apps, gaming and privacy tweaks, Lite OS branding, a clean Start menu and taskbar, Steam and the game runtimes preinstalled."/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,0" Text="- Windows Setup asks which disk to use (nothing is wiped automatically) and lets you create a local account."/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,0" Text="- Flash it to a USB stick with Rufus and install it like any Windows."/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- Step 2: options -->
      <ScrollViewer x:Name="PageOptions" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,18,24,8">
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="2. Mode"/>
              <RadioButton x:Name="RbLite" GroupName="Mode" IsChecked="True" FontWeight="SemiBold" Content="Lite (recommended)"/>
              <TextBlock Style="{StaticResource Sub}" Margin="28,2,0,12" Text="Lean and fast, and still a normal Windows: Windows Update, Microsoft Store, Defender, Xbox / Game Pass and kernel anti-cheat keep working."/>
              <RadioButton x:Name="RbCore" GroupName="Mode" FontWeight="SemiBold" Content="Core (advanced, not serviceable)"/>
              <TextBlock Style="{StaticResource Sub}" Margin="28,2,0,0" Text="X-Lite style: the smallest and fastest build, but Windows Update, Defender, the Edge browser and recovery are removed."/>
              <Border x:Name="CoreWarning" Visibility="Collapsed" Margin="28,12,0,0" Padding="14,12" CornerRadius="8" BorderThickness="1"
                      Background="{StaticResource DangerBgBrush}" BorderBrush="{StaticResource DangerBrush}">
                <StackPanel>
                  <TextBlock x:Name="TxtCoreWarningTitle" Text="Read this before you choose Core" FontWeight="SemiBold" Foreground="{StaticResource DangerBrush}"/>
                  <TextBlock x:Name="TxtCoreWarning" TextWrapping="Wrap" Margin="0,6,0,10"/>
                  <CheckBox x:Name="CbCoreConfirm">
                    <TextBlock x:Name="TxtCoreConfirm" TextWrapping="Wrap" Text="I understand: Core cannot be updated (I rebuild from a newer ISO instead) and has no Defender, no Edge browser and no recovery environment."/>
                  </CheckBox>
                </StackPanel>
              </Border>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Windows edition"/>
              <ComboBox x:Name="CbEdition" Width="320" HorizontalAlignment="Left"/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,8,0,0" Text="Only this edition is kept in the image. Activate it with your own license: a digital license of this PC activates automatically."/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Preinstall (baked into the image)"/>
              <TextBlock Style="{StaticResource Sub}" Text="Official installers are downloaded from their publishers while building, their digital signatures are checked, and Windows Setup installs them silently."/>
              <StackPanel x:Name="PanelInstallers" Margin="0,8,0,0"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <DockPanel>
                <Button x:Name="BtnAppsRecommended" DockPanel.Dock="Right" Content="Select recommended" Padding="12,4" MinHeight="28"/>
                <TextBlock Style="{StaticResource H2}" Text="Apps installed at first sign-in (optional)"/>
              </DockPanel>
              <TextBlock Style="{StaticResource Sub}" Text="Installed with winget from their official sources the first time you sign in (needs internet)."/>
              <WrapPanel x:Name="PanelApps" Margin="0,8,0,0"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Windows Setup"/>
              <CheckBox x:Name="CbBypass" IsChecked="True">
                <StackPanel>
                  <TextBlock Text="Skip the TPM / Secure Boot / CPU / RAM checks"/>
                  <TextBlock Style="{StaticResource Sub}" FontSize="12" Text="Lets Setup install on older PCs. Some anti-cheat (Vanguard, FACEIT) still needs TPM 2.0 and Secure Boot to play."/>
                </StackPanel>
              </CheckBox>
              <CheckBox x:Name="CbKeepEncryption" Margin="0,8,0,0">
                <StackPanel>
                  <TextBlock Text="Keep automatic device encryption (BitLocker)"/>
                  <TextBlock Style="{StaticResource Sub}" FontSize="12" Text="Off by default, so a new install is not encrypted silently. You can turn BitLocker on yourself any time."/>
                </StackPanel>
              </CheckBox>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Output"/>
              <TextBlock Text="Save the Lite OS ISO in" Margin="0,0,0,4"/>
              <DockPanel>
                <Button x:Name="BtnBrowseOutput" DockPanel.Dock="Right" Content="Browse..."/>
                <TextBox x:Name="TbOutput"/>
              </DockPanel>
              <TextBlock x:Name="TxtWorkLabel" Margin="0,12,0,4" Text="Work folder (optional, needs about 30 GB free on a local NTFS drive)"/>
              <DockPanel>
                <Button x:Name="BtnBrowseWork" DockPanel.Dock="Right" Content="Browse..."/>
                <TextBox x:Name="TbWorkDir"/>
              </DockPanel>
              <TextBlock x:Name="TxtSpace" Style="{StaticResource Sub}" Margin="0,8,0,0"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <Expander x:Name="ExpCustomize" Header="Customize tweaks and removals (advanced)" FontWeight="SemiBold" FontSize="14">
              <StackPanel TextElement.FontWeight="Normal" TextElement.FontSize="13">
                <TextBlock Style="{StaticResource Sub}" Text="Checked items are applied. The defaults follow the mode; your own changes are kept when you switch modes. Hover an item for details."/>
                <DockPanel Margin="0,10,0,8">
                  <Button x:Name="BtnResetCustom" DockPanel.Dock="Right" Content="Reset to defaults"/>
                  <TextBlock DockPanel.Dock="Left" Text="Filter" VerticalAlignment="Center" Margin="0,0,10,0"/>
                  <TextBox x:Name="TbFilter"/>
                </DockPanel>
                <TextBlock x:Name="TxtCustomSummary" Style="{StaticResource Sub}" Margin="0,0,0,8"/>
                <Border BorderBrush="{StaticResource CardBorderBrush}" BorderThickness="1" CornerRadius="6" Padding="12,6" Background="{StaticResource BgBrush}">
                  <ScrollViewer MaxHeight="430" VerticalScrollBarVisibility="Auto">
                    <StackPanel x:Name="PanelCustom"/>
                  </ScrollViewer>
                </Border>
              </StackPanel>
            </Expander>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- Step 3: build -->
      <Grid x:Name="PageBuild" Visibility="Collapsed" Margin="24,18,24,12">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <DockPanel Grid.Row="0">
          <TextBlock x:Name="TxtElapsed" DockPanel.Dock="Right" VerticalAlignment="Bottom" Foreground="{StaticResource SubTextBrush}"/>
          <StackPanel>
            <TextBlock x:Name="TxtStage" Text="3. Build" FontSize="18" FontWeight="SemiBold"/>
            <TextBlock x:Name="TxtStatus" Margin="0,4,0,0" Foreground="{StaticResource SubTextBrush}" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </DockPanel>
        <Grid Grid.Row="1" Margin="0,12,0,12">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="56"/>
          </Grid.ColumnDefinitions>
          <ProgressBar x:Name="PbBuild" Height="10" Minimum="0" Maximum="100" Value="0" BorderThickness="0"
                       Foreground="{StaticResource AccentBrush}" Background="{StaticResource InputBrush}"/>
          <TextBlock x:Name="TxtPercent" Grid.Column="1" Text="0%" HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
        <StackPanel Grid.Row="2">
          <Border x:Name="PanelResult" Visibility="Collapsed" Margin="0,0,0,12" Padding="16,14" CornerRadius="8" BorderThickness="1"
                  Background="{StaticResource OkBgBrush}" BorderBrush="{StaticResource OkBrush}">
            <StackPanel>
              <TextBlock x:Name="TxtResultTitle" Text="Lite OS is ready" FontSize="16" FontWeight="SemiBold" Foreground="{StaticResource OkBrush}"/>
              <TextBlock Text="ISO" Margin="0,10,0,2" Foreground="{StaticResource SubTextBrush}"/>
              <TextBox x:Name="TbResultPath" IsReadOnly="True"/>
              <TextBlock Text="SHA256" Margin="0,8,0,2" Foreground="{StaticResource SubTextBrush}"/>
              <TextBox x:Name="TbResultHash" IsReadOnly="True" FontFamily="Consolas"/>
              <WrapPanel Margin="0,10,0,0">
                <Button x:Name="BtnOpenFolder" Margin="0,0,8,0" Content="Open folder"/>
                <Button x:Name="BtnCopyHash" Margin="0,0,8,0" Content="Copy SHA256"/>
              </WrapPanel>
              <TextBlock TextWrapping="Wrap" Margin="0,12,0,0">
                <Run Text="Next: flash the ISO to a USB stick with "/><Hyperlink x:Name="LinkRufus" Foreground="{StaticResource AccentBrush}"><Run Text="Rufus (rufus.ie)"/></Hyperlink><Run Text=", boot from it and install. Lite OS never writes to USB drives itself."/>
              </TextBlock>
              <TextBlock x:Name="TxtResultNote" TextWrapping="Wrap" Margin="0,6,0,0" Foreground="{StaticResource SubTextBrush}"/>
            </StackPanel>
          </Border>
          <Border x:Name="PanelError" Visibility="Collapsed" Margin="0,0,0,12" Padding="16,14" CornerRadius="8" BorderThickness="1"
                  Background="{StaticResource DangerBgBrush}" BorderBrush="{StaticResource DangerBrush}">
            <StackPanel>
              <TextBlock x:Name="TxtErrorTitle" FontSize="16" FontWeight="SemiBold" Foreground="{StaticResource DangerBrush}"/>
              <TextBlock x:Name="TxtErrorText" TextWrapping="Wrap" Margin="0,6,0,0"/>
              <WrapPanel Margin="0,10,0,0">
                <Button x:Name="BtnErrOpenMs" Margin="0,0,8,0" Content="Open the Microsoft download page"/>
                <Button x:Name="BtnErrUseIso" Margin="0,0,8,0" Content="Use my ISO instead"/>
                <Button x:Name="BtnErrOpenLog" Margin="0,0,8,0" Content="Open log"/>
              </WrapPanel>
            </StackPanel>
          </Border>
        </StackPanel>
        <TextBox x:Name="TbLog" Grid.Row="3" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap" FontFamily="Consolas" FontSize="12"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" VerticalContentAlignment="Top" Background="#FF0E1014"/>
      </Grid>
    </Grid>

    <!-- Footer -->
    <Border Grid.Row="2" Background="{StaticResource BarBrush}" BorderBrush="{StaticResource CardBorderBrush}" BorderThickness="0,1,0,0" Padding="24,12">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnCleanup" Visibility="Collapsed" Content="Cleanup leftovers"/>
          <Button x:Name="BtnBack" Content="Back"/>
          <Button x:Name="BtnNext" Style="{StaticResource AccentButton}" Content="Next"/>
          <Button x:Name="BtnBuild" Style="{StaticResource AccentButton}" Content="Build Lite OS"/>
          <Button x:Name="BtnNewBuild" Style="{StaticResource AccentButton}" Content="Build another"/>
          <Button x:Name="BtnCancel" Style="{StaticResource DangerButton}" Content="Cancel build"/>
          <Button x:Name="BtnForceStop" Style="{StaticResource DangerButton}" Content="Force stop"/>
        </StackPanel>
        <TextBlock x:Name="TxtLegal" TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,16,0" FontSize="11.5" Foreground="{StaticResource SubTextBrush}"
                   Text="Uses your official Windows from Microsoft; activate with your own license. Lite OS never ships Windows files, product keys or activators."/>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@

# Every x:Name the code uses (checked at startup, so a XAML typo fails loudly instead of later).
$script:ControlNames = @(
    'TxtTitle', 'TxtVersion', 'Step1', 'Step2', 'Step3',
    'PageSource', 'RbDownload', 'PanelDownload', 'CbLanguage', 'TxtDownloadInfo', 'CbRedownload', 'RbIso', 'PanelIso',
    'TbIsoPath', 'BtnBrowseIso', 'TxtIsoInfo', 'BtnOpenMsPage',
    'PageOptions', 'RbLite', 'RbCore', 'CoreWarning', 'TxtCoreWarningTitle', 'TxtCoreWarning', 'CbCoreConfirm', 'TxtCoreConfirm', 'CbEdition', 'PanelInstallers',
    'BtnAppsRecommended', 'PanelApps', 'CbBypass', 'CbKeepEncryption', 'TbOutput', 'BtnBrowseOutput', 'TxtWorkLabel',
    'TbWorkDir', 'BtnBrowseWork', 'TxtSpace', 'ExpCustomize', 'BtnResetCustom', 'TbFilter', 'TxtCustomSummary', 'PanelCustom',
    'PageBuild', 'TxtElapsed', 'TxtStage', 'TxtStatus', 'PbBuild', 'TxtPercent', 'PanelResult', 'TxtResultTitle',
    'TbResultPath', 'TbResultHash', 'BtnOpenFolder', 'BtnCopyHash', 'LinkRufus', 'TxtResultNote', 'PanelError',
    'TxtErrorTitle', 'TxtErrorText', 'BtnErrOpenMs', 'BtnErrUseIso', 'BtnErrOpenLog', 'TbLog',
    'BtnCleanup', 'BtnBack', 'BtnNext', 'BtnBuild', 'BtnNewBuild', 'BtnCancel', 'BtnForceStop', 'TxtLegal'
)

# =============================================================================================
# UI state
# =============================================================================================
$script:Window          = $null
$script:Ui              = @{}
$script:Step            = 1
$script:Child           = $null
$script:Plan            = $null
$script:Outcome         = ''
$script:CancelRequested = $false
$script:ForceStopped    = $false
$script:CloseAfterExit  = $false
$script:StopHelper      = $null
$script:KillHelper      = $null
$script:CoreGateKind    = ''
$script:BuildStartedAt  = $null
$script:TickErrorShown  = $false
$script:AwakeHeld       = $false
$script:Overrides       = @{}
$script:InstallerChoice = @{}
$script:InstallerBoxes  = [System.Collections.Generic.List[object]]::new()
$script:AppBoxes        = [System.Collections.Generic.List[object]]::new()
$script:CustomItems     = [System.Collections.Generic.List[object]]::new()
$script:CustomHeaders   = [System.Collections.Generic.List[object]]::new()
$script:PowerShellExe   = Get-GuiPowerShellExe
$script:ChildEncoding   = [System.Text.Encoding]::Default
try { $script:ChildEncoding = [Console]::OutputEncoding } catch { $null = $_ }

# =============================================================================================
# UI helpers
# =============================================================================================
function Show-GuiMessage {
    param([string]$Text, [string]$Title = '', [string]$Buttons = 'OK', [string]$Icon = 'Information')
    if (-not $Title) { $Title = $script:BrandName + ' Builder' }
    $b = [System.Windows.MessageBoxButton]$Buttons
    $i = [System.Windows.MessageBoxImage]$Icon
    if ($null -ne $script:Window -and $script:Window.IsLoaded) { return [System.Windows.MessageBox]::Show($script:Window, $Text, $Title, $b, $i) }
    return [System.Windows.MessageBox]::Show($Text, $Title, $b, $i)
}

function Invoke-GuiAction {
    # Every UI handler runs through here: an error is logged and shown, never crashes the window.
    param([scriptblock]$Action)
    try { & $Action }
    catch {
        $msg = $_.Exception.Message
        Write-GuiLog ('{0} | {1}' -f $msg, ($_.ScriptStackTrace -replace "`r?`n", ' <- ')) 'Error'
        try { [void](Show-GuiMessage -Text $msg -Icon 'Error') } catch { $null = $_ }
    }
}

function Get-GuiBrush {
    param([string]$Key)
    return $script:Window.FindResource($Key)
}

function Open-GuiUrl {
    param([string]$Url)
    try {
        # explorer.exe passes the URL to the signed-in user's default browser (not elevated).
        Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList $Url -ErrorAction Stop
        Write-GuiLog ('Opened {0}' -f $Url)
    }
    catch { [void](Show-GuiMessage -Text ('Open this address in your browser:' + [Environment]::NewLine + $Url)) }
}

function Open-GuiFile {
    param([string]$Path, [switch]$Select)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $explorer = Join-Path $env:SystemRoot 'explorer.exe'
    if ($Select) { Start-Process -FilePath $explorer -ArgumentList ('/select,"{0}"' -f $Path) }
    else { Start-Process -FilePath $explorer -ArgumentList ('"{0}"' -f $Path) }
}

function Initialize-GuiNative {
    # kernel32 calls used by the GUI process itself (compiled once, in memory).
    if ('LiteOSBuilder.Native' -as [type]) { return $true }
    try {
        $sig = '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);' +
               '[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] public static extern System.IntPtr GetStdHandle(int which);' +
               '[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(System.IntPtr handle, out uint mode);' +
               '[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(System.IntPtr handle, uint mode);'
        Add-Type -Namespace 'LiteOSBuilder' -Name 'Native' -MemberDefinition $sig
        return $true
    }
    catch {
        Write-GuiLog ('Native helpers are not available: {0}' -f $_.Exception.Message) 'Warn'
        return $false
    }
}

function Disable-GuiQuickEdit {
    # Selecting text in the (minimized) log console would block Write-Host and freeze the window.
    # QuickEdit is switched off for this console window only; nothing is saved.
    if (-not (Initialize-GuiNative)) { return }
    try {
        $h = [LiteOSBuilder.Native]::GetStdHandle(-10)
        $mode = [uint32]0
        if ([LiteOSBuilder.Native]::GetConsoleMode($h, [ref]$mode)) {
            $new = [int64]$mode
            if (($new -band 0x40) -ne 0) { $new = $new - 0x40 }
            $new = $new -bor 0x80
            if ($new -ne [int64]$mode) { [void][LiteOSBuilder.Native]::SetConsoleMode($h, [uint32]$new) }
        }
    }
    catch { Write-GuiLog ('Could not switch off QuickEdit in the log window: {0}' -f $_.Exception.Message) 'Warn' }
}

function Set-GuiKeepAwake {
    # Keeps the PC from sleeping while a build runs (released automatically when this process exits).
    param([bool]$On)
    if (-not (Initialize-GuiNative)) { return }
    try {
        if ($On) { [void][LiteOSBuilder.Native]::SetThreadExecutionState([uint32]2147483649) }    # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
        else { [void][LiteOSBuilder.Native]::SetThreadExecutionState([uint32]2147483648) }       # ES_CONTINUOUS
        $script:AwakeHeld = $On
    }
    catch { Write-GuiLog ('Could not change the sleep request: {0}' -f $_.Exception.Message) 'Warn' }
}

function Select-GuiFolder {
    param([string]$Start, [string]$Description)
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Description
    $dlg.ShowNewFolderButton = $true
    if ($Start -and [System.IO.Directory]::Exists($Start)) { $dlg.SelectedPath = $Start }
    $owner = New-Object System.Windows.Forms.NativeWindow
    try {
        $owner.AssignHandle((New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $script:Window).Handle)
        if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    }
    finally {
        try { $owner.ReleaseHandle() } catch { $null = $_ }
        $dlg.Dispose()
    }
    return $null
}

function New-GuiCheckBox {
    param([string]$Title, [string]$Detail, [string]$Tip, [string]$Badge, [double]$Width = 0)
    $cb = New-Object System.Windows.Controls.CheckBox
    $sp = New-Object System.Windows.Controls.StackPanel
    $t = New-Object System.Windows.Controls.TextBlock
    $t.TextWrapping = [System.Windows.TextWrapping]::Wrap
    [void]$t.Inlines.Add((New-Object System.Windows.Documents.Run -ArgumentList $Title))
    if ($Badge) {
        $run = New-Object System.Windows.Documents.Run -ArgumentList ('   ' + $Badge)
        $run.Foreground = Get-GuiBrush 'SubTextBrush'
        $run.FontSize = 11
        [void]$t.Inlines.Add($run)
    }
    [void]$sp.Children.Add($t)
    if ($Detail) {
        $d = New-Object System.Windows.Controls.TextBlock
        $d.Text = $Detail
        $d.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $d.FontSize = 12
        $d.Foreground = Get-GuiBrush 'SubTextBrush'
        [void]$sp.Children.Add($d)
    }
    $cb.Content = $sp
    if ($Tip) {
        $tt = New-Object System.Windows.Controls.TextBlock
        $tt.Text = $Tip
        $tt.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $tt.MaxWidth = 460
        $cb.ToolTip = $tt
    }
    if ($Width -gt 0) { $cb.Width = $Width }
    $cb.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 4, 14, 4
    return $cb
}

function New-GuiHeader {
    param([string]$Text)
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = $Text
    $h.FontWeight = [System.Windows.FontWeights]::SemiBold
    $h.Foreground = Get-GuiBrush 'AccentBrush'
    $h.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 12, 0, 4
    return $h
}

function New-GuiNote {
    param([string]$Text, [string]$BrushKey = 'WarnBrush')
    $n = New-Object System.Windows.Controls.TextBlock
    $n.Text = $Text
    $n.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $n.Foreground = Get-GuiBrush $BrushKey
    $n.Margin = New-Object System.Windows.Thickness -ArgumentList 0, 8, 0, 8
    return $n
}

function Get-GuiMode {
    if ($script:Ui.RbCore.IsChecked -eq $true) { return 'Core' }
    return 'Lite'
}

function Get-GuiText {
    param($TextBox)
    return ([string]$TextBox.Text).Trim().Trim('"').Trim()
}

# =============================================================================================
# Step 1: source
# =============================================================================================
function Get-GuiDownloadTarget {
    $lang = [string]$script:Ui.CbLanguage.SelectedItem
    if (-not $lang) { $lang = 'English (United States)' }
    $safe = ($lang -replace '[^A-Za-z0-9]+', '-').Trim('-')
    return (Join-Path (Get-GuiDownloadsFolder) ('Windows11-x64-{0}.iso' -f $safe))
}

function Update-GuiSource {
    $dl = ($script:Ui.RbDownload.IsChecked -eq $true)
    $script:Ui.PanelDownload.IsEnabled = $dl
    $script:Ui.PanelIso.IsEnabled = -not $dl
    $script:Ui.PanelDownload.Opacity = 1.0
    $script:Ui.PanelIso.Opacity = 1.0
    if (-not $dl) { $script:Ui.PanelDownload.Opacity = 0.55 } else { $script:Ui.PanelIso.Opacity = 0.55 }
    Update-GuiDownloadInfo
    Update-GuiIsoInfo
    Update-GuiSpace
}

function Update-GuiDownloadInfo {
    $target = Get-GuiDownloadTarget
    if ([System.IO.File]::Exists($target)) {
        $fi = New-Object System.IO.FileInfo -ArgumentList $target
        $script:Ui.TxtDownloadInfo.Text = ('Already downloaded on {0} ({1}): {2}. It is reused, so building again is quick.' -f $fi.LastWriteTime.ToString('d'), (Format-GuiBytes $fi.Length), $target)
        $script:Ui.CbRedownload.Visibility = 'Visible'
    }
    else {
        $script:Ui.TxtDownloadInfo.Text = ('Saved as {0} and kept for later builds.' -f $target)
        $script:Ui.CbRedownload.Visibility = 'Collapsed'
        $script:Ui.CbRedownload.IsChecked = $false
    }
}

function Update-GuiIsoInfo {
    $p = Get-GuiText $script:Ui.TbIsoPath
    if (-not $p) {
        $script:Ui.TxtIsoInfo.Text = ''
        return
    }
    $r = Test-GuiIsoFile -Path $p
    $script:Ui.TxtIsoInfo.Text = $r.Text
    if ($r.Valid) { $script:Ui.TxtIsoInfo.Foreground = Get-GuiBrush 'OkBrush' }
    else { $script:Ui.TxtIsoInfo.Foreground = Get-GuiBrush 'DangerBrush' }
}

function Invoke-GuiBrowseIso {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Choose the official Windows 11 ISO'
    $dlg.Filter = 'Windows ISO (*.iso)|*.iso|All files (*.*)|*.*'
    $cur = Get-GuiText $script:Ui.TbIsoPath
    if ($cur -and [System.IO.File]::Exists($cur)) { $dlg.InitialDirectory = [System.IO.Path]::GetDirectoryName($cur) }
    else { $dlg.InitialDirectory = Get-GuiDownloadsFolder }
    if ($dlg.ShowDialog($script:Window) -eq $true) {
        $script:Ui.RbIso.IsChecked = $true
        $script:Ui.TbIsoPath.Text = $dlg.FileName
    }
}

function Test-GuiSourceReady {
    # Returns '' when step 1 is complete, else the reason.
    if ($script:Ui.RbDownload.IsChecked -eq $true) {
        if (-not [string]$script:Ui.CbLanguage.SelectedItem) { return 'Choose the Windows language.' }
        return ''
    }
    $r = Test-GuiIsoFile -Path (Get-GuiText $script:Ui.TbIsoPath)
    if (-not $r.Valid) { return $r.Text }
    return ''
}

# =============================================================================================
# Step 2: options
# =============================================================================================
function Update-GuiInstallers {
    $mode = (Get-GuiMode).ToLowerInvariant()
    $panel = $script:Ui.PanelInstallers
    $panel.Children.Clear()
    $script:InstallerBoxes.Clear()
    foreach ($i in $script:Installers) {
        $m = ([string](Get-GuiProp $i 'mode' 'both')).ToLowerInvariant()
        if ($m -ne 'both' -and $m -ne $mode) { continue }
        $id = [string](Get-GuiProp $i 'id' '')
        $name = [string](Get-GuiProp $i 'name' $id)
        $tip = ('{0}{1}Publisher: {2}{1}{3}' -f [string](Get-GuiProp $i 'description' ''), [Environment]::NewLine, [string](Get-GuiProp $i 'publisher' ''), [string](Get-GuiProp $i 'url' ''))
        $cb = New-GuiCheckBox -Title $name -Detail ([string](Get-GuiProp $i 'description' '')) -Tip $tip
        $cb.Tag = $id
        $on = ConvertTo-GuiBool (Get-GuiProp $i 'default' $false)
        if ($script:InstallerChoice.ContainsKey($id)) { $on = [bool]$script:InstallerChoice[$id] }
        $cb.IsChecked = $on
        $cb.Add_Click({ param($s, $e) Invoke-GuiAction { $script:InstallerChoice[[string]$s.Tag] = ($s.IsChecked -eq $true) } })
        [void]$panel.Children.Add($cb)
        $script:InstallerBoxes.Add($cb)
    }
    if ($script:InstallerBoxes.Count -eq 0) {
        [void]$panel.Children.Add((New-GuiNote 'No installers are defined for this mode (image\installers.json).' 'SubTextBrush'))
    }
}

function Get-GuiInstallersArg {
    $mode = (Get-GuiMode).ToLowerInvariant()
    $picked = New-Object System.Collections.Generic.List[string]
    foreach ($cb in $script:InstallerBoxes) { if ($cb.IsChecked -eq $true) { $picked.Add([string]$cb.Tag) } }
    $defaults = New-Object System.Collections.Generic.List[string]
    foreach ($i in $script:Installers) {
        $m = ([string](Get-GuiProp $i 'mode' 'both')).ToLowerInvariant()
        if (($m -eq 'both' -or $m -eq $mode) -and (ConvertTo-GuiBool (Get-GuiProp $i 'default' $false))) { $defaults.Add([string](Get-GuiProp $i 'id' '')) }
    }
    if ($picked.Count -eq 0) { return 'none' }
    $same = ($picked.Count -eq $defaults.Count)
    if ($same) { foreach ($d in $defaults) { if (-not $picked.Contains($d)) { $same = $false; break } } }
    if ($same) { return 'default' }
    return ($picked.ToArray() -join ',')
}

function Initialize-GuiApps {
    $panel = $script:Ui.PanelApps
    $panel.Children.Clear()
    $script:AppBoxes.Clear()
    foreach ($a in $script:Apps) {
        $id = [string](Get-GuiProp $a 'id' '')
        $name = [string](Get-GuiProp $a 'name' $id)
        $tip = ('{0}{1}winget id: {2}' -f [string](Get-GuiProp $a 'description' ''), [Environment]::NewLine, $id)
        $cb = New-GuiCheckBox -Title $name -Badge ([string](Get-GuiProp $a 'group' '')) -Tip $tip -Width 270
        $cb.Tag = $id
        $cb.IsChecked = $false
        [void]$panel.Children.Add($cb)
        $script:AppBoxes.Add($cb)
    }
    if ($script:AppBoxes.Count -eq 0) {
        [void]$panel.Children.Add((New-GuiNote 'No optional apps are defined (tweaks\apps-install.json).' 'SubTextBrush'))
    }
}

function Select-GuiRecommendedApps {
    foreach ($cb in $script:AppBoxes) {
        $id = [string]$cb.Tag
        $on = $false
        foreach ($a in $script:Apps) { if ([string](Get-GuiProp $a 'id' '') -eq $id) { $on = ConvertTo-GuiBool (Get-GuiProp $a 'default' $false) } }
        $cb.IsChecked = $on
    }
}

function Get-GuiAppsArg {
    $picked = New-Object System.Collections.Generic.List[string]
    foreach ($cb in $script:AppBoxes) { if ($cb.IsChecked -eq $true) { $picked.Add([string]$cb.Tag) } }
    if ($picked.Count -eq 0) { return 'none' }
    return ($picked.ToArray() -join ',')
}

function Initialize-GuiCustomize {
    $panel = $script:Ui.PanelCustom
    $panel.Children.Clear()
    $script:CustomItems.Clear()
    $script:CustomHeaders.Clear()
    $nl = [Environment]::NewLine

    if ($script:TweakError) {
        [void]$panel.Children.Add((New-GuiNote ('The tweak catalog could not be loaded, so tweaks cannot be customized here: ' + $script:TweakError) 'DangerBrush'))
    }
    $lastCat = $null
    $header = $null
    foreach ($t in $script:TweakCatalog) {
        $id = [string](Get-GuiProp $t 'id' '')
        if (-not $id) { continue }
        $cat = [string](Get-GuiProp $t 'category' '')
        if ($cat -ne $lastCat) {
            $header = New-GuiHeader ([string](Get-GuiProp $t 'categoryTitle' $cat))
            [void]$panel.Children.Add($header)
            $script:CustomHeaders.Add($header)
            $lastCat = $cat
        }
        $name = [string](Get-GuiProp $t 'name' $id)
        $level = ([string](Get-GuiProp $t 'level' '')).ToLowerInvariant()
        $risk = ([string](Get-GuiProp $t 'risk' '')).ToLowerInvariant()
        $desc = [string](Get-GuiProp $t 'description' '')
        $badge = $level
        if ($risk -and $risk -ne 'none') { $badge += (', risk ' + $risk) }
        if (ConvertTo-GuiBool (Get-GuiProp $t 'reboot' $false)) { $badge += ', restart' }
        $cb = New-GuiCheckBox -Title $name -Badge $badge -Tip ($desc + $nl + $nl + $id)
        $cb.Tag = $id
        $cb.Add_Click({ param($s, $e) Register-GuiOverride -Box $s })
        [void]$panel.Children.Add($cb)
        $script:CustomItems.Add([pscustomobject]@{
                Id      = $id
                Name    = $name
                Kind    = 'tweak'
                RMode   = ''
                Box     = $cb
                Header  = $header
                DefLite = $script:TweakDefaults.Lite.Contains($id)
                DefCore = $script:TweakDefaults.Core.Contains($id)
                Search  = ('{0} {1} {2} {3} {4}' -f $id, $name, $desc, $cat, $level).ToLowerInvariant()
            })
    }

    if ($script:Removals.Count -gt 0) {
        $header = New-GuiHeader 'Windows components removed from the image'
        [void]$panel.Children.Add($header)
        $script:CustomHeaders.Add($header)
        foreach ($r in $script:Removals) {
            $id = [string](Get-GuiProp $r 'id' '')
            $name = [string](Get-GuiProp $r 'name' $id)
            $rmode = ([string](Get-GuiProp $r 'mode' '')).ToLowerInvariant()
            $risk = ([string](Get-GuiProp $r 'risk' '')).ToLowerInvariant()
            $desc = [string](Get-GuiProp $r 'description' '')
            $badge = $rmode
            if ($risk -and $risk -ne 'none') { $badge += (', risk ' + $risk) }
            $cb = New-GuiCheckBox -Title $name -Badge $badge -Tip ($desc + $nl + $nl + $id + ' (' + [string](Get-GuiProp $r 'type' '') + ')')
            $cb.Tag = $id
            $cb.Add_Click({ param($s, $e) Register-GuiOverride -Box $s })
            [void]$panel.Children.Add($cb)
            $script:CustomItems.Add([pscustomobject]@{
                    Id      = $id
                    Name    = $name
                    Kind    = 'removal'
                    RMode   = $rmode
                    Box     = $cb
                    Header  = $header
                    DefLite = $script:RemovalDefaults.Lite.Contains($id)
                    DefCore = $script:RemovalDefaults.Core.Contains($id)
                    Search  = ('{0} {1} {2} {3}' -f $id, $name, $desc, $rmode).ToLowerInvariant()
                })
        }
    }
    if ($script:RemovalError) {
        [void]$panel.Children.Add((New-GuiNote $script:RemovalError 'WarnBrush'))
    }
}

function Register-GuiOverride {
    param($Box)
    try {
        $script:Overrides[[string]$Box.Tag] = ($Box.IsChecked -eq $true)
        Update-GuiCustomSummary
    }
    catch { Write-GuiLog ('Customize: {0}' -f $_.Exception.Message) 'Error' }
}

function Update-GuiCustomChecks {
    $mode = Get-GuiMode
    foreach ($it in $script:CustomItems) {
        $want = $it.DefLite
        if ($mode -eq 'Core') { $want = $it.DefCore }
        if ($script:Overrides.ContainsKey($it.Id)) { $want = [bool]$script:Overrides[$it.Id] }
        $it.Box.IsChecked = $want
    }
    Update-GuiCustomSummary
}

function Get-GuiIncludeExclude {
    $mode = Get-GuiMode
    $inc = New-Object System.Collections.Generic.List[string]
    $exc = New-Object System.Collections.Generic.List[string]
    foreach ($it in $script:CustomItems) {
        $def = $it.DefLite
        if ($mode -eq 'Core') { $def = $it.DefCore }
        $on = ($it.Box.IsChecked -eq $true)
        if ($on -and -not $def) { $inc.Add($it.Id) }
        elseif ($def -and -not $on) { $exc.Add($it.Id) }
    }
    return @{ Include = $inc.ToArray(); Exclude = $exc.ToArray() }
}

function Update-GuiCustomSummary {
    $tw = 0; $twOn = 0; $rm = 0; $rmOn = 0
    foreach ($it in $script:CustomItems) {
        $on = ($it.Box.IsChecked -eq $true)
        if ($it.Kind -eq 'tweak') { $tw++; if ($on) { $twOn++ } } else { $rm++; if ($on) { $rmOn++ } }
    }
    $ie = Get-GuiIncludeExclude
    $text = ('Tweaks: {0} of {1} selected.' -f $twOn, $tw)
    if ($rm -gt 0) { $text += ('  Image removals: {0} of {1} selected.' -f $rmOn, $rm) }
    if ($ie.Include.Count -gt 0 -or $ie.Exclude.Count -gt 0) { $text += ('  Your changes: {0} added, {1} removed.' -f $ie.Include.Count, $ie.Exclude.Count) }
    else { $text += '  Using the defaults of the mode.' }
    $script:Ui.TxtCustomSummary.Text = $text
    # A ticked / unticked Core-only removal changes whether the Core warning must be confirmed.
    Update-GuiCoreGate
}

function Update-GuiCustomFilter {
    $q = ([string]$script:Ui.TbFilter.Text).Trim().ToLowerInvariant()
    foreach ($h in $script:CustomHeaders) { $h.Visibility = [System.Windows.Visibility]::Collapsed }
    foreach ($it in $script:CustomItems) {
        if (-not $q -or $it.Search.Contains($q)) {
            $it.Box.Visibility = [System.Windows.Visibility]::Visible
            if ($null -ne $it.Header) { $it.Header.Visibility = [System.Windows.Visibility]::Visible }
        }
        else { $it.Box.Visibility = [System.Windows.Visibility]::Collapsed }
    }
}

function Get-GuiCoreOnlyChecked {
    # Core-only image removals ticked in "Customize" while the mode is Lite: they break the Lite
    # promise, so they need the same warning + confirmation as Core (the builder gets -Yes).
    # Emits the items one by one (wrap the call in @()).
    if ((Get-GuiMode) -eq 'Core') { return }
    foreach ($it in $script:CustomItems) {
        if ($it.Kind -ne 'removal' -or $it.RMode -ne 'core') { continue }
        if ($it.Box.IsChecked -eq $true) { $it }
    }
}

function Test-GuiNeedsCoreConfirm {
    if ((Get-GuiMode) -eq 'Core') { return $true }
    return (@(Get-GuiCoreOnlyChecked).Count -gt 0)
}

function Update-GuiCoreGate {
    # Shows the Core warning for Core and for Lite builds with Core-only removals; a change between
    # those two situations clears the confirmation, because the text being confirmed changed.
    $kind = ''
    if ((Get-GuiMode) -eq 'Core') { $kind = 'core' }
    elseif (@(Get-GuiCoreOnlyChecked).Count -gt 0) { $kind = 'lite-core' }
    if ($kind -ne $script:CoreGateKind) {
        $script:CoreGateKind = $kind
        $script:Ui.CbCoreConfirm.IsChecked = $false
    }
    if ($kind) { $script:Ui.CoreWarning.Visibility = 'Visible' } else { $script:Ui.CoreWarning.Visibility = 'Collapsed' }
    Update-GuiCoreWarning
    Update-GuiNav
}

function Update-GuiCoreWarning {
    $lines = New-Object System.Collections.Generic.List[string]
    $liteCore = @(Get-GuiCoreOnlyChecked)
    if ($liteCore.Count -gt 0) {
        $script:Ui.TxtCoreWarningTitle.Text = 'Your Lite build includes Core-only removals'
        $script:Ui.TxtCoreConfirm.Text = 'I understand: these Core-only removals break what Lite normally keeps working, and some of them cannot be undone without building again.'
        $lines.Add(('- Ticked in "Customize": {0}.' -f ((@($liteCore | ForEach-Object { $_.Name })) -join ', ')))
        foreach ($it in $liteCore) {
            switch ([string]$it.Id) {
                'image.windows-update' { $lines.Add('- Windows Update is disabled: no more security updates, and Microsoft Store / Xbox Game Pass installs and updates stop working (they need the Windows Update service).') }
                'image.defender' { $lines.Add('- Microsoft Defender and the Windows Security app are removed: nothing scans your downloads unless you install another antivirus.') }
                'image.edge' { $lines.Add('- The Edge browser is removed (WebView2 and its updater stay, so the Xbox app and game launchers keep working). Install another browser.') }
                'image.winre' { $lines.Add('- The recovery environment (WinRE) is disabled after Setup: no "Reset this PC" and no automatic Startup Repair.') }
                default { $lines.Add(('- {0}: read its description in "Customize".' -f $it.Name)) }
            }
        }
        $lines.Add('- Untick them (or choose Core on purpose) if you want a normal, updatable Lite build.')
        $script:Ui.TxtCoreWarning.Text = ($lines.ToArray() -join [Environment]::NewLine)
        return
    }
    $script:Ui.TxtCoreWarningTitle.Text = 'Read this before you choose Core'
    $script:Ui.TxtCoreConfirm.Text = 'I understand: Core cannot be updated (I rebuild from a newer ISO instead) and has no Defender, no Edge browser and no recovery environment.'
    $lines.Add('- Not serviceable: Windows Update is disabled. To get a newer Windows, build again from a newer ISO.')
    $lines.Add('- Microsoft Store / Xbox Game Pass installs and updates stop working (they need the Windows Update service).')
    $lines.Add('- Microsoft Defender is removed. Nothing scans your downloads unless you install another antivirus.')
    $lines.Add('- The Edge browser is removed (WebView2 and its updater stay, so the Xbox app and game launchers keep working). Install another browser.')
    $lines.Add('- The recovery environment (WinRE) is disabled after Setup: no "Reset this PC" and no automatic Startup Repair.')
    $extreme = 0
    $coreOnly = New-Object System.Collections.Generic.List[string]
    foreach ($it in $script:CustomItems) {
        if (-not $it.DefCore -or $it.DefLite) { continue }
        if ($it.Kind -eq 'tweak') { $extreme++ } else { $coreOnly.Add($it.Name) }
    }
    if ($extreme -gt 0) { $lines.Add(('- {0} extreme tweaks are applied; some trade security or features for speed (see "Customize").' -f $extreme)) }
    if ($coreOnly.Count -gt 0) {
        $shown = @($coreOnly | Select-Object -First 10)
        $more = ''
        if ($coreOnly.Count -gt 10) { $more = (' and {0} more' -f ($coreOnly.Count - 10)) }
        $lines.Add(('- Removed only in Core: {0}{1}.' -f ($shown -join ', '), $more))
    }
    $lines.Add('- Some apps, games or anti-cheat systems may need a component that Core removes. If something does not work, use Lite.')
    $script:Ui.TxtCoreWarning.Text = ($lines.ToArray() -join [Environment]::NewLine)
}

function Update-GuiMode {
    Update-GuiInstallers
    Update-GuiCustomChecks
    Update-GuiCoreGate
}

function Update-GuiSpace {
    # Runs on every keystroke in the path boxes: a half-typed or invalid path just shows no info.
    try { Update-GuiSpaceCore }
    catch {
        $script:Ui.TxtSpace.Text = ''
        $script:Ui.TxtSpace.Foreground = Get-GuiBrush 'SubTextBrush'
    }
}

function Update-GuiSpaceCore {
    $parts = New-Object System.Collections.Generic.List[string]
    $low = $false
    $out = Get-GuiText $script:Ui.TbOutput
    $work = Get-GuiText $script:Ui.TbWorkDir
    if (-not $work) { $work = Get-GuiDefaultWorkDir }
    $workRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($work))
    # The ISO is downloaded BEFORE the build starts, so when it lands on the work drive the builder's
    # 30 GB check runs after those 8 GB are already used: ask for both up front.
    $isoOnWorkDrive = $false
    $dlRoot = ''
    if ($script:Ui.RbDownload.IsChecked -eq $true -and -not [System.IO.File]::Exists((Get-GuiDownloadTarget))) {
        $dlRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath((Get-GuiDownloadsFolder)))
        $isoOnWorkDrive = [string]::Equals($dlRoot, $workRoot, [System.StringComparison]::OrdinalIgnoreCase)
    }
    $workNeed = $script:WorkNeededBytes
    if ($isoOnWorkDrive) { $workNeed += $script:IsoNeededBytes }
    $wf = Get-GuiFreeBytes $work
    if ($wf -ge 0) {
        $needText = ('about {0} GB needed' -f [int]($workNeed / 1GB))
        if ($isoOnWorkDrive) { $needText += ' including the Windows download' }
        $parts.Add(('work folder drive {0} {1} free ({2})' -f $workRoot, (Format-GuiBytes $wf), $needText))
        if ($wf -lt $workNeed) { $low = $true }
    }
    if ($out) {
        $of = Get-GuiFreeBytes $out
        if ($of -ge 0) {
            $parts.Add(('output drive {0} {1} free (about 7 GB needed)' -f [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($out)), (Format-GuiBytes $of)))
            if ($of -lt $script:OutputNeededBytes) { $low = $true }
        }
    }
    if ($dlRoot -and -not $isoOnWorkDrive) {
        $df = Get-GuiFreeBytes (Get-GuiDownloadsFolder)
        if ($df -ge 0) {
            $parts.Add(('download drive {0} {1} free (about 8 GB needed)' -f $dlRoot, (Format-GuiBytes $df)))
            if ($df -lt $script:IsoNeededBytes) { $low = $true }
        }
    }
    $text = ''
    if ($parts.Count -gt 0) { $text = 'Free space: ' + ($parts.ToArray() -join '; ') + '.' }
    $script:Ui.TxtWorkLabel.Text = ('Work folder (optional; empty = {0}). Needs about 30 GB free on a local NTFS drive.' -f (Get-GuiDefaultWorkDir))
    if ($low) {
        $text += ' Not enough free space - free some up or choose another drive.'
        $script:Ui.TxtSpace.Foreground = Get-GuiBrush 'WarnBrush'
    }
    else { $script:Ui.TxtSpace.Foreground = Get-GuiBrush 'SubTextBrush' }
    $script:Ui.TxtSpace.Text = $text
}

function Test-GuiCanBuild {
    if ($null -ne $script:Child) { return $false }
    if ((Test-GuiNeedsCoreConfirm) -and $script:Ui.CbCoreConfirm.IsChecked -ne $true) { return $false }
    if (-not (Get-GuiText $script:Ui.TbOutput)) { return $false }
    return $true
}

# =============================================================================================
# Navigation
# =============================================================================================
function Set-GuiStep {
    param([int]$Step)
    $script:Step = $Step
    $pages = @($script:Ui.PageSource, $script:Ui.PageOptions, $script:Ui.PageBuild)
    $pills = @($script:Ui.Step1, $script:Ui.Step2, $script:Ui.Step3)
    for ($i = 0; $i -lt 3; $i++) {
        if ($i -eq $Step - 1) {
            $pages[$i].Visibility = [System.Windows.Visibility]::Visible
            $pills[$i].Background = Get-GuiBrush 'AccentBrush'
        }
        else {
            $pages[$i].Visibility = [System.Windows.Visibility]::Collapsed
            $pills[$i].Background = Get-GuiBrush 'ButtonBrush'
        }
    }
    Update-GuiNav
}

function Set-GuiVisible {
    param($Element, [bool]$Visible)
    if ($Visible) { $Element.Visibility = [System.Windows.Visibility]::Visible }
    else { $Element.Visibility = [System.Windows.Visibility]::Collapsed }
}

function Update-GuiNav {
    $running = ($null -ne $script:Child)
    $stopping = ($running -and $script:CancelRequested)
    $cleanupRunning = ($running -and $script:Child.Stage -eq 'cleanup')
    Set-GuiVisible $script:Ui.BtnBack (($script:Step -eq 2) -or ($script:Step -eq 3 -and -not $running))
    Set-GuiVisible $script:Ui.BtnNext ($script:Step -eq 1)
    Set-GuiVisible $script:Ui.BtnBuild ($script:Step -eq 2)
    $script:Ui.BtnBuild.IsEnabled = (Test-GuiCanBuild)
    Set-GuiVisible $script:Ui.BtnCancel ($script:Step -eq 3 -and $running -and -not $stopping -and -not $cleanupRunning)
    $forceOk = $false
    if ($stopping -and $null -ne $script:Child.StopAt) { $forceOk = (([DateTime]::UtcNow - $script:Child.StopAt).TotalSeconds -ge 8) -or $script:Child.StopFailed }
    Set-GuiVisible $script:Ui.BtnForceStop ($script:Step -eq 3 -and $forceOk)
    Set-GuiVisible $script:Ui.BtnCleanup ($script:Step -eq 3 -and -not $running -and ($script:Outcome -eq 'error' -or $script:Outcome -eq 'cancelled'))
    Set-GuiVisible $script:Ui.BtnNewBuild ($script:Step -eq 3 -and -not $running -and $script:Outcome -eq 'ok')
    $script:Ui.Step1.IsEnabled = -not $running
}

function Invoke-GuiNext {
    $why = Test-GuiSourceReady
    if ($why) {
        [void](Show-GuiMessage -Text $why -Icon 'Warning')
        return
    }
    Set-GuiStep 2
}

function Invoke-GuiBack {
    if ($null -ne $script:Child) { return }
    if ($script:Step -eq 3) { Set-GuiStep 2 }
    elseif ($script:Step -eq 2) { Set-GuiStep 1 }
}

# =============================================================================================
# Build plan and child processes
# =============================================================================================
function Get-GuiPlan {
    $p = @{}
    $p.Download = ($script:Ui.RbDownload.IsChecked -eq $true)
    $p.Language = ''
    $p.IsoTarget = ''
    $p.Redownload = $false
    $p.IsoPath = ''
    if ($p.Download) {
        $p.Language = [string]$script:Ui.CbLanguage.SelectedItem
        if (-not $p.Language) { throw 'Choose the Windows language on step 1.' }
        $p.IsoTarget = Get-GuiDownloadTarget
        $p.Redownload = ($script:Ui.CbRedownload.IsChecked -eq $true -and $script:Ui.CbRedownload.Visibility -eq 'Visible')
    }
    else {
        $iso = Get-GuiText $script:Ui.TbIsoPath
        $check = Test-GuiIsoFile -Path $iso
        if (-not $check.Valid) { throw ('The Windows ISO cannot be used: ' + $check.Text) }
        $p.IsoPath = [System.IO.Path]::GetFullPath($iso)
    }
    $p.Mode = Get-GuiMode
    if ((Test-GuiNeedsCoreConfirm) -and $script:Ui.CbCoreConfirm.IsChecked -ne $true) {
        if ($p.Mode -eq 'Core') { throw 'Read the Core warning and tick the confirmation box first (or choose Lite).' }
        throw 'Your Lite build includes Core-only removals: read the warning under Mode and tick its confirmation box, or untick those removals in "Customize".'
    }
    $p.Edition = [string]$script:Ui.CbEdition.SelectedItem
    if (-not $p.Edition) { $p.Edition = 'Windows 11 Pro' }
    $p.Installers = Get-GuiInstallersArg
    $p.Apps = Get-GuiAppsArg
    $ie = Get-GuiIncludeExclude
    $p.Include = $ie.Include
    $p.Exclude = $ie.Exclude
    $p.Bypass = ($script:Ui.CbBypass.IsChecked -eq $true)
    $p.KeepEncryption = ($script:Ui.CbKeepEncryption.IsChecked -eq $true)
    $out = Get-GuiText $script:Ui.TbOutput
    if (-not $out) { throw 'Choose the folder for the Lite OS ISO.' }
    $out = [System.IO.Path]::GetFullPath($out)
    if ([System.IO.File]::Exists($out)) { throw ('The output must be a folder, not a file: ' + $out) }
    $p.OutputFolder = $out
    # A folder: Build-LiteOS.ps1 names the ISO LiteOS-<mode>-<build>-<language>.iso and never
    # overwrites an existing file (it adds -2, -3, ...); the final path comes back in ##LITEOS-RESULT.
    $p.OutputPath = $out.TrimEnd('\') + '\'
    $work = Get-GuiText $script:Ui.TbWorkDir
    if ($work) {
        $work = [System.IO.Path]::GetFullPath($work)
        if ($work.StartsWith('\\')) { throw 'The work folder must be on a local drive.' }
    }
    $p.WorkDir = $work
    return $p
}

function Get-GuiBuildArgs {
    param($Plan, [string]$Iso)
    $a = New-Object System.Collections.Generic.List[string]
    foreach ($x in @('-IsoPath', $Iso, '-Mode', $Plan.Mode, '-Edition', $Plan.Edition, '-Installers', $Plan.Installers, '-Apps', $Plan.Apps)) { $a.Add([string]$x) }
    # powershell.exe -File passes each value as one string; the engine splits comma separated id lists.
    if (@($Plan.Include).Count -gt 0) { $a.Add('-Include'); $a.Add((@($Plan.Include) -join ',')) }
    if (@($Plan.Exclude).Count -gt 0) { $a.Add('-Exclude'); $a.Add((@($Plan.Exclude) -join ',')) }
    if (-not $Plan.Bypass) { $a.Add('-NoBypassRequirements') }
    if ($Plan.KeepEncryption) { $a.Add('-KeepAutoEncryption') }
    $a.Add('-OutputPath'); $a.Add($Plan.OutputPath)
    if ($Plan.WorkDir) { $a.Add('-WorkDir'); $a.Add($Plan.WorkDir) }
    $a.Add('-Yes')
    $a.Add('-ProgressProtocol')
    return , $a.ToArray()
}

function Get-GuiDownloadArgs {
    param($Plan)
    $a = New-Object System.Collections.Generic.List[string]
    foreach ($x in @('-Language', $Plan.Language, '-OutFile', $Plan.IsoTarget, '-ProgressProtocol', '-NoBrowser')) { $a.Add([string]$x) }
    $a.Add('-LogPath'); $a.Add((Join-Path $script:LogDir ('get-windowsiso-{0}.log' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))))
    if ($Plan.Redownload) { $a.Add('-Force') }
    return , $a.ToArray()
}

function Start-GuiChild {
    # Starts a hidden child powershell.exe with redirected output; Invoke-GuiTick reads it.
    param(
        [string]$Stage,
        [string]$ScriptPath,
        [string[]]$Arguments = @(),
        [string]$EncodedCommand,
        [int]$RangeStart = 0,
        [int]$RangeEnd = 100
    )
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($x in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass')) { $parts.Add($x) }
    if ($EncodedCommand) {
        $parts.Add('-EncodedCommand')
        $parts.Add($EncodedCommand)
        Write-GuiLog ('Starting {0} (inline cleanup script)' -f $Stage)
    }
    else {
        if (-not [System.IO.File]::Exists($ScriptPath)) { throw ('Missing file: {0}. Extract the whole Lite OS folder again.' -f $ScriptPath) }
        $parts.Add('-File')
        $parts.Add($ScriptPath)
        foreach ($x in @($Arguments)) { $parts.Add([string]$x) }
        Write-GuiLog ('Starting {0}: powershell.exe {1}' -f $Stage, (Join-GuiArgs -Arguments ($parts.ToArray())))
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PowerShellExe
    $psi.Arguments = Join-GuiArgs -Arguments ($parts.ToArray())
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:ChildEncoding
    $psi.StandardErrorEncoding = $script:ChildEncoding
    $psi.WorkingDirectory = $script:Root
    $proc = [System.Diagnostics.Process]::Start($psi)
    $script:Child = [pscustomobject]@{
        Stage       = $Stage
        Process     = $proc
        OutTask     = $proc.StandardOutput.ReadLineAsync()
        ErrTask     = $proc.StandardError.ReadLineAsync()
        OutDone     = $false
        ErrDone     = $false
        RangeStart  = $RangeStart
        RangeEnd    = $RangeEnd
        StartedAt   = [DateTime]::UtcNow
        ExitedAt    = $null
        StopAt      = $null
        StopFailed  = $false
        Result      = ''
        ResultPath  = ''
        ResultHash  = ''
        ResultError = ''
        Blocked     = $false
        Tail        = (New-Object System.Collections.Generic.List[string])
        LastLogPct  = -100
        LastLogMsg  = ''
    }
    Write-GuiLog ('{0} started (process {1})' -f $Stage, $proc.Id)
    Update-GuiNav
}

function Add-GuiLogText {
    param([string]$Text)
    $tb = $script:Ui.TbLog
    $tb.AppendText($Text)
    if ($tb.Text.Length -gt 400000) { $tb.Text = $tb.Text.Substring($tb.Text.Length - 250000) }
    $tb.ScrollToEnd()
}

function Set-GuiProgress {
    param([double]$Percent, [string]$Message)
    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    $script:Ui.PbBuild.Value = $Percent
    $script:Ui.TxtPercent.Text = ('{0}%' -f [int][math]::Floor($Percent))
    if ($null -ne $Message) { $script:Ui.TxtStatus.Text = $Message }
}

function Receive-GuiLine {
    param($Child, [AllowEmptyString()][string]$Line, [bool]$IsError, [System.Text.StringBuilder]$Sink)
    $p = Get-GuiProgressLine -Line $Line
    if ($null -ne $p) {
        if ($p.Kind -eq 'progress') {
            $overall = $Child.RangeStart + (($Child.RangeEnd - $Child.RangeStart) * $p.Percent / 100.0)
            Set-GuiProgress -Percent $overall -Message $p.Message
            # Log step changes; download speed updates only every 10 percent.
            $key = ($p.Message -replace '[\d.,:/]+', '#')
            if ($key -ne $Child.LastLogMsg -or ($p.Percent - $Child.LastLogPct) -ge 10 -or $p.Percent -eq 100) {
                $Child.LastLogMsg = $key
                $Child.LastLogPct = $p.Percent
                [void]$Sink.AppendLine(('[{0,3}%] {1}' -f $p.Percent, $p.Message))
                Write-GuiLog ('[{0}] {1}% {2}' -f $Child.Stage, $p.Percent, $p.Message) 'Child'
            }
            return
        }
        if ($p.Kind -eq 'ok') {
            $Child.Result = 'ok'
            $Child.ResultPath = $p.Path
            $Child.ResultHash = $p.Hash
            [void]$Sink.AppendLine(('[result] ok {0} {1}' -f $p.Path, $p.Hash))
            Write-GuiLog ('[{0}] RESULT ok {1} {2}' -f $Child.Stage, $p.Path, $p.Hash) 'Child'
            return
        }
        $Child.Result = 'error'
        $Child.ResultError = $p.Message
        [void]$Sink.AppendLine(('[result] error {0}' -f $p.Message))
        Write-GuiLog ('[{0}] RESULT error {1}' -f $Child.Stage, $p.Message) 'Child'
        return
    }
    if ($Line -match '715-123130') { $Child.Blocked = $true }
    $prefix = ''
    if ($IsError) { $prefix = '! ' }
    [void]$Sink.AppendLine($prefix + $Line)
    if ($Line.Trim()) {
        $Child.Tail.Add($prefix + $Line)
        if ($Child.Tail.Count -gt 60) { $Child.Tail.RemoveAt(0) }
    }
    Write-GuiLog ('[{0}] {1}{2}' -f $Child.Stage, $prefix, $Line) 'Child'
}

function Read-GuiChildStream {
    # Drains completed ReadLineAsync results without blocking. Returns $true at end of stream.
    param($Child, [bool]$IsError, [System.Text.StringBuilder]$Sink)
    $budget = 500
    while ($budget -gt 0) {
        $budget--
        $task = $Child.OutTask
        if ($IsError) { $task = $Child.ErrTask }
        if (-not $task.IsCompleted) { return $false }
        if ($task.IsFaulted -or $task.IsCanceled) { return $true }
        $line = $task.Result
        if ($null -eq $line) { return $true }
        Receive-GuiLine -Child $Child -Line $line -IsError $IsError -Sink $Sink
        if ($IsError) { $Child.ErrTask = $Child.Process.StandardError.ReadLineAsync() }
        else { $Child.OutTask = $Child.Process.StandardOutput.ReadLineAsync() }
    }
    return $false
}

function Invoke-GuiTick {
    try {
        $c = $script:Child
        if ($null -ne $script:StopHelper -and $script:StopHelper.HasExited) {
            $code = $script:StopHelper.ExitCode
            $script:StopHelper.Dispose()
            $script:StopHelper = $null
            if ($code -eq 0) { Write-GuiLog 'Stop signal (Ctrl+C) sent to the builder; waiting for it to clean up.' }
            else {
                Write-GuiLog ('Could not send the stop signal (helper exit code {0}). Use "Force stop".' -f $code) 'Warn'
                if ($null -ne $c) { $c.StopFailed = $true }
            }
        }
        $kh = $script:KillHelper
        if ($null -ne $kh) {
            if ($kh.Process.HasExited) {
                $kcode = -1
                try { $kcode = $kh.Process.ExitCode } catch { $kcode = -1 }
                try { $kh.Process.Dispose() } catch { $null = $_ }
                $script:KillHelper = $null
                Write-GuiLog ('taskkill finished (exit code {0}).' -f $kcode)
            }
            elseif (-not $kh.Warned -and ([DateTime]::UtcNow - $kh.StartedAt).TotalSeconds -gt 15) {
                $kh.Warned = $true
                Write-GuiLog 'taskkill did not finish within 15 s; the window keeps working, the builder may still be ending.' 'Warn'
            }
        }
        if ($null -eq $c) { return }
        $sink = New-Object System.Text.StringBuilder
        if (-not $c.OutDone) { $c.OutDone = Read-GuiChildStream -Child $c -IsError $false -Sink $sink }
        if (-not $c.ErrDone) { $c.ErrDone = Read-GuiChildStream -Child $c -IsError $true -Sink $sink }
        if ($sink.Length -gt 0) { Add-GuiLogText $sink.ToString() }
        if ($null -ne $script:BuildStartedAt) {
            $script:Ui.TxtElapsed.Text = ('Elapsed {0}' -f (Format-GuiDuration ([DateTime]::UtcNow - $script:BuildStartedAt)))
        }
        if ($script:CancelRequested) { Update-GuiNav }
        if ($c.Process.HasExited) {
            if ($null -eq $c.ExitedAt) { $c.ExitedAt = [DateTime]::UtcNow }
            # A grandchild that inherited the pipes can keep them open: stop waiting after 8 s.
            if (($c.OutDone -and $c.ErrDone) -or ([DateTime]::UtcNow - $c.ExitedAt).TotalSeconds -gt 8) { Complete-GuiChild -Child $c }
        }
    }
    catch {
        if (-not $script:TickErrorShown) {
            $script:TickErrorShown = $true
            Write-GuiLog ('Progress update failed: {0} | {1}' -f $_.Exception.Message, ($_.ScriptStackTrace -replace "`r?`n", ' <- ')) 'Error'
        }
    }
}

function Complete-GuiChild {
    param($Child)
    $script:Child = $null
    $code = -1
    try { $code = $Child.Process.ExitCode } catch { $code = -1 }
    try { $Child.Process.Dispose() } catch { $null = $_ }
    Write-GuiLog ('{0} finished (exit code {1}, result {2})' -f $Child.Stage, $code, $Child.Result)

    if ($Child.Stage -eq 'cleanup') {
        Add-GuiLogText ('--- Cleanup finished (exit code {0}) ---{1}' -f $code, [Environment]::NewLine)
        $script:Ui.TxtStatus.Text = 'Cleanup finished. Details are in the log below.'
        Update-GuiNav
        [void](Show-GuiMessage -Text 'Cleanup finished. Details are in the log.')
        return
    }

    if ($script:CancelRequested -or $script:ForceStopped) {
        if ($Child.Stage -eq 'download') { Remove-GuiBitsJobs }
        $text = 'The builder was stopped and cleaned up after itself.'
        if ($script:ForceStopped) { $text = 'The builder was force-stopped. A mounted image, loaded registry hives or an attached ISO may be left behind: click "Cleanup leftovers" to remove them.' }
        Show-GuiFailure -Title 'Build stopped' -Text $text -Outcome 'cancelled'
        Complete-GuiRun
        return
    }

    if ($Child.Stage -eq 'download') {
        $plan = $script:Plan
        $check = Test-GuiIsoFile -Path $plan.IsoTarget
        if ($code -eq 0 -and $check.Valid) {
            Add-GuiLogText ('--- Windows 11 ISO ready: {0} ---{1}' -f $plan.IsoTarget, [Environment]::NewLine)
            $plan.IsoPath = $plan.IsoTarget
            try { Start-GuiBuildStage -Plan $plan }
            catch {
                Show-GuiFailure -Title 'Could not start the builder' -Text $_.Exception.Message
                Complete-GuiRun
            }
            Update-DownloadInfoSafe
            return
        }
        if ($Child.Blocked) {
            $text = 'Microsoft refused the download for your country or network (message code 715-123130). Open the Microsoft download page in your browser, download "Windows 11 (multi-edition ISO for x64 devices)" in your language there, then click "Use my ISO instead" and pick the file.'
            Show-GuiFailure -Title 'Microsoft blocked the download' -Text $text -Blocked $true
        }
        else {
            Show-GuiFailure -Title 'The Windows 11 download failed' -Text (Get-GuiTailText $Child) -Blocked $true
        }
        Complete-GuiRun
        return
    }

    # build
    if ($Child.Result -eq 'ok') {
        Show-GuiResult -Path (Resolve-GuiResultPath -Reported $Child.ResultPath -Folder ([string]$script:Plan.OutputFolder)) -Hash $Child.ResultHash
    }
    elseif ($Child.Result -eq 'error') {
        $msg = $Child.ResultError
        if (-not $msg) { $msg = Get-GuiTailText $Child }
        Show-GuiFailure -Title 'The build failed' -Text ($msg + [Environment]::NewLine + [Environment]::NewLine + 'The builder undoes its mounts by itself. If something was left behind, click "Cleanup leftovers".')
    }
    elseif ($code -eq 0) {
        Show-GuiFailure -Title 'The builder ended without a result' -Text ('Build-LiteOS.ps1 exited without reporting a result line. ' + (Get-GuiTailText $Child))
    }
    else {
        Show-GuiFailure -Title 'The build failed' -Text (('Build-LiteOS.ps1 stopped with exit code {0}. ' -f $code) + (Get-GuiTailText $Child))
    }
    Complete-GuiRun
}

function Update-DownloadInfoSafe {
    try { Update-GuiDownloadInfo } catch { $null = $_ }
}

function Complete-GuiRun {
    Set-GuiKeepAwake $false
    $script:CancelRequested = $false
    $script:ForceStopped = $false
    Update-DownloadInfoSafe
    Update-GuiNav
    if ($script:CloseAfterExit) {
        $script:CloseAfterExit = $false
        $script:Window.Close()
    }
}

function Get-GuiTailText {
    param($Child)
    $lines = @($Child.Tail.ToArray())
    $err = @($lines | Where-Object { $_ -match '(?i)error|failed|cannot|refused|not found' } | Select-Object -Last 4)
    if ($err.Count -eq 0) { $err = @($lines | Select-Object -Last 4) }
    if ($err.Count -eq 0) { return 'See the log below.' }
    return (($err -join [Environment]::NewLine) + [Environment]::NewLine + 'See the log below for details.')
}

function Resolve-GuiResultPath {
    # The child's stdout uses the console (OEM) code page, so folder names with characters outside it
    # (e.g. a Persian or Cyrillic user folder) arrive as '?'. The ISO file name itself is ASCII
    # (LiteOS-<mode>-<build>-<lang>[-n].iso) and the GUI knows the folder it passed: rebuild the path.
    param([string]$Reported, [string]$Folder)
    try {
        if ($Reported -and [System.IO.File]::Exists($Reported)) { return $Reported }
        if (-not $Folder -or -not $Reported) { return $Reported }
        $leaf = ($Reported -split '[\\/]')[-1]
        if (-not $leaf -or $leaf -notmatch '^[A-Za-z0-9._\-]+\.iso$') { return $Reported }
        $candidate = Join-Path $Folder $leaf
        if ([System.IO.File]::Exists($candidate)) {
            Write-GuiLog ('Result path rebuilt from the output folder: {0}' -f $candidate)
            return $candidate
        }
    }
    catch { $null = $_ }
    return $Reported
}

function Show-GuiResult {
    param([string]$Path, [string]$Hash)
    $script:Outcome = 'ok'
    Set-GuiProgress -Percent 100 -Message 'Done.'
    $script:Ui.TxtStage.Text = ('{0} {1} is ready' -f $script:BrandName, $script:Plan.Mode)
    $script:Ui.TbResultPath.Text = $Path
    $script:Ui.TbResultHash.Text = $Hash
    $note = 'Install it on the PC you want, then activate Windows with your own license.'
    if ($script:Plan.Download) { $note += (' The Windows 11 ISO from Microsoft stays at {0} for your next build (you can delete it).' -f $script:Plan.IsoTarget) }
    $script:Ui.TxtResultNote.Text = $note
    Set-GuiVisible $script:Ui.PanelResult $true
    Set-GuiVisible $script:Ui.PanelError $false
    Write-GuiLog ('Lite OS ISO: {0} SHA256 {1}' -f $Path, $Hash)
}

function Show-GuiFailure {
    param([string]$Title, [string]$Text, [bool]$Blocked = $false, [string]$Outcome = 'error')
    $script:Outcome = $Outcome
    $script:Ui.TxtStage.Text = $Title
    $script:Ui.TxtStatus.Text = ''
    $script:Ui.TxtErrorTitle.Text = $Title
    $script:Ui.TxtErrorText.Text = $Text
    Set-GuiVisible $script:Ui.BtnErrOpenMs $Blocked
    Set-GuiVisible $script:Ui.BtnErrUseIso $Blocked
    Set-GuiVisible $script:Ui.PanelError $true
    Set-GuiVisible $script:Ui.PanelResult $false
    Write-GuiLog ('{0}: {1}' -f $Title, ($Text -replace "`r?`n", ' | ')) 'Warn'
}

function Start-GuiBuildStage {
    param($Plan)
    $start = 0
    if ($Plan.Download) { $start = $script:DownloadShare }
    $script:Ui.TxtStage.Text = ('Building {0} {1}' -f $script:BrandName, $Plan.Mode)
    Set-GuiProgress -Percent $start -Message 'Starting the builder'
    Start-GuiChild -Stage 'build' -ScriptPath $script:Paths.Build -Arguments (Get-GuiBuildArgs -Plan $Plan -Iso $Plan.IsoPath) -RangeStart $start -RangeEnd 100
}

function Start-GuiBuild {
    if ($null -ne $script:Child) { return }
    $plan = Get-GuiPlan
    $nl = [Environment]::NewLine
    $source = ('your ISO {0}' -f $plan.IsoPath)
    if ($plan.Download) { $source = ('download Windows 11 ({0}) from Microsoft' -f $plan.Language) }
    $space = 'about 30 GB of free space'
    if ($plan.Download) { $space += ' (plus about 8 GB for the Windows download)' }
    $q = ('Build {0} {1} now?{2}{2}Source: {3}{2}Edition: {4}{2}Output folder: {5}{2}{2}This takes about 20 to 60 minutes and needs {6}. Your PC stays awake until it is done.' -f $script:BrandName, $plan.Mode, $nl, $source, $plan.Edition, $plan.OutputFolder, $space)
    if ((Show-GuiMessage -Text $q -Buttons 'YesNo' -Icon 'Question') -ne 'Yes') { return }
    [void][System.IO.Directory]::CreateDirectory($plan.OutputFolder)

    $script:Plan = $plan
    $script:Outcome = ''
    $script:CancelRequested = $false
    $script:ForceStopped = $false
    $script:BuildStartedAt = [DateTime]::UtcNow
    $script:Ui.TbLog.Clear()
    Set-GuiVisible $script:Ui.PanelResult $false
    Set-GuiVisible $script:Ui.PanelError $false
    $script:Ui.TxtElapsed.Text = ''
    Set-GuiProgress -Percent 0 -Message ''
    Set-GuiStep 3
    Write-GuiLog ('Build plan: {0}' -f (ConvertTo-Json -InputObject $plan -Compress))
    Set-GuiKeepAwake $true
    try {
        if ($plan.Download) {
            $script:Ui.TxtStage.Text = 'Downloading Windows 11 from Microsoft'
            Set-GuiProgress -Percent 0 -Message 'Contacting Microsoft'
            Start-GuiChild -Stage 'download' -ScriptPath $script:Paths.GetIso -Arguments (Get-GuiDownloadArgs -Plan $plan) -RangeStart 0 -RangeEnd $script:DownloadShare
        }
        else {
            Start-GuiBuildStage -Plan $plan
        }
    }
    catch {
        Show-GuiFailure -Title 'Could not start' -Text $_.Exception.Message
        Complete-GuiRun
    }
}

# =============================================================================================
# Cancel / force stop / cleanup
# =============================================================================================
function Send-GuiCtrlC {
    # Ctrl+C makes the child PowerShell stop like a user pressing Ctrl+C: its finally blocks run, so
    # Build-LiteOS.ps1 discards the mounted image and unloads its hives itself. A tiny helper process
    # attaches to the child's (hidden) console and raises the event there.
    param([int]$ProcessId, [int64]$StartTicks)
    $code = @'
# Only the process Lite OS Builder started (same id AND start time), never a reused process id.
$p = Get-Process -Id __PID__ -ErrorAction SilentlyContinue
if ($null -eq $p) { exit 4 }
try { if ($p.StartTime.ToUniversalTime().Ticks -ne __TICKS__) { exit 4 } } catch { exit 4 }
$sig = '[DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint p);' +
       '[DllImport("kernel32.dll", SetLastError = true)] public static extern bool FreeConsole();' +
       '[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleCtrlHandler(System.IntPtr h, bool add);' +
       '[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GenerateConsoleCtrlEvent(uint e, uint g);'
$k = Add-Type -MemberDefinition $sig -Name 'CtrlC' -Namespace 'LiteOSBuilderStop' -PassThru
[void]$k::FreeConsole()
if (-not $k::AttachConsole(__PID__)) { exit 2 }
[void]$k::SetConsoleCtrlHandler([System.IntPtr]::Zero, $true)
$ok = $k::GenerateConsoleCtrlEvent(0, 0)
Start-Sleep -Milliseconds 500
[void]$k::FreeConsole()
if ($ok) { exit 0 }
exit 3
'@
    $code = $code.Replace('__PID__', [string]$ProcessId).Replace('__TICKS__', [string]$StartTicks)
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($code))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PowerShellExe
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $enc
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $script:StopHelper = [System.Diagnostics.Process]::Start($psi)
}

function Request-GuiStop {
    param([switch]$NoConfirm)
    $c = $script:Child
    if ($null -eq $c -or $c.Stage -eq 'cleanup' -or $script:CancelRequested) { return }
    if (-not $NoConfirm) {
        $q = 'Stop the build? The builder undoes its changes (unmounts the image, unloads hives) before it exits; this can take a few minutes.'
        if ((Show-GuiMessage -Text $q -Buttons 'YesNo' -Icon 'Question') -ne 'Yes') { return }
        # The child may have finished while the question was open.
        if (-not [object]::ReferenceEquals($script:Child, $c) -or $c.Process.HasExited) { return }
    }
    $script:CancelRequested = $true
    $c.StopAt = [DateTime]::UtcNow
    $script:Ui.TxtStatus.Text = 'Stopping - the builder is cleaning up (unmounting the image). This can take a few minutes.'
    Write-GuiLog ('Stop requested for {0} (process {1})' -f $c.Stage, $c.Process.Id) 'Warn'
    try { Send-GuiCtrlC -ProcessId $c.Process.Id -StartTicks $c.Process.StartTime.ToUniversalTime().Ticks }
    catch {
        Write-GuiLog ('Could not start the stop helper: {0}' -f $_.Exception.Message) 'Warn'
        $c.StopFailed = $true
    }
    Update-GuiNav
}

function Stop-GuiChildForce {
    param([switch]$NoConfirm)
    $c = $script:Child
    if ($null -eq $c) { return }
    if (-not $NoConfirm) {
        $q = 'Force stop kills the builder immediately. A mounted image, loaded registry hives or an attached ISO may be left behind; click "Cleanup leftovers" afterwards. Force stop now?'
        if ((Show-GuiMessage -Text $q -Buttons 'YesNo' -Icon 'Warning') -ne 'Yes') { return }
    }
    # This process holds a handle to the child, so its id cannot be reused while it is listed here.
    if (-not [object]::ReferenceEquals($script:Child, $c) -or $c.Process.HasExited) { return }
    $script:ForceStopped = $true
    $script:CancelRequested = $true
    if ($null -eq $c.StopAt) { $c.StopAt = [DateTime]::UtcNow }
    Write-GuiLog ('Force stop: taskkill /T /F /PID {0}' -f $c.Process.Id) 'Warn'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    $psi.Arguments = ('/PID {0} /T /F' -f $c.Process.Id)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    # Never wait on the UI thread: Invoke-GuiTick checks the helper (like the Ctrl+C helper).
    if ($null -ne $script:KillHelper) { try { $script:KillHelper.Process.Dispose() } catch { $null = $_ } }
    $script:KillHelper = [pscustomobject]@{ Process = [System.Diagnostics.Process]::Start($psi); StartedAt = [DateTime]::UtcNow; Warned = $false }
    Update-GuiNav
}

function Remove-GuiBitsJobs {
    # Only Lite OS's own download job: a killed download must not keep running in the background.
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        foreach ($j in @(Get-BitsTransfer -ErrorAction Stop | Where-Object { $_.DisplayName -eq $script:BitsDisplayName })) {
            Remove-BitsTransfer -BitsJob $j -ErrorAction Stop
            Write-GuiLog ('Removed the unfinished Windows download (BITS job {0}).' -f $j.JobId)
        }
    }
    catch { Write-GuiLog ('BITS cleanup: {0}' -f $_.Exception.Message) 'Warn' }
}

function Start-GuiCleanup {
    if ($null -ne $script:Child) { return }
    $work = Get-GuiText $script:Ui.TbWorkDir
    if ($script:Plan -and $script:Plan.WorkDir) { $work = $script:Plan.WorkDir }
    if (-not $work) { $work = Get-GuiDefaultWorkDir }
    $work = [System.IO.Path]::GetFullPath($work).TrimEnd('\')
    $iso = ''
    if ($script:Plan) { $iso = [string]$script:Plan.IsoPath; if (-not $iso) { $iso = [string]$script:Plan.IsoTarget } }
    $nl = [Environment]::NewLine
    $q = ('Clean up what an interrupted build may have left behind?{0}{0}- unload Lite OS registry hives (HKLM\LITE_*){0}- discard Windows images mounted by DISM inside {1}{0}- detach the Windows ISO if it is still attached{0}- remove an unfinished Lite OS download (BITS){0}- run dism /Cleanup-Wim{0}{0}Nothing outside the Lite OS work folder is touched.' -f $nl, $work)
    if ((Show-GuiMessage -Text $q -Buttons 'YesNo' -Icon 'Question') -ne 'Yes') { return }
    $deleteWork = $false
    if ([System.IO.Directory]::Exists($work)) {
        $q2 = ('Also delete the work folder {0}? It is deleted only if it contains the Lite OS marker file and nothing is mounted in it any more.' -f $work)
        $deleteWork = ((Show-GuiMessage -Text $q2 -Buttons 'YesNo' -Icon 'Question') -eq 'Yes')
    }
    $cleanupCode = @'
$ErrorActionPreference = 'Continue'
$work = __WORK__
$iso = __ISO__
$deleteWork = __DELETE__
$jobName = __JOB__
function Say([int]$p, [string]$m) { Write-Output ('##LITEOS-PROGRESS {0} {1}' -f $p, $m) }
# List loaded hives with reg.exe (as Build-LiteOS.ps1 and build-test.yml do): Get-ChildItem on the
# registry provider would open a handle on every hive root and make "reg unload" fail.
function Get-LiteHives {
    $names = @()
    foreach ($line in @(& reg.exe query HKLM 2>$null)) {
        $m = [regex]::Match([string]$line, '^HKEY_LOCAL_MACHINE\\(LITE_\w+)\s*$', 'IgnoreCase')
        if ($m.Success) { $names += $m.Groups[1].Value }
    }
    $names
}
function Get-WorkMounts {
    $info = @(& dism.exe /English /Get-MountedImageInfo 2>&1 | ForEach-Object { [string]$_ })
    $dirs = @($info | Where-Object { $_ -match '^\s*Mount Dir\s*:' } | ForEach-Object { ($_ -replace '^\s*Mount Dir\s*:\s*', '').Trim() })
    @($dirs | Where-Object { $_.StartsWith($work + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $_ -ieq $work })
}
Say 5 'Unloading Lite OS registry hives'
$hives = @(Get-LiteHives)
if ($hives.Count -eq 0) { 'No Lite OS registry hives are loaded.' }
foreach ($h in $hives) {
    'reg unload HKLM\' + $h
    for ($try = 1; $try -le 6; $try++) {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        $out = @(& reg.exe unload ('HKLM\' + $h) 2>&1 | ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -eq 0 -or -not (@(Get-LiteHives) -contains $h)) { '  unloaded'; break }
        if ($try -eq 6) { $out | ForEach-Object { '  ' + $_ }; '  still loaded: close Registry Editor or restart Windows, then run the cleanup again.' }
        else { Start-Sleep -Seconds 2 }
    }
}
Say 25 'Discarding mounted Lite OS images'
$mounts = Get-WorkMounts
if ($mounts.Count -eq 0) { 'No Windows image is mounted inside ' + $work + '.' }
foreach ($d in $mounts) {
    'dism /Unmount-Image /MountDir:' + $d + ' /Discard'
    & dism.exe /English /Unmount-Image ('/MountDir:' + $d) /Discard 2>&1 | ForEach-Object { '  ' + [string]$_ }
}
Say 55 'Detaching the Windows ISO'
if ($iso -and (Test-Path -LiteralPath $iso)) {
    try {
        $di = Get-DiskImage -ImagePath $iso -ErrorAction Stop
        if ($di.Attached) { Dismount-DiskImage -ImagePath $iso -ErrorAction Stop | Out-Null; 'Detached ' + $iso }
        else { 'The Windows ISO is not attached.' }
    }
    catch { 'Could not check the ISO: ' + $_.Exception.Message }
}
Say 65 'Removing an unfinished download'
try {
    Import-Module BitsTransfer -ErrorAction Stop
    foreach ($j in @(Get-BitsTransfer -ErrorAction Stop | Where-Object { $_.DisplayName -eq $jobName })) { Remove-BitsTransfer -BitsJob $j; 'Removed BITS job ' + $j.JobId }
}
catch { 'BITS: ' + $_.Exception.Message }
Say 75 'dism /Cleanup-Wim'
& dism.exe /English /Cleanup-Wim 2>&1 | ForEach-Object { '  ' + [string]$_ }
if ($deleteWork -and (Test-Path -LiteralPath $work)) {
    Say 90 'Deleting the work folder'
    if ((Get-WorkMounts).Count -gt 0 -or (Get-LiteHives).Count -gt 0) { 'Work folder kept: an image or registry hive is still in use. Restart Windows and run the cleanup again.' }
    elseif (-not (Test-Path -LiteralPath (Join-Path $work '.liteos-workdir'))) { 'Work folder kept: it has no Lite OS marker file (.liteos-workdir).' }
    else {
        & cmd.exe /d /c rmdir /s /q $work 2>&1 | ForEach-Object { '  ' + [string]$_ }
        if (Test-Path -LiteralPath $work) { 'Some files could not be deleted (in use). Restart Windows and delete ' + $work + ' yourself.' }
        else { 'Deleted ' + $work }
    }
}
Say 100 'Cleanup finished'
'@
    $deleteLiteral = '$false'
    if ($deleteWork) { $deleteLiteral = '$true' }
    $cleanupCode = $cleanupCode.Replace('__WORK__', (ConvertTo-GuiPsLiteral $work)).Replace('__ISO__', (ConvertTo-GuiPsLiteral $iso)).Replace('__DELETE__', $deleteLiteral).Replace('__JOB__', (ConvertTo-GuiPsLiteral $script:BitsDisplayName))
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cleanupCode))
    $script:Ui.TxtStage.Text = 'Cleaning up leftovers'
    Set-GuiProgress -Percent 0 -Message 'Starting the cleanup'
    Set-GuiVisible $script:Ui.PanelError $false
    Add-GuiLogText ('--- Cleanup leftovers (work folder {0}) ---{1}' -f $work, $nl)
    Write-GuiLog ('Cleanup leftovers: work={0} iso={1} deleteWork={2}' -f $work, $iso, $deleteWork)
    Start-GuiChild -Stage 'cleanup' -EncodedCommand $enc -RangeStart 0 -RangeEnd 100
}

function Invoke-GuiClosing {
    param($Cancelable)
    $c = $script:Child
    if ($null -eq $c) { return }
    if ($c.Stage -eq 'cleanup') {
        [void](Show-GuiMessage -Text 'The cleanup is still running. Please wait until it finishes.' -Icon 'Information')
        $Cancelable.Cancel = $true
        return
    }
    if ($script:CancelRequested) {
        $q = 'The builder is still cleaning up. Force stop it and close? (Use "Cleanup leftovers" next time if something is left behind.)'
        $answer = Show-GuiMessage -Text $q -Buttons 'YesNo' -Icon 'Warning'
        if ($null -eq $script:Child) {
            if ($answer -ne 'Yes') { $Cancelable.Cancel = $true }
            return
        }
        if ($answer -eq 'Yes') {
            Stop-GuiChildForce -NoConfirm
            $script:CloseAfterExit = $true
        }
        $Cancelable.Cancel = $true
        return
    }
    $q2 = 'A build is running. Stop it and close Lite OS Builder?'
    $answer = Show-GuiMessage -Text $q2 -Buttons 'YesNo' -Icon 'Question'
    if ($null -eq $script:Child) {
        # It finished while the question was open: close (Yes) or stay (No).
        if ($answer -ne 'Yes') { $Cancelable.Cancel = $true }
        return
    }
    if ($answer -eq 'Yes') {
        Request-GuiStop -NoConfirm
        $script:CloseAfterExit = $true
    }
    $Cancelable.Cancel = $true
}

# =============================================================================================
# Create the window
# =============================================================================================
try {
    $script:Window = [System.Windows.Markup.XamlReader]::Parse($script:Xaml)
    foreach ($n in $script:ControlNames) {
        $el = $script:Window.FindName($n)
        if ($null -eq $el) { throw ("XAML element '{0}' is missing" -f $n) }
        $script:Ui[$n] = $el
    }
}
catch {
    Write-GuiLog ('The window could not be created: {0}' -f $_.Exception.Message) 'Error'
    try { [void][System.Windows.MessageBox]::Show(('Lite OS Builder could not create its window:' + [Environment]::NewLine + $_.Exception.Message), 'Lite OS Builder', 'OK', 'Error') } catch { $null = $_ }
    exit 1
}

$script:Window.Title = $script:BrandName + ' Builder'
$script:Ui.TxtTitle.Text = $script:BrandName
$script:Ui.TxtVersion.Text = ('v' + $script:GuiVersion)

foreach ($l in $script:IsoLanguages) { [void]$script:Ui.CbLanguage.Items.Add($l) }
$script:Ui.CbLanguage.SelectedItem = 'English (United States)'
foreach ($e in $script:Editions) { [void]$script:Ui.CbEdition.Items.Add($e) }
$script:Ui.CbEdition.SelectedIndex = 0

$defaultOut = $OutputFolder
if ([string]::IsNullOrWhiteSpace($defaultOut)) { $defaultOut = Get-GuiDownloadsFolder }
$script:Ui.TbOutput.Text = $defaultOut
if ($IsoPath) {
    $script:Ui.RbIso.IsChecked = $true
    $script:Ui.TbIsoPath.Text = $IsoPath
}
if ($Mode -eq 'Core') { $script:Ui.RbCore.IsChecked = $true }

Initialize-GuiApps
Initialize-GuiCustomize

# --- events ---
$script:Ui.RbDownload.Add_Checked({ Invoke-GuiAction { Update-GuiSource } })
$script:Ui.RbIso.Add_Checked({ Invoke-GuiAction { Update-GuiSource } })
$script:Ui.CbLanguage.Add_SelectionChanged({ Invoke-GuiAction { Update-GuiDownloadInfo; Update-GuiSpace } })
$script:Ui.TbIsoPath.Add_TextChanged({ Invoke-GuiAction { Update-GuiIsoInfo } })
$script:Ui.BtnBrowseIso.Add_Click({ Invoke-GuiAction { Invoke-GuiBrowseIso } })
$script:Ui.BtnOpenMsPage.Add_Click({ Invoke-GuiAction { Open-GuiUrl $script:MsDownloadPage } })

$script:Ui.RbLite.Add_Checked({ Invoke-GuiAction { Update-GuiMode } })
$script:Ui.RbCore.Add_Checked({ Invoke-GuiAction { Update-GuiMode } })
$script:Ui.CbCoreConfirm.Add_Click({ Invoke-GuiAction { Update-GuiNav } })
$script:Ui.BtnAppsRecommended.Add_Click({ Invoke-GuiAction { Select-GuiRecommendedApps } })
$script:Ui.TbOutput.Add_TextChanged({ Invoke-GuiAction { Update-GuiSpace; Update-GuiNav } })
$script:Ui.TbWorkDir.Add_TextChanged({ Invoke-GuiAction { Update-GuiSpace } })
$script:Ui.BtnBrowseOutput.Add_Click({
        Invoke-GuiAction {
            $f = Select-GuiFolder -Start (Get-GuiText $script:Ui.TbOutput) -Description 'Folder for the Lite OS ISO'
            if ($f) { $script:Ui.TbOutput.Text = $f }
        }
    })
$script:Ui.BtnBrowseWork.Add_Click({
        Invoke-GuiAction {
            $f = Select-GuiFolder -Start (Get-GuiText $script:Ui.TbWorkDir) -Description 'Work folder on a local NTFS drive with about 30 GB free'
            if ($f) { $script:Ui.TbWorkDir.Text = $f }
        }
    })
$script:Ui.TbFilter.Add_TextChanged({ Invoke-GuiAction { Update-GuiCustomFilter } })
$script:Ui.BtnResetCustom.Add_Click({ Invoke-GuiAction { $script:Overrides.Clear(); Update-GuiCustomChecks } })

$script:Ui.BtnBack.Add_Click({ Invoke-GuiAction { Invoke-GuiBack } })
$script:Ui.BtnNext.Add_Click({ Invoke-GuiAction { Invoke-GuiNext } })
$script:Ui.BtnBuild.Add_Click({ Invoke-GuiAction { Start-GuiBuild } })
$script:Ui.BtnNewBuild.Add_Click({ Invoke-GuiAction { Set-GuiStep 2 } })
$script:Ui.BtnCancel.Add_Click({ Invoke-GuiAction { Request-GuiStop } })
$script:Ui.BtnForceStop.Add_Click({ Invoke-GuiAction { Stop-GuiChildForce } })
$script:Ui.BtnCleanup.Add_Click({ Invoke-GuiAction { Start-GuiCleanup } })

$script:Ui.BtnOpenFolder.Add_Click({ Invoke-GuiAction { Open-GuiFile -Path $script:Ui.TbResultPath.Text -Select } })
$script:Ui.BtnCopyHash.Add_Click({ Invoke-GuiAction { [System.Windows.Clipboard]::SetText([string]$script:Ui.TbResultHash.Text) } })
$script:Ui.LinkRufus.Add_Click({ Invoke-GuiAction { Open-GuiUrl $script:RufusUrl } })
$script:Ui.BtnErrOpenMs.Add_Click({ Invoke-GuiAction { Open-GuiUrl $script:MsDownloadPage } })
$script:Ui.BtnErrUseIso.Add_Click({
        Invoke-GuiAction {
            $script:Ui.RbIso.IsChecked = $true
            Set-GuiStep 1
            Invoke-GuiBrowseIso
        }
    })
$script:Ui.BtnErrOpenLog.Add_Click({ Invoke-GuiAction { if ($script:LogFile) { Open-GuiFile -Path $script:LogFile } } })

$script:Window.Add_Closing({ param($s, $e) Invoke-GuiAction { Invoke-GuiClosing -Cancelable $e } })
$script:Window.Dispatcher.Add_UnhandledException({
        param($s, $e)
        $e.Handled = $true
        try { Write-GuiLog ('Unhandled UI error: {0}' -f $e.Exception.Message) 'Error' } catch { $null = $_ }
    })

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:Timer.Add_Tick({ Invoke-GuiTick })

# --- initial state ---
Update-GuiSource
Update-GuiMode
Update-GuiCustomFilter
Set-GuiStep 1
if (-not [System.IO.File]::Exists($script:Paths.Build)) {
    [void](Show-GuiMessage -Text ('builder\Build-LiteOS.ps1 is missing next to LiteOS-Builder.ps1. Extract the whole Lite OS folder again.') -Icon 'Error')
}

Disable-GuiQuickEdit
$script:Timer.Start()
Write-GuiLog 'Window ready.'
try {
    [void]$script:Window.ShowDialog()
}
finally {
    $script:Timer.Stop()
    if ($script:AwakeHeld) { Set-GuiKeepAwake $false }
    if ($null -ne $script:Child) {
        # Only reachable if the window was closed while a child still runs (e.g. the session ends):
        # leave a note; the builder's own cleanup still runs when it finishes or is stopped.
        Write-GuiLog ('Window closed while {0} (process {1}) is still running.' -f $script:Child.Stage, $script:Child.Process.Id) 'Warn'
    }
    Write-GuiLog 'Lite OS Builder closed.'
}

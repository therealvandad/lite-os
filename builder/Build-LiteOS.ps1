<#
.SYNOPSIS
    Builds a Lite OS ISO: the OFFICIAL Windows 11 ISO with Lite OS baked into the image.

.DESCRIPTION
    Build-LiteOS.ps1 is the Lite OS Builder (the GUI LiteOS-Builder.ps1 runs it as a child process).
    It takes the official Windows 11 (24H2 / 25H2+, build >= 26100) x64 ISO - either a file you
    downloaded yourself (-IsoPath) or one it downloads from Microsoft for you (-Download, via
    Get-WindowsIso.ps1) - and produces a bootable Lite OS ISO on THIS PC:

      - keeps only the edition you choose (default "Windows 11 Pro"), named "Lite OS <Mode>"
      - removes preinstalled apps and image components (image\removals.json) for the mode
      - bakes the tweak catalog (tweaks\*.json) into the offline image (Invoke-LiteOSOfflinePlan),
        with a revert backup at C:\ProgramData\LiteOS\backup\backup-image.json
      - Lite OS branding (OEM information, registered organization), Start and taskbar pins
      - downloads the official Steam / VC++ / DirectX / .NET installers on this PC, verifies their
        Authenticode signatures and bakes them in; SetupComplete.cmd installs them silently
      - adds autounattend.xml (no disk/partition settings: YOU pick the disk in Setup)
      - writes a bootable (BIOS + UEFI) UDF ISO, its SHA256 and a build report

    Modes:
      Lite (default)  Balanced tweaks + "lite" removals. Stays updatable (Windows Update, Store),
                      Defender on, Xbox / Game Pass and kernel anti-cheat keep working.
      Core (opt-in)   Extreme tweaks + "lite" and "core" removals (Windows X-Lite style: Defender,
                      Windows Update stack, Edge browser and WinRE removed or disabled; WebView2 is
                      kept). NOT serviceable: to update, rebuild from a newer ISO.

    Nothing from Microsoft is shipped with Lite OS and nothing is uploaded: the ISO is assembled
    on your PC from Microsoft's own files. No product keys, generic install keys or activators are
    added and no Microsoft binary is patched.

    Requires: Windows 10/11 host, Windows PowerShell 5.1 (64-bit) run as Administrator,
    >= 30 GB free on the work drive (NTFS), >= 40 GB with -Download. The Windows ADK "Deployment
    Tools" (oscdimg.exe) are optional; without them the ISO is written with the built-in IMAPI2 API.

.PARAMETER IsoPath
    Official Windows 11 ISO (or a folder with its extracted contents). Use this or -Download.

.PARAMETER Download
    Download the official Windows 11 x64 multi-edition ISO from Microsoft (Get-WindowsIso.ps1).

.PARAMETER Language
    ISO language for -Download, as Microsoft names it. Default "English (United States)".

.PARAMETER Edition
    Edition (image name) to keep, e.g. "Windows 11 Pro", "Windows 11 Home". An image index number
    is accepted too. If the name is not found you get a picker (or a clear error with -Yes).

.PARAMETER Mode
    Lite (default) or Core. Core needs confirmation (type CORE) unless -Yes is given.

.PARAMETER Include
    Tweak ids (see docs\TWEAKS.md) and/or removal ids (image.*) to add. Exact ids or wildcards.

.PARAMETER Exclude
    Tweak ids and/or removal ids (image.*) to skip. Exact ids or wildcards. Exclude wins.

.PARAMETER Apps
    Apps installed with winget at the first sign-in: "none" (default), "default", "all" or a list
    of exact winget ids from tweaks\apps-install.json.

.PARAMETER Installers
    Official installers baked into the image (image\installers.json): "default" (default),
    "none", "all" or a list of installer ids (e.g. steam,vcredist-x64).

.PARAMETER NoBypassRequirements
    Do NOT add the TPM / Secure Boot / RAM / storage / CPU requirement bypass (boot.wim, install
    image and autounattend.xml). Use this for hardware that meets the requirements.

.PARAMETER KeepAutoEncryption
    Keep Windows' automatic device encryption. By default the image sets PreventDeviceEncryption=1;
    you can still turn BitLocker on yourself any time.

.PARAMETER NoPrompt
    Use efisys_noprompt.bin for UEFI boot of the ISO (no "Press any key to boot from CD or DVD").

.PARAMETER OutputPath
    ISO file (ends in .iso) or output folder. Default: the current folder.
    The file name is LiteOS-<Mode>-<build>-<language>.iso.

.PARAMETER WorkDir
    Scratch folder on a local NTFS drive. Default: <SystemDrive>\LiteOS-Build.

.PARAMETER Yes
    Never prompt (GUI / CI): Core is accepted, an existing ISO gets a new name instead of being
    overwritten (unless -Force), and a missing edition is an error.

.PARAMETER ProgressProtocol
    Emit "##LITEOS-PROGRESS <0-100> <message>" lines (monotonic) for the GUI and a final
    "##LITEOS-RESULT ok <iso path> <sha256>" or "##LITEOS-RESULT error <message>" line.
    Implies no prompts.

.PARAMETER SplitWim
    Split install.wim into <= 3800 MB install*.swm parts when it is larger than 4 GB (FAT32 USB).

.PARAMETER KeepWorkDir
    Do not delete the work folder at the end (troubleshooting).

.PARAMETER KeepDownload
    Keep the ISO downloaded with -Download (in <WorkDir>\download) for later -IsoPath builds.

.PARAMETER Force
    Overwrite an existing output ISO and skip the interactive Core confirmation.

.EXAMPLE
    .\Build-LiteOS.ps1 -Download

.EXAMPLE
    .\Build-LiteOS.ps1 -IsoPath "$env:USERPROFILE\Downloads\Win11_25H2_English_x64.iso" -Edition "Windows 11 Home"

.EXAMPLE
    .\Build-LiteOS.ps1 -IsoPath D:\Win11.iso -Mode Core -Exclude image.edge -Installers steam -Yes -OutputPath E:\Builds

.NOTES
    Lite OS builder 2.x. Windows PowerShell 5.1 compatible, ASCII only.
    Binding contract: docs\ARCHITECTURE.md, section "Lite OS image (v2)".
    Order of the offline steps follows the contract; DISM servicing (provisioned apps,
    capabilities, features, packages, cleanup) runs while the offline hives are NOT loaded,
    because DISM must load the same hive files itself (sharing violation 0x80070020 otherwise).
    Same approach as tiny11builder (ntdevlabs) and other offline image tools.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$IsoPath,

    [switch]$Download,

    [string]$Language = 'English (United States)',

    [string]$Edition = 'Windows 11 Pro',

    [ValidateSet('Lite', 'Core')]
    [string]$Mode = 'Lite',

    [string[]]$Include = @(),

    [string[]]$Exclude = @(),

    [string[]]$Apps = @('none'),

    [string[]]$Installers = @('default'),

    [switch]$NoBypassRequirements,

    [switch]$KeepAutoEncryption,

    [switch]$NoPrompt,

    [string]$OutputPath,

    [string]$WorkDir,

    [switch]$Yes,

    [switch]$ProgressProtocol,

    [switch]$SplitWim,

    [switch]$KeepWorkDir,

    [switch]$KeepDownload,

    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------
# Script state
# ---------------------------------------------------------------------------------------------
$script:BuilderVersion    = '2.0.0'
$script:TotalSteps        = 22
$script:StepNumber        = 0
$script:LogFile           = $null
$script:DismLog           = $null
$script:RegExe            = Join-Path $env:SystemRoot 'System32\reg.exe'
$script:LoadedHives       = New-Object System.Collections.ArrayList
$script:MountedImages     = New-Object System.Collections.ArrayList
$script:IsoFullPath       = $null
$script:IsoAttachedByUs   = $false
$script:WorkRoot          = $null
$script:WorkMarker        = '.liteos-workdir'
$script:WorkChildren      = @('iso', 'mount', 'bootmount', 'scratch', 'stage', 'engine', 'installers')
$script:HiveNames         = @('LITE_SOFTWARE', 'LITE_SYSTEM', 'LITE_DEFAULT', 'LITE_BOOTSYSTEM')
$script:LabConfigNames    = @('BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck', 'BypassStorageCheck', 'BypassCPUCheck')
$script:DismRemovalTypes  = @('capability', 'feature', 'package')
$script:StartPinMembers   = @('primaryOEMPins', 'secondaryOEMPins', 'firstRunOEMPins', 'pinnedList')
$script:TaskbarOemPath    = 'C:\Windows\OEM\TaskbarLayoutModification.xml'
$script:Succeeded         = $false
$script:FailureMessage    = $null
$script:UseProtocol       = [bool]$ProgressProtocol
$script:LastProgress      = 0
$script:ProgressBase      = 0.0
$script:ProgressScale     = 1.0
$script:WarningList       = New-Object System.Collections.ArrayList
$script:DownloadDir       = $null
$script:DownloadedIso     = $null
$script:DownloadCompleted = $false
$script:ReportPath        = $null
$script:Report            = [ordered]@{}

# ---------------------------------------------------------------------------------------------
# Output / logging / progress protocol
# ---------------------------------------------------------------------------------------------
function ConvertTo-SingleLine {
    param([AllowNull()][AllowEmptyString()][string]$Text, [int]$Max = 400)
    if ($null -eq $Text) { return '' }
    $t = ($Text -replace '[\r\n\t]+', ' ' -replace '\s{2,}', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 3) + '...' }
    return $t
}

function Write-BuildLog {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Warn', 'Error', 'Step', 'Ok')][string]$Level = 'Info'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { Write-Verbose ('Log write failed: ' + $_.Exception.Message) }
    }
    if ($Level -eq 'Warn' -and $script:WarningList.Count -lt 300) { [void]$script:WarningList.Add((ConvertTo-SingleLine $Message 400)) }
    switch ($Level) {
        'Step'  { Write-Host ''; Write-Host $Message -ForegroundColor Cyan }
        'Warn'  { Write-Host ('  WARNING: ' + $Message) -ForegroundColor Yellow }
        'Error' { Write-Host ('  ERROR: ' + $Message) -ForegroundColor Red }
        'Ok'    { Write-Host ('  ' + $Message) -ForegroundColor Green }
        default { Write-Host ('  ' + $Message) }
    }
}

function Write-ProgressLine {
    # Raw protocol line for the GUI. Never goes backwards and never reaches 100 before the end.
    param([double]$Percent, [string]$Message, [switch]$Final)
    if (-not $script:UseProtocol) { return }
    $p = [int][Math]::Floor($Percent)
    if (-not $Final -and $p -gt 99) { $p = 99 }
    if ($p -gt 100) { $p = 100 }
    if ($p -lt $script:LastProgress) { $p = $script:LastProgress }
    $script:LastProgress = $p
    Write-Host ('##LITEOS-PROGRESS {0} {1}' -f $p, (ConvertTo-SingleLine $Message 200))
}

function Set-BuildProgress {
    # Percent on the 0-100 "build" scale; after a download the build scale is squeezed into 30-100.
    param([double]$Percent, [string]$Message)
    Write-ProgressLine -Percent ($script:ProgressBase + ($Percent * $script:ProgressScale)) -Message $Message
}

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Title, [double]$Percent = -1)
    $script:StepNumber++
    Write-BuildLog -Level Step -Message ('[{0}/{1}] {2}' -f $script:StepNumber, $script:TotalSteps, $Title)
    if ($Percent -ge 0) { Set-BuildProgress -Percent $Percent -Message $Title }
}

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Interactive {
    if (-not [Environment]::UserInteractive) { return $false }
    foreach ($a in [Environment]::GetCommandLineArgs()) {
        if ($a -like '-NonI*') { return $false }
    }
    return $true
}

function Test-CanPrompt {
    # -Yes and -ProgressProtocol (GUI child process) never prompt.
    if ($Yes -or $ProgressProtocol) { return $false }
    return (Test-Interactive)
}

function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Test-Field {
    param($Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return [bool]$Object.Contains($Name) }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-Field {
    # Strict-mode safe read of a property (PSCustomObject from ConvertFrom-Json, .NET object) or a
    # dictionary key. Arrays are unrolled: wrap the call in @() when a list is expected.
    param($Object, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Get-FieldRaw {
    # Like Get-Field, but returns the value as it is (an array stays one array, a scalar stays a scalar).
    param($Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return , $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return , $p.Value
}

function ConvertTo-IdList {
    # Accepts arrays and comma separated strings (powershell.exe -File passes one string).
    param([string[]]$Values)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($v in @($Values)) {
        if ($null -eq $v) { continue }
        foreach ($part in ($v -split '[,;]')) {
            $t = $part.Trim()
            if ($t -and -not ($list -contains $t)) { $list.Add($t) }
        }
    }
    return , $list.ToArray()
}

function Invoke-Native {
    # Runs a native exe without letting stderr become a terminating error (PS 5.1 + EAP Stop).
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    if (-not (Get-Command -Name $FilePath -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "Required program not found: $FilePath"
    }
    $ErrorActionPreference = 'Continue'
    $output = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    return New-Object PSObject -Property @{ ExitCode = $code; Output = $output }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $raw = [IO.File]::ReadAllText($Path)
    return ($raw | ConvertFrom-Json)
}

function Write-TextFile {
    # UTF-8 without BOM.
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $enc)
}

function Write-AsciiCrlfFile {
    # Batch files: plain ASCII with CRLF line ends (cmd.exe misreads LF-only files).
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string[]]$Lines)
    $text = (($Lines | ForEach-Object { [string]$_ }) -join "`r`n") + "`r`n"
    foreach ($ch in $text.ToCharArray()) {
        if ([int]$ch -gt 127) { throw "Refusing to write non-ASCII text to $Path" }
    }
    [IO.File]::WriteAllText($Path, $text, [Text.Encoding]::ASCII)
}

function Get-DriveSpace {
    param([Parameter(Mandatory = $true)][string]$Path)
    $root = [IO.Path]::GetPathRoot($Path)
    if (-not $root -or $root.StartsWith('\\')) { throw "Path '$Path' must be on a local drive (no UNC paths)." }
    $drive = New-Object System.IO.DriveInfo($root)
    return New-Object PSObject -Property @{ Root = $root; Free = [int64]$drive.AvailableFreeSpace; Format = [string]$drive.DriveFormat; Type = [string]$drive.DriveType }
}

function Get-SanitizedLogText {
    # Replaces local folder paths (longest first, case-insensitive) so a log copied into the image
    # does not reveal the build PC's user name or folder layout.
    param([AllowEmptyString()][string]$Text, [object[]]$Pairs)
    $list = New-Object System.Collections.ArrayList
    foreach ($p in @($Pairs)) {
        $from = [string]$p[0]
        if ([string]::IsNullOrEmpty($from)) { continue }
        $from = $from.TrimEnd('\')
        if ($from.Length -lt 3) { continue }
        [void]$list.Add((New-Object PSObject -Property @{ From = $from; To = [string]$p[1] }))
    }
    foreach ($p in @($list | Sort-Object -Property @{ Expression = { $_.From.Length }; Descending = $true })) {
        $Text = [regex]::Replace($Text, [regex]::Escape($p.From), $p.To.Replace('$', '$$'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    return $Text
}

function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    return ('{0:N0} MB' -f ($Bytes / 1MB))
}

function Test-PathUnder {
    param([string]$Child, [string]$Parent)
    if (-not $Child -or -not $Parent) { return $false }
    $c = $Child.TrimEnd('\') + '\'
    $p = $Parent.TrimEnd('\') + '\'
    return $c.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)
}

function Test-OutputIsFolder {
    # -OutputPath ending in .iso is a file; anything else (or an existing folder) is a folder.
    param([string]$Requested, [string]$Full)
    if (Test-Path -LiteralPath $Full -PathType Container) { return $true }
    if ($Requested.EndsWith('\') -or $Requested.EndsWith('/')) { return $true }
    return ([IO.Path]::GetExtension($Full) -ne '.iso')
}

function Get-OptionalSplat {
    # Adds optional parameters only when the target command declares them (APIs owned by other
    # files may gain or lack -LogPath / -ScratchDirectory).
    param([Parameter(Mandatory = $true)][string]$CommandName, [hashtable]$Base, [hashtable]$Optional)
    $splat = @{}
    foreach ($k in @($Base.Keys)) { $splat[$k] = $Base[$k] }
    $cmd = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and $null -ne $Optional) {
        foreach ($k in @($Optional.Keys)) {
            if ($cmd.Parameters.ContainsKey($k) -and $null -ne $Optional[$k]) { $splat[$k] = $Optional[$k] }
        }
    }
    return $splat
}

function Get-StatusCounts {
    param([object[]]$Results)
    $c = [ordered]@{}
    foreach ($r in @($Results)) {
        if ($null -eq $r) { continue }
        $s = [string](Get-Field $r 'status' 'unknown')
        if (-not $s) { $s = 'unknown' }
        if ($c.Contains($s)) { $c[$s] = [int]$c[$s] + 1 } else { $c[$s] = 1 }
    }
    return $c
}

function ConvertTo-ResultRows {
    param([object[]]$Results)
    $rows = New-Object System.Collections.ArrayList
    foreach ($r in @($Results)) {
        if ($null -eq $r) { continue }
        [void]$rows.Add([ordered]@{
                id      = [string](Get-Field $r 'id' '')
                status  = [string](Get-Field $r 'status' '')
                message = (ConvertTo-SingleLine ([string](Get-Field $r 'message' '')) 300)
            })
    }
    return , $rows.ToArray()
}

function Select-ResultObjects {
    # Keeps only result-like objects (APIs may also write stray strings to the pipeline).
    param([object[]]$Items)
    $out = New-Object System.Collections.ArrayList
    foreach ($i in @($Items)) {
        if ($null -eq $i -or $i -is [string] -or $i -is [System.ValueType]) { continue }
        if ((Test-Field $i 'status') -or (Test-Field $i 'id')) { [void]$out.Add($i) }
    }
    return , $out.ToArray()
}

# ---------------------------------------------------------------------------------------------
# Offline registry hives
# ---------------------------------------------------------------------------------------------
function Test-HiveLoaded {
    param([Parameter(Mandatory = $true)][string]$Name)
    $r = Invoke-Native -FilePath $script:RegExe -ArgumentList @('query', "HKLM\$Name")
    return ($r.ExitCode -eq 0)
}

function Dismount-OfflineHive {
    param([Parameter(Mandatory = $true)][string]$Name)
    for ($i = 1; $i -le 6; $i++) {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        $r = Invoke-Native -FilePath $script:RegExe -ArgumentList @('unload', "HKLM\$Name")
        if ($r.ExitCode -eq 0) {
            if ($script:LoadedHives -contains $Name) { $script:LoadedHives.Remove($Name) }
            return $true
        }
        if (-not (Test-HiveLoaded -Name $Name)) {
            if ($script:LoadedHives -contains $Name) { $script:LoadedHives.Remove($Name) }
            return $true
        }
        Start-Sleep -Seconds 2
    }
    Write-BuildLog -Level Warn -Message ("Could not unload HKLM\{0}. Close Registry Editor / other tools, then run: reg unload HKLM\{0}" -f $Name)
    return $false
}

function Mount-OfflineHive {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "Registry hive file not found: $File" }
    if (Test-HiveLoaded -Name $Name) {
        Write-BuildLog -Level Warn -Message "HKLM\$Name is already loaded (left over from an earlier run); unloading it first."
        if (-not (Dismount-OfflineHive -Name $Name)) { throw "HKLM\$Name is still loaded; cannot continue." }
    }
    $r = Invoke-Native -FilePath $script:RegExe -ArgumentList @('load', "HKLM\$Name", $File)
    if ($r.ExitCode -ne 0) { throw ("reg load HKLM\{0} failed (exit {1}): {2}" -f $Name, $r.ExitCode, ($r.Output -join ' ')) }
    [void]$script:LoadedHives.Add($Name)
}

function Write-OfflineRegValue {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Data
    )
    # Windows PowerShell 5.1 drops empty native arguments, so "/d ''" would swallow "/f".
    if ([string]::IsNullOrEmpty($Data)) { throw "reg add $Key /v ${Name}: empty data is not supported." }
    $r = Invoke-Native -FilePath $script:RegExe -ArgumentList @('add', $Key, '/v', $Name, '/t', $Type, '/d', $Data, '/f')
    if ($r.ExitCode -ne 0) { throw ("reg add {0} /v {1} failed (exit {2}): {3}" -f $Key, $Name, $r.ExitCode, ($r.Output -join ' ')) }
}

function Invoke-OfflineRegKeyDelete {
    # Returns $true if the key existed and was deleted, $false if it was not present.
    param([Parameter(Mandatory = $true)][string]$Key)
    $q = Invoke-Native -FilePath $script:RegExe -ArgumentList @('query', $Key)
    if ($q.ExitCode -ne 0) { return $false }
    $r = Invoke-Native -FilePath $script:RegExe -ArgumentList @('delete', $Key, '/f')
    if ($r.ExitCode -ne 0) { throw ("reg delete {0} failed (exit {1}): {2}" -f $Key, $r.ExitCode, ($r.Output -join ' ')) }
    return $true
}

function Get-OfflineControlSet {
    # Offline SYSTEM hives have no CurrentControlSet; Select\Current says which ControlSet00N is live.
    param([Parameter(Mandatory = $true)][string]$HiveName)
    $n = 1
    $r = Invoke-Native -FilePath $script:RegExe -ArgumentList @('query', "HKLM\$HiveName\Select", '/v', 'Current')
    if ($r.ExitCode -eq 0) {
        foreach ($line in $r.Output) {
            if ($line -match 'Current\s+REG_DWORD\s+0x([0-9a-fA-F]+)') { $n = [Convert]::ToInt32($Matches[1], 16) }
        }
    }
    if ($n -lt 1) { $n = 1 }
    return ('ControlSet{0:D3}' -f $n)
}

# ---------------------------------------------------------------------------------------------
# ACLs
# ---------------------------------------------------------------------------------------------
function Set-ProtectedAcl {
    # New folders in the image inherit "Authenticated Users: Modify" (from C:\) or "Users: create
    # files" (from ProgramData). The playbook and its backups run elevated, so only SYSTEM and
    # Administrators may change them; Users can read. Well-known SIDs resolve the same offline.
    param([Parameter(Mandatory = $true)][string]$Path)
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    $runs = New-Object System.Collections.ArrayList
    [void]$runs.Add(@($Path, '/setowner', '*S-1-5-32-544', '/T', '/C', '/Q'))
    [void]$runs.Add(@($Path, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX', '/C', '/Q'))
    if (@(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Count -gt 0) {
        # everything below inherits from the protected folder only (no copied or creator ACEs)
        [void]$runs.Add(@((Join-Path $Path '*'), '/reset', '/T', '/C', '/Q'))
    }
    foreach ($argList in $runs) {
        $r = Invoke-Native -FilePath $icacls -ArgumentList $argList
        if ($r.ExitCode -ne 0) { throw ("icacls {0} failed (exit {1}): {2}" -f ($argList -join ' '), $r.ExitCode, ($r.Output -join ' ')) }
    }
}

function Set-AdminOwner {
    # Files created in the image are owned by the build PC's admin account (an unknown SID on the
    # installed system); hand them to BUILTIN\Administrators. Inherited ACEs are kept.
    param([Parameter(Mandatory = $true)][string]$Path)
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    $r = Invoke-Native -FilePath $icacls -ArgumentList @($Path, '/setowner', '*S-1-5-32-544', '/C', '/Q')
    if ($r.ExitCode -ne 0) { Write-BuildLog -Level Warn -Message ("Could not set the owner of {0}: {1}" -f $Path, ($r.Output -join ' ')) }
}

# ---------------------------------------------------------------------------------------------
# Selection helpers
# ---------------------------------------------------------------------------------------------
function Select-ImageIndex {
    param([Parameter(Mandatory = $true)][object[]]$Images, [Parameter(Mandatory = $true)][string]$Wanted)
    if ($Wanted -match '^\s*\d+\s*$') {
        $n = [int]$Wanted.Trim()
        if (@($Images | Where-Object { $_.ImageIndex -eq $n }).Count -eq 1) { return $n }
    }
    $exact = @($Images | Where-Object { $_.ImageName -eq $Wanted })
    if ($exact.Count -ge 1) { return [int]$exact[0].ImageIndex }
    $partial = @($Images | Where-Object { $_.ImageName.IndexOf($Wanted, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($partial.Count -eq 1) {
        Write-BuildLog -Level Warn -Message ("Edition '{0}' matched '{1}' (closest name)." -f $Wanted, $partial[0].ImageName)
        return [int]$partial[0].ImageIndex
    }
    Write-BuildLog -Level Warn -Message ("Edition '{0}' was not found in this ISO. Available editions:" -f $Wanted)
    foreach ($img in $Images) { Write-BuildLog -Message ('{0,2}) {1}' -f $img.ImageIndex, $img.ImageName) }
    if (-not (Test-CanPrompt)) {
        $names = @($Images | ForEach-Object { '"' + $_.ImageName + '"' }) -join ', '
        throw ("Edition '{0}' not found. Re-run with -Edition set to one of: {1}" -f $Wanted, $names)
    }
    while ($true) {
        $answer = Read-Host '  Type the number of the edition to build (Q = quit)'
        if ($answer -match '^\s*[Qq]') { throw 'Cancelled by user.' }
        if ($answer -match '^\s*\d+\s*$') {
            $n = [int]$answer.Trim()
            $hit = @($Images | Where-Object { $_.ImageIndex -eq $n })
            if ($hit.Count -eq 1) { return $n }
        }
        Write-Host '  Invalid choice, try again.' -ForegroundColor Yellow
    }
}

function Test-IdMatch {
    # Same rules as the engine (Test-LiteOSIdMatch): exact id, or -like when the pattern has * or ?.
    param([string]$Id, [string[]]$Patterns)
    foreach ($p in @($Patterns)) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        if ($Id -eq $p) { return $true }
        if ($p.IndexOf('*') -ge 0 -or $p.IndexOf('?') -ge 0) {
            try { if ($Id -like $p) { return $true } } catch { Write-Verbose ('Bad pattern: ' + $p) }
        }
    }
    return $false
}

function Split-IdPattern {
    # -Include / -Exclude hold tweak ids AND removal ids. A pattern goes to the removal list when it
    # starts with "image." or matches a removal id, to the tweak list when it does not start with
    # "image." and matches a tweak id (or nothing at all). "*onedrive*" can go to both.
    param([string[]]$Patterns, [string[]]$TweakIds, [string[]]$RemovalIds, [string]$What)
    $tw = New-Object System.Collections.Generic.List[string]
    $rm = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($Patterns)) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        $isImage = $p.StartsWith('image.', [StringComparison]::OrdinalIgnoreCase)
        $hitR = $false
        foreach ($id in @($RemovalIds)) { if (Test-IdMatch -Id $id -Patterns @($p)) { $hitR = $true; break } }
        $hitT = $false
        if (-not $isImage) {
            foreach ($id in @($TweakIds)) { if (Test-IdMatch -Id $id -Patterns @($p)) { $hitT = $true; break } }
        }
        if ($isImage -or $hitR) { $rm.Add($p) }
        if (-not $isImage -and ($hitT -or -not $hitR)) { $tw.Add($p) }
        if (-not $hitR -and -not $hitT) { Write-BuildLog -Level Warn -Message ("{0} '{1}' matches no tweak or removal id (typo?)." -f $What, $p) }
    }
    return New-Object PSObject -Property @{ Tweaks = $tw.ToArray(); Removals = $rm.ToArray() }
}

function Test-AppxOnlyTweak {
    # Synthetic apps.remove.* tweaks (and any tweak made only of appx-remove actions) are handled by
    # the builder's own offline appx step, before the hives are loaded.
    param($Tweak)
    $actions = @(Get-Field $Tweak 'actions' @())
    if ($actions.Count -eq 0) { return $false }
    foreach ($a in $actions) {
        if ([string](Get-Field $a 'type' '') -ne 'appx-remove') { return $false }
    }
    return $true
}

# ---------------------------------------------------------------------------------------------
# autounattend.xml
# ---------------------------------------------------------------------------------------------
function Get-LiteOSUnattendXml {
    # Turns builder\autounattend.xml (template) into the final answer file text.
    param(
        [Parameter(Mandatory = $true)][string]$TemplateText,
        [Parameter(Mandatory = $true)][bool]$BypassRequirements,
        [string]$Banner = ''
    )
    $blockPattern  = '(?s)[ \t]*<!--\s*LITEOS:BYPASS:BEGIN\s*-->.*?<!--\s*LITEOS:BYPASS:END\s*-->[ \t]*(\r?\n)?'
    $markerPattern = '[ \t]*<!--\s*LITEOS:BYPASS:(BEGIN|END)\s*-->[ \t]*(\r?\n)?'
    if (-not [regex]::IsMatch($TemplateText, $blockPattern)) {
        throw 'autounattend.xml template is missing the LITEOS:BYPASS:BEGIN / LITEOS:BYPASS:END markers.'
    }
    if ($BypassRequirements) {
        $text = [regex]::Replace($TemplateText, $markerPattern, '')
    } else {
        $text = [regex]::Replace($TemplateText, $blockPattern, '')
    }
    if ($Banner) {
        $safe = $Banner.Replace('--', '-')
        $decl = [regex]::Match($text, '^\s*<\?xml[^>]*\?>')
        if ($decl.Success) {
            $text = $text.Substring(0, $decl.Length) + "`r`n<!-- " + $safe + " -->" + $text.Substring($decl.Length)
        } else {
            $text = "<!-- " + $safe + " -->`r`n" + $text
        }
    }

    # Validate: must parse, must keep the user in control of disks, keys and accounts.
    $doc = New-Object System.Xml.XmlDocument
    $doc.XmlResolver = $null
    $doc.LoadXml($text)
    if ($doc.DocumentElement.LocalName -ne 'unattend' -or $doc.DocumentElement.NamespaceURI -ne 'urn:schemas-microsoft-com:unattend') {
        throw 'autounattend.xml: root element must be <unattend xmlns="urn:schemas-microsoft-com:unattend">.'
    }
    $forbidden = @('DiskConfiguration', 'ImageInstall', 'InstallTo', 'InstallToAvailablePartition', 'CreatePartitions', 'ModifyPartitions', 'WillWipeDisk', 'LocalAccounts', 'AutoLogon', 'AdministratorPassword')
    foreach ($f in $forbidden) {
        if ($doc.SelectNodes("//*[local-name()='$f']").Count -gt 0) {
            throw "autounattend.xml must not contain <$f> (Lite OS never picks disks, keys or accounts for the user)."
        }
    }
    # Windows Setup needs a ProductKey element in windowsPE UserData, so exactly that one is
    # allowed - with an EMPTY Key. A key anywhere (or ProductKey anywhere else) is refused.
    foreach ($pk in @($doc.SelectNodes("//*[local-name()='ProductKey']"))) {
        $ud = $pk.ParentNode
        $comp = $null
        $pass = $null
        if ($null -ne $ud) { $comp = $ud.ParentNode }
        if ($null -ne $comp) { $pass = $comp.ParentNode }
        $placeOk = ($null -ne $ud -and $ud.LocalName -eq 'UserData' -and
            $null -ne $comp -and $comp.LocalName -eq 'component' -and $comp.GetAttribute('name') -eq 'Microsoft-Windows-Setup' -and
            $null -ne $pass -and $pass.LocalName -eq 'settings' -and $pass.GetAttribute('pass') -eq 'windowsPE')
        if (-not $placeOk) { throw 'autounattend.xml: <ProductKey> is only allowed in windowsPE / Microsoft-Windows-Setup / UserData.' }
        foreach ($child in @($pk.ChildNodes)) {
            if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element -and $child.LocalName -ne 'Key') {
                throw ("autounattend.xml: <ProductKey> may only contain an empty <Key />, found <{0}>." -f $child.LocalName)
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($pk.InnerText)) {
            throw 'autounattend.xml: <ProductKey><Key> must be empty - Lite OS never ships product keys.'
        }
    }
    $firstLogon = $false
    foreach ($node in $doc.SelectNodes("//*[local-name()='CommandLine']")) {
        if ($node.InnerText -like '*C:\LiteOS\LiteOS.ps1*-FirstLogon*') { $firstLogon = $true }
    }
    if (-not $firstLogon) { throw 'autounattend.xml: FirstLogonCommands must run C:\LiteOS\LiteOS.ps1 -FirstLogon.' }
    $hasLabConfig = $false
    foreach ($node in $doc.SelectNodes("//*[local-name()='Path']")) {
        if ($node.InnerText -match 'LabConfig') { $hasLabConfig = $true }
    }
    if ($BypassRequirements -and -not $hasLabConfig) { throw 'autounattend.xml: requirement bypass block is empty.' }
    if (-not $BypassRequirements -and $hasLabConfig) { throw 'autounattend.xml: LabConfig bypass still present after -NoBypassRequirements.' }
    return $text
}

# ---------------------------------------------------------------------------------------------
# Branding and layout
# ---------------------------------------------------------------------------------------------
function Get-BrandingInfo {
    # image\branding.json with safe defaults. Tokens <mode>/{mode} and <build>/{build} are expanded.
    param([string]$Path, [string]$ModeName, [string]$BuildText)
    $values = [ordered]@{
        name                   = 'Lite OS'
        manufacturer           = 'Lite OS'
        model                  = 'Lite OS <mode> (<build>)'
        supportUrl             = 'https://github.com/therealvandad/lite-os'
        registeredOrganization = 'Lite OS'
        bootDescription        = 'Lite OS'
        isoLabelPrefix         = 'LITEOS'
    }
    $source = 'built-in defaults'
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        try {
            $json = Read-JsonFile -Path $Path
            foreach ($k in @($values.Keys)) {
                $v = Get-Field $json $k $null
                if ($v -is [string] -and $v.Trim()) { $values[$k] = $v.Trim() }
            }
            $source = 'image\branding.json'
        } catch {
            Write-BuildLog -Level Warn -Message ("image\branding.json could not be read ({0}); using the default Lite OS branding." -f $_.Exception.Message)
        }
    } else {
        Write-BuildLog -Level Warn -Message 'image\branding.json not found; using the default Lite OS branding.'
    }
    $ic = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $out = [ordered]@{}
    foreach ($k in @($values.Keys)) {
        $v = [string]$values[$k]
        $v = [regex]::Replace($v, '<mode>|\{mode\}', $ModeName.Replace('$', '$$'), $ic)
        $v = [regex]::Replace($v, '<build>|\{build\}', $BuildText.Replace('$', '$$'), $ic)
        # registry data and cmd lines: no quotes / control characters, ASCII, bounded length
        $v = ($v -replace '["\x00-\x1F]', '' -replace '[^\x20-\x7E]', '').Trim()
        if ($v.Length -gt 200) { $v = $v.Substring(0, 200) }
        $out[$k] = $v
    }
    if (-not $out['name']) { $out['name'] = 'Lite OS' }
    $out['source'] = $source
    return $out
}

function Test-EdgePinValue {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    return ($Value -match '(?i)(^MSEdge$|\\Microsoft Edge\.lnk$|^Microsoft\.MicrosoftEdge)')
}

function Get-StartPinCount {
    # Number of pins in a LayoutModification.json object (OEM members, plus the policy-format list).
    param($Json)
    $n = 0
    foreach ($k in $script:StartPinMembers) { $n += @(Get-Field $Json $k @()).Count }
    return $n
}

function Install-LayoutFile {
    # Start pins (LayoutModification.json) and taskbar pins (TaskbarLayoutModification.xml) for the
    # Default profile, plus the OEM copy that LayoutXMLPath points to (Microsoft Learn: "Customize
    # the Windows 11 taskbar"). In Users\Default\...\Shell Windows reads the OEM members
    # primaryOEMPins / secondaryOEMPins (4 each) / firstRunOEMPins (1) - Microsoft Learn: "Customize
    # the Windows 11 Start menu"; pinnedList / applyOnce belong to the ConfigureStartPins POLICY and
    # are not used there. -DropEdge removes Edge pins (Core).
    param([string]$LayoutDir, [string]$MountPath, [bool]$DropEdge)
    $res = [ordered]@{ start = $false; taskbar = $false; taskbarOem = $false; edgePinsRemoved = 0 }
    $shellDir = Join-Path $MountPath 'Users\Default\AppData\Local\Microsoft\Windows\Shell'
    if (-not (Test-Path -LiteralPath $shellDir)) { New-Item -ItemType Directory -Path $shellDir -Force | Out-Null }

    $startSrc = Join-Path $LayoutDir 'LayoutModification.json'
    if (Test-Path -LiteralPath $startSrc -PathType Leaf) {
        try {
            $raw = [IO.File]::ReadAllText($startSrc)
            $json = $raw | ConvertFrom-Json
            if ((Get-StartPinCount $json) -eq 0) { throw 'it has no primaryOEMPins / secondaryOEMPins / firstRunOEMPins entries' }
            if (@(Get-Field $json 'pinnedList' @()).Count -gt 0) {
                Write-BuildLog -Level Warn -Message 'LayoutModification.json has a pinnedList (ConfigureStartPins policy format): Windows ignores it in the Default profile. Use primaryOEMPins / secondaryOEMPins.'
            }
            foreach ($k in @('primaryOEMPins', 'secondaryOEMPins')) {
                if (@(Get-Field $json $k @()).Count -gt 4) { Write-BuildLog -Level Warn -Message ("LayoutModification.json: Windows uses only the first 4 {0} entries." -f $k) }
            }
            $text = $raw
            if ($DropEdge) {
                $obj = [ordered]@{}
                $changed = $false
                foreach ($prop in @($json.PSObject.Properties)) {
                    if ($script:StartPinMembers -notcontains $prop.Name) { $obj[$prop.Name] = $prop.Value; continue }
                    $kept = New-Object System.Collections.ArrayList
                    foreach ($pin in @($prop.Value)) {
                        $isEdge = $false
                        if ($null -ne $pin) {
                            foreach ($pp in @($pin.PSObject.Properties)) {
                                if ($pp.Value -is [string] -and (Test-EdgePinValue $pp.Value)) { $isEdge = $true }
                            }
                        }
                        if ($isEdge) { $res['edgePinsRemoved'] = [int]$res['edgePinsRemoved'] + 1; $changed = $true } else { [void]$kept.Add($pin) }
                    }
                    $obj[$prop.Name] = $kept.ToArray()
                }
                if ($changed) { $text = ConvertTo-Json -InputObject $obj -Depth 10 }
            }
            $dest = Join-Path $shellDir 'LayoutModification.json'
            Write-TextFile -Path $dest -Text $text
            $res['start'] = $true
            Write-BuildLog -Message ('Start pins -> Users\Default\AppData\Local\Microsoft\Windows\Shell\LayoutModification.json ({0} OEM pins)' -f (Get-StartPinCount ($text | ConvertFrom-Json)))
        } catch {
            Write-BuildLog -Level Warn -Message ("Start layout skipped: image\layout\LayoutModification.json is not usable ({0})." -f $_.Exception.Message)
        }
    } else {
        Write-BuildLog -Level Warn -Message 'image\layout\LayoutModification.json not found; Windows default Start pins are kept.'
    }

    $barSrc = Join-Path $LayoutDir 'TaskbarLayoutModification.xml'
    if (Test-Path -LiteralPath $barSrc -PathType Leaf) {
        try {
            $doc = New-Object System.Xml.XmlDocument
            $doc.XmlResolver = $null
            $doc.LoadXml([IO.File]::ReadAllText($barSrc))
            if ($doc.DocumentElement.LocalName -ne 'LayoutModificationTemplate') { throw 'root element is not LayoutModificationTemplate' }
            $removed = 0
            if ($DropEdge) {
                foreach ($n in @($doc.SelectNodes("//*[local-name()='DesktopApp' or local-name()='UWA']"))) {
                    $isEdge = $false
                    foreach ($attr in @($n.Attributes)) { if (Test-EdgePinValue $attr.Value) { $isEdge = $true } }
                    if ($isEdge) { [void]$n.ParentNode.RemoveChild($n); $removed++ }
                }
            }
            $res['edgePinsRemoved'] = [int]$res['edgePinsRemoved'] + $removed
            $oemDir = Join-Path $MountPath 'Windows\OEM'
            if (-not (Test-Path -LiteralPath $oemDir)) {
                New-Item -ItemType Directory -Path $oemDir -Force | Out-Null
                Set-AdminOwner -Path $oemDir
            }
            $targets = @((Join-Path $shellDir 'TaskbarLayoutModification.xml'), (Join-Path $oemDir 'TaskbarLayoutModification.xml'))
            foreach ($t in $targets) {
                if ($removed -eq 0) {
                    Copy-Item -LiteralPath $barSrc -Destination $t -Force
                } else {
                    $ws = New-Object System.Xml.XmlWriterSettings
                    $ws.Indent = $true
                    $ws.Encoding = New-Object System.Text.UTF8Encoding($false)
                    $w = [System.Xml.XmlWriter]::Create($t, $ws)
                    try { $doc.Save($w) } finally { $w.Close() }
                }
            }
            $res['taskbar'] = $true
            $res['taskbarOem'] = $true
            Set-AdminOwner -Path (Join-Path $oemDir 'TaskbarLayoutModification.xml')
            Write-BuildLog -Message ('Taskbar pins -> Default profile Shell folder and {0} (LayoutXMLPath)' -f $script:TaskbarOemPath)
        } catch {
            Write-BuildLog -Level Warn -Message ("Taskbar layout skipped: image\layout\TaskbarLayoutModification.xml is not usable ({0})." -f $_.Exception.Message)
        }
    } else {
        Write-BuildLog -Level Warn -Message 'image\layout\TaskbarLayoutModification.xml not found; Windows default taskbar pins are kept.'
    }
    if ($res['edgePinsRemoved'] -gt 0) { Write-BuildLog -Message ('{0} Edge pin(s) left out (Core / Edge removed).' -f $res['edgePinsRemoved']) }
    return $res
}

# ---------------------------------------------------------------------------------------------
# Official installers (downloaded on THIS PC, never shipped with Lite OS)
# ---------------------------------------------------------------------------------------------
function Get-InstallerPlan {
    param($Json, [string]$ModeName, [string[]]$Requested)
    $plan = New-Object System.Collections.ArrayList
    $req = @($Requested | ForEach-Object { $_.ToLowerInvariant() })
    if ($req.Count -eq 0) { $req = @('default') }
    if ($req -contains 'none') {
        if ($req.Count -gt 1) { throw "-Installers: 'none' cannot be combined with other values." }
        return , $plan.ToArray()
    }
    $keyword = $null
    if ($req.Count -eq 1 -and @('default', 'all') -contains $req[0]) { $keyword = $req[0] }
    elseif (@($req | Where-Object { @('default', 'all') -contains $_ }).Count -gt 0) { throw "-Installers: use 'default', 'all', 'none' or a list of installer ids, not both." }
    $seen = New-Object System.Collections.Generic.List[string]
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($e in @(Get-Field $Json 'installers' @())) {
        $id = [string](Get-Field $e 'id' '')
        if (-not $id) { continue }
        $ids.Add($id)
        $m = ([string](Get-Field $e 'mode' 'both')).ToLowerInvariant()
        $modeOk = ($m -eq 'both' -or $m -eq $ModeName.ToLowerInvariant())
        $take = $false
        if ($keyword -eq 'default') { $take = ($modeOk -and [bool](Get-Field $e 'default' $false)) }
        elseif ($keyword -eq 'all') { $take = $modeOk }
        elseif (Test-IdMatch -Id $id -Patterns $Requested) {
            $take = $true
            if (-not $modeOk) { Write-BuildLog -Level Warn -Message ("Installer '{0}' is meant for mode '{1}'; baking it in because you asked for it." -f $id, $m) }
        }
        if ($take -and -not $seen.Contains($id)) { $seen.Add($id); [void]$plan.Add($e) }
    }
    if (-not $keyword) {
        foreach ($r in $Requested) {
            $hit = $false
            foreach ($id in $ids) { if (Test-IdMatch -Id $id -Patterns @($r)) { $hit = $true; break } }
            if (-not $hit) { Write-BuildLog -Level Warn -Message ("Installer id '{0}' is not in image\installers.json." -f $r) }
        }
    }
    return , $plan.ToArray()
}

function Save-WebFile {
    # Downloads an official installer: Invoke-WebRequest with retries, BITS as the last resort.
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$Path, [int]$Attempts = 3)
    $last = 'unknown error'
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
            $oldPref = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'   # the PS 5.1 progress bar slows downloads a lot
            try {
                Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec 600 -MaximumRedirection 10 | Out-Null
            } finally {
                $ProgressPreference = $oldPref
            }
            if ((Test-Path -LiteralPath $Path -PathType Leaf) -and (Get-Item -LiteralPath $Path).Length -gt 0) { return }
            $last = 'empty file'
        } catch {
            $last = $_.Exception.Message
        }
        Write-BuildLog -Level Warn -Message ("Download attempt {0}/{1} failed: {2}" -f $i, $Attempts, (ConvertTo-SingleLine $last 200))
        if ($i -lt $Attempts) { Start-Sleep -Seconds (5 * $i) }
    }
    if (Get-Command -Name 'Start-BitsTransfer' -ErrorAction SilentlyContinue) {
        try {
            if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
            Start-BitsTransfer -Source $Url -Destination $Path -ErrorAction Stop
            if ((Test-Path -LiteralPath $Path -PathType Leaf) -and (Get-Item -LiteralPath $Path).Length -gt 0) { return }
        } catch {
            $last = $_.Exception.Message
        }
    }
    throw ('download failed: {0}' -f (ConvertTo-SingleLine $last 200))
}

function Save-InstallerSet {
    # Returns one result per planned installer. A failing installer is a warning, never an abort.
    param([object[]]$Plan, [string]$TargetDir)
    $results = New-Object System.Collections.ArrayList
    $files = New-Object System.Collections.Generic.List[string]
    $n = 0
    foreach ($e in @($Plan)) {
        $n++
        $id = [string](Get-Field $e 'id' '')
        $name = [string](Get-Field $e 'name' $id)
        $file = [string](Get-Field $e 'file' '')
        $url = [string](Get-Field $e 'url' '')
        $publisher = [string](Get-Field $e 'publisher' '')
        $r = [ordered]@{ id = $id; name = $name; file = $file; status = 'failed'; message = ''; sha256 = $null; signer = $null; size = 0 }
        Set-BuildProgress -Percent (8 + 6 * ($n - 1) / [Math]::Max(1, @($Plan).Count)) -Message ('Downloading ' + $name)
        try {
            if (-not $file -or $file -notmatch '^[A-Za-z0-9][A-Za-z0-9._ \-]*\.(exe|msi)$' -or $file.Contains('..')) { throw "bad 'file' name '$file' (plain .exe/.msi file name expected)" }
            if ($files.Contains($file.ToLowerInvariant())) { throw "file name '$file' is used by two installers" }
            if (-not $url.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) { throw "url must be an official https:// link, got '$url'" }
            if (-not $publisher) { throw "no 'publisher' to verify the signature against" }
            $dest = Join-Path $TargetDir $file
            Write-BuildLog -Message ("downloading {0} from {1}" -f $name, $url)
            Save-WebFile -Url $url -Path $dest
            $sig = Get-AuthenticodeSignature -LiteralPath $dest
            $subject = ''
            if ($null -ne $sig.SignerCertificate) { $subject = [string]$sig.SignerCertificate.Subject }
            if ([string]$sig.Status -ne 'Valid') { throw ("Authenticode signature is '{0}' ({1})" -f $sig.Status, (ConvertTo-SingleLine ([string]$sig.StatusMessage) 150)) }
            if ($subject.IndexOf($publisher, [StringComparison]::OrdinalIgnoreCase) -lt 0) { throw ("signed by '{0}', expected a signer containing '{1}'" -f $subject, $publisher) }
            $r['signer'] = $subject
            $r['size'] = [int64](Get-Item -LiteralPath $dest).Length
            $r['sha256'] = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
            $r['status'] = 'ok'
            $r['message'] = 'signature valid'
            $files.Add($file.ToLowerInvariant())
            Write-BuildLog -Level Ok -Message ("{0}: {1}, signed by {2}" -f $name, (Format-Size $r['size']), $subject)
        } catch {
            $r['message'] = ConvertTo-SingleLine $_.Exception.Message 300
            Write-BuildLog -Level Warn -Message ("Installer '{0}' is NOT baked in: {1}" -f $name, $r['message'])
            if ($file -and $file -notmatch '[\\/]') {
                $bad = Join-Path $TargetDir $file
                if (-not $files.Contains($file.ToLowerInvariant()) -and (Test-Path -LiteralPath $bad -PathType Leaf)) { Remove-Item -LiteralPath $bad -Force -ErrorAction SilentlyContinue }
            }
        }
        [void]$results.Add($r)
    }
    return , $results.ToArray()
}

# ---------------------------------------------------------------------------------------------
# Windows 11 download (Get-WindowsIso.ps1)
# ---------------------------------------------------------------------------------------------
function Invoke-WindowsIsoDownload {
    # Runs Get-WindowsIso.ps1 in this process. Its last pipeline object is the ISO path; it reuses a
    # valid ISO already at -OutFile; when Microsoft refuses it throws (called from a script).
    param([Parameter(Mandatory = $true)][string]$ScriptPath, [string]$Lang, [Parameter(Mandatory = $true)][string]$OutFile, [string]$LogPath)
    $hint = 'Download it yourself from https://www.microsoft.com/software-download/windows11 (Windows 11 multi-edition ISO for x64 devices), then build with -IsoPath <file> (GUI: "Use my ISO").'
    $info = Get-Command -Name $ScriptPath -ErrorAction Stop
    $names = @($info.Parameters.Keys)
    if (-not ($names -contains 'OutFile')) { throw 'builder\Get-WindowsIso.ps1 has no -OutFile parameter (outdated file?).' }
    $splat = @{ OutFile = $OutFile }
    if ($names -contains 'Language' -and $Lang) { $splat['Language'] = $Lang }
    # Its protocol mode never prompts, so it is also used for -Yes (lines are re-emitted below).
    $quiet = (-not (Test-CanPrompt))
    if ($names -contains 'ProgressProtocol' -and ($script:UseProtocol -or $quiet)) { $splat['ProgressProtocol'] = $true }
    # GUI / CI / -Yes: no browser window (the GUI shows its own "open the Microsoft page" button).
    if ($names -contains 'NoBrowser' -and $quiet) { $splat['NoBrowser'] = $true }
    if ($names -contains 'LogPath' -and $LogPath) { $splat['LogPath'] = $LogPath }
    $state = @{ Path = $null; Error = $null }
    try {
        # 6>&1: Write-Host output of the download script comes back here, so its progress lines can
        # be rescaled into this build's 2-30 % range (keeps the GUI progress monotonic).
        & $ScriptPath @splat 6>&1 | ForEach-Object {
            $item = $_
            $isOutput = $true
            if ($item -is [System.Management.Automation.InformationRecord]) { $text = [string]$item.MessageData; $isOutput = $false }
            elseif ($item -is [System.IO.FileInfo]) { $state.Path = $item.FullName; return }
            else { $text = [string]$item }
            if ($text -match '^##LITEOS-PROGRESS\s+(\d{1,3})\s*(.*)$') {
                $pct = [double]$Matches[1]
                if ($pct -gt 100) { $pct = 100 }
                $what = $Matches[2].Trim()
                if (-not $what) { $what = 'downloading' }
                if ($script:UseProtocol) {
                    Write-ProgressLine -Percent (2 + $pct * 0.28) -Message ('Downloading Windows 11: ' + $what)
                } else {
                    Write-Progress -Activity 'Downloading Windows 11 from Microsoft' -Status $what -PercentComplete ([int]$pct)
                }
                return
            }
            if ($text -match '^##LITEOS-RESULT\s+(\S+)\s*(.*)$') {
                if ($Matches[1] -eq 'error') { $state.Error = $Matches[2].Trim() }
                elseif ($Matches[2] -match '^(.*?\.iso)(\s+[0-9A-Fa-f]{64})?\s*$') { $state.Path = $Matches[1].Trim() }
                return
            }
            if ($isOutput -and $text -match '(?i)\.iso$' -and (Test-Path -LiteralPath $text -PathType Leaf)) { $state.Path = $text; return }
            if ($text.Trim()) { Write-BuildLog -Message $text.Trim() }
        }
    } catch {
        throw ('Windows 11 could not be downloaded from Microsoft: {0}. {1}' -f (ConvertTo-SingleLine $_.Exception.Message 300), $hint)
    } finally {
        if (-not $script:UseProtocol) { Write-Progress -Activity 'Downloading Windows 11 from Microsoft' -Completed }
    }
    $final = $null
    if (Test-Path -LiteralPath $OutFile -PathType Leaf) { $final = $OutFile }
    elseif ($state.Path -and (Test-Path -LiteralPath $state.Path -PathType Leaf)) { $final = [string]$state.Path }
    if (-not $final) {
        $why = 'no ISO file was produced'
        if ($state.Error) { $why = $state.Error }
        throw ('Windows 11 could not be downloaded from Microsoft: {0}. {1}' -f $why, $hint)
    }
    $len = (Get-Item -LiteralPath $final).Length
    if ($len -lt 2GB) { throw ('The downloaded file {0} is only {1}; it is not a complete Windows 11 ISO. {2}' -f $final, (Format-Size $len), $hint) }
    return $final
}

# ---------------------------------------------------------------------------------------------
# Image removals (builder\LiteOS.Image.psm1)
# ---------------------------------------------------------------------------------------------
function Invoke-RemovalBatch {
    # One stage of the image removals: 'Dism' (hives NOT loaded: capability / feature / package types
    # and the "appx" parts) or 'Hives' (everything else, hives loaded). See builder\LiteOS.Image.psm1.
    param([object[]]$Batch, [string]$MountPath, [hashtable]$Hives, [string]$Scratch, [Parameter(Mandatory = $true)][ValidateSet('Dism', 'Hives')][string]$Stage)
    $items = @($Batch | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) {
        Write-BuildLog -Message 'Nothing to remove in this group.'
        return , @()
    }
    foreach ($rm in $items) {
        $what = [string](Get-Field $rm 'type' '?')
        if ($Stage -eq 'Dism' -and -not ($script:DismRemovalTypes -contains $what.ToLowerInvariant())) { $what = 'appx part' }
        Write-BuildLog -Message ('queued {0} ({1})' -f (Get-Field $rm 'id' '?'), $what)
    }
    $splat = Get-OptionalSplat -CommandName 'Invoke-LiteOSImageRemovals' -Base @{ MountPath = $MountPath; Removals = $items; Hives = $Hives; Stage = $Stage } -Optional @{ LogPath = $script:DismLog; ScratchDirectory = $Scratch }
    # '| ForEach-Object { $_ }' flattens APIs that return one array object (return , $list).
    $res = Select-ResultObjects -Items @(Invoke-LiteOSImageRemovals @splat | ForEach-Object { $_ })
    foreach ($r in $res) {
        $s = [string](Get-Field $r 'status' '?')
        $line = '{0,-9} {1}: {2}' -f $s, (Get-Field $r 'id' '?'), (ConvertTo-SingleLine ([string](Get-Field $r 'message' '')) 250)
        $nd = @(Get-Field $r 'deferred' @()).Count
        if ($nd -gt 0) { $line += (' [{0} action(s) for SetupComplete]' -f $nd) }
        if ($s -eq 'failed') { Write-BuildLog -Level Warn -Message $line } else { Write-BuildLog -Message $line }
    }
    return , $res
}

function ConvertTo-RemovalDeferred {
    # Deferred actions of the (merged) removal results -> deferred tweaks in the engine's
    # deferred.json format (one per removal id; SetupComplete applies them as SYSTEM).
    param([object[]]$Results, [object[]]$Removals)
    $out = New-Object System.Collections.ArrayList
    foreach ($r in @($Results)) {
        if ($null -eq $r) { continue }
        $acts = @(@(Get-Field $r 'deferred' @()) | Where-Object { $null -ne $_ })
        if ($acts.Count -eq 0) { continue }
        $rid = [string](Get-Field $r 'id' '')
        if (-not $rid) { continue }
        $src = $null
        foreach ($x in @($Removals)) { if ([string](Get-Field $x 'id' '') -eq $rid) { $src = $x; break } }
        $lvl = 'balanced'
        if ($null -ne $src -and ([string](Get-Field $src 'mode' '')).ToLowerInvariant() -eq 'core') { $lvl = 'extreme' }
        [void]$out.Add([pscustomobject]@{
                id       = $rid
                name     = [string](Get-Field $r 'name' $rid)
                category = 'image'
                level    = $lvl
                reboot   = $false
                minBuild = $null
                maxBuild = $null
                actions  = $acts
            })
    }
    return , $out.ToArray()
}

function Export-DeferredFile {
    # deferred.json via the engine's Export-LiteOSDeferred; falls back to the contract format
    # { tweaks: [ {id, actions} ] } if the API is missing or refuses the input (e.g. empty list).
    param([object[]]$Deferred, [string]$Path, [string]$MountPath)
    $items = @($Deferred | Where-Object { $null -ne $_ })
    $cmd = Get-Command -Name 'Export-LiteOSDeferred' -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        $keys = @($cmd.Parameters.Keys)
        $splat = @{}
        foreach ($k in @('Deferred', 'Tweaks', 'InputObject', 'Items')) { if ($keys -contains $k) { $splat[$k] = $items; break } }
        $pathKey = $null
        foreach ($k in @('Path', 'OutFile', 'FilePath', 'LiteralPath', 'Destination')) { if ($keys -contains $k) { $pathKey = $k; break } }
        if ($pathKey) { $splat[$pathKey] = $Path } elseif ($keys -contains 'MountPath') { $splat['MountPath'] = $MountPath }
        if ($splat.Count -ge 2) {
            try {
                Export-LiteOSDeferred @splat | Out-Null
                if (Test-Path -LiteralPath $Path -PathType Leaf) { return 'Export-LiteOSDeferred' }
                Write-BuildLog -Level Warn -Message 'Export-LiteOSDeferred did not write C:\LiteOS\deferred.json; writing it directly.'
            } catch {
                Write-BuildLog -Level Warn -Message ("Export-LiteOSDeferred failed ({0}); writing deferred.json directly." -f (ConvertTo-SingleLine $_.Exception.Message 200))
            }
        } else {
            Write-BuildLog -Level Warn -Message 'Export-LiteOSDeferred has unexpected parameters; writing deferred.json directly.'
        }
    } else {
        Write-BuildLog -Level Warn -Message 'Export-LiteOSDeferred is not available in the engine; writing deferred.json directly.'
    }
    $list = New-Object System.Collections.ArrayList
    foreach ($d in $items) {
        [void]$list.Add([ordered]@{ id = [string](Get-Field $d 'id' ''); actions = @(Get-Field $d 'actions' @()) })
    }
    Write-TextFile -Path $Path -Text (ConvertTo-Json -InputObject ([ordered]@{ tweaks = $list.ToArray() }) -Depth 20)
    return 'builder'
}

# ---------------------------------------------------------------------------------------------
# Work directory handling (never deletes anything it did not create)
# ---------------------------------------------------------------------------------------------
function Initialize-WorkDir {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { throw "WorkDir '$Path' is a file." }
    if (Test-Path -LiteralPath $Path) {
        $items = @(Get-ChildItem -LiteralPath $Path -Force)
        $marker = Join-Path $Path $script:WorkMarker
        if ($items.Count -gt 0 -and -not (Test-Path -LiteralPath $marker)) {
            throw "WorkDir '$Path' is not empty and was not created by the Lite OS builder. Choose another -WorkDir."
        }
        foreach ($m in @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue)) {
            if (Test-PathUnder -Child $m.Path -Parent $Path) {
                Write-BuildLog -Level Warn -Message ("Discarding image left mounted at {0} by an earlier run." -f $m.Path)
                try {
                    Dismount-WindowsImage -Path $m.Path -Discard | Out-Null
                } catch {
                    Write-BuildLog -Level Warn -Message ("Discard failed ({0}); cleaning up corrupt mount points and retrying." -f $_.Exception.Message)
                    try {
                        Clear-WindowsCorruptMountPoint | Out-Null
                        Dismount-WindowsImage -Path $m.Path -Discard | Out-Null
                    } catch {
                        throw ("An image from an earlier run is still mounted at {0} and could not be discarded ({1}). From an elevated prompt run:  dism /Unmount-Image /MountDir:""{0}"" /Discard   then   dism /Cleanup-Wim   and start the builder again." -f $m.Path, $_.Exception.Message)
                    }
                }
            }
        }
        foreach ($child in $script:WorkChildren) {
            $c = Join-Path $Path $child
            if (Test-Path -LiteralPath $c) { Remove-Item -LiteralPath $c -Recurse -Force }
        }
    } else {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $Path $script:WorkMarker) -Value 'Created by Lite OS Build-LiteOS.ps1. Safe to delete when no build is running.' -Encoding ASCII
    foreach ($child in $script:WorkChildren) {
        New-Item -ItemType Directory -Path (Join-Path $Path $child) -Force | Out-Null
    }
}

function Clear-WorkDir {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath (Join-Path $Path $script:WorkMarker))) { return }
    foreach ($m in @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue)) {
        if (Test-PathUnder -Child $m.Path -Parent $Path) {
            Write-BuildLog -Level Warn -Message "Not deleting $Path because an image is still mounted at $($m.Path)."
            return
        }
    }
    foreach ($child in $script:WorkChildren) {
        $c = Join-Path $Path $child
        if (Test-Path -LiteralPath $c) {
            try { Remove-Item -LiteralPath $c -Recurse -Force } catch { Write-BuildLog -Level Warn -Message "Could not delete ${c}: $($_.Exception.Message)" }
        }
    }
    # The download folder only goes when it is empty (a kept ISO stays for -IsoPath builds).
    $dl = Join-Path $Path 'download'
    if ((Test-Path -LiteralPath $dl) -and @(Get-ChildItem -LiteralPath $dl -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -LiteralPath $dl -Force -ErrorAction SilentlyContinue
    }
    if (@(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $script:WorkMarker }).Count -eq 0) {
        Remove-Item -LiteralPath (Join-Path $Path $script:WorkMarker) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Cleanup {
    param([bool]$Failed)
    foreach ($h in @($script:LoadedHives)) {
        [void](Dismount-OfflineHive -Name $h)
    }
    foreach ($m in @($script:MountedImages)) {
        Write-BuildLog -Message "Discarding mounted image at $m ..."
        try {
            Dismount-WindowsImage -Path $m -Discard -LogPath $script:DismLog | Out-Null
            $script:MountedImages.Remove($m)
        } catch {
            Write-BuildLog -Level Warn -Message ("Discard failed for {0}: {1}" -f $m, $_.Exception.Message)
        }
    }
    if ($script:IsoAttachedByUs -and $script:IsoFullPath) {
        try {
            Dismount-DiskImage -ImagePath $script:IsoFullPath | Out-Null
            $script:IsoAttachedByUs = $false
        } catch {
            Write-BuildLog -Level Warn -Message ("Could not dismount the ISO: {0}" -f $_.Exception.Message)
        }
    }
    if ($script:DownloadedIso -and (Test-Path -LiteralPath $script:DownloadedIso -PathType Leaf) -and (Test-PathUnder -Child $script:DownloadedIso -Parent $script:DownloadDir)) {
        # Kept: -KeepDownload / -KeepWorkDir, or a complete download after a failed build (retry
        # with -IsoPath). A partial download is always deleted.
        $keep = ($KeepDownload -or $KeepWorkDir -or $Failed) -and $script:DownloadCompleted
        if ($keep) {
            Write-BuildLog -Message ("The downloaded Windows 11 ISO is kept at {0} - build again with -IsoPath ""{0}"" to skip the download." -f $script:DownloadedIso)
        } else {
            try {
                Remove-Item -LiteralPath $script:DownloadedIso -Force
                Write-BuildLog -Message 'Downloaded Windows 11 ISO deleted (use -KeepDownload to keep it).'
            } catch {
                Write-BuildLog -Level Warn -Message ("Could not delete the downloaded ISO {0}: {1}" -f $script:DownloadedIso, $_.Exception.Message)
            }
        }
    }
    if ($script:WorkRoot -and -not $KeepWorkDir -and $script:LoadedHives.Count -eq 0 -and $script:MountedImages.Count -eq 0) {
        Clear-WorkDir -Path $script:WorkRoot
    }
    if ($Failed) {
        Write-Host ''
        Write-BuildLog -Level Warn -Message 'The build did not finish. Nothing on this PC was changed except the work folder.'
        if ($script:MountedImages.Count -gt 0 -or $script:LoadedHives.Count -gt 0) {
            Write-BuildLog -Level Warn -Message 'Some items could not be cleaned up automatically. From an elevated prompt run:'
            foreach ($h in @($script:LoadedHives)) { Write-Host ("      reg unload HKLM\{0}" -f $h) }
            foreach ($m in @($script:MountedImages)) { Write-Host ("      dism /Unmount-Image /MountDir:""{0}"" /Discard" -f $m) }
        }
        Write-BuildLog -Message 'If DISM reports stale mounts later, run:  dism /Cleanup-Wim   (or Clear-WindowsCorruptMountPoint). The next build also cleans up leftovers.'
        if ($script:LogFile) { Write-BuildLog -Message ("Full log: {0}" -f $script:LogFile) }
    }
}

function Write-BuildReport {
    # Machine-readable summary next to the ISO (CI uploads it; it never contains the ISO/WIM).
    param([string]$Status, [string]$ErrorText, [string]$FallbackDir, [string]$Stamp)
    try {
        $r = [ordered]@{}
        $r['tool'] = 'Lite OS Build-LiteOS.ps1'
        $r['version'] = $script:BuilderVersion
        $r['status'] = $Status
        if ($ErrorText) { $r['error'] = $ErrorText }
        foreach ($k in @($script:Report.Keys)) { $r[$k] = $script:Report[$k] }
        $r['finishedAt'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $r['warnings'] = [string[]]@($script:WarningList)
        $path = $script:ReportPath
        if (-not $path) {
            if (-not $FallbackDir -or -not (Test-Path -LiteralPath $FallbackDir)) { return $null }
            $path = Join-Path $FallbackDir ('LiteOS-{0}-{1}.report.json' -f $Mode, $Stamp)
        }
        Write-TextFile -Path $path -Text (ConvertTo-Json -InputObject $r -Depth 12)
        Write-BuildLog -Message ("Build report: {0}" -f $path)
        return $path
    } catch {
        Write-Verbose ('Report write failed: ' + $_.Exception.Message)
        return $null
    }
}

# =============================================================================================
# Main
# =============================================================================================
$isoSourceRoot    = $null
$installSource    = $null
$outFull          = $null
$outDir           = $null
$logDir           = $null
$selected         = $null
$imageBuild       = 0
$imageRevision    = 0
$imageLang        = 'xx'
$level            = 'Balanced'
$hash             = $null
$removedApps      = New-Object System.Collections.ArrayList
$offlineLog       = New-Object System.Collections.ArrayList
$appxResults      = New-Object System.Collections.ArrayList
$removalResults   = New-Object System.Collections.ArrayList
$installerResults = @()
$tweakResults     = @()
$deferred         = @()
$startStamp       = (Get-Date).ToString('yyyyMMdd-HHmmss')

try {
    if ($Mode -eq 'Core') { $Mode = 'Core'; $level = 'Extreme' } else { $Mode = 'Lite'; $level = 'Balanced' }
    $bypass         = -not $NoBypassRequirements
    $includeList    = ConvertTo-IdList -Values $Include
    $excludeList    = ConvertTo-IdList -Values $Exclude
    $appsList       = ConvertTo-IdList -Values $Apps
    $installersList = ConvertTo-IdList -Values $Installers
    $repoRoot       = Split-Path -Parent $PSScriptRoot
    if ($ProgressProtocol) { $ProgressPreference = 'SilentlyContinue' }
    $script:Report['startedAt'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $script:Report['mode'] = $Mode
    $script:Report['level'] = $level

    # Log (and report) next to the requested output, or in the current folder.
    $logDir = (Get-Location).ProviderPath
    if ($OutputPath) {
        $reqFull = Resolve-FullPath $OutputPath
        if (Test-OutputIsFolder -Requested $OutputPath -Full $reqFull) { $candidate = $reqFull } else { $candidate = Split-Path -Parent $reqFull }
        if ($candidate) {
            if (-not (Test-Path -LiteralPath $candidate)) { New-Item -ItemType Directory -Path $candidate -Force | Out-Null }
            $logDir = $candidate
        }
    }
    $script:LogFile = Join-Path $logDir ("LiteOS-build-{0}.log" -f $startStamp)
    $script:DismLog = Join-Path $logDir ("LiteOS-build-{0}.dism.log" -f $startStamp)

    Write-Host ''
    Write-Host ('Lite OS Builder {0}' -f $script:BuilderVersion) -ForegroundColor White
    Write-Host 'Scripts only: uses the OFFICIAL Windows 11 ISO from Microsoft. No Windows files, keys or activators are added.'
    Write-BuildLog -Message ("Log file: {0}" -f $script:LogFile)

    # -----------------------------------------------------------------------------------------
    Write-Step 'Pre-flight checks' 1
    # -----------------------------------------------------------------------------------------
    if (-not (Test-IsAdmin)) { throw 'Run this script from an elevated PowerShell (Run as administrator).' }
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell (not the x86 version).' }
    if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'Windows PowerShell 5.1 or newer is required.' }
    $neededCmdlets = @('Mount-WindowsImage', 'Dismount-WindowsImage', 'Export-WindowsImage', 'Get-WindowsImage', 'Get-AppxProvisionedPackage', 'Remove-AppxProvisionedPackage', 'Mount-DiskImage', 'Get-DiskImage', 'Dismount-DiskImage', 'Get-AuthenticodeSignature')
    if ($SplitWim) { $neededCmdlets += 'Split-WindowsImage' }
    foreach ($cmd in $neededCmdlets) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "Required cmdlet '$cmd' is missing (DISM / Storage / Security modules)." }
    }
    if (-not (Test-Path -LiteralPath $script:RegExe)) { throw "reg.exe not found at $script:RegExe" }
    $hostBuild = [Environment]::OSVersion.Version.Build
    if ($hostBuild -lt 22000) {
        Write-BuildLog -Level Warn -Message "This PC runs Windows build $hostBuild. Building on Windows 11 (or with the latest Windows ADK) is recommended for servicing 24H2+ images."
    }

    if ($Download -and $IsoPath) { throw 'Use either -IsoPath <official ISO> or -Download, not both.' }
    if (-not $Download -and -not $IsoPath) { throw 'No Windows 11 source: pass -IsoPath <official Windows 11 ISO> or -Download (downloads it from Microsoft).' }

    $isoScript   = Join-Path $PSScriptRoot 'New-IsoFile.ps1'
    $template    = Join-Path $PSScriptRoot 'autounattend.xml'
    $imageModule = Join-Path $PSScriptRoot 'LiteOS.Image.psm1'
    $getIso      = Join-Path $PSScriptRoot 'Get-WindowsIso.ps1'
    $needFiles = @($isoScript, $template, $imageModule)
    if ($Download) { $needFiles += $getIso }
    foreach ($f in $needFiles) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "Builder file missing: $f. Use a complete Lite OS release folder." }
    }
    foreach ($p in @('LiteOS.ps1', 'src\LiteOS.Engine.psm1', 'tweaks', 'image\removals.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $p))) { throw "Lite OS payload incomplete: '$p' not found under $repoRoot. Use a complete Lite OS release folder." }
    }
    # Importing the modules has no side effects.
    Import-Module -Name (Join-Path $repoRoot 'src\LiteOS.Engine.psm1') -Force -DisableNameChecking -ErrorAction Stop
    Import-Module -Name $imageModule -Force -DisableNameChecking -ErrorAction Stop
    foreach ($fn in @('Initialize-LiteOS', 'Get-LiteOSCatalog', 'Select-LiteOSTweaks', 'Invoke-LiteOSOfflinePlan', 'Get-LiteOSProtectedApps', 'Test-LiteOSProtectedApp', 'Get-LiteOSRemovals', 'Select-LiteOSRemovals', 'Invoke-LiteOSImageRemovals', 'Merge-LiteOSRemovalResults', 'Invoke-LiteOSImageCleanup')) {
        if (-not (Get-Command -Name $fn -ErrorAction SilentlyContinue)) { throw "Lite OS payload too old or incomplete: $fn is missing (engine / image module). Use a complete Lite OS 2.x release folder." }
    }
    if (-not (Get-Command -Name 'Invoke-LiteOSImageRemovals').Parameters.ContainsKey('Stage')) {
        throw 'Lite OS payload too old or incomplete: Invoke-LiteOSImageRemovals has no -Stage parameter (builder\LiteOS.Image.psm1). Use a complete Lite OS 2.x release folder.'
    }

    # Options
    if ($appsList.Count -eq 0) { $appsList = @('none') }
    $kw = @($appsList | Where-Object { @('default', 'none', 'all') -contains $_.ToLowerInvariant() })
    if ($kw.Count -gt 0 -and $appsList.Count -gt 1) { throw "-Apps: use either 'default', 'none', 'all' or a list of winget ids, not both." }
    if ($kw.Count -eq 1) { $appsValue = $kw[0].ToLowerInvariant() } else { $appsValue = [string[]]$appsList }
    $appsInstallPath = Join-Path $repoRoot 'tweaks\apps-install.json'
    if ($appsValue -is [array] -and (Test-Path -LiteralPath $appsInstallPath)) {
        try {
            $known = @(@(Get-Field (Read-JsonFile -Path $appsInstallPath) 'apps' @()) | ForEach-Object { [string](Get-Field $_ 'id' '') })
            foreach ($a in $appsValue) {
                if (-not ($known -contains $a)) { Write-BuildLog -Level Warn -Message "App id '$a' is not in tweaks\apps-install.json (it will still be passed to winget)." }
            }
        } catch { Write-BuildLog -Level Warn -Message "tweaks\apps-install.json could not be parsed: $($_.Exception.Message)" }
    }

    # Work dir + space (the downloaded ISO also lives in the work folder).
    if (-not $WorkDir) { $WorkDir = Join-Path $env:SystemDrive 'LiteOS-Build' }
    $script:WorkRoot = Resolve-FullPath $WorkDir
    $space = Get-DriveSpace -Path $script:WorkRoot
    if ($space.Type -ne 'Fixed') { Write-BuildLog -Level Warn -Message "WorkDir drive $($space.Root) is not a fixed disk ($($space.Type)); DISM may refuse to mount there." }
    if ($space.Format -ne 'NTFS') { Write-BuildLog -Level Warn -Message "WorkDir drive $($space.Root) is $($space.Format); DISM mounts need NTFS." }
    $needGb = 30
    if ($Download) { $needGb = 40 }
    if ($space.Free -lt ([int64]$needGb * 1GB)) {
        throw ("Not enough free space on {0}: {1} free, {2} GB needed{3}. Free some space or use -WorkDir on another NTFS drive." -f $space.Root, (Format-Size $space.Free), $needGb, $(if ($Download) { ' (including the Windows download)' } else { '' }))
    }
    Write-BuildLog -Message ("Work folder: {0} ({1} free on {2})" -f $script:WorkRoot, (Format-Size $space.Free), $space.Root)
    if ($OutputPath -and (Test-PathUnder -Child (Resolve-FullPath $OutputPath) -Parent $script:WorkRoot)) { throw 'OutputPath must not be inside WorkDir.' }
    if (Test-PathUnder -Child $logDir -Parent $script:WorkRoot) { throw 'Run the builder from (or set -OutputPath to) a folder outside WorkDir.' }

    # Leftover hives first: while a hive from mount\Windows\System32\config is loaded, DISM cannot
    # discard that mount.
    foreach ($h in $script:HiveNames) {
        if (Test-HiveLoaded -Name $h) {
            Write-BuildLog -Level Warn -Message "Unloading leftover hive HKLM\$h from an earlier run."
            if (-not (Dismount-OfflineHive -Name $h)) { throw "HKLM\$h from an earlier run is still loaded. Close Registry Editor, run: reg unload HKLM\$h  and start the builder again." }
        }
    }
    Initialize-WorkDir -Path $script:WorkRoot
    $isoDir     = Join-Path $script:WorkRoot 'iso'
    $mountDir   = Join-Path $script:WorkRoot 'mount'
    $bootMount  = Join-Path $script:WorkRoot 'bootmount'
    $scratch    = Join-Path $script:WorkRoot 'scratch'
    $stageDir   = Join-Path $script:WorkRoot 'stage'
    $stageWim   = Join-Path $stageDir 'install.wim'
    $instDir    = Join-Path $script:WorkRoot 'installers'
    $script:DownloadDir = Join-Path $script:WorkRoot 'download'

    # Engine context: state in the work folder, log lines go to this build log.
    $ctx = Initialize-LiteOS -StateRoot (Join-Path $script:WorkRoot 'engine') -Level $level -LogFile $script:LogFile

    # Catalogs (fail early on schema errors, before any download or DISM work).
    # '| ForEach-Object { $_ }' flattens APIs that return one array object (return , $list).
    $catalog = @(Get-LiteOSCatalog -Path (Join-Path $repoRoot 'tweaks') | ForEach-Object { $_ })
    $removals = @(Get-LiteOSRemovals -Path (Join-Path $repoRoot 'image\removals.json') | ForEach-Object { $_ })
    Write-BuildLog -Message ("Catalog: {0} tweaks, {1} image removals." -f $catalog.Count, $removals.Count)
    $tweakIds = @($catalog | ForEach-Object { [string](Get-Field $_ 'id' '') })
    $removalIds = @($removals | ForEach-Object { [string](Get-Field $_ 'id' '') })
    $incSplit = Split-IdPattern -Patterns $includeList -TweakIds $tweakIds -RemovalIds $removalIds -What '-Include'
    $excSplit = Split-IdPattern -Patterns $excludeList -TweakIds $tweakIds -RemovalIds $removalIds -What '-Exclude'
    $tweakInclude = [string[]]@($incSplit.Tweaks)
    $tweakExclude = [string[]]@($excSplit.Tweaks)
    $removalInclude = [string[]]@($incSplit.Removals)
    $removalExclude = [string[]]@($excSplit.Removals)
    $selArgs = @{ Removals = $removals; Mode = $Mode }
    if ($removalInclude.Count -gt 0) { $selArgs['Include'] = $removalInclude }
    if ($removalExclude.Count -gt 0) { $selArgs['Exclude'] = $removalExclude }
    $selectedRemovals = @(Select-LiteOSRemovals @selArgs | ForEach-Object { $_ } | Where-Object { $null -ne $_ })
    Write-BuildLog -Message ("Mode {0}: {1} image removal(s) selected: {2}" -f $Mode, $selectedRemovals.Count, ((@($selectedRemovals | ForEach-Object { Get-Field $_ 'id' '?' })) -join ', '))
    $edgeRemoved = (@($selectedRemovals | Where-Object { ([string](Get-Field $_ 'type' '')) -eq 'edge' }).Count -gt 0)

    # A removal can rule out tweaks that would undo it in the same image (removals.json "conflicts";
    # e.g. image.windows-update writes NoAutoUpdate=1, updates.no-auto-restart / notify-only write 0
    # and run later). Those tweaks are excluded (Exclude wins, as everywhere).
    $conflictTweaks = New-Object System.Collections.Generic.List[string]
    foreach ($rm in $selectedRemovals) {
        foreach ($c in @(Get-Field $rm 'conflicts' @())) {
            $cid = ([string]$c).Trim()
            if (-not $cid -or $conflictTweaks.Contains($cid)) { continue }
            $conflictTweaks.Add($cid)
            $how = 'not baked into the image'
            if (Test-IdMatch -Id $cid -Patterns $tweakInclude) { $how = 'dropped although you included it' }
            Write-BuildLog -Level Warn -Message ("Tweak {0} is {1}: it would undo removal {2}." -f $cid, $how, (Get-Field $rm 'id' '?'))
        }
    }
    if ($conflictTweaks.Count -gt 0) { $tweakExclude = [string[]](@($tweakExclude) + @($conflictTweaks.ToArray())) }

    # Core (and Lite with Core-only removals included) breaks the Lite promise: warn + confirm.
    $coreItems = @($selectedRemovals | Where-Object { ([string](Get-Field $_ 'mode' '')).ToLowerInvariant() -eq 'core' })
    if ($Mode -eq 'Core' -or $coreItems.Count -gt 0) {
        Write-Host ''
        if ($Mode -eq 'Core') {
            Write-BuildLog -Level Warn -Message 'CORE mode (Windows X-Lite style) was requested. Read this before you continue:'
        } else {
            Write-BuildLog -Level Warn -Message 'This Lite build includes Core-only removals, so the Lite promises below may not hold:'
        }
        Write-Host '    - Core removes or disables Windows Defender, the Windows Update stack, the Edge browser' -ForegroundColor Yellow
        Write-Host '      (WebView2 and its updater are kept) and Windows RE (disabled after Setup), and applies the Extreme tweaks.' -ForegroundColor Yellow
        Write-Host '    - The result is NOT serviceable: no Windows Update. To update, build again from a newer ISO.' -ForegroundColor Yellow
        Write-Host '    - Microsoft Store / Xbox Game Pass installs and updates stop working (they need the Windows Update service).' -ForegroundColor Yellow
        Write-Host '    - Security is lower. Some anti-cheat or work apps may not work.' -ForegroundColor Yellow
        foreach ($c in $coreItems) { Write-Host ('    - removes: {0} ({1})' -f (Get-Field $c 'name' (Get-Field $c 'id' '?')), (Get-Field $c 'id' '?')) -ForegroundColor Yellow }
        if (-not $Yes -and -not $Force) {
            if (-not (Test-CanPrompt)) { throw 'Core removals need confirmation: re-run with -Yes to accept the warnings above.' }
            $answer = Read-Host '  Type CORE to continue'
            if ($answer -cne 'CORE') { throw 'Core not confirmed; nothing was built.' }
        }
    }

    # Installers plan (pure) - downloaded later on this PC.
    $installersJsonPath = Join-Path $repoRoot 'image\installers.json'
    $installerPlan = @()
    if (Test-Path -LiteralPath $installersJsonPath -PathType Leaf) {
        # Get-InstallerPlan returns one array object: assign it directly (no @() wrapper).
        $installerPlan = Get-InstallerPlan -Json (Read-JsonFile -Path $installersJsonPath) -ModeName $Mode -Requested $installersList
    } elseif (-not (@($installersList | Where-Object { $_ -eq 'none' }).Count -gt 0)) {
        Write-BuildLog -Level Warn -Message 'image\installers.json not found; no installers are baked in.'
    }
    Write-BuildLog -Message ("Installers to bake in: {0}" -f $(if ($installerPlan.Count -gt 0) { (@($installerPlan | ForEach-Object { Get-Field $_ 'id' '?' })) -join ', ' } else { 'none' }))
    Write-BuildLog -Message ("Mode: {0} (tweaks {1}) | Edition: {2} | First-logon apps: {3} | Requirement bypass: {4} | Auto device encryption: {5}" -f $Mode, $level, $Edition, ($appsList -join ','), $(if ($bypass) { 'on' } else { 'off' }), $(if ($KeepAutoEncryption) { 'kept' } else { 'prevented' }))
    $script:Report['options'] = [ordered]@{
        edition              = $Edition
        include              = [string[]]$includeList
        exclude              = [string[]]$excludeList
        apps                 = $appsValue
        installers           = [string[]]$installersList
        bypassRequirements   = [bool]$bypass
        keepAutoEncryption   = [bool]$KeepAutoEncryption
        download             = [bool]$Download
    }

    # -----------------------------------------------------------------------------------------
    if ($Download) { Write-Step 'Downloading Windows 11 from Microsoft' 2 } else { Write-Step 'Checking the Windows 11 ISO' 2 }
    # -----------------------------------------------------------------------------------------
    if ($Download) {
        if (-not (Test-Path -LiteralPath $script:DownloadDir)) { New-Item -ItemType Directory -Path $script:DownloadDir -Force | Out-Null }
        $slug = ($Language -replace '[^A-Za-z0-9]+', '-').Trim('-')
        if (-not $slug) { $slug = 'default' }
        $dlFile = Join-Path $script:DownloadDir ('Win11-{0}-x64.iso' -f $slug)
        $script:DownloadedIso = $dlFile
        Write-BuildLog -Message ("Language: {0}. This downloads about 5-7 GB from Microsoft's own servers." -f $Language)
        $got = Invoke-WindowsIsoDownload -ScriptPath $getIso -Lang $Language -OutFile $dlFile -LogPath (Join-Path $logDir ("LiteOS-build-{0}.download.log" -f $startStamp))
        $script:DownloadedIso = $got
        $script:DownloadCompleted = $true
        $IsoPath = $got
        Write-BuildLog -Level Ok -Message ("Downloaded {0} ({1})" -f (Split-Path -Leaf $got), (Format-Size (Get-Item -LiteralPath $got).Length))
        # From here on the build scale runs from 30 to 100 %.
        $script:ProgressBase = 30.0
        $script:ProgressScale = 0.70
    }
    if (-not (Test-Path -LiteralPath $IsoPath)) { throw "ISO not found: $IsoPath" }
    $script:IsoFullPath = (Resolve-Path -LiteralPath $IsoPath).ProviderPath
    $sourceIsFolder = Test-Path -LiteralPath $script:IsoFullPath -PathType Container
    if (-not $sourceIsFolder -and [IO.Path]::GetExtension($script:IsoFullPath) -ne '.iso') {
        Write-BuildLog -Level Warn -Message "'$($script:IsoFullPath)' does not end in .iso; trying anyway."
    }
    if ((Test-PathUnder -Child $script:IsoFullPath -Parent $script:WorkRoot) -and -not (Test-PathUnder -Child $script:IsoFullPath -Parent $script:DownloadDir)) {
        throw 'The source ISO must not be inside WorkDir (the work folder is emptied on every build).'
    }
    $script:Report['source'] = [ordered]@{ type = $(if ($Download) { 'download' } else { 'iso' }); name = (Split-Path -Leaf $script:IsoFullPath); language = $(if ($Download) { $Language } else { $null }) }

    # -----------------------------------------------------------------------------------------
    Write-Step 'Opening the ISO and choosing the edition' 4
    # -----------------------------------------------------------------------------------------
    if ($sourceIsFolder) {
        $isoSourceRoot = $script:IsoFullPath
        if ($isoSourceRoot.Length -gt 3) { $isoSourceRoot = $isoSourceRoot.TrimEnd('\') }
        Write-BuildLog -Message "Using extracted ISO folder $isoSourceRoot"
    } else {
        $disk = Get-DiskImage -ImagePath $script:IsoFullPath
        if ($disk.Attached) {
            Write-BuildLog -Message 'ISO is already mounted; using the existing drive.'
        } else {
            Mount-DiskImage -ImagePath $script:IsoFullPath -StorageType ISO -Access ReadOnly | Out-Null
            $script:IsoAttachedByUs = $true
        }
        $letter = $null
        for ($i = 0; $i -lt 20 -and -not $letter; $i++) {
            $vol = Get-DiskImage -ImagePath $script:IsoFullPath | Get-Volume -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($vol -and ("$($vol.DriveLetter)" -match '^[A-Za-z]$')) { $letter = "$($vol.DriveLetter)" } else { Start-Sleep -Milliseconds 500 }
        }
        if (-not $letter) { throw 'The ISO was mounted but got no drive letter (is automount disabled?). Extract the ISO to a folder and pass that folder as -IsoPath.' }
        $isoSourceRoot = $letter + ':\'
        Write-BuildLog -Message "ISO mounted as $isoSourceRoot"
    }

    foreach ($rel in @('setup.exe', 'sources\boot.wim', 'boot\etfsboot.com', 'efi\microsoft\boot\efisys.bin')) {
        if (-not (Test-Path -LiteralPath (Join-Path $isoSourceRoot $rel))) { throw "This does not look like Windows installation media: '$rel' is missing." }
    }
    foreach ($name in @('install.wim', 'install.esd')) {
        $c = Join-Path $isoSourceRoot ('sources\' + $name)
        if (Test-Path -LiteralPath $c -PathType Leaf) { $installSource = $c; break }
    }
    if (-not $installSource) {
        if (Test-Path -LiteralPath (Join-Path $isoSourceRoot 'sources\install.swm')) { throw 'Split install.swm media is not supported. Use the ISO from microsoft.com/software-download/windows11 (or -Download).' }
        throw 'sources\install.wim or sources\install.esd not found. Is this a Windows 11 ISO?'
    }
    Write-BuildLog -Message ("Install image: {0}" -f $installSource)
    if (Test-Path -LiteralPath (Join-Path $isoSourceRoot 'autounattend.xml')) {
        Write-BuildLog -Level Warn -Message 'The source media already has an autounattend.xml; it will be replaced by the Lite OS one. Use an untouched official ISO for best results.'
    }

    $images = @(Get-WindowsImage -ImagePath $installSource -LogPath $script:DismLog)
    if ($images.Count -eq 0) { throw 'The install image contains no editions.' }
    $index = Select-ImageIndex -Images $images -Wanted $Edition
    $selected = Get-WindowsImage -ImagePath $installSource -Index $index -LogPath $script:DismLog
    $imageBuild = [int]$selected.Build
    $imageRevision = [int]$selected.SPBuild
    Write-BuildLog -Message ("Selected: [{0}] {1} ({2}), version {3}.{4}.{5}.{6}" -f $index, $selected.ImageName, $selected.EditionId, $selected.MajorVersion, $selected.MinorVersion, $imageBuild, $imageRevision)
    if ([string]$selected.InstallationType -ne 'Client') { throw "This is a '$($selected.InstallationType)' image. Lite OS needs a Windows 11 client (Home/Pro/Education) ISO." }
    if ($selected.MajorVersion -ne 10 -or $imageBuild -lt 22000) { throw "Build $imageBuild is not Windows 11 (needs build 22000 or newer, 26100+ recommended)." }
    if ($imageBuild -lt 26100) { Write-BuildLog -Level Warn -Message "Build $imageBuild is older than 24H2 (26100). Lite OS is designed and tested for 24H2 / 25H2+; some tweaks will be skipped." }
    if ([int]$selected.Architecture -ne 9) { throw ("Only x64 (amd64) images are supported; this image architecture id is {0}." -f $selected.Architecture) }
    if ([string]$selected.EditionId -cmatch 'N$') { Write-BuildLog -Level Warn -Message 'This is an "N" edition without media components. Many games, Xbox app and Game Bar need the Media Feature Pack.' }
    $langs = @(Get-Field $selected 'Languages' @())
    $langIndex = [int](Get-Field $selected 'DefaultLanguageIndex' 0)
    if ($langs.Count -gt 0) {
        $l = [string]$langs[0]
        if ($langIndex -ge 0 -and $langIndex -lt $langs.Count) { $l = [string]$langs[$langIndex] }
        $l = (($l.Trim() -split '\s+')[0]) -replace '[^A-Za-z0-9\-]', ''
        if ($l) { $imageLang = $l }
    }
    $buildText = '{0}.{1}' -f $imageBuild, $imageRevision
    $branding = Get-BrandingInfo -Path (Join-Path $repoRoot 'image\branding.json') -ModeName $Mode -BuildText $buildText
    $wimName = ('{0} {1}' -f $branding['name'], $Mode)
    $script:Report['image'] = [ordered]@{ edition = [string]$selected.ImageName; editionId = [string]$selected.EditionId; build = $buildText; language = $imageLang; wimName = $wimName }

    # Output file: LiteOS-<Mode>-<build>-<lang>.iso
    $isoName = 'LiteOS-{0}-{1}-{2}.iso' -f $Mode, $buildText, $imageLang
    if ($OutputPath) {
        $reqFull = Resolve-FullPath $OutputPath
        if (Test-OutputIsFolder -Requested $OutputPath -Full $reqFull) { $outFull = Join-Path $reqFull $isoName } else { $outFull = $reqFull }
    } else {
        $outFull = Join-Path (Get-Location).ProviderPath $isoName
    }
    if (Test-PathUnder -Child $outFull -Parent $script:WorkRoot) { throw 'OutputPath must not be inside WorkDir.' }
    if (Test-Path -LiteralPath $outFull) {
        if ($Force) {
            Write-BuildLog -Level Warn -Message "$outFull exists and will be overwritten (-Force)."
        } elseif (Test-CanPrompt) {
            $answer = Read-Host ("  {0} already exists. Overwrite it? [y/N]" -f $outFull)
            if ($answer -notmatch '^\s*[Yy]') { throw 'Output file exists; nothing was built. Use -OutputPath or -Force.' }
        } else {
            $base = [IO.Path]::Combine((Split-Path -Parent $outFull), [IO.Path]::GetFileNameWithoutExtension($outFull))
            $n = 2
            while (Test-Path -LiteralPath ('{0}-{1}.iso' -f $base, $n)) { $n++ }
            $newOut = '{0}-{1}.iso' -f $base, $n
            Write-BuildLog -Level Warn -Message ("{0} already exists; writing {1} instead (use -Force to overwrite)." -f $outFull, (Split-Path -Leaf $newOut))
            $outFull = $newOut
        }
    }
    $outDir = Split-Path -Parent $outFull
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $outSpace = Get-DriveSpace -Path $outFull
    if ($outSpace.Root -ne $space.Root -and $outSpace.Free -lt ([int64]8 * 1GB)) {
        throw ("Not enough free space for the ISO on {0}: {1} free, 8 GB needed." -f $outSpace.Root, (Format-Size $outSpace.Free))
    }
    $script:ReportPath = [IO.Path]::ChangeExtension($outFull, '.report.json')
    Write-BuildLog -Message ("Output: {0}" -f $outFull)

    # Tweaks for this image build (engine rules: Balanced / Extreme defaults + include - exclude).
    # The context describes the IMAGE (minBuild / maxBuild, backup header), not this PC.
    $ctx | Add-Member -NotePropertyName ImageBuild -NotePropertyValue $imageBuild -Force
    $ctx | Add-Member -NotePropertyName Mode -NotePropertyValue $Mode -Force
    if ($ctx.PSObject.Properties['Edition']) { $ctx.Edition = [string]$selected.EditionId }
    $selectedTweaks = @(Select-LiteOSTweaks -Catalog $catalog -Level $level -Include $tweakInclude -Exclude $tweakExclude -Build $imageBuild | ForEach-Object { $_ })
    $appxTweaks = @($selectedTweaks | Where-Object { Test-AppxOnlyTweak $_ })
    $planTweaks = @($selectedTweaks | Where-Object { -not (Test-AppxOnlyTweak $_) })
    Write-BuildLog -Message ("{0} tweaks selected ({1} level): {2} app removals, {3} other tweaks." -f $selectedTweaks.Count, $level, $appxTweaks.Count, $planTweaks.Count)

    # -----------------------------------------------------------------------------------------
    Write-Step 'Copying setup files to the work folder' 6
    # -----------------------------------------------------------------------------------------
    $rc = Invoke-Native -FilePath 'robocopy.exe' -ArgumentList @($isoSourceRoot, $isoDir, '/E', '/XF', 'install.wim', 'install.esd', 'install.swm', '/A-:R', '/R:2', '/W:2', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
    if ($rc.ExitCode -ge 8) { throw ("Copying the ISO failed (robocopy exit {0}): {1}" -f $rc.ExitCode, ($rc.Output -join ' ')) }
    foreach ($f in @(Get-ChildItem -LiteralPath $isoDir -Recurse -File -Force | Where-Object { $_.IsReadOnly })) { $f.IsReadOnly = $false }
    Write-BuildLog -Level Ok -Message 'Setup files copied.'

    # -----------------------------------------------------------------------------------------
    Write-Step 'Downloading the official installers (Steam, runtimes)' 8
    # -----------------------------------------------------------------------------------------
    if ($installerPlan.Count -gt 0) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $installerResults = Save-InstallerSet -Plan $installerPlan -TargetDir $instDir
        $okCount = @($installerResults | Where-Object { $_['status'] -eq 'ok' }).Count
        Write-BuildLog -Level Ok -Message ("{0} of {1} installer(s) downloaded and verified." -f $okCount, $installerPlan.Count)
    } else {
        Write-BuildLog -Message 'Skipped (no installers selected).'
    }
    $script:Report['installers'] = $installerResults

    # -----------------------------------------------------------------------------------------
    Write-Step ("Exporting '{0}' as '{1}'" -f $selected.ImageName, $wimName) 15
    # -----------------------------------------------------------------------------------------
    # Staging export uses fast compression; the final install.wim is re-exported with max compression.
    Write-BuildLog -Message 'This takes several minutes (install.esd is decompressed)...'
    try {
        Export-WindowsImage -SourceImagePath $installSource -SourceIndex $index -DestinationImagePath $stageWim -DestinationName $wimName -CompressionType 'fast' -ScratchDirectory $scratch -LogPath $script:DismLog | Out-Null
    } catch {
        Write-BuildLog -Level Warn -Message ("Export with fast compression failed ({0}); retrying with max compression." -f $_.Exception.Message)
        if (Test-Path -LiteralPath $stageWim) { Remove-Item -LiteralPath $stageWim -Force }
        Export-WindowsImage -SourceImagePath $installSource -SourceIndex $index -DestinationImagePath $stageWim -DestinationName $wimName -CompressionType 'max' -ScratchDirectory $scratch -LogPath $script:DismLog | Out-Null
    }
    Write-BuildLog -Level Ok -Message ("Staging image: {0} ({1})" -f $stageWim, (Format-Size (Get-Item -LiteralPath $stageWim).Length))
    if ($script:IsoAttachedByUs) {
        Dismount-DiskImage -ImagePath $script:IsoFullPath | Out-Null
        $script:IsoAttachedByUs = $false
        Write-BuildLog -Message 'ISO dismounted.'
    }

    # -----------------------------------------------------------------------------------------
    Write-Step 'Mounting the install image' 28
    # -----------------------------------------------------------------------------------------
    Mount-WindowsImage -ImagePath $stageWim -Index 1 -Path $mountDir -ScratchDirectory $scratch -LogPath $script:DismLog | Out-Null
    [void]$script:MountedImages.Add($mountDir)
    Write-BuildLog -Level Ok -Message "Mounted at $mountDir"
    $payloadDir = Join-Path $mountDir 'LiteOS'
    $stateDir   = Join-Path $mountDir 'ProgramData\LiteOS'
    $backupPath = Join-Path $stateDir 'backup\backup-image.json'
    foreach ($d in @($payloadDir, $stateDir, (Join-Path $stateDir 'logs'), (Join-Path $stateDir 'backup'))) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    # -----------------------------------------------------------------------------------------
    Write-Step ("Removing preinstalled apps offline ({0} app rules)" -f $appxTweaks.Count) 31
    # -----------------------------------------------------------------------------------------
    # DISM servicing runs while the offline hives are NOT loaded (DISM loads them itself).
    # Built-in engine list + "protected" from apps-remove.json: Store, winget, Xbox / Gaming
    # Services, runtimes and Edge/WebView2 are never removed from the image.
    $protectedPatterns = @(Get-LiteOSProtectedApps -Path (Join-Path $repoRoot 'tweaks') | ForEach-Object { $_ } | ForEach-Object { [string]$_ })
    Write-BuildLog -Message ("{0} protected app patterns are never removed." -f $protectedPatterns.Count)
    if ($appxTweaks.Count -gt 0) {
        $provisioned = @(Get-AppxProvisionedPackage -Path $mountDir -LogPath $script:DismLog)
        Write-BuildLog -Message ("{0} provisioned packages in the image." -f $provisioned.Count)
        foreach ($t in $appxTweaks) {
            $tid = [string](Get-Field $t 'id' '')
            $patterns = New-Object System.Collections.Generic.List[string]
            foreach ($a in @(Get-Field $t 'actions' @())) {
                foreach ($p in @(Get-Field $a 'packages' @())) { if ($p -is [string] -and $p.Trim()) { $patterns.Add($p.Trim()) } }
            }
            $done = New-Object System.Collections.Generic.List[string]
            $failedPkgs = New-Object System.Collections.Generic.List[string]
            $refused = New-Object System.Collections.Generic.List[string]
            foreach ($pat in $patterns) {
                foreach ($pkg in @($provisioned | Where-Object { $_.DisplayName -like $pat })) {
                    if (Test-LiteOSProtectedApp -Name $pkg.DisplayName -Protected $protectedPatterns) {
                        $refused.Add($pkg.DisplayName)
                        Write-BuildLog -Level Warn -Message ("refuse {0}: protected package (rule '{1}')" -f $pkg.DisplayName, $pat)
                        continue
                    }
                    if ($removedApps -contains $pkg.DisplayName) { continue }
                    try {
                        Remove-AppxProvisionedPackage -Path $mountDir -PackageName $pkg.PackageName -LogPath $script:DismLog | Out-Null
                        [void]$removedApps.Add($pkg.DisplayName)
                        $done.Add($pkg.DisplayName)
                        Write-BuildLog -Message ("removed {0}" -f $pkg.DisplayName)
                    } catch {
                        $failedPkgs.Add($pkg.DisplayName)
                        Write-BuildLog -Level Warn -Message ("could not remove {0}: {1}" -f $pkg.DisplayName, $_.Exception.Message)
                    }
                }
            }
            if ($failedPkgs.Count -gt 0) { $st = 'failed'; $msg = 'could not remove ' + ($failedPkgs -join ', ') }
            elseif ($done.Count -gt 0) { $st = 'applied'; $msg = 'removed ' + ($done -join ', ') }
            elseif ($refused.Count -gt 0) { $st = 'skipped'; $msg = 'protected: ' + ($refused -join ', ') }
            else { $st = 'skipped'; $msg = 'not in this image' }
            [void]$appxResults.Add([pscustomobject]@{ id = $tid; status = $st; message = $msg })
        }
    }
    Write-BuildLog -Level Ok -Message ("{0} provisioned app(s) removed." -f $removedApps.Count)
    $script:Report['removedAppx'] = [string[]]@($removedApps)

    # Removal stages: DISM servicing now, while the hives are NOT loaded (capability / feature /
    # package types and every "appx" part, e.g. Core's Windows Security app); the rest (files,
    # OneDrive, Edge, WinRE, Core scripts) after the hives are loaded. Joined per id afterwards.
    $removalsDism = @($selectedRemovals | Where-Object { ($script:DismRemovalTypes -contains ([string](Get-Field $_ 'type' '')).ToLowerInvariant()) -or (@(Get-Field $_ 'appx' @()).Count -gt 0) })
    $removalsRest = @($selectedRemovals | Where-Object { -not ($script:DismRemovalTypes -contains ([string](Get-Field $_ 'type' '')).ToLowerInvariant()) })
    $removalParts = New-Object System.Collections.ArrayList
    $removalDeferred = @()
    $hives = @{ SOFTWARE = 'HKLM\LITE_SOFTWARE'; SYSTEM = 'HKLM\LITE_SYSTEM'; DEFAULT = 'HKLM\LITE_DEFAULT' }

    # -----------------------------------------------------------------------------------------
    Write-Step ("Removing Windows components: capabilities, features, packages, Core app overrides ({0})" -f $removalsDism.Count) 35
    # -----------------------------------------------------------------------------------------
    foreach ($r in (Invoke-RemovalBatch -Batch $removalsDism -MountPath $mountDir -Hives $hives -Scratch $scratch -Stage 'Dism')) { [void]$removalParts.Add($r) }

    $imageHives = @('LITE_SOFTWARE', 'LITE_SYSTEM', 'LITE_DEFAULT')
    try {
        # -------------------------------------------------------------------------------------
        Write-Step 'Loading the offline registry (SOFTWARE, SYSTEM, Default user)' 42
        # -------------------------------------------------------------------------------------
        Mount-OfflineHive -Name 'LITE_SOFTWARE' -File (Join-Path $mountDir 'Windows\System32\config\SOFTWARE')
        Mount-OfflineHive -Name 'LITE_SYSTEM'   -File (Join-Path $mountDir 'Windows\System32\config\SYSTEM')
        Mount-OfflineHive -Name 'LITE_DEFAULT'  -File (Join-Path $mountDir 'Users\Default\NTUSER.DAT')
        $controlSet = Get-OfflineControlSet -HiveName 'LITE_SYSTEM'
        Write-BuildLog -Level Ok -Message ("Hives loaded (live control set: {0})." -f $controlSet)

        # -------------------------------------------------------------------------------------
        Write-Step ("Removing Windows components: apps, files, settings ({0})" -f $removalsRest.Count) 44
        # -------------------------------------------------------------------------------------
        foreach ($r in (Invoke-RemovalBatch -Batch $removalsRest -MountPath $mountDir -Hives $hives -Scratch $scratch -Stage 'Hives')) { [void]$removalParts.Add($r) }
        foreach ($r in @(Merge-LiteOSRemovalResults -Results $removalParts.ToArray() | ForEach-Object { $_ })) { [void]$removalResults.Add($r) }
        $removalDeferred = ConvertTo-RemovalDeferred -Results $removalResults.ToArray() -Removals $selectedRemovals
        foreach ($rd in $removalDeferred) {
            Write-BuildLog -Message ('{0}: {1} action(s) deferred to SetupComplete (installed system, SYSTEM)' -f $rd.id, @($rd.actions).Count)
        }
        $script:Report['removals'] = [ordered]@{
            selected = [string[]]@($selectedRemovals | ForEach-Object { [string](Get-Field $_ 'id' '') })
            counts   = (Get-StatusCounts -Results $removalResults.ToArray())
            results  = (ConvertTo-ResultRows -Results $removalResults.ToArray())
        }

        # -------------------------------------------------------------------------------------
        Write-Step ("Baking {0} tweaks into the image ({1} level)" -f $planTweaks.Count, $level) 48
        # -------------------------------------------------------------------------------------
        if ($planTweaks.Count -gt 0) {
            $planSplat = Get-OptionalSplat -CommandName 'Invoke-LiteOSOfflinePlan' -Base @{ Tweaks = $planTweaks; MountPath = $mountDir; Hives = $hives; BackupPath = $backupPath; Context = $ctx } -Optional @{ Build = $imageBuild }
            $planOut = Invoke-LiteOSOfflinePlan @planSplat
            $planObj = $null
            foreach ($o in @($planOut)) { if (Test-Field $o 'Results') { $planObj = $o } }
            if ($null -eq $planObj) { throw 'Invoke-LiteOSOfflinePlan returned no Results (engine / builder version mismatch).' }
            $tweakResults = Select-ResultObjects -Items @(Get-Field $planObj 'Results' @())
            $deferred = @(@(Get-Field $planObj 'Deferred' @()) | Where-Object { $null -ne $_ })
        } else {
            Write-BuildLog -Message 'No tweaks selected.'
        }
        # Removal actions that only work on the installed system go into the same deferred.json.
        if (@($removalDeferred).Count -gt 0) { $deferred = @($deferred) + @($removalDeferred) }
        $tc = Get-StatusCounts -Results $tweakResults
        Write-BuildLog -Level Ok -Message ("Tweaks: {0}; {1} deferred to SetupComplete / first logon." -f ((@($tc.Keys | ForEach-Object { '{0} {1}' -f $tc[$_], $_ })) -join ', '), $deferred.Count)
        foreach ($tr in @($tweakResults | Where-Object { [string](Get-Field $_ 'status' '') -eq 'failed' })) {
            Write-BuildLog -Level Warn -Message ("tweak {0} failed: {1}" -f (Get-Field $tr 'id' '?'), (ConvertTo-SingleLine ([string](Get-Field $tr 'message' '')) 250))
        }

        # -------------------------------------------------------------------------------------
        Write-Step 'Branding, Start / taskbar layout and setup settings' 55
        # -------------------------------------------------------------------------------------
        $dropEdge = ($Mode -eq 'Core' -or $edgeRemoved)
        $layout = Install-LayoutFile -LayoutDir (Join-Path $repoRoot 'image\layout') -MountPath $mountDir -DropEdge $dropEdge
        $cdm = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        $settings = @(
            @{ Hive = 'SOFTWARE'; Op = 'set'; When = 'always'; Key = 'Microsoft\Windows\CurrentVersion\OOBE'; Name = 'BypassNRO'; Type = 'REG_DWORD'; Data = '1'; Why = 'OOBE: allow setup without network / with a local account' },
            @{ Hive = 'SOFTWARE'; Op = 'set'; When = 'always'; Key = 'Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures'; Type = 'REG_DWORD'; Data = '1'; Why = 'No consumer-feature app auto-installs' },
            @{ Hive = 'SOFTWARE'; Op = 'set'; When = 'always'; Key = 'Policies\Microsoft\Windows\CloudContent'; Name = 'DisableCloudOptimizedContent'; Type = 'REG_DWORD'; Data = '1'; Why = 'No cloud-optimized (sponsored) Start/taskbar content' },
            @{ Hive = 'SOFTWARE'; Op = 'delete-key'; When = 'always'; Key = 'Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'; Why = 'No automatic Outlook (new) install during OOBE' },
            @{ Hive = 'SOFTWARE'; Op = 'delete-key'; When = 'always'; Key = 'Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'; Why = 'No automatic Dev Home install during OOBE' },
            @{ Hive = 'DEFAULT';  Op = 'set'; When = 'always'; Key = $cdm; Name = 'OemPreInstalledAppsEnabled'; Type = 'REG_DWORD'; Data = '0'; Why = 'No OEM sponsored apps for new users' },
            @{ Hive = 'DEFAULT';  Op = 'set'; When = 'always'; Key = $cdm; Name = 'PreInstalledAppsEnabled'; Type = 'REG_DWORD'; Data = '0'; Why = 'No sponsored preinstalled apps for new users' },
            @{ Hive = 'DEFAULT';  Op = 'set'; When = 'always'; Key = $cdm; Name = 'PreInstalledAppsEverEnabled'; Type = 'REG_DWORD'; Data = '0'; Why = 'No sponsored preinstalled apps for new users' },
            @{ Hive = 'DEFAULT';  Op = 'set'; When = 'always'; Key = $cdm; Name = 'SilentInstalledAppsEnabled'; Type = 'REG_DWORD'; Data = '0'; Why = 'No silent sponsored app installs for new users' },
            @{ Hive = 'DEFAULT';  Op = 'set'; When = 'always'; Key = $cdm; Name = 'SystemPaneSuggestionsEnabled'; Type = 'REG_DWORD'; Data = '0'; Why = 'No app suggestions in Start for new users' },
            @{ Hive = 'DEFAULT';  Op = 'set'; When = 'always'; Key = $cdm; Name = 'SubscribedContent-338388Enabled'; Type = 'REG_DWORD'; Data = '0'; Why = 'No app suggestions in Start for new users' },
            @{ Hive = 'SYSTEM';   Op = 'set'; When = 'noencrypt'; Key = 'CONTROLSET\Control\BitLocker'; Name = 'PreventDeviceEncryption'; Type = 'REG_DWORD'; Data = '1'; Why = 'No automatic device encryption (BitLocker can still be enabled manually)' },
            @{ Hive = 'SYSTEM';   Op = 'set'; When = 'bypass'; Key = 'Setup\MoSetup'; Name = 'AllowUpgradesWithUnsupportedTPMOrCPU'; Type = 'REG_DWORD'; Data = '1'; Why = 'Feature updates on unsupported TPM/CPU' },
            @{ Hive = 'DEFAULT';  Op = 'set'; When = 'bypass'; Key = 'Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV1'; Type = 'REG_DWORD'; Data = '0'; Why = 'No "system requirements not met" notice' },
            @{ Hive = 'DEFAULT';  Op = 'set'; When = 'bypass'; Key = 'Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV2'; Type = 'REG_DWORD'; Data = '0'; Why = 'No "system requirements not met" notice' },
            @{ Hive = 'SOFTWARE'; Op = 'set'; When = 'always'; Key = 'Microsoft\Windows\CurrentVersion\OEMInformation'; Name = 'Manufacturer'; Type = 'REG_SZ'; Data = $branding['manufacturer']; Why = 'Branding (Settings > System > About)' },
            @{ Hive = 'SOFTWARE'; Op = 'set'; When = 'always'; Key = 'Microsoft\Windows\CurrentVersion\OEMInformation'; Name = 'Model'; Type = 'REG_SZ'; Data = $branding['model']; Why = 'Branding (Settings > System > About)' },
            @{ Hive = 'SOFTWARE'; Op = 'set'; When = 'always'; Key = 'Microsoft\Windows\CurrentVersion\OEMInformation'; Name = 'SupportURL'; Type = 'REG_SZ'; Data = $branding['supportUrl']; Why = 'Branding (support link)' },
            @{ Hive = 'SOFTWARE'; Op = 'set'; When = 'always'; Key = 'Microsoft\Windows NT\CurrentVersion'; Name = 'RegisteredOrganization'; Type = 'REG_SZ'; Data = $branding['registeredOrganization']; Why = 'Branding (registered organization)' },
            @{ Hive = 'SOFTWARE'; Op = 'set'; When = 'taskbar'; Key = 'Microsoft\Windows\CurrentVersion\Explorer'; Name = 'LayoutXMLPath'; Type = 'REG_SZ'; Data = $script:TaskbarOemPath; Why = 'Taskbar pins file (documented OEM LayoutXMLPath)' }
        )
        foreach ($n in $script:LabConfigNames) {
            $settings += @{ Hive = 'SYSTEM'; Op = 'set'; When = 'bypass'; Key = 'Setup\LabConfig'; Name = $n; Type = 'REG_DWORD'; Data = '1'; Why = 'Windows 11 requirement bypass (in-place repair/upgrade setup)' }
        }
        $applied = 0; $failed = 0
        foreach ($s in $settings) {
            if ($s.When -eq 'bypass' -and -not $bypass) { continue }
            if ($s.When -eq 'noencrypt' -and $KeepAutoEncryption) { continue }
            if ($s.When -eq 'taskbar' -and -not $layout['taskbarOem']) { continue }
            if ($s.Op -eq 'set' -and [string]::IsNullOrEmpty([string]$s.Data)) { Write-BuildLog -Message ("skip    {0}\{1} (empty value)" -f $s.Key, $s.Name); continue }
            $relKey = ([string]$s.Key).Replace('CONTROLSET', $controlSet)
            $fullKey = 'HKLM\LITE_{0}\{1}' -f $s.Hive, $relKey
            $label = '{0}\{1}' -f $s.Hive, $relKey
            try {
                if ($s.Op -eq 'delete-key') {
                    if (Invoke-OfflineRegKeyDelete -Key $fullKey) {
                        Write-BuildLog -Message ("deleted {0}  ({1})" -f $label, $s.Why)
                        [void]$offlineLog.Add(('delete {0}' -f $label))
                    } else {
                        Write-BuildLog -Message ("absent  {0}" -f $label)
                    }
                } else {
                    Write-OfflineRegValue -Key $fullKey -Name $s.Name -Type $s.Type -Data ([string]$s.Data)
                    Write-BuildLog -Message ("set     {0}\{1} = {2}  ({3})" -f $label, $s.Name, $s.Data, $s.Why)
                    [void]$offlineLog.Add(('{0}\{1} = {2} ({3})' -f $label, $s.Name, $s.Data, $s.Type))
                }
                $applied++
            } catch {
                $failed++
                Write-BuildLog -Level Warn -Message $_.Exception.Message
            }
        }
        Write-BuildLog -Level Ok -Message ("{0} builder setting(s) applied, {1} failed." -f $applied, $failed)
        $script:Report['layout'] = $layout
        $script:Report['branding'] = [ordered]@{ name = $branding['name']; model = $branding['model']; source = $branding['source'] }

        # -------------------------------------------------------------------------------------
        Write-Step 'Unloading the offline registry' 58
        # -------------------------------------------------------------------------------------
    } finally {
        # Always unload (never throw from here, so the original error is not hidden).
        foreach ($h in @('LITE_DEFAULT', 'LITE_SYSTEM', 'LITE_SOFTWARE')) {
            if ($script:LoadedHives -contains $h) { [void](Dismount-OfflineHive -Name $h) }
        }
    }
    $stillLoaded = @($script:LoadedHives | Where-Object { $imageHives -contains $_ })
    if ($stillLoaded.Count -gt 0) { throw ("Could not unload {0}; the image cannot be saved safely." -f ($stillLoaded -join ', ')) }
    Write-BuildLog -Level Ok -Message 'Hives unloaded.'
    $allTweakResults = @($appxResults.ToArray()) + @($tweakResults)
    $script:Report['tweaks'] = [ordered]@{
        selected = $selectedTweaks.Count
        deferred = $deferred.Count
        counts   = (Get-StatusCounts -Results $allTweakResults)
        failed   = (ConvertTo-ResultRows -Results @($allTweakResults | Where-Object { [string](Get-Field $_ 'status' '') -eq 'failed' }))
    }

    # -----------------------------------------------------------------------------------------
    Write-Step 'Copying Lite OS, installers, config and SetupComplete into the image' 60
    # -----------------------------------------------------------------------------------------
    foreach ($item in @('LiteOS.ps1', 'Revert-LiteOS.ps1', 'Start-LiteOS.cmd', 'src', 'tweaks', 'LICENSE', 'README.md')) {
        $srcItem = Join-Path $repoRoot $item
        if (-not (Test-Path -LiteralPath $srcItem)) {
            if (@('Revert-LiteOS.ps1', 'Start-LiteOS.cmd') -contains $item) { Write-BuildLog -Level Warn -Message "$item not found; skipped." }
            continue
        }
        Copy-Item -LiteralPath $srcItem -Destination (Join-Path $payloadDir $item) -Recurse -Force
        Write-BuildLog -Message ("copied {0} -> C:\LiteOS\{0}" -f $item)
    }
    $payloadImageDir = Join-Path $payloadDir 'image'
    if (-not (Test-Path -LiteralPath $payloadImageDir)) { New-Item -ItemType Directory -Path $payloadImageDir -Force | Out-Null }
    $brandingSrc = Join-Path $repoRoot 'image\branding.json'
    if (Test-Path -LiteralPath $brandingSrc -PathType Leaf) {
        Copy-Item -LiteralPath $brandingSrc -Destination (Join-Path $payloadImageDir 'branding.json') -Force
        Write-BuildLog -Message 'copied image\branding.json -> C:\LiteOS\image\branding.json'
    }

    # Installers verified earlier on this PC + manifest for SetupComplete (in this order).
    $manifest = New-Object System.Collections.ArrayList
    $okInstallers = @($installerResults | Where-Object { $_['status'] -eq 'ok' })
    if ($okInstallers.Count -gt 0) {
        $instTarget = Join-Path $payloadDir 'installers'
        if (-not (Test-Path -LiteralPath $instTarget)) { New-Item -ItemType Directory -Path $instTarget -Force | Out-Null }
        foreach ($e in $installerPlan) {
            $eid = [string](Get-Field $e 'id' '')
            $res = @($okInstallers | Where-Object { $_['id'] -eq $eid }) | Select-Object -First 1
            if ($null -eq $res) { continue }
            Copy-Item -LiteralPath (Join-Path $instDir $res['file']) -Destination (Join-Path $instTarget $res['file']) -Force
            # Same schema as image\installers.json (read by Get-LiteOSInstallerJobs at SetupComplete);
            # args may be a string or an array, so the values are copied as they are.
            $m = [ordered]@{ id = $eid; name = $res['name']; file = $res['file'] }
            foreach ($k in @('args', 'extract', 'successCodes', 'timeoutMinutes')) {
                if (Test-Field $e $k) { $m[$k] = Get-FieldRaw $e $k }
            }
            $m['publisher'] = [string](Get-Field $e 'publisher' '')
            $m['sha256'] = $res['sha256']
            [void]$manifest.Add($m)
            Write-BuildLog -Message ("copied {0} -> C:\LiteOS\installers\{0}" -f $res['file'])
        }
        Write-TextFile -Path (Join-Path $instTarget 'installers.json') -Text (ConvertTo-Json -InputObject ([ordered]@{ installers = $manifest.ToArray() }) -Depth 10)
        Write-BuildLog -Message ('wrote C:\LiteOS\installers\installers.json ({0} installer(s), run silently by SetupComplete)' -f $manifest.Count)
    }
    # Drop mark-of-the-web so the payload runs cleanly on the new install.
    Get-ChildItem -LiteralPath $payloadDir -Recurse -File -Force | Unblock-File -ErrorAction SilentlyContinue

    $deferredPath = Join-Path $payloadDir 'deferred.json'
    $deferredBy = Export-DeferredFile -Deferred $deferred -Path $deferredPath -MountPath $mountDir
    $null = Read-JsonFile -Path $deferredPath
    Write-BuildLog -Message ('wrote C:\LiteOS\deferred.json ({0} deferred tweak(s), by {1})' -f $deferred.Count, $deferredBy)

    $builtAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $config = [ordered]@{
        mode       = $Mode
        level      = $level
        include    = [string[]]$tweakInclude
        exclude    = [string[]]$tweakExclude
        apps       = $appsValue
        builtWith  = ('Lite OS Build-LiteOS.ps1 {0}' -f $script:BuilderVersion)
        builtAt    = $builtAt
        imageBuild = $imageBuild
    }
    $configPath = Join-Path $stateDir 'config.json'
    Write-TextFile -Path $configPath -Text (ConvertTo-Json -InputObject $config -Depth 5)
    $null = Read-JsonFile -Path $configPath
    Write-BuildLog -Message 'wrote C:\ProgramData\LiteOS\config.json'

    $buildInfo = [ordered]@{
        builder                 = ('Build-LiteOS.ps1 {0}' -f $script:BuilderVersion)
        builtAt                 = $builtAt
        source                  = $(if ($Download) { 'download' } else { 'iso' })
        sourceIso               = (Split-Path -Leaf $script:IsoFullPath)
        edition                 = [string]$selected.ImageName
        editionId               = [string]$selected.EditionId
        imageName               = $wimName
        build                   = $buildText
        language                = $imageLang
        mode                    = $Mode
        level                   = $level
        bypassRequirements      = [bool]$bypass
        preventDeviceEncryption = [bool](-not $KeepAutoEncryption)
        removedProvisionedApps  = [string[]]@($removedApps)
        removals                = [string[]]@($removalResults | Where-Object { @('applied', 'removed', 'ok', 'deferred') -contains [string](Get-Field $_ 'status' '') } | ForEach-Object { [string](Get-Field $_ 'id' '') })
        removalsInclude         = $removalInclude
        removalsExclude         = $removalExclude
        tweaks                  = (Get-StatusCounts -Results $allTweakResults)
        deferredTweaks          = $deferred.Count
        installers              = [string[]]@($manifest | ForEach-Object { $_['name'] })
        offlineRegistry         = [string[]]@($offlineLog)
        branding                = $branding['name']
        layout                  = $layout
    }
    Write-TextFile -Path (Join-Path $stateDir 'build-info.json') -Text (ConvertTo-Json -InputObject $buildInfo -Depth 6)
    $script:Report['buildInfo'] = $buildInfo
    Write-BuildLog -Message 'wrote C:\ProgramData\LiteOS\build-info.json (what the builder changed offline)'
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        Write-BuildLog -Level Warn -Message 'No C:\ProgramData\LiteOS\backup\backup-image.json was written by the engine (no revertable offline change?).'
    }

    # SetupComplete.cmd: Windows runs it as SYSTEM at the end of Setup, before the first sign-in.
    $scriptsDir = Join-Path $mountDir 'Windows\Setup\Scripts'
    if (-not (Test-Path -LiteralPath $scriptsDir)) {
        New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
        Set-AdminOwner -Path $scriptsDir
    }
    $setupComplete = Join-Path $scriptsDir 'SetupComplete.cmd'
    if (Test-Path -LiteralPath $setupComplete) { Write-BuildLog -Level Warn -Message 'The image already has a SetupComplete.cmd; it is replaced by the Lite OS one.' }
    Write-AsciiCrlfFile -Path $setupComplete -Lines @(
        '@echo off',
        ('rem Lite OS {0} - written by builder\Build-LiteOS.ps1 at {1}.' -f $script:BuilderVersion, $builtAt),
        'rem Windows runs this once as SYSTEM at the end of Setup, before the first sign-in:',
        'rem deferred machine tweaks, boot menu name, baked installers (C:\LiteOS\installers).',
        'setlocal',
        'if not exist "%ProgramData%\LiteOS\logs" mkdir "%ProgramData%\LiteOS\logs"',
        'if exist "C:\LiteOS\LiteOS.ps1" (',
        '  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File C:\LiteOS\LiteOS.ps1 -SetupComplete >> "%ProgramData%\LiteOS\logs\setupcomplete-console.log" 2>&1',
        ') else (',
        '  echo Lite OS: C:\LiteOS\LiteOS.ps1 not found. >> "%ProgramData%\LiteOS\logs\setupcomplete-console.log"',
        ')',
        'endlocal',
        'exit /b 0'
    )
    Set-AdminOwner -Path $setupComplete
    Write-BuildLog -Message 'wrote C:\Windows\Setup\Scripts\SetupComplete.cmd (runs LiteOS.ps1 -SetupComplete as SYSTEM)'

    if ($script:LogFile -and (Test-Path -LiteralPath $script:LogFile)) {
        # Cleaned copy: no user name / folder layout of the PC the ISO was built on.
        $logText = Get-SanitizedLogText -Text ([IO.File]::ReadAllText($script:LogFile)) -Pairs @(
            @($script:WorkRoot, '<WorkDir>'),
            @($logDir, '<BuildFolder>'),
            @((Split-Path -Parent $script:IsoFullPath), '<IsoFolder>'),
            @($outDir, '<OutputFolder>'),
            @($repoRoot, '<LiteOSFolder>'),
            @($env:USERPROFILE, '%USERPROFILE%')
        )
        Write-TextFile -Path (Join-Path $stateDir ('logs\builder-{0}.log' -f $startStamp)) -Text $logText
    }
    Set-ProtectedAcl -Path $payloadDir
    Set-ProtectedAcl -Path $stateDir
    Write-BuildLog -Message 'C:\LiteOS and C:\ProgramData\LiteOS: only SYSTEM and Administrators can change them (Users: read only).'
    Write-BuildLog -Level Ok -Message 'Payload, config, deferred tweaks, installers and SetupComplete in place.'

    # -----------------------------------------------------------------------------------------
    Write-Step 'Cleaning up the component store (StartComponentCleanup /ResetBase)' 64
    # -----------------------------------------------------------------------------------------
    Write-BuildLog -Message 'This can take 10-30 minutes.'
    try {
        $cleanSplat = Get-OptionalSplat -CommandName 'Invoke-LiteOSImageCleanup' -Base @{ MountPath = $mountDir; ResetBase = $true } -Optional @{ LogPath = $script:DismLog; ScratchDirectory = $scratch }
        $cleanOut = @(Invoke-LiteOSImageCleanup @cleanSplat)
        $cleanFailed = $null
        foreach ($o in $cleanOut) {
            if ($o -is [string]) { if ($o.Trim()) { Write-BuildLog -Message $o.Trim() }; continue }
            if ($null -ne $o -and (Test-Field $o 'status')) {
                $cst = [string](Get-Field $o 'status' '')
                $cmsg = ConvertTo-SingleLine ([string](Get-Field $o 'message' '')) 300
                Write-BuildLog -Message ('cleanup: {0} - {1}' -f $cst, $cmsg)
                if ($cst -eq 'failed') { $cleanFailed = $cmsg }
            }
        }
        if ($cleanFailed) { throw $cleanFailed }
        Write-BuildLog -Level Ok -Message 'Component store cleaned.'
        $script:Report['cleanup'] = 'ok'
    } catch {
        $script:Report['cleanup'] = ('failed: ' + (ConvertTo-SingleLine $_.Exception.Message 300))
        Write-BuildLog -Level Warn -Message ("Image cleanup failed ({0}); the image is still fine, only larger." -f $_.Exception.Message)
    }

    # -----------------------------------------------------------------------------------------
    Write-Step 'Saving and unmounting the install image' 78
    # -----------------------------------------------------------------------------------------
    Dismount-WindowsImage -Path $mountDir -Save -ScratchDirectory $scratch -LogPath $script:DismLog | Out-Null
    $script:MountedImages.Remove($mountDir)
    Write-BuildLog -Level Ok -Message 'Install image saved.'

    # -----------------------------------------------------------------------------------------
    Write-Step 'Adding the requirement bypass to Windows Setup (boot.wim)' 82
    # -----------------------------------------------------------------------------------------
    if ($bypass) {
        $bootWim = Join-Path $isoDir 'sources\boot.wim'
        $bootImages = @(Get-WindowsImage -ImagePath $bootWim -LogPath $script:DismLog)
        $bootIndex = 2
        $setupImage = @($bootImages | Where-Object { $_.ImageName -like '*Setup*' } | Select-Object -First 1)
        if ($setupImage.Count -eq 1) { $bootIndex = [int]$setupImage[0].ImageIndex }
        elseif (@($bootImages | Where-Object { $_.ImageIndex -eq 2 }).Count -eq 0) { throw 'boot.wim has no Windows Setup image (index 2).' }
        else { Write-BuildLog -Level Warn -Message 'No boot.wim image named "Setup"; using index 2.' }
        Mount-WindowsImage -ImagePath $bootWim -Index $bootIndex -Path $bootMount -ScratchDirectory $scratch -LogPath $script:DismLog | Out-Null
        [void]$script:MountedImages.Add($bootMount)
        try {
            Mount-OfflineHive -Name 'LITE_BOOTSYSTEM' -File (Join-Path $bootMount 'Windows\System32\config\SYSTEM')
            foreach ($n in $script:LabConfigNames) {
                Write-OfflineRegValue -Key 'HKLM\LITE_BOOTSYSTEM\Setup\LabConfig' -Name $n -Type 'REG_DWORD' -Data '1'
                Write-BuildLog -Message ("set     boot.wim[{0}] SYSTEM\Setup\LabConfig\{1} = 1" -f $bootIndex, $n)
            }
        } finally {
            if ($script:LoadedHives -contains 'LITE_BOOTSYSTEM') { [void](Dismount-OfflineHive -Name 'LITE_BOOTSYSTEM') }
        }
        if ($script:LoadedHives -contains 'LITE_BOOTSYSTEM') { throw 'Could not unload HKLM\LITE_BOOTSYSTEM; boot.wim cannot be saved safely.' }
        Dismount-WindowsImage -Path $bootMount -Save -ScratchDirectory $scratch -LogPath $script:DismLog | Out-Null
        $script:MountedImages.Remove($bootMount)
        Write-BuildLog -Level Ok -Message ("boot.wim index {0} patched." -f $bootIndex)
    } else {
        Write-BuildLog -Message 'Skipped (-NoBypassRequirements).'
    }

    # -----------------------------------------------------------------------------------------
    Write-Step 'Optimizing install.wim (maximum compression)' 85
    # -----------------------------------------------------------------------------------------
    $finalWim = Join-Path $isoDir 'sources\install.wim'
    foreach ($old in @('install.wim', 'install.esd')) {
        $o = Join-Path $isoDir ('sources\' + $old)
        if (Test-Path -LiteralPath $o) { Remove-Item -LiteralPath $o -Force }
    }
    Export-WindowsImage -SourceImagePath $stageWim -SourceIndex 1 -DestinationImagePath $finalWim -DestinationName $wimName -CompressionType 'max' -ScratchDirectory $scratch -LogPath $script:DismLog | Out-Null
    Remove-Item -LiteralPath $stageWim -Force
    $wimSize = (Get-Item -LiteralPath $finalWim).Length
    Write-BuildLog -Level Ok -Message ("install.wim: {0} (image name '{1}')" -f (Format-Size $wimSize), $wimName)
    $script:Report['wimSizeBytes'] = [int64]$wimSize
    if ($wimSize -ge 4294967295) {
        if ($SplitWim) {
            Write-BuildLog -Message 'Splitting install.wim into install*.swm (FAT32 friendly)...'
            Split-WindowsImage -ImagePath $finalWim -SplitImagePath (Join-Path $isoDir 'sources\install.swm') -FileSize 3800 -ScratchDirectory $scratch -LogPath $script:DismLog | Out-Null
            Remove-Item -LiteralPath $finalWim -Force
            Write-BuildLog -Level Ok -Message ("Split into {0} part(s)." -f @(Get-ChildItem -LiteralPath (Join-Path $isoDir 'sources') -Filter 'install*.swm').Count)
        } else {
            Write-BuildLog -Message 'install.wim is larger than 4 GB: Rufus will use NTFS automatically (or rebuild with -SplitWim for FAT32).'
        }
    }

    # -----------------------------------------------------------------------------------------
    Write-Step 'Writing autounattend.xml' 92
    # -----------------------------------------------------------------------------------------
    $banner = ('Generated by Lite OS Build-LiteOS.ps1 {0} at {1}; mode {2}; requirement bypass {3}. No disk, key or account settings.' -f $script:BuilderVersion, $builtAt, $Mode, $(if ($bypass) { 'ON' } else { 'OFF' }))
    $unattend = Get-LiteOSUnattendXml -TemplateText ([IO.File]::ReadAllText($template)) -BypassRequirements $bypass -Banner $banner
    Write-TextFile -Path (Join-Path $isoDir 'autounattend.xml') -Text $unattend
    Write-BuildLog -Level Ok -Message 'autounattend.xml written to the ISO root (validated: no disk settings, no product key - only the empty Key Setup requires - and no accounts).'

    # -----------------------------------------------------------------------------------------
    Write-Step 'Creating the bootable ISO' 93
    # -----------------------------------------------------------------------------------------
    $prefix = (([string]$branding['isoLabelPrefix']).ToUpperInvariant() -replace '[^A-Z0-9_\-]', '')
    if (-not $prefix) { $prefix = 'LITEOS' }
    $volLabel = '{0}_{1}' -f $prefix, $imageBuild
    if ($volLabel.Length -gt 32) { $volLabel = $volLabel.Substring(0, 32) }
    $isoArgs = @{ SourcePath = $isoDir; OutputPath = $outFull; VolumeLabel = $volLabel; Force = $true }
    if ($NoPrompt) { $isoArgs['NoPrompt'] = $true }
    Write-BuildLog -Message ("Volume label: {0}" -f $volLabel)
    & $isoScript @isoArgs | Out-Null
    if (-not (Test-Path -LiteralPath $outFull -PathType Leaf)) { throw 'New-IsoFile.ps1 did not produce the ISO.' }

    # -----------------------------------------------------------------------------------------
    Write-Step 'Computing SHA256 and writing the build report' 98
    # -----------------------------------------------------------------------------------------
    $hash = (Get-FileHash -LiteralPath $outFull -Algorithm SHA256).Hash
    $isoItem = Get-Item -LiteralPath $outFull
    Set-Content -LiteralPath ($outFull + '.sha256') -Value ('{0} *{1}' -f $hash, $isoItem.Name) -Encoding ASCII
    Write-BuildLog -Message ("SHA256 {0}" -f $hash)
    $script:Report['iso'] = [ordered]@{ name = $isoItem.Name; sizeBytes = [int64]$isoItem.Length; sha256 = $hash; volumeLabel = $volLabel }

    $script:Succeeded = $true
    Write-BuildLog -Level Step -Message 'Build complete'
    Write-BuildLog -Level Ok -Message ("Lite OS ISO: {0} ({1})" -f $outFull, (Format-Size $isoItem.Length))
    Write-BuildLog -Message ("{0}: edition {1}, build {2}, {3} apps removed, {4} components removed, {5} installers baked in" -f $wimName, $selected.ImageName, $buildText, $removedApps.Count, @($removalResults | Where-Object { @('applied', 'removed', 'ok', 'deferred') -contains [string](Get-Field $_ 'status' '') }).Count, $manifest.Count)
    Write-Host ''
    Write-Host '  Next: write the ISO to a USB stick with Rufus (https://rufus.ie; untick all "Windows User Experience"'
    Write-Host '  options - Lite OS has its own answer file), boot it, and pick the disk/partition yourself in Setup.'
    Write-Host '  See builder\README.md for BIOS/UEFI notes and licensing.'
}
catch {
    $script:FailureMessage = ConvertTo-SingleLine $_.Exception.Message 600
    Write-BuildLog -Level Error -Message $_.Exception.Message
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        if ($script:LogFile) { try { Add-Content -LiteralPath $script:LogFile -Value $_.InvocationInfo.PositionMessage -Encoding UTF8 } catch { Write-Verbose 'Log write failed.' } }
    }
}
finally {
    try {
        Invoke-Cleanup -Failed (-not $script:Succeeded)
    } catch {
        Write-BuildLog -Level Warn -Message ("Cleanup error: {0}" -f $_.Exception.Message)
    }
    if ($script:Succeeded) { $reportStatus = 'ok' } else { $reportStatus = 'error' }
    [void](Write-BuildReport -Status $reportStatus -ErrorText $script:FailureMessage -FallbackDir $logDir -Stamp $startStamp)
}

if ($script:UseProtocol) {
    if ($script:Succeeded) {
        Write-ProgressLine -Percent 100 -Message 'Done' -Final
        Write-Host ('##LITEOS-RESULT ok {0} {1}' -f $outFull, $hash)
    } else {
        $msg = $script:FailureMessage
        if (-not $msg) { $msg = 'The build was interrupted.' }
        Write-Host ('##LITEOS-RESULT error {0}' -f $msg)
    }
}
if ($script:Succeeded) { exit 0 } else { exit 1 }

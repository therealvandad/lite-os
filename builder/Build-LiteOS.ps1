<#
.SYNOPSIS
    Builds a Lite OS ISO from an OFFICIAL Windows 11 ISO that you downloaded yourself.

.DESCRIPTION
    Build-LiteOS.ps1 turns an official Windows 11 (24H2 / 25H2+, build >= 26100) ISO into a
    Lite OS ISO:

      - keeps only the edition you choose (default "Windows 11 Pro") in a new install.wim
      - removes the preinstalled apps listed in tweaks\apps-remove.json for the chosen level
        (protected apps such as Store, Xbox, Game Bar, Gaming Services are never removed)
      - applies a few offline registry settings (local-account OOBE, no sponsored app installs,
        no automatic device encryption, optional hardware requirement bypass)
      - copies the Lite OS playbook to C:\LiteOS inside the image and writes
        C:\ProgramData\LiteOS\config.json, so the first logon runs
        "LiteOS.ps1 -FirstLogon" at the level chosen here
      - adds autounattend.xml (no disk/partition settings: YOU pick the disk in Setup)
      - writes a bootable (BIOS + UEFI) UDF ISO with New-IsoFile.ps1 and prints its SHA256

    Nothing from Microsoft is shipped with Lite OS: you bring your own ISO and your own license.
    No product keys, generic install keys or activators are added.

    Requires: Windows 10/11 host, Windows PowerShell 5.1 (64-bit) run as Administrator,
    >= 25 GB free on the work drive (NTFS). The Windows ADK "Deployment Tools" (oscdimg.exe)
    are optional; without them the ISO is written with the built-in IMAPI2 COM API.

.PARAMETER IsoPath
    Path to the official Windows 11 ISO (or to a folder that contains the extracted ISO).

.PARAMETER OutputPath
    Where to write the Lite OS ISO. Default: .\LiteOS-<build>.iso in the current directory.

.PARAMETER Edition
    Edition (image name) to keep, e.g. "Windows 11 Pro", "Windows 11 Home". An image index
    number is accepted too. If the name is not found you get an interactive picker.

.PARAMETER Level
    Balanced (default, recommended) or Extreme. Used for offline app removal and written to
    config.json for the first-logon playbook run.

.PARAMETER Apps
    Gaming apps the first logon installs with winget: "default" (the default set from
    tweaks\apps-install.json), "none", "all", or a list of exact winget ids.

.PARAMETER Include
    Optional tweak ids to force-include (written to config.json; apps.remove.* ids also affect
    the offline app removal).

.PARAMETER Exclude
    Optional tweak ids to exclude (written to config.json; apps.remove.* ids also affect the
    offline app removal).

.PARAMETER NoBypassRequirements
    Do NOT add the TPM / Secure Boot / RAM / storage / CPU requirement bypass (boot.wim,
    install image and autounattend.xml). Use this for hardware that meets the requirements.

.PARAMETER KeepAutoEncryption
    Keep Windows' automatic device encryption (BitLocker device encryption). By default the
    image sets PreventDeviceEncryption=1; you can still turn BitLocker on yourself any time.

.PARAMETER WorkDir
    Scratch folder on a local NTFS drive with >= 25 GB free. Default: <SystemDrive>\LiteOS-Build.

.PARAMETER NoPrompt
    Use efisys_noprompt.bin for UEFI boot of the ISO itself (no "Press any key to boot from
    CD or DVD"). Default keeps the prompt so media left in the drive never restarts Setup.

.PARAMETER SplitWim
    Split install.wim into <= 3800 MB install*.swm parts when it is larger than 4 GB, so the
    files fit on a FAT32 USB stick.

.PARAMETER KeepWorkDir
    Do not delete the work folder at the end (for troubleshooting).

.PARAMETER Force
    Overwrite an existing output ISO and skip the interactive Extreme confirmation.

.EXAMPLE
    .\Build-LiteOS.ps1 -IsoPath "$env:USERPROFILE\Downloads\Win11_25H2_English_x64.iso"

.EXAMPLE
    .\Build-LiteOS.ps1 -IsoPath D:\Win11.iso -Edition "Windows 11 Home" -Apps Valve.Steam,Discord.Discord -WorkDir E:\LiteOS-Build

.NOTES
    Lite OS builder. Windows PowerShell 5.1 compatible, ASCII only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$IsoPath,

    [string]$OutputPath,

    [string]$Edition = 'Windows 11 Pro',

    [ValidateSet('Balanced', 'Extreme')]
    [string]$Level = 'Balanced',

    [string[]]$Apps = @('default'),

    [string[]]$Include = @(),

    [string[]]$Exclude = @(),

    [switch]$NoBypassRequirements,

    [switch]$KeepAutoEncryption,

    [string]$WorkDir,

    [switch]$NoPrompt,

    [switch]$SplitWim,

    [switch]$KeepWorkDir,

    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------
# Script state
# ---------------------------------------------------------------------------------------------
$script:BuilderVersion = '1.0.0'
$script:TotalSteps     = 15
$script:StepNumber     = 0
$script:LogFile        = $null
$script:DismLog        = $null
$script:RegExe         = Join-Path $env:SystemRoot 'System32\reg.exe'
$script:LoadedHives    = New-Object System.Collections.ArrayList
$script:MountedImages  = New-Object System.Collections.ArrayList
$script:IsoFullPath    = $null
$script:IsoAttachedByUs = $false
$script:WorkRoot       = $null
$script:WorkMarker     = '.liteos-workdir'
$script:WorkChildren   = @('iso', 'mount', 'bootmount', 'scratch', 'stage')
$script:HiveNames      = @('LITE_SOFTWARE', 'LITE_SYSTEM', 'LITE_DEFAULT', 'LITE_BOOTSYSTEM')
$script:LabConfigNames = @('BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck', 'BypassStorageCheck', 'BypassCPUCheck')
$script:Succeeded      = $false

# ---------------------------------------------------------------------------------------------
# Output / logging
# ---------------------------------------------------------------------------------------------
function Write-BuildLog {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Warn', 'Error', 'Step', 'Ok')][string]$Level = 'Info'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { Write-Verbose ('Log write failed: ' + $_.Exception.Message) }
    }
    switch ($Level) {
        'Step'  { Write-Host ''; Write-Host $Message -ForegroundColor Cyan }
        'Warn'  { Write-Host ('  WARNING: ' + $Message) -ForegroundColor Yellow }
        'Error' { Write-Host ('  ERROR: ' + $Message) -ForegroundColor Red }
        'Ok'    { Write-Host ('  ' + $Message) -ForegroundColor Green }
        default { Write-Host ('  ' + $Message) }
    }
}

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Title)
    $script:StepNumber++
    Write-BuildLog -Level Step -Message ('[{0}/{1}] {2}' -f $script:StepNumber, $script:TotalSteps, $Title)
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

function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-JsonProp {
    # Strict-mode safe property read for PSCustomObjects coming from ConvertFrom-Json.
    param($Object, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
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
# Image helpers
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
    foreach ($img in $Images) { Write-Host ('      {0,2}) {1}' -f $img.ImageIndex, $img.ImageName) }
    if (-not (Test-Interactive)) {
        throw "Edition '$Wanted' not found. Re-run with -Edition set to one of the names (or index numbers) listed above."
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

function Get-AppRemovalPlan {
    # Mirrors the engine: Balanced = balanced+default; Extreme = Balanced + extreme+default;
    # -Include / -Exclude with synthetic ids apps.remove.<match-lowercased>.
    param($AppsJson, [string]$ChosenLevel, [string[]]$IncludeIds, [string[]]$ExcludeIds)
    $plan = New-Object System.Collections.ArrayList
    foreach ($entry in @(Get-JsonProp $AppsJson 'packages' @())) {
        $match = [string](Get-JsonProp $entry 'match' '')
        if (-not $match) { continue }
        $id = 'apps.remove.' + $match.ToLowerInvariant()
        $entryLevel = ([string](Get-JsonProp $entry 'level' 'balanced')).ToLowerInvariant()
        $isDefault = [bool](Get-JsonProp $entry 'default' $false)
        $selected = $false
        if ($isDefault) {
            if ($entryLevel -eq 'balanced') { $selected = $true }
            elseif ($entryLevel -eq 'extreme' -and $ChosenLevel -eq 'Extreme') { $selected = $true }
        }
        if (Test-IdMatch -Id $id -Patterns $IncludeIds) { $selected = $true }
        if (Test-IdMatch -Id $id -Patterns $ExcludeIds) { $selected = $false }
        if ($selected) {
            [void]$plan.Add((New-Object PSObject -Property @{
                Id    = $id
                Match = $match
                Name  = [string](Get-JsonProp $entry 'name' $match)
            }))
        }
    }
    return , $plan.ToArray()
}

function Test-ProtectedApp {
    param([string]$PackageName, [string[]]$Patterns)
    foreach ($p in @($Patterns)) {
        if ($p -and ($PackageName -like $p)) { return $true }
    }
    return $false
}

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
    Remove-Item -LiteralPath (Join-Path $Path $script:WorkMarker) -Force -ErrorAction SilentlyContinue
    if (@(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Count -eq 0) {
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
        Write-BuildLog -Message 'If DISM reports stale mounts later, run:  dism /Cleanup-Wim   (or Clear-WindowsCorruptMountPoint)'
        if ($script:LogFile) { Write-BuildLog -Message ("Full log: {0}" -f $script:LogFile) }
    }
}

# =============================================================================================
# Main
# =============================================================================================
$isoSourceRoot = $null
$installSource = $null
$outFull       = $null
$selected      = $null
$imageBuild    = 0
$imageRevision = 0
$removedApps   = New-Object System.Collections.ArrayList
$offlineLog    = New-Object System.Collections.ArrayList

try {
    $bypass       = -not $NoBypassRequirements
    if ($Level -eq 'Extreme') { $Level = 'Extreme' } else { $Level = 'Balanced' }
    $includeList  = ConvertTo-IdList -Values $Include
    $excludeList  = ConvertTo-IdList -Values $Exclude
    $appsList     = ConvertTo-IdList -Values $Apps
    $repoRoot     = Split-Path -Parent $PSScriptRoot
    $startStamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')

    # Log next to the requested output (or in the current folder).
    if ($OutputPath) { $logDir = Split-Path -Parent (Resolve-FullPath $OutputPath) } else { $logDir = (Get-Location).ProviderPath }
    if (-not $logDir -or -not (Test-Path -LiteralPath $logDir)) { $logDir = (Get-Location).ProviderPath }
    $script:LogFile = Join-Path $logDir ("LiteOS-build-{0}.log" -f $startStamp)
    $script:DismLog = Join-Path $logDir ("LiteOS-build-{0}.dism.log" -f $startStamp)

    Write-Host ''
    Write-Host ('Lite OS ISO builder {0}' -f $script:BuilderVersion) -ForegroundColor White
    Write-Host 'Scripts only: uses YOUR official Windows 11 ISO. No Windows files, keys or activators are added.'
    Write-BuildLog -Message ("Log file: {0}" -f $script:LogFile)

    # -----------------------------------------------------------------------------------------
    Write-Step 'Pre-flight checks'
    # -----------------------------------------------------------------------------------------
    if (-not (Test-IsAdmin)) { throw 'Run this script from an elevated PowerShell (Run as administrator).' }
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell (not the x86 version).' }
    if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'Windows PowerShell 5.1 or newer is required.' }
    foreach ($cmd in @('Mount-WindowsImage', 'Dismount-WindowsImage', 'Export-WindowsImage', 'Get-WindowsImage', 'Get-AppxProvisionedPackage', 'Remove-AppxProvisionedPackage', 'Mount-DiskImage')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "Required cmdlet '$cmd' is missing (DISM / Storage modules)." }
    }
    if (-not (Test-Path -LiteralPath $script:RegExe)) { throw "reg.exe not found at $script:RegExe" }
    $hostBuild = [Environment]::OSVersion.Version.Build
    if ($hostBuild -lt 22000) {
        Write-BuildLog -Level Warn -Message "This PC runs Windows build $hostBuild. Building on Windows 11 (or with the latest Windows ADK) is recommended for servicing 24H2+ images."
    }

    $isoScript = Join-Path $PSScriptRoot 'New-IsoFile.ps1'
    $template  = Join-Path $PSScriptRoot 'autounattend.xml'
    foreach ($f in @($isoScript, $template)) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "Builder file missing: $f" }
    }
    $requiredPayload = @('LiteOS.ps1', 'src\LiteOS.Engine.psm1', 'tweaks')
    foreach ($p in $requiredPayload) {
        if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $p))) { throw "Lite OS payload incomplete: '$p' not found under $repoRoot. Use a complete Lite OS release folder." }
    }
    # The engine's protected-app list (built in + apps-remove.json) also guards the offline removal.
    # Importing the module has no side effects.
    Import-Module -Name (Join-Path $repoRoot 'src\LiteOS.Engine.psm1') -Force -DisableNameChecking -ErrorAction Stop

    # Options
    $keywords = @('default', 'none', 'all')
    if ($appsList.Count -eq 0) { $appsList = @('default') }
    $kw = @($appsList | Where-Object { $keywords -contains $_.ToLowerInvariant() })
    if ($kw.Count -gt 0 -and $appsList.Count -gt 1) { throw "-Apps: use either 'default', 'none', 'all' or a list of winget ids, not both." }
    if ($kw.Count -eq 1) { $appsValue = $kw[0].ToLowerInvariant() } else { $appsValue = [string[]]$appsList }

    # Optional catalogue checks (warnings only).
    $appsRemovePath  = Join-Path $repoRoot 'tweaks\apps-remove.json'
    $appsInstallPath = Join-Path $repoRoot 'tweaks\apps-install.json'
    $appsRemoveJson  = $null
    if (Test-Path -LiteralPath $appsRemovePath) {
        try { $appsRemoveJson = Read-JsonFile -Path $appsRemovePath } catch { Write-BuildLog -Level Warn -Message "tweaks\apps-remove.json could not be parsed: $($_.Exception.Message)" }
    } else {
        Write-BuildLog -Level Warn -Message 'tweaks\apps-remove.json not found; no apps will be removed offline.'
    }
    if ($appsValue -is [array] -and (Test-Path -LiteralPath $appsInstallPath)) {
        try {
            $known = @((Read-JsonFile -Path $appsInstallPath).apps | ForEach-Object { [string](Get-JsonProp $_ 'id' '') })
            foreach ($a in $appsValue) {
                if (-not ($known -contains $a)) { Write-BuildLog -Level Warn -Message "App id '$a' is not in tweaks\apps-install.json (it will still be passed to winget)." }
            }
        } catch { Write-BuildLog -Level Warn -Message "tweaks\apps-install.json could not be parsed: $($_.Exception.Message)" }
    }
    if (($includeList.Count + $excludeList.Count) -gt 0) {
        $knownIds = New-Object System.Collections.Generic.List[string]
        foreach ($jf in @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tweaks') -Filter '*.json' -File)) {
            if ($jf.Name -like 'apps-*') { continue }
            try { foreach ($t in @(Get-JsonProp (Read-JsonFile -Path $jf.FullName) 'tweaks' @())) { $knownIds.Add([string](Get-JsonProp $t 'id' '')) } } catch { Write-Verbose ('Catalog file skipped: ' + $jf.Name) }
        }
        if ($appsRemoveJson) {
            foreach ($e in @(Get-JsonProp $appsRemoveJson 'packages' @())) { $knownIds.Add('apps.remove.' + ([string](Get-JsonProp $e 'match' '')).ToLowerInvariant()) }
        }
        foreach ($id in @($includeList) + @($excludeList)) {
            $hit = $false
            foreach ($k in $knownIds) { if (Test-IdMatch -Id $k -Patterns @($id)) { $hit = $true; break } }
            if (-not $hit) { Write-BuildLog -Level Warn -Message "Tweak id or pattern '$id' matches nothing in the catalog (typo?)." }
        }
    }

    if ($Level -eq 'Extreme' -and -not $Force) {
        Write-Host ''
        Write-Host '  EXTREME level was requested.' -ForegroundColor Yellow
        Write-Host '  Extreme tweaks can weaken security and may break Windows Update, Defender, the Store,' -ForegroundColor Yellow
        Write-Host '  Xbox / Game Pass or kernel anti-cheat. Read docs\TWEAKS.md before using it.' -ForegroundColor Yellow
        if (-not (Test-Interactive)) { throw 'Extreme needs confirmation: re-run with -Force to confirm non-interactively.' }
        $answer = Read-Host '  Type EXTREME to continue'
        if ($answer -cne 'EXTREME') { throw 'Extreme level not confirmed; nothing was done.' }
    }

    # Source
    if (-not (Test-Path -LiteralPath $IsoPath)) { throw "ISO not found: $IsoPath" }
    $script:IsoFullPath = (Resolve-Path -LiteralPath $IsoPath).ProviderPath
    $sourceIsFolder = Test-Path -LiteralPath $script:IsoFullPath -PathType Container
    if (-not $sourceIsFolder -and [IO.Path]::GetExtension($script:IsoFullPath) -ne '.iso') {
        Write-BuildLog -Level Warn -Message "'$($script:IsoFullPath)' does not end in .iso; trying anyway."
    }

    # Work dir + space
    if (-not $WorkDir) { $WorkDir = Join-Path $env:SystemDrive 'LiteOS-Build' }
    $script:WorkRoot = Resolve-FullPath $WorkDir
    $space = Get-DriveSpace -Path $script:WorkRoot
    if ($space.Type -ne 'Fixed') { Write-BuildLog -Level Warn -Message "WorkDir drive $($space.Root) is not a fixed disk ($($space.Type)); DISM may refuse to mount there." }
    if ($space.Format -ne 'NTFS') { Write-BuildLog -Level Warn -Message "WorkDir drive $($space.Root) is $($space.Format); DISM mounts need NTFS." }
    $needBytes = [int64]25 * 1GB
    if ($space.Free -lt $needBytes) {
        throw ("Not enough free space on {0}: {1} free, 25 GB needed. Use -WorkDir on another NTFS drive." -f $space.Root, (Format-Size $space.Free))
    }
    Write-BuildLog -Message ("Work folder: {0} ({1} free on {2})" -f $script:WorkRoot, (Format-Size $space.Free), $space.Root)
    if ($OutputPath) {
        $outFull = Resolve-FullPath $OutputPath
        if ((Test-Path -LiteralPath $outFull) -and -not $Force) { throw "Output file already exists: $outFull (use -Force to overwrite)." }
        if (Test-PathUnder -Child $outFull -Parent $script:WorkRoot) { throw 'OutputPath must not be inside WorkDir.' }
    }
    Write-BuildLog -Message ("Level: {0} | Edition: {1} | Apps: {2} | Requirement bypass: {3} | Auto device encryption: {4}" -f $Level, $Edition, ($appsList -join ','), $(if ($bypass) { 'on' } else { 'off' }), $(if ($KeepAutoEncryption) { 'kept' } else { 'prevented' }))

    # -----------------------------------------------------------------------------------------
    Write-Step 'Opening the Windows 11 ISO'
    # -----------------------------------------------------------------------------------------
    # Leftover hives first: while a hive from mount\Windows\System32\config is loaded, DISM cannot
    # discard that mount.
    foreach ($h in $script:HiveNames) {
        if (Test-HiveLoaded -Name $h) {
            Write-BuildLog -Level Warn -Message "Unloading leftover hive HKLM\$h from an earlier run."
            if (-not (Dismount-OfflineHive -Name $h)) { throw "HKLM\$h from an earlier run is still loaded. Close Registry Editor, run: reg unload HKLM\$h  and start the builder again." }
        }
    }
    Initialize-WorkDir -Path $script:WorkRoot
    $isoDir    = Join-Path $script:WorkRoot 'iso'
    $mountDir  = Join-Path $script:WorkRoot 'mount'
    $bootMount = Join-Path $script:WorkRoot 'bootmount'
    $scratch   = Join-Path $script:WorkRoot 'scratch'
    $stageDir  = Join-Path $script:WorkRoot 'stage'
    $stageWim  = Join-Path $stageDir 'install.wim'

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
        if (Test-Path -LiteralPath (Join-Path $isoSourceRoot 'sources\install.swm')) { throw 'Split install.swm media is not supported. Download the ISO from microsoft.com/software-download/windows11.' }
        throw 'sources\install.wim or sources\install.esd not found. Is this a Windows 11 ISO?'
    }
    Write-BuildLog -Message ("Install image: {0}" -f $installSource)
    if (Test-Path -LiteralPath (Join-Path $isoSourceRoot 'autounattend.xml')) {
        Write-BuildLog -Level Warn -Message 'The source media already has an autounattend.xml; it will be replaced by the Lite OS one. Use an untouched official ISO for best results.'
    }

    # -----------------------------------------------------------------------------------------
    Write-Step 'Checking the Windows version and choosing the edition'
    # -----------------------------------------------------------------------------------------
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

    if (-not $outFull) {
        $outFull = Join-Path (Get-Location).ProviderPath ("LiteOS-{0}.{1}.iso" -f $imageBuild, $imageRevision)
        if ((Test-Path -LiteralPath $outFull) -and -not $Force) { throw "Output file already exists: $outFull (use -Force or -OutputPath)." }
    }
    $outDir = Split-Path -Parent $outFull
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $outSpace = Get-DriveSpace -Path $outFull
    if ($outSpace.Root -ne $space.Root -and $outSpace.Free -lt ([int64]8 * 1GB)) {
        throw ("Not enough free space for the ISO on {0}: {1} free, 8 GB needed." -f $outSpace.Root, (Format-Size $outSpace.Free))
    }

    # -----------------------------------------------------------------------------------------
    Write-Step 'Copying setup files to the work folder'
    # -----------------------------------------------------------------------------------------
    $rc = Invoke-Native -FilePath 'robocopy.exe' -ArgumentList @($isoSourceRoot, $isoDir, '/E', '/XF', 'install.wim', 'install.esd', 'install.swm', '/A-:R', '/R:2', '/W:2', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
    if ($rc.ExitCode -ge 8) { throw ("Copying the ISO failed (robocopy exit {0}): {1}" -f $rc.ExitCode, ($rc.Output -join ' ')) }
    foreach ($f in @(Get-ChildItem -LiteralPath $isoDir -Recurse -File -Force | Where-Object { $_.IsReadOnly })) { $f.IsReadOnly = $false }
    Write-BuildLog -Level Ok -Message 'Setup files copied.'

    # -----------------------------------------------------------------------------------------
    Write-Step ("Exporting '{0}' to a single-edition image" -f $selected.ImageName)
    # -----------------------------------------------------------------------------------------
    # Staging export uses fast compression; the final install.wim is re-exported with max compression.
    Write-BuildLog -Message 'This takes several minutes (install.esd is decompressed)...'
    try {
        Export-WindowsImage -SourceImagePath $installSource -SourceIndex $index -DestinationImagePath $stageWim -CompressionType 'fast' -ScratchDirectory $scratch -LogPath $script:DismLog | Out-Null
    } catch {
        Write-BuildLog -Level Warn -Message ("Export with fast compression failed ({0}); retrying with max compression." -f $_.Exception.Message)
        if (Test-Path -LiteralPath $stageWim) { Remove-Item -LiteralPath $stageWim -Force }
        Export-WindowsImage -SourceImagePath $installSource -SourceIndex $index -DestinationImagePath $stageWim -CompressionType 'max' -ScratchDirectory $scratch -LogPath $script:DismLog | Out-Null
    }
    Write-BuildLog -Level Ok -Message ("Staging image: {0} ({1})" -f $stageWim, (Format-Size (Get-Item -LiteralPath $stageWim).Length))
    if ($script:IsoAttachedByUs) {
        Dismount-DiskImage -ImagePath $script:IsoFullPath | Out-Null
        $script:IsoAttachedByUs = $false
        Write-BuildLog -Message 'ISO dismounted.'
    }

    # -----------------------------------------------------------------------------------------
    Write-Step 'Mounting the install image'
    # -----------------------------------------------------------------------------------------
    Mount-WindowsImage -ImagePath $stageWim -Index 1 -Path $mountDir -ScratchDirectory $scratch -LogPath $script:DismLog | Out-Null
    [void]$script:MountedImages.Add($mountDir)
    Write-BuildLog -Level Ok -Message "Mounted at $mountDir"

    # -----------------------------------------------------------------------------------------
    Write-Step ("Removing preinstalled apps offline ({0} level)" -f $Level)
    # -----------------------------------------------------------------------------------------
    if ($appsRemoveJson) {
        # Built-in engine list + "protected" from apps-remove.json, so a trimmed or broken JSON list
        # never removes Store, winget, Xbox / Gaming Services, runtimes or Edge from the image.
        $protectedPatterns = @(Get-LiteOSProtectedApps -Path (Join-Path $repoRoot 'tweaks') | ForEach-Object { [string]$_ })
        foreach ($p in @(Get-JsonProp $appsRemoveJson 'protected' @())) {
            if ($p -is [string] -and $p.Trim() -and -not ($protectedPatterns -contains $p.Trim())) { $protectedPatterns += $p.Trim() }
        }
        Write-BuildLog -Message ("{0} protected app patterns are never removed." -f $protectedPatterns.Count)
        $plan = Get-AppRemovalPlan -AppsJson $appsRemoveJson -ChosenLevel $Level -IncludeIds $includeList -ExcludeIds $excludeList
        $provisioned = @(Get-AppxProvisionedPackage -Path $mountDir -LogPath $script:DismLog)
        Write-BuildLog -Message ("{0} provisioned packages in the image, {1} removal rules selected." -f $provisioned.Count, $plan.Count)
        foreach ($rule in $plan) {
            $hits = @($provisioned | Where-Object { $_.DisplayName -like $rule.Match })
            if ($hits.Count -eq 0) { Write-BuildLog -Message ("skip   {0} (not in this image)" -f $rule.Match); continue }
            foreach ($pkg in $hits) {
                if (Test-ProtectedApp -PackageName $pkg.DisplayName -Patterns $protectedPatterns) {
                    Write-BuildLog -Level Warn -Message ("refuse {0}: protected package (matched rule '{1}')" -f $pkg.DisplayName, $rule.Match)
                    continue
                }
                try {
                    Remove-AppxProvisionedPackage -Path $mountDir -PackageName $pkg.PackageName -LogPath $script:DismLog | Out-Null
                    [void]$removedApps.Add($pkg.DisplayName)
                    Write-BuildLog -Message ("removed {0}" -f $pkg.DisplayName)
                } catch {
                    Write-BuildLog -Level Warn -Message ("could not remove {0}: {1}" -f $pkg.DisplayName, $_.Exception.Message)
                }
            }
        }
        Write-BuildLog -Level Ok -Message ("{0} provisioned app(s) removed." -f $removedApps.Count)
    } else {
        Write-BuildLog -Message 'Skipped (no apps-remove.json).'
    }

    # -----------------------------------------------------------------------------------------
    Write-Step 'Applying offline registry settings'
    # -----------------------------------------------------------------------------------------
    $imageHives = @('LITE_SOFTWARE', 'LITE_SYSTEM', 'LITE_DEFAULT')
    try {
        Mount-OfflineHive -Name 'LITE_SOFTWARE' -File (Join-Path $mountDir 'Windows\System32\config\SOFTWARE')
        Mount-OfflineHive -Name 'LITE_SYSTEM'   -File (Join-Path $mountDir 'Windows\System32\config\SYSTEM')
        Mount-OfflineHive -Name 'LITE_DEFAULT'  -File (Join-Path $mountDir 'Users\Default\NTUSER.DAT')
        $controlSet = Get-OfflineControlSet -HiveName 'LITE_SYSTEM'
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
            @{ Hive = 'DEFAULT';  Op = 'set'; When = 'bypass'; Key = 'Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV2'; Type = 'REG_DWORD'; Data = '0'; Why = 'No "system requirements not met" notice' }
        )
        foreach ($n in $script:LabConfigNames) {
            $settings += @{ Hive = 'SYSTEM'; Op = 'set'; When = 'bypass'; Key = 'Setup\LabConfig'; Name = $n; Type = 'REG_DWORD'; Data = '1'; Why = 'Windows 11 requirement bypass (in-place repair/upgrade setup)' }
        }

        $applied = 0; $failed = 0
        foreach ($s in $settings) {
            if ($s.When -eq 'bypass' -and -not $bypass) { continue }
            if ($s.When -eq 'noencrypt' -and $KeepAutoEncryption) { continue }
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
                    Write-OfflineRegValue -Key $fullKey -Name $s.Name -Type $s.Type -Data $s.Data
                    Write-BuildLog -Message ("set     {0}\{1} = {2}  ({3})" -f $label, $s.Name, $s.Data, $s.Why)
                    [void]$offlineLog.Add(('{0}\{1} = {2} ({3})' -f $label, $s.Name, $s.Data, $s.Type))
                }
                $applied++
            } catch {
                $failed++
                Write-BuildLog -Level Warn -Message $_.Exception.Message
            }
        }
        Write-BuildLog -Level Ok -Message ("{0} offline registry change(s) applied, {1} failed." -f $applied, $failed)
    } finally {
        # Always unload (never throw from here, so the original error is not hidden).
        foreach ($h in @('LITE_DEFAULT', 'LITE_SYSTEM', 'LITE_SOFTWARE')) {
            if ($script:LoadedHives -contains $h) { [void](Dismount-OfflineHive -Name $h) }
        }
    }
    $stillLoaded = @($script:LoadedHives | Where-Object { $imageHives -contains $_ })
    if ($stillLoaded.Count -gt 0) { throw ("Could not unload {0}; the image cannot be saved safely." -f ($stillLoaded -join ', ')) }

    # -----------------------------------------------------------------------------------------
    Write-Step 'Copying the Lite OS playbook into the image'
    # -----------------------------------------------------------------------------------------
    $payloadDir = Join-Path $mountDir 'LiteOS'
    $stateDir   = Join-Path $mountDir 'ProgramData\LiteOS'
    foreach ($d in @($payloadDir, $stateDir, (Join-Path $stateDir 'logs'))) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    foreach ($item in @('LiteOS.ps1', 'Revert-LiteOS.ps1', 'Start-LiteOS.cmd', 'src', 'tweaks', 'LICENSE', 'README.md')) {
        $srcItem = Join-Path $repoRoot $item
        if (-not (Test-Path -LiteralPath $srcItem)) {
            if (@('Revert-LiteOS.ps1', 'Start-LiteOS.cmd') -contains $item) { Write-BuildLog -Level Warn -Message "$item not found; skipped." }
            continue
        }
        Copy-Item -LiteralPath $srcItem -Destination (Join-Path $payloadDir $item) -Recurse -Force
        Write-BuildLog -Message ("copied {0} -> C:\LiteOS\{0}" -f $item)
    }
    # Drop mark-of-the-web so the payload runs cleanly on the new install.
    Get-ChildItem -LiteralPath $payloadDir -Recurse -File -Force | Unblock-File -ErrorAction SilentlyContinue

    $builtAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $config = [ordered]@{
        level     = $Level
        include   = [string[]]$includeList
        exclude   = [string[]]$excludeList
        apps      = $appsValue
        builtWith = ('Lite OS Build-LiteOS.ps1 {0}' -f $script:BuilderVersion)
        builtAt   = $builtAt
    }
    $configPath = Join-Path $stateDir 'config.json'
    Write-TextFile -Path $configPath -Text (ConvertTo-Json -InputObject $config -Depth 5)
    $null = Read-JsonFile -Path $configPath
    Write-BuildLog -Message 'wrote C:\ProgramData\LiteOS\config.json'

    $buildInfo = [ordered]@{
        builder                 = ('Build-LiteOS.ps1 {0}' -f $script:BuilderVersion)
        builtAt                 = $builtAt
        sourceIso               = (Split-Path -Leaf $script:IsoFullPath)
        edition                 = [string]$selected.ImageName
        editionId               = [string]$selected.EditionId
        build                   = ('{0}.{1}' -f $imageBuild, $imageRevision)
        level                   = $Level
        bypassRequirements      = [bool]$bypass
        preventDeviceEncryption = [bool](-not $KeepAutoEncryption)
        removedProvisionedApps  = [string[]]@($removedApps)
        offlineRegistry         = [string[]]@($offlineLog)
    }
    Write-TextFile -Path (Join-Path $stateDir 'build-info.json') -Text (ConvertTo-Json -InputObject $buildInfo -Depth 5)
    Write-BuildLog -Message 'wrote C:\ProgramData\LiteOS\build-info.json (what the builder changed offline)'
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
    Write-BuildLog -Level Ok -Message 'Payload and config in place.'

    # -----------------------------------------------------------------------------------------
    Write-Step 'Saving and unmounting the install image'
    # -----------------------------------------------------------------------------------------
    Dismount-WindowsImage -Path $mountDir -Save -ScratchDirectory $scratch -LogPath $script:DismLog | Out-Null
    $script:MountedImages.Remove($mountDir)
    Write-BuildLog -Level Ok -Message 'Install image saved.'

    # -----------------------------------------------------------------------------------------
    Write-Step 'Adding the requirement bypass to Windows Setup (boot.wim)'
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
    Write-Step 'Optimizing install.wim (maximum compression)'
    # -----------------------------------------------------------------------------------------
    $finalWim = Join-Path $isoDir 'sources\install.wim'
    foreach ($old in @('install.wim', 'install.esd')) {
        $o = Join-Path $isoDir ('sources\' + $old)
        if (Test-Path -LiteralPath $o) { Remove-Item -LiteralPath $o -Force }
    }
    Export-WindowsImage -SourceImagePath $stageWim -SourceIndex 1 -DestinationImagePath $finalWim -CompressionType 'max' -ScratchDirectory $scratch -LogPath $script:DismLog | Out-Null
    Remove-Item -LiteralPath $stageWim -Force
    $wimSize = (Get-Item -LiteralPath $finalWim).Length
    Write-BuildLog -Level Ok -Message ("install.wim: {0}" -f (Format-Size $wimSize))
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
    Write-Step 'Writing autounattend.xml'
    # -----------------------------------------------------------------------------------------
    $banner = ('Generated by Lite OS Build-LiteOS.ps1 {0} at {1}; requirement bypass {2}. No disk, key or account settings.' -f $script:BuilderVersion, $builtAt, $(if ($bypass) { 'ON' } else { 'OFF' }))
    $unattend = Get-LiteOSUnattendXml -TemplateText ([IO.File]::ReadAllText($template)) -BypassRequirements $bypass -Banner $banner
    Write-TextFile -Path (Join-Path $isoDir 'autounattend.xml') -Text $unattend
    Write-BuildLog -Level Ok -Message 'autounattend.xml written to the ISO root (validated: no disk settings, no product key - only the empty Key Setup requires - and no accounts).'

    # -----------------------------------------------------------------------------------------
    Write-Step 'Creating the bootable ISO'
    # -----------------------------------------------------------------------------------------
    $label = ('LITEOS_{0}' -f $imageBuild)
    $isoArgs = @{ SourcePath = $isoDir; OutputPath = $outFull; Label = $label; Force = $true }
    if ($NoPrompt) { $isoArgs['NoPrompt'] = $true }
    & $isoScript @isoArgs | Out-Null
    if (-not (Test-Path -LiteralPath $outFull -PathType Leaf)) { throw 'New-IsoFile.ps1 did not produce the ISO.' }

    # -----------------------------------------------------------------------------------------
    Write-Step 'Computing SHA256'
    # -----------------------------------------------------------------------------------------
    $hash = (Get-FileHash -LiteralPath $outFull -Algorithm SHA256).Hash
    $isoItem = Get-Item -LiteralPath $outFull
    Set-Content -LiteralPath ($outFull + '.sha256') -Value ('{0} *{1}' -f $hash, $isoItem.Name) -Encoding ASCII
    Write-BuildLog -Message ("SHA256 {0}" -f $hash)

    $script:Succeeded = $true
    Write-BuildLog -Level Step -Message 'Build complete'
    Write-BuildLog -Level Ok -Message ("Lite OS ISO: {0} ({1})" -f $outFull, (Format-Size $isoItem.Length))
    Write-BuildLog -Message ("Edition {0}, build {1}.{2}, level {3}, apps {4}" -f $selected.ImageName, $imageBuild, $imageRevision, $Level, ($appsList -join ','))
    Write-Host ''
    Write-Host '  Next: write the ISO to a USB stick with Rufus (uncheck all "Windows User Experience" options;'
    Write-Host '  Lite OS already has its own answer file), boot it, and pick the disk/partition yourself in Setup.'
    Write-Host '  See builder\README.md for BIOS/UEFI notes and licensing.'
}
catch {
    Write-BuildLog -Level Error -Message $_.Exception.Message
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        if ($script:LogFile) { try { Add-Content -LiteralPath $script:LogFile -Value $_.InvocationInfo.PositionMessage -Encoding UTF8 } catch { Write-Verbose 'Log write failed.' } }
    }
}
finally {
    Invoke-Cleanup -Failed (-not $script:Succeeded)
}

if ($script:Succeeded) { exit 0 } else { exit 1 }

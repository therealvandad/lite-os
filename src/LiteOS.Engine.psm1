#Requires -Version 5.1
<#
    Lite OS tweak engine (src/LiteOS.Engine.psm1)

    Loads the tweak catalog (tweaks/*.json), selects tweaks for a level, applies them while
    recording a revert entry for every change, and restores backups.
    The binding contract is docs/ARCHITECTURE.md.

    Importing this module has NO side effects: nothing is written to disk or to the registry
    until Initialize-LiteOS, Invoke-LiteOSTweak, Invoke-LiteOSPlan, Restore-LiteOSBackup or
    New-LiteOSRestorePoint is called. Select-LiteOSTweaks is a pure function.

    Windows PowerShell 5.1 compatible, ASCII only.
#>

Set-StrictMode -Version 2.0

# =============================================================================================
# Module constants (in memory only)
# =============================================================================================

$script:LiteOSVersion   = '2.0.0'
$script:ModuleRoot      = $PSScriptRoot
$script:LiteOSLogFile   = $null
$script:DefaultHiveName = 'LiteOS_Default'
$script:Utf8NoBom       = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
$script:Utf8Bom         = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true

$script:ActionTypes   = @('registry', 'registry-delete', 'service', 'task', 'powershell', 'appx-remove')
$script:RegistryKinds = @('DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary')
$script:StartupTypes  = @('Disabled', 'Manual', 'Automatic', 'AutomaticDelayed')
$script:TaskStates    = @('Disabled', 'Enabled')
$script:Levels        = @('balanced', 'extreme')
$script:Risks         = @('none', 'low', 'medium', 'high')
$script:CategoryOrder = @('privacy', 'ui', 'gaming', 'performance', 'network', 'services', 'updates', 'security-extreme', 'apps')

# Live hives of the running PC (first key under HKLM). An offline hive mapping (-Hives) that names one
# of these is refused, so offline image edits can never change the build PC.
$script:LiveHiveNames = @('SOFTWARE', 'SYSTEM', 'SAM', 'SECURITY', 'HARDWARE', 'BCD00000000', 'COMPONENTS', 'DRIVERS', 'ELAM', 'SCHEMA')
# Installer exit codes treated as success (1638: same or newer version installed; 3010/1641: restart needed).
$script:InstallerSuccessCodes = @(0, 1638, 3010, 1641)

# SYSTEM and BUILTIN\Administrators: the only owners / writers trusted for the state folder.
$script:TrustedOwnerSids = @('S-1-5-18', 'S-1-5-32-544')
# FileSystemRights bits that allow changing a folder or file: WriteData, AppendData,
# WriteExtendedAttributes, DeleteSubdirectoriesAndFiles, WriteAttributes, Delete, ChangePermissions,
# TakeOwnership, GENERIC_ALL, GENERIC_WRITE.
$script:WriteRightsMask = [int64](0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000)

# Always protected, even if tweaks/apps-remove.json is edited or missing. Matched with -like
# against the AppX package Name (and the provisioned package DisplayName).
$script:BuiltInProtectedApps = @(
    'Microsoft.WindowsStore',
    'Microsoft.StorePurchaseApp',
    'Microsoft.DesktopAppInstaller',
    'Microsoft.GamingApp',
    'Microsoft.GamingServices',
    'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxGameOverlay',
    'Microsoft.XboxIdentityProvider',
    'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.Xbox.TCUI',
    'Microsoft.XboxGameCallableUI',
    'Microsoft.VCLibs*',
    'Microsoft.UI.Xaml*',
    'Microsoft.NET.Native*',
    'Microsoft.WindowsAppRuntime*',
    'Microsoft.WindowsCalculator',
    'Microsoft.Windows.Photos',
    'Microsoft.WindowsNotepad',
    'Microsoft.WindowsTerminal',
    'Microsoft.Paint',
    'Microsoft.ScreenSketch',
    'Microsoft.SecHealthUI',
    'Microsoft.Windows.SecHealthUI',
    'Microsoft.MicrosoftEdge*',
    'Microsoft.Win32WebViewHost',
    'Microsoft.WebView2*',
    'Microsoft.Windows.ShellExperienceHost',
    'Microsoft.Windows.StartMenuExperienceHost',
    'Microsoft.WidgetsPlatformRuntime',
    'MicrosoftWindows.Client.CBS',
    'MicrosoftWindows.Client.Core',
    'Microsoft.Windows.CloudExperienceHost',
    'Microsoft.AAD.BrokerPlugin',
    'Microsoft.AccountsControl',
    'Microsoft.LockApp',
    'windows.immersivecontrolpanel'
)

# Whole-key deletes of these (relative to HKLM / HKCU, lower case) are always refused.
$script:CriticalKeys = @(
    'software',
    'software\classes',
    'software\microsoft',
    'software\microsoft\windows',
    'software\microsoft\windows\currentversion',
    'software\microsoft\windows\currentversion\explorer',
    'software\microsoft\windows\currentversion\policies',
    'software\microsoft\windows nt',
    'software\microsoft\windows nt\currentversion',
    'software\policies',
    'software\policies\microsoft',
    'software\policies\microsoft\windows',
    'software\wow6432node',
    'system',
    'system\currentcontrolset',
    'system\currentcontrolset\control',
    'system\currentcontrolset\services',
    'system\controlset001',
    'system\setup'
)

# =============================================================================================
# Small generic helpers (internal)
# =============================================================================================

function Get-LiteOSProp {
    # Returns a property of a PSCustomObject / hashtable, or $Default. Arrays are unrolled
    # (wrap with @() when an array is expected).
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

function Get-LiteOSPropRaw {
    # Like Get-LiteOSProp but keeps arrays intact when assigned ($x = Get-LiteOSPropRaw ...).
    param($Object, [string]$Name)
    $v = $null
    if ($null -ne $Object) {
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { $v = $Object[$Name] }
        }
        else {
            $p = $Object.PSObject.Properties[$Name]
            if ($null -ne $p) { $v = $p.Value }
        }
    }
    return , $v
}

function Test-LiteOSProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return [bool]$Object.Contains($Name) }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-LiteOSCanonical {
    # Case-insensitive lookup of $Value in $Set; returns the canonical spelling or $null.
    param($Value, [string[]]$Set)
    if (-not ($Value -is [string])) { return $null }
    $v = $Value.Trim()
    foreach ($s in $Set) { if ($s -eq $v) { return $s } }
    return $null
}

function ConvertTo-LiteOSBool {
    param($Value, [bool]$Default = $false)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) {
        $s = $Value.Trim().ToLowerInvariant()
        return ($s -eq 'true' -or $s -eq '1' -or $s -eq 'yes' -or $s -eq 'on')
    }
    try { return ([decimal]$Value -ne 0) } catch { return $Default }
}

function ConvertTo-LiteOSDecimal {
    param($Value)
    if ($null -eq $Value) { throw 'a number is required' }
    if ($Value -is [bool]) { if ($Value) { return [decimal]1 } else { return [decimal]0 } }
    if ($Value -is [string]) {
        $s = $Value.Trim()
        if ($s -match '^0[xX]([0-9a-fA-F]{1,16})$') {
            return [decimal][uint64]::Parse($Matches[1], [System.Globalization.NumberStyles]::HexNumber)
        }
        $out = [decimal]0
        if ([decimal]::TryParse($s, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$out)) {
            return $out
        }
        throw ("'{0}' is not a number" -f $Value)
    }
    $d = [decimal]0
    try { $d = [decimal]$Value } catch { throw ("'{0}' is not a number" -f $Value) }
    if ($d -ne [decimal]::Truncate($d)) { throw ("'{0}' is not a whole number" -f $Value) }
    return $d
}

function ConvertTo-LiteOSDWord {
    param($Value)
    $d = ConvertTo-LiteOSDecimal $Value
    if ($d -lt [decimal]-2147483648 -or $d -gt [decimal]4294967295) { throw ("DWord value out of range: {0}" -f $Value) }
    if ($d -gt [decimal]2147483647) { $d = $d - [decimal]4294967296 }
    return [int32]$d
}

function ConvertTo-LiteOSQWord {
    param($Value)
    $d = ConvertTo-LiteOSDecimal $Value
    if ($d -lt [decimal][int64]::MinValue -or $d -gt [decimal][uint64]::MaxValue) { throw ("QWord value out of range: {0}" -f $Value) }
    if ($d -gt [decimal][int64]::MaxValue) {
        return [System.BitConverter]::ToInt64([System.BitConverter]::GetBytes([uint64]$d), 0)
    }
    return [int64]$d
}

function ConvertFrom-LiteOSHex {
    # Hex string ("01 00 ff", "0100ff", "01,00,ff", "hex:01,00") or array of numbers -> byte[]
    param($Value)
    if ($null -eq $Value) { return , ([byte[]]@()) }
    if ($Value -is [byte[]]) { return , $Value }
    if ($Value -is [string]) {
        $s = $Value.Trim()
        if ($s.StartsWith('hex:', [System.StringComparison]::OrdinalIgnoreCase)) { $s = $s.Substring(4) }
        $s = ($s -replace '0x', '') -replace '[\s,\-]', ''
        if ($s -notmatch '^[0-9a-fA-F]*$') { throw 'Binary value must be a hex string such as "01 00 ff"' }
        if (($s.Length % 2) -ne 0) { throw 'Binary value has an odd number of hex digits' }
        $bytes = New-Object -TypeName byte[] -ArgumentList ([int]($s.Length / 2))
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            $bytes[$i] = [System.Convert]::ToByte($s.Substring($i * 2, 2), 16)
        }
        return , $bytes
    }
    $list = New-Object -TypeName 'System.Collections.Generic.List[byte]'
    foreach ($x in @($Value)) {
        if ($null -eq $x) { continue }
        $n = ConvertTo-LiteOSDecimal $x
        if ($n -lt 0 -or $n -gt 255) { throw ("Binary byte out of range: {0}" -f $x) }
        $list.Add([byte]$n)
    }
    return , ($list.ToArray())
}

function ConvertTo-LiteOSHex {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    return ([System.BitConverter]::ToString($Bytes)).Replace('-', '').ToLowerInvariant()
}

function ConvertTo-LiteOSStringArray {
    param($Value)
    $list = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($x in @($Value)) {
        if ($null -ne $x) { $list.Add([string]$x) }
    }
    return , ($list.ToArray())
}

function Split-LiteOSList {
    # Accepts arrays and comma/semicolon separated strings (powershell -File passes "a,b" as one string).
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

function ConvertTo-LiteOSValueName {
    # The .NET registry API only treats "" as a key's unnamed default value; "(default)" or "@"
    # would create a value literally called that. Map the usual spellings to "".
    param([string]$Name)
    if ($null -eq $Name) { return '' }
    $t = $Name.Trim()
    if ($t -eq '@' -or $t -match '^\((?i:default)\)$') { return '' }
    return $Name
}

function Test-LiteOSIdMatch {
    param([string]$Id, [string[]]$Patterns)
    foreach ($p in @($Patterns)) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        if ($Id -eq $p) { return $true }
        if ($p.IndexOf('*') -ge 0 -or $p.IndexOf('?') -ge 0) {
            try { if ($Id -like $p) { return $true } } catch { $null = $_ }
        }
    }
    return $false
}

function Get-LiteOSBuildBound {
    param($Tweak, [string]$Name)
    $v = Get-LiteOSProp $Tweak $Name
    if ($null -eq $v) { return 0 }
    try { return [int](ConvertTo-LiteOSDecimal $v) } catch { return 0 }
}

function Test-LiteOSBuildRange {
    param($Tweak, [int]$Build)
    if ($Build -le 0) { return $true }
    $min = Get-LiteOSBuildBound $Tweak 'minBuild'
    $max = Get-LiteOSBuildBound $Tweak 'maxBuild'
    if ($min -gt 0 -and $Build -lt $min) { return $false }
    if ($max -gt 0 -and $Build -gt $max) { return $false }
    return $true
}

function Read-LiteOSJsonFile {
    param([string]$Path)
    $raw = $null
    try { $raw = [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom) }
    catch { throw ("{0}: cannot read file: {1}" -f $Path, $_.Exception.Message) }
    if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
    if ([string]::IsNullOrWhiteSpace($raw)) { throw ("{0}: file is empty" -f $Path) }
    try { $obj = ConvertFrom-Json -InputObject $raw }
    catch { throw ("{0}: invalid JSON: {1}" -f $Path, $_.Exception.Message) }
    if ($null -eq $obj) { throw ("{0}: JSON document is empty" -f $Path) }
    return $obj
}

function Write-LiteOSTextFile {
    # Atomic-ish write: temp file + replace, so a crash never leaves a half-written file.
    # ReplaceFile keeps the replaced file's DACL but NOT its owner (the result is owned by whoever
    # wrote the temp file, e.g. the elevated user's own SID). When the old file was owned by SYSTEM or
    # Administrators (backup-image.json, deferred.json, ...) that trusted owner is put back - or
    # Administrators when this process may not assign SYSTEM - so the owner check of other
    # administrators (Test-LiteOSTrustedFile) keeps accepting the file after the rewrite.
    param([string]$Path, [string]$Text, [System.Text.Encoding]$Encoding = $script:Utf8NoBom)
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $tmp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $Text, $Encoding)
    if ([System.IO.File]::Exists($Path)) {
        $oldOwner = Get-LiteOSFileOwner $Path
        try { [System.IO.File]::Replace($tmp, $Path, $null) }
        catch {
            [System.IO.File]::Copy($tmp, $Path, $true)
            [System.IO.File]::Delete($tmp)
        }
        if ($script:TrustedOwnerSids -contains $oldOwner) { Restore-LiteOSFileOwner -Path $Path -Owner $oldOwner }
    }
    else {
        [System.IO.File]::Move($tmp, $Path)
    }
}

function Restore-LiteOSFileOwner {
    # Best effort, never throws: gives $Path back its trusted owner (SYSTEM / Administrators) after a
    # rewrite changed it. Falls back to Administrators, which an elevated admin may always assign.
    param([string]$Path, [string]$Owner)
    try {
        $now = Get-LiteOSFileOwner $Path
        if ([string]::IsNullOrEmpty($now) -or $now -eq $Owner) { return }
        $candidates = @($Owner)
        if ($Owner -ne 'S-1-5-32-544') { $candidates += 'S-1-5-32-544' }
        foreach ($sid in $candidates) {
            try {
                $sec = [System.IO.File]::GetAccessControl($Path, [System.Security.AccessControl.AccessControlSections]::Owner)
                $sec.SetOwner((New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList $sid))
                [System.IO.File]::SetAccessControl($Path, $sec)
                return
            }
            catch { $null = $_ }
        }
        Write-LiteOSLog -NoConsole -Level Warn ('{0} is now owned by {1}; other administrators may have to adopt it (icacls "{0}" /setowner *S-1-5-32-544).' -f $Path, $now)
    }
    catch { $null = $_ }
}

function Invoke-LiteOSNative {
    # Runs a native exe without PS 5.1 turning stderr into terminating errors.
    param([string]$FilePath, [string[]]$ArgumentList = @())
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = @()
    $code = -1
    try {
        $out = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
    }
    catch {
        $out = @($_.Exception.Message)
        $code = -1
    }
    finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{ ExitCode = $code; Output = (($out | Where-Object { $_ -ne '' }) -join ' ').Trim() }
}

function Get-LiteOSSystemExe {
    param([string]$Name)
    $root = $env:SystemRoot
    if ([string]::IsNullOrEmpty($root)) { $root = 'C:\Windows' }
    $p = Join-Path (Join-Path $root 'System32') $Name
    if (Test-Path -LiteralPath $p) { return $p }
    return $Name
}

function Get-LiteOSDefaultStateRoot {
    $pd = $env:ProgramData
    if ([string]::IsNullOrEmpty($pd)) {
        $sd = $env:SystemDrive
        if ([string]::IsNullOrEmpty($sd)) { $sd = 'C:' }
        $pd = Join-Path $sd 'ProgramData'
    }
    return (Join-Path $pd 'LiteOS')
}

function Get-LiteOSDefaultTweaksPath {
    return (Join-Path (Split-Path -Parent $script:ModuleRoot) 'tweaks')
}

function Get-LiteOSCurrentSid {
    try { return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { return '' }
}

function Format-LiteOSShort {
    param([string]$Text, [int]$Max = 120)
    if ($null -eq $Text) { return '' }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -le $Max) { return $t }
    return ($t.Substring(0, $Max - 3) + '...')
}

function ConvertTo-LiteOSOutcome {
    param([string]$Status, [string]$Message, [bool]$Reboot = $false, $Apps = $null)
    return [pscustomobject]@{ status = $Status; message = $Message; reboot = $Reboot; apps = $Apps }
}

# =============================================================================================
# Logging
# =============================================================================================

function Write-LiteOSLog {
    <#
    .SYNOPSIS
        Writes a timestamped line to the Lite OS log (if Initialize-LiteOS ran) and to the console.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateSet('Info', 'Warn', 'Error', 'Success', 'Debug')]
        [string]$Level = 'Info',

        [switch]$NoConsole
    )
    $tag = 'INFO '
    switch ($Level) {
        'Warn'    { $tag = 'WARN ' }
        'Error'   { $tag = 'ERROR' }
        'Success' { $tag = 'OK   ' }
        'Debug'   { $tag = 'DEBUG' }
    }
    if ($null -ne $script:LiteOSLogFile) {
        try {
            $line = '{0} [{1}] {2}{3}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $tag, $Message, [Environment]::NewLine
            [System.IO.File]::AppendAllText($script:LiteOSLogFile, $line, $script:Utf8NoBom)
        }
        catch { $null = $_ }
    }
    if ($NoConsole -or $Level -eq 'Debug') { return }
    switch ($Level) {
        'Warn'    { Write-Host ('  WARNING: ' + $Message) -ForegroundColor Yellow }
        'Error'   { Write-Host ('  ERROR: ' + $Message) -ForegroundColor Red }
        'Success' { Write-Host ('  ' + $Message) -ForegroundColor Green }
        default   { Write-Host ('  ' + $Message) }
    }
}

# =============================================================================================
# System information / context
# =============================================================================================

function Test-LiteOSAdmin {
    <#
    .SYNOPSIS
        True when the current process runs elevated (member of BUILTIN\Administrators, full token).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $id
        return [bool]$principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-LiteOSWindowsInfo {
    <#
    .SYNOPSIS
        Read-only: Windows build, UBR, display version, edition and product name.
    #>
    [CmdletBinding()]
    param()
    $cv = $null
    try { $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop } catch { $cv = $null }
    $build = 0
    try { $build = [int](Get-LiteOSProp $cv 'CurrentBuildNumber' '0') } catch { $build = 0 }
    if ($build -le 0) { $build = [System.Environment]::OSVersion.Version.Build }
    $ubr = 0
    try { $ubr = [int](Get-LiteOSProp $cv 'UBR' 0) } catch { $ubr = 0 }
    $display = [string](Get-LiteOSProp $cv 'DisplayVersion' '')
    if (-not $display) { $display = [string](Get-LiteOSProp $cv 'ReleaseId' '') }
    $edition = [string](Get-LiteOSProp $cv 'EditionID' '')
    $product = [string](Get-LiteOSProp $cv 'ProductName' 'Windows')
    if ($build -ge 22000) { $product = $product -replace 'Windows 10', 'Windows 11' }
    $arch = [string]$env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = [string]$env:PROCESSOR_ARCHITEW6432 }
    return [pscustomobject]@{
        Build          = $build
        UBR            = $ubr
        FullBuild      = ('{0}.{1}' -f $build, $ubr)
        DisplayVersion = $display
        EditionID      = $edition
        ProductName    = $product
        Architecture   = $arch
        IsWindows11    = ($build -ge 22000)
        IsSupported    = ($build -ge 26100)
    }
}

function Get-LiteOSBlankContext {
    param([string]$StateRoot, [string]$Level = '', [bool]$DryRun = $false)
    if ([string]::IsNullOrEmpty($StateRoot)) { $StateRoot = Get-LiteOSDefaultStateRoot }
    $info = Get-LiteOSWindowsInfo
    $user = [string]$env:USERNAME
    if ($env:USERDOMAIN) { $user = ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME) }
    return [pscustomobject]@{
        Version          = $script:LiteOSVersion
        StateRoot        = $StateRoot
        LogDir           = (Join-Path $StateRoot 'logs')
        BackupDir        = (Join-Path $StateRoot 'backup')
        ConfigPath       = (Join-Path $StateRoot 'config.json')
        LogFile          = $null
        PayloadRoot      = (Split-Path -Parent $script:ModuleRoot)
        TweaksPath       = (Get-LiteOSDefaultTweaksPath)
        Build            = $info.Build
        UBR              = $info.UBR
        DisplayVersion   = $info.DisplayVersion
        Edition          = $info.EditionID
        ProductName      = $info.ProductName
        Architecture     = $info.Architecture
        Level            = $Level
        WhatIf           = $DryRun
        IsAdmin          = (Test-LiteOSAdmin)
        UserName         = $user
        UserSid          = (Get-LiteOSCurrentSid)
        BackupFile       = $null
        BackupHeader     = $null
        BackupEntries    = $null
        LastBackupFile   = $null
        DefaultHiveState = 'NotLoaded'
        DefaultHiveOwned = $false
        AppxCache        = $null
        ProvisionedCache = $null
        ProtectedApps    = $null
        RebootRequired   = $false
        Started          = (Get-Date)
    }
}

function Get-LiteOSFileOwner {
    # Owner SID of a file or folder ('' when it cannot be read).
    param([string]$Path)
    try {
        $sidType = [System.Security.Principal.SecurityIdentifier]
        $owners = [System.Security.AccessControl.AccessControlSections]::Owner
        if ([System.IO.Directory]::Exists($Path)) {
            return [string]([System.IO.Directory]::GetAccessControl($Path, $owners).GetOwner($sidType))
        }
        return [string]([System.IO.File]::GetAccessControl($Path, $owners).GetOwner($sidType))
    }
    catch { return '' }
}

function Test-LiteOSTrustedFile {
    # True when a state file (backup) was created by SYSTEM, the Administrators group or the
    # current elevated user - not planted by a standard account. Restores run its undo scripts
    # and registry data as administrator, so untrusted files are never used.
    param([string]$Path)
    $owner = Get-LiteOSFileOwner $Path
    if ([string]::IsNullOrEmpty($owner)) { return $false }
    if ($script:TrustedOwnerSids -contains $owner) { return $true }
    return ($owner -eq (Get-LiteOSCurrentSid) -and (Test-LiteOSAdmin))
}

function Protect-LiteOSStateDir {
    # Gives $env:ProgramData\LiteOS a protected ACL (inheritance off): SYSTEM and Administrators
    # full control, Users read only, owner Administrators. ProgramData normally lets every user
    # create files there, and backup files contain scripts that run elevated on revert.
    # Returns $null, or a warning text when the ACL could not be set.
    param([string]$Path)
    $sidType = [System.Security.Principal.SecurityIdentifier]
    try {
        $acl = [System.IO.Directory]::GetAccessControl($Path)
        $ok = [bool]$acl.AreAccessRulesProtected
        if ($ok -and ($script:TrustedOwnerSids -notcontains [string]$acl.GetOwner($sidType))) { $ok = $false }
        if ($ok) {
            foreach ($rule in @($acl.GetAccessRules($true, $true, $sidType))) {
                if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
                if ($script:TrustedOwnerSids -contains [string]$rule.IdentityReference) { continue }
                if (([int64]$rule.FileSystemRights -band $script:WriteRightsMask) -ne 0) { $ok = $false; break }
            }
        }
        if ($ok) { return $null }

        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $none = [System.Security.AccessControl.PropagationFlags]::None
        $allow = [System.Security.AccessControl.AccessControlType]::Allow
        $full = [System.Security.AccessControl.FileSystemRights]::FullControl
        $read = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
        $sec = New-Object -TypeName System.Security.AccessControl.DirectorySecurity
        $sec.SetAccessRuleProtection($true, $false)
        foreach ($s in @('S-1-5-18', 'S-1-5-32-544')) {
            $id = New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList $s
            $sec.AddAccessRule((New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule -ArgumentList $id, $full, $inherit, $none, $allow))
        }
        $usersId = New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-32-545'
        $sec.AddAccessRule((New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule -ArgumentList $usersId, $read, $inherit, $none, $allow))
        [System.IO.Directory]::SetAccessControl($Path, $sec)

        $note = $null
        try {
            $own = New-Object -TypeName System.Security.AccessControl.DirectorySecurity
            $own.SetOwner((New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-32-544'))
            [System.IO.Directory]::SetAccessControl($Path, $own)
        }
        catch { $note = ('Protected {0}, but could not make Administrators its owner: {1}' -f $Path, $_.Exception.Message) }
        return $note
    }
    catch {
        return ('Could not protect {0} (only administrators should be able to write there): {1}' -f $Path, $_.Exception.Message)
    }
}

function Initialize-LiteOS {
    <#
    .SYNOPSIS
        Creates $env:ProgramData\LiteOS\{logs,backup}, starts a new log file and returns the context object.
    .PARAMETER StateRoot
        Override the state folder (default $env:ProgramData\LiteOS). Useful for tests.
    .PARAMETER LogName
        Log file prefix (liteos-<timestamp>.log by default).
    .PARAMETER DryRun
        Marks the context as WhatIf: Invoke-* and Restore-* will not change anything.
    .PARAMETER LogFile
        Continue an existing log file instead of starting a new one.
    #>
    [CmdletBinding()]
    param(
        [string]$StateRoot,
        [string]$Level = '',
        [string]$LogName = 'liteos',
        [switch]$DryRun,
        [string]$LogFile
    )
    $ctx = Get-LiteOSBlankContext -StateRoot $StateRoot -Level $Level -DryRun ([bool]$DryRun)
    foreach ($d in @($ctx.StateRoot, $ctx.LogDir, $ctx.BackupDir)) {
        if (-not [System.IO.Directory]::Exists($d)) { [void][System.IO.Directory]::CreateDirectory($d) }
    }
    # Backups hold undo scripts that run elevated, so only SYSTEM / Administrators may write here.
    $aclNote = $null
    if (-not $DryRun -and $ctx.IsAdmin) { $aclNote = Protect-LiteOSStateDir -Path $ctx.StateRoot }
    if (-not [string]::IsNullOrEmpty($LogFile)) {
        $ctx.LogFile = $LogFile
        $script:LiteOSLogFile = $LogFile
        Write-LiteOSLog -NoConsole ('Lite OS {0} - log resumed' -f $script:LiteOSVersion)
        if ($aclNote) { Write-LiteOSLog -NoConsole -Level Warn $aclNote }
        return $ctx
    }
    $safeName = ($LogName -replace '[^A-Za-z0-9_\-]', '')
    if (-not $safeName) { $safeName = 'liteos' }
    $ctx.LogFile = Join-Path $ctx.LogDir ('{0}-{1}.log' -f $safeName, (Get-Date).ToString('yyyyMMdd-HHmmss'))
    $script:LiteOSLogFile = $ctx.LogFile

    # Keep the 40 most recent logs (never in a dry run: it must not change anything).
    if (-not $DryRun) {
        try {
            $old = @(Get-ChildItem -LiteralPath $ctx.LogDir -Filter '*.log' -File -ErrorAction Stop |
                    Sort-Object -Property LastWriteTime -Descending | Select-Object -Skip 40)
            foreach ($f in $old) { try { [System.IO.File]::Delete($f.FullName) } catch { $null = $_ } }
        }
        catch { $null = $_ }
    }

    Write-LiteOSLog -NoConsole ('Lite OS {0} - log started' -f $script:LiteOSVersion)
    if ($aclNote) { Write-LiteOSLog -NoConsole -Level Warn $aclNote }
    Write-LiteOSLog -NoConsole ('Windows: {0} {1} build {2}.{3} ({4}, {5})' -f $ctx.ProductName, $ctx.DisplayVersion, $ctx.Build, $ctx.UBR, $ctx.Edition, $ctx.Architecture)
    Write-LiteOSLog -NoConsole ('User: {0} ({1}), admin: {2}, PowerShell {3}, dry-run: {4}' -f $ctx.UserName, $ctx.UserSid, $ctx.IsAdmin, $PSVersionTable.PSVersion, $ctx.WhatIf)
    return $ctx
}

# =============================================================================================
# Protected apps
# =============================================================================================

function Get-LiteOSProtectedApps {
    <#
    .SYNOPSIS
        Built-in protected AppX names plus the "protected" list from tweaks/apps-remove.json.
    #>
    [CmdletBinding()]
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { $Path = Join-Path (Get-LiteOSDefaultTweaksPath) 'apps-remove.json' }
    elseif (Test-Path -LiteralPath $Path -PathType Container) { $Path = Join-Path $Path 'apps-remove.json' }
    $set = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($p in $script:BuiltInProtectedApps) { $set.Add($p) }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $json = Read-LiteOSJsonFile $Path
            foreach ($p in @(Get-LiteOSProp $json 'protected' @())) {
                if ($p -is [string] -and $p.Trim().Length -gt 0) {
                    $t = $p.Trim()
                    $dup = $false
                    foreach ($e in $set) { if ($e -eq $t) { $dup = $true; break } }
                    if (-not $dup) { $set.Add($t) }
                }
            }
        }
        catch {
            Write-LiteOSLog -Level Warn ('Could not read protected list from {0}: {1}. Using the built-in list.' -f $Path, $_.Exception.Message)
        }
    }
    return $set.ToArray()
}

function Test-LiteOSProtectedApp {
    <#
    .SYNOPSIS
        True if an AppX package name matches the protected list (never removed).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$Protected
    )
    if ($null -eq $Protected -or @($Protected).Count -eq 0) { $Protected = Get-LiteOSProtectedApps }
    foreach ($p in $Protected) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        try { if ($Name -like $p) { return $true } } catch { if ($Name -eq $p) { return $true } }
    }
    return $false
}

function Get-LiteOSProtectedConflict {
    # Returns @{ Blocked = protected entry that fully covers the pattern; Overlap = protected names the pattern could match }
    param([string]$Pattern, [string[]]$Protected)
    $literal = $Pattern.Replace('*', '').Replace('?', '')
    $blocked = $null
    $overlap = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($p in $Protected) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        $hit = $false
        try { $hit = ($Pattern -like $p) -or ($literal -like $p) } catch { $hit = ($Pattern -eq $p) }
        if ($hit -and $null -eq $blocked) { $blocked = $p }
        $pl = $p.Replace('*', '').Replace('?', '')
        $ov = $false
        try { $ov = ($pl -like $Pattern) } catch { $ov = $false }
        if ($ov) { $overlap.Add($p) }
    }
    return [pscustomobject]@{ Blocked = $blocked; Overlap = $overlap.ToArray() }
}

# =============================================================================================
# Registry primitives (Microsoft.Win32.RegistryKey, 64-bit view)
# =============================================================================================

function Resolve-LiteOSRegistryPath {
    # 'HKLM:\X\Y' / 'HKEY_LOCAL_MACHINE\X\Y' / 'Registry::HKEY_CURRENT_USER\X' -> {Root='HKLM'|'HKCU'; SubKey; Path}
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.Trim()
    if ($p.StartsWith('Registry::', [System.StringComparison]::OrdinalIgnoreCase)) { $p = $p.Substring(10) }
    $root = $null
    $rest = $null
    foreach ($prefix in @('HKEY_LOCAL_MACHINE\', 'HKLM:\', 'HKLM\')) {
        if ($p.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $root = 'HKLM'; $rest = $p.Substring($prefix.Length); break }
    }
    if ($null -eq $root) {
        foreach ($prefix in @('HKEY_CURRENT_USER\', 'HKCU:\', 'HKCU\')) {
            if ($p.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $root = 'HKCU'; $rest = $p.Substring($prefix.Length); break }
        }
    }
    if ($null -eq $root) { return $null }
    $rest = $rest.Trim('\')
    if ($rest.Length -eq 0) { return $null }
    if ($rest.IndexOf('\\') -ge 0) { return $null }
    return [pscustomobject]@{ Root = $root; SubKey = $rest; Path = ('{0}:\{1}' -f $root, $rest) }
}

function Test-LiteOSCriticalKey {
    param([string]$SubKey)
    $s = $SubKey.Trim('\').ToLowerInvariant()
    if (@($s.Split('\')).Count -lt 2) { return $true }
    return ($script:CriticalKeys -contains $s)
}

function Get-LiteOSRegistryTarget {
    # Resolves a logical HKLM:\ / HKCU:\ path for a hive: Machine, User (current user or a SID) or Default.
    param([string]$Path, [string]$Hive, [string]$UserSid)
    $info = Resolve-LiteOSRegistryPath $Path
    if ($null -eq $info) { throw ("Invalid registry path '{0}' (must start with HKLM:\ or HKCU:\)" -f $Path) }
    $prefix = ''
    $display = ''
    $baseHive = [Microsoft.Win32.RegistryHive]::LocalMachine
    if ($info.Root -eq 'HKLM') {
        $display = 'HKLM\'
    }
    elseif ($Hive -eq 'Default') {
        $baseHive = [Microsoft.Win32.RegistryHive]::Users
        $prefix = $script:DefaultHiveName + '\'
        $display = 'HKU\' + $prefix
    }
    else {
        $current = Get-LiteOSCurrentSid
        if (-not [string]::IsNullOrEmpty($UserSid) -and $UserSid -ne $current) {
            $baseHive = [Microsoft.Win32.RegistryHive]::Users
            $prefix = $UserSid + '\'
            $display = 'HKU\' + $prefix
        }
        else {
            $baseHive = [Microsoft.Win32.RegistryHive]::CurrentUser
            $display = 'HKCU\'
        }
    }
    return [pscustomobject]@{
        BaseHive = $baseHive
        Prefix   = $prefix
        Logical  = $info.SubKey
        SubKey   = ($prefix + $info.SubKey)
        Display  = ($display + $info.SubKey)
        Root     = $info.Root
    }
}

function Open-LiteOSBaseKey {
    param([Microsoft.Win32.RegistryHive]$Hive)
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry64)
}

function Test-LiteOSRegistryPrefix {
    # For Users-rooted targets, the hive (Default / SID) must be loaded.
    param($Target)
    if ([string]::IsNullOrEmpty($Target.Prefix)) { return $true }
    $base = Open-LiteOSBaseKey $Target.BaseHive
    try {
        $k = $base.OpenSubKey($Target.Prefix.TrimEnd('\'), $false)
        if ($null -eq $k) { return $false }
        $k.Close()
        return $true
    }
    finally { $base.Close() }
}

function Get-LiteOSRegistryValueState {
    param($Target, [string]$Name)
    $base = Open-LiteOSBaseKey $Target.BaseHive
    try {
        $key = $base.OpenSubKey($Target.SubKey, $false)
        if ($null -eq $key) {
            return [pscustomobject]@{ KeyExists = $false; Exists = $false; Kind = $null; Value = $null }
        }
        try {
            $exists = $false
            foreach ($n in $key.GetValueNames()) { if ($n -eq $Name) { $exists = $true; break } }
            if (-not $exists) {
                return [pscustomobject]@{ KeyExists = $true; Exists = $false; Kind = $null; Value = $null }
            }
            $kind = $key.GetValueKind($Name).ToString()
            $raw = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            return [pscustomobject]@{ KeyExists = $true; Exists = $true; Kind = $kind; Value = $raw }
        }
        finally { $key.Close() }
    }
    finally { $base.Close() }
}

function ConvertTo-LiteOSStoredValue {
    # Registry .NET value -> JSON friendly value (wrapped so arrays survive the return).
    param([string]$Kind, $Raw)
    $v = $null
    switch ($Kind) {
        'DWord' {
            $n = [int64][int32]$Raw
            if ($n -lt 0) { $n = $n + 4294967296 }
            $v = $n
        }
        'QWord'        { $v = [int64]$Raw }
        'String'       { $v = [string]$Raw }
        'ExpandString' { $v = [string]$Raw }
        'MultiString'  { $v = ConvertTo-LiteOSStringArray $Raw }
        default {
            if ($Raw -is [byte[]]) { $v = ConvertTo-LiteOSHex $Raw }
            elseif ($null -ne $Raw) { $v = [string]$Raw }
        }
    }
    return [pscustomobject]@{ Value = $v }
}

function Format-LiteOSRegistryValue {
    param([string]$Kind, $Value)
    if ($null -eq $Value) { return '(null)' }
    switch ($Kind) {
        'MultiString' { return (Format-LiteOSShort ('[' + ((ConvertTo-LiteOSStringArray $Value) -join ' | ') + ']') 80) }
        'Binary'      { return (Format-LiteOSShort ('hex:' + (ConvertTo-LiteOSHex (ConvertFrom-LiteOSHex $Value))) 80) }
        'None'        { return (Format-LiteOSShort ('hex:' + (ConvertTo-LiteOSHex (ConvertFrom-LiteOSHex $Value))) 80) }
        'String'      { return (Format-LiteOSShort ('"' + [string]$Value + '"') 80) }
        'ExpandString' { return (Format-LiteOSShort ('"' + [string]$Value + '"') 80) }
        default       { return [string]$Value }
    }
}

function Test-LiteOSRegistryDataEqual {
    param([string]$Kind, $Current, $Desired)
    switch ($Kind) {
        'DWord' { return ((ConvertTo-LiteOSDWord $Current) -eq (ConvertTo-LiteOSDWord $Desired)) }
        'QWord' { return ((ConvertTo-LiteOSQWord $Current) -eq (ConvertTo-LiteOSQWord $Desired)) }
        'MultiString' {
            $a = ConvertTo-LiteOSStringArray $Current
            $b = ConvertTo-LiteOSStringArray $Desired
            if ($a.Length -ne $b.Length) { return $false }
            for ($i = 0; $i -lt $a.Length; $i++) { if (-not ($a[$i] -ceq $b[$i])) { return $false } }
            return $true
        }
        'Binary' {
            return ((ConvertTo-LiteOSHex (ConvertFrom-LiteOSHex $Current)) -eq (ConvertTo-LiteOSHex (ConvertFrom-LiteOSHex $Desired)))
        }
        default { return ([string]$Current -ceq [string]$Desired) }
    }
}

function Write-LiteOSRegistryData {
    # Writes one value to an already opened writable key.
    param([Microsoft.Win32.RegistryKey]$Key, [string]$Name, [string]$Kind, $Value)
    switch ($Kind) {
        'DWord' {
            $Key.SetValue($Name, [int32](ConvertTo-LiteOSDWord $Value), [Microsoft.Win32.RegistryValueKind]::DWord)
        }
        'QWord' {
            $Key.SetValue($Name, [int64](ConvertTo-LiteOSQWord $Value), [Microsoft.Win32.RegistryValueKind]::QWord)
        }
        'String' {
            $s = ''
            if ($null -ne $Value) { $s = [string]$Value }
            $Key.SetValue($Name, $s, [Microsoft.Win32.RegistryValueKind]::String)
        }
        'ExpandString' {
            $s = ''
            if ($null -ne $Value) { $s = [string]$Value }
            $Key.SetValue($Name, $s, [Microsoft.Win32.RegistryValueKind]::ExpandString)
        }
        'MultiString' {
            [string[]]$ms = ConvertTo-LiteOSStringArray $Value
            if ($null -eq $ms) { $ms = [string[]]@() }
            $Key.SetValue($Name, $ms, [Microsoft.Win32.RegistryValueKind]::MultiString)
        }
        'None' {
            [byte[]]$b = ConvertFrom-LiteOSHex $Value
            if ($null -eq $b) { $b = [byte[]]@() }
            $Key.SetValue($Name, $b, [Microsoft.Win32.RegistryValueKind]::None)
        }
        default {
            # Binary, and Unknown types restored as Binary
            [byte[]]$b = ConvertFrom-LiteOSHex $Value
            if ($null -eq $b) { $b = [byte[]]@() }
            $Key.SetValue($Name, $b, [Microsoft.Win32.RegistryValueKind]::Binary)
        }
    }
}

function Get-LiteOSMissingKeys {
    # Logical sub keys (top-down) that do not exist yet and would be created for $Target.
    param($Target)
    $list = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $base = Open-LiteOSBaseKey $Target.BaseHive
    try {
        $parts = $Target.Logical.Split('\')
        $logical = ''
        $missing = $false
        for ($i = 0; $i -lt $parts.Length; $i++) {
            if ($i -eq 0) { $logical = $parts[0] } else { $logical = $logical + '\' + $parts[$i] }
            if (-not $missing) {
                $k = $base.OpenSubKey($Target.Prefix + $logical, $false)
                if ($null -eq $k) { $missing = $true } else { $k.Close() }
            }
            if ($missing) { $list.Add($logical) }
        }
    }
    finally { $base.Close() }
    return , ($list.ToArray())
}

function Write-LiteOSRegistryValue {
    # Creates missing keys and writes the value.
    param($Target, [string]$Name, [string]$Kind, $Value)
    $base = Open-LiteOSBaseKey $Target.BaseHive
    try {
        $key = $base.CreateSubKey($Target.SubKey)
        if ($null -eq $key) { throw ('Could not open or create key {0}' -f $Target.Display) }
        try { Write-LiteOSRegistryData -Key $key -Name $Name -Kind $Kind -Value $Value }
        finally { $key.Close() }
    }
    finally { $base.Close() }
}

function Clear-LiteOSRegistryValue {
    param($Target, [string]$Name)
    $base = Open-LiteOSBaseKey $Target.BaseHive
    try {
        $key = $base.OpenSubKey($Target.SubKey, $true)
        if ($null -eq $key) { return $false }
        try {
            $exists = $false
            foreach ($n in $key.GetValueNames()) { if ($n -eq $Name) { $exists = $true; break } }
            if ($exists) { $key.DeleteValue($Name, $false) }
            return $exists
        }
        finally { $key.Close() }
    }
    finally { $base.Close() }
}

function Clear-LiteOSEmptyKeys {
    # Deletes keys Lite OS created (deepest first) only if they are empty now.
    param($Target, [string[]]$LogicalKeys)
    $removed = 0
    $keys = @($LogicalKeys | Where-Object { -not [string]::IsNullOrEmpty($_) } | Sort-Object -Property Length -Descending)
    if ($keys.Count -eq 0) { return 0 }
    $base = Open-LiteOSBaseKey $Target.BaseHive
    try {
        foreach ($logical in $keys) {
            $full = $Target.Prefix + $logical
            $k = $base.OpenSubKey($full, $false)
            if ($null -eq $k) { continue }
            $empty = $false
            try { $empty = ($k.SubKeyCount -eq 0 -and $k.ValueCount -eq 0) } finally { $k.Close() }
            if ($empty) {
                try { $base.DeleteSubKey($full, $false); $removed++ } catch { $null = $_ }
            }
        }
    }
    finally { $base.Close() }
    return $removed
}

function Export-LiteOSRegistryTree {
    param([Microsoft.Win32.RegistryKey]$Key, [int]$Depth = 0)
    if ($Depth -gt 25) { throw 'Registry tree is too deep to back up safely' }
    $values = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($n in $Key.GetValueNames()) {
        $kind = $Key.GetValueKind($n).ToString()
        $raw = $Key.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $values.Add([pscustomobject]@{ name = $n; kind = $kind; value = (ConvertTo-LiteOSStoredValue $kind $raw).Value })
    }
    $subs = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($s in $Key.GetSubKeyNames()) {
        $sk = $Key.OpenSubKey($s, $false)
        if ($null -eq $sk) { continue }
        try { $subs.Add([pscustomobject]@{ name = $s; tree = (Export-LiteOSRegistryTree -Key $sk -Depth ($Depth + 1)) }) }
        finally { $sk.Close() }
    }
    return [pscustomobject]@{ values = $values.ToArray(); keys = $subs.ToArray() }
}

function Import-LiteOSRegistryTree {
    param([Microsoft.Win32.RegistryKey]$Base, [string]$SubKey, $Tree)
    $key = $Base.CreateSubKey($SubKey)
    if ($null -eq $key) { throw ('Could not create key {0}' -f $SubKey) }
    try {
        foreach ($v in @(Get-LiteOSProp $Tree 'values' @())) {
            if ($null -eq $v) { continue }
            $kind = [string](Get-LiteOSProp $v 'kind' 'String')
            $val = Get-LiteOSPropRaw $v 'value'
            Write-LiteOSRegistryData -Key $key -Name ([string](Get-LiteOSProp $v 'name' '')) -Kind $kind -Value $val
        }
    }
    finally { $key.Close() }
    foreach ($k in @(Get-LiteOSProp $Tree 'keys' @())) {
        if ($null -eq $k) { continue }
        Import-LiteOSRegistryTree -Base $Base -SubKey ($SubKey + '\' + [string](Get-LiteOSProp $k 'name')) -Tree (Get-LiteOSProp $k 'tree')
    }
}

# =============================================================================================
# Default user profile hive
# =============================================================================================

function Get-LiteOSDefaultHivePath {
    $dir = $null
    try {
        $pl = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction Stop
        $dir = [string](Get-LiteOSProp $pl 'Default' '')
    }
    catch { $dir = $null }
    if ([string]::IsNullOrEmpty($dir)) {
        $sd = $env:SystemDrive
        if ([string]::IsNullOrEmpty($sd)) { $sd = 'C:' }
        $dir = Join-Path $sd 'Users\Default'
    }
    $dir = [System.Environment]::ExpandEnvironmentVariables($dir)
    return (Join-Path $dir 'NTUSER.DAT')
}

function Mount-LiteOSDefaultHive {
    # Loads C:\Users\Default\NTUSER.DAT as HKU\LiteOS_Default. Returns $true when available.
    param($Context)
    if ($Context.DefaultHiveState -eq 'Mounted') { return $true }
    if ($Context.DefaultHiveState -eq 'Unavailable') { return $false }
    $users = Open-LiteOSBaseKey ([Microsoft.Win32.RegistryHive]::Users)
    try {
        $k = $users.OpenSubKey($script:DefaultHiveName, $false)
        if ($null -ne $k) {
            $k.Close()
            $Context.DefaultHiveState = 'Mounted'
            $Context.DefaultHiveOwned = $true
            Write-LiteOSLog -NoConsole ('Default profile hive was already loaded at HKU\{0}; reusing it.' -f $script:DefaultHiveName)
            return $true
        }
    }
    finally { $users.Close() }
    $hive = Get-LiteOSDefaultHivePath
    if (-not (Test-Path -LiteralPath $hive -PathType Leaf)) {
        $Context.DefaultHiveState = 'Unavailable'
        Write-LiteOSLog -Level Warn ('Default profile hive not found ({0}); HKCU tweaks apply to the current user only.' -f $hive)
        return $false
    }
    $r = Invoke-LiteOSNative -FilePath (Get-LiteOSSystemExe 'reg.exe') -ArgumentList @('load', ('HKU\' + $script:DefaultHiveName), $hive)
    if ($r.ExitCode -ne 0) {
        $Context.DefaultHiveState = 'Unavailable'
        Write-LiteOSLog -Level Warn ('Could not load the Default profile hive ({0}); HKCU tweaks apply to the current user only.' -f $r.Output)
        return $false
    }
    $Context.DefaultHiveState = 'Mounted'
    $Context.DefaultHiveOwned = $true
    Write-LiteOSLog -NoConsole ('Loaded Default profile hive {0} at HKU\{1}' -f $hive, $script:DefaultHiveName)
    return $true
}

function Dismount-LiteOSDefaultHive {
    param($Context)
    if ($Context.DefaultHiveState -ne 'Mounted') { return }
    if (-not $Context.DefaultHiveOwned) { return }
    $ok = $false
    $msg = ''
    for ($i = 0; $i -lt 6 -and -not $ok; $i++) {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        [System.GC]::Collect()
        $r = Invoke-LiteOSNative -FilePath (Get-LiteOSSystemExe 'reg.exe') -ArgumentList @('unload', ('HKU\' + $script:DefaultHiveName))
        if ($r.ExitCode -eq 0) { $ok = $true } else { $msg = $r.Output; Start-Sleep -Milliseconds 750 }
    }
    if ($ok) {
        Write-LiteOSLog -NoConsole 'Unloaded Default profile hive.'
    }
    else {
        Write-LiteOSLog -Level Warn ('Could not unload HKU\{0} ({1}). It will be released at the next restart.' -f $script:DefaultHiveName, $msg)
    }
    $Context.DefaultHiveState = 'NotLoaded'
    $Context.DefaultHiveOwned = $false
}

# =============================================================================================
# Backup file (written incrementally, write-ahead: the entry is saved BEFORE the change)
# =============================================================================================

function Save-LiteOSBackup {
    param($Context)
    if ([string]::IsNullOrEmpty($Context.BackupFile)) { return }
    $header = (ConvertTo-Json -InputObject $Context.BackupHeader -Depth 5).TrimEnd()
    if ($header.EndsWith('}')) { $header = $header.Substring(0, $header.Length - 1).TrimEnd() }
    $sb = New-Object -TypeName System.Text.StringBuilder
    [void]$sb.Append($header)
    [void]$sb.Append(',' + "`r`n" + '    "entries":  [' + "`r`n")
    $first = $true
    foreach ($e in $Context.BackupEntries) {
        if (-not $first) { [void]$sb.Append(',' + "`r`n") }
        [void]$sb.Append('        ').Append($e)
        $first = $false
    }
    [void]$sb.Append("`r`n" + '    ]' + "`r`n" + '}' + "`r`n")
    Write-LiteOSTextFile -Path $Context.BackupFile -Text $sb.ToString() -Encoding $script:Utf8Bom
}

function Open-LiteOSBackup {
    # Starts the run's backup file. Without -Path: a new backup-<timestamp>.json in BackupDir.
    # With -Path (image backup, e.g. backup-image.json): an existing trusted file is continued
    # (its header and entries are kept and new entries are appended); a missing file is created
    # with -Header fields added to the standard header (e.g. source = 'image').
    param($Context, [string]$Path, [System.Collections.IDictionary]$Header)
    if (-not [string]::IsNullOrEmpty($Context.BackupFile)) { return }
    if (-not [string]::IsNullOrEmpty($Path)) {
        if (Open-LiteOSBackupAt -Context $Context -Path $Path -Header $Header) { return }
    }
    if (-not [System.IO.Directory]::Exists($Context.BackupDir)) { [void][System.IO.Directory]::CreateDirectory($Context.BackupDir) }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $path = Join-Path $Context.BackupDir ('backup-{0}.json' -f $stamp)
    $n = 1
    while (Test-Path -LiteralPath $path) {
        $path = Join-Path $Context.BackupDir ('backup-{0}-{1}.json' -f $stamp, $n)
        $n++
    }
    $Context.BackupFile = $path
    $Context.BackupEntries = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $Context.BackupHeader = [ordered]@{
        version  = 1
        created  = (Get-Date).ToString('s')
        level    = [string]$Context.Level
        build    = $Context.Build
        ubr      = $Context.UBR
        edition  = [string]$Context.Edition
        liteos   = $script:LiteOSVersion
        computer = [string]$env:COMPUTERNAME
        user     = [string]$Context.UserName
        userSid  = [string]$Context.UserSid
        complete = $false
        restored = $null
    }
    Save-LiteOSBackup $Context
    Write-LiteOSLog -NoConsole ('Backup file: {0}' -f $path)
}

function Open-LiteOSBackupAt {
    # Opens (append) or creates the backup file $Path. Returns $false when an existing file cannot
    # be continued (not trusted / unreadable); the caller then falls back to a new timestamped file.
    param($Context, [string]$Path, [System.Collections.IDictionary]$Header)
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    if ([System.IO.File]::Exists($Path)) {
        if (-not (Test-LiteOSTrustedFile $Path)) {
            Write-LiteOSLog -Level Warn ('Backup {0} is not owned by SYSTEM or Administrators; it is left alone and a new backup file is used.' -f $Path)
            return $false
        }
        $data = $null
        try { $data = Read-LiteOSJsonFile $Path }
        catch {
            Write-LiteOSLog -Level Warn ('Backup {0} cannot be read ({1}); it is left alone and a new backup file is used.' -f $Path, $_.Exception.Message)
            return $false
        }
        $h = [ordered]@{}
        foreach ($p in $data.PSObject.Properties) { if ($p.Name -ne 'entries') { $h[$p.Name] = $p.Value } }
        $list = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($e in @(Get-LiteOSProp $data 'entries' @())) {
            if ($null -ne $e) { $list.Add((ConvertTo-Json -InputObject $e -Depth 100 -Compress)) }
        }
        $h['complete'] = $false
        $h['updated'] = (Get-Date).ToString('s')
        $Context.BackupFile = $Path
        $Context.BackupEntries = $list
        $Context.BackupHeader = $h
        Save-LiteOSBackup $Context
        Write-LiteOSLog -NoConsole ('Backup file (continued, {0} existing entries): {1}' -f $list.Count, $Path)
        return $true
    }
    $hdr = [ordered]@{
        version  = 1
        created  = (Get-Date).ToString('s')
        level    = [string]$Context.Level
        build    = $Context.Build
        ubr      = $Context.UBR
        edition  = [string]$Context.Edition
        liteos   = $script:LiteOSVersion
        computer = [string]$env:COMPUTERNAME
        user     = [string]$Context.UserName
        userSid  = [string]$Context.UserSid
        complete = $false
        restored = $null
    }
    if ($null -ne $Header) { foreach ($k in @($Header.Keys)) { $hdr[[string]$k] = $Header[$k] } }
    $Context.BackupFile = $Path
    $Context.BackupEntries = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $Context.BackupHeader = $hdr
    Save-LiteOSBackup $Context
    Write-LiteOSLog -NoConsole ('Backup file: {0}' -f $Path)
    return $true
}

function Add-LiteOSBackupEntry {
    param($Context, [string]$TweakId, $Action, [string]$Hive, $Before)
    if ([string]::IsNullOrEmpty($Context.BackupFile)) { return }
    $entry = [ordered]@{
        tweakId = $TweakId
        action  = $Action
        hive    = $Hive
        before  = $Before
        time    = (Get-Date).ToString('s')
    }
    $Context.BackupEntries.Add((ConvertTo-Json -InputObject $entry -Depth 100 -Compress))
    Save-LiteOSBackup $Context
}

function Close-LiteOSBackup {
    param($Context)
    if ([string]::IsNullOrEmpty($Context.BackupFile)) { return }
    $path = $Context.BackupFile
    try {
        if ($null -eq $Context.BackupEntries -or $Context.BackupEntries.Count -eq 0) {
            if (Test-Path -LiteralPath $path) { [System.IO.File]::Delete($path) }
            Write-LiteOSLog -NoConsole 'No changes were made, so the empty backup file was removed.'
            $Context.LastBackupFile = $null
        }
        else {
            $Context.BackupHeader['complete'] = $true
            $Context.BackupHeader['finished'] = (Get-Date).ToString('s')
            Save-LiteOSBackup $Context
            $Context.LastBackupFile = $path
            Write-LiteOSLog -NoConsole ('Backup saved: {0} ({1} entries)' -f $path, $Context.BackupEntries.Count)
        }
    }
    finally {
        $Context.BackupFile = $null
        $Context.BackupEntries = $null
        $Context.BackupHeader = $null
    }
}

# =============================================================================================
# Catalog loading and validation
# =============================================================================================

function Test-LiteOSScriptText {
    param([string]$Text)
    $errs = $null
    $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errs)
    if ($null -ne $errs -and @($errs).Count -gt 0) { return (@($errs)[0].Message) }
    return $null
}

function ConvertTo-LiteOSActionObject {
    param($Raw, [string]$Where, $Errors, $Warnings, [string[]]$Protected)
    if ($null -eq $Raw -or $Raw -is [string] -or $Raw -is [System.ValueType] -or $Raw -is [System.Array]) {
        $Errors.Add(('{0}: each action must be a JSON object' -f $Where)); return $null
    }
    $typeRaw = Get-LiteOSProp $Raw 'type'
    $type = Get-LiteOSCanonical $typeRaw $script:ActionTypes
    if ($null -eq $type) {
        $Errors.Add(("{0}: unknown action type '{1}' (expected one of: {2})" -f $Where, $typeRaw, ($script:ActionTypes -join ', ')))
        return $null
    }
    $Where = '{0} [{1}]' -f $Where, $type
    $before = $Errors.Count
    $o = [ordered]@{ type = $type }

    if ($type -eq 'registry' -or $type -eq 'registry-delete') {
        $pathRaw = Get-LiteOSProp $Raw 'path'
        $info = $null
        if ($pathRaw -is [string]) { $info = Resolve-LiteOSRegistryPath $pathRaw }
        if ($null -eq $info) {
            $Errors.Add(("{0}: bad registry path '{1}' (must start with HKLM:\ or HKCU:\)" -f $Where, $pathRaw))
        }
        else { $o['path'] = $info.Path }

        if ($type -eq 'registry') {
            $nameRaw = Get-LiteOSProp $Raw 'name'
            if ($null -eq $nameRaw) { $Errors.Add(('{0}: missing ''name'' (use "" for the default value)' -f $Where)) }
            else { $o['name'] = ConvertTo-LiteOSValueName ([string]$nameRaw) }
            $kindRaw = Get-LiteOSProp $Raw 'kind'
            $kind = Get-LiteOSCanonical $kindRaw $script:RegistryKinds
            if ($null -eq $kind) {
                $Errors.Add(("{0}: bad kind '{1}' (expected one of: {2})" -f $Where, $kindRaw, ($script:RegistryKinds -join ', ')))
            }
            else { $o['kind'] = $kind }
            if (-not (Test-LiteOSProp $Raw 'value')) {
                $Errors.Add(('{0}: missing ''value''' -f $Where))
            }
            else {
                $val = Get-LiteOSPropRaw $Raw 'value'
                if ($null -eq $val -and $kind -ne 'MultiString' -and $kind -ne 'String' -and $kind -ne 'ExpandString') {
                    $Errors.Add(('{0}: ''value'' must not be null' -f $Where))
                }
                elseif ($null -ne $kind) {
                    try { Test-LiteOSRegistryValueShape -Kind $kind -Value $val }
                    catch { $Errors.Add(("{0}: value is not valid for kind {1}: {2}" -f $Where, $kind, $_.Exception.Message)) }
                }
                $o['value'] = $val
            }
        }
        else {
            if (Test-LiteOSProp $Raw 'name') {
                $nameRaw = Get-LiteOSProp $Raw 'name'
                if ($null -ne $nameRaw) { $o['name'] = ConvertTo-LiteOSValueName ([string]$nameRaw) }
            }
            if (-not $o.Contains('name') -and $null -ne $info -and (Test-LiteOSCriticalKey $info.SubKey)) {
                $Errors.Add(("{0}: refusing to delete the whole key '{1}' (too broad / critical)" -f $Where, $info.Path))
            }
        }
    }
    elseif ($type -eq 'service') {
        $name = Get-LiteOSProp $Raw 'name'
        if (-not ($name -is [string]) -or [string]::IsNullOrWhiteSpace($name) -or $name.IndexOf('\') -ge 0) {
            $Errors.Add(('{0}: missing or bad service ''name''' -f $Where))
        }
        else { $o['name'] = $name.Trim() }
        $startRaw = Get-LiteOSProp $Raw 'startup'
        $startup = Get-LiteOSCanonical $startRaw $script:StartupTypes
        if ($null -eq $startup) {
            $Errors.Add(("{0}: bad startup '{1}' (expected one of: {2})" -f $Where, $startRaw, ($script:StartupTypes -join ', ')))
        }
        else { $o['startup'] = $startup }
        if (Test-LiteOSProp $Raw 'stop') {
            $stop = Get-LiteOSProp $Raw 'stop'
            if (-not ($stop -is [bool])) { $Errors.Add(('{0}: ''stop'' must be true or false' -f $Where)) }
            else { $o['stop'] = $stop }
        }
        else { $o['stop'] = $false }
    }
    elseif ($type -eq 'task') {
        $tp = Get-LiteOSProp $Raw 'path'
        if (-not ($tp -is [string]) -or [string]::IsNullOrWhiteSpace($tp)) { $Errors.Add(('{0}: missing task ''path''' -f $Where)) }
        else { $o['path'] = (ConvertTo-LiteOSTaskPath $tp) }
        $tn = Get-LiteOSProp $Raw 'name'
        if (-not ($tn -is [string]) -or [string]::IsNullOrWhiteSpace($tn)) { $Errors.Add(('{0}: missing task ''name''' -f $Where)) }
        else { $o['name'] = $tn.Trim() }
        $stRaw = Get-LiteOSProp $Raw 'state'
        $st = Get-LiteOSCanonical $stRaw $script:TaskStates
        if ($null -eq $st) { $Errors.Add(("{0}: bad task state '{1}' (expected Disabled or Enabled)" -f $Where, $stRaw)) }
        else { $o['state'] = $st }
    }
    elseif ($type -eq 'powershell') {
        $script = Get-LiteOSProp $Raw 'script'
        if (-not ($script -is [string]) -or [string]::IsNullOrWhiteSpace($script)) {
            $Errors.Add(('{0}: missing ''script''' -f $Where))
        }
        else {
            $perr = Test-LiteOSScriptText $script
            if ($perr) { $Errors.Add(('{0}: script does not parse: {1}' -f $Where, $perr)) }
            $o['script'] = $script
        }
        if (Test-LiteOSProp $Raw 'undo') {
            $undo = Get-LiteOSProp $Raw 'undo'
            if ($null -ne $undo) {
                if (-not ($undo -is [string])) { $Errors.Add(('{0}: ''undo'' must be a string' -f $Where)) }
                else {
                    $perr = Test-LiteOSScriptText $undo
                    if ($perr) { $Errors.Add(('{0}: undo does not parse: {1}' -f $Where, $perr)) }
                    $o['undo'] = $undo
                }
            }
        }
        if (Test-LiteOSProp $Raw 'perUser') {
            $pu = Get-LiteOSProp $Raw 'perUser'
            if (-not ($pu -is [bool])) { $Errors.Add(('{0}: ''perUser'' must be true or false' -f $Where)) }
            else { $o['perUser'] = $pu }
        }
    }
    elseif ($type -eq 'appx-remove') {
        $pk = @(Get-LiteOSProp $Raw 'packages' @())
        $clean = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($p in $pk) {
            if (-not ($p -is [string]) -or [string]::IsNullOrWhiteSpace($p)) { $Errors.Add(('{0}: ''packages'' must contain non-empty strings' -f $Where)); continue }
            $p = $p.Trim()
            $c = Get-LiteOSProtectedConflict -Pattern $p -Protected $Protected
            if ($null -ne $c.Blocked) {
                $Warnings.Add(("{0}: package '{1}' is protected ({2}) and will never be removed" -f $Where, $p, $c.Blocked))
            }
            elseif ($c.Overlap.Length -gt 0) {
                $Warnings.Add(("{0}: pattern '{1}' also matches protected packages ({2}); those are skipped" -f $Where, $p, ($c.Overlap -join ', ')))
            }
            $clean.Add($p)
        }
        if ($clean.Count -eq 0) { $Errors.Add(('{0}: ''packages'' must be a non-empty array' -f $Where)) }
        $o['packages'] = $clean.ToArray()
    }

    if ($Errors.Count -gt $before) { return $null }
    return [pscustomobject]$o
}

function Test-LiteOSRegistryValueShape {
    param([string]$Kind, $Value)
    switch ($Kind) {
        'DWord'  { $null = ConvertTo-LiteOSDWord $Value }
        'QWord'  { $null = ConvertTo-LiteOSQWord $Value }
        'Binary' { $null = ConvertFrom-LiteOSHex $Value }
        'MultiString' {
            foreach ($x in @($Value)) {
                if ($null -ne $x -and -not ($x -is [string]) -and -not ($x -is [System.ValueType])) { throw 'MultiString values must be strings' }
            }
        }
        default {
            if ($null -ne $Value -and -not ($Value -is [string]) -and -not ($Value -is [System.ValueType])) { throw 'value must be a string' }
        }
    }
}

function ConvertTo-LiteOSTaskPath {
    param([string]$Path)
    $p = $Path.Trim()
    if (-not $p.StartsWith('\')) { $p = '\' + $p }
    if (-not $p.EndsWith('\')) { $p = $p + '\' }
    return $p
}

function ConvertTo-LiteOSTweakObject {
    param($Raw, [string]$Category, [string]$CategoryTitle, [string]$Source, [string]$Where, $Errors, $Warnings, [string[]]$Protected)
    if ($null -eq $Raw -or $Raw -is [string] -or $Raw -is [System.ValueType] -or $Raw -is [System.Array]) {
        $Errors.Add(('{0}: each tweak must be a JSON object' -f $Where)); return $null
    }
    $id = Get-LiteOSProp $Raw 'id'
    if (-not ($id -is [string]) -or [string]::IsNullOrWhiteSpace($id)) {
        $Errors.Add(('{0}: missing ''id''' -f $Where)); return $null
    }
    $id = $id.Trim()
    $Where = '{0} ({1})' -f $Where, $id
    $before = $Errors.Count

    if ($id -match '\s') { $Errors.Add(('{0}: id must not contain spaces' -f $Where)) }
    elseif ($id -cnotmatch '^[a-z0-9][a-z0-9.\-]*$') { $Warnings.Add(('{0}: id should be lower-case <category>.<kebab-name>' -f $Where)) }
    elseif (-not $id.StartsWith($Category + '.', [System.StringComparison]::OrdinalIgnoreCase)) {
        $Warnings.Add(("{0}: id should start with '{1}.'" -f $Where, $Category))
    }

    $name = Get-LiteOSProp $Raw 'name'
    if (-not ($name -is [string]) -or [string]::IsNullOrWhiteSpace($name)) { $Errors.Add(('{0}: missing ''name''' -f $Where)); $name = $id }

    $desc = Get-LiteOSProp $Raw 'description' ''
    if (-not ($desc -is [string])) { $Errors.Add(('{0}: ''description'' must be a string' -f $Where)); $desc = '' }

    $levelRaw = Get-LiteOSProp $Raw 'level'
    $level = Get-LiteOSCanonical $levelRaw $script:Levels
    if ($null -eq $level) { $Errors.Add(("{0}: bad level '{1}' (expected balanced or extreme)" -f $Where, $levelRaw)) }
    elseif ($level -eq 'extreme' -and [string]::IsNullOrWhiteSpace($desc)) { $Warnings.Add(('{0}: extreme tweaks must explain their downside in ''description''' -f $Where)) }

    $default = Get-LiteOSProp $Raw 'default'
    if (-not ($default -is [bool])) { $Errors.Add(('{0}: ''default'' must be true or false' -f $Where)); $default = $false }

    $risk = 'low'
    if (Test-LiteOSProp $Raw 'risk') {
        $riskRaw = Get-LiteOSProp $Raw 'risk'
        $r = Get-LiteOSCanonical $riskRaw $script:Risks
        if ($null -eq $r) { $Errors.Add(("{0}: bad risk '{1}' (expected none, low, medium or high)" -f $Where, $riskRaw)) } else { $risk = $r }
    }

    $reboot = $false
    if (Test-LiteOSProp $Raw 'reboot') {
        $rb = Get-LiteOSProp $Raw 'reboot'
        if (-not ($rb -is [bool])) { $Errors.Add(('{0}: ''reboot'' must be true or false' -f $Where)) } else { $reboot = $rb }
    }

    $minBuild = $null
    $maxBuild = $null
    foreach ($bn in @('minBuild', 'maxBuild')) {
        if (Test-LiteOSProp $Raw $bn) {
            $bv = Get-LiteOSProp $Raw $bn
            if ($null -ne $bv) {
                $ok = $true
                $iv = 0
                try { $iv = [int](ConvertTo-LiteOSDecimal $bv) } catch { $ok = $false }
                if (-not $ok -or $iv -lt 0) { $Errors.Add(("{0}: '{1}' must be a whole number" -f $Where, $bn)) }
                elseif ($bn -eq 'minBuild') { $minBuild = $iv } else { $maxBuild = $iv }
            }
        }
    }

    $actionsRaw = @(Get-LiteOSProp $Raw 'actions' @())
    $actions = New-Object -TypeName 'System.Collections.Generic.List[object]'
    if ($actionsRaw.Count -eq 0) { $Errors.Add(('{0}: ''actions'' must be a non-empty array' -f $Where)) }
    $ai = 0
    foreach ($a in $actionsRaw) {
        $ai++
        $act = ConvertTo-LiteOSActionObject -Raw $a -Where ('{0} action #{1}' -f $Where, $ai) -Errors $Errors -Warnings $Warnings -Protected $Protected
        if ($null -ne $act) { $actions.Add($act) }
    }

    if ($Errors.Count -gt $before) { return $null }
    return [pscustomobject]@{
        id            = $id
        name          = $name.Trim()
        description   = $desc
        level         = $level
        default       = $default
        risk          = $risk
        reboot        = $reboot
        minBuild      = $minBuild
        maxBuild      = $maxBuild
        actions       = $actions.ToArray()
        category      = $Category
        categoryTitle = $CategoryTitle
        source        = $Source
    }
}

function ConvertFrom-LiteOSAppsRemove {
    # tweaks/apps-remove.json -> synthetic tweaks apps.remove.<match-lowercased> (category 'apps')
    param($Json, [string]$Source, $Errors, $Warnings, [string[]]$Protected)
    $out = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $title = [string](Get-LiteOSProp $Json 'title' 'Remove preinstalled apps')
    if (-not (Test-LiteOSProp $Json 'packages')) { $Errors.Add(('{0}: missing ''packages'' array' -f $Source)); return , ($out.ToArray()) }
    $i = 0
    foreach ($pkg in @(Get-LiteOSProp $Json 'packages' @())) {
        $i++
        $where = '{0} package #{1}' -f $Source, $i
        if ($null -eq $pkg -or $pkg -is [string] -or $pkg -is [System.ValueType]) { $Errors.Add(('{0}: each package must be a JSON object' -f $where)); continue }
        $match = Get-LiteOSProp $pkg 'match'
        if (-not ($match -is [string]) -or [string]::IsNullOrWhiteSpace($match)) { $Errors.Add(('{0}: missing ''match''' -f $where)); continue }
        $match = $match.Trim()
        $where = '{0} ({1})' -f $where, $match
        $before = $Errors.Count
        $name = Get-LiteOSProp $pkg 'name'
        if (-not ($name -is [string]) -or [string]::IsNullOrWhiteSpace($name)) { $name = $match }
        $levelRaw = Get-LiteOSProp $pkg 'level'
        $level = Get-LiteOSCanonical $levelRaw $script:Levels
        if ($null -eq $level) { $Errors.Add(("{0}: bad level '{1}' (expected balanced or extreme)" -f $where, $levelRaw)) }
        $default = Get-LiteOSProp $pkg 'default'
        if (-not ($default -is [bool])) { $Errors.Add(('{0}: ''default'' must be true or false' -f $where)); $default = $false }
        $risk = 'low'
        if (Test-LiteOSProp $pkg 'risk') {
            $r = Get-LiteOSCanonical (Get-LiteOSProp $pkg 'risk') $script:Risks
            if ($null -eq $r) { $Errors.Add(("{0}: bad risk '{1}'" -f $where, (Get-LiteOSProp $pkg 'risk'))) } else { $risk = $r }
        }
        if ($Errors.Count -gt $before) { continue }

        $c = Get-LiteOSProtectedConflict -Pattern $match -Protected $Protected
        if ($null -ne $c.Blocked) {
            $Warnings.Add(("{0}: '{1}' is protected ({2}); this entry is ignored" -f $where, $match, $c.Blocked))
            continue
        }
        if ($c.Overlap.Length -gt 0) {
            $Warnings.Add(("{0}: pattern '{1}' also matches protected packages ({2}); those are skipped" -f $where, $match, ($c.Overlap -join ', ')))
        }
        $desc = Get-LiteOSProp $pkg 'description'
        if (-not ($desc -is [string]) -or [string]::IsNullOrWhiteSpace($desc)) {
            $desc = ('Uninstalls {0} for all users and removes it from the Windows image so new accounts do not get it. You can reinstall it any time from the Microsoft Store or with winget.' -f $name)
        }
        $minBuild = $null
        $maxBuild = $null
        if ($null -ne (Get-LiteOSProp $pkg 'minBuild')) { try { $minBuild = [int](ConvertTo-LiteOSDecimal (Get-LiteOSProp $pkg 'minBuild')) } catch { $Errors.Add(('{0}: bad minBuild' -f $where)) } }
        if ($null -ne (Get-LiteOSProp $pkg 'maxBuild')) { try { $maxBuild = [int](ConvertTo-LiteOSDecimal (Get-LiteOSProp $pkg 'maxBuild')) } catch { $Errors.Add(('{0}: bad maxBuild' -f $where)) } }
        $action = [pscustomobject]([ordered]@{ type = 'appx-remove'; packages = @($match) })
        $out.Add([pscustomobject]@{
                id            = ('apps.remove.' + $match.ToLowerInvariant())
                name          = ('Remove ' + $name.Trim())
                description   = $desc
                level         = $level
                default       = $default
                risk          = $risk
                reboot        = $false
                minBuild      = $minBuild
                maxBuild      = $maxBuild
                actions       = @($action)
                category      = 'apps'
                categoryTitle = $title
                source        = $Source
                match         = $match
            })
    }
    return , ($out.ToArray())
}

function Get-LiteOSCatalog {
    <#
    .SYNOPSIS
        Loads and validates the tweak catalog. Returns tweak objects with .category added.
    .DESCRIPTION
        Reads every tweaks/*.json (except apps-install.json). apps-remove.json entries become
        synthetic tweaks 'apps.remove.<match-lowercased>' (category 'apps', action appx-remove);
        entries matching the protected list are dropped. Throws one error listing every schema
        problem (unknown action type, bad kind, duplicate id, bad level, ...).
    .PARAMETER Path
        A tweaks folder, or one or more JSON files. Default: <repo>\tweaks.
    #>
    [CmdletBinding()]
    param([string[]]$Path)
    if ($null -eq $Path -or @($Path).Count -eq 0) { $Path = @(Get-LiteOSDefaultTweaksPath) }

    $files = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($p in $Path) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (Test-Path -LiteralPath $p -PathType Container) {
            foreach ($f in @(Get-ChildItem -LiteralPath $p -Filter '*.json' -File)) { $files.Add($f.FullName) }
        }
        elseif (Test-Path -LiteralPath $p -PathType Leaf) {
            $files.Add((Resolve-Path -LiteralPath $p).ProviderPath)
        }
        else {
            throw ('Lite OS catalog path not found: {0}' -f $p)
        }
    }

    $selected = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($f in $files) {
        $leaf = [System.IO.Path]::GetFileName($f)
        if ($leaf -eq 'apps-install.json') { continue }
        if (-not $selected.Contains($f)) { $selected.Add($f) }
    }
    $order = $script:CategoryOrder
    $sorted = @($selected | Sort-Object -Property @{ Expression = {
                $b = [System.IO.Path]::GetFileNameWithoutExtension($_).ToLowerInvariant()
                if ($b -eq 'apps-remove') { $b = 'apps' }
                $ix = [array]::IndexOf($order, $b)
                if ($ix -lt 0) { $ix = 100 }
                $ix
            }
        }, @{ Expression = { [System.IO.Path]::GetFileName($_).ToLowerInvariant() } })

    $errors = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $warnings = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $tweaks = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $ids = @{}

    # Protected list: built-in + apps-remove.json next to the files being loaded.
    $appsRemove = $null
    foreach ($f in $sorted) { if ([System.IO.Path]::GetFileName($f) -eq 'apps-remove.json') { $appsRemove = $f } }
    if ($null -eq $appsRemove) {
        $dirs = @($sorted | ForEach-Object { [System.IO.Path]::GetDirectoryName($_) } | Select-Object -Unique)
        foreach ($d in $dirs) { $cand = Join-Path $d 'apps-remove.json'; if (Test-Path -LiteralPath $cand) { $appsRemove = $cand; break } }
    }
    $protected = @(Get-LiteOSProtectedApps -Path $appsRemove)

    foreach ($file in $sorted) {
        $leaf = [System.IO.Path]::GetFileName($file)
        $json = $null
        try { $json = Read-LiteOSJsonFile $file }
        catch { $errors.Add($_.Exception.Message); continue }

        $fileTweaks = @()
        if ($leaf -eq 'apps-remove.json') {
            # The function returns one array object; assign it directly (no @() wrapper).
            $fileTweaks = ConvertFrom-LiteOSAppsRemove -Json $json -Source $leaf -Errors $errors -Warnings $warnings -Protected $protected
        }
        else {
            $cat = Get-LiteOSProp $json 'category'
            if (-not ($cat -is [string]) -or [string]::IsNullOrWhiteSpace($cat)) {
                $errors.Add(('{0}: missing ''category''' -f $leaf)); continue
            }
            $cat = $cat.Trim()
            $title = Get-LiteOSProp $json 'title' $cat
            if (-not ($title -is [string]) -or [string]::IsNullOrWhiteSpace($title)) { $title = $cat }
            if (-not (Test-LiteOSProp $json 'tweaks')) { $errors.Add(('{0}: missing ''tweaks'' array' -f $leaf)); continue }
            $list = New-Object -TypeName 'System.Collections.Generic.List[object]'
            $i = 0
            foreach ($raw in @(Get-LiteOSProp $json 'tweaks' @())) {
                $i++
                $rawId = Get-LiteOSProp $raw 'id'
                if ($rawId -is [string] -and $rawId.Trim().Length -gt 0) {
                    $rawId = $rawId.Trim()
                    if ($ids.ContainsKey($rawId)) {
                        $errors.Add(("duplicate tweak id '{0}' in {1} tweak #{2} (first defined in {3})" -f $rawId, $leaf, $i, $ids[$rawId]))
                        continue
                    }
                    $ids[$rawId] = $leaf
                }
                $t = ConvertTo-LiteOSTweakObject -Raw $raw -Category $cat -CategoryTitle $title -Source $leaf -Where ('{0} tweak #{1}' -f $leaf, $i) -Errors $errors -Warnings $warnings -Protected $protected
                if ($null -ne $t) { $list.Add($t) }
            }
            $fileTweaks = $list.ToArray()
        }
        foreach ($t in @($fileTweaks)) {
            if ($null -eq $t) { continue }
            if ($leaf -eq 'apps-remove.json') {
                if ($ids.ContainsKey($t.id)) {
                    $errors.Add(("duplicate tweak id '{0}' in {1} (first defined in {2})" -f $t.id, $leaf, $ids[$t.id]))
                    continue
                }
                $ids[$t.id] = $leaf
            }
            $tweaks.Add($t)
        }
    }

    foreach ($w in $warnings) { Write-LiteOSLog -Level Warn ('catalog: ' + $w) }
    if ($errors.Count -gt 0) {
        $msg = 'Lite OS catalog has {0} error(s):{1} - {2}' -f $errors.Count, [Environment]::NewLine, ($errors -join ([Environment]::NewLine + ' - '))
        Write-LiteOSLog -NoConsole -Level Error $msg
        throw $msg
    }
    Write-LiteOSLog -NoConsole ('Catalog loaded: {0} tweaks from {1} file(s)' -f $tweaks.Count, $sorted.Count)
    return $tweaks.ToArray()
}

# =============================================================================================
# Selection (pure)
# =============================================================================================

function Select-LiteOSTweaks {
    <#
    .SYNOPSIS
        Pure function: picks tweaks for a level, plus -Include, minus -Exclude, filtered by -Build.
    .DESCRIPTION
        Balanced = balanced tweaks with default:true. Extreme = Balanced + extreme tweaks with
        default:true. None = nothing except -Include. -Include / -Exclude accept exact ids,
        wildcards (privacy.*) and comma separated strings; -Exclude wins over -Include.
        -Build > 0 drops tweaks outside minBuild/maxBuild (also included ones). Catalog order is kept.
        No system access.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Catalog,

        [ValidateSet('Balanced', 'Extreme', 'None')]
        [string]$Level = 'Balanced',

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Include = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Exclude = @(),

        [int]$Build = 0
    )
    $inc = Split-LiteOSList $Include
    $exc = Split-LiteOSList $Exclude
    foreach ($t in @($Catalog)) {
        if ($null -eq $t) { continue }
        $id = [string](Get-LiteOSProp $t 'id' '')
        if ([string]::IsNullOrEmpty($id)) { continue }
        $lvl = ([string](Get-LiteOSProp $t 'level' '')).Trim().ToLowerInvariant()
        $def = ConvertTo-LiteOSBool (Get-LiteOSProp $t 'default' $false)
        $picked = $false
        if ($Level -eq 'Balanced') { $picked = ($def -and $lvl -eq 'balanced') }
        elseif ($Level -eq 'Extreme') { $picked = ($def -and ($lvl -eq 'balanced' -or $lvl -eq 'extreme')) }
        if (-not $picked -and $inc.Length -gt 0) { $picked = Test-LiteOSIdMatch -Id $id -Patterns $inc }
        if (-not $picked) { continue }
        if ($exc.Length -gt 0 -and (Test-LiteOSIdMatch -Id $id -Patterns $exc)) { continue }
        if ($Build -gt 0 -and -not (Test-LiteOSBuildRange -Tweak $t -Build $Build)) { continue }
        $t
    }
}

# =============================================================================================
# Action handlers (apply). Each returns one or more outcome objects.
# =============================================================================================

function Invoke-LiteOSRegistryAction {
    param($Context, [string]$TweakId, $Action, [string]$Hive, [bool]$DryRun)
    $target = Get-LiteOSRegistryTarget -Path ([string]$Action.path) -Hive $Hive
    if (-not (Test-LiteOSRegistryPrefix $target)) { return (ConvertTo-LiteOSOutcome 'skipped' ('[{0}] hive not loaded' -f $Hive)) }
    $name = [string](Get-LiteOSProp $Action 'name' '')
    $kind = [string]$Action.kind
    $value = Get-LiteOSPropRaw $Action 'value'
    $label = '[{0}] {1}\{2}' -f $Hive, $target.Display, $(if ($name -eq '') { '(Default)' } else { $name })
    $shown = Format-LiteOSRegistryValue $kind $value
    $state = Get-LiteOSRegistryValueState -Target $target -Name $name
    if ($state.Exists -and $state.Kind -eq $kind -and (Test-LiteOSRegistryDataEqual $kind $state.Value $value)) {
        return (ConvertTo-LiteOSOutcome 'unchanged' ('{0} already {1}' -f $label, $shown))
    }
    $was = '(absent)'
    if ($state.Exists) { $was = '{0} ({1})' -f (Format-LiteOSRegistryValue $state.Kind $state.Value), $state.Kind }
    if ($DryRun) { return (ConvertTo-LiteOSOutcome 'applied' ('WhatIf: would set {0} = {1} ({2}); now {3}' -f $label, $shown, $kind, $was)) }

    $created = Get-LiteOSMissingKeys $target
    $stored = $null
    if ($state.Exists) { $stored = (ConvertTo-LiteOSStoredValue $state.Kind $state.Value).Value }
    $before = [ordered]@{
        exists      = [bool]$state.Exists
        kind        = $state.Kind
        value       = $stored
        createdKeys = @($created)
        target      = $target.Display
    }
    Add-LiteOSBackupEntry -Context $Context -TweakId $TweakId -Action $Action -Hive $Hive -Before $before
    Write-LiteOSRegistryValue -Target $target -Name $name -Kind $kind -Value $value
    return (ConvertTo-LiteOSOutcome 'applied' ('{0} = {1} ({2}); was {3}' -f $label, $shown, $kind, $was))
}

function Invoke-LiteOSRegistryDeleteAction {
    param($Context, [string]$TweakId, $Action, [string]$Hive, [bool]$DryRun)
    $target = Get-LiteOSRegistryTarget -Path ([string]$Action.path) -Hive $Hive
    if (-not (Test-LiteOSRegistryPrefix $target)) { return (ConvertTo-LiteOSOutcome 'skipped' ('[{0}] hive not loaded' -f $Hive)) }
    if (Test-LiteOSProp $Action 'name') {
        $name = [string]$Action.name
        $label = '[{0}] {1}\{2}' -f $Hive, $target.Display, $(if ($name -eq '') { '(Default)' } else { $name })
        $state = Get-LiteOSRegistryValueState -Target $target -Name $name
        if (-not $state.Exists) { return (ConvertTo-LiteOSOutcome 'unchanged' ('{0} already absent' -f $label)) }
        if ($DryRun) { return (ConvertTo-LiteOSOutcome 'applied' ('WhatIf: would delete value {0}' -f $label)) }
        $before = [ordered]@{
            exists = $true
            kind   = $state.Kind
            value  = (ConvertTo-LiteOSStoredValue $state.Kind $state.Value).Value
            target = $target.Display
        }
        Add-LiteOSBackupEntry -Context $Context -TweakId $TweakId -Action $Action -Hive $Hive -Before $before
        [void](Clear-LiteOSRegistryValue -Target $target -Name $name)
        return (ConvertTo-LiteOSOutcome 'applied' ('deleted value {0}' -f $label))
    }

    if (Test-LiteOSCriticalKey $target.Logical) { throw ('refusing to delete critical key {0}' -f $target.Display) }
    $label = '[{0}] {1}' -f $Hive, $target.Display
    $base = Open-LiteOSBaseKey $target.BaseHive
    try {
        $key = $base.OpenSubKey($target.SubKey, $false)
        if ($null -eq $key) { return (ConvertTo-LiteOSOutcome 'unchanged' ('{0} already absent' -f $label)) }
        $tree = $null
        try {
            if ($DryRun) { return (ConvertTo-LiteOSOutcome 'applied' ('WhatIf: would delete key {0} ({1} values, {2} sub keys)' -f $label, $key.ValueCount, $key.SubKeyCount)) }
            $tree = Export-LiteOSRegistryTree -Key $key
        }
        finally { $key.Close() }
        $before = [ordered]@{ existed = $true; tree = $tree; target = $target.Display }
        Add-LiteOSBackupEntry -Context $Context -TweakId $TweakId -Action $Action -Hive $Hive -Before $before
        $base.DeleteSubKeyTree($target.SubKey, $false)
    }
    finally { $base.Close() }
    return (ConvertTo-LiteOSOutcome 'applied' ('deleted key {0}' -f $label))
}

function Get-LiteOSServiceConfig {
    param([string]$Name)
    $base = Open-LiteOSBaseKey ([Microsoft.Win32.RegistryHive]::LocalMachine)
    try {
        $k = $base.OpenSubKey(('SYSTEM\CurrentControlSet\Services\{0}' -f $Name), $false)
        if ($null -eq $k) { return $null }
        try {
            $start = $k.GetValue('Start', $null)
            if ($null -eq $start) { return $null }
            $delayedRaw = $k.GetValue('DelayedAutostart', $null)
            $delayed = $null
            if ($null -ne $delayedRaw) { $delayed = [int]$delayedRaw }
            return [pscustomobject]@{ Name = $Name; Start = [int]$start; Delayed = $delayed }
        }
        finally { $k.Close() }
    }
    finally { $base.Close() }
}

function Get-LiteOSStartupName {
    param([int]$Start, $Delayed)
    switch ($Start) {
        0 { return 'Boot' }
        1 { return 'System' }
        2 { if ($null -ne $Delayed -and [int]$Delayed -eq 1) { return 'AutomaticDelayed' } else { return 'Automatic' } }
        3 { return 'Manual' }
        4 { return 'Disabled' }
    }
    return ('Unknown({0})' -f $Start)
}

function Get-LiteOSStartupSpec {
    param([string]$Startup)
    switch ($Startup) {
        'Disabled'         { return [pscustomobject]@{ Start = 4; Delayed = $null } }
        'Manual'           { return [pscustomobject]@{ Start = 3; Delayed = $null } }
        'Automatic'        { return [pscustomobject]@{ Start = 2; Delayed = 0 } }
        'AutomaticDelayed' { return [pscustomobject]@{ Start = 2; Delayed = 1 } }
    }
    throw ("bad startup '{0}'" -f $Startup)
}

function Test-LiteOSServiceConfigMatch {
    param($Config, [int]$Start, $Delayed)
    if ($null -eq $Config) { return $false }
    if ($Config.Start -ne $Start) { return $false }
    if ($Start -ne 2) { return $true }
    $cur = ($null -ne $Config.Delayed -and [int]$Config.Delayed -eq 1)
    $want = ($null -ne $Delayed -and [int]$Delayed -eq 1)
    return ($cur -eq $want)
}

function Invoke-LiteOSServiceConfig {
    # Sets start type via sc.exe (immediate), verifies, falls back to the registry (after restart).
    # With -ExactDelayed, a $null Delayed removes the DelayedAutostart value (used by restore).
    param([string]$Name, [int]$Start, $Delayed, [switch]$ExactDelayed)
    $mode = 'demand'
    switch ($Start) {
        0 { $mode = 'boot' }
        1 { $mode = 'system' }
        2 { if ($null -ne $Delayed -and [int]$Delayed -eq 1) { $mode = 'delayed-auto' } else { $mode = 'auto' } }
        3 { $mode = 'demand' }
        4 { $mode = 'disabled' }
    }
    $sc = Invoke-LiteOSNative -FilePath (Get-LiteOSSystemExe 'sc.exe') -ArgumentList @('config', $Name, 'start=', $mode)
    $cfg = Get-LiteOSServiceConfig $Name
    $needDelayedFix = $false
    if ($ExactDelayed -and $null -ne $cfg) {
        if ($null -eq $Delayed -and $null -ne $cfg.Delayed) { $needDelayedFix = $true }
        elseif ($null -ne $Delayed -and ($null -eq $cfg.Delayed -or [int]$cfg.Delayed -ne [int]$Delayed)) { $needDelayedFix = $true }
    }
    if ($sc.ExitCode -eq 0 -and (Test-LiteOSServiceConfigMatch $cfg $Start $Delayed) -and -not $needDelayedFix) {
        return [pscustomobject]@{ UsedRegistry = $false; Message = ('sc.exe start= {0}' -f $mode) }
    }
    # Registry fallback (per-user service templates, services the SCM refuses to reconfigure).
    $base = Open-LiteOSBaseKey ([Microsoft.Win32.RegistryHive]::LocalMachine)
    try {
        $k = $base.OpenSubKey(('SYSTEM\CurrentControlSet\Services\{0}' -f $Name), $true)
        if ($null -eq $k) { throw ('service key for {0} not found' -f $Name) }
        try {
            $k.SetValue('Start', [int32]$Start, [Microsoft.Win32.RegistryValueKind]::DWord)
            if ($null -ne $Delayed) {
                if ($Start -eq 2 -or $ExactDelayed) { $k.SetValue('DelayedAutostart', [int32]$Delayed, [Microsoft.Win32.RegistryValueKind]::DWord) }
            }
            elseif ($ExactDelayed) {
                $k.DeleteValue('DelayedAutostart', $false)
            }
        }
        finally { $k.Close() }
    }
    catch {
        throw ('could not change service {0}: sc.exe exit {1} ({2}); registry: {3}' -f $Name, $sc.ExitCode, (Format-LiteOSShort $sc.Output 100), $_.Exception.Message)
    }
    finally { $base.Close() }
    return [pscustomobject]@{ UsedRegistry = $true; Message = ('set in the registry (sc.exe exit {0}); takes effect after restart' -f $sc.ExitCode) }
}

function Invoke-LiteOSServiceAction {
    param($Context, [string]$TweakId, $Action, [bool]$DryRun)
    $name = [string]$Action.name
    $startup = [string]$Action.startup
    $stop = ConvertTo-LiteOSBool (Get-LiteOSProp $Action 'stop' $false)
    $cfg = Get-LiteOSServiceConfig $name
    if ($null -eq $cfg) { return (ConvertTo-LiteOSOutcome 'skipped' ('service {0} not found' -f $name)) }
    $spec = Get-LiteOSStartupSpec $startup
    $current = Get-LiteOSStartupName $cfg.Start $cfg.Delayed
    $status = ''
    try {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $svc) { $status = [string]$svc.Status }
    }
    catch { $status = '' }
    $match = Test-LiteOSServiceConfigMatch $cfg $spec.Start $spec.Delayed
    $needStop = $stop -and ($spec.Start -ge 3) -and ($status -eq 'Running' -or $status -eq 'StartPending')
    if ($match -and -not $needStop) {
        return (ConvertTo-LiteOSOutcome 'unchanged' ('service {0} already {1}' -f $name, $startup))
    }
    if ($DryRun) {
        $m = 'WhatIf: would set service {0} startup {1} (now {2})' -f $name, $startup, $current
        if ($needStop) { $m += ' and stop it' }
        return (ConvertTo-LiteOSOutcome 'applied' $m)
    }
    $msg = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $reboot = $false
    $before = [ordered]@{ start = $cfg.Start; delayed = $cfg.Delayed; startType = $current; status = $status }
    if ($match) {
        # Start type already right, only the running service is stopped: still record it, so a
        # revert starts it again (Restore-LiteOSEntry restarts services whose status was Running).
        $before['stopOnly'] = $true
        Add-LiteOSBackupEntry -Context $Context -TweakId $TweakId -Action $Action -Hive 'Machine' -Before $before
    }
    else {
        Add-LiteOSBackupEntry -Context $Context -TweakId $TweakId -Action $Action -Hive 'Machine' -Before $before
        $r = Invoke-LiteOSServiceConfig -Name $name -Start $spec.Start -Delayed $spec.Delayed
        $msg.Add(('service {0}: {1} -> {2} ({3})' -f $name, $current, $startup, $r.Message))
        if ($r.UsedRegistry) { $reboot = $true }
    }
    if ($needStop) {
        try {
            Stop-Service -Name $name -Force -NoWait -ErrorAction Stop -WarningAction SilentlyContinue
            $msg.Add(('stop requested for {0}' -f $name))
        }
        catch {
            $msg.Add(('{0} could not be stopped now ({1}); it will not start after a restart' -f $name, (Format-LiteOSShort $_.Exception.Message 80)))
            $reboot = $true
        }
    }
    return (ConvertTo-LiteOSOutcome 'applied' ($msg -join '; ') $reboot)
}

function Get-LiteOSTasks {
    param([string]$TaskPath, [string]$TaskName)
    # Emits matching tasks (unrolled; wrap the call in @()).
    try { Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue } catch { $null = $_ }
}

function Invoke-LiteOSTaskAction {
    param($Context, [string]$TweakId, $Action, [bool]$DryRun)
    $tp = ConvertTo-LiteOSTaskPath ([string]$Action.path)
    $tn = [string]$Action.name
    $want = [string]$Action.state
    $tasks = @(Get-LiteOSTasks -TaskPath $tp -TaskName $tn)
    if ($tasks.Count -eq 0) { return (ConvertTo-LiteOSOutcome 'skipped' ('task {0}{1} not found' -f $tp, $tn)) }
    foreach ($t in $tasks) {
        $full = '{0}{1}' -f $t.TaskPath, $t.TaskName
        $cur = 'Enabled'
        if ([string]$t.State -eq 'Disabled') { $cur = 'Disabled' }
        if ($cur -eq $want) { ConvertTo-LiteOSOutcome 'unchanged' ('task {0} already {1}' -f $full, $want); continue }
        if ($DryRun) { ConvertTo-LiteOSOutcome 'applied' ('WhatIf: would set task {0} {1}' -f $full, $want); continue }
        try {
            $before = [ordered]@{ taskPath = [string]$t.TaskPath; taskName = [string]$t.TaskName; state = $cur }
            Add-LiteOSBackupEntry -Context $Context -TweakId $TweakId -Action $Action -Hive 'Machine' -Before $before
            if ($want -eq 'Disabled') {
                $null = Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop
            }
            else {
                $null = Enable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop
            }
            ConvertTo-LiteOSOutcome 'applied' ('task {0}: {1} -> {2}' -f $full, $cur, $want)
        }
        catch {
            ConvertTo-LiteOSOutcome 'failed' ('task {0}: {1}' -f $full, (Format-LiteOSShort $_.Exception.Message 140))
        }
    }
}

function Invoke-LiteOSScriptText {
    # Runs a tweak script in a child scope, StrictMode off, errors terminate. $Variables are
    # defined as string variables before the script (e.g. LiteOSUserRoot, LiteOSHiveTag).
    # Returns Output (shortened, one line), Raw (full text) and the last native ExitCode.
    param([string]$Text, [System.Collections.IDictionary]$Variables)
    $pre = New-Object -TypeName System.Text.StringBuilder
    [void]$pre.Append("Set-StrictMode -Off`r`n`$ErrorActionPreference = 'Stop'`r`n")
    if ($null -ne $Variables) {
        foreach ($k in @($Variables.Keys)) {
            $name = [string]$k
            if ($name -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { throw ("bad script variable name '{0}'" -f $name) }
            $val = ([string]$Variables[$k]).Replace("'", "''")
            [void]$pre.Append(('${0} = ''{1}''' -f $name, $val)).Append("`r`n")
        }
    }
    $sb = [scriptblock]::Create($pre.ToString() + $Text)
    Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
    $out = (& $sb | Out-String)
    $code = 0
    try { $code = [int](Get-Variable -Name LASTEXITCODE -Scope Global -ValueOnly -ErrorAction Stop) } catch { $code = 0 }
    return [pscustomobject]@{ Output = (Format-LiteOSShort $out 300); Raw = [string]$out; ExitCode = $code }
}

function Get-LiteOSScriptVerdict {
    # Script output convention: a line starting with "SKIPPED:" (not applicable on this PC) or
    # "UNCHANGED:" (already in the wanted state) means the script changed NOTHING.
    # Returns {Status = skipped|unchanged; Message} or $null for a normal (applied) run.
    param([string]$Output)
    if ([string]::IsNullOrEmpty($Output)) { return $null }
    $m = [regex]::Match($Output, '(?m)^[ \t]*(SKIPPED|UNCHANGED):[ \t]*([^\r\n]*)')
    if (-not $m.Success) { return $null }
    $status = 'skipped'
    if ($m.Groups[1].Value -eq 'UNCHANGED') { $status = 'unchanged' }
    $msg = $m.Groups[2].Value.Trim()
    if (-not $msg) { $msg = $status }
    return [pscustomobject]@{ Status = $status; Message = (Format-LiteOSShort $msg 300) }
}

function Get-LiteOSScriptHive {
    # What a script sees for the hive it runs against:
    #   Root   -> $LiteOSUserRoot, the registry root to use instead of HKCU:
    #   Tag    -> $LiteOSHiveTag, a file-name-safe tag (user SID or 'Default') for per-hive state files
    #   Loaded -> $false when the hive of another user is not loaded (revert by a different admin)
    param([string]$Hive, [string]$UserSid)
    if ($Hive -eq 'Default') {
        return [pscustomobject]@{ Root = ('Registry::HKEY_USERS\' + $script:DefaultHiveName); Tag = 'Default'; Loaded = $true }
    }
    $current = Get-LiteOSCurrentSid
    if ($Hive -eq 'User' -and -not [string]::IsNullOrEmpty($UserSid) -and $UserSid -ne $current) {
        $loaded = $false
        $users = Open-LiteOSBaseKey ([Microsoft.Win32.RegistryHive]::Users)
        try {
            $k = $users.OpenSubKey($UserSid, $false)
            if ($null -ne $k) { $k.Close(); $loaded = $true }
        }
        finally { $users.Close() }
        return [pscustomobject]@{ Root = ('Registry::HKEY_USERS\' + $UserSid); Tag = $UserSid; Loaded = $loaded }
    }
    $tag = $current
    if ([string]::IsNullOrEmpty($tag)) { $tag = 'User' }
    return [pscustomobject]@{ Root = 'HKCU:'; Tag = $tag; Loaded = $true }
}

function Invoke-LiteOSPowerShellAction {
    param($Context, [string]$TweakId, $Action, [string]$Hive, [bool]$DryRun)
    if ([string]::IsNullOrEmpty($Hive)) { $Hive = 'Machine' }
    $text = [string]$Action.script
    $undo = Get-LiteOSProp $Action 'undo'
    $sh = Get-LiteOSScriptHive -Hive $Hive
    $where = ''
    if ($Hive -ne 'Machine') { $where = '[{0}] ' -f $Hive }
    if ($DryRun) { return (ConvertTo-LiteOSOutcome 'applied' ('{0}WhatIf: would run a PowerShell script ({1} chars)' -f $where, $text.Length)) }
    $before = [ordered]@{ undo = $undo; hiveTag = $sh.Tag }
    $mark = -1
    if ($null -ne $Context.BackupEntries) { $mark = $Context.BackupEntries.Count }
    Add-LiteOSBackupEntry -Context $Context -TweakId $TweakId -Action $Action -Hive $Hive -Before $before
    $r = Invoke-LiteOSScriptText -Text $text -Variables ([ordered]@{ LiteOSUserRoot = $sh.Root; LiteOSHiveTag = $sh.Tag })
    $verdict = Get-LiteOSScriptVerdict $r.Raw
    if ($null -ne $verdict) {
        # The script changed nothing: drop its write-ahead entry, so reverting THIS run never
        # undoes what an earlier run did (script state files are shared between runs).
        if ($mark -ge 0 -and $null -ne $Context.BackupEntries -and $Context.BackupEntries.Count -eq ($mark + 1)) {
            $Context.BackupEntries.RemoveAt($mark)
            Save-LiteOSBackup $Context
        }
        return (ConvertTo-LiteOSOutcome $verdict.Status ($where + $verdict.Message))
    }
    $m = $where + 'script ran'
    if ($r.Output) { $m += (': ' + $r.Output) }
    if ($r.ExitCode -ne 0) {
        $m += (' (note: last native exit code {0})' -f $r.ExitCode)
        Write-LiteOSLog -NoConsole -Level Warn ('{0}: script finished but the last native command returned exit code {1}' -f $TweakId, $r.ExitCode)
    }
    return (ConvertTo-LiteOSOutcome 'applied' $m)
}

function Get-LiteOSAppxCache {
    param($Context)
    if ($null -eq $Context.AppxCache) {
        $list = New-Object -TypeName 'System.Collections.Generic.List[object]'
        foreach ($p in @(Get-AppxPackage -AllUsers -PackageTypeFilter Main, Bundle -ErrorAction Stop)) {
            $list.Add([pscustomobject]@{
                    Name              = [string]$p.Name
                    PackageFullName   = [string]$p.PackageFullName
                    PackageFamilyName = [string]$p.PackageFamilyName
                    IsBundle          = (ConvertTo-LiteOSBool (Get-LiteOSProp $p 'IsBundle' $false))
                    NonRemovable      = (ConvertTo-LiteOSBool (Get-LiteOSProp $p 'NonRemovable' $false))
                })
        }
        $Context.AppxCache = $list
    }
    return , $Context.AppxCache
}

function Get-LiteOSProvisionedCache {
    param($Context)
    if ($null -eq $Context.ProvisionedCache) {
        $list = New-Object -TypeName 'System.Collections.Generic.List[object]'
        foreach ($p in @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)) {
            $list.Add([pscustomobject]@{ DisplayName = [string]$p.DisplayName; PackageName = [string]$p.PackageName })
        }
        $Context.ProvisionedCache = $list
    }
    return , $Context.ProvisionedCache
}

function Invoke-LiteOSAppxAction {
    param($Context, [string]$TweakId, $Action, [bool]$DryRun)
    if ($null -eq $Context.ProtectedApps) { $Context.ProtectedApps = @(Get-LiteOSProtectedApps -Path $Context.TweaksPath) }
    $protected = @($Context.ProtectedApps)
    $patterns = @(Get-LiteOSProp $Action 'packages' @())
    foreach ($pattern in $patterns) {
        $pattern = [string]$pattern
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        $c = Get-LiteOSProtectedConflict -Pattern $pattern -Protected $protected
        if ($null -ne $c.Blocked) {
            Write-LiteOSLog -NoConsole -Level Warn ('{0}: refused to remove protected package {1}' -f $TweakId, $pattern)
            ConvertTo-LiteOSOutcome 'skipped' ('refused: {0} is protected' -f $pattern)
            continue
        }
        $pkgs = $null
        $prov = $null
        try {
            $pkgs = Get-LiteOSAppxCache $Context
            $prov = Get-LiteOSProvisionedCache $Context
        }
        catch {
            if ($DryRun) { ConvertTo-LiteOSOutcome 'applied' ('WhatIf: would remove packages matching {0} (could not list packages: {1})' -f $pattern, (Format-LiteOSShort $_.Exception.Message 80)); continue }
            throw
        }
        $userHits = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $provHits = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $refused = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($p in $pkgs) {
            if (-not ($p.Name -like $pattern)) { continue }
            if (Test-LiteOSProtectedApp -Name $p.Name -Protected $protected) { if (-not $refused.Contains($p.Name)) { $refused.Add($p.Name) }; continue }
            if ($p.NonRemovable) { if (-not $refused.Contains($p.Name + ' (system)')) { $refused.Add($p.Name + ' (system)') }; continue }
            $userHits.Add($p)
        }
        foreach ($p in $prov) {
            if (-not ($p.DisplayName -like $pattern)) { continue }
            if (Test-LiteOSProtectedApp -Name $p.DisplayName -Protected $protected) { if (-not $refused.Contains($p.DisplayName)) { $refused.Add($p.DisplayName) }; continue }
            $provHits.Add($p)
        }
        if ($refused.Count -gt 0) {
            Write-LiteOSLog -NoConsole -Level Warn ('{0}: skipped protected/system packages: {1}' -f $TweakId, ($refused -join ', '))
        }
        if ($userHits.Count -eq 0 -and $provHits.Count -eq 0) {
            ConvertTo-LiteOSOutcome 'skipped' ('{0} is not installed' -f $pattern)
            continue
        }
        $names = @($userHits | ForEach-Object { $_.Name }) + @($provHits | ForEach-Object { $_.DisplayName }) | Select-Object -Unique
        if ($DryRun) { ConvertTo-LiteOSOutcome 'applied' ('WhatIf: would remove {0}' -f ($names -join ', ')); continue }

        $removed = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $failed = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $ordered = @($userHits | Sort-Object -Property @{ Expression = { -not $_.IsBundle } })
        foreach ($p in $ordered) {
            try {
                Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop
                $removed.Add([pscustomobject]([ordered]@{ name = $p.Name; fullName = $p.PackageFullName; familyName = $p.PackageFamilyName; provisioned = $false }))
            }
            catch {
                $em = $_.Exception.Message
                if ($em -match '0x80073CF1' -or $em -match 'not found') {
                    # Already removed together with its bundle.
                    $removed.Add([pscustomobject]([ordered]@{ name = $p.Name; fullName = $p.PackageFullName; familyName = $p.PackageFamilyName; provisioned = $false }))
                }
                else { $failed.Add(('{0}: {1}' -f $p.PackageFullName, (Format-LiteOSShort $em 120))) }
            }
            [void]$Context.AppxCache.Remove($p)
        }
        foreach ($p in $provHits) {
            try {
                $null = Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -AllUsers -ErrorAction Stop
                $removed.Add([pscustomobject]([ordered]@{ name = $p.DisplayName; fullName = $p.PackageName; familyName = ''; provisioned = $true }))
            }
            catch { $failed.Add(('{0} (provisioned): {1}' -f $p.PackageName, (Format-LiteOSShort $_.Exception.Message 120))) }
            [void]$Context.ProvisionedCache.Remove($p)
        }
        if ($removed.Count -gt 0) {
            $before = [ordered]@{ removed = $removed.ToArray() }
            Add-LiteOSBackupEntry -Context $Context -TweakId $TweakId -Action $Action -Hive 'Machine' -Before $before
        }
        if ($failed.Count -gt 0) {
            ConvertTo-LiteOSOutcome 'failed' ('could not remove: {0}' -f ($failed -join '; '))
        }
        if ($removed.Count -gt 0) {
            ConvertTo-LiteOSOutcome 'applied' ('removed {0}' -f (($removed | ForEach-Object { $_.name } | Select-Object -Unique) -join ', '))
        }
    }
}

function Test-LiteOSUserRegistryAction {
    param($Action)
    $type = [string](Get-LiteOSProp $Action 'type' '')
    if ($type -ne 'registry' -and $type -ne 'registry-delete') { return $false }
    $info = Resolve-LiteOSRegistryPath ([string](Get-LiteOSProp $Action 'path' ''))
    return ($null -ne $info -and $info.Root -eq 'HKCU')
}

function Test-LiteOSPerUserScript {
    # powershell actions with "perUser": true run once per user hive, like HKCU registry actions.
    param($Action)
    if ([string](Get-LiteOSProp $Action 'type' '') -ne 'powershell') { return $false }
    return (ConvertTo-LiteOSBool (Get-LiteOSProp $Action 'perUser' $false))
}

function Test-LiteOSUserAction {
    # Actions applied to the current user (hive 'User') instead of the machine.
    param($Action)
    return ((Test-LiteOSUserRegistryAction $Action) -or (Test-LiteOSPerUserScript $Action))
}

function Test-LiteOSDefaultHiveTarget {
    # User actions that are also applied to the Default user profile (new accounts).
    # HKCU\Software\Classes is excluded: it lives in UsrClass.dat, not NTUSER.DAT, so writing it
    # to the Default profile hive would never reach a new account.
    param($Action)
    if (Test-LiteOSPerUserScript $Action) { return $true }
    if (-not (Test-LiteOSUserRegistryAction $Action)) { return $false }
    $info = Resolve-LiteOSRegistryPath ([string](Get-LiteOSProp $Action 'path' ''))
    if ($null -eq $info) { return $false }
    $s = $info.SubKey.ToLowerInvariant()
    return (-not ($s -eq 'software\classes' -or $s.StartsWith('software\classes\')))
}

function Test-LiteOSNeedsDefaultHive {
    param([object[]]$Tweaks)
    foreach ($t in @($Tweaks)) {
        foreach ($a in @(Get-LiteOSProp $t 'actions' @())) {
            if (Test-LiteOSDefaultHiveTarget $a) { return $true }
        }
    }
    return $false
}

function Invoke-LiteOSAction {
    param($Context, [string]$TweakId, $Action, [string]$Hive, [bool]$DryRun)
    $type = Get-LiteOSCanonical (Get-LiteOSProp $Action 'type') $script:ActionTypes
    switch ($type) {
        'registry'        { return (Invoke-LiteOSRegistryAction -Context $Context -TweakId $TweakId -Action $Action -Hive $Hive -DryRun $DryRun) }
        'registry-delete' { return (Invoke-LiteOSRegistryDeleteAction -Context $Context -TweakId $TweakId -Action $Action -Hive $Hive -DryRun $DryRun) }
        'service'         { return (Invoke-LiteOSServiceAction -Context $Context -TweakId $TweakId -Action $Action -DryRun $DryRun) }
        'task'            { return (Invoke-LiteOSTaskAction -Context $Context -TweakId $TweakId -Action $Action -DryRun $DryRun) }
        'powershell'      { return (Invoke-LiteOSPowerShellAction -Context $Context -TweakId $TweakId -Action $Action -Hive $Hive -DryRun $DryRun) }
        'appx-remove'     { return (Invoke-LiteOSAppxAction -Context $Context -TweakId $TweakId -Action $Action -DryRun $DryRun) }
    }
    throw ("unknown action type '{0}'" -f (Get-LiteOSProp $Action 'type'))
}

function Write-LiteOSTweakLine {
    param($Result, [int]$Index = 0, [int]$Total = 0)
    $prefix = '  '
    if ($Total -gt 0) {
        $w = ([string]$Total).Length
        $prefix = '  [{0}/{1}] ' -f ([string]$Index).PadLeft($w), $Total
    }
    $tag = 'OK'
    $color = 'DarkGreen'
    if ($Result.status -eq 'failed') { $tag = 'FAIL'; $color = 'Red' }
    elseif ($Result.status -eq 'skipped') { $tag = 'SKIP'; $color = 'DarkGray' }
    elseif ($Result.status -eq 'deferred') { $tag = 'LATER'; $color = 'DarkCyan' }
    elseif ($Result.whatIf -and $Result.changes -gt 0) { $tag = 'WOULD'; $color = 'Cyan' }
    elseif ($Result.changes -gt 0) { $tag = 'DONE'; $color = 'Green' }
    Write-Host $prefix -NoNewline
    Write-Host ($tag.PadRight(6)) -ForegroundColor $color -NoNewline
    Write-Host $Result.name
    if ($Result.status -eq 'failed') {
        Write-Host ('         ' + (Format-LiteOSShort $Result.message 200)) -ForegroundColor Red
    }
    elseif (($Result.status -eq 'skipped' -or $Result.status -eq 'deferred') -and $Result.message) {
        Write-Host ('         ' + (Format-LiteOSShort $Result.message 120)) -ForegroundColor DarkGray
    }
}

# =============================================================================================
# Apply
# =============================================================================================

function Invoke-LiteOSTweak {
    <#
    .SYNOPSIS
        Applies one tweak. Returns {id, name, category, status (applied|skipped|failed), message, reboot, ...}.
    .DESCRIPTION
        Every change is written to the backup file before it is made. HKCU registry actions are
        applied to the current user and to the Default user profile. Failures never throw.
        -WhatIf (or a context created with -DryRun) changes nothing.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        $Tweak,

        $Context,

        [int]$Index = 0,
        [int]$Total = 0,
        [switch]$Quiet
    )
    if ($null -eq $Context) { $Context = Get-LiteOSBlankContext -DryRun ([bool]$WhatIfPreference) }
    $id = [string](Get-LiteOSProp $Tweak 'id' '(no id)')
    $dry = [bool]$Context.WhatIf
    if (-not $dry) {
        if (-not $PSCmdlet.ShouldProcess($id, 'Apply Lite OS tweak')) { $dry = $true }
    }
    $result = [pscustomobject]@{
        id       = $id
        name     = [string](Get-LiteOSProp $Tweak 'name' $id)
        category = [string](Get-LiteOSProp $Tweak 'category' '')
        status   = 'skipped'
        message  = ''
        reboot   = $false
        whatIf   = $dry
        changes  = 0
        details  = @()
    }
    $outcomes = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $ownHive = $false
    $ownBackup = $false
    $actions = @(Get-LiteOSProp $Tweak 'actions' @())
    $early = $null
    if ($Context.Build -gt 0 -and -not (Test-LiteOSBuildRange -Tweak $Tweak -Build $Context.Build)) {
        $maxText = 'any'
        if ((Get-LiteOSBuildBound $Tweak 'maxBuild') -gt 0) { $maxText = [string](Get-LiteOSBuildBound $Tweak 'maxBuild') }
        $early = 'not for this Windows build ({0}; needs {1} to {2})' -f $Context.Build, (Get-LiteOSBuildBound $Tweak 'minBuild'), $maxText
    }
    elseif ($actions.Count -eq 0) { $early = 'no actions' }
    if ($null -ne $early) { $outcomes.Add((ConvertTo-LiteOSOutcome 'skipped' $early)) }
    else {
        try {
            $needsDefault = $false
            foreach ($a in $actions) { if (Test-LiteOSDefaultHiveTarget $a) { $needsDefault = $true; break } }
            if (-not $dry) {
                if ([string]::IsNullOrEmpty($Context.BackupFile)) { Open-LiteOSBackup $Context; $ownBackup = $true }
                if ($needsDefault -and $Context.DefaultHiveState -eq 'NotLoaded') {
                    if (Mount-LiteOSDefaultHive $Context) { $ownHive = $true }
                }
            }

            foreach ($a in $actions) {
                $type = [string](Get-LiteOSProp $a 'type' '?')
                $hives = @('Machine')
                if (Test-LiteOSUserAction $a) {
                    $hives = @('User')
                    if ($Context.DefaultHiveState -eq 'Mounted' -and (Test-LiteOSDefaultHiveTarget $a)) { $hives += 'Default' }
                }
                foreach ($h in $hives) {
                    try {
                        foreach ($o in @(Invoke-LiteOSAction -Context $Context -TweakId $id -Action $a -Hive $h -DryRun $dry)) {
                            if ($null -ne $o) { $outcomes.Add($o) }
                        }
                    }
                    catch {
                        $outcomes.Add((ConvertTo-LiteOSOutcome 'failed' ('{0} [{1}]: {2}' -f $type, $h, (Format-LiteOSShort $_.Exception.Message 200))))
                    }
                }
            }
            if ($dry -and $needsDefault -and $Context.DefaultHiveState -ne 'Mounted') {
                $outcomes.Add((ConvertTo-LiteOSOutcome 'unchanged' 'WhatIf: HKCU values would also be written to the Default user profile'))
            }
        }
        catch {
            $outcomes.Add((ConvertTo-LiteOSOutcome 'failed' (Format-LiteOSShort $_.Exception.Message 200)))
        }
        finally {
            if ($ownHive) { Dismount-LiteOSDefaultHive $Context }
            if ($ownBackup) { Close-LiteOSBackup $Context }
        }
    }

    $nApplied = @($outcomes | Where-Object { $_.status -eq 'applied' }).Count
    $nSame = @($outcomes | Where-Object { $_.status -eq 'unchanged' }).Count
    $nSkip = @($outcomes | Where-Object { $_.status -eq 'skipped' }).Count
    $nFail = @($outcomes | Where-Object { $_.status -eq 'failed' }).Count
    $result.changes = $nApplied
    $result.details = @($outcomes | ForEach-Object { '{0}: {1}' -f $_.status, $_.message })
    if ($nFail -gt 0) {
        $result.status = 'failed'
        $result.message = (@($outcomes | Where-Object { $_.status -eq 'failed' } | ForEach-Object { $_.message }) -join '; ')
        if ($nApplied -gt 0) { $result.message = ('{0} of {1} changes made; ' -f $nApplied, ($nApplied + $nFail)) + $result.message }
    }
    elseif ($nApplied -eq 0 -and $nSame -eq 0) {
        $result.status = 'skipped'
        $result.message = (@($outcomes | ForEach-Object { $_.message }) -join '; ')
    }
    else {
        $result.status = 'applied'
        if ($nApplied -eq 0) { $result.message = 'already applied' }
        elseif ($dry) { $result.message = ('would make {0} change(s)' -f $nApplied) }
        else { $result.message = ('{0} change(s)' -f $nApplied) }
        if ($nSkip -gt 0) { $result.message += ('; {0} not applicable' -f $nSkip) }
    }
    if (-not $dry -and $nApplied -gt 0) {
        $tweakReboot = ConvertTo-LiteOSBool (Get-LiteOSProp $Tweak 'reboot' $false)
        $outcomeReboot = @($outcomes | Where-Object { $_.reboot }).Count -gt 0
        if ($tweakReboot -or $outcomeReboot) { $result.reboot = $true; $Context.RebootRequired = $true }
    }

    $lvl = 'Info'
    if ($result.status -eq 'failed') { $lvl = 'Error' } elseif ($result.status -eq 'applied' -and $nApplied -gt 0) { $lvl = 'Success' }
    Write-LiteOSLog -NoConsole -Level $lvl ('{0} {1}: {2}' -f $result.status.ToUpperInvariant(), $id, $result.message)
    foreach ($o in $outcomes) { Write-LiteOSLog -NoConsole -Level Debug ('    {0}: {1}' -f $o.status, $o.message) }
    if (-not $Quiet) { Write-LiteOSTweakLine -Result $result -Index $Index -Total $Total }
    return $result
}

function Invoke-LiteOSPlan {
    <#
    .SYNOPSIS
        Applies a list of tweaks in order, writing one backup file for the run. Returns all results.
    .PARAMETER BackupPath
        Optional backup file to use instead of a new backup-<timestamp>.json. An existing trusted
        file is continued (entries appended), e.g. SetupComplete appending the deferred image actions
        to backup-image.json.
    .PARAMETER BackupSource
        Written as "source" into the header when BackupPath does not exist yet (e.g. 'image').
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Tweaks,

        $Context,

        [string]$BackupPath,

        [string]$BackupSource,

        [switch]$Quiet
    )
    if ($null -eq $Context) { $Context = Get-LiteOSBlankContext -DryRun ([bool]$WhatIfPreference) }
    $list = @($Tweaks | Where-Object { $null -ne $_ })
    $dry = [bool]$Context.WhatIf
    if (-not $dry) {
        if (-not $PSCmdlet.ShouldProcess(('{0} tweak(s)' -f $list.Count), 'Apply Lite OS plan')) { $dry = $true }
    }
    $prevWhatIf = $Context.WhatIf
    $Context.WhatIf = $dry
    $results = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $mounted = $false
    Write-LiteOSLog -NoConsole ('Plan: {0} tweak(s), level {1}, dry-run {2}' -f $list.Count, $Context.Level, $dry)
    try {
        if (-not $dry) {
            if ([string]::IsNullOrEmpty($BackupPath)) { Open-LiteOSBackup $Context }
            else {
                $extra = $null
                if (-not [string]::IsNullOrEmpty($BackupSource)) { $extra = [ordered]@{ source = $BackupSource } }
                Open-LiteOSBackup -Context $Context -Path $BackupPath -Header $extra
            }
            if ((Test-LiteOSNeedsDefaultHive $list) -and $Context.DefaultHiveState -eq 'NotLoaded') {
                $mounted = Mount-LiteOSDefaultHive $Context
            }
        }
        $i = 0
        foreach ($t in $list) {
            $i++
            $r = $null
            try {
                if ($dry) {
                    $r = Invoke-LiteOSTweak -Tweak $t -Context $Context -Index $i -Total $list.Count -Quiet:$Quiet
                }
                else {
                    $r = Invoke-LiteOSTweak -Tweak $t -Context $Context -Index $i -Total $list.Count -Quiet:$Quiet -WhatIf:$false -Confirm:$false
                }
            }
            catch {
                $r = [pscustomobject]@{
                    id = [string](Get-LiteOSProp $t 'id' '?'); name = [string](Get-LiteOSProp $t 'name' '?'); category = [string](Get-LiteOSProp $t 'category' '')
                    status = 'failed'; message = $_.Exception.Message; reboot = $false; whatIf = $dry; changes = 0; details = @()
                }
                Write-LiteOSLog -Level Error ('{0}: {1}' -f $r.id, $r.message)
            }
            $results.Add($r)
        }
    }
    finally {
        if ($mounted) { Dismount-LiteOSDefaultHive $Context }
        if (-not $dry) { Close-LiteOSBackup $Context }
        $Context.WhatIf = $prevWhatIf
    }
    $a = @($results | Where-Object { $_.status -eq 'applied' }).Count
    $s = @($results | Where-Object { $_.status -eq 'skipped' }).Count
    $f = @($results | Where-Object { $_.status -eq 'failed' }).Count
    Write-LiteOSLog -NoConsole ('Plan finished: {0} applied, {1} skipped, {2} failed, reboot required: {3}' -f $a, $s, $f, $Context.RebootRequired)
    return $results.ToArray()
}

function Write-LiteOSSummary {
    <#
    .SYNOPSIS
        Prints the per-category summary table and returns the totals.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Results,

        $Context
    )
    $rows = @($Results | Where-Object { $null -ne $_ })
    $cats = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($r in $rows) { $c = [string]$r.category; if (-not $c) { $c = '(other)' }; if (-not $cats.Contains($c)) { $cats.Add($c) } }
    Write-Host ''
    Write-Host '  Summary' -ForegroundColor Cyan
    Write-Host ('  {0,-22} {1,8} {2,8} {3,8}' -f 'Category', 'Applied', 'Skipped', 'Failed')
    Write-Host ('  ' + ('-' * 49))
    foreach ($c in $cats) {
        $sub = @($rows | Where-Object { $rc = [string]$_.category; if (-not $rc) { $rc = '(other)' }; $rc -eq $c })
        $a = @($sub | Where-Object { $_.status -eq 'applied' }).Count
        $s = @($sub | Where-Object { $_.status -eq 'skipped' }).Count
        $f = @($sub | Where-Object { $_.status -eq 'failed' }).Count
        $color = 'Gray'
        if ($f -gt 0) { $color = 'Yellow' }
        Write-Host ('  {0,-22} {1,8} {2,8} {3,8}' -f (Format-LiteOSShort $c 22), $a, $s, $f) -ForegroundColor $color
    }
    $ta = @($rows | Where-Object { $_.status -eq 'applied' }).Count
    $ts = @($rows | Where-Object { $_.status -eq 'skipped' }).Count
    $tf = @($rows | Where-Object { $_.status -eq 'failed' }).Count
    Write-Host ('  ' + ('-' * 49))
    Write-Host ('  {0,-22} {1,8} {2,8} {3,8}' -f 'TOTAL', $ta, $ts, $tf) -ForegroundColor White
    $failed = @($rows | Where-Object { $_.status -eq 'failed' })
    if ($failed.Count -gt 0) {
        Write-Host ''
        Write-Host '  Failed:' -ForegroundColor Red
        foreach ($r in $failed) { Write-Host ('   - {0}: {1}' -f $r.id, (Format-LiteOSShort $r.message 160)) -ForegroundColor Red }
    }
    $reboot = (@($rows | Where-Object { $_.reboot }).Count -gt 0)
    if ($null -ne $Context -and $Context.RebootRequired) { $reboot = $true }
    Write-Host ''
    if ($reboot) { Write-Host '  Reboot required: YES - restart Windows to finish applying the changes.' -ForegroundColor Yellow }
    else { Write-Host '  Reboot required: no (a restart is still recommended for Explorer/UI changes).' }
    if ($null -ne $Context) {
        if ($Context.LastBackupFile) { Write-Host ('  Backup: {0}' -f $Context.LastBackupFile) }
        if ($Context.LogFile) { Write-Host ('  Log:    {0}' -f $Context.LogFile) }
    }
    Write-LiteOSLog -NoConsole ('Summary: {0} applied, {1} skipped, {2} failed, reboot {3}' -f $ta, $ts, $tf, $reboot)
    return [pscustomobject]@{ Applied = $ta; Skipped = $ts; Failed = $tf; Total = $rows.Count; RebootRequired = $reboot }
}

# =============================================================================================
# Restore point
# =============================================================================================

function New-LiteOSRestorePoint {
    <#
    .SYNOPSIS
        Enables System Restore on the system drive if needed and creates a restore point. Never throws.
    .OUTPUTS
        $true if a restore point was created.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [string]$Description = 'Lite OS - before tweaks',
        $Context
    )
    $drive = $env:SystemDrive
    if ([string]::IsNullOrEmpty($drive)) { $drive = 'C:' }
    $drive = $drive.TrimEnd('\') + '\'
    if ($null -ne $Context -and $Context.WhatIf) {
        Write-LiteOSLog ('WhatIf: would create a System Restore point "{0}" on {1}' -f $Description, $drive)
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($drive, 'Create System Restore point')) { return $false }

    $srPath = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $freqName = 'SystemRestorePointCreationFrequency'
    $hadFreq = $false
    $oldFreq = $null
    $freqChanged = $false
    $ok = $false
    try {
        # Enable System Restore if it is off.
        $enabled = $true
        try {
            $sr = Get-ItemProperty -LiteralPath ('HKLM:\' + $srPath) -ErrorAction Stop
            $rp = Get-LiteOSProp $sr 'RPSessionInterval'
            if ($null -ne $rp -and [int]$rp -eq 0) { $enabled = $false }
            if ($null -eq $rp) { $enabled = $false }
        }
        catch { $enabled = $false }
        if (-not $enabled) {
            try {
                Enable-ComputerRestore -Drive $drive -ErrorAction Stop
                Write-LiteOSLog ('System Restore enabled on {0}' -f $drive)
            }
            catch {
                Write-LiteOSLog -Level Warn ('Could not enable System Restore on {0}: {1}' -f $drive, $_.Exception.Message)
            }
        }

        # Allow more than one restore point per 24 h for this call.
        $base = Open-LiteOSBaseKey ([Microsoft.Win32.RegistryHive]::LocalMachine)
        try {
            $k = $base.CreateSubKey($srPath)
            if ($null -ne $k) {
                try {
                    foreach ($n in $k.GetValueNames()) { if ($n -eq $freqName) { $hadFreq = $true } }
                    if ($hadFreq) { $oldFreq = $k.GetValue($freqName) }
                    $k.SetValue($freqName, [int32]0, [Microsoft.Win32.RegistryValueKind]::DWord)
                    $freqChanged = $true
                }
                finally { $k.Close() }
            }
        }
        catch { Write-LiteOSLog -NoConsole -Level Warn ('Could not adjust {0}: {1}' -f $freqName, $_.Exception.Message) }
        finally { $base.Close() }

        Write-LiteOSLog 'Creating a System Restore point (this can take a minute)...'
        $warn = $null
        Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable warn
        if ($null -ne $warn -and @($warn).Count -gt 0) {
            Write-LiteOSLog -Level Warn ('Restore point not created: {0}' -f (@($warn)[0]))
        }
        else {
            $ok = $true
            Write-LiteOSLog -Level Success ('Restore point created: {0}' -f $Description)
        }
    }
    catch {
        Write-LiteOSLog -Level Warn ('Could not create a restore point: {0}. Continuing; the Lite OS backup still allows reverting.' -f $_.Exception.Message)
    }
    finally {
        if ($freqChanged) {
            $base = $null
            try {
                $base = Open-LiteOSBaseKey ([Microsoft.Win32.RegistryHive]::LocalMachine)
                $k = $base.OpenSubKey($srPath, $true)
                if ($null -ne $k) {
                    try {
                        if ($hadFreq -and $null -ne $oldFreq) { $k.SetValue($freqName, [int32]$oldFreq, [Microsoft.Win32.RegistryValueKind]::DWord) }
                        else { $k.DeleteValue($freqName, $false) }
                    }
                    finally { $k.Close() }
                }
            }
            catch { Write-LiteOSLog -NoConsole -Level Warn ('Could not restore {0}: {1}' -f $freqName, $_.Exception.Message) }
            finally { if ($null -ne $base) { $base.Close() } }
        }
    }
    return $ok
}

# =============================================================================================
# Backups / restore
# =============================================================================================

function Get-LiteOSBackups {
    <#
    .SYNOPSIS
        Lists Lite OS backups, newest first: Path, Name, Created, Level, Build, EntryCount, Complete, Restored, Valid.
    #>
    [CmdletBinding()]
    param([string]$Directory)
    if ([string]::IsNullOrEmpty($Directory)) { $Directory = Join-Path (Get-LiteOSDefaultStateRoot) 'backup' }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    $items = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($f in @(Get-ChildItem -LiteralPath $Directory -Filter 'backup-*.json' -File -ErrorAction SilentlyContinue)) {
        $created = $f.CreationTime.ToString('s')
        $o = [pscustomobject]@{
            Path = $f.FullName; Name = $f.Name; Created = $created; Level = ''; Build = 0
            EntryCount = 0; Complete = $false; Restored = $null; RestoreAttempted = $null; Valid = $false; Error = $null
            Source = ''; Mode = ''
        }
        try {
            if (-not (Test-LiteOSTrustedFile $f.FullName)) {
                $owner = Get-LiteOSFileOwner $f.FullName
                if (-not $owner) { $owner = 'unknown' }
                throw ('not created by an administrator (owner {0}); ignored for safety' -f $owner)
            }
            $d = Read-LiteOSJsonFile $f.FullName
            $c = [string](Get-LiteOSProp $d 'created' '')
            if ($c) { $o.Created = $c }
            $o.Level = [string](Get-LiteOSProp $d 'level' '')
            try { $o.Build = [int](Get-LiteOSProp $d 'build' 0) } catch { $o.Build = 0 }
            $o.EntryCount = @(Get-LiteOSProp $d 'entries' @()).Count
            $o.Complete = ConvertTo-LiteOSBool (Get-LiteOSProp $d 'complete' $false)
            $o.Restored = Get-LiteOSProp $d 'restored'
            $o.RestoreAttempted = Get-LiteOSProp $d 'restoreAttempted'
            $o.Source = [string](Get-LiteOSProp $d 'source' '')
            $o.Mode = [string](Get-LiteOSProp $d 'mode' '')
            $o.Valid = $true
        }
        catch { $o.Error = $_.Exception.Message }
        $items.Add($o)
    }
    $items | Sort-Object -Property @{ Expression = { $_.Created }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $true }
}

function Restore-LiteOSEntry {
    param($Context, $Entry, [string]$UserSid)
    $action = Get-LiteOSProp $Entry 'action'
    $type = Get-LiteOSCanonical (Get-LiteOSProp $action 'type') $script:ActionTypes
    $hive = [string](Get-LiteOSProp $Entry 'hive' 'Machine')
    $before = Get-LiteOSProp $Entry 'before'

    if ($type -eq 'registry' -or $type -eq 'registry-delete') {
        if ($hive -eq 'Default' -and $Context.DefaultHiveState -ne 'Mounted') {
            return (ConvertTo-LiteOSOutcome 'skipped' 'Default profile hive not available')
        }
        $target = Get-LiteOSRegistryTarget -Path ([string](Get-LiteOSProp $action 'path')) -Hive $hive -UserSid $UserSid
        if (-not (Test-LiteOSRegistryPrefix $target)) {
            return (ConvertTo-LiteOSOutcome 'skipped' ('user hive {0} is not loaded; sign in as that user and run the revert again' -f $target.Prefix.TrimEnd('\')))
        }
        if ($type -eq 'registry-delete' -and -not (Test-LiteOSProp $action 'name')) {
            $tree = Get-LiteOSProp $before 'tree'
            if ($null -eq $tree) { return (ConvertTo-LiteOSOutcome 'skipped' 'no key export in backup') }
            $base = Open-LiteOSBaseKey $target.BaseHive
            try { Import-LiteOSRegistryTree -Base $base -SubKey $target.SubKey -Tree $tree } finally { $base.Close() }
            return (ConvertTo-LiteOSOutcome 'restored' ('recreated key {0}' -f $target.Display))
        }
        $name = [string](Get-LiteOSProp $action 'name' '')
        $label = '{0}\{1}' -f $target.Display, $(if ($name -eq '') { '(Default)' } else { $name })
        if (ConvertTo-LiteOSBool (Get-LiteOSProp $before 'exists' $false)) {
            $kind = [string](Get-LiteOSProp $before 'kind' 'String')
            Write-LiteOSRegistryValue -Target $target -Name $name -Kind $kind -Value (Get-LiteOSPropRaw $before 'value')
            return (ConvertTo-LiteOSOutcome 'restored' ('{0} = {1} ({2})' -f $label, (Format-LiteOSRegistryValue $kind (Get-LiteOSPropRaw $before 'value')), $kind))
        }
        $had = Clear-LiteOSRegistryValue -Target $target -Name $name
        $n = Clear-LiteOSEmptyKeys -Target $target -LogicalKeys @(Get-LiteOSProp $before 'createdKeys' @())
        $m = '{0} removed' -f $label
        if (-not $had) { $m = '{0} already absent' -f $label }
        if ($n -gt 0) { $m += ('; {0} empty key(s) removed' -f $n) }
        return (ConvertTo-LiteOSOutcome 'restored' $m)
    }
    if ($type -eq 'service') {
        $name = [string](Get-LiteOSProp $action 'name')
        if ($null -eq (Get-LiteOSServiceConfig $name)) { return (ConvertTo-LiteOSOutcome 'skipped' ('service {0} not found' -f $name)) }
        $start = [int](Get-LiteOSProp $before 'start' 3)
        $delayed = Get-LiteOSProp $before 'delayed'
        $r = Invoke-LiteOSServiceConfig -Name $name -Start $start -Delayed $delayed -ExactDelayed
        $m = 'service {0} -> {1} ({2})' -f $name, (Get-LiteOSStartupName $start $delayed), $r.Message
        $status = [string](Get-LiteOSProp $before 'status' '')
        if ($status -eq 'Running' -and $start -ne 4 -and -not $r.UsedRegistry) {
            try { Start-Service -Name $name -ErrorAction Stop -WarningAction SilentlyContinue; $m += '; started' }
            catch { $m += ('; could not start now ({0})' -f (Format-LiteOSShort $_.Exception.Message 60)) }
        }
        return (ConvertTo-LiteOSOutcome 'restored' $m $r.UsedRegistry)
    }
    if ($type -eq 'task') {
        $tp = [string](Get-LiteOSProp $before 'taskPath' (Get-LiteOSProp $action 'path'))
        $tn = [string](Get-LiteOSProp $before 'taskName' (Get-LiteOSProp $action 'name'))
        $st = [string](Get-LiteOSProp $before 'state' 'Enabled')
        $tasks = @(Get-LiteOSTasks -TaskPath $tp -TaskName $tn)
        if ($tasks.Count -eq 0) { return (ConvertTo-LiteOSOutcome 'skipped' ('task {0}{1} not found' -f $tp, $tn)) }
        if ($st -eq 'Disabled') { $null = Disable-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction Stop }
        else { $null = Enable-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction Stop }
        return (ConvertTo-LiteOSOutcome 'restored' ('task {0}{1} -> {2}' -f $tp, $tn, $st))
    }
    if ($type -eq 'powershell') {
        $undo = Get-LiteOSProp $before 'undo'
        if (-not ($undo -is [string]) -or [string]::IsNullOrWhiteSpace($undo)) {
            return (ConvertTo-LiteOSOutcome 'skipped' 'no undo script for this PowerShell action')
        }
        if ($hive -eq 'Default' -and $Context.DefaultHiveState -ne 'Mounted') {
            return (ConvertTo-LiteOSOutcome 'skipped' 'Default profile hive not available')
        }
        $sh = Get-LiteOSScriptHive -Hive $hive -UserSid $UserSid
        if (-not $sh.Loaded) {
            return (ConvertTo-LiteOSOutcome 'skipped' ('user hive {0} is not loaded; sign in as that user and run the revert again' -f $UserSid))
        }
        $tag = [string](Get-LiteOSProp $before 'hiveTag' '')
        if ([string]::IsNullOrEmpty($tag)) { $tag = $sh.Tag }
        $r = Invoke-LiteOSScriptText -Text $undo -Variables ([ordered]@{ LiteOSUserRoot = $sh.Root; LiteOSHiveTag = $tag })
        $m = 'undo script ran'
        if ($r.Output) { $m += (': ' + $r.Output) }
        return (ConvertTo-LiteOSOutcome 'restored' $m)
    }
    if ($type -eq 'appx-remove') {
        $apps = New-Object -TypeName 'System.Collections.Generic.List[object]'
        foreach ($p in @(Get-LiteOSProp $before 'removed' @())) {
            $nm = [string](Get-LiteOSProp $p 'name' '')
            if (-not $nm) { continue }
            $dup = $false
            foreach ($x in $apps) { if ($x.name -eq $nm) { $dup = $true } }
            if (-not $dup) { $apps.Add([pscustomobject]@{ name = $nm; familyName = [string](Get-LiteOSProp $p 'familyName' '') }) }
        }
        $names = @($apps | ForEach-Object { $_.name }) -join ', '
        return (ConvertTo-LiteOSOutcome 'skipped' ('apps are not reinstalled automatically ({0}); reinstall from the Microsoft Store or with winget' -f $names) $false $apps.ToArray())
    }
    return (ConvertTo-LiteOSOutcome 'failed' ("unknown action type '{0}' in backup" -f (Get-LiteOSProp $action 'type')))
}

function Restore-LiteOSBackup {
    <#
    .SYNOPSIS
        Reverts a backup file in reverse order, best effort; logs and returns one result per entry.
    .DESCRIPTION
        Results: {tweakId, action, hive, status (restored|skipped|failed), message, apps}. Removed AppX
        packages cannot be restored automatically; their names are returned so the caller can show
        Microsoft Store / winget hints. The backup file is marked as restored afterwards only when
        no entry failed (otherwise 'restoreAttempted' is set and it stays pending for a retry).
        Backup files not owned by SYSTEM / Administrators / the current admin are refused.

        Image backups ("source": "image", backup-image.json written by the Lite OS Builder and
        SetupComplete): Machine entries are restored normally. Their 'User' entries hold the values the
        Default user profile had in the official image (every account on a Lite OS install was created
        from it), so they are restored into the HKCU of the user running the revert; with
        -IncludeDefaultProfile also into the Default profile (C:\Users\Default\NTUSER.DAT), so accounts
        created later start with the stock values too. Other existing accounts keep their settings until
        they run the revert themselves (Revert-LiteOS.ps1 -Path <backup-image.json>).
    .PARAMETER IncludeDefaultProfile
        Image backups only: also restore the per-user entries into the Default user profile.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        $Context,

        [switch]$IncludeDefaultProfile
    )
    if ($null -eq $Context) { $Context = Get-LiteOSBlankContext -DryRun ([bool]$WhatIfPreference) }
    $dry = [bool]$Context.WhatIf
    if (-not $dry) {
        if (-not $PSCmdlet.ShouldProcess($Path, 'Restore Lite OS backup')) { $dry = $true }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('Backup file not found: {0}' -f $Path) }
    if (-not $dry -and -not (Test-LiteOSTrustedFile $Path)) {
        $owner = Get-LiteOSFileOwner $Path
        if (-not $owner) { $owner = 'unknown' }
        throw ('Refusing to restore {0}: it is owned by {1}, not by SYSTEM, Administrators or you, so it may have been planted by another account. If you made it yourself, run: icacls "{0}" /setowner *S-1-5-32-544 (elevated) and try again.' -f $Path, $owner)
    }
    $data = Read-LiteOSJsonFile $Path
    $entries = @(Get-LiteOSProp $data 'entries' @())
    $sid = [string](Get-LiteOSProp $data 'userSid' '')
    $isImage = (Test-LiteOSImageBackupData $data)
    Write-LiteOSLog ('Restoring {0} ({1} entries, newest first){2}' -f $Path, $entries.Count, $(if ($dry) { ' - dry run' } else { '' }))
    if ($isImage) {
        # Per-user entries of an image backup belong to the Default profile the image shipped with,
        # not to one account: restore them into the reverting user's own HKCU.
        $sid = ''
        $who = [string]$Context.UserName
        if (-not $who) { $who = 'the current user' }
        $dp = ''
        if ($IncludeDefaultProfile) { $dp = ' and into the Default profile used for new accounts' }
        Write-LiteOSLog ('Image backup: machine-wide settings are restored for the whole PC; per-user settings baked into the image are restored into the account of {0}{1}.' -f $who, $dp)
        if ([string]$Context.UserSid -eq 'S-1-5-18') {
            Write-LiteOSLog -Level Warn 'The revert runs as SYSTEM: per-user settings go to the SYSTEM profile, not to a signed-in account.'
        }
    }
    elseif ($sid -and $sid -ne (Get-LiteOSCurrentSid)) {
        Write-LiteOSLog -Level Warn ('This backup was made by another user ({0}); their HKCU values are restored only if that profile is loaded.' -f $sid)
    }
    $results = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $mounted = $false
    try {
        $needDefault = $false
        foreach ($e in $entries) {
            $eh = [string](Get-LiteOSProp $e 'hive' '')
            if ($eh -eq 'Default' -or ($isImage -and $IncludeDefaultProfile -and $eh -eq 'User')) { $needDefault = $true; break }
        }
        if ($needDefault -and -not $dry -and $Context.DefaultHiveState -eq 'NotLoaded') { $mounted = Mount-LiteOSDefaultHive $Context }
        for ($i = $entries.Count - 1; $i -ge 0; $i--) {
            $e = $entries[$i]
            $tid = [string](Get-LiteOSProp $e 'tweakId' '?')
            $act = Get-LiteOSProp $e 'action'
            $type = [string](Get-LiteOSProp $act 'type' '?')
            $hive = [string](Get-LiteOSProp $e 'hive' 'Machine')
            $targets = @($hive)
            if ($isImage -and $hive -eq 'User' -and $IncludeDefaultProfile) { $targets = @('User', 'Default') }
            # Image backups: every undo of a per-user script consumes (deletes) the Default-profile
            # state file the image shipped with. Keep one copy per ENTRY and put it back after each
            # target (User and Default), so the Default profile and every other account can still
            # revert later (the undo is idempotent, so a kept state file is harmless).
            $kept = $null
            if (-not $dry -and $isImage -and $hive -eq 'User' -and $type -eq 'powershell') {
                try { $kept = Save-LiteOSHiveStateFiles -Directory $Context.StateRoot -Tag ([string](Get-LiteOSProp (Get-LiteOSProp $e 'before') 'hiveTag' 'Default')) }
                catch {
                    $kept = $null
                    Write-LiteOSLog -NoConsole -Level Warn ('{0}: could not keep a copy of its state files: {1}' -f $tid, $_.Exception.Message)
                }
            }
            foreach ($h in $targets) {
                $entry = $e
                if ($h -ne $hive) { $entry = Copy-LiteOSBackupEntry -Entry $e -Hive $h }
                $o = $null
                if ($dry) {
                    $o = ConvertTo-LiteOSOutcome 'restored' ('WhatIf: would revert {0} [{1}]' -f $type, $h)
                }
                else {
                    try { $o = Restore-LiteOSEntry -Context $Context -Entry $entry -UserSid $sid }
                    catch { $o = ConvertTo-LiteOSOutcome 'failed' (Format-LiteOSShort $_.Exception.Message 200) }
                    finally {
                        if ($null -ne $kept) {
                            try { [void](Restore-LiteOSHiveStateFiles -Saved $kept) }
                            catch { Write-LiteOSLog -NoConsole -Level Warn ('{0}: could not put back its state files: {1}' -f $tid, $_.Exception.Message) }
                        }
                    }
                }
                $r = [pscustomobject]@{ tweakId = $tid; action = $type; hive = $h; status = $o.status; message = $o.message; reboot = $o.reboot; apps = $o.apps }
                $results.Add($r)
                $lvl = 'Info'
                if ($r.status -eq 'failed') { $lvl = 'Error' } elseif ($r.status -eq 'skipped') { $lvl = 'Warn' }
                Write-LiteOSLog -NoConsole -Level $lvl ('REVERT {0} {1} [{2}] {3}: {4}' -f $r.status.ToUpperInvariant(), $tid, $h, $type, $r.message)
            }
        }
    }
    finally {
        if ($mounted) { Dismount-LiteOSDefaultHive $Context }
    }
    if (-not $dry) {
        try {
            $nFailed = @($results | Where-Object { $_.status -eq 'failed' }).Count
            $now = (Get-Date).ToString('s')
            if ($isImage) {
                # Informational: which accounts already got their per-user values back.
                $users = New-Object -TypeName 'System.Collections.Generic.List[string]'
                foreach ($u in @(Get-LiteOSProp $data 'restoredUsers' @())) { if ($u -and -not $users.Contains([string]$u)) { $users.Add([string]$u) } }
                $me = [string]$Context.UserSid
                if ($me -and -not $users.Contains($me)) { $users.Add($me) }
                $data | Add-Member -NotePropertyName restoredUsers -NotePropertyValue $users.ToArray() -Force
                if ($IncludeDefaultProfile) { $data | Add-Member -NotePropertyName restoredDefaultProfile -NotePropertyValue $now -Force }
            }
            $data | Add-Member -NotePropertyName restoreAttempted -NotePropertyValue $now -Force
            if ($nFailed -eq 0) {
                $data | Add-Member -NotePropertyName restored -NotePropertyValue $now -Force
            }
            elseif ($null -eq $data.PSObject.Properties['restored']) {
                # Keep the backup pending, so -Silent / -All / the default choice retry the failed
                # entries (every restore step is idempotent).
                $data | Add-Member -NotePropertyName restored -NotePropertyValue $null -Force
            }
            $data | Add-Member -NotePropertyName restoreSummary -NotePropertyValue ([ordered]@{
                    restored = @($results | Where-Object { $_.status -eq 'restored' }).Count
                    skipped  = @($results | Where-Object { $_.status -eq 'skipped' }).Count
                    failed   = $nFailed
                }) -Force
            Write-LiteOSTextFile -Path $Path -Text (ConvertTo-Json -InputObject $data -Depth 100) -Encoding $script:Utf8Bom
            if ($nFailed -gt 0) {
                Write-LiteOSLog -Level Warn ('{0} change(s) could not be reverted; the backup stays "not reverted" so you can retry it.' -f $nFailed)
            }
        }
        catch { Write-LiteOSLog -NoConsole -Level Warn ('Could not mark backup as restored: {0}' -f $_.Exception.Message) }
        $Context.RebootRequired = $true
    }
    return $results.ToArray()
}

function Test-LiteOSImageBackupData {
    # True for a backup written by the image builder / SetupComplete ("source": "image").
    param($Data)
    return ([string](Get-LiteOSProp $Data 'source' '') -eq 'image')
}

function Copy-LiteOSBackupEntry {
    # Shallow copy of a backup entry with another hive (image backups: User entry -> Default profile).
    param($Entry, [string]$Hive)
    $h = [ordered]@{}
    foreach ($p in $Entry.PSObject.Properties) { $h[$p.Name] = $p.Value }
    $h['hive'] = $Hive
    return [pscustomobject]$h
}

function Save-LiteOSHiveStateFiles {
    # In-memory copy of the per-hive script state files of one hive tag (prev-*<tag>*), so they can
    # be put back after an undo script consumed them. Returns an object[] (possibly empty) or $null.
    # NOTE: never hand out a New-Object List[object]: on Windows PowerShell 5.1.26100 "@($list)" of
    # such a list throws "Argument types do not match", so callers get a plain array.
    param([string]$Directory, [string]$Tag)
    if ([string]::IsNullOrEmpty($Tag) -or [string]::IsNullOrEmpty($Directory)) { return $null }
    if (-not [System.IO.Directory]::Exists($Directory)) { return $null }
    $saved = New-Object -TypeName 'System.Collections.ArrayList'
    foreach ($f in @(Get-ChildItem -LiteralPath $Directory -Filter 'prev-*' -File -ErrorAction SilentlyContinue)) {
        if ($f.Name.IndexOf($Tag, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        try { [void]$saved.Add([pscustomobject]@{ Path = $f.FullName; Bytes = [System.IO.File]::ReadAllBytes($f.FullName) }) }
        catch { Write-LiteOSLog -NoConsole -Level Warn ('Could not read state file {0}: {1}' -f $f.FullName, $_.Exception.Message) }
    }
    return , ([object[]]$saved.ToArray())
}

function Restore-LiteOSHiveStateFiles {
    # Puts back state files saved by Save-LiteOSHiveStateFiles that an undo script deleted. Never
    # throws (a state-file problem must not abort a revert); returns how many files were written.
    param($Saved)
    $n = 0
    if ($null -eq $Saved) { return $n }
    foreach ($s in $Saved) {
        if ($null -eq $s) { continue }
        try {
            if ([System.IO.File]::Exists([string]$s.Path)) { continue }
            [System.IO.File]::WriteAllBytes([string]$s.Path, [byte[]]$s.Bytes)
            $n++
        }
        catch { Write-LiteOSLog -NoConsole -Level Warn ('Could not put back state file {0}: {1}' -f $s.Path, $_.Exception.Message) }
    }
    return $n
}

# =============================================================================================
# Lite OS image (v2): offline plan into a mounted image, deferred actions, SetupComplete helpers.
# The builder mounts the WIM and loads the offline hives (HKLM\LITE_SOFTWARE, HKLM\LITE_SYSTEM,
# HKLM\LITE_DEFAULT = Users\Default\NTUSER.DAT); this engine never loads or unloads hives itself.
# Approach (offline registry edits through loaded hives, Default-profile HKCU) as popularised by
# tiny11builder (ntdevlabs) and documented by Microsoft (DISM offline servicing); no code copied.
# =============================================================================================

function Get-LiteOSHiveValue {
    # Case-insensitive lookup in any dictionary (hashtable, ordered, Dictionary[string,..]).
    param([System.Collections.IDictionary]$Hives, [string]$Name)
    if ($null -eq $Hives) { return $null }
    foreach ($k in @($Hives.Keys)) { if ([string]$k -eq $Name) { return $Hives[$k] } }
    return $null
}

function ConvertTo-LiteOSHiveRoot {
    # 'HKLM\LITE_SOFTWARE' (also HKEY_LOCAL_MACHINE\, HKLM:\, Registry::..., HKU\, HKEY_USERS\) ->
    # {BaseHive; Name; Root='Registry::HKEY_LOCAL_MACHINE\LITE_SOFTWARE'; Display='HKLM\LITE_SOFTWARE'}.
    # $null when empty or malformed, and when it names a LIVE hive of this PC (HKLM\SOFTWARE,
    # HKLM\SYSTEM, HKU\S-1-5-..., HKU\.DEFAULT, ...): offline writes must never reach the build PC.
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $p = $Value.Trim()
    if ($p.StartsWith('Registry::', [System.StringComparison]::OrdinalIgnoreCase)) { $p = $p.Substring(10) }
    $base = $null
    $rest = $null
    $long = ''
    $short = ''
    foreach ($prefix in @('HKEY_LOCAL_MACHINE\', 'HKLM:\', 'HKLM\')) {
        if ($p.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $base = [Microsoft.Win32.RegistryHive]::LocalMachine; $rest = $p.Substring($prefix.Length); $long = 'HKEY_LOCAL_MACHINE'; $short = 'HKLM'; break
        }
    }
    if ($null -eq $base) {
        foreach ($prefix in @('HKEY_USERS\', 'HKU:\', 'HKU\')) {
            if ($p.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $base = [Microsoft.Win32.RegistryHive]::Users; $rest = $p.Substring($prefix.Length); $long = 'HKEY_USERS'; $short = 'HKU'; break
            }
        }
    }
    if ($null -eq $base) { return $null }
    $rest = $rest.Trim('\')
    if ($rest.Length -eq 0 -or $rest.IndexOf('\\') -ge 0) { return $null }
    $first = $rest.Split('\')[0]
    if ($base -eq [Microsoft.Win32.RegistryHive]::LocalMachine -and ($script:LiveHiveNames -contains $first)) { return $null }
    if ($base -eq [Microsoft.Win32.RegistryHive]::Users -and ($first -eq '.DEFAULT' -or $first -like 'S-1-*')) { return $null }
    return [pscustomobject]@{
        BaseHive = $base
        Name     = $rest
        Root     = ('Registry::{0}\{1}' -f $long, $rest)
        Display  = ('{0}\{1}' -f $short, $rest)
    }
}

function Get-LiteOSOfflineMapping {
    # Online HKLM:\ / HKCU:\ path -> where it lives in the loaded offline hives, or $null (deferred).
    # OnlineLogical / OnlinePrefix keep the ONLINE spelling for backups; OfflineSubKey is relative to
    # the base key (HKLM or HKU) of the loaded hive.
    param([string]$Path, [System.Collections.IDictionary]$Hives, [string]$ControlSet = 'ControlSet001')
    $info = Resolve-LiteOSRegistryPath $Path
    if ($null -eq $info) { return $null }
    if ([string]::IsNullOrEmpty($ControlSet) -or $ControlSet -notmatch '^ControlSet\d{3}$') { $ControlSet = 'ControlSet001' }
    $parts = $info.SubKey.Split('\')
    $hiveName = $null
    $skip = 0
    $inner = ''
    if ($info.Root -eq 'HKLM') {
        if ($parts[0] -eq 'SOFTWARE') { $hiveName = 'SOFTWARE'; $skip = 1 }
        elseif ($parts[0] -eq 'SYSTEM') {
            $hiveName = 'SYSTEM'
            $skip = 1
            # CurrentControlSet is a link created at boot; offline it is the ControlSet00N Select\Current names.
            if ($parts.Length -ge 2 -and $parts[1] -eq 'CurrentControlSet') { $skip = 2; $inner = $ControlSet }
        }
        else { return $null }
    }
    else {
        $s = $info.SubKey.ToLowerInvariant()
        # HKCU\Software\Classes lives in UsrClass.dat, not in NTUSER.DAT: applied at first logon.
        if ($s -eq 'software\classes' -or $s.StartsWith('software\classes\')) { return $null }
        $hiveName = 'DEFAULT'
    }
    $hr = ConvertTo-LiteOSHiveRoot ([string](Get-LiteOSHiveValue $Hives $hiveName))
    if ($null -eq $hr) { return $null }
    $onlinePrefix = ''
    for ($i = 0; $i -lt $skip; $i++) { $onlinePrefix += ($parts[$i] + '\') }
    $restList = New-Object -TypeName 'System.Collections.Generic.List[string]'
    for ($i = $skip; $i -lt $parts.Length; $i++) { $restList.Add($parts[$i]) }
    $rest = $restList.ToArray() -join '\'
    $offPrefix = $hr.Name + '\'
    if ($inner) { $offPrefix += ($inner + '\') }
    $offSub = ($offPrefix + $rest).TrimEnd('\')
    $offPath = $hr.Root
    if ($inner) { $offPath += ('\' + $inner) }
    if ($rest) { $offPath += ('\' + $rest) }
    $hive = 'Machine'
    if ($info.Root -eq 'HKCU') { $hive = 'User' }
    $short = 'HKLM\'
    if ($hr.BaseHive -eq [Microsoft.Win32.RegistryHive]::Users) { $short = 'HKU\' }
    return [pscustomobject]@{
        Root           = $info.Root
        Hive           = $hive
        HiveName       = $hiveName
        BaseHive       = $hr.BaseHive
        HiveRoot       = $hr.Root
        OfflinePrefix  = $offPrefix
        Rest           = $rest
        OnlinePrefix   = $onlinePrefix
        OnlineLogical  = $info.SubKey
        OnlinePath     = $info.Path
        OnlineDisplay  = ('{0}\{1}' -f $info.Root, $info.SubKey)
        OfflineSubKey  = $offSub
        OfflineDisplay = ($short + $offSub)
        OfflinePath    = $offPath
    }
}

function ConvertTo-LiteOSOfflinePath {
    <#
    .SYNOPSIS
        Pure: maps an online HKLM:\ / HKCU:\ registry path into the loaded offline image hives
        (a Registry:: path), or returns $null when it cannot be mapped (the action is deferred).
    .DESCRIPTION
        HKLM:\SOFTWARE\X                 -> Registry::HKEY_LOCAL_MACHINE\LITE_SOFTWARE\X
        HKLM:\SYSTEM\CurrentControlSet\X -> Registry::HKEY_LOCAL_MACHINE\LITE_SYSTEM\ControlSet001\X
        HKLM:\SYSTEM\X                   -> Registry::HKEY_LOCAL_MACHINE\LITE_SYSTEM\X
        HKCU:\X                          -> Registry::HKEY_LOCAL_MACHINE\LITE_DEFAULT\X (Default user profile)
        HKCU:\Software\Classes\...       -> $null (UsrClass.dat; applied to the first user at first logon)
        any other root, or a hive missing from -Hives -> $null (applied on the installed system).
        Hive names come from -Hives (e.g. @{ SOFTWARE = 'HKLM\LITE_SOFTWARE'; SYSTEM = 'HKLM\LITE_SYSTEM';
        DEFAULT = 'HKLM\LITE_DEFAULT' }); a hive that names a live hive of this PC (HKLM\SOFTWARE ...)
        is treated as missing. No registry access.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [System.Collections.IDictionary]$Hives,

        [string]$ControlSet = 'ControlSet001'
    )
    $m = Get-LiteOSOfflineMapping -Path $Path -Hives $Hives -ControlSet $ControlSet
    if ($null -eq $m) { return $null }
    return [string]$m.OfflinePath
}

function Get-LiteOSOfflineDisposition {
    <#
    .SYNOPSIS
        Pure: how Invoke-LiteOSOfflinePlan handles one action.
    .OUTPUTS
        {Type; Mode = offline|deferred|invalid; Scope = Machine|User; OfflinePath; Reason}.
        Deferred Machine actions run in SetupComplete (SYSTEM, before the first sign-in), deferred
        User actions at the first logon for the signed-in user.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Action,

        [AllowNull()]
        [System.Collections.IDictionary]$Hives,

        [string]$ControlSet = 'ControlSet001'
    )
    if ([string]::IsNullOrEmpty($ControlSet) -or $ControlSet -notmatch '^ControlSet\d{3}$') { $ControlSet = 'ControlSet001' }
    $type = Get-LiteOSCanonical (Get-LiteOSProp $Action 'type') $script:ActionTypes
    $scope = 'Machine'
    if (Test-LiteOSUserAction $Action) { $scope = 'User' }
    $mode = 'deferred'
    $path = $null
    $reason = ''
    if ($type -eq 'registry' -or $type -eq 'registry-delete') {
        $rp = [string](Get-LiteOSProp $Action 'path' '')
        $m = Get-LiteOSOfflineMapping -Path $rp -Hives $Hives -ControlSet $ControlSet
        if ($null -ne $m) { $mode = 'offline'; $path = $m.OfflinePath; $reason = 'written into the offline image hive' }
        else {
            $info = Resolve-LiteOSRegistryPath $rp
            if ($null -eq $info) { $mode = 'invalid'; $reason = ('bad registry path {0}' -f $rp) }
            elseif ($info.Root -eq 'HKCU') {
                $s = $info.SubKey.ToLowerInvariant()
                if ($s -eq 'software\classes' -or $s.StartsWith('software\classes\')) { $reason = 'HKCU:\Software\Classes lives in UsrClass.dat, not in the Default profile hive; applied to the user at first logon' }
                else { $reason = 'the Default profile hive is not loaded; applied at first logon' }
            }
            else { $reason = 'no offline hive for this registry root; applied by SetupComplete' }
        }
    }
    elseif ($type -eq 'service') {
        $hr = ConvertTo-LiteOSHiveRoot ([string](Get-LiteOSHiveValue $Hives 'SYSTEM'))
        if ($null -ne $hr) {
            $mode = 'offline'
            $path = '{0}\{1}\Services\{2}' -f $hr.Root, $ControlSet, [string](Get-LiteOSProp $Action 'name' '')
            $reason = 'start type written into the offline SYSTEM hive'
        }
        else { $reason = 'the SYSTEM hive is not loaded; applied by SetupComplete' }
    }
    elseif ($type -eq 'task') {
        $reason = 'scheduled tasks are changed by SetupComplete on the installed system'
    }
    elseif ($type -eq 'powershell') {
        if ($scope -eq 'User') {
            $hr = ConvertTo-LiteOSHiveRoot ([string](Get-LiteOSHiveValue $Hives 'DEFAULT'))
            if ($null -ne $hr) { $mode = 'offline'; $path = $hr.Root; $reason = 'per-user script runs against the Default profile hive' }
            else { $reason = 'the Default profile hive is not loaded; runs at first logon' }
        }
        else { $reason = 'machine scripts need the running system; run by SetupComplete' }
    }
    elseif ($type -eq 'appx-remove') {
        # DISM must load the image's SOFTWARE hive itself to service provisioned apps; while the
        # caller has the offline hives loaded that fails with a sharing violation (0x80070020). So with
        # hives in use the removal runs on the installed system (SetupComplete, -Online) instead. The
        # builder removes appx-only tweaks itself before it loads the hives, so this is a safety net.
        $hivesInUse = $false
        if ($null -ne $Hives) {
            foreach ($hn in @('SOFTWARE', 'SYSTEM', 'DEFAULT')) {
                if (-not [string]::IsNullOrWhiteSpace([string](Get-LiteOSHiveValue $Hives $hn))) { $hivesInUse = $true }
            }
        }
        if ($hivesInUse) {
            $reason = 'provisioned apps cannot be serviced while the offline hives are loaded (DISM sharing violation); removed by SetupComplete on the installed system'
        }
        else {
            $mode = 'offline'
            $reason = 'Remove-AppxProvisionedPackage -Path <mount>'
        }
    }
    else {
        $mode = 'invalid'
        $reason = ("unknown action type '{0}'" -f (Get-LiteOSProp $Action 'type'))
    }
    return [pscustomobject]@{ Type = $type; Mode = $mode; Scope = $scope; OfflinePath = $path; Reason = $reason }
}

function Test-LiteOSHiveLoaded {
    param($HiveRoot)
    if ($null -eq $HiveRoot) { return $false }
    $base = Open-LiteOSBaseKey $HiveRoot.BaseHive
    try {
        $k = $base.OpenSubKey($HiveRoot.Name, $false)
        if ($null -eq $k) { return $false }
        $k.Close()
        return $true
    }
    finally { $base.Close() }
}

function Get-LiteOSOfflineHiveState {
    # Which of the given hives are usable now. Throws when a hive names a live hive of this PC.
    # In a dry run, configured hives count as usable even when they are not loaded (reads then
    # simply find nothing), so -WhatIf previews work without a mounted image.
    param([System.Collections.IDictionary]$Hives, [bool]$DryRun)
    $usable = @{}
    $notes = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($name in @('SOFTWARE', 'SYSTEM', 'DEFAULT')) {
        $v = [string](Get-LiteOSHiveValue $Hives $name)
        if ([string]::IsNullOrWhiteSpace($v)) { $notes.Add(('no {0} hive given; its actions are deferred' -f $name)); continue }
        $hr = ConvertTo-LiteOSHiveRoot $v
        if ($null -eq $hr) {
            throw ("-Hives {0} = '{1}' is not an offline hive (expected something like HKLM\LITE_{0}); live hives of this PC are refused" -f $name, $v)
        }
        if (-not (Test-LiteOSHiveLoaded $hr)) {
            if (-not $DryRun) { $notes.Add(('hive {0} ({1}) is not loaded; its actions are deferred' -f $name, $hr.Display)); continue }
            $notes.Add(('hive {0} ({1}) is not loaded (dry run: values read as absent)' -f $name, $hr.Display))
        }
        $usable[$name] = $hr.Display
    }
    $controlSet = 'ControlSet001'
    $sysRoot = ConvertTo-LiteOSHiveRoot ([string](Get-LiteOSHiveValue $usable 'SYSTEM'))
    if ($null -ne $sysRoot) {
        try {
            $base = Open-LiteOSBaseKey $sysRoot.BaseHive
            try {
                $k = $base.OpenSubKey($sysRoot.Name + '\Select', $false)
                if ($null -ne $k) {
                    try {
                        $cur = $k.GetValue('Current', $null)
                        if ($null -ne $cur -and [int]$cur -ge 1 -and [int]$cur -le 999) {
                            $cand = 'ControlSet{0:D3}' -f [int]$cur
                            $ck = $base.OpenSubKey($sysRoot.Name + '\' + $cand, $false)
                            if ($null -ne $ck) { $ck.Close(); $controlSet = $cand }
                        }
                    }
                    finally { $k.Close() }
                }
            }
            finally { $base.Close() }
        }
        catch { $notes.Add(('could not read Select\Current from the SYSTEM hive ({0}); using ControlSet001' -f $_.Exception.Message)) }
    }
    return [pscustomobject]@{ Usable = $usable; ControlSet = $controlSet; Notes = $notes.ToArray() }
}

function Get-LiteOSOfflineImageInfo {
    # Read-only: build / UBR / edition from the offline SOFTWARE hive (zeros / '' when unavailable).
    param([System.Collections.IDictionary]$Hives)
    $o = [pscustomobject]@{ Build = 0; UBR = 0; EditionID = ''; DisplayVersion = '' }
    $hr = ConvertTo-LiteOSHiveRoot ([string](Get-LiteOSHiveValue $Hives 'SOFTWARE'))
    if ($null -eq $hr) { return $o }
    try {
        $base = Open-LiteOSBaseKey $hr.BaseHive
        try {
            $k = $base.OpenSubKey($hr.Name + '\Microsoft\Windows NT\CurrentVersion', $false)
            if ($null -ne $k) {
                try {
                    $b = 0
                    if ([int]::TryParse([string]$k.GetValue('CurrentBuildNumber', ''), [ref]$b)) { $o.Build = $b }
                    $u = $k.GetValue('UBR', $null)
                    if ($null -ne $u) { $o.UBR = [int]$u }
                    $o.EditionID = [string]$k.GetValue('EditionID', '')
                    $o.DisplayVersion = [string]$k.GetValue('DisplayVersion', '')
                }
                finally { $k.Close() }
            }
        }
        finally { $base.Close() }
    }
    catch { Write-LiteOSLog -NoConsole -Level Warn ('Could not read the image version from the offline SOFTWARE hive: {0}' -f $_.Exception.Message) }
    return $o
}

function Get-LiteOSOfflineTarget {
    # Mapping -> target object for the registry primitives (Get-LiteOSRegistryValueState, ...).
    param($Mapping)
    return [pscustomobject]@{
        BaseHive      = $Mapping.BaseHive
        Prefix        = $Mapping.OfflinePrefix
        Logical       = $Mapping.Rest
        SubKey        = $Mapping.OfflineSubKey
        Display       = $Mapping.OfflineDisplay
        Root          = $Mapping.Root
        Hive          = $Mapping.Hive
        OnlinePrefix  = $Mapping.OnlinePrefix
        OnlineLogical = $Mapping.OnlineLogical
        OnlineDisplay = $Mapping.OnlineDisplay
    }
}

function Get-LiteOSOfflineMissingKeys {
    # Keys that would be created, in ONLINE logical form (relative to HKLM / HKCU) for the backup.
    param($Target)
    $list = New-Object -TypeName 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrEmpty($Target.Logical)) { return , ($list.ToArray()) }
    # Get-LiteOSMissingKeys returns one wrapped array: assign it (do not wrap the call in @()).
    $rel = Get-LiteOSMissingKeys $Target
    foreach ($k in $rel) {
        if (-not [string]::IsNullOrEmpty($k)) { $list.Add($Target.OnlinePrefix + $k) }
    }
    return , ($list.ToArray())
}

function Invoke-LiteOSOfflineRegistryAction {
    param($Context, [string]$TweakId, $Action, $State, [bool]$DryRun)
    $m = Get-LiteOSOfflineMapping -Path ([string]$Action.path) -Hives $State.Usable -ControlSet $State.ControlSet
    if ($null -eq $m) { throw ('{0} cannot be mapped into the offline image' -f $Action.path) }
    $target = Get-LiteOSOfflineTarget $m
    $name = [string](Get-LiteOSProp $Action 'name' '')
    $kind = [string]$Action.kind
    $value = Get-LiteOSPropRaw $Action 'value'
    $label = '[{0}] {1}\{2}' -f $m.Hive, $target.Display, $(if ($name -eq '') { '(Default)' } else { $name })
    $shown = Format-LiteOSRegistryValue $kind $value
    $state = Get-LiteOSRegistryValueState -Target $target -Name $name
    if ($state.Exists -and $state.Kind -eq $kind -and (Test-LiteOSRegistryDataEqual $kind $state.Value $value)) {
        return (ConvertTo-LiteOSOutcome 'unchanged' ('{0} already {1}' -f $label, $shown))
    }
    $was = '(absent)'
    if ($state.Exists) { $was = '{0} ({1})' -f (Format-LiteOSRegistryValue $state.Kind $state.Value), $state.Kind }
    if ($DryRun) { return (ConvertTo-LiteOSOutcome 'applied' ('WhatIf: would set {0} = {1} ({2}); now {3}' -f $label, $shown, $kind, $was)) }
    $created = Get-LiteOSOfflineMissingKeys $target
    $stored = $null
    if ($state.Exists) { $stored = (ConvertTo-LiteOSStoredValue $state.Kind $state.Value).Value }
    $before = [ordered]@{
        exists      = [bool]$state.Exists
        kind        = $state.Kind
        value       = $stored
        createdKeys = @($created)
        target      = $target.OnlineDisplay
    }
    Add-LiteOSBackupEntry -Context $Context -TweakId $TweakId -Action $Action -Hive $m.Hive -Before $before
    Write-LiteOSRegistryValue -Target $target -Name $name -Kind $kind -Value $value
    return (ConvertTo-LiteOSOutcome 'applied' ('{0} = {1} ({2}); was {3}' -f $label, $shown, $kind, $was))
}

function Invoke-LiteOSOfflineRegistryDeleteAction {
    param($Context, [string]$TweakId, $Action, $State, [bool]$DryRun)
    $m = Get-LiteOSOfflineMapping -Path ([string]$Action.path) -Hives $State.Usable -ControlSet $State.ControlSet
    if ($null -eq $m) { throw ('{0} cannot be mapped into the offline image' -f $Action.path) }
    $target = Get-LiteOSOfflineTarget $m
    if (Test-LiteOSProp $Action 'name') {
        $name = [string]$Action.name
        $label = '[{0}] {1}\{2}' -f $m.Hive, $target.Display, $(if ($name -eq '') { '(Default)' } else { $name })
        $state = Get-LiteOSRegistryValueState -Target $target -Name $name
        if (-not $state.Exists) { return (ConvertTo-LiteOSOutcome 'unchanged' ('{0} already absent' -f $label)) }
        if ($DryRun) { return (ConvertTo-LiteOSOutcome 'applied' ('WhatIf: would delete value {0}' -f $label)) }
        $before = [ordered]@{
            exists = $true
            kind   = $state.Kind
            value  = (ConvertTo-LiteOSStoredValue $state.Kind $state.Value).Value
            target = $target.OnlineDisplay
        }
        Add-LiteOSBackupEntry -Context $Context -TweakId $TweakId -Action $Action -Hive $m.Hive -Before $before
        [void](Clear-LiteOSRegistryValue -Target $target -Name $name)
        return (ConvertTo-LiteOSOutcome 'applied' ('deleted value {0}' -f $label))
    }
    if ([string]::IsNullOrEmpty($m.Rest) -or (Test-LiteOSCriticalKey $m.OnlineLogical)) {
        throw ('refusing to delete critical key {0}' -f $m.OnlineDisplay)
    }
    $label = '[{0}] {1}' -f $m.Hive, $target.Display
    $base = Open-LiteOSBaseKey $target.BaseHive
    try {
        $key = $base.OpenSubKey($target.SubKey, $false)
        if ($null -eq $key) { return (ConvertTo-LiteOSOutcome 'unchanged' ('{0} already absent' -f $label)) }
        $tree = $null
        try {
            if ($DryRun) { return (ConvertTo-LiteOSOutcome 'applied' ('WhatIf: would delete key {0} ({1} values, {2} sub keys)' -f $label, $key.ValueCount, $key.SubKeyCount)) }
            $tree = Export-LiteOSRegistryTree -Key $key
        }
        finally { $key.Close() }
        $before = [ordered]@{ existed = $true; tree = $tree; target = $target.OnlineDisplay }
        Add-LiteOSBackupEntry -Context $Context -TweakId $TweakId -Action $Action -Hive $m.Hive -Before $before
        $base.DeleteSubKeyTree($target.SubKey, $false)
    }
    finally { $base.Close() }
    return (ConvertTo-LiteOSOutcome 'applied' ('deleted key {0}' -f $label))
}

function Invoke-LiteOSOfflineServiceAction {
    # Start (+ DelayedAutostart) of <SYSTEM>\ControlSet00N\Services\<name>. 'stop' has no meaning offline.
    param($Context, [string]$TweakId, $Action, $State, [bool]$DryRun)
    $hr = ConvertTo-LiteOSHiveRoot ([string](Get-LiteOSHiveValue $State.Usable 'SYSTEM'))
    if ($null -eq $hr) { throw 'the offline SYSTEM hive is not available' }
    $name = [string]$Action.name
    $startup = [string]$Action.startup
    $sub = '{0}\{1}\Services\{2}' -f $hr.Name, $State.ControlSet, $name
    $base = Open-LiteOSBaseKey $hr.BaseHive
    try {
        $k = $base.OpenSubKey($sub, $false)
        if ($null -eq $k) { return (ConvertTo-LiteOSOutcome 'skipped' ('service {0} is not in the image' -f $name)) }
        $start = $null
        $delayed = $null
        try {
            $start = $k.GetValue('Start', $null)
            $d = $k.GetValue('DelayedAutostart', $null)
            if ($null -ne $d) { $delayed = [int]$d }
        }
        finally { $k.Close() }
        if ($null -eq $start) { return (ConvertTo-LiteOSOutcome 'skipped' ('service {0} has no Start value in the image' -f $name)) }
        $cfg = [pscustomobject]@{ Name = $name; Start = [int]$start; Delayed = $delayed }
        $spec = Get-LiteOSStartupSpec $startup
        $current = Get-LiteOSStartupName $cfg.Start $cfg.Delayed
        if (Test-LiteOSServiceConfigMatch $cfg $spec.Start $spec.Delayed) {
            return (ConvertTo-LiteOSOutcome 'unchanged' ('service {0} already {1} in the image' -f $name, $startup))
        }
        if ($DryRun) { return (ConvertTo-LiteOSOutcome 'applied' ('WhatIf: would set service {0} startup {1} in the image (now {2})' -f $name, $startup, $current)) }
        $before = [ordered]@{ start = $cfg.Start; delayed = $cfg.Delayed; startType = $current; status = '' }
        Add-LiteOSBackupEntry -Context $Context -TweakId $TweakId -Action $Action -Hive 'Machine' -Before $before
        $w = $base.OpenSubKey($sub, $true)
        if ($null -eq $w) { throw ('cannot open HKLM\{0} for writing' -f $sub) }
        try {
            $w.SetValue('Start', [int32]$spec.Start, [Microsoft.Win32.RegistryValueKind]::DWord)
            if ($spec.Start -eq 2 -and $null -ne $spec.Delayed) {
                $w.SetValue('DelayedAutostart', [int32]$spec.Delayed, [Microsoft.Win32.RegistryValueKind]::DWord)
            }
        }
        finally { $w.Close() }
        return (ConvertTo-LiteOSOutcome 'applied' ('service {0}: {1} -> {2} (offline image)' -f $name, $current, $startup))
    }
    finally { $base.Close() }
}

function Invoke-LiteOSOfflineScriptAction {
    # perUser PowerShell action against the offline Default profile hive. $env:ProgramData points
    # at <mount>\ProgramData while it runs, so its state file (prev-*-Default.txt) ships in the image
    # and the undo finds it as C:\ProgramData\LiteOS\... on the installed system.
    param($Context, [string]$TweakId, $Action, $State, [bool]$DryRun)
    $hr = ConvertTo-LiteOSHiveRoot ([string](Get-LiteOSHiveValue $State.Usable 'DEFAULT'))
    if ($null -eq $hr) { throw 'the offline Default profile hive is not available' }
    $text = [string]$Action.script
    $undo = Get-LiteOSProp $Action 'undo'
    if ($DryRun) { return (ConvertTo-LiteOSOutcome 'applied' ('[User] WhatIf: would run a per-user PowerShell script against the Default profile hive ({0} chars)' -f $text.Length)) }
    $before = [ordered]@{ undo = $undo; hiveTag = 'Default' }
    $mark = -1
    if ($null -ne $Context.BackupEntries) { $mark = $Context.BackupEntries.Count }
    Add-LiteOSBackupEntry -Context $Context -TweakId $TweakId -Action $Action -Hive 'User' -Before $before
    $pdOld = [System.Environment]::GetEnvironmentVariable('ProgramData', 'Process')
    $r = $null
    try {
        [System.Environment]::SetEnvironmentVariable('ProgramData', (Join-Path $State.MountPath 'ProgramData'), 'Process')
        $r = Invoke-LiteOSScriptText -Text $text -Variables ([ordered]@{ LiteOSUserRoot = $hr.Root; LiteOSHiveTag = 'Default' })
    }
    finally {
        [System.Environment]::SetEnvironmentVariable('ProgramData', $pdOld, 'Process')
    }
    $verdict = Get-LiteOSScriptVerdict $r.Raw
    if ($null -ne $verdict) {
        if ($mark -ge 0 -and $null -ne $Context.BackupEntries -and $Context.BackupEntries.Count -eq ($mark + 1)) {
            $Context.BackupEntries.RemoveAt($mark)
            Save-LiteOSBackup $Context
        }
        return (ConvertTo-LiteOSOutcome $verdict.Status ('[User] ' + $verdict.Message))
    }
    $msg = '[User] script ran against the Default profile hive'
    if ($r.Output) { $msg += (': ' + $r.Output) }
    if ($r.ExitCode -ne 0) { $msg += (' (note: last native exit code {0})' -f $r.ExitCode) }
    return (ConvertTo-LiteOSOutcome 'applied' $msg)
}

function Invoke-LiteOSOfflineAppxAction {
    # Remove-AppxProvisionedPackage -Path <mount>; the protected list is always enforced.
    param($Context, [string]$TweakId, $Action, $State, [bool]$DryRun)
    if ($null -eq $Context.ProtectedApps) { $Context.ProtectedApps = @(Get-LiteOSProtectedApps -Path $Context.TweaksPath) }
    $protected = @($Context.ProtectedApps)
    foreach ($pattern in @(Get-LiteOSProp $Action 'packages' @())) {
        $pattern = [string]$pattern
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        $c = Get-LiteOSProtectedConflict -Pattern $pattern -Protected $protected
        if ($null -ne $c.Blocked) {
            Write-LiteOSLog -NoConsole -Level Warn ('{0}: refused to remove protected package {1}' -f $TweakId, $pattern)
            ConvertTo-LiteOSOutcome 'skipped' ('refused: {0} is protected' -f $pattern)
            continue
        }
        if (-not $State.Mounted) {
            if ($DryRun) { ConvertTo-LiteOSOutcome 'applied' ('WhatIf: would remove provisioned packages matching {0} (image not mounted, not listed)' -f $pattern); continue }
            throw ('no mounted image at {0}' -f $State.MountPath)
        }
        if ($null -eq $State.Provisioned) {
            $l = New-Object -TypeName 'System.Collections.Generic.List[object]'
            foreach ($p in @(Get-AppxProvisionedPackage -Path $State.MountPath -ErrorAction Stop)) {
                $l.Add([pscustomobject]@{ DisplayName = [string]$p.DisplayName; PackageName = [string]$p.PackageName })
            }
            $State.Provisioned = $l
        }
        $hits = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $refused = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($p in $State.Provisioned) {
            if (-not ($p.DisplayName -like $pattern)) { continue }
            if (Test-LiteOSProtectedApp -Name $p.DisplayName -Protected $protected) { if (-not $refused.Contains($p.DisplayName)) { $refused.Add($p.DisplayName) }; continue }
            $hits.Add($p)
        }
        if ($refused.Count -gt 0) { Write-LiteOSLog -NoConsole -Level Warn ('{0}: skipped protected packages: {1}' -f $TweakId, ($refused -join ', ')) }
        if ($hits.Count -eq 0) { ConvertTo-LiteOSOutcome 'skipped' ('{0} is not provisioned in the image' -f $pattern); continue }
        $names = @($hits | ForEach-Object { $_.DisplayName } | Select-Object -Unique)
        if ($DryRun) { ConvertTo-LiteOSOutcome 'applied' ('WhatIf: would remove {0} from the image' -f ($names -join ', ')); continue }
        $removed = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $failed = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($p in @($hits.ToArray())) {
            try {
                $null = Remove-AppxProvisionedPackage -Path $State.MountPath -PackageName $p.PackageName -ErrorAction Stop
                $removed.Add([pscustomobject]([ordered]@{ name = $p.DisplayName; fullName = $p.PackageName; familyName = ''; provisioned = $true }))
                [void]$State.Provisioned.Remove($p)
            }
            catch { $failed.Add(('{0}: {1}' -f $p.PackageName, (Format-LiteOSShort $_.Exception.Message 120))) }
        }
        if ($removed.Count -gt 0) {
            Add-LiteOSBackupEntry -Context $Context -TweakId $TweakId -Action $Action -Hive 'Machine' -Before ([ordered]@{ removed = $removed.ToArray() })
            ConvertTo-LiteOSOutcome 'applied' ('removed {0} from the image' -f (($removed | ForEach-Object { $_.name } | Select-Object -Unique) -join ', '))
        }
        if ($failed.Count -gt 0) { ConvertTo-LiteOSOutcome 'failed' ('could not remove: {0}' -f ($failed -join '; ')) }
    }
}

function Invoke-LiteOSOfflineAction {
    param($Context, [string]$TweakId, $Action, [string]$Type, $State, [bool]$DryRun)
    switch ($Type) {
        'registry'        { return (Invoke-LiteOSOfflineRegistryAction -Context $Context -TweakId $TweakId -Action $Action -State $State -DryRun $DryRun) }
        'registry-delete' { return (Invoke-LiteOSOfflineRegistryDeleteAction -Context $Context -TweakId $TweakId -Action $Action -State $State -DryRun $DryRun) }
        'service'         { return (Invoke-LiteOSOfflineServiceAction -Context $Context -TweakId $TweakId -Action $Action -State $State -DryRun $DryRun) }
        'powershell'      { return (Invoke-LiteOSOfflineScriptAction -Context $Context -TweakId $TweakId -Action $Action -State $State -DryRun $DryRun) }
        'appx-remove'     { return (Invoke-LiteOSOfflineAppxAction -Context $Context -TweakId $TweakId -Action $Action -State $State -DryRun $DryRun) }
    }
    throw ("action type '{0}' cannot be applied offline" -f $Type)
}

function New-LiteOSDeferredTweak {
    param($Tweak, [object[]]$Actions)
    $min = Get-LiteOSProp $Tweak 'minBuild'
    $max = Get-LiteOSProp $Tweak 'maxBuild'
    return [pscustomobject]([ordered]@{
            id       = [string](Get-LiteOSProp $Tweak 'id' '')
            name     = [string](Get-LiteOSProp $Tweak 'name' (Get-LiteOSProp $Tweak 'id' ''))
            category = [string](Get-LiteOSProp $Tweak 'category' '')
            level    = [string](Get-LiteOSProp $Tweak 'level' '')
            reboot   = (ConvertTo-LiteOSBool (Get-LiteOSProp $Tweak 'reboot' $false))
            minBuild = $min
            maxBuild = $max
            actions  = @($Actions)
        })
}

function Invoke-LiteOSOfflineTweak {
    # One tweak into the image. Returns the result object; appends deferred actions to $Deferred.
    param($Tweak, $Context, $State, [int]$Build, [bool]$DryRun, $Deferred)
    $id = [string](Get-LiteOSProp $Tweak 'id' '(no id)')
    $result = [pscustomobject]@{
        id       = $id
        name     = [string](Get-LiteOSProp $Tweak 'name' $id)
        category = [string](Get-LiteOSProp $Tweak 'category' '')
        status   = 'skipped'
        message  = ''
        reboot   = $false
        whatIf   = $DryRun
        changes  = 0
        deferred = 0
        details  = @()
    }
    $outcomes = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $later = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $actions = @(Get-LiteOSProp $Tweak 'actions' @())
    if ($Build -gt 0 -and -not (Test-LiteOSBuildRange -Tweak $Tweak -Build $Build)) {
        $maxText = 'any'
        if ((Get-LiteOSBuildBound $Tweak 'maxBuild') -gt 0) { $maxText = [string](Get-LiteOSBuildBound $Tweak 'maxBuild') }
        $outcomes.Add((ConvertTo-LiteOSOutcome 'skipped' ('not for this image build ({0}; needs {1} to {2})' -f $Build, (Get-LiteOSBuildBound $Tweak 'minBuild'), $maxText)))
    }
    elseif ($actions.Count -eq 0) { $outcomes.Add((ConvertTo-LiteOSOutcome 'skipped' 'no actions')) }
    else {
        foreach ($a in $actions) {
            $d = Get-LiteOSOfflineDisposition -Action $a -Hives $State.Usable -ControlSet $State.ControlSet
            $where = 'SetupComplete'
            if ($d.Scope -eq 'User') { $where = 'first logon' }
            if ($d.Mode -eq 'invalid') { $outcomes.Add((ConvertTo-LiteOSOutcome 'failed' $d.Reason)); continue }
            if ($d.Mode -eq 'deferred') {
                $later.Add($a)
                $outcomes.Add((ConvertTo-LiteOSOutcome 'deferred' ('{0} [{1}] deferred to {2}: {3}' -f $d.Type, $d.Scope, $where, $d.Reason)))
                continue
            }
            try {
                foreach ($o in @(Invoke-LiteOSOfflineAction -Context $Context -TweakId $id -Action $a -Type $d.Type -State $State -DryRun $DryRun)) {
                    if ($null -ne $o) { $outcomes.Add($o) }
                }
            }
            catch {
                $em = Format-LiteOSShort $_.Exception.Message 160
                if (-not $DryRun -and $d.Type -ne 'appx-remove') {
                    # The running system (SYSTEM in SetupComplete / the user at first logon) gets a
                    # second chance: e.g. a key whose ACL lets SYSTEM but not the builder write.
                    $later.Add($a)
                    $outcomes.Add((ConvertTo-LiteOSOutcome 'deferred' ('{0} [{1}] could not be applied offline ({2}); deferred to {3}' -f $d.Type, $d.Scope, $em, $where)))
                    Write-LiteOSLog -NoConsole -Level Warn ('{0}: {1} could not be applied offline ({2}); deferred to {3}' -f $id, $d.Type, $em, $where)
                }
                else {
                    $outcomes.Add((ConvertTo-LiteOSOutcome 'failed' ('{0} [{1}]: {2}' -f $d.Type, $d.Scope, $em)))
                }
            }
        }
    }
    if ($later.Count -gt 0) { $Deferred.Add((New-LiteOSDeferredTweak -Tweak $Tweak -Actions $later.ToArray())) }

    $nApplied = @($outcomes | Where-Object { $_.status -eq 'applied' }).Count
    $nSame = @($outcomes | Where-Object { $_.status -eq 'unchanged' }).Count
    $nSkip = @($outcomes | Where-Object { $_.status -eq 'skipped' }).Count
    $nFail = @($outcomes | Where-Object { $_.status -eq 'failed' }).Count
    $nLater = @($outcomes | Where-Object { $_.status -eq 'deferred' }).Count
    $result.changes = $nApplied
    $result.deferred = $nLater
    $result.details = @($outcomes | ForEach-Object { '{0}: {1}' -f $_.status, $_.message })
    if ($nFail -gt 0) {
        $result.status = 'failed'
        $result.message = (@($outcomes | Where-Object { $_.status -eq 'failed' } | ForEach-Object { $_.message }) -join '; ')
        if ($nApplied -gt 0) { $result.message = ('{0} of {1} changes made; ' -f $nApplied, ($nApplied + $nFail)) + $result.message }
    }
    elseif ($nApplied -eq 0 -and $nSame -eq 0 -and $nLater -gt 0) {
        $result.status = 'deferred'
        $result.message = ('{0} action(s) run on the installed system (SetupComplete / first logon)' -f $nLater)
    }
    elseif ($nApplied -eq 0 -and $nSame -eq 0) {
        $result.status = 'skipped'
        $result.message = (@($outcomes | ForEach-Object { $_.message }) -join '; ')
    }
    else {
        $result.status = 'applied'
        if ($nApplied -eq 0) { $result.message = 'already set in the image' }
        elseif ($DryRun) { $result.message = ('would make {0} change(s) in the image' -f $nApplied) }
        else { $result.message = ('{0} change(s) in the image' -f $nApplied) }
        if ($nLater -gt 0) { $result.message += ('; {0} deferred to the installed system' -f $nLater) }
        if ($nSkip -gt 0) { $result.message += ('; {0} not applicable' -f $nSkip) }
    }
    $lvl = 'Info'
    if ($result.status -eq 'failed') { $lvl = 'Error' } elseif ($result.status -eq 'applied' -and $nApplied -gt 0) { $lvl = 'Success' }
    Write-LiteOSLog -NoConsole -Level $lvl ('IMAGE {0} {1}: {2}' -f $result.status.ToUpperInvariant(), $id, $result.message)
    foreach ($o in $outcomes) { Write-LiteOSLog -NoConsole -Level Debug ('    {0}: {1}' -f $o.status, $o.message) }
    return $result
}

function Invoke-LiteOSOfflinePlan {
    <#
    .SYNOPSIS
        Bakes tweaks into a mounted Windows image. Returns @{ Results = result[]; Deferred = deferred-tweak[] }.
    .DESCRIPTION
        The CALLER (the builder) mounts the image and loads its hives, e.g.
        -Hives @{ SOFTWARE = 'HKLM\LITE_SOFTWARE'; SYSTEM = 'HKLM\LITE_SYSTEM'; DEFAULT = 'HKLM\LITE_DEFAULT' },
        and unloads them afterwards (this function closes every handle and runs the garbage collector
        before it returns, so the hives can be unloaded).

        - registry / registry-delete: written into the loaded hives (HKLM:\SYSTEM\CurrentControlSet ->
          ControlSet00N from SYSTEM\Select\Current, normally ControlSet001; HKCU:\ -> Default profile).
        - service: Start (+ DelayedAutostart) in <SYSTEM>\ControlSet00N\Services\<name>; missing -> skipped.
        - powershell perUser: runs now with $LiteOSUserRoot = the Default hive, $LiteOSHiveTag = 'Default'
          and $env:ProgramData = <mount>\ProgramData (state files ship inside the image).
        - appx-remove: Remove-AppxProvisionedPackage -Path <mount> (protected list enforced) only when no
          offline hive is in use; with hives loaded DISM cannot service provisioned apps, so the action
          is deferred to SetupComplete (online removal). The builder removes apps before loading hives.
        - task, machine powershell, HKCU:\Software\Classes and unmappable roots: deferred (returned in
          Deferred; write them with Export-LiteOSDeferred to <mount>\LiteOS\deferred.json). A registry,
          service or script action that fails offline is deferred too (second chance on the real system).
        minBuild / maxBuild are checked against the IMAGE build: -Build, else $Context.ImageBuild, else
        CurrentBuildNumber of the offline SOFTWARE hive.

        Every change records its before value with the ONLINE path (HKLM:\... hive 'Machine',
        HKCU:\... hive 'User') in -BackupPath (default <mount>\ProgramData\LiteOS\backup\backup-image.json,
        written incrementally, same schema as playbook backups plus "source": "image"), so
        Revert-LiteOS.ps1 on the installed system can undo baked tweaks. -WhatIf changes nothing.
        Result status: applied | skipped | failed | deferred (all actions run on the installed system).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Tweaks,

        [Parameter(Mandatory = $true)]
        [string]$MountPath,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Hives,

        [string]$BackupPath,

        $Context,

        [int]$Build = 0,

        [switch]$Quiet
    )
    if ($null -eq $Context) { $Context = Get-LiteOSBlankContext -DryRun ([bool]$WhatIfPreference) }
    $list = @($Tweaks | Where-Object { $null -ne $_ })
    $dry = [bool]$Context.WhatIf
    if (-not $dry) {
        if (-not $PSCmdlet.ShouldProcess(('{0} tweak(s) into the image at {1}' -f $list.Count, $MountPath), 'Apply Lite OS tweaks offline')) { $dry = $true }
    }

    # Safety: never treat the running Windows installation as the image.
    $full = ''
    try { $full = [System.IO.Path]::GetFullPath($MountPath).TrimEnd('\') } catch { throw ('Bad -MountPath {0}: {1}' -f $MountPath, $_.Exception.Message) }
    $liveWin = [string]$env:SystemRoot
    if ($liveWin -and [string]::Equals(($full + '\Windows'), $liveWin.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('Refusing to treat {0} as an offline image: it is the running Windows installation.' -f $MountPath)
    }
    $mounted = [System.IO.Directory]::Exists((Join-Path ($full + '\') 'Windows'))
    if (-not $mounted -and -not $dry) { throw ('No mounted Windows image at {0} (Windows folder missing).' -f $MountPath) }
    if ([string]::IsNullOrEmpty($BackupPath)) { $BackupPath = Join-Path ($full + '\') 'ProgramData\LiteOS\backup\backup-image.json' }

    $hs = Get-LiteOSOfflineHiveState -Hives $Hives -DryRun $dry
    foreach ($n in $hs.Notes) { Write-LiteOSLog -NoConsole -Level Warn ('offline plan: ' + $n) }
    $img = Get-LiteOSOfflineImageInfo -Hives $hs.Usable

    $imageBuild = $Build
    $buildFrom = '-Build'
    if ($imageBuild -le 0) {
        $cb = 0
        try { $cb = [int](Get-LiteOSProp $Context 'ImageBuild' 0) } catch { $cb = 0 }
        if ($cb -gt 0) { $imageBuild = $cb; $buildFrom = 'context ImageBuild' }
    }
    if ($imageBuild -le 0 -and $img.Build -gt 0) { $imageBuild = $img.Build; $buildFrom = 'offline SOFTWARE hive' }
    if ($imageBuild -le 0) {
        $imageBuild = [int]$Context.Build
        $buildFrom = 'this PC (image build unknown)'
        Write-LiteOSLog -Level Warn ('The image build is unknown; minBuild/maxBuild are checked against this PC (build {0}).' -f $imageBuild)
    }

    $state = [pscustomobject]@{
        MountPath   = $full
        Mounted     = $mounted
        Usable      = $hs.Usable
        ControlSet  = $hs.ControlSet
        Provisioned = $null
    }
    $edition = [string]$img.EditionID
    $header = [ordered]@{
        source   = 'image'
        mode     = [string](Get-LiteOSProp $Context 'Mode' '')
        build    = $imageBuild
        ubr      = $img.UBR
        edition  = $edition
        # The backup ships inside the image: never the build PC's name or account.
        computer = ''
        user     = ''
        userSid  = ''
    }
    Write-LiteOSLog -NoConsole ('Offline plan: {0} tweak(s) into {1}, image build {2} ({3}), {4}, dry-run {5}, hives [{6}]' -f $list.Count, $full, $imageBuild, $buildFrom, $hs.ControlSet, $dry, ((@($hs.Usable.Keys) | Sort-Object | ForEach-Object { '{0}={1}' -f $_, $hs.Usable[$_] }) -join ', '))

    $results = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $deferred = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $saved = [pscustomobject]@{ File = $Context.BackupFile; Entries = $Context.BackupEntries; Header = $Context.BackupHeader; Last = $Context.LastBackupFile }
    $Context.BackupFile = $null
    $Context.BackupEntries = $null
    $Context.BackupHeader = $null
    $written = $null
    try {
        if (-not $dry) { Open-LiteOSBackup -Context $Context -Path $BackupPath -Header $header }
        $i = 0
        foreach ($t in $list) {
            $i++
            $r = $null
            try { $r = Invoke-LiteOSOfflineTweak -Tweak $t -Context $Context -State $state -Build $imageBuild -DryRun $dry -Deferred $deferred }
            catch {
                $r = [pscustomobject]@{
                    id = [string](Get-LiteOSProp $t 'id' '?'); name = [string](Get-LiteOSProp $t 'name' '?'); category = [string](Get-LiteOSProp $t 'category' '')
                    status = 'failed'; message = $_.Exception.Message; reboot = $false; whatIf = $dry; changes = 0; deferred = 0; details = @()
                }
                Write-LiteOSLog -NoConsole -Level Error ('IMAGE FAILED {0}: {1}' -f $r.id, $r.message)
            }
            $results.Add($r)
            if (-not $Quiet) { Write-LiteOSTweakLine -Result $r -Index $i -Total $list.Count }
        }
    }
    finally {
        if (-not $dry) {
            try { Close-LiteOSBackup $Context; $written = $Context.LastBackupFile }
            catch { Write-LiteOSLog -Level Error ('Could not finish the image backup {0}: {1}' -f $BackupPath, $_.Exception.Message) }
        }
        $Context.BackupFile = $saved.File
        $Context.BackupEntries = $saved.Entries
        $Context.BackupHeader = $saved.Header
        $Context.LastBackupFile = $saved.Last
        # Release registry handles (also those of script providers) so the caller can unload the hives.
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        [System.GC]::Collect()
    }
    $a = @($results | Where-Object { $_.status -eq 'applied' }).Count
    $s = @($results | Where-Object { $_.status -eq 'skipped' }).Count
    $f = @($results | Where-Object { $_.status -eq 'failed' }).Count
    $d = @($results | Where-Object { $_.status -eq 'deferred' }).Count
    $nd = 0
    foreach ($x in $deferred) { $nd += @($x.actions).Count }
    Write-LiteOSLog -NoConsole ('Offline plan finished: {0} applied, {1} deferred, {2} skipped, {3} failed; {4} deferred action(s) in {5} tweak(s); backup {6}' -f $a, $d, $s, $f, $nd, $deferred.Count, $(if ($written) { $written } else { '(none)' }))
    return @{
        Results    = $results.ToArray()
        Deferred   = $deferred.ToArray()
        BackupPath = $written
        ImageBuild = $imageBuild
        ControlSet = $hs.ControlSet
    }
}

function ConvertTo-LiteOSAsciiJson {
    # JSON text -> same JSON with every non-ASCII character escaped as \uXXXX (only valid inside strings,
    # which is the only place ConvertTo-Json puts them).
    param([string]$Json)
    if ($null -eq $Json) { return '' }
    $sb = New-Object -TypeName System.Text.StringBuilder -ArgumentList ($Json.Length + 16)
    foreach ($ch in $Json.ToCharArray()) {
        if ([int]$ch -gt 127) { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) } else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function ConvertTo-LiteOSDeferredJson {
    <#
    .SYNOPSIS
        Pure: deferred tweaks (Invoke-LiteOSOfflinePlan .Deferred) -> deferred.json text (ASCII).
    .DESCRIPTION
        { "version": 1, "created": "...", "liteos": "...", "tweaks": [ { "id", "name", "category", "level",
        "reboot", "minBuild", "maxBuild", "actions": [ ... ] } ] }. Entries with the same id are merged.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Deferred
    )
    $order = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $byId = @{}
    foreach ($d in @($Deferred)) {
        if ($null -eq $d) { continue }
        $id = [string](Get-LiteOSProp $d 'id' '')
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $acts = @(Get-LiteOSProp $d 'actions' @() | Where-Object { $null -ne $_ })
        if (-not $byId.ContainsKey($id)) {
            $order.Add($id)
            $byId[$id] = [ordered]@{
                id       = $id
                name     = [string](Get-LiteOSProp $d 'name' $id)
                category = [string](Get-LiteOSProp $d 'category' '')
                level    = [string](Get-LiteOSProp $d 'level' '')
                reboot   = (ConvertTo-LiteOSBool (Get-LiteOSProp $d 'reboot' $false))
                minBuild = (Get-LiteOSProp $d 'minBuild')
                maxBuild = (Get-LiteOSProp $d 'maxBuild')
                actions  = (New-Object -TypeName 'System.Collections.Generic.List[object]')
            }
        }
        foreach ($a in $acts) { $byId[$id]['actions'].Add($a) }
    }
    $tweaks = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($id in $order) {
        $e = $byId[$id]
        $e['actions'] = $e['actions'].ToArray()
        $tweaks.Add($e)
    }
    $doc = [ordered]@{
        version = 1
        created = (Get-Date).ToString('s')
        liteos  = $script:LiteOSVersion
        tweaks  = $tweaks.ToArray()
    }
    return (ConvertTo-LiteOSAsciiJson (ConvertTo-Json -InputObject $doc -Depth 30))
}

function Export-LiteOSDeferred {
    <#
    .SYNOPSIS
        Writes deferred.json (normally <mount>\LiteOS\deferred.json) for SetupComplete / first logon.
        Always writes the file (an empty "tweaks" list too). Returns the path.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Deferred,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $json = ConvertTo-LiteOSDeferredJson -Deferred $Deferred
    if (-not $PSCmdlet.ShouldProcess($Path, 'Write Lite OS deferred actions')) { return $null }
    Write-LiteOSTextFile -Path $Path -Text ($json + "`r`n") -Encoding $script:Utf8NoBom
    $n = 0
    foreach ($d in @($Deferred)) { if ($null -ne $d) { $n += @(Get-LiteOSProp $d 'actions' @()).Count } }
    Write-LiteOSLog -NoConsole ('Deferred actions written: {0} ({1} action(s))' -f $Path, $n)
    return $Path
}

function Read-LiteOSDeferred {
    <#
    .SYNOPSIS
        Reads deferred.json -> tweak objects ready for Invoke-LiteOSPlan (one per tweak id, only the
        actions of -Scope). Missing file -> nothing.
    .DESCRIPTION
        Scope Machine = everything except HKCU registry actions and perUser scripts (SetupComplete);
        Scope User = HKCU registry actions and perUser scripts (first logon, signed-in user).
        Every action is validated like a catalog action; invalid ones are logged and dropped.
        -Path files must be owned by SYSTEM / Administrators (they run elevated), unless -SkipTrustCheck.
        -Json parses text instead of a file (pure; used by tests).
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')]
        [string]$Path,

        [Parameter(Mandatory = $true, ParameterSetName = 'Json')]
        [string]$Json,

        [ValidateSet('All', 'Machine', 'User')]
        [string]$Scope = 'All',

        [switch]$SkipTrustCheck
    )
    $doc = $null
    $src = 'deferred.json'
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Write-LiteOSLog -NoConsole ('No deferred actions file at {0}.' -f $Path)
            return
        }
        if (-not $SkipTrustCheck -and -not (Test-LiteOSTrustedFile $Path)) {
            $owner = Get-LiteOSFileOwner $Path
            if (-not $owner) { $owner = 'unknown' }
            throw ('Refusing to use {0}: it is owned by {1}, not by SYSTEM or Administrators.' -f $Path, $owner)
        }
        $doc = Read-LiteOSJsonFile $Path
        $src = [System.IO.Path]::GetFileName($Path)
    }
    else {
        $doc = ConvertFrom-Json -InputObject $Json
    }
    $raw = @()
    if ($doc -is [System.Array]) { $raw = @($doc) } else { $raw = @(Get-LiteOSProp $doc 'tweaks' @()) }
    $protected = @(Get-LiteOSProtectedApps)
    $errors = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $warnings = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $i = 0
    foreach ($t in $raw) {
        $i++
        if ($null -eq $t -or $t -is [string] -or $t -is [System.ValueType]) { $errors.Add(('{0} entry #{1}: not an object' -f $src, $i)); continue }
        $id = [string](Get-LiteOSProp $t 'id' '')
        if ([string]::IsNullOrWhiteSpace($id)) { $errors.Add(('{0} entry #{1}: missing id' -f $src, $i)); continue }
        $id = $id.Trim()
        $acts = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $ai = 0
        foreach ($a in @(Get-LiteOSProp $t 'actions' @())) {
            $ai++
            $act = ConvertTo-LiteOSActionObject -Raw $a -Where ('{0} {1} action #{2}' -f $src, $id, $ai) -Errors $errors -Warnings $warnings -Protected $protected
            if ($null -eq $act) { continue }
            $isUser = Test-LiteOSUserAction $act
            if ($Scope -eq 'Machine' -and $isUser) { continue }
            if ($Scope -eq 'User' -and -not $isUser) { continue }
            $acts.Add($act)
        }
        if ($acts.Count -eq 0) { continue }
        $min = $null
        $max = $null
        try { if ($null -ne (Get-LiteOSProp $t 'minBuild')) { $min = [int](ConvertTo-LiteOSDecimal (Get-LiteOSProp $t 'minBuild')) } } catch { $min = $null }
        try { if ($null -ne (Get-LiteOSProp $t 'maxBuild')) { $max = [int](ConvertTo-LiteOSDecimal (Get-LiteOSProp $t 'maxBuild')) } } catch { $max = $null }
        $level = Get-LiteOSCanonical (Get-LiteOSProp $t 'level') $script:Levels
        if ($null -eq $level) { $level = 'balanced' }
        $cat = [string](Get-LiteOSProp $t 'category' '')
        if (-not $cat) { $cat = 'image' }
        [pscustomobject]@{
            id            = $id
            name          = [string](Get-LiteOSProp $t 'name' $id)
            description   = 'Part of the Lite OS image; applied on the installed system because it cannot be baked offline.'
            level         = $level
            default       = $true
            risk          = 'low'
            reboot        = (ConvertTo-LiteOSBool (Get-LiteOSProp $t 'reboot' $false))
            minBuild      = $min
            maxBuild      = $max
            actions       = $acts.ToArray()
            category      = $cat
            categoryTitle = 'Lite OS image (deferred)'
            source        = $src
        }
    }
    foreach ($w in $warnings) { Write-LiteOSLog -NoConsole -Level Warn ('deferred: ' + $w) }
    foreach ($e in $errors) { Write-LiteOSLog -Level Warn ('deferred: ' + $e + ' (ignored)') }
}

function Set-LiteOSImageFileOwner {
    <#
    .SYNOPSIS
        Makes BUILTIN\Administrators the owner of Lite OS image files (backup-image.json, deferred.json)
        that are still owned by the account that ran the builder on another PC. Returns how many changed.
    .DESCRIPTION
        Only meant for the SetupComplete stage: before the first sign-in nothing but the builder can have
        written these files, so adopting them is safe; afterwards the owner check of backups and
        deferred.json works as usual. Files already owned by SYSTEM / Administrators are left alone.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Path
    )
    $n = 0
    foreach ($p in @($Path)) {
        if ([string]::IsNullOrEmpty($p) -or -not [System.IO.File]::Exists($p)) { continue }
        $owner = Get-LiteOSFileOwner $p
        if ($script:TrustedOwnerSids -contains $owner) { continue }
        if (-not $PSCmdlet.ShouldProcess($p, 'Set owner to Administrators')) { continue }
        $done = $false
        foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {
            try {
                $sec = [System.IO.File]::GetAccessControl($p, [System.Security.AccessControl.AccessControlSections]::Owner)
                $sec.SetOwner((New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList $sid))
                [System.IO.File]::SetAccessControl($p, $sec)
                $done = $true
                break
            }
            catch { $null = $_ }
        }
        if ($done) { $n++; Write-LiteOSLog -NoConsole ('Adopted {0} (owner was {1}).' -f $p, $owner) }
        else { Write-LiteOSLog -Level Warn ('Could not take ownership of {0} (owner {1}).' -f $p, $owner) }
    }
    return $n
}

function Get-LiteOSInstallKind {
    <#
    .SYNOPSIS
        'image' when this Windows was installed from a Lite OS image (v2 builder), else 'playbook'.
    .DESCRIPTION
        Image markers: <PayloadRoot>\deferred.json, <StateRoot>\backup\backup-image.json,
        <StateRoot>\setupcomplete.done, or config.json with "source": "image" / "image": true / "mode".
        Read-only (file existence only).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$PayloadRoot, [string]$StateRoot, $Config)
    if (-not [string]::IsNullOrEmpty($PayloadRoot) -and [System.IO.File]::Exists((Join-Path $PayloadRoot 'deferred.json'))) { return 'image' }
    if (-not [string]::IsNullOrEmpty($StateRoot)) {
        if ([System.IO.File]::Exists((Join-Path $StateRoot 'backup\backup-image.json'))) { return 'image' }
        if ([System.IO.File]::Exists((Join-Path $StateRoot 'setupcomplete.done'))) { return 'image' }
    }
    if ($null -ne $Config) {
        if ([string](Get-LiteOSProp $Config 'source' '') -eq 'image') { return 'image' }
        if (ConvertTo-LiteOSBool (Get-LiteOSProp $Config 'image' $false)) { return 'image' }
        $m = [string](Get-LiteOSProp $Config 'mode' '')
        if ($m -eq 'Lite' -or $m -eq 'Core') { return 'image' }
    }
    return 'playbook'
}

function Expand-LiteOSPlaceholder {
    # Case-insensitive literal replace of {name} (no regex, so paths with $ or \ are safe).
    param([string]$Text, [string]$Name, [string]$Value)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $token = '{' + $Name + '}'
    $sb = New-Object -TypeName System.Text.StringBuilder
    $pos = 0
    while ($true) {
        $ix = $Text.IndexOf($token, $pos, [System.StringComparison]::OrdinalIgnoreCase)
        if ($ix -lt 0) { [void]$sb.Append($Text.Substring($pos)); break }
        [void]$sb.Append($Text.Substring($pos, $ix - $pos)).Append($Value)
        $pos = $ix + $token.Length
    }
    return $sb.ToString()
}

function Resolve-LiteOSInstallerPath {
    # Installer file name -> full path inside $Directory (or the extract folder). Pure string logic.
    param([string]$File, [string]$Directory, [string]$ExtractDir, [string]$DefaultRoot)
    if ([string]::IsNullOrWhiteSpace($File)) { return [pscustomobject]@{ Path = $null; Error = 'missing "file"' } }
    $f = $File.Trim().Replace('/', '\')
    foreach ($ph in @('extractDir', 'temp')) { $f = Expand-LiteOSPlaceholder $f $ph $ExtractDir }
    $f = Expand-LiteOSPlaceholder $f 'dir' $Directory
    if ($f -match '(^|\\)\.\.(\\|$)') { return [pscustomobject]@{ Path = $null; Error = ('"{0}" must not contain ..' -f $File) } }
    if (-not [System.IO.Path]::IsPathRooted($f)) { $f = Join-Path $DefaultRoot $f }
    $full = $null
    try { $full = [System.IO.Path]::GetFullPath($f) } catch { return [pscustomobject]@{ Path = $null; Error = ('"{0}" is not a valid path' -f $File) } }
    $ok = $false
    foreach ($root in @($Directory, $ExtractDir)) {
        if ([string]::IsNullOrEmpty($root)) { continue }
        $r = $root.TrimEnd('\') + '\'
        if ($full.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) { $ok = $true; break }
    }
    if (-not $ok) { return [pscustomobject]@{ Path = $null; Error = ('"{0}" is outside the installers folder' -f $File) } }
    return [pscustomobject]@{ Path = $full; Error = $null }
}

function Get-LiteOSInstallerJobs {
    <#
    .SYNOPSIS
        Pure: the installers manifest the builder wrote (C:\LiteOS\installers\installers.json, same schema
        as image/installers.json) -> ordered job list for SetupComplete.
    .DESCRIPTION
        Per entry: id, name, file (relative to -Directory), args (string or array; placeholders {dir},
        {extractDir} / {temp} = <ExtractRoot>\<id>), optional extract = { run, args } (second step run
        from the extract folder, e.g. DirectX DXSETUP.exe /silent), successCodes (default 0, 1638,
        3010, 1641), timeoutMinutes (default 15), publisher (checked against the Authenticode signer).
        Invalid entries get .Error and are reported, never run. No file system access.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Manifest,

        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [string]$ExtractRoot
    )
    $dir = $Directory.TrimEnd('\')
    if ([string]::IsNullOrEmpty($ExtractRoot)) { $ExtractRoot = Join-Path $dir '_extract' }
    $raw = @()
    if ($null -eq $Manifest) { $raw = @() }
    elseif ($Manifest -is [System.Array]) { $raw = @($Manifest) }
    else { $raw = @(Get-LiteOSProp $Manifest 'installers' @()) }
    $i = 0
    foreach ($e in $raw) {
        $i++
        if ($null -eq $e -or $e -is [string] -or $e -is [System.ValueType]) { continue }
        $id = ([string](Get-LiteOSProp $e 'id' '')).Trim()
        if (-not $id) { $id = 'installer-{0}' -f $i }
        $safeId = ($id -replace '[^A-Za-z0-9_.\-]', '-') -replace '\.\.+', '-'
        $name = [string](Get-LiteOSProp $e 'name' $id)
        $extractDir = Join-Path $ExtractRoot $safeId
        $err = $null
        $steps = New-Object -TypeName 'System.Collections.Generic.List[object]'

        $main = Resolve-LiteOSInstallerPath -File ([string](Get-LiteOSProp $e 'file' '')) -Directory $dir -ExtractDir $extractDir -DefaultRoot $dir
        if ($null -ne $main.Error) { $err = $main.Error }
        else { $steps.Add((New-LiteOSInstallerStep -File $main.Path -Arguments (Get-LiteOSPropRaw $e 'args') -Directory $dir -ExtractDir $extractDir)) }

        $ex = Get-LiteOSProp $e 'extract'
        if ($null -eq $err -and $null -ne $ex) {
            $run = [string](Get-LiteOSProp $ex 'run' (Get-LiteOSProp $ex 'file' ''))
            $p2 = Resolve-LiteOSInstallerPath -File $run -Directory $dir -ExtractDir $extractDir -DefaultRoot $extractDir
            if ($null -ne $p2.Error) { $err = 'extract: ' + $p2.Error }
            else { $steps.Add((New-LiteOSInstallerStep -File $p2.Path -Arguments (Get-LiteOSPropRaw $ex 'args') -Directory $dir -ExtractDir $extractDir)) }
        }
        foreach ($st in $steps) { if ($null -eq $err -and $null -ne $st.Error) { $err = $st.Error } }

        $timeout = 15
        $tm = Get-LiteOSProp $e 'timeoutMinutes'
        if ($null -ne $tm) { try { $timeout = [int](ConvertTo-LiteOSDecimal $tm) } catch { $timeout = 15 } }
        if ($timeout -lt 1) { $timeout = 1 }
        if ($timeout -gt 120) { $timeout = 120 }
        $codes = New-Object -TypeName 'System.Collections.Generic.List[int]'
        foreach ($c in @(Get-LiteOSProp $e 'successCodes' @())) {
            try { $codes.Add([int](ConvertTo-LiteOSDecimal $c)) } catch { $null = $_ }
        }
        if ($codes.Count -eq 0) { foreach ($c in $script:InstallerSuccessCodes) { $codes.Add($c) } }
        [pscustomobject]@{
            Id             = $id
            Name           = $name
            Publisher      = [string](Get-LiteOSProp $e 'publisher' '')
            Steps          = $steps.ToArray()
            ExtractDir     = $extractDir
            TimeoutSeconds = ($timeout * 60)
            SuccessCodes   = $codes.ToArray()
            Error          = $err
        }
    }
}

function New-LiteOSInstallerStep {
    param([string]$File, $Arguments, [string]$Directory, [string]$ExtractDir)
    $argText = ''
    if ($null -ne $Arguments) {
        if ($Arguments -is [System.Array]) { $argText = (@($Arguments | ForEach-Object { [string]$_ }) -join ' ') }
        else { $argText = [string]$Arguments }
    }
    foreach ($ph in @('extractDir', 'temp')) { $argText = Expand-LiteOSPlaceholder $argText $ph $ExtractDir }
    $argText = (Expand-LiteOSPlaceholder $argText 'dir' $Directory).Trim()
    $ext = [System.IO.Path]::GetExtension($File).ToLowerInvariant()
    $kind = $null
    $err = $null
    if ($ext -eq '.exe') { $kind = 'exe' }
    elseif ($ext -eq '.msi') { $kind = 'msi' }
    else { $err = ('unsupported installer type "{0}" (only .exe and .msi)' -f $ext) }
    return [pscustomobject]@{ File = $File; Arguments = $argText; Kind = $kind; Error = $err }
}

function Get-LiteOSSignatureVerdict {
    <#
    .SYNOPSIS
        Pure: decides whether an installer may run, from its Authenticode status and signer subject.
    .DESCRIPTION
        Valid + publisher in the signer subject -> run. HashMismatch / NotSigned / Incompatible -> never
        (the file was changed after the builder verified it). Chain problems that can happen offline at
        SetupComplete (UnknownError, NotTrusted) -> run with a warning only when the signer subject still
        names the expected publisher. Returns {Allowed; Warning; Message}.
    #>
    [CmdletBinding()]
    param([string]$Status, [string]$Subject, [string]$Publisher)
    $subj = [string]$Subject
    $pubOk = $true
    if (-not [string]::IsNullOrWhiteSpace($Publisher)) {
        $pubOk = ($subj.IndexOf($Publisher.Trim(), [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    if ($Status -eq 'Valid') {
        if ($pubOk) { return [pscustomobject]@{ Allowed = $true; Warning = $false; Message = ('signature valid ({0})' -f (Format-LiteOSShort $subj 80)) } }
        return [pscustomobject]@{ Allowed = $false; Warning = $false; Message = ('signed by "{0}", expected "{1}"' -f (Format-LiteOSShort $subj 80), $Publisher) }
    }
    if (@('HashMismatch', 'NotSigned', 'Incompatible', 'NotSupportedFileFormat') -contains $Status) {
        return [pscustomobject]@{ Allowed = $false; Warning = $false; Message = ('signature {0}: the file is not the one the builder verified' -f $Status) }
    }
    if (-not [string]::IsNullOrWhiteSpace($subj) -and $pubOk -and -not [string]::IsNullOrWhiteSpace($Publisher)) {
        return [pscustomobject]@{ Allowed = $true; Warning = $true; Message = ('signature status {0} (certificate chain not verifiable now), signer "{1}" matches' -f $Status, (Format-LiteOSShort $subj 80)) }
    }
    return [pscustomobject]@{ Allowed = $false; Warning = $false; Message = ('signature status {0}, signer "{1}"' -f $Status, (Format-LiteOSShort $subj 80)) }
}

function Get-LiteOSExitCodeVerdict {
    <#
    .SYNOPSIS
        Pure: installer exit code -> {Ok; Reboot; Message}. 3010 / 1641 = success, restart needed;
        1638 = a same or newer version is already installed.
    #>
    [CmdletBinding()]
    param([int]$ExitCode, [int[]]$SuccessCodes)
    # (@() of an unset typed array parameter is $null in Windows PowerShell 5.1, so test it directly.)
    $codes = $SuccessCodes
    if ($null -eq $codes -or $codes.Length -eq 0) { $codes = $script:InstallerSuccessCodes }
    $reboot = ($ExitCode -eq 3010 -or $ExitCode -eq 1641)
    if ($codes -contains $ExitCode) {
        $m = 'exit code {0}' -f $ExitCode
        if ($ExitCode -eq 1638) { $m += ' (a same or newer version is already installed)' }
        elseif ($reboot) { $m += ' (restart needed)' }
        return [pscustomobject]@{ Ok = $true; Reboot = $reboot; Message = $m }
    }
    return [pscustomobject]@{ Ok = $false; Reboot = $false; Message = ('exit code {0} (0x{1:X8})' -f $ExitCode, $ExitCode) }
}

function Get-LiteOSBootDescription {
    <#
    .SYNOPSIS
        Pure: the boot menu name from branding.json (bootDescription, else name), limited to letters,
        digits, space and . _ + ( ) -, max 60 characters. $null when there is nothing usable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Branding)
    if ($null -eq $Branding) { return $null }
    $d = [string](Get-LiteOSProp $Branding 'bootDescription' '')
    if ([string]::IsNullOrWhiteSpace($d)) { $d = [string](Get-LiteOSProp $Branding 'name' '') }
    $d = ($d -replace '[^A-Za-z0-9 ._+()\-]', '').Trim()
    $d = ($d -replace '\s+', ' ')
    if ($d.Length -gt 60) { $d = $d.Substring(0, 60).Trim() }
    if ($d.Length -eq 0) { return $null }
    return $d
}

function Get-LiteOSBcdDescription {
    <#
    .SYNOPSIS
        Pure: the "description" of the first entry in "bcdedit /enum {current}" output, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $m = [regex]::Match($Text, '(?im)^[ \t]*description[ \t]+([^\r\n]*?)[ \t]*\r?$')
    if (-not $m.Success) { return $null }
    $v = $m.Groups[1].Value
    if ($v.Length -eq 0) { return $null }
    return $v
}

function New-LiteOSBootDescriptionTweak {
    <#
    .SYNOPSIS
        Pure: synthetic tweak 'image.boot-description' that renames the boot menu entry of this
        installation ({current}) and records an undo that puts the previous name back.
    .PARAMETER Previous
        The description before the change (from bcdedit); 'Windows 11' (what Setup writes) when unknown.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [AllowNull()][AllowEmptyString()][string]$Previous
    )
    $want = ($Description -replace '[^A-Za-z0-9 ._+()\-]', '').Trim()
    if ($want.Length -eq 0) { throw 'empty boot description' }
    $old = 'Windows 11'
    if (-not [string]::IsNullOrWhiteSpace($Previous)) { $old = ($Previous -replace '[\x00-\x1F]', '').Trim() }
    $oldQ = $old.Replace("'", "''")
    $applyText = @(
        ('$want = ''{0}''' -f $want),
        '$bcd = Join-Path $env:SystemRoot ''System32\bcdedit.exe''',
        '$now = (& $bcd /enum ''{current}'' 2>&1 | Out-String)',
        'if ($now -match ''(?im)^[ \t]*description[ \t]+([^\r\n]*?)[ \t]*\r?$'' -and $Matches[1] -eq $want) { Write-Output (''UNCHANGED: the boot menu entry is already called '' + $want); return }',
        '$out = (& $bcd /set ''{current}'' description $want 2>&1 | Out-String)',
        'if ($LASTEXITCODE -ne 0) { throw (''bcdedit /set description failed: '' + $out.Trim()) }',
        'Write-Output (''boot menu entry renamed to '' + $want)'
    ) -join "`r`n"
    $undo = @(
        ('$old = ''{0}''' -f $oldQ),
        '$bcd = Join-Path $env:SystemRoot ''System32\bcdedit.exe''',
        '$out = (& $bcd /set ''{current}'' description $old 2>&1 | Out-String)',
        'if ($LASTEXITCODE -ne 0) { throw (''bcdedit /set description failed: '' + $out.Trim()) }',
        'Write-Output (''boot menu entry renamed back to '' + $old)'
    ) -join "`r`n"
    return [pscustomobject]@{
        id            = 'image.boot-description'
        name          = ('Name the boot menu entry "{0}"' -f $want)
        description   = 'Lite OS branding: the Windows Boot Manager entry of this installation shows the Lite OS name. Reverting puts the previous name back.'
        level         = 'balanced'
        default       = $true
        risk          = 'none'
        reboot        = $false
        minBuild      = $null
        maxBuild      = $null
        actions       = @([pscustomobject]([ordered]@{ type = 'powershell'; script = $applyText; undo = $undo }))
        category      = 'image'
        categoryTitle = 'Lite OS image'
        source        = 'branding.json'
    }
}

Export-ModuleMember -Function @(
    'Initialize-LiteOS',
    'Get-LiteOSCatalog',
    'Select-LiteOSTweaks',
    'Invoke-LiteOSTweak',
    'Invoke-LiteOSPlan',
    'New-LiteOSRestorePoint',
    'Get-LiteOSBackups',
    'Restore-LiteOSBackup',
    'Write-LiteOSLog',
    'Test-LiteOSAdmin',
    'Get-LiteOSWindowsInfo',
    'Get-LiteOSProtectedApps',
    'Test-LiteOSProtectedApp',
    'Write-LiteOSSummary',
    # Lite OS image (v2)
    'ConvertTo-LiteOSOfflinePath',
    'Get-LiteOSOfflineDisposition',
    'Invoke-LiteOSOfflinePlan',
    'ConvertTo-LiteOSDeferredJson',
    'Export-LiteOSDeferred',
    'Read-LiteOSDeferred',
    'Set-LiteOSImageFileOwner',
    'Get-LiteOSInstallKind',
    'Get-LiteOSInstallerJobs',
    'Get-LiteOSSignatureVerdict',
    'Get-LiteOSExitCodeVerdict',
    'Get-LiteOSBootDescription',
    'Get-LiteOSBcdDescription',
    'New-LiteOSBootDescriptionTweak'
)

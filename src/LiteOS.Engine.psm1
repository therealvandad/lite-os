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

$script:LiteOSVersion   = '1.0.0'
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
    param([string]$Path, [string]$Text, [System.Text.Encoding]$Encoding = $script:Utf8NoBom)
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $tmp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $Text, $Encoding)
    if ([System.IO.File]::Exists($Path)) {
        try { [System.IO.File]::Replace($tmp, $Path, $null) }
        catch {
            [System.IO.File]::Copy($tmp, $Path, $true)
            [System.IO.File]::Delete($tmp)
        }
    }
    else {
        [System.IO.File]::Move($tmp, $Path)
    }
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
    param($Context)
    if (-not [string]::IsNullOrEmpty($Context.BackupFile)) { return }
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
    elseif ($Result.whatIf -and $Result.changes -gt 0) { $tag = 'WOULD'; $color = 'Cyan' }
    elseif ($Result.changes -gt 0) { $tag = 'DONE'; $color = 'Green' }
    Write-Host $prefix -NoNewline
    Write-Host ($tag.PadRight(6)) -ForegroundColor $color -NoNewline
    Write-Host $Result.name
    if ($Result.status -eq 'failed') {
        Write-Host ('         ' + (Format-LiteOSShort $Result.message 200)) -ForegroundColor Red
    }
    elseif ($Result.status -eq 'skipped' -and $Result.message) {
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
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Tweaks,

        $Context,

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
            Open-LiteOSBackup $Context
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
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        $Context
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
    Write-LiteOSLog ('Restoring {0} ({1} entries, newest first){2}' -f $Path, $entries.Count, $(if ($dry) { ' - dry run' } else { '' }))
    if ($sid -and $sid -ne (Get-LiteOSCurrentSid)) {
        Write-LiteOSLog -Level Warn ('This backup was made by another user ({0}); their HKCU values are restored only if that profile is loaded.' -f $sid)
    }
    $results = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $mounted = $false
    try {
        $needDefault = $false
        foreach ($e in $entries) { if ([string](Get-LiteOSProp $e 'hive' '') -eq 'Default') { $needDefault = $true; break } }
        if ($needDefault -and -not $dry -and $Context.DefaultHiveState -eq 'NotLoaded') { $mounted = Mount-LiteOSDefaultHive $Context }
        for ($i = $entries.Count - 1; $i -ge 0; $i--) {
            $e = $entries[$i]
            $tid = [string](Get-LiteOSProp $e 'tweakId' '?')
            $act = Get-LiteOSProp $e 'action'
            $type = [string](Get-LiteOSProp $act 'type' '?')
            $hive = [string](Get-LiteOSProp $e 'hive' 'Machine')
            $o = $null
            if ($dry) {
                $o = ConvertTo-LiteOSOutcome 'restored' ('WhatIf: would revert {0} [{1}]' -f $type, $hive)
            }
            else {
                try { $o = Restore-LiteOSEntry -Context $Context -Entry $e -UserSid $sid }
                catch { $o = ConvertTo-LiteOSOutcome 'failed' (Format-LiteOSShort $_.Exception.Message 200) }
            }
            $r = [pscustomobject]@{ tweakId = $tid; action = $type; hive = $hive; status = $o.status; message = $o.message; reboot = $o.reboot; apps = $o.apps }
            $results.Add($r)
            $lvl = 'Info'
            if ($r.status -eq 'failed') { $lvl = 'Error' } elseif ($r.status -eq 'skipped') { $lvl = 'Warn' }
            Write-LiteOSLog -NoConsole -Level $lvl ('REVERT {0} {1} [{2}] {3}: {4}' -f $r.status.ToUpperInvariant(), $tid, $hive, $type, $r.message)
        }
    }
    finally {
        if ($mounted) { Dismount-LiteOSDefaultHive $Context }
    }
    if (-not $dry) {
        try {
            $nFailed = @($results | Where-Object { $_.status -eq 'failed' }).Count
            $now = (Get-Date).ToString('s')
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
    'Write-LiteOSSummary'
)

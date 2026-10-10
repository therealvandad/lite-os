<#
.SYNOPSIS
    Checks a finished Lite OS ISO, READ-ONLY: image name and build, payload, SetupComplete, state
    files, Start / taskbar layout, removed apps and the service / policy promises of the mode.

.DESCRIPTION
    Test-LiteOSImage.ps1 verifies an ISO made by builder\Build-LiteOS.ps1 without changing it:

      ISO        setup / boot files, sources\install.wim, autounattend.xml safety rules
                 (no disk, key or account settings), boot.wim has the Setup image
      install.wim exactly one image, named "Lite OS <Mode>", x64 client, build >= 26100
      image      mounted with Mount-WindowsImage -ReadOnly (always dismounted with -Discard):
                 C:\LiteOS payload, SetupComplete.cmd, C:\ProgramData\LiteOS\config.json,
                 build-info.json, backup\backup-image.json, C:\LiteOS\deferred.json, protected
                 ACLs, Default-profile LayoutModification.json, taskbar layout, Winre.wim kept,
                 WebView2 kept, removed provisioned apps really gone, Store / Xbox apps kept
      registry   COPIES of the image's SYSTEM and SOFTWARE hives are loaded as
                 HKLM\LITE_VERIFY_SYSTEM / HKLM\LITE_VERIFY_SOFTWARE (always unloaded, copies
                 deleted): Lite = Defender, Windows Update, Store and Xbox services not disabled
                 and not changed by the builder, no NoAutoUpdate / DisableAntiSpyware policy;
                 Core = WinDefend Start=4, update services disabled (or deferred to SetupComplete),
                 NoAutoUpdate=1 and none of the removals' "conflicts" tweaks baked in

    Nothing is written into the ISO or the image. The only changes on this PC: the ISO is attached
    read-only while the script runs, a temporary mount / hive-copy folder (-WorkDir, deleted at the
    end) and the report files. Needs an elevated Windows PowerShell 5.1 (DISM and reg load).

    Results: pass / warn / fail / info / skip per check, printed and written as JSON
    (<ReportPath>) plus a Markdown summary (.md) and a log (.log) next to it; small text files
    from the image (build-info.json, config.json, deferred.json, backup-image.json, layouts,
    SetupComplete.cmd) are copied into <report name>-files\ for review. When run in GitHub Actions
    the Markdown summary is also added to the job summary.

    Exit code: 0 = no failed check (warnings allowed), 1 = at least one check failed,
    2 = the verification could not run (not elevated, ISO not readable, mount failed, ...).

.PARAMETER IsoPath
    Lite OS ISO file, or a folder with the extracted ISO contents.

.PARAMETER Mode
    Lite or Core. Default: taken from the image name ("Lite OS <Mode>").

.PARAMETER ExpectedName
    Image name install.wim must have. Default "<branding name> <Mode>" = "Lite OS <Mode>".

.PARAMETER MinBuild
    Lowest Windows build accepted. Default 26100 (24H2).

.PARAMETER WorkDir
    Scratch folder on a local NTFS drive (empty, or one this script created earlier) for the
    read-only mount and the hive copies; needs about 1 GB (more when the WIM has to be copied).
    Default: %TEMP%\LiteOS-Verify-<time>. Deleted at the end.

.PARAMETER ReportPath
    JSON report. Default: <ISO name>.verify.json next to the ISO (or in the current folder for
    an ISO folder).

.PARAMETER RepoRoot
    Lite OS folder (image\branding.json, image\removals.json, tweaks\apps-remove.json).
    Default: the folder above this script.

.PARAMETER NoMount
    Only check the ISO and the install.wim metadata (no image mount, no registry checks).

.PARAMETER PassThru
    Also return the report object.

.EXAMPLE
    .\Test-LiteOSImage.ps1 -IsoPath D:\Builds\LiteOS-Lite-26200.6584-en-US.iso

.EXAMPLE
    .\Test-LiteOSImage.ps1 -IsoPath E:\LiteOS-Core.iso -Mode Core -WorkDir E:\verify -ReportPath E:\reports\core.verify.json

.NOTES
    Lite OS builder 2.x. Windows PowerShell 5.1 compatible, ASCII only. Read-only by design: the
    image is mounted with -ReadOnly and discarded, registry checks use copies of the hive files.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$IsoPath,

    [string]$Mode = '',

    [string]$ExpectedName,

    [int]$MinBuild = 26100,

    [string]$WorkDir,

    [string]$ReportPath,

    [string]$RepoRoot,

    [switch]$NoMount,

    [switch]$PassThru
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------------------------
$script:VerifierVersion = '2.0.0'
$script:Checks          = New-Object System.Collections.ArrayList
$script:LogFile         = $null
$script:DismLog         = $null
$script:RegExe          = Join-Path $env:SystemRoot 'System32\reg.exe'
$script:HiveNames       = @('LITE_VERIFY_SYSTEM', 'LITE_VERIFY_SOFTWARE')
$script:LoadedHives     = New-Object System.Collections.ArrayList
$script:MountDir        = $null
$script:Mounted         = $false
$script:IsoAttachedByUs = $false
$script:IsoFull         = $null
$script:WorkRoot        = $null
$script:WorkCreated     = $false
$script:WorkMarker      = '.liteos-verify'
$script:Fatal           = $null

# Services Lite must leave alone (Defender, Windows Update, Store, Xbox / Game Pass) with the
# usual Windows 11 Start value (information only: the value in the source image is what counts).
$script:LiteServices = [ordered]@{
    WinDefend             = 2
    WdNisSvc              = 3
    SecurityHealthService = 3
    wscsvc                = 2
    mpssvc                = 2
    wuauserv              = 3
    UsoSvc                = 2
    WaaSMedicSvc          = 3
    BITS                  = 3
    CryptSvc              = 2
    TrustedInstaller      = 3
    InstallService        = 3
    XblAuthManager        = 3
    XboxNetApiSvc         = 3
    XboxGipSvc            = 3
}
# Provisioned apps Lite OS never removes. Required = always in the official ISO.
$script:KeepAppsRequired = @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller')
$script:KeepAppsGaming   = @('Microsoft.GamingApp', 'Microsoft.XboxIdentityProvider', 'Microsoft.XboxGamingOverlay', 'Microsoft.Xbox.TCUI', 'Microsoft.XboxSpeechToTextOverlay')

# ---------------------------------------------------------------------------------------------
# Output, log, checks
# ---------------------------------------------------------------------------------------------
function ConvertTo-OneLine {
    param([AllowNull()][AllowEmptyString()][string]$Text, [int]$Max = 400)
    if ($null -eq $Text) { return '' }
    $t = ($Text -replace '[\r\n\t]+', ' ' -replace '\s{2,}', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 3) + '...' }
    return $t
}

function Write-VerifyLog {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message, [string]$Color = '')
    $line = '{0} {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { Write-Verbose ('Log write failed: ' + $_.Exception.Message) }
    }
    if ($Color) { Write-Host ('  ' + $Message) -ForegroundColor $Color } else { Write-Host ('  ' + $Message) }
}

function Add-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('pass', 'fail', 'warn', 'info', 'skip')][string]$Status,
        [AllowEmptyString()][string]$Message = ''
    )
    $msg = ConvertTo-OneLine $Message 600
    [void]$script:Checks.Add([ordered]@{ id = $Id; status = $Status; message = $msg })
    $color = 'Gray'
    switch ($Status) {
        'pass' { $color = 'Green' }
        'fail' { $color = 'Red' }
        'warn' { $color = 'Yellow' }
        'skip' { $color = 'DarkGray' }
    }
    Write-VerifyLog -Color $color -Message ('{0,-4} {1}: {2}' -f $Status.ToUpperInvariant(), $Id, $msg)
}

function Invoke-Check {
    # Per-check error handling: an exception inside one check fails that check only.
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][scriptblock]$Body)
    try { & $Body } catch { Add-Check -Id $Id -Status 'fail' -Message ('check error: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-Prop {
    # Strict-mode safe property / key read. Arrays are unrolled: wrap in @() when a list is expected.
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

function Test-Prop {
    param($Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return [bool]$Object.Contains($Name) }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Read-JsonSafe {
    # -> @{ Ok; Data; Error }
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ Ok = $false; Data = $null; Error = 'missing' } }
    try {
        $raw = [IO.File]::ReadAllText($Path)
        return @{ Ok = $true; Data = ($raw | ConvertFrom-Json); Error = $null }
    } catch {
        return @{ Ok = $false; Data = $null; Error = ('does not parse: ' + (ConvertTo-OneLine $_.Exception.Message 200)) }
    }
}

function Invoke-NativeTool {
    # Native exe without stderr turning into a terminating error (PS 5.1 + EAP Stop).
    param([Parameter(Mandatory = $true)][string]$FilePath, [string[]]$ArgumentList = @())
    $ErrorActionPreference = 'Continue'
    $output = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" })
    return New-Object PSObject -Property @{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Test-LikeAny {
    param([string]$Name, [string[]]$Patterns)
    foreach ($p in @($Patterns)) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        try { if ($Name -like $p) { return $true } } catch { Write-Verbose ('Bad pattern ' + $p) }
    }
    return $false
}

function Test-IdMatch {
    # Same id rules as the engine: exact id, or -like when the pattern has * or ?.
    param([string]$Id, [string[]]$Patterns)
    foreach ($p in @($Patterns)) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        if ($Id -eq $p) { return $true }
        if ($p.IndexOf('*') -ge 0 -or $p.IndexOf('?') -ge 0) {
            try { if ($Id -like $p) { return $true } } catch { Write-Verbose ('Bad pattern ' + $p) }
        }
    }
    return $false
}

function Write-Utf8File {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------------------------
# Registry (copies of the image hives only)
# ---------------------------------------------------------------------------------------------
function Test-HiveLoaded {
    param([Parameter(Mandatory = $true)][string]$Name)
    return ((Invoke-NativeTool -FilePath $script:RegExe -ArgumentList @('query', "HKLM\$Name")).ExitCode -eq 0)
}

function Dismount-VerifyHive {
    param([Parameter(Mandatory = $true)][string]$Name)
    for ($i = 1; $i -le 6; $i++) {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        $r = Invoke-NativeTool -FilePath $script:RegExe -ArgumentList @('unload', "HKLM\$Name")
        if ($r.ExitCode -eq 0 -or -not (Test-HiveLoaded -Name $Name)) {
            if ($script:LoadedHives -contains $Name) { $script:LoadedHives.Remove($Name) }
            return $true
        }
        Start-Sleep -Seconds 2
    }
    Write-VerifyLog -Color Yellow -Message ("Could not unload HKLM\{0}; run: reg unload HKLM\{0}" -f $Name)
    return $false
}

function Mount-VerifyHive {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$File)
    if (Test-HiveLoaded -Name $Name) {
        if (-not (Dismount-VerifyHive -Name $Name)) { throw "HKLM\$Name is still loaded from an earlier run." }
    }
    $r = Invoke-NativeTool -FilePath $script:RegExe -ArgumentList @('load', "HKLM\$Name", $File)
    if ($r.ExitCode -ne 0) { throw ("reg load HKLM\{0} failed (exit {1}): {2}" -f $Name, $r.ExitCode, ($r.Output -join ' ')) }
    [void]$script:LoadedHives.Add($Name)
}

function Get-RegValue {
    # -> @{ Exists; Type; Data } (REG_DWORD data as [int64]); Exists = $false when key or value is absent.
    param([Parameter(Mandatory = $true)][string]$Key, [Parameter(Mandatory = $true)][string]$Name)
    $out = @{ Exists = $false; Type = $null; Data = $null }
    $r = Invoke-NativeTool -FilePath $script:RegExe -ArgumentList @('query', $Key, '/v', $Name)
    if ($r.ExitCode -ne 0) { return $out }
    foreach ($line in $r.Output) {
        if ($line -match '^\s{2,}(.+?)\s{2,}(REG_[A-Z_]+)\s{0,}(.*)$') {
            if ($Matches[1] -ne $Name) { continue }
            $out.Exists = $true
            $out.Type = $Matches[2]
            $data = $Matches[3].Trim()
            if ($out.Type -eq 'REG_DWORD' -or $out.Type -eq 'REG_QWORD') {
                if ($data -match '^0x([0-9a-fA-F]+)$') { $data = [Convert]::ToInt64($Matches[1], 16) }
            }
            $out.Data = $data
            break
        }
    }
    return $out
}

function Get-ServiceStartText {
    param($Start, $Delayed)
    if ($null -eq $Start) { return 'missing' }
    $names = @{ 0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }
    $n = [int]$Start
    $t = [string]$n
    if ($names.ContainsKey($n)) { $t = '{0} ({1})' -f $n, $names[$n] }
    if ($n -eq 2 -and $null -ne $Delayed -and [int]$Delayed -eq 1) { $t = '2 (Automatic, delayed)' }
    return $t
}

# ---------------------------------------------------------------------------------------------
# Image data helpers
# ---------------------------------------------------------------------------------------------
function Get-BackupServiceNames {
    # Service names the builder changed offline (backup-image.json entries with a service action).
    param($Backup)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($e in @(Get-Prop $Backup 'entries' @())) {
        $a = Get-Prop $e 'action' $null
        if ([string](Get-Prop $a 'type' '') -eq 'service') {
            $n = [string](Get-Prop $a 'name' '')
            if ($n -and -not $names.Contains($n.ToLowerInvariant())) { $names.Add($n.ToLowerInvariant()) }
        }
    }
    return $names.ToArray()
}

function Get-BackupTweakIds {
    param($Backup)
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($e in @(Get-Prop $Backup 'entries' @())) {
        $t = [string](Get-Prop $e 'tweakId' '')
        if ($t -and -not $ids.Contains($t)) { $ids.Add($t) }
    }
    return $ids.ToArray()
}

function Get-DeferredActions {
    # All actions in deferred.json as objects with an added "owner" (deferred tweak / removal id).
    param($Deferred)
    $list = New-Object System.Collections.ArrayList
    foreach ($t in @(Get-Prop $Deferred 'tweaks' @())) {
        $owner = [string](Get-Prop $t 'id' '')
        foreach ($a in @(Get-Prop $t 'actions' @())) {
            if ($null -eq $a) { continue }
            [void]$list.Add((New-Object PSObject -Property @{ Owner = $owner; Type = [string](Get-Prop $a 'type' ''); Name = [string](Get-Prop $a 'name' ''); Startup = [string](Get-Prop $a 'startup' ''); Path = [string](Get-Prop $a 'path' ''); Value = (Get-Prop $a 'value' $null) }))
        }
    }
    return $list.ToArray()
}

function Test-DeferredService {
    # $true when deferred.json disables the service on the installed system (SetupComplete).
    param([object[]]$Actions, [string]$Service)
    foreach ($a in @($Actions)) {
        if ($a.Type -eq 'service' -and $a.Name -eq $Service -and $a.Startup -eq 'Disabled') { return $true }
        if ($a.Type -eq 'registry' -and $a.Path -match ('(?i)\\Services\\' + [regex]::Escape($Service) + '$') -and $a.Name -eq 'Start' -and [string]$a.Value -eq '4') { return $true }
    }
    return $false
}

function Get-AclProblems {
    # Lite OS state folders: owner Administrators (or SYSTEM), and no write access for Users,
    # Authenticated Users or Everyone (backups hold undo scripts that run elevated).
    param([Parameter(Mandatory = $true)][string]$Path)
    $problems = New-Object System.Collections.Generic.List[string]
    $acl = Get-Acl -LiteralPath $Path
    $sidType = [System.Security.Principal.SecurityIdentifier]
    $owner = [string]$acl.GetOwner($sidType).Value
    if (@('S-1-5-32-544', 'S-1-5-18') -notcontains $owner) { $problems.Add('owner is ' + $owner + ' (expected S-1-5-32-544 Administrators)') }
    $weak = @{ 'S-1-1-0' = 'Everyone'; 'S-1-5-11' = 'Authenticated Users'; 'S-1-5-32-545' = 'Users'; 'S-1-3-0' = 'CREATOR OWNER' }
    $writeMask = [int64](2 -bor 4 -bor 16 -bor 64 -bor 256 -bor 65536 -bor 262144 -bor 524288)
    foreach ($rule in @($acl.GetAccessRules($true, $true, $sidType))) {
        if ([string]$rule.AccessControlType -ne 'Allow') { continue }
        $sid = [string]$rule.IdentityReference.Value
        if (-not $weak.ContainsKey($sid)) { continue }
        if (([int64]$rule.FileSystemRights -band $writeMask) -ne 0) { $problems.Add(('{0} may write ({1})' -f $weak[$sid], $rule.FileSystemRights)) }
    }
    return $problems.ToArray()
}

# =============================================================================================
# Main
# =============================================================================================
$started = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$isoRoot = $null
$wim = $null
$image = $null
$imageName = $null
$imageBuild = 0
$buildText = $null
$report = $null
$reportJson = $null
$filesDir = $null

try {
    if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
    if (-not (Test-Path -LiteralPath $IsoPath)) { throw "ISO not found: $IsoPath" }
    $script:IsoFull = (Resolve-Path -LiteralPath $IsoPath).ProviderPath
    $isoIsFolder = Test-Path -LiteralPath $script:IsoFull -PathType Container

    # Report / log paths
    if (-not $ReportPath) {
        if ($isoIsFolder) { $ReportPath = Join-Path (Get-Location).ProviderPath 'LiteOS-image.verify.json' }
        else { $ReportPath = [IO.Path]::ChangeExtension($script:IsoFull, '.verify.json') }
    }
    $reportJson = Resolve-FullPath $ReportPath
    $reportDir = Split-Path -Parent $reportJson
    if (-not (Test-Path -LiteralPath $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
    $script:LogFile = [IO.Path]::ChangeExtension($reportJson, '.log')
    $script:DismLog = [IO.Path]::ChangeExtension($reportJson, '.dism.log')
    $filesDir = Join-Path $reportDir ([IO.Path]::GetFileNameWithoutExtension($reportJson) + '-files')

    Write-Host ''
    Write-Host ('Lite OS image verifier {0} (read-only)' -f $script:VerifierVersion) -ForegroundColor White
    Write-VerifyLog -Message ('ISO: {0}' -f $script:IsoFull)
    Write-VerifyLog -Message ('Report: {0}' -f $reportJson)

    if ($Mode -and @('Lite', 'Core') -notcontains $Mode) { throw "-Mode must be Lite or Core (got '$Mode')." }
    if ($Mode) { $Mode = (Get-Culture).TextInfo.ToTitleCase($Mode.ToLowerInvariant()) }
    if (-not (Test-IsAdmin)) { throw 'Run this script from an elevated Windows PowerShell (Run as administrator): DISM and reg load need it.' }
    foreach ($cmd in @('Get-WindowsImage', 'Mount-WindowsImage', 'Dismount-WindowsImage', 'Get-AppxProvisionedPackage', 'Mount-DiskImage', 'Dismount-DiskImage')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "Required cmdlet '$cmd' is missing (DISM / Storage modules)." }
    }

    # Branding name, removal conflicts and the app list from the Lite OS folder (optional).
    $brandName = 'Lite OS'
    $b = Read-JsonSafe -Path (Join-Path $RepoRoot 'image\branding.json')
    if ($b.Ok) {
        $n = [string](Get-Prop $b.Data 'name' '')
        $n = ($n -replace '["\x00-\x1F]', '' -replace '[^\x20-\x7E]', '').Trim()
        if ($n) { $brandName = $n }
    }
    $removalCatalog = Read-JsonSafe -Path (Join-Path $RepoRoot 'image\removals.json')
    $appsCatalog = Read-JsonSafe -Path (Join-Path $RepoRoot 'tweaks\apps-remove.json')

    # -----------------------------------------------------------------------------------------
    # 1. ISO
    # -----------------------------------------------------------------------------------------
    Write-Host ''
    Write-Host '[1/4] ISO' -ForegroundColor Cyan
    if ($isoIsFolder) {
        $isoRoot = $script:IsoFull.TrimEnd('\')
        Write-VerifyLog -Message ('Using the extracted ISO folder {0}' -f $isoRoot)
    } else {
        $disk = Get-DiskImage -ImagePath $script:IsoFull
        if (-not $disk.Attached) {
            Mount-DiskImage -ImagePath $script:IsoFull -StorageType ISO -Access ReadOnly | Out-Null
            $script:IsoAttachedByUs = $true
        }
        $letter = $null
        for ($i = 0; $i -lt 30 -and -not $letter; $i++) {
            $vol = Get-DiskImage -ImagePath $script:IsoFull | Get-Volume -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($vol -and ("$($vol.DriveLetter)" -match '^[A-Za-z]$')) { $letter = "$($vol.DriveLetter)" } else { Start-Sleep -Milliseconds 500 }
        }
        if (-not $letter) { throw 'The ISO was attached but got no drive letter (automount disabled?). Extract it to a folder and pass that folder as -IsoPath.' }
        $isoRoot = $letter + ':'
        Write-VerifyLog -Message ('ISO attached read-only as {0}\' -f $isoRoot)
        Invoke-Check 'iso.volume-label' {
            $label = [string]$vol.FileSystemLabel
            if ($label -match '^[A-Z0-9_\-]*LITEOS') { Add-Check 'iso.volume-label' 'pass' ('volume label ' + $label) }
            else { Add-Check 'iso.volume-label' 'info' ('volume label "' + $label + '" (Lite OS uses LITEOS_<build> by default)') }
        }
    }

    Invoke-Check 'iso.boot-files' {
        $missing = @(@('setup.exe', 'sources\boot.wim', 'boot\etfsboot.com', 'efi\microsoft\boot\efisys.bin', 'efi\boot\bootx64.efi', 'bootmgr', 'bootmgr.efi') |
                Where-Object { -not (Test-Path -LiteralPath (Join-Path $isoRoot $_)) })
        if ($missing.Count -eq 0) { Add-Check 'iso.boot-files' 'pass' 'setup.exe, boot.wim and the BIOS + UEFI boot files are present' }
        else { Add-Check 'iso.boot-files' 'fail' ('missing: ' + ($missing -join ', ')) }
    }

    Invoke-Check 'iso.install-image' {
        $w = Join-Path $isoRoot 'sources\install.wim'
        if (Test-Path -LiteralPath $w -PathType Leaf) {
            $script:FoundWim = $w
            Add-Check 'iso.install-image' 'pass' ('sources\install.wim ({0:N2} GB)' -f ((Get-Item -LiteralPath $w).Length / 1GB))
        } elseif (Test-Path -LiteralPath (Join-Path $isoRoot 'sources\install.swm') -PathType Leaf) {
            $script:FoundWim = Join-Path $isoRoot 'sources\install.swm'
            Add-Check 'iso.install-image' 'warn' 'install.wim is split (install*.swm, -SplitWim): metadata is checked, the image itself is not mounted'
        } elseif (Test-Path -LiteralPath (Join-Path $isoRoot 'sources\install.esd') -PathType Leaf) {
            $script:FoundWim = Join-Path $isoRoot 'sources\install.esd'
            Add-Check 'iso.install-image' 'fail' 'sources\install.esd found: the Lite OS builder always writes sources\install.wim (is this an unmodified Microsoft ISO?)'
        } else {
            Add-Check 'iso.install-image' 'fail' 'no sources\install.wim / install.esd / install.swm'
        }
    }
    if (Test-Path variable:script:FoundWim) { $wim = $script:FoundWim }

    Invoke-Check 'iso.autounattend' {
        $p = Join-Path $isoRoot 'autounattend.xml'
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Add-Check 'iso.autounattend' 'fail' 'autounattend.xml is missing at the ISO root'; return }
        $doc = New-Object System.Xml.XmlDocument
        $doc.XmlResolver = $null
        $doc.LoadXml([IO.File]::ReadAllText($p))
        $problems = New-Object System.Collections.Generic.List[string]
        if ($doc.DocumentElement.LocalName -ne 'unattend' -or $doc.DocumentElement.NamespaceURI -ne 'urn:schemas-microsoft-com:unattend') { $problems.Add('root is not <unattend> in the unattend namespace') }
        foreach ($f in @('DiskConfiguration', 'ImageInstall', 'InstallTo', 'InstallToAvailablePartition', 'CreatePartitions', 'ModifyPartitions', 'WillWipeDisk', 'LocalAccounts', 'AutoLogon', 'AdministratorPassword')) {
            if ($doc.SelectNodes("//*[local-name()='$f']").Count -gt 0) { $problems.Add("contains <$f>") }
        }
        foreach ($pk in @($doc.SelectNodes("//*[local-name()='ProductKey']"))) {
            $ud = $pk.ParentNode
            $okPlace = ($null -ne $ud -and $ud.LocalName -eq 'UserData' -and $null -ne $ud.ParentNode -and $ud.ParentNode.GetAttribute('name') -eq 'Microsoft-Windows-Setup')
            if (-not $okPlace) { $problems.Add('ProductKey outside windowsPE Microsoft-Windows-Setup UserData') }
            if (-not [string]::IsNullOrWhiteSpace($pk.InnerText)) { $problems.Add('ProductKey holds a key') }
        }
        $first = $false
        foreach ($node in @($doc.SelectNodes("//*[local-name()='CommandLine']"))) { if ($node.InnerText -like '*C:\LiteOS\LiteOS.ps1*-FirstLogon*') { $first = $true } }
        if (-not $first) { $problems.Add('FirstLogonCommands do not run C:\LiteOS\LiteOS.ps1 -FirstLogon') }
        $bypass = ([IO.File]::ReadAllText($p) -match 'LabConfig')
        if ($problems.Count -eq 0) { Add-Check 'iso.autounattend' 'pass' ('safe: no disk, key or account settings; FirstLogon runs LiteOS.ps1; requirement bypass ' + $(if ($bypass) { 'on' } else { 'off' })) }
        else { Add-Check 'iso.autounattend' 'fail' ($problems -join '; ') }
    }

    Invoke-Check 'iso.boot-wim' {
        $bw = Join-Path $isoRoot 'sources\boot.wim'
        if (-not (Test-Path -LiteralPath $bw -PathType Leaf)) { Add-Check 'iso.boot-wim' 'fail' 'sources\boot.wim is missing'; return }
        $bi = @(Get-WindowsImage -ImagePath $bw -LogPath $script:DismLog)
        $setup = @($bi | Where-Object { $_.ImageName -like '*Setup*' })
        if ($bi.Count -ge 2 -and $setup.Count -ge 1) { Add-Check 'iso.boot-wim' 'pass' ('{0} images, Setup = index {1}' -f $bi.Count, $setup[0].ImageIndex) }
        else { Add-Check 'iso.boot-wim' 'fail' ('{0} image(s), no Windows Setup image' -f $bi.Count) }
    }

    # -----------------------------------------------------------------------------------------
    # 2. install.wim metadata
    # -----------------------------------------------------------------------------------------
    Write-Host ''
    Write-Host '[2/4] install.wim' -ForegroundColor Cyan
    if (-not $wim) { throw 'No install image on the ISO; nothing more to check.' }
    $images = @(Get-WindowsImage -ImagePath $wim -LogPath $script:DismLog)
    if ($images.Count -eq 1) { Add-Check 'wim.single-index' 'pass' 'exactly one image' }
    else { Add-Check 'wim.single-index' 'fail' ('{0} images: {1} (the builder keeps only the chosen edition)' -f $images.Count, ((@($images | ForEach-Object { '[{0}] {1}' -f $_.ImageIndex, $_.ImageName })) -join ', ')) }
    if ($images.Count -eq 0) { throw 'install image has no editions.' }
    $image = Get-WindowsImage -ImagePath $wim -Index ([int]$images[0].ImageIndex) -LogPath $script:DismLog
    $imageName = [string]$image.ImageName
    $imageBuild = [int]$image.Build
    $buildText = '{0}.{1}' -f $imageBuild, $image.SPBuild

    if (-not $Mode) {
        if ($imageName -match '\s(Lite|Core)$') { $Mode = $Matches[1] }
        else { $Mode = 'Lite'; Write-VerifyLog -Color Yellow -Message ('Mode not given and not in the image name "{0}"; checking the Lite promises.' -f $imageName) }
    }
    if (-not $ExpectedName) { $ExpectedName = '{0} {1}' -f $brandName, $Mode }
    Write-VerifyLog -Message ('Mode: {0}; expected image name: {1}' -f $Mode, $ExpectedName)

    Invoke-Check 'wim.name' {
        if ($imageName -ceq $ExpectedName) { Add-Check 'wim.name' 'pass' ('image name "' + $imageName + '"') }
        else { Add-Check 'wim.name' 'fail' ('image name "' + $imageName + '", expected "' + $ExpectedName + '"') }
    }
    Invoke-Check 'wim.build' {
        if ([int]$image.MajorVersion -eq 10 -and $imageBuild -ge $MinBuild) { Add-Check 'wim.build' 'pass' ('build ' + $buildText + ' (>= ' + $MinBuild + ')') }
        else { Add-Check 'wim.build' 'fail' ('build ' + $buildText + ', need >= ' + $MinBuild) }
    }
    Invoke-Check 'wim.edition' {
        $arch = [int]$image.Architecture
        $type = [string]$image.InstallationType
        $msg = 'edition {0} ({1}), {2}, architecture id {3}' -f $image.EditionId, $type, $(if ($arch -eq 9) { 'x64' } else { 'NOT x64' }), $arch
        if ($arch -eq 9 -and $type -eq 'Client') { Add-Check 'wim.edition' 'pass' $msg } else { Add-Check 'wim.edition' 'fail' $msg }
    }

    # -----------------------------------------------------------------------------------------
    # 3. Mounted image (read-only)
    # -----------------------------------------------------------------------------------------
    Write-Host ''
    Write-Host '[3/4] Image contents (read-only mount)' -ForegroundColor Cyan
    $canMount = (-not $NoMount) -and ([IO.Path]::GetExtension($wim) -eq '.wim')
    if (-not $canMount) {
        $why = 'skipped (-NoMount)'
        if (-not $NoMount) { $why = 'skipped (only install.wim can be mounted here)' }
        Add-Check 'image.mount' 'skip' $why
    } else {
        if (-not $WorkDir) { $WorkDir = Join-Path $env:TEMP ('LiteOS-Verify-' + $stamp) }
        $script:WorkRoot = Resolve-FullPath $WorkDir
        if (Test-Path -LiteralPath $script:WorkRoot) {
            $items = @(Get-ChildItem -LiteralPath $script:WorkRoot -Force)
            if ($items.Count -gt 0 -and -not (Test-Path -LiteralPath (Join-Path $script:WorkRoot $script:WorkMarker))) { throw "WorkDir '$($script:WorkRoot)' is not empty and was not created by Test-LiteOSImage.ps1." }
            foreach ($m in @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue)) {
                if (([string]$m.Path).StartsWith($script:WorkRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    Write-VerifyLog -Color Yellow -Message ('Discarding a mount left by an earlier run: ' + $m.Path)
                    Dismount-WindowsImage -Path $m.Path -Discard -LogPath $script:DismLog | Out-Null
                }
            }
        } else {
            New-Item -ItemType Directory -Path $script:WorkRoot -Force | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $script:WorkRoot $script:WorkMarker) -Value 'Created by Lite OS Test-LiteOSImage.ps1 (read-only image check). Safe to delete.' -Encoding ASCII
        $script:WorkCreated = $true
        try {
            $space = New-Object System.IO.DriveInfo([IO.Path]::GetPathRoot($script:WorkRoot))
            if ([string]$space.DriveFormat -ne 'NTFS') { Write-VerifyLog -Color Yellow -Message ('WorkDir drive is {0}; DISM mounts need NTFS.' -f $space.DriveFormat) }
        } catch { Write-VerifyLog -Color Yellow -Message ('WorkDir should be on a local NTFS drive: ' + $_.Exception.Message) }
        $script:MountDir = Join-Path $script:WorkRoot 'mount'
        $scratch = Join-Path $script:WorkRoot 'scratch'
        foreach ($d in @($script:MountDir, $scratch)) {
            if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
        Write-VerifyLog -Message ('Mounting {0} read-only at {1} ...' -f $wim, $script:MountDir)
        try {
            Mount-WindowsImage -ImagePath $wim -Index 1 -Path $script:MountDir -ReadOnly -ScratchDirectory $scratch -LogPath $script:DismLog | Out-Null
            $script:Mounted = $true
        } catch {
            # Some DISM versions refuse a WIM on a read-only ISO volume: retry from a local copy.
            $first = $_.Exception.Message
            Write-VerifyLog -Color Yellow -Message ('Read-only mount from the ISO failed ({0}); copying install.wim to the work folder and retrying.' -f (ConvertTo-OneLine $first 200))
            try { Dismount-WindowsImage -Path $script:MountDir -Discard -LogPath $script:DismLog -ErrorAction SilentlyContinue | Out-Null } catch { Write-Verbose 'Nothing to discard.' }
            $copy = Join-Path $script:WorkRoot 'install.wim'
            Copy-Item -LiteralPath $wim -Destination $copy -Force
            (Get-Item -LiteralPath $copy).IsReadOnly = $false
            # a fresh, empty mount folder (DISM may still list the failed one)
            $script:MountDir = Join-Path $script:WorkRoot 'mount2'
            if (Test-Path -LiteralPath $script:MountDir) { Remove-Item -LiteralPath $script:MountDir -Recurse -Force }
            New-Item -ItemType Directory -Path $script:MountDir -Force | Out-Null
            Mount-WindowsImage -ImagePath $copy -Index 1 -Path $script:MountDir -ReadOnly -ScratchDirectory $scratch -LogPath $script:DismLog | Out-Null
            $script:Mounted = $true
        }
        Add-Check 'image.mount' 'pass' 'install.wim index 1 mounted read-only'
        $mnt = $script:MountDir
        $payload = Join-Path $mnt 'LiteOS'
        $state = Join-Path $mnt 'ProgramData\LiteOS'
        if (-not (Test-Path -LiteralPath $filesDir)) { New-Item -ItemType Directory -Path $filesDir -Force | Out-Null }

        # Copies of the small image files for the report (never binaries).
        $copies = [ordered]@{
            'ProgramData\LiteOS\config.json'                                             = 'config.json'
            'ProgramData\LiteOS\build-info.json'                                         = 'build-info.json'
            'ProgramData\LiteOS\backup\backup-image.json'                                = 'backup-image.json'
            'LiteOS\deferred.json'                                                       = 'deferred.json'
            'LiteOS\installers\installers.json'                                          = 'installers.json'
            'Windows\Setup\Scripts\SetupComplete.cmd'                                    = 'SetupComplete.cmd.txt'
            'Users\Default\AppData\Local\Microsoft\Windows\Shell\LayoutModification.json' = 'LayoutModification.json'
            'Windows\OEM\TaskbarLayoutModification.xml'                                  = 'TaskbarLayoutModification.xml'
        }
        foreach ($rel in @($copies.Keys)) {
            $src = Join-Path $mnt $rel
            try {
                if ((Test-Path -LiteralPath $src -PathType Leaf) -and (Get-Item -LiteralPath $src).Length -lt 20MB) {
                    Copy-Item -LiteralPath $src -Destination (Join-Path $filesDir $copies[$rel]) -Force
                }
            } catch { Write-VerifyLog -Color Yellow -Message ('Could not copy {0} for the report: {1}' -f $rel, $_.Exception.Message) }
        }

        Invoke-Check 'payload' {
            $need = @('LiteOS.ps1', 'Revert-LiteOS.ps1', 'Start-LiteOS.cmd', 'src\LiteOS.Engine.psm1')
            $missing = @($need | Where-Object { -not (Test-Path -LiteralPath (Join-Path $payload $_) -PathType Leaf) })
            $tw = @(Get-ChildItem -LiteralPath (Join-Path $payload 'tweaks') -Filter '*.json' -File -ErrorAction SilentlyContinue)
            if ($tw.Count -eq 0) { $missing += 'tweaks\*.json' }
            if ($missing.Count -eq 0) { Add-Check 'payload' 'pass' ('C:\LiteOS has LiteOS.ps1, Revert-LiteOS.ps1, the engine and {0} tweak files' -f $tw.Count) }
            else { Add-Check 'payload' 'fail' ('C:\LiteOS is missing: ' + ($missing -join ', ')) }
        }

        Invoke-Check 'payload.installers' {
            $j = Read-JsonSafe -Path (Join-Path $payload 'installers\installers.json')
            if (-not $j.Ok) {
                if ($j.Error -eq 'missing') { Add-Check 'payload.installers' 'info' 'no baked installers (C:\LiteOS\installers\installers.json absent)' }
                else { Add-Check 'payload.installers' 'fail' ('installers.json ' + $j.Error) }
                return
            }
            $names = New-Object System.Collections.Generic.List[string]
            $missing = New-Object System.Collections.Generic.List[string]
            foreach ($e in @(Get-Prop $j.Data 'installers' @())) {
                $f = [string](Get-Prop $e 'file' '')
                $names.Add([string](Get-Prop $e 'name' $f))
                if (-not $f -or -not (Test-Path -LiteralPath (Join-Path $payload ('installers\' + $f)) -PathType Leaf)) { $missing.Add($f) }
            }
            if ($missing.Count -gt 0) { Add-Check 'payload.installers' 'fail' ('listed but missing: ' + ($missing -join ', ')) }
            elseif ($names.Count -eq 0) { Add-Check 'payload.installers' 'warn' 'installers.json lists no installers' }
            else { Add-Check 'payload.installers' 'pass' ('{0} installer(s): {1}' -f $names.Count, ($names -join ', ')) }
        }

        Invoke-Check 'setupcomplete' {
            $p = Join-Path $mnt 'Windows\Setup\Scripts\SetupComplete.cmd'
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Add-Check 'setupcomplete' 'fail' 'C:\Windows\Setup\Scripts\SetupComplete.cmd is missing'; return }
            $bytes = [IO.File]::ReadAllBytes($p)
            $nonAscii = @($bytes | Where-Object { $_ -gt 127 -or $_ -eq 0 }).Count
            $text = [Text.Encoding]::ASCII.GetString($bytes)
            $problems = @()
            if ($nonAscii -gt 0) { $problems += 'not plain ASCII' }
            if ($text -notmatch '(?i)C:\\LiteOS\\LiteOS\.ps1\s+-SetupComplete') { $problems += 'does not run C:\LiteOS\LiteOS.ps1 -SetupComplete' }
            if ($text -notmatch "`r`n") { $problems += 'no CRLF line ends' }
            if ($problems.Count -eq 0) { Add-Check 'setupcomplete' 'pass' 'SetupComplete.cmd runs LiteOS.ps1 -SetupComplete (ASCII, CRLF)' }
            else { Add-Check 'setupcomplete' 'fail' ($problems -join '; ') }
        }

        # State files
        $config = $null; $buildInfo = $null; $backup = $null; $deferred = $null
        Invoke-Check 'state.config' {
            $j = Read-JsonSafe -Path (Join-Path $state 'config.json')
            if (-not $j.Ok) { Add-Check 'state.config' 'fail' ('C:\ProgramData\LiteOS\config.json ' + $j.Error); return }
            $script:VConfig = $j.Data
            $m = [string](Get-Prop $j.Data 'mode' '')
            if ($m -eq $Mode) { Add-Check 'state.config' 'pass' ('config.json: mode {0}, level {1}' -f $m, (Get-Prop $j.Data 'level' '?')) }
            else { Add-Check 'state.config' 'fail' ('config.json mode is "{0}", expected {1}' -f $m, $Mode) }
        }
        if (Test-Path variable:script:VConfig) { $config = $script:VConfig }

        Invoke-Check 'state.build-info' {
            $j = Read-JsonSafe -Path (Join-Path $state 'build-info.json')
            if (-not $j.Ok) { Add-Check 'state.build-info' 'warn' ('C:\ProgramData\LiteOS\build-info.json ' + $j.Error); return }
            $script:VBuildInfo = $j.Data
            $problems = @()
            if ([string](Get-Prop $j.Data 'mode' '') -ne $Mode) { $problems += ('mode "{0}"' -f (Get-Prop $j.Data 'mode' '')) }
            $n = [string](Get-Prop $j.Data 'imageName' '')
            if ($n -and $n -cne $imageName) { $problems += ('imageName "{0}" but the WIM says "{1}"' -f $n, $imageName) }
            if ($problems.Count -eq 0) { Add-Check 'state.build-info' 'pass' ('build-info.json: {0}, built {1} with {2}' -f (Get-Prop $j.Data 'build' '?'), (Get-Prop $j.Data 'builtAt' '?'), (Get-Prop $j.Data 'builder' '?')) }
            else { Add-Check 'state.build-info' 'fail' ($problems -join '; ') }
        }
        if (Test-Path variable:script:VBuildInfo) { $buildInfo = $script:VBuildInfo }

        Invoke-Check 'state.backup-image' {
            $j = Read-JsonSafe -Path (Join-Path $state 'backup\backup-image.json')
            if (-not $j.Ok) { Add-Check 'state.backup-image' 'fail' ('C:\ProgramData\LiteOS\backup\backup-image.json ' + $j.Error + ' (baked tweaks could not be reverted)'); return }
            $script:VBackup = $j.Data
            $src = [string](Get-Prop $j.Data 'source' '')
            $n = @(Get-Prop $j.Data 'entries' @()).Count
            if ($src -eq 'image') { Add-Check 'state.backup-image' 'pass' ('backup-image.json: source image, {0} revert entries' -f $n) }
            else { Add-Check 'state.backup-image' 'fail' ('backup-image.json source is "{0}", expected "image"' -f $src) }
        }
        if (Test-Path variable:script:VBackup) { $backup = $script:VBackup }

        Invoke-Check 'state.deferred' {
            $p = Join-Path $payload 'deferred.json'
            if (-not (Test-Path -LiteralPath $p -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $state 'deferred.json') -PathType Leaf)) { $p = Join-Path $state 'deferred.json' }
            $j = Read-JsonSafe -Path $p
            if (-not $j.Ok) { Add-Check 'state.deferred' 'fail' ('C:\LiteOS\deferred.json ' + $j.Error); return }
            if (-not (Test-Prop $j.Data 'tweaks')) { Add-Check 'state.deferred' 'fail' 'deferred.json has no "tweaks" list'; return }
            $script:VDeferred = $j.Data
            $ids = @(@(Get-Prop $j.Data 'tweaks' @()) | ForEach-Object { [string](Get-Prop $_ 'id' '') })
            Add-Check 'state.deferred' 'pass' ('deferred.json: {0} deferred tweak(s) / removal(s) for SetupComplete or first logon' -f $ids.Count)
        }
        if (Test-Path variable:script:VDeferred) { $deferred = $script:VDeferred }
        $deferredActions = @(Get-DeferredActions -Deferred $deferred)

        # Image removals: applied (build-info.json) vs. expected for the mode (removals.json defaults,
        # build-info removalsInclude / removalsExclude; Exclude wins).
        $appliedRemovals = @()
        $expectedRemovals = @()
        if ($null -ne $buildInfo) { $appliedRemovals = @(@(Get-Prop $buildInfo 'removals' @()) | ForEach-Object { [string]$_ }) }
        if ($removalCatalog.Ok) {
            $rInc = @(); $rExc = @()
            if ($null -ne $buildInfo) {
                $rInc = @(@(Get-Prop $buildInfo 'removalsInclude' @()) | ForEach-Object { [string]$_ })
                $rExc = @(@(Get-Prop $buildInfo 'removalsExclude' @()) | ForEach-Object { [string]$_ })
            }
            foreach ($r in @(Get-Prop $removalCatalog.Data 'removals' @())) {
                $rid = [string](Get-Prop $r 'id' '')
                if (-not $rid) { continue }
                $rm = ([string](Get-Prop $r 'mode' '')).ToLowerInvariant()
                $take = [bool](Get-Prop $r 'default' $false) -and ($rm -eq 'lite' -or ($rm -eq 'core' -and $Mode -eq 'Core'))
                if (Test-IdMatch -Id $rid -Patterns $rInc) { $take = $true }
                if (Test-IdMatch -Id $rid -Patterns $rExc) { $take = $false }
                if ($take) { $expectedRemovals += $rid }
            }
        } elseif ($Mode -eq 'Core') {
            $expectedRemovals = @('image.defender', 'image.windows-update')
        }
        Invoke-Check 'removals' {
            if ($null -eq $buildInfo) { Add-Check 'removals' 'skip' 'no build-info.json'; return }
            $missing = @($expectedRemovals | Where-Object { $appliedRemovals -notcontains $_ })
            $coreHit = @($appliedRemovals | Where-Object { $_ -match '^image\.(defender|windows-update|edge|winre)$' })
            if ($Mode -eq 'Lite' -and $coreHit.Count -gt 0) { Add-Check 'removals' 'warn' ('Lite build with Core removals: ' + ($coreHit -join ', ') + ' (the Lite promises do not hold)'); return }
            if ($missing.Count -eq 0) { Add-Check 'removals' 'pass' ('{0} removal(s) applied: {1}' -f $appliedRemovals.Count, ($appliedRemovals -join ', ')) }
            else { Add-Check 'removals' 'warn' ('expected for {0} but not applied (failed, or not in this ISO - see the build report): {1}' -f $Mode, ($missing -join ', ')) }
        }

        Invoke-Check 'state.acl' {
            $problems = @()
            foreach ($pair in @(@($payload, 'C:\LiteOS'), @($state, 'C:\ProgramData\LiteOS'))) {
                if (-not (Test-Path -LiteralPath $pair[0])) { $problems += ($pair[1] + ' missing'); continue }
                foreach ($x in @(Get-AclProblems -Path $pair[0])) { $problems += ($pair[1] + ': ' + $x) }
            }
            if ($problems.Count -eq 0) { Add-Check 'state.acl' 'pass' 'C:\LiteOS and C:\ProgramData\LiteOS: owner Administrators, Users read only' }
            else { Add-Check 'state.acl' 'fail' ($problems -join '; ') }
        }

        # Layout
        Invoke-Check 'layout.start' {
            $p = Join-Path $mnt 'Users\Default\AppData\Local\Microsoft\Windows\Shell\LayoutModification.json'
            $j = Read-JsonSafe -Path $p
            if (-not $j.Ok) { Add-Check 'layout.start' 'fail' ('Default profile LayoutModification.json ' + $j.Error); return }
            $primary = @(Get-Prop $j.Data 'primaryOEMPins' @())
            $all = @($primary) + @(Get-Prop $j.Data 'secondaryOEMPins' @()) + @(Get-Prop $j.Data 'firstRunOEMPins' @())
            $edge = @($all | Where-Object { $null -ne $_ } | Where-Object { (($_.PSObject.Properties | ForEach-Object { [string]$_.Value }) -join ' ') -match '(?i)MSEdge|Microsoft Edge\.lnk|Microsoft\.MicrosoftEdge' })
            if ($primary.Count -eq 0) { Add-Check 'layout.start' 'fail' 'LayoutModification.json has no primaryOEMPins (OEM Start format)'; return }
            if ($Mode -eq 'Core' -and $edge.Count -gt 0) { Add-Check 'layout.start' 'warn' ('{0} OEM pins, but {1} Edge pin(s) in Core' -f $all.Count, $edge.Count); return }
            Add-Check 'layout.start' 'pass' ('Default profile LayoutModification.json: {0} OEM Start pins ({1} on page 1)' -f $all.Count, $primary.Count)
        }
        Invoke-Check 'layout.taskbar' {
            $p = Join-Path $mnt 'Windows\OEM\TaskbarLayoutModification.xml'
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Add-Check 'layout.taskbar' 'warn' 'C:\Windows\OEM\TaskbarLayoutModification.xml is missing (Windows default taskbar pins)'; return }
            $doc = New-Object System.Xml.XmlDocument
            $doc.XmlResolver = $null
            $doc.LoadXml([IO.File]::ReadAllText($p))
            $pins = @($doc.SelectNodes("//*[local-name()='DesktopApp' or local-name()='UWA']")).Count
            $shell = Test-Path -LiteralPath (Join-Path $mnt 'Users\Default\AppData\Local\Microsoft\Windows\Shell\TaskbarLayoutModification.xml') -PathType Leaf
            Add-Check 'layout.taskbar' 'pass' ('taskbar layout with {0} pins (OEM folder{1})' -f $pins, $(if ($shell) { ' + Default profile' } else { '' }))
        }

        # Components that must stay
        Invoke-Check 'image.winre' {
            if (Test-Path -LiteralPath (Join-Path $mnt 'Windows\System32\Recovery\Winre.wim') -PathType Leaf) { Add-Check 'image.winre' 'pass' 'Winre.wim kept in the image (24H2+ Setup needs it; Core disables WinRE after Setup)' }
            else { Add-Check 'image.winre' 'fail' 'Windows\System32\Recovery\Winre.wim is missing: Windows 11 24H2+ Setup fails without it' }
        }
        Invoke-Check 'image.webview2' {
            $wv = @(Get-ChildItem -LiteralPath (Join-Path $mnt 'Program Files (x86)\Microsoft\EdgeWebView\Application') -Directory -ErrorAction SilentlyContinue)
            $eu = Test-Path -LiteralPath (Join-Path $mnt 'Program Files (x86)\Microsoft\EdgeUpdate')
            if ($wv.Count -gt 0 -and $eu) { Add-Check 'image.webview2' 'pass' 'WebView2 Runtime and Edge Update are present' }
            elseif ($wv.Count -gt 0) { Add-Check 'image.webview2' 'warn' 'WebView2 Runtime present, but no Program Files (x86)\Microsoft\EdgeUpdate (WebView2 will not update)' }
            else { Add-Check 'image.webview2' 'warn' 'no WebView2 Runtime in Program Files (x86)\Microsoft\EdgeWebView (it may not be preinstalled in this ISO; it must never be removed)' }
        }
        Invoke-Check 'image.edge' {
            $edgeExe = Test-Path -LiteralPath (Join-Path $mnt 'Program Files (x86)\Microsoft\Edge\Application\msedge.exe') -PathType Leaf
            $edgeRemoved = $false
            if ($null -ne $buildInfo) { $edgeRemoved = (@(Get-Prop $buildInfo 'removals' @()) -contains 'image.edge') }
            if ($Mode -eq 'Lite' -and -not $edgeRemoved) {
                if ($edgeExe) { Add-Check 'image.edge' 'pass' 'Edge browser present (Lite)' } else { Add-Check 'image.edge' 'info' 'Edge browser files not found in the image (Windows may install it during Setup)' }
            } else {
                if ($edgeExe) { Add-Check 'image.edge' 'warn' 'image.edge was applied but msedge.exe is still in the image' } else { Add-Check 'image.edge' 'pass' 'Edge browser removed' }
            }
        }

        # Provisioned apps
        Invoke-Check 'appx' {
            $prov = @(Get-AppxProvisionedPackage -Path $mnt -LogPath $script:DismLog)
            $names = @($prov | ForEach-Object { [string]$_.DisplayName })
            Write-VerifyLog -Message ('{0} provisioned apps in the image' -f $names.Count)
            try { Write-Utf8File -Path (Join-Path $filesDir 'provisioned-apps.txt') -Text ((@($names | Sort-Object)) -join "`r`n") } catch { Write-Verbose 'Could not write the app list.' }
            $removed = @()
            if ($null -ne $buildInfo) { $removed = @(@(Get-Prop $buildInfo 'removedProvisionedApps' @()) | ForEach-Object { [string]$_ }) }
            if ($null -eq $buildInfo) { Add-Check 'appx.removed' 'skip' 'no build-info.json: the list of removed apps is unknown' }
            elseif ($removed.Count -eq 0) { Add-Check 'appx.removed' 'info' 'the builder removed no provisioned apps' }
            else {
                $still = @($removed | Where-Object { $names -contains $_ })
                if ($still.Count -eq 0) { Add-Check 'appx.removed' 'pass' ('{0} removed apps are absent: {1}' -f $removed.Count, ($removed -join ', ')) }
                else { Add-Check 'appx.removed' 'fail' ('still provisioned although removed: ' + ($still -join ', ')) }
            }

            # Default app rules of the mode (warning only: Exclude / Include and the source ISO decide).
            if ($appsCatalog.Ok -and $null -ne $config) {
                $lvl = [string](Get-Prop $config 'level' 'Balanced')
                $exc = @(@(Get-Prop $config 'exclude' @()) | ForEach-Object { [string]$_ })
                $protected = @(@(Get-Prop $appsCatalog.Data 'protected' @()) | ForEach-Object { [string]$_ })
                $left = New-Object System.Collections.Generic.List[string]
                foreach ($p in @(Get-Prop $appsCatalog.Data 'packages' @())) {
                    $match = [string](Get-Prop $p 'match' '')
                    if (-not $match -or -not [bool](Get-Prop $p 'default' $false)) { continue }
                    $pl = [string](Get-Prop $p 'level' 'balanced')
                    if ($pl -eq 'extreme' -and $lvl -ne 'Extreme') { continue }
                    if (Test-IdMatch -Id ('apps.remove.' + $match.ToLowerInvariant()) -Patterns $exc) { continue }
                    foreach ($n in $names) {
                        if ($n -like $match -and -not (Test-LikeAny -Name $n -Patterns $protected) -and -not $left.Contains($n)) { $left.Add($n) }
                    }
                }
                if ($left.Count -eq 0) { Add-Check 'appx.defaults' 'pass' ('no default {0} app rule matches a provisioned app any more' -f $lvl) }
                else { Add-Check 'appx.defaults' 'warn' ('still provisioned though a default {0} rule matches: {1}' -f $lvl, ($left -join ', ')) }
            } else {
                Add-Check 'appx.defaults' 'skip' 'tweaks\apps-remove.json or config.json not available'
            }

            $missReq = @($script:KeepAppsRequired | Where-Object { $names -notcontains $_ })
            $missGame = @($script:KeepAppsGaming | Where-Object { $names -notcontains $_ })
            $wrongly = @(@($script:KeepAppsRequired) + @($script:KeepAppsGaming) | Where-Object { $removed -contains $_ })
            if ($wrongly.Count -gt 0) { Add-Check 'appx.kept' 'fail' ('the builder removed protected apps: ' + ($wrongly -join ', ')) }
            elseif ($missReq.Count -gt 0) { Add-Check 'appx.kept' 'fail' ('not provisioned: ' + ($missReq -join ', ')) }
            elseif ($missGame.Count -gt 0) { Add-Check 'appx.kept' 'warn' ('Store and App Installer kept; not in this image: ' + ($missGame -join ', ') + ' (installable from the Store)') }
            else { Add-Check 'appx.kept' 'pass' 'Microsoft Store, App Installer (winget), Xbox app, Game Bar, Xbox Identity / TCUI / speech overlay are provisioned' }
            $sec = ($names -contains 'Microsoft.SecHealthUI')
            if ($Mode -eq 'Lite') {
                if ($sec) { Add-Check 'appx.security-app' 'pass' 'Windows Security app (SecHealthUI) kept' }
                elseif ($removed -contains 'Microsoft.SecHealthUI') { Add-Check 'appx.security-app' 'fail' 'Lite removed the Windows Security app' }
                else { Add-Check 'appx.security-app' 'warn' 'Windows Security app (SecHealthUI) is not provisioned in this image' }
            } else {
                Add-Check 'appx.security-app' 'info' $(if ($sec) { 'Windows Security app still provisioned (image.defender excluded?)' } else { 'Windows Security app removed (Core)' })
            }
        }

        # -------------------------------------------------------------------------------------
        # 4. Registry: copies of SYSTEM and SOFTWARE
        # -------------------------------------------------------------------------------------
        Write-Host ''
        Write-Host '[4/4] Services and policies (copies of the image registry)' -ForegroundColor Cyan
        $hiveDir = Join-Path $script:WorkRoot 'hives'
        if (Test-Path -LiteralPath $hiveDir) { Remove-Item -LiteralPath $hiveDir -Recurse -Force }
        New-Item -ItemType Directory -Path $hiveDir -Force | Out-Null
        try {
            foreach ($h in @('SYSTEM', 'SOFTWARE')) {
                $srcDir = Join-Path $mnt 'Windows\System32\config'
                $dst = Join-Path $hiveDir $h
                New-Item -ItemType Directory -Path $dst -Force | Out-Null
                foreach ($f in @($h, ($h + '.LOG1'), ($h + '.LOG2'))) {
                    $sf = Join-Path $srcDir $f
                    if (Test-Path -LiteralPath $sf -PathType Leaf) {
                        Copy-Item -LiteralPath $sf -Destination (Join-Path $dst $f) -Force
                        (Get-Item -LiteralPath (Join-Path $dst $f)).IsReadOnly = $false
                    }
                }
                Mount-VerifyHive -Name ('LITE_VERIFY_' + $h) -File (Join-Path $dst $h)
            }
            $sysRoot = 'HKLM\LITE_VERIFY_SYSTEM'
            $swRoot = 'HKLM\LITE_VERIFY_SOFTWARE'
            $cur = Get-RegValue -Key ($sysRoot + '\Select') -Name 'Current'
            $cs = 'ControlSet001'
            if ($cur.Exists -and $cur.Data -is [int64] -and $cur.Data -ge 1) { $cs = 'ControlSet{0:D3}' -f [int]$cur.Data }
            Write-VerifyLog -Message ('Image control set: ' + $cs)

            $changedServices = @(Get-BackupServiceNames -Backup $backup)
            # Removals to hold the image to: the ones the builder applied, plus (Core) the Defender /
            # Windows Update removals whenever they were not excluded - a removal that FAILED must not
            # silently turn its checks into "not applied".
            $applied = @($appliedRemovals)
            if ($Mode -eq 'Core') {
                foreach ($rid in @('image.defender', 'image.windows-update')) {
                    if ($applied -notcontains $rid -and $expectedRemovals -contains $rid) { $applied += $rid }
                }
            }
            $svcRows = New-Object System.Collections.ArrayList

            function Get-ImageService {
                param([string]$Name)
                $k = '{0}\{1}\Services\{2}' -f $sysRoot, $cs, $Name
                $s = Get-RegValue -Key $k -Name 'Start'
                $d = Get-RegValue -Key $k -Name 'DelayedAutostart'
                $start = $null
                $delayed = $null
                if ($s.Exists) { $start = [int64]$s.Data }
                if ($d.Exists) { $delayed = [int64]$d.Data }
                return New-Object PSObject -Property @{ Name = $Name; Start = $start; Delayed = $delayed; Text = (Get-ServiceStartText $start $delayed) }
            }

            if ($Mode -eq 'Lite') {
                foreach ($svc in @($script:LiteServices.Keys)) {
                    Invoke-Check ('service.' + $svc) {
                        $s = Get-ImageService -Name $svc
                        [void]$svcRows.Add([ordered]@{ name = $svc; start = $s.Start; delayed = $s.Delayed })
                        $byBuilder = ($changedServices -contains $svc.ToLowerInvariant())
                        $byDeferred = @($deferredActions | Where-Object { $_.Type -eq 'service' -and $_.Name -eq $svc }).Count -gt 0
                        if ($null -eq $s.Start) { Add-Check ('service.' + $svc) 'info' 'not in this image'; return }
                        if ($s.Start -eq 4) { Add-Check ('service.' + $svc) 'fail' ('DISABLED (Start=4) in a Lite image'); return }
                        if ($byBuilder) { Add-Check ('service.' + $svc) 'fail' ('Start ' + $s.Text + ': changed by the builder (backup-image.json) - Lite must leave it alone'); return }
                        if ($byDeferred) { Add-Check ('service.' + $svc) 'fail' ('Start ' + $s.Text + ': deferred.json changes it at SetupComplete - Lite must leave it alone'); return }
                        $def = $script:LiteServices[$svc]
                        $note = ''
                        if ($null -ne $def -and [int]$def -ne [int]$s.Start) { $note = (' (usual Windows 11 value {0}; unchanged by Lite OS)' -f $def) }
                        Add-Check ('service.' + $svc) 'pass' ('Start ' + $s.Text + ', unchanged' + $note)
                    }
                }
                Invoke-Check 'policy.windows-update' {
                    $v = Get-RegValue -Key ($swRoot + '\Policies\Microsoft\Windows\WindowsUpdate\AU') -Name 'NoAutoUpdate'
                    $dc = Get-RegValue -Key ($swRoot + '\Policies\Microsoft\Windows\WindowsUpdate') -Name 'DoNotConnectToWindowsUpdateInternetLocations'
                    if (($v.Exists -and [string]$v.Data -eq '1') -or ($dc.Exists -and [string]$dc.Data -eq '1')) { Add-Check 'policy.windows-update' 'fail' 'Windows Update is blocked by policy (NoAutoUpdate / DoNotConnectToWindowsUpdateInternetLocations = 1) in a Lite image' }
                    else { Add-Check 'policy.windows-update' 'pass' ('Windows Update not blocked by policy (NoAutoUpdate = {0})' -f $(if ($v.Exists) { $v.Data } else { 'not set' })) }
                }
                Invoke-Check 'policy.defender' {
                    $v = Get-RegValue -Key ($swRoot + '\Policies\Microsoft\Windows Defender') -Name 'DisableAntiSpyware'
                    $rt = Get-RegValue -Key ($swRoot + '\Policies\Microsoft\Windows Defender\Real-Time Protection') -Name 'DisableRealtimeMonitoring'
                    if (($v.Exists -and [string]$v.Data -eq '1') -or ($rt.Exists -and [string]$rt.Data -eq '1')) { Add-Check 'policy.defender' 'fail' 'Defender is turned off by policy in a Lite image' }
                    else { Add-Check 'policy.defender' 'pass' 'Defender is not turned off by policy' }
                }
            } else {
                Invoke-Check 'service.WinDefend' {
                    $s = Get-ImageService -Name 'WinDefend'
                    [void]$svcRows.Add([ordered]@{ name = 'WinDefend'; start = $s.Start; delayed = $s.Delayed })
                    $want = ($applied -contains 'image.defender')
                    if (-not $want) { Add-Check 'service.WinDefend' 'info' ('image.defender not applied (excluded?); Start ' + $s.Text); return }
                    if ($s.Start -eq 4) { Add-Check 'service.WinDefend' 'pass' 'Start=4 (Disabled) in Core' }
                    else { Add-Check 'service.WinDefend' 'fail' ('Start ' + $s.Text + ', expected 4 (Disabled) in Core') }
                }
                foreach ($svc in @('WdNisSvc', 'SecurityHealthService', 'wuauserv', 'UsoSvc', 'WaaSMedicSvc')) {
                    Invoke-Check ('service.' + $svc) {
                        $s = Get-ImageService -Name $svc
                        [void]$svcRows.Add([ordered]@{ name = $svc; start = $s.Start; delayed = $s.Delayed })
                        $owner = 'image.windows-update'
                        if (@('WdNisSvc', 'SecurityHealthService') -contains $svc) { $owner = 'image.defender' }
                        if (-not ($applied -contains $owner)) { Add-Check ('service.' + $svc) 'info' ($owner + ' not applied; Start ' + $s.Text); return }
                        if ($null -eq $s.Start) { Add-Check ('service.' + $svc) 'info' 'not in this image'; return }
                        if ($s.Start -eq 4) { Add-Check ('service.' + $svc) 'pass' 'Start=4 (Disabled)'; return }
                        if (Test-DeferredService -Actions $deferredActions -Service $svc) { Add-Check ('service.' + $svc) 'pass' ('Start ' + $s.Text + ' in the image; SetupComplete disables it (deferred.json)'); return }
                        Add-Check ('service.' + $svc) 'fail' ('Start ' + $s.Text + ' and nothing in deferred.json disables it (' + $owner + ')')
                    }
                }
                Invoke-Check 'policy.windows-update' {
                    if (-not ($applied -contains 'image.windows-update')) { Add-Check 'policy.windows-update' 'info' 'image.windows-update not applied'; return }
                    $v = Get-RegValue -Key ($swRoot + '\Policies\Microsoft\Windows\WindowsUpdate\AU') -Name 'NoAutoUpdate'
                    if ($v.Exists -and [string]$v.Data -eq '1') { Add-Check 'policy.windows-update' 'pass' 'NoAutoUpdate=1 (no later tweak undid it)' }
                    else { Add-Check 'policy.windows-update' 'fail' ('NoAutoUpdate is {0}, expected 1: a tweak undid image.windows-update' -f $(if ($v.Exists) { $v.Data } else { 'not set' })) }
                }
            }

            Invoke-Check 'tweaks.conflicts' {
                if (-not $removalCatalog.Ok) { Add-Check 'tweaks.conflicts' 'skip' 'image\removals.json not available'; return }
                $conf = New-Object System.Collections.Generic.List[string]
                foreach ($r in @(Get-Prop $removalCatalog.Data 'removals' @())) {
                    if ($applied -notcontains [string](Get-Prop $r 'id' '')) { continue }
                    foreach ($c in @(Get-Prop $r 'conflicts' @())) { if ($c -and -not $conf.Contains([string]$c)) { $conf.Add([string]$c) } }
                }
                if ($conf.Count -eq 0) { Add-Check 'tweaks.conflicts' 'pass' 'no applied removal declares conflicting tweaks'; return }
                $baked = @(@(Get-BackupTweakIds -Backup $backup) | Where-Object { Test-IdMatch -Id $_ -Patterns $conf.ToArray() })
                $def = @($deferredActions | Where-Object { Test-IdMatch -Id $_.Owner -Patterns $conf.ToArray() } | ForEach-Object { $_.Owner } | Select-Object -Unique)
                if ($baked.Count -eq 0 -and $def.Count -eq 0) { Add-Check 'tweaks.conflicts' 'pass' ('none of the conflicting tweaks was baked in: ' + ($conf -join ', ')) }
                else { Add-Check 'tweaks.conflicts' 'fail' ('conflicting tweaks in the image: ' + ((@($baked) + @($def)) -join ', ')) }
            }

            Invoke-Check 'branding' {
                $m = Get-RegValue -Key ($swRoot + '\Microsoft\Windows\CurrentVersion\OEMInformation') -Name 'Manufacturer'
                $md = Get-RegValue -Key ($swRoot + '\Microsoft\Windows\CurrentVersion\OEMInformation') -Name 'Model'
                $pn = Get-RegValue -Key ($swRoot + '\Microsoft\Windows NT\CurrentVersion') -Name 'ProductName'
                if ($m.Exists -and [string]$m.Data) { Add-Check 'branding' 'pass' ('OEM information: {0} / {1}; ProductName unchanged: {2}' -f $m.Data, $(if ($md.Exists) { $md.Data } else { '-' }), $(if ($pn.Exists) { $pn.Data } else { '-' })) }
                else { Add-Check 'branding' 'warn' 'no OEMInformation Manufacturer (branding not applied)' }
            }
            Invoke-Check 'setup.oobe' {
                $nro = Get-RegValue -Key ($swRoot + '\Microsoft\Windows\CurrentVersion\OOBE') -Name 'BypassNRO'
                $lx = Get-RegValue -Key ($swRoot + '\Microsoft\Windows\CurrentVersion\Explorer') -Name 'LayoutXMLPath'
                Add-Check 'setup.oobe' 'info' ('BypassNRO = {0}; taskbar LayoutXMLPath = {1}' -f $(if ($nro.Exists) { $nro.Data } else { 'not set' }), $(if ($lx.Exists) { $lx.Data } else { 'not set' }))
            }
            $script:ServiceRows = $svcRows.ToArray()
        } finally {
            foreach ($h in @($script:LoadedHives)) { [void](Dismount-VerifyHive -Name $h) }
            if ($script:LoadedHives.Count -eq 0) {
                try { Remove-Item -LiteralPath $hiveDir -Recurse -Force } catch { Write-VerifyLog -Color Yellow -Message ('Could not delete the hive copies in {0}: {1}' -f $hiveDir, $_.Exception.Message) }
            }
        }
    }
} catch {
    $script:Fatal = ConvertTo-OneLine $_.Exception.Message 600
    Write-VerifyLog -Color Red -Message ('ERROR: ' + $_.Exception.Message)
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage -and $script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $_.InvocationInfo.PositionMessage -Encoding UTF8 } catch { Write-Verbose 'Log write failed.' }
    }
} finally {
    # Cleanup: hives, image mount (discard), ISO, work folder. Never throws.
    foreach ($h in @($script:LoadedHives)) { try { [void](Dismount-VerifyHive -Name $h) } catch { Write-Verbose 'unload failed' } }
    if ($script:Mounted -and $script:MountDir) {
        try {
            Dismount-WindowsImage -Path $script:MountDir -Discard -LogPath $script:DismLog | Out-Null
            $script:Mounted = $false
            Write-VerifyLog -Message 'Image dismounted (discarded, nothing saved).'
        } catch {
            Write-VerifyLog -Color Yellow -Message ('Discard failed ({0}). Run: dism /Unmount-Image /MountDir:"{1}" /Discard   then   dism /Cleanup-Wim' -f $_.Exception.Message, $script:MountDir)
        }
    }
    if ($script:IsoAttachedByUs -and $script:IsoFull) {
        try { Dismount-DiskImage -ImagePath $script:IsoFull | Out-Null; $script:IsoAttachedByUs = $false } catch { Write-VerifyLog -Color Yellow -Message ('Could not detach the ISO: ' + $_.Exception.Message) }
    }
    if ($script:WorkCreated -and $script:WorkRoot -and -not $script:Mounted -and $script:LoadedHives.Count -eq 0) {
        # Only what this script creates; the folder itself goes when nothing else is left in it.
        foreach ($child in @('mount', 'mount2', 'scratch', 'hives', 'install.wim', $script:WorkMarker)) {
            $c = Join-Path $script:WorkRoot $child
            if (Test-Path -LiteralPath $c) {
                try { Remove-Item -LiteralPath $c -Recurse -Force } catch { Write-VerifyLog -Color Yellow -Message ('Could not delete {0}: {1}' -f $c, $_.Exception.Message) }
            }
        }
        if (@(Get-ChildItem -LiteralPath $script:WorkRoot -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $script:WorkRoot -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------------------------
$counts = [ordered]@{ pass = 0; fail = 0; warn = 0; info = 0; skip = 0 }
foreach ($c in $script:Checks) { $counts[$c['status']] = [int]$counts[$c['status']] + 1 }
$result = 'pass'
if ($counts['fail'] -gt 0) { $result = 'fail' }
if ($script:Fatal) { $result = 'error' }
$services = @()
if (Test-Path variable:script:ServiceRows) { $services = $script:ServiceRows }
$report = [ordered]@{
    tool         = 'Lite OS Test-LiteOSImage.ps1'
    version      = $script:VerifierVersion
    result       = $result
    error        = $script:Fatal
    iso          = $(if ($script:IsoFull) { Split-Path -Leaf $script:IsoFull } else { $null })
    mode         = $Mode
    imageName    = $imageName
    expectedName = $ExpectedName
    build        = $buildText
    startedAt    = $started
    finishedAt   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    counts       = $counts
    checks       = $script:Checks.ToArray()
    services     = $services
}
$md = New-Object System.Collections.Generic.List[string]
$md.Add(('### Lite OS image check: {0} - {1}' -f $(if ($Mode) { $Mode } else { '?' }), $result.ToUpperInvariant()))
$md.Add('')
$mdName = '-'
if ($imageName) { $mdName = '`' + $imageName + '`' }
$mdBuild = '-'
if ($buildText) { $mdBuild = $buildText }
$md.Add(('Image {0}, build {1}. {2} passed, {3} failed, {4} warnings, {5} info, {6} skipped.' -f $mdName, $mdBuild, $counts['pass'], $counts['fail'], $counts['warn'], $counts['info'], $counts['skip']))
if ($script:Fatal) { $md.Add(''); $md.Add(('**Could not finish:** {0}' -f $script:Fatal)) }
$md.Add('')
$md.Add('| Check | Result | Details |')
$md.Add('|---|---|---|')
foreach ($c in $script:Checks) {
    $md.Add(('| {0} | {1} | {2} |' -f $c['id'], $c['status'].ToUpperInvariant(), ([string]$c['message']).Replace('|', '/')))
}
try {
    if ($reportJson) {
        Write-Utf8File -Path $reportJson -Text (ConvertTo-Json -InputObject $report -Depth 8)
        Write-Utf8File -Path ([IO.Path]::ChangeExtension($reportJson, '.md')) -Text (($md.ToArray() -join "`r`n") + "`r`n")
    }
    if ($env:GITHUB_STEP_SUMMARY) { [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, (($md.ToArray() -join "`n") + "`n`n"), (New-Object System.Text.UTF8Encoding($false))) }
} catch {
    Write-Host ('  Could not write the report: ' + $_.Exception.Message) -ForegroundColor Yellow
}

Write-Host ''
$color = 'Green'
if ($result -ne 'pass') { $color = 'Red' }
Write-Host ('Result: {0} - {1} passed, {2} failed, {3} warnings ({4})' -f $result.ToUpperInvariant(), $counts['pass'], $counts['fail'], $counts['warn'], $reportJson) -ForegroundColor $color
if ($PassThru) { $report }
if ($script:Fatal) { exit 2 }
if ($counts['fail'] -gt 0) { exit 1 }
exit 0

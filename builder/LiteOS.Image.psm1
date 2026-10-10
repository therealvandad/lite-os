#Requires -Version 5.1
<#
    Lite OS image removals (builder/LiteOS.Image.psm1)

    Image-level removals applied to an OFFLINE-mounted install.wim by the Lite OS builder.
    The binding contract is docs/ARCHITECTURE.md, section "Lite OS image (v2)".

    Public API:
      Get-LiteOSRemovals      [-Path]                                 -> validated removal[] (throws on schema errors)
      Select-LiteOSRemovals   -Removals -Mode Lite|Core [-Include] [-Exclude]   (pure; no system access)
      Invoke-LiteOSImageRemovals -MountPath -Removals [-Hives] [-Stage All|Dism|Hives] [-WhatIf]
                                                                       -> result[] {id,name,status,message,deferred,...}
      Merge-LiteOSRemovalResults -Results                              (pure) one result per id (Dism + Hives stages)
      Invoke-LiteOSImageCleanup  -MountPath [-ResetBase] [-WhatIf]             -> result {id=image.cleanup,status,message}

    Removal types (JSON "type"):
      capability  match[]  -> Remove-WindowsCapability -Path
      feature     match[]  -> Disable-WindowsOptionalFeature -Path -Remove
      package     match[]  -> Remove-WindowsPackage -Path (only packages DISM reports removable)
      files       paths[]  -> delete after taking ownership (never under Windows\System32 unless allowSystem32:true)
      onedrive             -> remove the Default-hive "OneDriveSetup" Run entry (OneDriveSetup.exe is a
                              serviced, WinSxS-hardlinked file: it is left alone)
      edge                 -> remove the Edge browser + its Edge Update registration (NEVER WebView2; Edge
                              Update itself stays so the WebView2 Runtime keeps getting updates)
      winre                -> Winre.wim STAYS in the image (Windows 11 24H2+ Setup fails at ~5% without it);
                              WinRE is disabled after Setup (deferred SetupComplete action: reagentc /disable,
                              then delete C:\Windows\System32\Recovery\Winre.wim)
      script      script   -> run the script string with $MountPath, $Hives, $WhatIf in scope
    Optional fields:
      appx        string[] -> provisioned app DisplayName patterns removed in the DISM stage (Core only: an
                              explicit override of the Lite protected app list, e.g. Microsoft.SecHealthUI)
      conflicts   string[] -> tweak ids the builder must NOT bake in when this removal is selected
                              (e.g. image.windows-update vs. the tweaks that write NoAutoUpdate=0)

    Stages: DISM servicing (capability / feature / package and every "appx" part) must run while the
    builder has NOT loaded the offline hives (DISM loads them itself; sharing violation 0x80070020
    otherwise). -Stage Dism runs only that part, -Stage Hives the rest (files, onedrive, edge, winre,
    script) with the hives loaded, -Stage All (default) everything. The builder calls Dism then Hives
    and joins the two partial results per id with Merge-LiteOSRemovalResults.

    Deferred actions: a result's "deferred" property holds catalog-style actions (registry, service,
    powershell) that only work on the installed system (e.g. keys whose ACL only lets SYSTEM write,
    WinRE). The builder writes them to C:\LiteOS\deferred.json; SetupComplete applies them as SYSTEM
    and records them in the image backup.

    Importing this module has NO side effects. Select-LiteOSRemovals and Merge-LiteOSRemovalResults
    are pure. Every function accepts -WhatIf and then does nothing but report what it would do;
    failures never throw out of Invoke-LiteOSImageRemovals (they are reported as status 'failed').

    Windows PowerShell 5.1 compatible, ASCII only, StrictMode 2.
#>

Set-StrictMode -Version 2.0

# =============================================================================================
# Module constants (in memory only)
# =============================================================================================

$script:ImageVersion   = '1.0.0'
$script:Utf8NoBom       = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

$script:RemovalTypes   = @('capability', 'feature', 'package', 'files', 'onedrive', 'edge', 'winre', 'script')
$script:DismRemovalTypes = @('capability', 'feature', 'package')
$script:RemovalModes   = @('lite', 'core')
$script:RemovalRisks   = @('none', 'low', 'medium', 'high')
$script:IdPattern      = '^image\.[a-z0-9]+(-[a-z0-9]+)*$'
$script:AppxPattern    = '^[A-Za-z0-9][A-Za-z0-9.*?_-]*$'
$script:TweakIdPattern = '^[a-z0-9*?]+(\.[a-z0-9*?]+(-[a-z0-9*?]+)*)+$'

# Edge Update application GUIDs (HKLM\...\Policies\Microsoft\EdgeUpdate and
# WOW6432Node\Microsoft\EdgeUpdate\Clients / ClientState). The WebView2 Runtime GUID is kept
# explicitly ALLOWED and registered, so removing the browser never disables or freezes WebView2.
$script:EdgeStableGuid   = '{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'
$script:EdgeWebView2Guid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'

# Core WinRE: deferred SetupComplete action (runs as SYSTEM on the installed system). Windows 11
# 24H2 / 25H2 Setup needs Windows\System32\Recovery\Winre.wim in install.wim (it fails at ~5%
# without it - NTLite forum "Windows 11 24H2 and winre.wim"; tiny11 core notes), so the image keeps
# it and WinRE is turned off only after Setup. reagentc /disable moves Winre.wim from the recovery
# partition back to C:\Windows\System32\Recovery, which is then deleted. Partitions are never touched.
# The WinRE state is read from System32\Recovery\ReAgent.xml (<InstallState state="1"/> = enabled,
# "0" = disabled; locale independent, unlike the reagentc /info text). Winre.wim is only deleted
# once WinRE is no longer enabled, and a re-run on an already disabled system changes nothing.
$script:WinreDisableScript = @'
$ErrorActionPreference = 'Continue'
$reagent = Join-Path $env:SystemRoot 'System32\reagentc.exe'
$wim = Join-Path $env:SystemRoot 'System32\Recovery\Winre.wim'
$cfg = Join-Path $env:SystemRoot 'System32\Recovery\ReAgent.xml'
if (-not (Test-Path -LiteralPath $reagent)) { 'SKIPPED: reagentc.exe not found'; return }
$state = ''
try { $state = [string](([xml](Get-Content -LiteralPath $cfg -Raw -ErrorAction Stop)).WindowsRE.InstallState.state) } catch { $state = '' }
if ($state -eq '0' -and -not (Test-Path -LiteralPath $wim)) { 'UNCHANGED: WinRE is already disabled and Winre.wim is gone'; return }
$out = ((& $reagent /disable 2>&1 | ForEach-Object { [string]$_ }) -join ' ').Trim()
$code = $LASTEXITCODE
$state = ''
try { $state = [string](([xml](Get-Content -LiteralPath $cfg -Raw -ErrorAction Stop)).WindowsRE.InstallState.state) } catch { $state = '' }
if ($state -eq '1') { throw ('WinRE is still enabled after reagentc /disable (exit {0}): {1}' -f $code, $out) }
if ($code -ne 0 -and $state -ne '0') { throw ('reagentc /disable failed (exit {0}) and ReAgent.xml does not report WinRE as disabled: {1}' -f $code, $out) }
if (Test-Path -LiteralPath $wim) {
    Remove-Item -LiteralPath $wim -Force -ErrorAction Stop
    ('WinRE disabled (reagentc exit {0}); deleted {1}' -f $code, $wim)
}
else { ('WinRE disabled (reagentc exit {0}); {1} was not present: {2}' -f $code, $wim, $out) }
'@
$script:WinreUndoScript = @'
$ErrorActionPreference = 'Continue'
$reagent = Join-Path $env:SystemRoot 'System32\reagentc.exe'
$wim = Join-Path $env:SystemRoot 'System32\Recovery\Winre.wim'
if (Test-Path -LiteralPath $wim) {
    $out = ((& $reagent /enable 2>&1 | ForEach-Object { [string]$_ }) -join ' ').Trim()
    ('reagentc /enable (exit {0}): {1}' -f $LASTEXITCODE, $out)
}
else { 'WinRE stays off: Lite OS Core deleted Winre.wim. Copy Windows\System32\Recovery\Winre.wim from the install image to that folder, then run reagentc /enable.' }
'@

# =============================================================================================
# Small helpers (internal)
# =============================================================================================

function Get-ImgProp {
    # Strict-mode safe property / key read for PSCustomObject (ConvertFrom-Json) and hashtables.
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Test-ImgProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return [bool]$Object.Contains($Name) }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-ImgStringArray {
    # Returns a string[] from a JSON array, single string, or $null. Blank entries dropped.
    param($Value)
    $list = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($x in @($Value)) {
        if ($null -eq $x) { continue }
        $s = ([string]$x).Trim()
        if ($s.Length -gt 0) { $list.Add($s) }
    }
    return , ($list.ToArray())
}

function Test-ImgIdMatch {
    # Exact id, or -like when the pattern contains a wildcard.
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

function Split-ImgList {
    # Arrays and comma/semicolon separated strings (powershell -File passes "a,b" as one string).
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

function Get-ImageSystemExe {
    param([string]$Name)
    $root = $env:SystemRoot
    if ([string]::IsNullOrEmpty($root)) { $root = 'C:\Windows' }
    $p = Join-Path (Join-Path $root 'System32') $Name
    if (Test-Path -LiteralPath $p) { return $p }
    return $Name
}

function Invoke-ImageNative {
    # Runs a native exe without PS 5.1 turning stderr into a terminating error.
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
    $text = (($out | Where-Object { $_ -ne '' }) -join ' ').Trim()
    return [pscustomobject]@{ ExitCode = $code; Output = $text }
}

function Format-ImgShort {
    param([string]$Text, [int]$Max = 200)
    if ($null -eq $Text) { return '' }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -le $Max) { return $t }
    return ($t.Substring(0, $Max - 3) + '...')
}

function New-ImageOutcome {
    # status applied|skipped|failed|deferred; deferred = catalog-style actions for the installed system.
    param([string]$Status, [string]$Message, [int]$Changes = 0, [object[]]$Deferred = @())
    $d = @($Deferred | Where-Object { $null -ne $_ })
    return [pscustomobject]@{ status = $Status; message = $Message; changes = $Changes; deferred = $d }
}

function Get-ImageMergedStatus {
    # One status for several partial outcomes: failed > applied > deferred > skipped.
    param([string[]]$Statuses)
    foreach ($s in @('failed', 'applied', 'deferred')) { if (@($Statuses) -contains $s) { return $s } }
    return 'skipped'
}

function Join-ImageOutcome {
    # Combines the outcomes of the parts of one removal (e.g. its "appx" part and its main type).
    param([object[]]$Outcomes)
    $list = @($Outcomes | Where-Object { $null -ne $_ })
    if ($list.Count -eq 0) { return (New-ImageOutcome 'skipped' 'nothing to do') }
    if ($list.Count -eq 1) { return $list[0] }
    $statuses = @($list | ForEach-Object { [string]$_.status })
    $msgs = @($list | ForEach-Object { [string]$_.message } | Where-Object { $_ })
    $changes = 0
    $def = @()
    foreach ($o in $list) {
        $changes += [int](Get-ImgProp $o 'changes' 0)
        $def += @(Get-ImgProp $o 'deferred' @())
    }
    return (New-ImageOutcome (Get-ImageMergedStatus $statuses) ($msgs -join '; ') $changes $def)
}

function New-ImageDeferredRegistry {
    # Deferred registry action (online HKLM:\ path; applied by SetupComplete as SYSTEM).
    param([string]$Path, [string]$Name, [string]$Kind, $Value)
    return [pscustomobject]@{ type = 'registry'; path = $Path; name = $Name; kind = $Kind; value = $Value }
}

function New-ImageDeferredService {
    param([string]$Name, [string]$Startup)
    return [pscustomobject]@{ type = 'service'; name = $Name; startup = $Startup; stop = $false }
}

function New-ImageDeferredScript {
    param([string]$Script, [string]$Undo)
    return [pscustomobject]@{ type = 'powershell'; script = $Script; undo = $Undo }
}

function Get-ImageSettingsPageValue {
    # Pure: Explorer SettingsPageVisibility with one more hidden ms-settings page, merged with the
    # current value ('hide:a;b' gets ';page', 'showonly:...' already hides every unlisted page).
    param([AllowNull()][AllowEmptyString()][string]$Current, [string]$Page)
    $c = ''
    if ($null -ne $Current) { $c = $Current.Trim() }
    if ($c.Length -eq 0) { return ('hide:' + $Page) }
    if ($c -match '^(?i)showonly:') { return $c }
    $m = [regex]::Match($c, '^(?i)hide:(.*)$')
    if ($m.Success) {
        $pages = @($m.Groups[1].Value.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($pages -contains $Page) { return $c }
        return ('hide:' + ((@($pages) + @($Page)) -join ';'))
    }
    return ('hide:' + $Page)
}

# =============================================================================================
# Offline registry access (via reg.exe, so no handles block the caller's hive unload)
# =============================================================================================

function Get-ImageHiveRoot {
    # $Hives = @{ SOFTWARE='HKLM\LITE_SOFTWARE'; SYSTEM='HKLM\LITE_SYSTEM'; DEFAULT='HKLM\LITE_DEFAULT' }
    # Returns the reg.exe root for one logical hive, or $null when the caller did not load it.
    param($Hives, [string]$Which)
    if ($null -eq $Hives) { return $null }
    $v = Get-ImgProp $Hives $Which
    if ($null -eq $v) { return $null }
    $s = ([string]$v).Trim().TrimEnd('\')
    if ($s.Length -eq 0) { return $null }
    return $s
}

function Get-ImageRegExe {
    return (Get-ImageSystemExe 'reg.exe')
}

function Test-ImageRegKey {
    param([string]$Key)
    $r = Invoke-ImageNative -FilePath (Get-ImageRegExe) -ArgumentList @('query', $Key)
    return ($r.ExitCode -eq 0)
}

function Set-ImageRegValue {
    # Writes one value with reg add. Returns $true on success.
    param([string]$Key, [string]$Name, [string]$Type, [string]$Data)
    $regArgs = @('add', $Key, '/v', $Name, '/t', $Type, '/d', $Data, '/f')
    $r = Invoke-ImageNative -FilePath (Get-ImageRegExe) -ArgumentList $regArgs
    if ($r.ExitCode -ne 0) { throw ("reg add {0} /v {1} failed (exit {2}): {3}" -f $Key, $Name, $r.ExitCode, $r.Output) }
    return $true
}

function Remove-ImageRegValue {
    # Deletes one value if present. Returns $true if it existed and was removed.
    param([string]$Key, [string]$Name)
    $q = Invoke-ImageNative -FilePath (Get-ImageRegExe) -ArgumentList @('query', $Key, '/v', $Name)
    if ($q.ExitCode -ne 0) { return $false }
    $r = Invoke-ImageNative -FilePath (Get-ImageRegExe) -ArgumentList @('delete', $Key, '/v', $Name, '/f')
    if ($r.ExitCode -ne 0) { throw ("reg delete {0} /v {1} failed (exit {2}): {3}" -f $Key, $Name, $r.ExitCode, $r.Output) }
    return $true
}

function Remove-ImageRegKey {
    # Deletes a whole key if present. Returns $true if it existed and was removed.
    param([string]$Key)
    if (-not (Test-ImageRegKey $Key)) { return $false }
    $r = Invoke-ImageNative -FilePath (Get-ImageRegExe) -ArgumentList @('delete', $Key, '/f')
    if ($r.ExitCode -ne 0) { throw ("reg delete {0} failed (exit {1}): {2}" -f $Key, $r.ExitCode, $r.Output) }
    return $true
}

function Get-ImageRegString {
    # REG_SZ / REG_EXPAND_SZ data of one value ($null when the value does not exist).
    param([string]$Key, [string]$Name)
    $q = Invoke-ImageNative -FilePath (Get-ImageRegExe) -ArgumentList @('query', $Key, '/v', $Name)
    if ($q.ExitCode -ne 0) { return $null }
    $m = [regex]::Match([string]$q.Output, ('(?i)' + [regex]::Escape($Name) + '\s+REG_(?:EXPAND_)?SZ\s+(.*)$'))
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}

function Get-ImageControlSet {
    # Offline SYSTEM hives have no CurrentControlSet; Select\Current says which ControlSet00N is live.
    param([string]$SystemRoot)
    $n = 1
    $r = Invoke-ImageNative -FilePath (Get-ImageRegExe) -ArgumentList @('query', ($SystemRoot + '\Select'), '/v', 'Current')
    if ($r.ExitCode -eq 0) {
        if ($r.Output -match 'Current\s+REG_DWORD\s+0x([0-9a-fA-F]+)') { $n = [Convert]::ToInt32($Matches[1], 16) }
    }
    if ($n -lt 1) { $n = 1 }
    return ('ControlSet{0:D3}' -f $n)
}

function Set-ImageServiceStart {
    # Sets Services\<name>\Start in the offline SYSTEM hive. Missing service key -> skipped.
    # Returns one of 'set','skipped'. Throws only on an unexpected reg failure.
    param([string]$SystemRoot, [string]$ControlSet, [string]$Name, [int]$Start)
    $key = '{0}\{1}\Services\{2}' -f $SystemRoot, $ControlSet, $Name
    if (-not (Test-ImageRegKey $key)) { return 'skipped' }
    [void](Set-ImageRegValue -Key $key -Name 'Start' -Type 'REG_DWORD' -Data ([string]$Start))
    return 'set'
}

# =============================================================================================
# Offline file access (take ownership, then delete). Never runs under -WhatIf.
# =============================================================================================

function Get-ImageMountChildPath {
    # Joins a mount root with a path that is relative to the image root (leading slashes stripped).
    param([string]$MountPath, [string]$Relative)
    $rel = ([string]$Relative).Trim().Replace('/', '\').TrimStart('\')
    return (Join-Path $MountPath $rel)
}

function Test-ImageUnderSystem32 {
    param([string]$MountPath, [string]$FullPath)
    $sys = (Join-Path (Join-Path $MountPath 'Windows') 'System32').TrimEnd('\') + '\'
    $fp = ([string]$FullPath).TrimEnd('\') + '\'
    return $fp.StartsWith($sys, [System.StringComparison]::OrdinalIgnoreCase)
}

function Remove-ImageItem {
    # Deletes one file or directory inside the mounted image; takes ownership (Administrators) only
    # when a plain elevated delete is refused. takeown / icacls rewrite the security descriptor of
    # the FILE, i.e. of every hard link to it (WebView2 binaries are hard-linked with the Edge /
    # EdgeCore folders, serviced files with WinSxS), so they are the fallback, not the first step
    # (tiny11 also deletes the Edge folders with a plain Remove-Item).
    # Returns 'removed' | 'absent'. Throws on a real failure. NEVER called under -WhatIf.
    param([string]$FullPath)
    if (-not (Test-Path -LiteralPath $FullPath)) { return 'absent' }
    try { Remove-Item -LiteralPath $FullPath -Recurse -Force -ErrorAction Stop } catch { $null = $_ }
    if (-not (Test-Path -LiteralPath $FullPath)) { return 'removed' }
    $isDir = (Test-Path -LiteralPath $FullPath -PathType Container)
    $takeown = Get-ImageSystemExe 'takeown.exe'
    $icacls = Get-ImageSystemExe 'icacls.exe'
    if ($isDir) {
        # /a = give to Administrators group, /r = recurse, /d Y = default answer for the
        # locked-folder prompt (Y/N is the argument value, not a localized prompt answer).
        [void](Invoke-ImageNative -FilePath $takeown -ArgumentList @('/f', $FullPath, '/a', '/r', '/d', 'Y'))
        # *S-1-5-32-544 = BUILTIN\Administrators by SID (locale independent). (F)=Full control.
        [void](Invoke-ImageNative -FilePath $icacls -ArgumentList @($FullPath, '/grant', '*S-1-5-32-544:(F)', '/t', '/c', '/q'))
    }
    else {
        [void](Invoke-ImageNative -FilePath $takeown -ArgumentList @('/f', $FullPath, '/a'))
        [void](Invoke-ImageNative -FilePath $icacls -ArgumentList @($FullPath, '/grant', '*S-1-5-32-544:(F)', '/c', '/q'))
    }
    try {
        Remove-Item -LiteralPath $FullPath -Recurse -Force -ErrorAction Stop
    }
    catch {
        throw ("could not delete '{0}': {1}" -f $FullPath, $_.Exception.Message)
    }
    if (Test-Path -LiteralPath $FullPath) { throw ("'{0}' still exists after delete" -f $FullPath) }
    return 'removed'
}

# =============================================================================================
# DISM cmdlet wrappers (offline, -Path). Never run under -WhatIf (caller short-circuits first).
# =============================================================================================

function Invoke-ImageCapabilityType {
    param([string]$MountPath, [string[]]$Match)
    $all = @()
    try { $all = @(Get-WindowsCapability -Path $MountPath -ErrorAction Stop) }
    catch { return (New-ImageOutcome 'failed' ('could not list capabilities: ' + (Format-ImgShort $_.Exception.Message))) }
    $hits = @($all | Where-Object { $c = $_; (@($Match | Where-Object { $c.Name -like $_ }).Count -gt 0) })
    $present = @($hits | Where-Object { [string]$_.State -eq 'Installed' })
    if ($present.Count -eq 0) { return (New-ImageOutcome 'skipped' 'no matching capability is present in the image') }
    $done = 0
    $fail = @()
    foreach ($cap in $present) {
        try { [void](Remove-WindowsCapability -Path $MountPath -Name $cap.Name -ErrorAction Stop); $done++ }
        catch { $fail += ('{0}: {1}' -f $cap.Name, (Format-ImgShort $_.Exception.Message 120)) }
    }
    if ($fail.Count -gt 0) {
        $msg = ($fail -join '; ')
        if ($done -gt 0) { $msg = ('{0} removed, {1} failed: {2}' -f $done, $fail.Count, $msg) }
        return (New-ImageOutcome 'failed' $msg $done)
    }
    return (New-ImageOutcome 'applied' ('removed capability: ' + (@($present | ForEach-Object { $_.Name }) -join ', ')) $done)
}

function Invoke-ImageFeatureType {
    param([string]$MountPath, [string[]]$Match)
    $done = 0
    $fail = @()
    $present = @()
    foreach ($name in $Match) {
        $f = $null
        try { $f = Get-WindowsOptionalFeature -Path $MountPath -FeatureName $name -ErrorAction Stop }
        catch { $f = $null }
        if ($null -eq $f) { continue }
        $state = [string](Get-ImgProp $f 'State')
        if ($state -eq 'Disabled' -or $state -eq 'DisabledWithPayloadRemoved') { continue }
        $present += $name
        try { [void](Disable-WindowsOptionalFeature -Path $MountPath -FeatureName $name -Remove -ErrorAction Stop); $done++ }
        catch { $fail += ('{0}: {1}' -f $name, (Format-ImgShort $_.Exception.Message 120)) }
    }
    if ($present.Count -eq 0) { return (New-ImageOutcome 'skipped' 'no matching optional feature is present / enabled in the image') }
    if ($fail.Count -gt 0) {
        $msg = ($fail -join '; ')
        if ($done -gt 0) { $msg = ('{0} removed, {1} failed: {2}' -f $done, $fail.Count, $msg) }
        return (New-ImageOutcome 'failed' $msg $done)
    }
    return (New-ImageOutcome 'applied' ('removed feature: ' + ($present -join ', ')) $done)
}

function Invoke-ImagePackageType {
    param([string]$MountPath, [string[]]$Match)
    $all = @()
    try { $all = @(Get-WindowsPackage -Path $MountPath -ErrorAction Stop) }
    catch { return (New-ImageOutcome 'failed' ('could not list packages: ' + (Format-ImgShort $_.Exception.Message))) }
    $hits = @($all | Where-Object { $p = $_; (@($Match | Where-Object { $p.PackageName -like $_ }).Count -gt 0) })
    if ($hits.Count -eq 0) { return (New-ImageOutcome 'skipped' 'no matching package is present in the image') }
    $done = 0
    $skip = @()
    $fail = @()
    foreach ($pkg in $hits) {
        # Permanent / required packages are not removable; DISM reports that as an error we treat as skipped.
        try { [void](Remove-WindowsPackage -Path $MountPath -PackageName $pkg.PackageName -ErrorAction Stop); $done++ }
        catch {
            $m = [string]$_.Exception.Message
            if ($m -match '0x800f0825|permanent|cannot be removed|not removable') { $skip += $pkg.PackageName }
            else { $fail += ('{0}: {1}' -f $pkg.PackageName, (Format-ImgShort $m 120)) }
        }
    }
    if ($fail.Count -gt 0) {
        $msg = ($fail -join '; ')
        if ($done -gt 0) { $msg = ('{0} removed, {1} failed: {2}' -f $done, $fail.Count, $msg) }
        return (New-ImageOutcome 'failed' $msg $done)
    }
    if ($done -eq 0) { return (New-ImageOutcome 'skipped' ('matching packages are not removable: ' + ($skip -join ', '))) }
    $msg = ('removed package(s): {0}' -f $done)
    if ($skip.Count -gt 0) { $msg += ('; {0} not removable' -f $skip.Count) }
    return (New-ImageOutcome 'applied' $msg $done)
}

function Invoke-ImageAppxPart {
    # The "appx" field of a (Core-only) removal: Remove-AppxProvisionedPackage -Path for every
    # provisioned app whose DisplayName matches. This is an explicit, documented Core override of the
    # Lite protected app list (validated: only mode core may carry "appx"). DISM: hives NOT loaded.
    param([string]$MountPath, [string[]]$Patterns)
    $all = @()
    try { $all = @(Get-AppxProvisionedPackage -Path $MountPath -ErrorAction Stop) }
    catch { return (New-ImageOutcome 'failed' ('could not list provisioned apps: ' + (Format-ImgShort $_.Exception.Message))) }
    $hits = @($all | Where-Object { $prov = $_; (@($Patterns | Where-Object { [string]$prov.DisplayName -like $_ }).Count -gt 0) })
    if ($hits.Count -eq 0) { return (New-ImageOutcome 'skipped' ('provisioned app not in the image: ' + ($Patterns -join ', '))) }
    $done = 0
    $names = @()
    $kept = @()
    $fail = @()
    foreach ($pkg in $hits) {
        try {
            [void](Remove-AppxProvisionedPackage -Path $MountPath -PackageName $pkg.PackageName -ErrorAction Stop)
            $done++
            $names += [string]$pkg.DisplayName
        }
        catch {
            $m = [string]$_.Exception.Message
            # 0x80070032 (ERROR_NOT_SUPPORTED: "part of Windows") / 0x80073CFA (removal refused): the
            # image marks the app as a protected system app (SecHealthUI is NonRemovable on 24H2+).
            # That is a fact about the image, not a build error: report it, keep the other parts.
            # On 26100+ DISM only says "Removal failed. Please contact your software vendor." (no code).
            if ($m -match '(?i)0x80070032|0x80073CFA|part of Windows|cannot be uninstalled|Removal failed\. Please contact your software vendor') { $kept += [string]$pkg.DisplayName }
            else { $fail += ('{0}: {1}' -f $pkg.DisplayName, (Format-ImgShort $m 120)) }
        }
    }
    $keptNote = ''
    if ($kept.Count -gt 0) { $keptNote = ('protected by Windows in this image, kept: ' + ($kept -join ', ')) }
    if ($fail.Count -gt 0) {
        $msg = 'provisioned app removal failed: ' + ($fail -join '; ')
        if ($done -gt 0) { $msg = ('removed provisioned app {0}; ' -f ($names -join ', ')) + $msg }
        if ($keptNote) { $msg += ('; ' + $keptNote) }
        return (New-ImageOutcome 'failed' $msg $done)
    }
    if ($done -eq 0) { return (New-ImageOutcome 'skipped' $keptNote) }
    $msg = 'removed provisioned app (Core override of the protected list): ' + ($names -join ', ')
    if ($keptNote) { $msg += ('; ' + $keptNote) }
    return (New-ImageOutcome 'applied' $msg $done)
}

# =============================================================================================
# Non-DISM removal handlers
# =============================================================================================

function Invoke-ImageFilesType {
    param([string]$MountPath, $Removal)
    $paths = Get-ImgStringArray (Get-ImgProp $Removal 'paths')
    if ($paths.Count -eq 0) { return (New-ImageOutcome 'skipped' 'no paths given') }
    $allowSys = [bool](Get-ImgProp $Removal 'allowSystem32' $false)
    $done = 0
    $absent = 0
    $fail = @()
    foreach ($rel in $paths) {
        $full = Get-ImageMountChildPath -MountPath $MountPath -Relative $rel
        if ((Test-ImageUnderSystem32 -MountPath $MountPath -FullPath $full) -and -not $allowSys) {
            $fail += ("refused '{0}': under Windows\System32 and allowSystem32 is not set" -f $rel)
            continue
        }
        try {
            $r = Remove-ImageItem -FullPath $full
            if ($r -eq 'removed') { $done++ } else { $absent++ }
        }
        catch { $fail += (Format-ImgShort $_.Exception.Message 160) }
    }
    if ($fail.Count -gt 0) {
        $msg = ($fail -join '; ')
        if ($done -gt 0) { $msg = ('{0} removed, {1} failed: {2}' -f $done, $fail.Count, $msg) }
        return (New-ImageOutcome 'failed' $msg $done)
    }
    if ($done -eq 0) { return (New-ImageOutcome 'skipped' 'none of the paths were present in the image') }
    $msg = ('removed {0} path(s)' -f $done)
    if ($absent -gt 0) { $msg += ('; {0} already absent' -f $absent) }
    return (New-ImageOutcome 'applied' $msg $done)
}

function Invoke-ImageOneDriveType {
    # Removes only the Default-profile "OneDriveSetup" Run entry, which is what installs OneDrive for
    # every new account. Windows\System32\OneDriveSetup.exe is a serviced file hard-linked to its
    # WinSxS component: deleting it frees no space, needs takeown/icacls on the shared WinSxS
    # security descriptor and SFC / cumulative updates put it back, so it is left alone.
    param([string]$MountPath, $Hives)
    $def = Get-ImageHiveRoot -Hives $Hives -Which 'DEFAULT'
    if ($null -eq $def) { return (New-ImageOutcome 'failed' 'DEFAULT hive not supplied: the OneDriveSetup Run entry cannot be removed') }
    try {
        if (Remove-ImageRegValue -Key ($def + '\Software\Microsoft\Windows\CurrentVersion\Run') -Name 'OneDriveSetup') {
            return (New-ImageOutcome 'applied' 'removed the Default-profile OneDriveSetup Run entry (new accounts no longer install OneDrive)' 1)
        }
        return (New-ImageOutcome 'skipped' 'the Default profile has no OneDriveSetup Run entry')
    }
    catch { return (New-ImageOutcome 'failed' (Format-ImgShort $_.Exception.Message 200)) }
}

function Invoke-ImageEdgeType {
    param([string]$MountPath, $Hives)
    $done = 0
    $notes = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $fail = @()

    # 1) folders: Edge browser + its core. NEVER EdgeWebView / WebView2, and NOT EdgeUpdate: Edge
    #    Update is the only updater of the WebView2 Runtime (the Xbox app, Game Pass and many
    #    launchers embed WebView2). WebView2's binaries are hard links of their own, so deleting the
    #    Edge / EdgeCore links leaves them intact.
    $pf = 'Program Files (x86)\Microsoft'
    foreach ($leaf in @('Edge', 'EdgeCore')) {
        $full = Get-ImageMountChildPath -MountPath $MountPath -Relative (Join-Path $pf $leaf)
        try {
            $r = Remove-ImageItem -FullPath $full
            if ($r -eq 'removed') { $done++; $notes.Add('deleted ' + $leaf) }
        }
        catch { $fail += (Format-ImgShort $_.Exception.Message 160) }
    }

    # 2) shortcuts (public Start Menu + public Desktop)
    $shortcuts = @(
        'ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk',
        'Users\Public\Desktop\Microsoft Edge.lnk'
    )
    foreach ($rel in $shortcuts) {
        $full = Get-ImageMountChildPath -MountPath $MountPath -Relative $rel
        try {
            $r = Remove-ImageItem -FullPath $full
            if ($r -eq 'removed') { $done++; $notes.Add('removed shortcut ' + [System.IO.Path]::GetFileName($rel)) }
        }
        catch { $fail += (Format-ImgShort $_.Exception.Message 160) }
    }

    # 3) registry (SOFTWARE hive): the browser's uninstall entry and its Edge Update client
    #    registration (Clients / ClientState{Medium} {56EB18F8-...}), so Edge Update only services
    #    WebView2 and Edge Update itself; plus the reinstall policy (WebView2 explicitly allowed).
    $sw = Get-ImageHiveRoot -Hives $Hives -Which 'SOFTWARE'
    if ($null -ne $sw) {
        try {
            $uninstall = $sw + '\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
            if (Remove-ImageRegKey ($uninstall + '\Microsoft Edge')) { $done++; $notes.Add('removed uninstall key: Microsoft Edge') }
            $eu = $sw + '\WOW6432Node\Microsoft\EdgeUpdate'
            foreach ($sub in @('Clients', 'ClientState', 'ClientStateMedium')) {
                if (Remove-ImageRegKey ('{0}\{1}\{2}' -f $eu, $sub, $script:EdgeStableGuid)) { $done++; $notes.Add(('removed Edge Update {0} registration of the browser' -f $sub)) }
            }
            # Block Edge from being reinstalled by Edge Update; keep WebView2 explicitly allowed.
            $euPol = $sw + '\Policies\Microsoft\EdgeUpdate'
            [void](Set-ImageRegValue -Key $euPol -Name 'InstallDefault' -Type 'REG_DWORD' -Data '0')
            [void](Set-ImageRegValue -Key $euPol -Name ('Install' + $script:EdgeStableGuid) -Type 'REG_DWORD' -Data '0')
            [void](Set-ImageRegValue -Key $euPol -Name ('Install' + $script:EdgeWebView2Guid) -Type 'REG_DWORD' -Data '1')
            $done++
            $notes.Add('set Edge Update install policy (WebView2 allowed and still updated by Edge Update)')
        }
        catch { $fail += (Format-ImgShort $_.Exception.Message 160) }
    }
    else {
        $notes.Add('SOFTWARE hive not supplied: uninstall key / Edge Update registration / reinstall policy skipped')
    }

    # 4) the browser's elevation service points into the deleted Edge folder: disable it (best effort;
    #    it is demand-start, so a failure here only leaves a harmless dead entry).
    $sys = Get-ImageHiveRoot -Hives $Hives -Which 'SYSTEM'
    if ($null -ne $sys) {
        try {
            $cs = Get-ImageControlSet -SystemRoot $sys
            if ((Set-ImageServiceStart -SystemRoot $sys -ControlSet $cs -Name 'MicrosoftEdgeElevationService' -Start 4) -eq 'set') {
                $done++; $notes.Add('disabled MicrosoftEdgeElevationService')
            }
        }
        catch { $notes.Add('MicrosoftEdgeElevationService left unchanged: ' + (Format-ImgShort $_.Exception.Message 100)) }
    }

    if ($fail.Count -gt 0) {
        $msg = ($fail -join '; ')
        if ($done -gt 0) { $msg = ('{0} change(s) made; ' -f $done) + $msg }
        return (New-ImageOutcome 'failed' $msg $done)
    }
    if ($done -eq 0) { return (New-ImageOutcome 'skipped' 'Microsoft Edge was not present in the image') }
    return (New-ImageOutcome 'applied' ($notes -join '; ') $done)
}

function Get-ImageWinreDeferredAction {
    return (New-ImageDeferredScript -Script $script:WinreDisableScript -Undo $script:WinreUndoScript)
}

function Invoke-ImageWinreType {
    # Never deletes Winre.wim from install.wim: Windows 11 24H2 / 25H2 Setup fails (~5 %) without it.
    # WinRE is disabled on the installed system instead (deferred SetupComplete action, SYSTEM).
    param([string]$MountPath)
    $full = Get-ImageMountChildPath -MountPath $MountPath -Relative 'Windows\System32\Recovery\Winre.wim'
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return (New-ImageOutcome 'skipped' 'Windows\System32\Recovery\Winre.wim is not in the image (nothing to disable)') }
    $msg = 'Winre.wim is kept in the image (Windows 11 Setup needs it); SetupComplete disables WinRE (reagentc /disable) and deletes C:\Windows\System32\Recovery\Winre.wim on the installed system'
    return (New-ImageOutcome 'deferred' $msg 0 @(Get-ImageWinreDeferredAction))
}

# =============================================================================================
# Core-only scripted removals (called from the JSON "script" bodies). These deliberately go
# beyond the Lite protected list and are only ever selected in Core mode.
# =============================================================================================

function Invoke-LiteOSCoreDefender {
    <#
    .SYNOPSIS
        Core only: disables Microsoft Defender + SmartScreen in the offline image (registry and
        service part; runs with the offline hives loaded, no DISM call). The Windows Security app
        (SecHealthUI) is removed by the removal's "appx" field in the DISM stage, before the hives are
        loaded. SecurityHealthService's key only lets SYSTEM / TrustedInstaller write, so its Start=4
        is a deferred action applied by SetupComplete (SYSTEM). -WhatIf here is a plain switch (not
        ShouldProcess) because the JSON script bodies call this function as "... -WhatIf:$WhatIf".
    #>
    [CmdletBinding()]
    param([string]$MountPath, $Hives, [switch]$WhatIf)
    $dry = [bool]$WhatIf -or [bool]$WhatIfPreference
    $sys = Get-ImageHiveRoot -Hives $Hives -Which 'SYSTEM'
    $sw = Get-ImageHiveRoot -Hives $Hives -Which 'SOFTWARE'
    # Keys Administrators may write offline (checked read-only with Get-Acl on 26200).
    $svcs = @('WinDefend', 'WdNisSvc', 'WdNisDrv', 'WdFilter', 'WdBoot', 'Sense', 'MDCoreSvc')
    $deferred = @(New-ImageDeferredRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\SecurityHealthService' -Name 'Start' -Kind 'DWord' -Value 4)
    if ($dry) {
        return (New-ImageOutcome 'skipped' ('WhatIf: would set Start=4 for ' + ($svcs -join ', ') + '; SmartScreen off; hide Windows Security pages and notifications; SecurityHealthService Start=4 at SetupComplete'))
    }
    if ($null -eq $sys) { return (New-ImageOutcome 'failed' 'SYSTEM hive not supplied; cannot disable Defender services offline') }
    $done = 0
    $notes = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $fail = @()
    $cs = Get-ImageControlSet -SystemRoot $sys
    $disabled = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($s in $svcs) {
        try {
            $r = Set-ImageServiceStart -SystemRoot $sys -ControlSet $cs -Name $s -Start 4
            if ($r -eq 'set') { $done++; $disabled.Add($s) }
        }
        catch {
            # A service key that only SYSTEM / TrustedInstaller may write (like SecurityHealthService):
            # SetupComplete (SYSTEM) sets Start=4 on the installed system instead; the reg.exe text is
            # localized, so every offline failure is handed on (and still visible in the message).
            $deferred += (New-ImageDeferredRegistry -Path ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $s) -Name 'Start' -Kind 'DWord' -Value 4)
            $notes.Add(('{0}: not writable offline ({1}); Start=4 is set by SetupComplete' -f $s, (Format-ImgShort $_.Exception.Message 100)))
        }
    }
    if ($disabled.Count -gt 0) { $notes.Add('disabled services: ' + ($disabled -join ', ')) }
    if ($null -ne $sw) {
        try {
            $wdsc = $sw + '\Policies\Microsoft\Windows Defender Security Center'
            [void](Set-ImageRegValue -Key ($sw + '\Policies\Microsoft\Windows\System') -Name 'EnableSmartScreen' -Type 'REG_DWORD' -Data '0')
            [void](Set-ImageRegValue -Key ($sw + '\Policies\Microsoft\Windows Defender') -Name 'DisableAntiSpyware' -Type 'REG_DWORD' -Data '1')
            # Documented Windows Security policies: hide all its notifications ("virus protection is
            # off" toasts would open an app that is gone) and the Virus & threat protection area.
            [void](Set-ImageRegValue -Key ($wdsc + '\Notifications') -Name 'DisableNotifications' -Type 'REG_DWORD' -Data '1')
            [void](Set-ImageRegValue -Key ($wdsc + '\Virus and threat protection') -Name 'UILockdown' -Type 'REG_DWORD' -Data '1')
            # Settings > Privacy & security > Windows Security (ms-settings:windowsdefender), merged
            # with any SettingsPageVisibility value already in the image.
            $expl = $sw + '\Microsoft\Windows\CurrentVersion\Policies\Explorer'
            $spv = Get-ImageSettingsPageValue -Current (Get-ImageRegString -Key $expl -Name 'SettingsPageVisibility') -Page 'windowsdefender'
            [void](Set-ImageRegValue -Key $expl -Name 'SettingsPageVisibility' -Type 'REG_SZ' -Data $spv)
            $done++
            $notes.Add(('SmartScreen off, DisableAntiSpyware=1, Windows Security notifications and pages hidden (SettingsPageVisibility={0})' -f $spv))
            # The tray icon process of the removed Security app.
            if (Remove-ImageRegValue -Key ($sw + '\Microsoft\Windows\CurrentVersion\Run') -Name 'SecurityHealth') { $done++; $notes.Add('removed the SecurityHealth Run entry') }
        }
        catch { $fail += (Format-ImgShort $_.Exception.Message 160) }
    }
    else { $notes.Add('SOFTWARE hive not supplied: SmartScreen/policy left unchanged') }
    $notes.Add('SecurityHealthService Start=4 is applied by SetupComplete (only SYSTEM may write that key)')
    if ($fail.Count -gt 0) {
        $msg = ($fail -join '; ')
        if ($done -gt 0) { $msg = ('{0} change(s) made; ' -f $done) + $msg }
        return (New-ImageOutcome 'failed' $msg $done $deferred)
    }
    return (New-ImageOutcome 'applied' ($notes -join '; ') $done $deferred)
}

function Invoke-LiteOSCoreUpdateStack {
    <#
    .SYNOPSIS
        Core only: disables the Windows Update servicing stack in the offline image.
        -WhatIf is a plain switch (not ShouldProcess); the JSON script bodies call this as
        "... -WhatIf:$WhatIf". The same state is re-checked on the installed system: the outcome
        carries deferred service / policy actions that SetupComplete applies (unchanged when Setup
        left them alone; re-applied and logged when OOBE turned something back on). The tweaks that
        write NoAutoUpdate=0 are excluded by the builder through the removal's "conflicts" list.
    #>
    [CmdletBinding()]
    param([string]$MountPath, $Hives, [switch]$WhatIf)
    $dry = [bool]$WhatIf -or [bool]$WhatIfPreference
    $sys = Get-ImageHiveRoot -Hives $Hives -Which 'SYSTEM'
    $sw = Get-ImageHiveRoot -Hives $Hives -Which 'SOFTWARE'
    $svcs = @('wuauserv', 'UsoSvc', 'WaaSMedicSvc')
    $wuPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $deferred = @()
    foreach ($s in $svcs) { $deferred += (New-ImageDeferredService -Name $s -Startup 'Disabled') }
    $deferred += (New-ImageDeferredRegistry -Path $wuPol -Name 'DoNotConnectToWindowsUpdateInternetLocations' -Kind 'DWord' -Value 1)
    $deferred += (New-ImageDeferredRegistry -Path ($wuPol + '\AU') -Name 'NoAutoUpdate' -Kind 'DWord' -Value 1)
    if ($dry) {
        return (New-ImageOutcome 'skipped' ('WhatIf: would set Start=4 for ' + ($svcs -join ', ') + ' and write NoAutoUpdate / DoNotConnect policies (re-checked at SetupComplete)'))
    }
    if ($null -eq $sys) { return (New-ImageOutcome 'failed' 'SYSTEM hive not supplied; cannot disable the update services offline') }
    $done = 0
    $notes = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $fail = @()
    $cs = Get-ImageControlSet -SystemRoot $sys
    $disabled = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($s in $svcs) {
        try {
            $r = Set-ImageServiceStart -SystemRoot $sys -ControlSet $cs -Name $s -Start 4
            if ($r -eq 'set') { $done++; $disabled.Add($s) }
        }
        catch {
            # e.g. WaaSMedicSvc, whose key Administrators may only read: the deferred service action
            # above disables it at SetupComplete (SYSTEM), so this is a note, not a failed removal.
            $notes.Add(('{0}: not writable offline ({1}); disabled by SetupComplete' -f $s, (Format-ImgShort $_.Exception.Message 100)))
        }
    }
    if ($disabled.Count -gt 0) { $notes.Add('disabled services: ' + ($disabled -join ', ')) }
    if ($null -ne $sw) {
        try {
            $wu = $sw + '\Policies\Microsoft\Windows\WindowsUpdate'
            [void](Set-ImageRegValue -Key $wu -Name 'DoNotConnectToWindowsUpdateInternetLocations' -Type 'REG_DWORD' -Data '1')
            [void](Set-ImageRegValue -Key ($wu + '\AU') -Name 'NoAutoUpdate' -Type 'REG_DWORD' -Data '1')
            $done++
            $notes.Add('wrote NoAutoUpdate + DoNotConnect policies')
        }
        catch { $fail += (Format-ImgShort $_.Exception.Message 160) }
    }
    else { $notes.Add('SOFTWARE hive not supplied: update policies left unchanged') }
    $notes.Add('re-checked on the installed system by SetupComplete')
    if ($fail.Count -gt 0) {
        $msg = ($fail -join '; ')
        if ($done -gt 0) { $msg = ('{0} change(s) made; ' -f $done) + $msg }
        return (New-ImageOutcome 'failed' $msg $done $deferred)
    }
    return (New-ImageOutcome 'applied' ($notes -join '; ') $done $deferred)
}

function Invoke-ImageScriptType {
    # Runs the JSON "script" string with $MountPath, $Hives and $WhatIf in scope. The script is
    # expected to return a New-ImageOutcome object (the two Invoke-LiteOSCore* helpers do).
    param([string]$MountPath, $Hives, [bool]$Dry, [string]$Script)
    if ([string]::IsNullOrWhiteSpace($Script)) { return (New-ImageOutcome 'skipped' 'empty script') }
    $sb = $null
    try { $sb = [ScriptBlock]::Create($Script) }
    catch { return (New-ImageOutcome 'failed' ('script does not parse: ' + (Format-ImgShort $_.Exception.Message 160))) }
    $WhatIf = $Dry
    $result = $null
    try { $result = & $sb }
    catch { return (New-ImageOutcome 'failed' ('script error: ' + (Format-ImgShort $_.Exception.Message 200))) }
    $last = $null
    foreach ($o in @($result)) {
        if ($null -ne $o -and (Test-ImgProp $o 'status') -and (Test-ImgProp $o 'message')) { $last = $o }
    }
    if ($null -ne $last) { return (New-ImageOutcome ([string]$last.status) ([string]$last.message) ([int](Get-ImgProp $last 'changes' 0)) @(Get-ImgProp $last 'deferred' @())) }
    if ($Dry) { return (New-ImageOutcome 'skipped' 'WhatIf: script would run') }
    return (New-ImageOutcome 'applied' 'script completed' 1)
}

# =============================================================================================
# Schema validation
# =============================================================================================

function ConvertTo-LiteOSRemovalObject {
    # Validates one raw removal; adds found problems to $Errors; returns a normalized object or $null.
    param($Raw, [string]$Where, $Errors)
    $before = $Errors.Count

    $id = Get-ImgProp $Raw 'id'
    if (-not ($id -is [string]) -or [string]::IsNullOrWhiteSpace($id)) { $Errors.Add(("{0}: missing 'id'" -f $Where)); $id = '' }
    else {
        $id = $id.Trim()
        if ($id -notmatch $script:IdPattern) { $Errors.Add(("{0}: id '{1}' must look like image.<kebab-name>" -f $Where, $id)) }
    }

    $name = Get-ImgProp $Raw 'name'
    if (-not ($name -is [string]) -or [string]::IsNullOrWhiteSpace($name)) { $Errors.Add(("{0}: missing 'name'" -f $Where)); $name = $id }

    $desc = Get-ImgProp $Raw 'description'
    if (-not ($desc -is [string]) -or [string]::IsNullOrWhiteSpace($desc)) { $Errors.Add(("{0}: missing 'description' (every entry must state its downside)" -f $Where)); $desc = '' }

    $modeRaw = ([string](Get-ImgProp $Raw 'mode' '')).Trim().ToLowerInvariant()
    if ($script:RemovalModes -notcontains $modeRaw) { $Errors.Add(("{0}: bad mode '{1}' (expected lite or core)" -f $Where, (Get-ImgProp $Raw 'mode'))); $modeRaw = '' }

    if (-not (Test-ImgProp $Raw 'default')) { $Errors.Add(("{0}: missing 'default'" -f $Where)); $def = $false }
    else {
        $defVal = Get-ImgProp $Raw 'default'
        if (-not ($defVal -is [bool])) { $Errors.Add(("{0}: 'default' must be true or false" -f $Where)); $def = $false }
        else { $def = [bool]$defVal }
    }

    $riskRaw = ([string](Get-ImgProp $Raw 'risk' '')).Trim().ToLowerInvariant()
    if ($script:RemovalRisks -notcontains $riskRaw) { $Errors.Add(("{0}: bad risk '{1}' (expected none, low, medium or high)" -f $Where, (Get-ImgProp $Raw 'risk'))); $riskRaw = '' }
    elseif ($modeRaw -eq 'core' -and ($riskRaw -eq 'none' -or $riskRaw -eq 'low')) {
        $Errors.Add(("{0}: Core removals must have risk medium or high (got '{1}')" -f $Where, $riskRaw))
    }

    $typeRaw = ([string](Get-ImgProp $Raw 'type' '')).Trim().ToLowerInvariant()
    if ($script:RemovalTypes -notcontains $typeRaw) { $Errors.Add(("{0}: bad type '{1}'" -f $Where, (Get-ImgProp $Raw 'type'))); $typeRaw = '' }

    $match = Get-ImgStringArray (Get-ImgProp $Raw 'match')
    if ($script:DismRemovalTypes -contains $typeRaw) {
        foreach ($mp in $match) {
            # Removing Recall / the Windows AI (AIX) packages from an offline 24H2+ image breaks the new
            # File Explorer (undeclared CBS dependency); Recall is turned off by the ui.recall-off tweak.
            if ($mp -match '(?i)recall|windowsai|\baix\b') { $Errors.Add(("{0}: 'match' entry '{1}' removes Recall / Windows AI components offline, which breaks the 24H2+ File Explorer (use the ui.recall-off policy tweak)" -f $Where, $mp)) }
            # A pattern that is (nearly) all wildcards would remove every capability / feature / package.
            elseif (($mp -replace '[*?~]', '').Length -lt 4) { $Errors.Add(("{0}: 'match' entry '{1}' is too broad (name the component)" -f $Where, $mp)) }
        }
    }
    $paths = Get-ImgStringArray (Get-ImgProp $Raw 'paths')
    $scriptText = Get-ImgProp $Raw 'script'
    if (-not ($scriptText -is [string])) { $scriptText = '' }

    $appx = Get-ImgStringArray (Get-ImgProp $Raw 'appx')
    if ($appx.Count -gt 0 -and $modeRaw -ne 'core') {
        $Errors.Add(("{0}: 'appx' removes provisioned apps that the Lite protected list keeps; only mode core may use it" -f $Where))
    }
    foreach ($a in $appx) {
        if ($a -notmatch $script:AppxPattern -or ($a -replace '[*?]', '').Length -lt 6) { $Errors.Add(("{0}: 'appx' pattern '{1}' is not a specific provisioned app name" -f $Where, $a)) }
    }
    $conflicts = Get-ImgStringArray (Get-ImgProp $Raw 'conflicts')
    foreach ($c in $conflicts) {
        if ($c -notmatch $script:TweakIdPattern -or $c.StartsWith('image.', [System.StringComparison]::OrdinalIgnoreCase)) {
            $Errors.Add(("{0}: 'conflicts' entry '{1}' must be a tweak id (category.kebab-name, wildcards allowed)" -f $Where, $c))
        }
    }

    switch ($typeRaw) {
        'capability' { if ($match.Count -eq 0) { $Errors.Add(("{0}: type 'capability' needs a non-empty 'match' array" -f $Where)) } }
        'feature'    { if ($match.Count -eq 0) { $Errors.Add(("{0}: type 'feature' needs a non-empty 'match' array" -f $Where)) } }
        'package'    { if ($match.Count -eq 0) { $Errors.Add(("{0}: type 'package' needs a non-empty 'match' array" -f $Where)) } }
        'files'      { if ($paths.Count -eq 0) { $Errors.Add(("{0}: type 'files' needs a non-empty 'paths' array" -f $Where)) } }
        'script'     { if ([string]::IsNullOrWhiteSpace($scriptText)) { $Errors.Add(("{0}: type 'script' needs a non-empty 'script' string" -f $Where)) } }
        default      { }
    }

    if ($Errors.Count -gt $before) { return $null }

    return [pscustomobject]@{
        id            = $id
        name          = $name.Trim()
        description   = $desc.Trim()
        mode          = $modeRaw
        default       = $def
        risk          = $riskRaw
        type          = $typeRaw
        match         = $match
        paths         = $paths
        script        = $scriptText
        allowSystem32 = [bool](Get-ImgProp $Raw 'allowSystem32' $false)
        appx          = $appx
        conflicts     = $conflicts
    }
}

# =============================================================================================
# Public API
# =============================================================================================

function Get-LiteOSRemovals {
    <#
    .SYNOPSIS
        Loads and validates image/removals.json. Returns normalized removal objects.
    .DESCRIPTION
        Throws one error that lists every schema problem (missing fields, bad type/mode/risk,
        duplicate ids, Core entry below medium risk, type-specific missing match/paths/script).
    .PARAMETER Path
        The removals.json file, or a folder that contains it. Default: <repo>\image\removals.json.
    #>
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $root = Split-Path -Parent $PSScriptRoot
        $Path = Join-Path (Join-Path $root 'image') 'removals.json'
    }
    elseif (Test-Path -LiteralPath $Path -PathType Container) {
        $Path = Join-Path $Path 'removals.json'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('Lite OS removals file not found: {0}' -f $Path) }

    $raw = $null
    try { $raw = [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom) }
    catch { throw ("{0}: cannot read file: {1}" -f $Path, $_.Exception.Message) }
    if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
    if ([string]::IsNullOrWhiteSpace($raw)) { throw ("{0}: file is empty" -f $Path) }
    $json = $null
    try { $json = ConvertFrom-Json -InputObject $raw }
    catch { throw ("{0}: invalid JSON: {1}" -f $Path, $_.Exception.Message) }
    if ($null -eq $json) { throw ("{0}: JSON document is empty" -f $Path) }
    if (-not (Test-ImgProp $json 'removals')) { throw ("{0}: missing 'removals' array" -f $Path) }

    $leaf = [System.IO.Path]::GetFileName($Path)
    $errors = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $out = [System.Collections.Generic.List[object]]::new()
    $ids = @{}
    $i = 0
    foreach ($rawRemoval in @(Get-ImgProp $json 'removals' @())) {
        $i++
        $where = '{0} removal #{1}' -f $leaf, $i
        if ($null -eq $rawRemoval -or $rawRemoval -is [string] -or $rawRemoval -is [System.ValueType]) {
            $errors.Add(("{0}: each removal must be a JSON object" -f $where)); continue
        }
        $obj = ConvertTo-LiteOSRemovalObject -Raw $rawRemoval -Where $where -Errors $errors
        if ($null -eq $obj) { continue }
        if ($ids.ContainsKey($obj.id)) { $errors.Add(("duplicate removal id '{0}' ({1}; first at {2})" -f $obj.id, $where, $ids[$obj.id])); continue }
        $ids[$obj.id] = $where
        $out.Add($obj)
    }

    if ($errors.Count -gt 0) {
        $msg = 'Lite OS removals catalog has {0} error(s):{1} - {2}' -f $errors.Count, [Environment]::NewLine, ($errors -join ([Environment]::NewLine + ' - '))
        throw $msg
    }
    # No leading comma: emit the array so the usual @(Get-LiteOSRemovals) idiom unrolls it,
    # matching Get-LiteOSCatalog in the engine.
    return $out.ToArray()
}

function Select-LiteOSRemovals {
    <#
    .SYNOPSIS
        Pure function: picks the removals for a mode, plus -Include, minus -Exclude.
    .DESCRIPTION
        Lite = removals with mode 'lite' and default:true. Core = Lite plus removals with
        mode 'core' and default:true. -Include / -Exclude accept exact ids, wildcards
        (image.*) and comma separated strings; -Exclude wins. Catalog order is kept. No system access.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Removals,

        [ValidateSet('Lite', 'Core')]
        [string]$Mode = 'Lite',

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Include = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Exclude = @()
    )
    $inc = Split-ImgList $Include
    $exc = Split-ImgList $Exclude
    foreach ($r in @($Removals)) {
        if ($null -eq $r) { continue }
        $id = [string](Get-ImgProp $r 'id' '')
        if ([string]::IsNullOrEmpty($id)) { continue }
        $m = ([string](Get-ImgProp $r 'mode' '')).Trim().ToLowerInvariant()
        $def = [bool](Get-ImgProp $r 'default' $false)
        $picked = $false
        if ($Mode -eq 'Lite') { $picked = ($def -and $m -eq 'lite') }
        elseif ($Mode -eq 'Core') { $picked = ($def -and ($m -eq 'lite' -or $m -eq 'core')) }
        if (-not $picked -and $inc.Length -gt 0) { $picked = Test-ImgIdMatch -Id $id -Patterns $inc }
        if (-not $picked) { continue }
        if ($exc.Length -gt 0 -and (Test-ImgIdMatch -Id $id -Patterns $exc)) { continue }
        $r
    }
}

function Invoke-LiteOSImageRemovals {
    <#
    .SYNOPSIS
        Applies a list of image removals to an offline-mounted install.wim. Returns one result
        object per removal handled in this stage: {id, name, type, mode, stage, status
        (applied|skipped|failed|deferred), message, changes, deferred (actions for SetupComplete), whatIf}.
    .DESCRIPTION
        Each removal is dispatched by its type (plus its optional "appx" part). A failure in one
        removal never aborts the run or throws; it is reported as status 'failed'. -WhatIf changes
        nothing and reports what would happen. The caller (builder) loads/unloads the registry hives.
    .PARAMETER MountPath
        The folder where install.wim is mounted.
    .PARAMETER Removals
        Removal objects from Get-LiteOSRemovals (already filtered with Select-LiteOSRemovals).
    .PARAMETER Hives
        @{ SOFTWARE='HKLM\LITE_SOFTWARE'; SYSTEM='HKLM\LITE_SYSTEM'; DEFAULT='HKLM\LITE_DEFAULT' }.
        Optional; removals that need a hive not supplied are reported, not applied.
    .PARAMETER Stage
        All (default) = every part. Dism = only DISM servicing (capability / feature / package types
        and "appx" parts): call it while the offline hives are NOT loaded. Hives = only the other
        types (files, onedrive, edge, winre, script), with the hives loaded. Removals with nothing to
        do in the stage produce no result; join both stages with Merge-LiteOSRemovalResults.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MountPath,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Removals,

        $Hives = @{},

        [ValidateSet('All', 'Dism', 'Hives')]
        [string]$Stage = 'All'
    )
    $dry = [bool]$WhatIfPreference
    $results = New-Object -TypeName 'System.Collections.ArrayList'

    foreach ($r in @($Removals)) {
        if ($null -eq $r) { continue }
        $id = [string](Get-ImgProp $r 'id' '(no id)')
        $name = [string](Get-ImgProp $r 'name' $id)
        $type = ([string](Get-ImgProp $r 'type' '')).Trim().ToLowerInvariant()
        $mode = ([string](Get-ImgProp $r 'mode' '')).Trim().ToLowerInvariant()
        $match = Get-ImgStringArray (Get-ImgProp $r 'match')
        $appx = Get-ImgStringArray (Get-ImgProp $r 'appx')
        $isDism = ($script:DismRemovalTypes -contains $type)
        $runMain = ($Stage -eq 'All') -or ($Stage -eq 'Dism' -and $isDism) -or ($Stage -eq 'Hives' -and -not $isDism)
        $runAppx = ($appx.Count -gt 0) -and ($Stage -ne 'Hives')
        if (-not $runMain -and -not $runAppx) { continue }

        $thisDry = $dry
        if (-not $thisDry) {
            if (-not $PSCmdlet.ShouldProcess(('{0} ({1} stage)' -f $id, $Stage), 'Apply Lite OS image removal')) { $thisDry = $true }
        }

        $outcome = $null
        if ($thisDry) {
            # Never touch DISM / the filesystem / the registry under -WhatIf: report intent only.
            $whatParts = @()
            if ($runAppx) { $whatParts += ('remove provisioned app(s) ' + ($appx -join ', ') + ' (Core override of the protected list)') }
            if ($runMain) {
                $whatMain = switch ($type) {
                    'capability' { 'remove capabilities matching ' + ($match -join ', ') }
                    'feature'    { 'remove / disable optional features: ' + ($match -join ', ') }
                    'package'    { 'remove packages matching ' + ($match -join ', ') }
                    'files'      { 'delete image paths: ' + ((Get-ImgStringArray (Get-ImgProp $r 'paths')) -join ', ') }
                    'onedrive'   { 'remove the Default-profile OneDriveSetup Run entry' }
                    'edge'       { 'remove the Edge browser and its Edge Update registration, set the reinstall policy (WebView2 and Edge Update kept)' }
                    'winre'      { 'keep Winre.wim and disable WinRE at SetupComplete (reagentc /disable)' }
                    'script'     { 'run the Core removal script (' + $id + ')' }
                    default      { 'do nothing (unknown type)' }
                }
                $whatParts += [string]$whatMain
            }
            $outcome = New-ImageOutcome 'skipped' ('WhatIf: would ' + ($whatParts -join '; '))
        }
        else {
            $parts = @()
            if ($runAppx) {
                try { $parts += (Invoke-ImageAppxPart -MountPath $MountPath -Patterns $appx) }
                catch { $parts += (New-ImageOutcome 'failed' ('appx: ' + (Format-ImgShort $_.Exception.Message 200))) }
            }
            if ($runMain) {
                $main = $null
                try {
                    switch ($type) {
                        'capability' { $main = Invoke-ImageCapabilityType -MountPath $MountPath -Match $match }
                        'feature'    { $main = Invoke-ImageFeatureType    -MountPath $MountPath -Match $match }
                        'package'    { $main = Invoke-ImagePackageType    -MountPath $MountPath -Match $match }
                        'files'      { $main = Invoke-ImageFilesType      -MountPath $MountPath -Removal $r }
                        'onedrive'   { $main = Invoke-ImageOneDriveType   -MountPath $MountPath -Hives $Hives }
                        'edge'       { $main = Invoke-ImageEdgeType       -MountPath $MountPath -Hives $Hives }
                        'winre'      { $main = Invoke-ImageWinreType      -MountPath $MountPath }
                        'script'     { $main = Invoke-ImageScriptType -MountPath $MountPath -Hives $Hives -Dry $false -Script ([string](Get-ImgProp $r 'script' '')) }
                        default      { $main = New-ImageOutcome 'failed' ('unknown removal type: ' + $type) }
                    }
                }
                catch {
                    $main = New-ImageOutcome 'failed' (Format-ImgShort $_.Exception.Message 200)
                }
                if ($null -eq $main) { $main = New-ImageOutcome 'skipped' 'no outcome' }
                $parts += $main
            }
            $outcome = Join-ImageOutcome -Outcomes $parts
        }
        if ($null -eq $outcome) { $outcome = New-ImageOutcome 'skipped' 'no outcome' }

        [void]$results.Add([pscustomobject]@{
                id       = $id
                name     = $name
                type     = $type
                mode     = $mode
                stage    = $Stage
                status   = [string]$outcome.status
                message  = [string]$outcome.message
                changes  = [int](Get-ImgProp $outcome 'changes' 0)
                deferred = @(Get-ImgProp $outcome 'deferred' @())
                whatIf   = $thisDry
            })
    }
    return $results.ToArray()
}

function Merge-LiteOSRemovalResults {
    <#
    .SYNOPSIS
        Pure: joins the per-stage results of Invoke-LiteOSImageRemovals (Dism + Hives) into one result
        per removal id, in first-seen order.
    .DESCRIPTION
        status: failed > applied > deferred > skipped; messages joined with '; '; changes added up;
        deferred actions concatenated; whatIf true if any part was a dry run. No system access.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Results
    )
    $order = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $byId = @{}
    foreach ($r in @($Results)) {
        if ($null -eq $r -or $r -is [string] -or $r -is [System.ValueType]) { continue }
        $id = [string](Get-ImgProp $r 'id' '')
        if (-not $id) { continue }
        if (-not $byId.ContainsKey($id)) { $order.Add($id); $byId[$id] = New-Object -TypeName 'System.Collections.ArrayList' }
        [void]$byId[$id].Add($r)
    }
    foreach ($id in $order) {
        $parts = @($byId[$id].ToArray())
        $first = $parts[0]
        $statuses = @($parts | ForEach-Object { [string](Get-ImgProp $_ 'status' 'skipped') })
        $msgs = @($parts | ForEach-Object { [string](Get-ImgProp $_ 'message' '') } | Where-Object { $_ })
        $changes = 0
        $def = @()
        $wi = $false
        $stages = @()
        foreach ($p in $parts) {
            $changes += [int](Get-ImgProp $p 'changes' 0)
            $def += @(Get-ImgProp $p 'deferred' @())
            if ([bool](Get-ImgProp $p 'whatIf' $false)) { $wi = $true }
            $st = [string](Get-ImgProp $p 'stage' '')
            if ($st -and $stages -notcontains $st) { $stages += $st }
        }
        [pscustomobject]@{
            id       = $id
            name     = [string](Get-ImgProp $first 'name' $id)
            type     = [string](Get-ImgProp $first 'type' '')
            mode     = [string](Get-ImgProp $first 'mode' '')
            stage    = ($stages -join '+')
            status   = (Get-ImageMergedStatus $statuses)
            message  = ($msgs -join '; ')
            changes  = $changes
            deferred = @($def | Where-Object { $null -ne $_ })
            whatIf   = $wi
        }
    }
}

function Invoke-LiteOSImageCleanup {
    <#
    .SYNOPSIS
        Runs DISM component cleanup on the offline image (both modes).
    .DESCRIPTION
        dism /Image:<mount> /Cleanup-Image /StartComponentCleanup [/ResetBase]. Exit codes 0 and
        3010 (reboot queued) are success; anything else is a failure. -WhatIf changes nothing.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MountPath,

        [switch]$ResetBase
    )
    $dry = [bool]$WhatIfPreference
    $dismArgs = @(('/Image:' + $MountPath), '/Cleanup-Image', '/StartComponentCleanup')
    if ($ResetBase) { $dismArgs += '/ResetBase' }
    if ($dry -or -not $PSCmdlet.ShouldProcess($MountPath, 'DISM component cleanup')) {
        return [pscustomobject]@{ id = 'image.cleanup'; status = 'skipped'; message = ('WhatIf: would run dism ' + ($dismArgs -join ' ')); whatIf = $true }
    }
    $dism = Get-ImageSystemExe 'dism.exe'
    $r = Invoke-ImageNative -FilePath $dism -ArgumentList $dismArgs
    if ($r.ExitCode -eq 0 -or $r.ExitCode -eq 3010) {
        $msg = 'component cleanup complete'
        if ($ResetBase) { $msg = 'component cleanup + ResetBase complete' }
        if ($r.ExitCode -eq 3010) { $msg += ' (a reboot will be needed on the built system)' }
        return [pscustomobject]@{ id = 'image.cleanup'; status = 'applied'; message = $msg; whatIf = $false }
    }
    return [pscustomobject]@{ id = 'image.cleanup'; status = 'failed'; message = ('dism exit {0}: {1}' -f $r.ExitCode, (Format-ImgShort $r.Output 300)); whatIf = $false }
}

# =============================================================================================
# WIM image names (NAME / DISPLAYNAME)
# =============================================================================================
# Export-WindowsImage -DestinationName only sets NAME. DISM, Get-WindowsImage and Windows Setup show
# DISPLAYNAME when it exists, and Microsoft's images carry one ("Windows 11 Pro"). DISM has no switch
# for DISPLAYNAME, so we rewrite the WIM's XML resource ourselves. Layout (WIM format spec, also used
# by wimlib): the 208-byte header holds rhXmlData at 0x48 = 7-byte size + 1-byte flags, 8-byte offset,
# 8-byte original size. The XML is stored uncompressed as UTF-16LE with a BOM and is not covered by
# the integrity table (that table covers header end -> lookup table end). We append the new XML at
# the end of the file and repoint the header, so no existing byte the image depends on moves.

function Get-WimXmlLocation {
    param([System.IO.Stream]$Stream)
    $hdr = New-Object byte[] 208
    [void]$Stream.Seek(0, [System.IO.SeekOrigin]::Begin)
    if ($Stream.Read($hdr, 0, 208) -ne 208) { throw 'file is too small to be a WIM' }
    if ([System.Text.Encoding]::ASCII.GetString($hdr, 0, 5) -ne 'MSWIM') { throw 'not a WIM file (no MSWIM tag); .esd/.swm are not supported here' }
    $sizeBytes = New-Object byte[] 8
    [Array]::Copy($hdr, 0x48, $sizeBytes, 0, 7)
    return [pscustomobject]@{
        Header       = $hdr
        Size         = [BitConverter]::ToInt64($sizeBytes, 0)
        Flags        = $hdr[0x4F]
        Offset       = [BitConverter]::ToInt64($hdr, 0x50)
        OriginalSize = [BitConverter]::ToInt64($hdr, 0x58)
        PartNumber   = [BitConverter]::ToUInt16($hdr, 0x28)
        TotalParts   = [BitConverter]::ToUInt16($hdr, 0x2A)
    }
}

function Read-WimXmlText {
    param([System.IO.Stream]$Stream, $Location)
    if (($Location.Flags -band 0x04) -ne 0) { throw 'the WIM XML resource is compressed (unexpected); not touching it' }
    if ($Location.Size -le 2 -or $Location.Size -gt 64MB) { throw ('unexpected WIM XML size {0}' -f $Location.Size) }
    if ($Location.Offset -lt 208 -or ($Location.Offset + $Location.Size) -gt $Stream.Length) { throw 'WIM XML offset is outside the file' }
    $buf = New-Object byte[] ([int]$Location.Size)
    [void]$Stream.Seek($Location.Offset, [System.IO.SeekOrigin]::Begin)
    $read = 0
    while ($read -lt $buf.Length) {
        $n = $Stream.Read($buf, $read, $buf.Length - $read)
        if ($n -le 0) { throw 'unexpected end of file while reading the WIM XML' }
        $read += $n
    }
    $start = 0
    if ($buf.Length -ge 2 -and $buf[0] -eq 0xFF -and $buf[1] -eq 0xFE) { $start = 2 }
    return [System.Text.Encoding]::Unicode.GetString($buf, $start, $buf.Length - $start)
}

function Get-LiteOSWimInfo {
    <#
    .SYNOPSIS
        Reads NAME / DISPLAYNAME / DESCRIPTION / DISPLAYDESCRIPTION of one image straight from a .wim
        file's XML resource (read-only).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Index = 1
    )
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $loc = Get-WimXmlLocation -Stream $fs
        [xml]$doc = Read-WimXmlText -Stream $fs -Location $loc
    } finally { $fs.Dispose() }
    $img = $doc.SelectSingleNode(('/WIM/IMAGE[@INDEX="{0}"]' -f $Index))
    if (-not $img) { throw ('image index {0} not found in the WIM XML' -f $Index) }
    $get = { param($n) $e = $img.SelectSingleNode($n); if ($e) { [string]$e.InnerText } else { $null } }
    return [pscustomobject]@{
        Index              = $Index
        Name               = (& $get 'NAME')
        DisplayName        = (& $get 'DISPLAYNAME')
        Description        = (& $get 'DESCRIPTION')
        DisplayDescription = (& $get 'DISPLAYDESCRIPTION')
    }
}

function Set-LiteOSWimInfo {
    <#
    .SYNOPSIS
        Sets NAME, DISPLAYNAME, DESCRIPTION and DISPLAYDESCRIPTION of one image in a .wim file.
    .DESCRIPTION
        Appends a rewritten XML resource and repoints the WIM header (see the comment block above).
        The original header is kept in memory: if the result cannot be read back, the header and file
        length are restored, so a failed rename never leaves a broken install.wim. Single-part,
        uncompressed-XML WIMs only (what Export-WindowsImage writes). -WhatIf changes nothing.
        An 'applied' result also carries originalHeader (the 208 header bytes before the rename) and
        originalLength: Restore-LiteOSWimInfo puts the file back byte for byte with them (e.g. when
        DISM cannot read the renamed staging WIM that is the only copy of the image).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Index = 1,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$DisplayName,
        [string]$Description,
        [string]$DisplayDescription
    )
    if (-not $DisplayName) { $DisplayName = $Name }
    if (-not $DisplayDescription) { $DisplayDescription = $Description }
    if (-not $PSCmdlet.ShouldProcess($Path, ('set WIM image {0} name to "{1}"' -f $Index, $Name)) -or [bool]$WhatIfPreference) {
        return [pscustomobject]@{ status = 'skipped'; message = 'WhatIf: WIM image name not changed' }
    }
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $origHeader = $null
    $origLength = $fs.Length
    try {
        $loc = Get-WimXmlLocation -Stream $fs
        if ($loc.TotalParts -gt 1) { throw 'split WIM (.swm parts) are not supported; rename before splitting' }
        $origHeader = [byte[]]$loc.Header.Clone()
        [xml]$doc = Read-WimXmlText -Stream $fs -Location $loc
        $img = $doc.SelectSingleNode(('/WIM/IMAGE[@INDEX="{0}"]' -f $Index))
        if (-not $img) { throw ('image index {0} not found in the WIM XML' -f $Index) }
        $values = [ordered]@{ NAME = $Name; DESCRIPTION = $Description; DISPLAYNAME = $DisplayName; DISPLAYDESCRIPTION = $DisplayDescription }
        foreach ($k in $values.Keys) {
            if ($null -eq $values[$k] -or $values[$k] -eq '') { continue }
            $e = $img.SelectSingleNode($k)
            if (-not $e) { $e = $doc.CreateElement($k); [void]$img.AppendChild($e) }
            $e.InnerText = [string]$values[$k]
        }
        $newOffset = [int64]$fs.Length
        # TOTALBYTES = bytes before the XML resource (what DISM and wimlib write)
        $tb = $doc.SelectSingleNode('/WIM/TOTALBYTES')
        if ($tb) { $tb.InnerText = [string]$newOffset }
        $bom = [byte[]](0xFF, 0xFE)
        $body = [System.Text.Encoding]::Unicode.GetBytes($doc.DocumentElement.OuterXml)
        $bytes = New-Object byte[] ($bom.Length + $body.Length)
        [Array]::Copy($bom, 0, $bytes, 0, 2)
        [Array]::Copy($body, 0, $bytes, 2, $body.Length)

        [void]$fs.Seek($newOffset, [System.IO.SeekOrigin]::Begin)
        $fs.Write($bytes, 0, $bytes.Length)
        $hdr = [byte[]]$origHeader.Clone()
        $sizeBytes = [BitConverter]::GetBytes([int64]$bytes.Length)
        [Array]::Copy($sizeBytes, 0, $hdr, 0x48, 7)          # 56-bit size, flags byte (0x4F) untouched
        [Array]::Copy([BitConverter]::GetBytes($newOffset), 0, $hdr, 0x50, 8)
        [Array]::Copy([BitConverter]::GetBytes([int64]$bytes.Length), 0, $hdr, 0x58, 8)
        [void]$fs.Seek(0, [System.IO.SeekOrigin]::Begin)
        $fs.Write($hdr, 0, $hdr.Length)
        $fs.Flush()

        # read back from the same handle before letting go
        $check = Get-WimXmlLocation -Stream $fs
        [xml]$again = Read-WimXmlText -Stream $fs -Location $check
        $n = $again.SelectSingleNode(('/WIM/IMAGE[@INDEX="{0}"]/DISPLAYNAME' -f $Index))
        if (-not $n -or $n.InnerText -ne $DisplayName) { throw 'read-back of the new WIM XML did not match' }
    }
    catch {
        if ($origHeader) {
            try {
                [void]$fs.Seek(0, [System.IO.SeekOrigin]::Begin)
                $fs.Write($origHeader, 0, $origHeader.Length)
                $fs.SetLength($origLength)
                $fs.Flush()
            } catch { }
        }
        $fs.Dispose()
        return [pscustomobject]@{ status = 'failed'; message = ('WIM name unchanged: ' + $_.Exception.Message) }
    }
    $fs.Dispose()
    return [pscustomobject]@{
        status         = 'applied'
        message        = ('WIM image {0}: NAME and DISPLAYNAME set to "{1}"' -f $Index, $Name)
        originalHeader = $origHeader
        originalLength = [int64]$origLength
    }
}

function Restore-LiteOSWimInfo {
    <#
    .SYNOPSIS
        Undoes Set-LiteOSWimInfo: writes the original WIM header back and cuts the file to its
        original length.
    .DESCRIPTION
        Set-LiteOSWimInfo only appends a new XML resource and repoints the header, so the original
        header bytes plus the original length (originalHeader / originalLength of its 'applied'
        result) give back the file byte for byte. Refuses (status failed, file unchanged) when the
        bytes are not a WIM header, the file is shorter than before, or its header does not point at
        an XML resource behind the original end (so it never cuts a file that was rewritten since).
        -WhatIf changes nothing.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Header,
        [Parameter(Mandatory = $true)][int64]$Length
    )
    if ($Header.Length -ne 208 -or [System.Text.Encoding]::ASCII.GetString($Header, 0, 5) -ne 'MSWIM') {
        return [pscustomobject]@{ status = 'failed'; message = 'WIM rename not undone: the saved header is not a WIM header' }
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'restore the WIM header and length from before the rename') -or [bool]$WhatIfPreference) {
        return [pscustomobject]@{ status = 'skipped'; message = 'WhatIf: WIM rename not undone' }
    }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        if ($fs.Length -lt $Length) { throw ('the file ({0} bytes) is shorter than before the rename ({1} bytes); it was rewritten since' -f $fs.Length, $Length) }
        $now = Get-WimXmlLocation -Stream $fs
        if ($now.Offset -lt $Length) { throw 'the WIM header does not point at an XML resource appended by the rename; nothing to undo' }
        # header first: until the file is cut, the old header still points at the old (intact) XML
        [void]$fs.Seek(0, [System.IO.SeekOrigin]::Begin)
        $fs.Write($Header, 0, $Header.Length)
        $fs.SetLength($Length)
        $fs.Flush()
        $check = Get-WimXmlLocation -Stream $fs
        [void](Read-WimXmlText -Stream $fs -Location $check)
    }
    catch {
        return [pscustomobject]@{ status = 'failed'; message = ('WIM rename not undone: ' + $_.Exception.Message) }
    }
    finally {
        if ($null -ne $fs) { $fs.Dispose() }
    }
    return [pscustomobject]@{ status = 'applied'; message = 'WIM header and length restored (rename undone)' }
}

Export-ModuleMember -Function @(
    'Get-LiteOSWimInfo',
    'Set-LiteOSWimInfo',
    'Restore-LiteOSWimInfo',
    'Get-LiteOSRemovals',
    'Select-LiteOSRemovals',
    'Invoke-LiteOSImageRemovals',
    'Merge-LiteOSRemovalResults',
    'Invoke-LiteOSImageCleanup',
    'Invoke-LiteOSCoreDefender',
    'Invoke-LiteOSCoreUpdateStack'
)

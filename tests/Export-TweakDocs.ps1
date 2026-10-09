<#
.SYNOPSIS
    Generates docs\TWEAKS.md from the tweak catalog (tweaks\*.json) and docs\IMAGE.md from the
    Lite OS image definition (image\*.json, image\layout\*).

.DESCRIPTION
    Reads the JSON / XML directly (no module is loaded) and writes two Markdown pages:
      - docs\TWEAKS.md: one table per tweak category plus the app removal / app install lists.
      - docs\IMAGE.md:  Lite vs Core, everything removed from the image per mode, the installers
        baked into the image, the branding and the Start / taskbar pins.
    The output is deterministic (no timestamps, LF line endings) so CI can check that both files
    are up to date with "git diff --exit-code docs/TWEAKS.md docs/IMAGE.md".

    Read-only except for writing the output files.

.PARAMETER CatalogPath
    Folder with the catalog JSON files. Default: ..\tweaks

.PARAMETER OutFile
    Markdown file to write for the tweak list. Default: ..\docs\TWEAKS.md

.PARAMETER ImagePath
    Folder with removals.json, branding.json, installers.json and layout\. Default: ..\image

.PARAMETER ImageOutFile
    Markdown file to write for the image contents. Default: ..\docs\IMAGE.md

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Export-TweakDocs.ps1
#>
[CmdletBinding()]
param(
    [string]$CatalogPath,
    [string]$OutFile,
    [string]$ImagePath,
    [string]$ImageOutFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $CatalogPath) { $CatalogPath = Join-Path $repoRoot 'tweaks' }
if (-not $OutFile) { $OutFile = Join-Path $repoRoot 'docs\TWEAKS.md' }
if (-not $ImagePath) { $ImagePath = Join-Path $repoRoot 'image' }
if (-not $ImageOutFile) { $ImageOutFile = Join-Path $repoRoot 'docs\IMAGE.md' }

$categoryOrder = @('privacy', 'ui', 'gaming', 'performance', 'network', 'services', 'updates', 'security-extreme')
$appsRemoveName = 'apps-remove.json'
$appsInstallName = 'apps-install.json'

function Get-P {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Read-Json {
    param([string]$Path)
    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    } catch {
        $msg = (($_.Exception.Message -split "`r?`n")[0])
        if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }
        throw ('{0}: invalid JSON - {1}' -f (Split-Path -Leaf $Path), $msg)
    }
}

function ConvertTo-Cell {
    # one Markdown table cell: single line, pipes escaped, HTML-ish brackets neutralised
    param($Value)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    $s = $s -replace '\r?\n', ' '
    $s = $s -replace '\|', '\|'
    $s = $s -replace '<', '&lt;' -replace '>', '&gt;'
    return $s.Trim()
}

function ConvertTo-YesNo {
    param($Value)
    if ($Value -is [bool]) { if ($Value) { return 'yes' } else { return 'no' } }
    if ($null -eq $Value) { return '' }
    return (ConvertTo-Cell $Value)
}

function Get-BuildNote {
    param($Tweak)
    $min = Get-P $Tweak 'minBuild'
    $max = Get-P $Tweak 'maxBuild'
    if ($null -ne $min -and $null -ne $max) { return (' _(Windows builds {0}-{1} only)_' -f $min, $max) }
    if ($null -ne $min) { return (' _(Windows build {0}+)_' -f $min) }
    if ($null -ne $max) { return (' _(Windows build {0} and older)_' -f $max) }
    return ''
}

if (-not (Test-Path -LiteralPath $CatalogPath)) { throw "Catalog folder not found: $CatalogPath" }

# ---------------------------------------------------------------- load
$categories = New-Object System.Collections.ArrayList
foreach ($f in @(Get-ChildItem -LiteralPath $CatalogPath -Filter '*.json' -File | Sort-Object Name)) {
    if ($f.Name -eq $appsRemoveName -or $f.Name -eq $appsInstallName) { continue }
    $doc = Read-Json $f.FullName
    $cat = [string](Get-P $doc 'category' $f.BaseName)
    $rank = [array]::IndexOf($categoryOrder, $cat)
    if ($rank -lt 0) { $rank = 1000 }
    [void]$categories.Add((New-Object PSObject -Property @{
                File     = $f.Name
                Category = $cat
                Title    = [string](Get-P $doc 'title' $cat)
                Tweaks   = @(Get-P $doc 'tweaks' @())
                Rank     = $rank
            }))
}
# ordinal sort (known categories first, in contract order) so the output never depends on the culture
$byKey = @{}
foreach ($c in $categories) { $byKey[('{0:D4}|{1}|{2}' -f $c.Rank, $c.Category, $c.File)] = $c }
$sortKeys = [string[]]@($byKey.Keys)
[System.Array]::Sort($sortKeys, [System.StringComparer]::Ordinal)
$categories = @($sortKeys | ForEach-Object { $byKey[$_] })

$appsRemove = $null
$appsRemovePath = Join-Path $CatalogPath $appsRemoveName
if (Test-Path -LiteralPath $appsRemovePath) { $appsRemove = Read-Json $appsRemovePath }
$appsInstall = $null
$appsInstallPath = Join-Path $CatalogPath $appsInstallName
if (Test-Path -LiteralPath $appsInstallPath) { $appsInstall = Read-Json $appsInstallPath }

# ---------------------------------------------------------------- render
$md = New-Object System.Collections.Generic.List[string]
function Add-Line {
    param([string]$Text = '')
    $md.Add($Text)
}

$total = 0; $balDefault = 0; $extDefault = 0; $optIn = 0
foreach ($c in $categories) {
    foreach ($t in $c.Tweaks) {
        $total++
        $lvl = [string](Get-P $t 'level' '')
        $def = (Get-P $t 'default' $false) -eq $true
        if (-not $def) { $optIn++ }
        elseif ($lvl -eq 'balanced') { $balDefault++ }
        elseif ($lvl -eq 'extreme') { $extDefault++ }
    }
}

Add-Line '# Lite OS tweak list'
Add-Line ''
Add-Line '> Generated from `tweaks/*.json` by `tests/Export-TweakDocs.ps1` - do not edit this file by hand.'
Add-Line '> Change the JSON, then run `powershell -NoProfile -ExecutionPolicy Bypass -File tests\Export-TweakDocs.ps1`.'
Add-Line ''
Add-Line '## How levels work'
Add-Line ''
Add-Line '- **Balanced** applies every `balanced` tweak whose default is **yes**. It keeps Windows Defender, security updates,'
Add-Line '  Microsoft Store, Xbox / Game Pass / Gaming Services, Game Bar, Edge + WebView2, Windows Hello, VBS/HVCI, TPM,'
Add-Line '  BitLocker and kernel anti-cheat working.'
Add-Line '- **Extreme** applies Balanced **plus** every `extreme` tweak whose default is **yes**. Read the descriptions: extreme'
Add-Line '  tweaks trade security or compatibility for a little less background activity.'
Add-Line '- Tweaks whose default is **no** are opt-in: they only run when you pick them in Custom mode or pass `-Include <id>`.'
Add-Line '- **Risk** is our estimate of what can go wrong (`none`, `low`, `medium`, `high`). **Reboot** = needs a restart to take effect.'
Add-Line '- Every change is recorded and can be undone with `Revert-LiteOS.ps1` (or menu option 5). Removed apps can be'
Add-Line '  reinstalled from Microsoft Store or winget.'
Add-Line ''
Add-Line ('**{0}** tweaks in total: **{1}** in Balanced, **{2}** more in Extreme, **{3}** opt-in.' -f $total, $balDefault, $extDefault, $optIn)
Add-Line ''
Add-Line '| Category | File | Tweaks | Balanced (default) | Extreme (default) | Opt-in |'
Add-Line '|---|---|---:|---:|---:|---:|'
foreach ($c in $categories) {
    $b = @($c.Tweaks | Where-Object { (Get-P $_ 'level' '') -eq 'balanced' -and (Get-P $_ 'default' $false) -eq $true }).Count
    $e = @($c.Tweaks | Where-Object { (Get-P $_ 'level' '') -eq 'extreme' -and (Get-P $_ 'default' $false) -eq $true }).Count
    $o = @($c.Tweaks | Where-Object { (Get-P $_ 'default' $false) -ne $true }).Count
    Add-Line ('| [{0}](#{1}) | `{2}` | {3} | {4} | {5} | {6} |' -f (ConvertTo-Cell $c.Title), $c.Category, $c.File, @($c.Tweaks).Count, $b, $e, $o)
}
if ($null -ne $appsRemove) { Add-Line ('| [Preinstalled apps removed](#apps-remove) | `{0}` | {1} | | | |' -f $appsRemoveName, @(Get-P $appsRemove 'packages' @()).Count) }
if ($null -ne $appsInstall) { Add-Line ('| [Optional apps (winget)](#apps-install) | `{0}` | {1} | | | |' -f $appsInstallName, @(Get-P $appsInstall 'apps' @()).Count) }
Add-Line ''

foreach ($c in $categories) {
    Add-Line ('<a id="{0}"></a>' -f $c.Category)
    Add-Line ''
    Add-Line ('## {0}' -f (ConvertTo-Cell $c.Title))
    Add-Line ''
    Add-Line ('Source: `tweaks/{0}` - {1} tweak(s).' -f $c.File, @($c.Tweaks).Count)
    Add-Line ''
    Add-Line '| ID | Name | Level | Default | Risk | Reboot | Description |'
    Add-Line '|---|---|---|---|---|---|---|'
    foreach ($t in $c.Tweaks) {
        Add-Line ('| `{0}` | {1} | {2} | {3} | {4} | {5} | {6}{7} |' -f
            (ConvertTo-Cell (Get-P $t 'id' '')),
            (ConvertTo-Cell (Get-P $t 'name' '')),
            (ConvertTo-Cell (Get-P $t 'level' '')),
            (ConvertTo-YesNo (Get-P $t 'default')),
            (ConvertTo-Cell (Get-P $t 'risk' '')),
            (ConvertTo-YesNo (Get-P $t 'reboot')),
            (ConvertTo-Cell (Get-P $t 'description' '')),
            (Get-BuildNote $t))
    }
    Add-Line ''
}

if ($null -ne $appsRemove) {
    Add-Line '<a id="apps-remove"></a>'
    Add-Line ''
    Add-Line ('## {0}' -f (ConvertTo-Cell (Get-P $appsRemove 'title' 'Remove preinstalled apps')))
    Add-Line ''
    Add-Line ('Source: `tweaks/{0}`. Each entry is also selectable as a tweak with the ID shown. Apps are removed for all' -f $appsRemoveName)
    Add-Line 'users and from the image so they do not come back for new accounts. Reinstall any of them from Microsoft Store.'
    Add-Line ''
    Add-Line '| Package | Name | Level | Default | Tweak ID |'
    Add-Line '|---|---|---|---|---|'
    foreach ($p in @(Get-P $appsRemove 'packages' @())) {
        $match = [string](Get-P $p 'match' '')
        Add-Line ('| `{0}` | {1} | {2} | {3} | `apps.remove.{4}` |' -f
            (ConvertTo-Cell $match),
            (ConvertTo-Cell (Get-P $p 'name' '')),
            (ConvertTo-Cell (Get-P $p 'level' '')),
            (ConvertTo-YesNo (Get-P $p 'default')),
            (ConvertTo-Cell $match.ToLowerInvariant()))
    }
    Add-Line ''
    $prot = @(Get-P $appsRemove 'protected' @())
    if ($prot.Count -gt 0) {
        Add-Line '### Never removed'
        Add-Line ''
        Add-Line 'Lite OS refuses to remove anything matching these patterns, at every level:'
        Add-Line ''
        foreach ($x in $prot) { Add-Line ('- `{0}`' -f (ConvertTo-Cell $x)) }
        Add-Line ''
    }
}

if ($null -ne $appsInstall) {
    Add-Line '<a id="apps-install"></a>'
    Add-Line ''
    Add-Line '## Optional apps (winget)'
    Add-Line ''
    Add-Line ('Source: `tweaks/{0}`. Installed with `src/Install-Apps.ps1` from the official winget source, only when you choose' -f $appsInstallName)
    Add-Line 'to (menu option 4, `-Apps default|all|<ids>`, or at ISO build time). **Default** = pre-selected.'
    Add-Line ''
    $apps = @(Get-P $appsInstall 'apps' @())
    $groups = New-Object System.Collections.ArrayList
    foreach ($a in $apps) { $g = [string](Get-P $a 'group' 'Other'); if (-not $groups.Contains($g)) { [void]$groups.Add($g) } }
    foreach ($g in $groups) {
        Add-Line ('### {0}' -f (ConvertTo-Cell $g))
        Add-Line ''
        Add-Line '| winget ID | Name | Default |'
        Add-Line '|---|---|---|'
        foreach ($a in $apps) {
            if ([string](Get-P $a 'group' 'Other') -ne $g) { continue }
            Add-Line ('| `{0}` | {1} | {2} |' -f (ConvertTo-Cell (Get-P $a 'id' '')), (ConvertTo-Cell (Get-P $a 'name' '')), (ConvertTo-YesNo (Get-P $a 'default')))
        }
        Add-Line ''
    }
}

# ---------------------------------------------------------------- write (UTF-8 without BOM, LF)
function Save-Markdown {
    param([System.Collections.Generic.List[string]]$Lines, [string]$Path)
    while ($Lines.Count -gt 0 -and $Lines[$Lines.Count - 1] -eq '') { $Lines.RemoveAt($Lines.Count - 1) }
    $body = ($Lines -join "`n") + "`n"
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $dir = Split-Path -Parent $full
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    [System.IO.File]::WriteAllText($full, $body, (New-Object System.Text.UTF8Encoding($false)))
    return $full
}

$fullOut = Save-Markdown -Lines $md -Path $OutFile
Write-Host ('Wrote {0} ({1} tweaks in {2} categories)' -f $fullOut, $total, $categories.Count)

# =============================================================================================
# docs\IMAGE.md - what the Lite OS Builder bakes into the image
# =============================================================================================
if (-not (Test-Path -LiteralPath $ImagePath)) {
    Write-Warning ('Image folder not found, {0} was not written: {1}' -f $ImageOutFile, $ImagePath)
    return
}

function Read-OptionalJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Read-Json $Path)
}

function Format-CodeList {
    # `a`, `b`, `c` (cell-safe); long lists are shortened so tables stay readable
    param([object[]]$Values, [int]$Max = 6)
    $items = @($Values | Where-Object { $null -ne $_ -and [string]$_ -ne '' } | ForEach-Object { '`' + (ConvertTo-Cell ([string]$_)) + '`' })
    if ($items.Count -eq 0) { return '' }
    if ($items.Count -gt $Max) { return ((($items[0..($Max - 1)]) -join ', ') + (', and {0} more' -f ($items.Count - $Max))) }
    return ($items -join ', ')
}

function Get-RemovalTarget {
    param($Removal)
    $type = [string](Get-P $Removal 'type' '')
    $match = @(Get-P $Removal 'match' @())
    $paths = @(Get-P $Removal 'paths' @())
    $appx = @(Get-P $Removal 'appx' @())
    $what = ''
    switch ($type) {
        'capability' { $what = ('capabilities ' + (Format-CodeList $match)) }
        'feature' { $what = ('optional features ' + (Format-CodeList $match)) }
        'package' { $what = ('packages ' + (Format-CodeList $match)) }
        'files' { $what = ('files ' + (Format-CodeList $paths)) }
        'onedrive' { $what = 'OneDrive first-logon install hook (Default profile Run entry)' }
        'edge' { $what = 'Microsoft Edge browser (WebView2 and Edge Update are kept)' }
        'winre' { $what = 'Windows Recovery Environment (WinRE), disabled after Setup' }
        'script' { $what = 'custom offline script' }
        default {
            $parts = @()
            if ($match.Count -gt 0) { $parts += (Format-CodeList $match) }
            if ($paths.Count -gt 0) { $parts += (Format-CodeList $paths) }
            $what = ($parts -join '; ')
        }
    }
    if ($appx.Count -gt 0) { $what += ('; provisioned apps ' + (Format-CodeList $appx)) }
    $conflicts = @(Get-P $Removal 'conflicts' @())
    if ($conflicts.Count -gt 0) { $what += ('; leaves out tweaks ' + (Format-CodeList $conflicts)) }
    return $what
}

function Get-PinName {
    # friendly name for a Start / taskbar pin key
    param([string]$Key)
    $k = $Key.ToLowerInvariant()
    if ($k -match 'file explorer\.lnk$|^id:microsoft\.windows\.explorer$') { return 'File Explorer' }
    if ($k -match 'microsoft edge\.lnk$|^id:msedge$') { return 'Microsoft Edge (Lite only; not installed in Core)' }
    if ($k -match '\\steam\\steam\.lnk$') { return 'Steam (preinstalled)' }
    if ($k -eq 'pkg:microsoft.gamingapp_8wekyb3d8bbwe!microsoft.xbox.app') { return 'Xbox' }
    if ($k -eq 'pkg:microsoft.windowsstore_8wekyb3d8bbwe!app') { return 'Microsoft Store' }
    if ($k -eq 'pkg:windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel') { return 'Settings' }
    if ($k -eq 'pkg:microsoft.windowsterminal_8wekyb3d8bbwe!app') { return 'Terminal' }
    return ''
}

$imageRemovals = Read-OptionalJson (Join-Path $ImagePath 'removals.json')
$imageBranding = Read-OptionalJson (Join-Path $ImagePath 'branding.json')
$imageInstallers = Read-OptionalJson (Join-Path $ImagePath 'installers.json')
$startLayout = Read-OptionalJson (Join-Path $ImagePath 'layout\LayoutModification.json')
$taskbarPath = Join-Path $ImagePath 'layout\TaskbarLayoutModification.xml'
$taskbarXml = $null
if (Test-Path -LiteralPath $taskbarPath) {
    $taskbarXml = New-Object System.Xml.XmlDocument
    $taskbarXml.XmlResolver = $null
    $taskbarXml.Load($taskbarPath)
}

$removalList = @()
if ($null -ne $imageRemovals) { $removalList = @(Get-P $imageRemovals 'removals' @()) }
$liteRemovals = @($removalList | Where-Object { [string](Get-P $_ 'mode' '') -eq 'lite' })
$coreRemovals = @($removalList | Where-Object { [string](Get-P $_ 'mode' '') -eq 'core' })
$liteDefault = @($liteRemovals | Where-Object { (Get-P $_ 'default' $false) -eq $true }).Count
$coreDefault = @($coreRemovals | Where-Object { (Get-P $_ 'default' $false) -eq $true }).Count

$md = New-Object System.Collections.Generic.List[string]

Add-Line '# What is inside a Lite OS image'
Add-Line ''
Add-Line '> Generated from `image/*.json` and `image/layout/*` by `tests/Export-TweakDocs.ps1` - do not edit this file by hand.'
Add-Line '> Change the JSON / XML, then run `powershell -NoProfile -ExecutionPolicy Bypass -File tests\Export-TweakDocs.ps1`.'
Add-Line ''
Add-Line 'The **Lite OS Builder** (`LiteOS-Builder.cmd`) downloads the official Windows 11 ISO from Microsoft on **your** PC'
Add-Line '(or uses an ISO you picked), removes the components below from the image, bakes in the tweaks from'
Add-Line '[TWEAKS.md](TWEAKS.md), the branding, the Start / taskbar layout and the installers listed here, and writes'
Add-Line '`LiteOS.iso`. Nothing is patched: Windows binaries, `ProductName` and `EditionID` stay Microsoft''s, so'
Add-Line 'activation works with your own license. Lite OS never hosts or uploads a Windows image.'
Add-Line ''
Add-Line '## Lite vs Core'
Add-Line ''
Add-Line '| | **Lite** (default) | **Core** (opt-in, X-Lite style) |'
Add-Line '|---|---|---|'
Add-Line '| Tweaks | Balanced | Extreme |'
Add-Line ('| Removed from the image | {0} Lite default(s) | the Lite ones plus {1} Core default(s) |' -f $liteDefault, $coreDefault)
Add-Line '| Windows Update / Microsoft Store | Keep working (monthly security updates) | **Not serviceable**: to update, rebuild from a newer official ISO |'
Add-Line '| Windows Defender | On | Removed / disabled - use another antivirus or accept the risk |'
Add-Line '| Microsoft Edge | Kept | Browser removed (WebView2 and its updater kept, launchers still work) |'
Add-Line '| WinRE (recovery) | Kept | Disabled after Setup - no "Reset this PC" or startup repair |'
Add-Line '| Xbox app, Game Pass, Gaming Services | Work | Installed, but Store and Game Pass installs / updates need the Windows Update service and fail |'
Add-Line '| Kernel anti-cheat | Works | Usually works; games that require Defender, VBS or recent updates may refuse to start |'
Add-Line ''
Add-Line 'Every image is cleaned with `DISM /Cleanup-Image /StartComponentCleanup /ResetBase` (both modes): installed'
Add-Line 'updates can no longer be uninstalled, but new updates install normally in Lite.'
Add-Line ''
Add-Line 'Override single entries with `-Include` / `-Exclude <id>` (exact ids or wildcards, Exclude wins) or in the'
Add-Line 'Builder''s **Customize** list. Entries whose default is **no** are only removed when you pick them.'
Add-Line ''

foreach ($section in @(
        @{ Mode = 'lite'; Title = 'Removed in Lite (and Core)'; Anchor = 'lite-removals'; List = $liteRemovals },
        @{ Mode = 'core'; Title = 'Removed in Core only'; Anchor = 'core-removals'; List = $coreRemovals })) {
    Add-Line ('<a id="{0}"></a>' -f $section.Anchor)
    Add-Line ''
    Add-Line ('## {0}' -f $section.Title)
    Add-Line ''
    if ($null -eq $imageRemovals) {
        Add-Line '_`image/removals.json` was not found._'
        Add-Line ''
        continue
    }
    if (@($section.List).Count -eq 0) {
        Add-Line '_No entries._'
        Add-Line ''
        continue
    }
    if ($section.Mode -eq 'core') {
        Add-Line '> **Core only.** These break Windows Update servicing, Defender or recovery on purpose. Read every description.'
        Add-Line ''
    }
    Add-Line '| ID | Name | Default | Risk | Removes | Description |'
    Add-Line '|---|---|---|---|---|---|'
    foreach ($r in @($section.List)) {
        Add-Line ('| `{0}` | {1} | {2} | {3} | {4} | {5} |' -f
            (ConvertTo-Cell (Get-P $r 'id' '')),
            (ConvertTo-Cell (Get-P $r 'name' '')),
            (ConvertTo-YesNo (Get-P $r 'default')),
            (ConvertTo-Cell (Get-P $r 'risk' '')),
            (Get-RemovalTarget $r),
            (ConvertTo-Cell (Get-P $r 'description' '')))
    }
    Add-Line ''
}

Add-Line '<a id="installers"></a>'
Add-Line ''
Add-Line '## Preinstalled software'
Add-Line ''
if ($null -eq $imageInstallers) {
    Add-Line '_`image/installers.json` was not found._'
    Add-Line ''
} else {
    Add-Line 'Source: `image/installers.json`. The **builder** downloads each installer from the official URL on your PC,'
    Add-Line 'refuses it unless its Authenticode signature is valid and the signer contains the publisher shown, and copies it'
    Add-Line 'to `C:\LiteOS\installers` in the image. `SetupComplete` runs them silently, in this order, before the first sign-in.'
    Add-Line 'Lite OS ships none of these files itself. Pick them in the Builder or with `-Installers default|none|<ids>`.'
    Add-Line ''
    Add-Line '| ID | Name | Mode | Default | Silent install | Signed by | Official source |'
    Add-Line '|---|---|---|---|---|---|---|'
    foreach ($i in @(Get-P $imageInstallers 'installers' @())) {
        $silent = '`' + (ConvertTo-Cell ([string](Get-P $i 'file' '') + ' ' + [string](Get-P $i 'args' ''))).Trim() + '`'
        $x = Get-P $i 'extract'
        if ($null -ne $x) { $silent += (' then `' + (ConvertTo-Cell ([string](Get-P $x 'run' '') + ' ' + [string](Get-P $x 'args' ''))).Trim() + '`') }
        $url = [string](Get-P $i 'url' '')
        $hostName = ''
        try { $hostName = ([System.Uri]$url).Host } catch { $hostName = $url }
        Add-Line ('| `{0}` | {1} | {2} | {3} | {4} | {5} | [{6}]({7}) |' -f
            (ConvertTo-Cell (Get-P $i 'id' '')),
            (ConvertTo-Cell (Get-P $i 'name' '')),
            (ConvertTo-Cell (Get-P $i 'mode' '')),
            (ConvertTo-YesNo (Get-P $i 'default')),
            $silent,
            (ConvertTo-Cell (Get-P $i 'publisher' '')),
            (ConvertTo-Cell $hostName),
            $url)
    }
    Add-Line ''
    Add-Line 'Installer fields: `url` (official https download), `file` (saved as), `args` (silent switches), `publisher`'
    Add-Line '(must be part of the Authenticode signer subject), `mode` (`lite`, `core` or `both`), `default`, and optional'
    Add-Line '`description`, `successCodes` (exit codes that count as success; default 0, 1638, 3010, 1641 - 3010 / 1641 mean'
    Add-Line 'success with a reboot pending, 1638 that a newer version is already installed), `timeoutMinutes` (default 15)'
    Add-Line 'and `extract` for self-extracting packages: `args` then contains `{extractDir}` (the runner replaces it with'
    Add-Line '`C:\LiteOS\installers\_extract\<id>`, a path without spaces), and after the extraction the runner starts'
    Add-Line '`extract.run` from that folder with `extract.args`. `{temp}` is a synonym of `{extractDir}`, `{dir}` is the'
    Add-Line 'installers folder.'
    Add-Line ''
}

Add-Line '<a id="branding"></a>'
Add-Line ''
Add-Line '## Branding'
Add-Line ''
if ($null -eq $imageBranding) {
    Add-Line '_`image/branding.json` was not found._'
    Add-Line ''
} else {
    Add-Line 'Source: `image/branding.json`. `<mode>` is Lite or Core, `<build>` the Windows build of your ISO.'
    Add-Line ''
    Add-Line '| Where it shows | Value |'
    Add-Line '|---|---|'
    Add-Line ('| Settings > System > About > Support (manufacturer) | {0} |' -f (ConvertTo-Cell (Get-P $imageBranding 'manufacturer' '')))
    Add-Line ('| OEM model | {0} |' -f (ConvertTo-Cell (Get-P $imageBranding 'model' '')))
    Add-Line ('| Support link | {0} |' -f (ConvertTo-Cell (Get-P $imageBranding 'supportUrl' '')))
    Add-Line ('| Registered organization | {0} |' -f (ConvertTo-Cell (Get-P $imageBranding 'registeredOrganization' '')))
    Add-Line ('| Boot menu entry | {0} |' -f (ConvertTo-Cell (Get-P $imageBranding 'bootDescription' '')))
    Add-Line ('| Windows Setup image name | {0} &lt;mode&gt; |' -f (ConvertTo-Cell (Get-P $imageBranding 'name' '')))
    Add-Line ('| ISO volume label | `{0}_...` |' -f (ConvertTo-Cell (Get-P $imageBranding 'isoLabelPrefix' '')))
    Add-Line ''
    Add-Line 'Lite OS does not patch Microsoft binaries (`basebrd.dll`, `winver`) and does not change `ProductName` or'
    Add-Line '`EditionID`: Windows Update and activation must keep recognising your edition.'
    Add-Line ''
}

Add-Line '<a id="layout"></a>'
Add-Line ''
Add-Line '## Start menu and taskbar'
Add-Line ''
if ($null -ne $startLayout) {
    Add-Line 'Start pins (`image/layout/LayoutModification.json` in the documented OEM format, copied to the Default'
    Add-Line 'profile and applied for every new account - you can rearrange them afterwards). File Explorer, Microsoft Store'
    Add-Line 'and Edge (Lite) are pinned on page 1 by Windows itself (an OEM pin of an app Windows already pins there is'
    Add-Line 'ignored); the OEM pins add:'
    Add-Line ''
    $n = 0
    foreach ($section in @(
            @{ Member = 'primaryOEMPins'; Where = 'page 1' },
            @{ Member = 'secondaryOEMPins'; Where = 'end of the pinned list' },
            @{ Member = 'firstRunOEMPins'; Where = 'Recommended' })) {
        foreach ($pin in @(Get-P $startLayout $section.Member @())) {
            $n++
            $key = ''
            foreach ($f in @('packagedAppId', 'desktopAppId', 'desktopAppLink')) {
                $v = Get-P $pin $f
                if ($null -ne $v) {
                    if ($f -eq 'packagedAppId') { $key = 'pkg:' + $v } elseif ($f -eq 'desktopAppId') { $key = 'id:' + $v } else { $key = 'lnk:' + $v }
                    break
                }
            }
            $name = Get-PinName $key
            $raw = $key -replace '^(pkg|id|lnk):', ''
            if ($name) { Add-Line ('{0}. {1} - `{2}` ({3})' -f $n, $name, (ConvertTo-Cell $raw), $section.Where) } else { Add-Line ('{0}. `{1}` ({2})' -f $n, (ConvertTo-Cell $raw), $section.Where) }
        }
    }
    Add-Line ''
}
if ($null -ne $taskbarXml) {
    $placement = ''
    $coll = $taskbarXml.SelectSingleNode('//*[local-name()="CustomTaskbarLayoutCollection"]')
    if ($null -ne $coll) { $placement = $coll.GetAttribute('PinListPlacement') }
    Add-Line ('Taskbar pins (`image/layout/TaskbarLayoutModification.xml`, `PinListPlacement="{0}"`, referenced by' -f $placement)
    Add-Line '`LayoutXMLPath` in the image; applied at first sign-in, you can unpin anything):'
    Add-Line ''
    $n = 0
    foreach ($node in @($taskbarXml.SelectNodes('//*[local-name()="TaskbarLayout" and not(@Region)]//*[local-name()="UWA" or local-name()="DesktopApp"]'))) {
        $n++
        $key = ''
        if ($node.HasAttribute('AppUserModelID')) { $key = 'pkg:' + $node.GetAttribute('AppUserModelID') }
        elseif ($node.HasAttribute('DesktopApplicationID')) { $key = 'id:' + $node.GetAttribute('DesktopApplicationID') }
        elseif ($node.HasAttribute('DesktopApplicationLinkPath')) { $key = 'lnk:' + $node.GetAttribute('DesktopApplicationLinkPath') }
        $name = Get-PinName $key
        $raw = $key -replace '^(pkg|id|lnk):', ''
        if ($name) { Add-Line ('{0}. {1} - `{2}`' -f $n, $name, (ConvertTo-Cell $raw)) } else { Add-Line ('{0}. `{1}`' -f $n, (ConvertTo-Cell $raw)) }
    }
    Add-Line ''
}
Add-Line 'Pins for apps that are not installed (for example Edge in Core) simply do not appear.'

$fullImageOut = Save-Markdown -Lines $md -Path $ImageOutFile
Write-Host ('Wrote {0} ({1} removals, {2} installers)' -f $fullImageOut, $removalList.Count, @(Get-P $imageInstallers 'installers' @()).Count)

<#
.SYNOPSIS
    Generates docs\TWEAKS.md from the tweak catalog (tweaks\*.json).

.DESCRIPTION
    Reads the catalog JSON directly (the engine is not loaded) and writes a Markdown page with
    one table per category plus the app removal / app install lists. The output is deterministic
    (no timestamps, LF line endings) so CI can check that docs\TWEAKS.md is up to date with
    "git status --porcelain docs/TWEAKS.md".

    Read-only except for writing the output file.

.PARAMETER CatalogPath
    Folder with the catalog JSON files. Default: ..\tweaks

.PARAMETER OutFile
    Markdown file to write. Default: ..\docs\TWEAKS.md

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Export-TweakDocs.ps1
#>
[CmdletBinding()]
param(
    [string]$CatalogPath,
    [string]$OutFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $CatalogPath) { $CatalogPath = Join-Path $repoRoot 'tweaks' }
if (-not $OutFile) { $OutFile = Join-Path $repoRoot 'docs\TWEAKS.md' }

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
while ($md.Count -gt 0 -and $md[$md.Count - 1] -eq '') { $md.RemoveAt($md.Count - 1) }
$text = ($md -join "`n") + "`n"
$fullOut = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
$outDir = Split-Path -Parent $fullOut
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { $null = New-Item -ItemType Directory -Path $outDir -Force }
[System.IO.File]::WriteAllText($fullOut, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('Wrote {0} ({1} tweaks in {2} categories)' -f $fullOut, $total, $categories.Count)

<#
.SYNOPSIS
    Lite OS optional app installer (winget).

.DESCRIPTION
    Installs optional gaming apps (launchers, runtimes, chat, tools) listed in
    tweaks\apps-install.json using winget from the official "winget" source:

        winget install --id <id> -e --source winget --accept-package-agreements
                       --accept-source-agreements --silent

    - An optional "location" in a catalog entry is passed as --location (some packages need one).
    - Apps that are already installed are skipped.
    - One failed app never aborts the run; a summary is printed at the end.
    - Without -Silent an interactive picker is shown (pre-selected with -Apps).
    - Nothing here touches Windows settings; it only runs winget.

.PARAMETER Apps
    What to install:
      default   catalog entries with "default": true (the default)
      all       every catalog entry
      none      nothing (exit immediately)
      <ids>     one or more exact winget ids, comma separated or as an array,
                e.g. -Apps "Valve.Steam,Discord.Discord". Can be mixed: "default,Mozilla.Firefox".
    Ids that are not in the catalog are allowed (they are shown as "Custom").

.PARAMETER Silent
    No prompts at all (used by LiteOS.ps1 -Silent / -FirstLogon). Installs the -Apps selection.

.PARAMETER CatalogPath
    Path to apps-install.json. Default: ..\tweaks\apps-install.json next to this script.

.PARAMETER DryRun
    Show what would be installed, install nothing. -WhatIf does the same.

.PARAMETER PassThru
    Also return one result object per app: Id, Name, Status (installed|skipped|failed|planned), Message, ExitCode.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\src\Install-Apps.ps1
    Interactive picker.

.EXAMPLE
    .\src\Install-Apps.ps1 -Apps default -Silent

.EXAMPLE
    .\src\Install-Apps.ps1 -Apps "Valve.Steam,EpicGames.EpicGamesLauncher" -Silent

.NOTES
    Exit codes: 0 = ok (nothing failed), 1 = at least one app failed, 2 = winget not available,
    3 = catalog could not be read. Part of Lite OS (GPL-3.0). Windows PowerShell 5.1 compatible, ASCII only.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]]$Apps = @('default'),
    [switch]$Silent,
    [string]$CatalogPath,
    [switch]$DryRun,
    [switch]$PassThru
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------
$script:IdPattern       = '^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$'
$script:StoreProductUri = 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1'
$script:GetWingetUrl    = 'https://aka.ms/getwinget'
$script:AppInstallerPfn = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
$script:LogFile         = $null
$script:IsDryRun        = ($DryRun.IsPresent -or [bool]$WhatIfPreference)

# winget return codes (https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md)
$script:WG_NO_APPLICATIONS_FOUND      = -1978335212   # 0x8A150014
$script:WG_NO_APPLICABLE_INSTALLER    = -1978335216   # 0x8A150010
$script:WG_MULTIPLE_APPLICATIONS      = -1978335210   # 0x8A150016
$script:WG_UPDATE_NOT_APPLICABLE      = -1978335189   # 0x8A15002B
$script:WG_PACKAGE_ALREADY_INSTALLED  = -1978335135   # 0x8A150061
$script:WG_INSTALL_PACKAGE_IN_USE     = -1978334975   # 0x8A150101
$script:WG_INSTALL_IN_PROGRESS        = -1978334974   # 0x8A150102
$script:WG_INSTALL_FILE_IN_USE        = -1978334973   # 0x8A150103
$script:WG_INSTALL_DISK_FULL          = -1978334971   # 0x8A150105
$script:WG_INSTALL_NO_NETWORK         = -1978334969   # 0x8A150107
$script:WG_INSTALL_REBOOT_TO_FINISH   = -1978334967   # 0x8A150109
$script:WG_INSTALL_REBOOT_FOR_INSTALL = -1978334966   # 0x8A15010A
$script:WG_INSTALL_REBOOT_INITIATED   = -1978334965   # 0x8A15010B
$script:WG_INSTALL_CANCELLED          = -1978334964   # 0x8A15010C
$script:WG_INSTALL_ALREADY_INSTALLED  = -1978334963   # 0x8A15010D
$script:WG_INSTALL_BLOCKED_BY_POLICY  = -1978334961   # 0x8A15010F
$script:WG_INSTALL_IN_USE_BY_APP      = -1978334959   # 0x8A150111

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Initialize-AppLog {
    if ($script:IsDryRun) { return }
    try {
        $dir = Join-Path $env:ProgramData 'LiteOS\logs'
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $script:LogFile = Join-Path $dir ('apps-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    } catch {
        $script:LogFile = $null
    }
}

function Write-AppLog {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Warn', 'Error', 'Ok', 'Muted')][string]$Level = 'Info',
        [switch]$NoConsole
    )
    if (-not $NoConsole) {
        $color = 'Gray'
        switch ($Level) {
            'Warn'  { $color = 'Yellow' }
            'Error' { $color = 'Red' }
            'Ok'    { $color = 'Green' }
            'Muted' { $color = 'DarkGray' }
        }
        Write-Host $Message -ForegroundColor $color
    }
    if ($null -ne $script:LogFile) {
        try {
            $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding ASCII
        } catch {
            $script:LogFile = $null
        }
    }
}

function Test-InteractiveHost {
    if ($Silent) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    foreach ($a in [Environment]::GetCommandLineArgs()) {
        if ($a -match '^-NonI') { return $false }
    }
    return $true
}

function Read-Answer {
    param([string]$Prompt, [string]$Default = '')
    try {
        $answer = Read-Host -Prompt $Prompt
    } catch {
        return $Default
    }
    if ($null -eq $answer) { return $Default }
    $answer = $answer.Trim()
    if ($answer -eq '') { return $Default }
    return $answer
}

function Format-ExitCode {
    param([int]$Code)
    return ('0x{0:X8}' -f $Code)
}

# ---------------------------------------------------------------------------
# catalog + selection
# ---------------------------------------------------------------------------
function Get-AppCatalog {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "App catalog not found: $Path" }
    $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $list = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($entry in @(Get-Prop $json 'apps' @())) {
        $id = [string](Get-Prop $entry 'id' '')
        if ($id -notmatch $script:IdPattern) {
            Write-AppLog ("Ignoring catalog entry with invalid id '{0}'." -f $id) -Level Warn
            continue
        }
        $key = $id.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $obj = New-Object PSObject -Property @{
            Id          = $id
            Name        = [string](Get-Prop $entry 'name' $id)
            Group       = [string](Get-Prop $entry 'group' 'Other')
            Default     = [bool](Get-Prop $entry 'default' $false)
            Description = [string](Get-Prop $entry 'description' '')
            Location    = [string](Get-Prop $entry 'location' '')
            InCatalog   = $true
        }
        [void]$list.Add($obj)
    }
    return $list.ToArray()
}

function Split-AppToken {
    param([string[]]$Value)
    $tokens = New-Object System.Collections.ArrayList
    foreach ($v in @($Value)) {
        if ($null -eq $v) { continue }
        foreach ($part in ($v -split '[,;\s]+')) {
            $t = $part.Trim()
            if ($t -ne '') { [void]$tokens.Add($t) }
        }
    }
    return $tokens.ToArray()
}

function Resolve-AppSelection {
    # Returns @{ Items = <all app objects incl. custom>; Selected = <hashtable lower-id -> $true> }
    param([object[]]$Catalog, [string[]]$Tokens)
    $items = New-Object System.Collections.ArrayList
    foreach ($c in @($Catalog)) { [void]$items.Add($c) }
    $byId = @{}
    foreach ($c in @($Catalog)) { $byId[$c.Id.ToLowerInvariant()] = $c }
    $selected = @{}
    $toks = @(Split-AppToken $Tokens)
    if ($toks.Count -eq 0) { $toks = @('default') }
    foreach ($t in $toks) {
        $lt = $t.ToLowerInvariant()
        if ($lt -eq 'default' -or $lt -eq 'defaults') {
            foreach ($c in @($Catalog)) { if ($c.Default) { $selected[$c.Id.ToLowerInvariant()] = $true } }
        } elseif ($lt -eq 'all') {
            foreach ($c in @($Catalog)) { $selected[$c.Id.ToLowerInvariant()] = $true }
        } elseif ($lt -eq 'none') {
            continue
        } elseif ($byId.ContainsKey($lt)) {
            $selected[$lt] = $true
        } elseif ($t -match $script:IdPattern) {
            $custom = New-Object PSObject -Property @{
                Id          = $t
                Name        = $t
                Group       = 'Custom'
                Default     = $false
                Description = 'Not in the Lite OS catalog (requested explicitly).'
                Location    = ''
                InCatalog   = $false
            }
            [void]$items.Add($custom)
            $byId[$lt] = $custom
            $selected[$lt] = $true
            Write-AppLog ("'{0}' is not in the Lite OS app catalog; it will be installed as a custom winget id." -f $t) -Level Warn
        } else {
            Write-AppLog ("Ignoring invalid app id '{0}'." -f $t) -Level Warn
        }
    }
    return @{ Items = $items.ToArray(); Selected = $selected }
}

function Get-OrderedApps {
    # group order = first appearance in the catalog, items keep catalog order
    param([object[]]$Items)
    $groups = New-Object System.Collections.ArrayList
    foreach ($i in @($Items)) { if (-not $groups.Contains($i.Group)) { [void]$groups.Add($i.Group) } }
    $ordered = New-Object System.Collections.ArrayList
    foreach ($g in $groups) {
        foreach ($i in @($Items)) { if ($i.Group -eq $g) { [void]$ordered.Add($i) } }
    }
    return @{ Groups = $groups.ToArray(); Apps = $ordered.ToArray() }
}

# ---------------------------------------------------------------------------
# winget discovery
# ---------------------------------------------------------------------------
function Find-Winget {
    try {
        $cmd = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd) { return $cmd.Source }
    } catch { $null = $_ }
    try {
        if ($env:LOCALAPPDATA) {
            $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
            if (Test-Path -LiteralPath $alias) { return $alias }
        }
    } catch { $null = $_ }
    try {
        # Works when running as SYSTEM or with access to WindowsApps; newest version wins.
        $pattern = Join-Path $env:ProgramFiles 'WindowsApps\Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe\winget.exe'
        $found = @(Resolve-Path -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object { $_.ProviderPath })
        if ($found.Count -gt 0) {
            $best = $found | Sort-Object -Descending -Property @{ Expression = {
                    $m = [regex]::Match($_, 'DesktopAppInstaller_([0-9.]+)_')
                    if ($m.Success) { try { [version]$m.Groups[1].Value } catch { [version]'0.0' } } else { [version]'0.0' }
                } } | Select-Object -First 1
            return $best
        }
    } catch { $null = $_ }
    return $null
}

function Register-AppInstaller {
    # On a brand-new account App Installer (winget) is registered in the background a few minutes
    # after first logon. Asking for the registration now usually makes winget available right away.
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage $script:AppInstallerPfn -ErrorAction Stop
        return $true
    } catch {
        Write-AppLog ('App Installer registration attempt failed: {0}' -f $_.Exception.Message) -Level Muted
        return $false
    }
}

function Wait-Winget {
    param([int]$TimeoutSeconds)
    $path = Find-Winget
    if ($null -ne $path) { return $path }
    if (-not $script:IsDryRun) {
        Write-AppLog 'winget not found yet - asking Windows to register App Installer...' -Level Warn
        $null = Register-AppInstaller
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $path = Find-Winget
        if ($null -ne $path) { return $path }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    return (Find-Winget)
}

function Show-WingetMissingHelp {
    param([bool]$Interactive)
    Write-AppLog '' -NoConsole
    Write-AppLog 'winget (App Installer) is not available, so no apps can be installed right now.' -Level Error
    Write-Host ''
    Write-Host '  How to fix it:' -ForegroundColor Yellow
    Write-Host '   1. Make sure you are online, then open Microsoft Store > Library > Get updates' -ForegroundColor Gray
    Write-Host '      (this installs or updates "App Installer", which contains winget).' -ForegroundColor Gray
    Write-Host ('   2. Or install App Installer from {0}' -f $script:GetWingetUrl) -ForegroundColor Gray
    Write-Host '   3. On a fresh install, signing out and back in (or waiting a few minutes) also works:' -ForegroundColor Gray
    Write-Host '      Windows registers winget for new accounts in the background.' -ForegroundColor Gray
    Write-Host '   Then run this again: Start-LiteOS.cmd > 4 (Install gaming apps).' -ForegroundColor Gray
    Write-Host ''
    if ($Interactive) {
        $a = Read-Answer -Prompt 'Open the App Installer page in Microsoft Store now? [y/N]' -Default 'n'
        if ($a -match '^(y|yes)$') {
            try { Start-Process -FilePath $script:StoreProductUri } catch { Write-AppLog ('Could not open Microsoft Store: {0}' -f $_.Exception.Message) -Level Warn }
        }
    }
}

# ---------------------------------------------------------------------------
# network
# ---------------------------------------------------------------------------
function Test-Internet {
    $hostName = 'cdn.winget.microsoft.com'
    try {
        $null = [System.Net.Dns]::GetHostAddresses($hostName)
    } catch {
        return $false
    }
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($hostName, 443, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(4000, $false)
        if ($ok -and $client.Connected) { return $true }
        return $false
    } catch {
        return $false
    } finally {
        if ($null -ne $client) { try { $client.Close() } catch { $null = $_ } }
    }
}

function Wait-Internet {
    param([int]$TimeoutSeconds)
    if (Test-Internet) { return $true }
    Write-AppLog ('No internet connection yet - waiting up to {0} seconds...' -f $TimeoutSeconds) -Level Warn
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        if (Test-Internet) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# installed-state detection
# ---------------------------------------------------------------------------
function Get-InstalledWingetIds {
    # One "winget export" call lists every installed package that maps to the winget source.
    # Returns a hashtable (lower-case id -> $true), or $null if export is not usable.
    param([Parameter(Mandatory = $true)][string]$Winget)
    $ErrorActionPreference = 'Continue'
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('liteos-winget-export-{0}.json' -f ([guid]::NewGuid().ToString('N')))
    try {
        $null = & $Winget export --output $tmp --source winget --accept-source-agreements --disable-interactivity 2>&1
        if (-not (Test-Path -LiteralPath $tmp)) { return $null }
        $data = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
        $ids = @{}
        foreach ($src in @(Get-Prop $data 'Sources' @())) {
            foreach ($pkg in @(Get-Prop $src 'Packages' @())) {
                $pkgId = [string](Get-Prop $pkg 'PackageIdentifier' '')
                if ($pkgId -ne '') { $ids[$pkgId.ToLowerInvariant()] = $true }
            }
        }
        return $ids
    } catch {
        return $null
    } finally {
        try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -WhatIf:$false } } catch { $null = $_ }
    }
}

function Test-WingetInstalled {
    param([Parameter(Mandatory = $true)][string]$Winget, [Parameter(Mandatory = $true)][string]$Id)
    $ErrorActionPreference = 'Continue'
    try {
        # exit code 0 = an installed package matches the exact id (0x8A150014 = none found). The table
        # output is not parsed because winget truncates long ids to fit the console width.
        $null = & $Winget list --id $Id -e --source winget --accept-source-agreements --disable-interactivity 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
function Invoke-WingetInstall {
    param(
        [Parameter(Mandatory = $true)][string]$Winget,
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Location = '',
        [bool]$NoInteractivity
    )
    # $Id was validated against $script:IdPattern (no spaces or quotes), so a plain argument string is safe.
    $arguments = 'install --id {0} -e --source winget --accept-package-agreements --accept-source-agreements --silent' -f $Id
    if ($Location -ne '') {
        # some packages (e.g. Battle.net) refuse to install without an explicit --location
        $expanded = [Environment]::ExpandEnvironmentVariables($Location)
        if ($expanded.IndexOf('"') -ge 0) { throw ('Invalid install location for {0}: {1}' -f $Id, $Location) }
        $arguments += (' --location "{0}"' -f $expanded.TrimEnd('\'))
    }
    if ($NoInteractivity) { $arguments += ' --disable-interactivity' }
    # Start-Process -Wait would also wait for apps the installer launches (e.g. a launcher that starts
    # itself), so wait only for winget's own process.
    $proc = Start-Process -FilePath $Winget -ArgumentList $arguments -NoNewWindow -PassThru
    $null = $proc.Handle
    $proc.WaitForExit()
    $code = $proc.ExitCode
    if ($null -eq $code) { $code = -1 }
    return [int]$code
}

function Convert-WingetResult {
    param([int]$Code)
    $hex = Format-ExitCode $Code
    if ($Code -eq 0) { return @{ Status = 'installed'; Message = 'installed'; Reboot = $false } }
    if ($Code -eq 3010 -or $Code -eq 1641 -or
        $Code -eq $script:WG_INSTALL_REBOOT_TO_FINISH -or
        $Code -eq $script:WG_INSTALL_REBOOT_FOR_INSTALL -or
        $Code -eq $script:WG_INSTALL_REBOOT_INITIATED) {
        return @{ Status = 'installed'; Message = 'installed - restart required to finish'; Reboot = $true }
    }
    if ($Code -eq $script:WG_PACKAGE_ALREADY_INSTALLED -or
        $Code -eq $script:WG_INSTALL_ALREADY_INSTALLED -or
        $Code -eq $script:WG_UPDATE_NOT_APPLICABLE) {
        return @{ Status = 'skipped'; Message = 'already installed'; Reboot = $false }
    }
    $msg = 'winget exit code {0}' -f $hex
    switch ($Code) {
        $script:WG_NO_APPLICATIONS_FOUND     { $msg = 'not found in the winget source (check the id)' }
        $script:WG_MULTIPLE_APPLICATIONS     { $msg = 'id matched more than one package' }
        $script:WG_NO_APPLICABLE_INSTALLER   { $msg = 'no installer for this system / architecture' }
        $script:WG_INSTALL_NO_NETWORK        { $msg = 'no network connection' }
        $script:WG_INSTALL_DISK_FULL         { $msg = 'disk is full' }
        $script:WG_INSTALL_CANCELLED         { $msg = 'cancelled' }
        $script:WG_INSTALL_BLOCKED_BY_POLICY { $msg = 'blocked by policy' }
        $script:WG_INSTALL_IN_PROGRESS       { $msg = 'another installation is in progress - try again later' }
        $script:WG_INSTALL_PACKAGE_IN_USE    { $msg = 'app is running - close it and try again' }
        $script:WG_INSTALL_IN_USE_BY_APP     { $msg = 'app is running - close it and try again' }
        $script:WG_INSTALL_FILE_IN_USE       { $msg = 'files are in use - close the app and try again' }
    }
    if ($msg -notmatch '^winget exit code') { $msg = '{0} ({1})' -f $msg, $hex }
    return @{ Status = 'failed'; Message = $msg; Reboot = $false }
}

function New-AppResult {
    param($App, [string]$Status, [string]$Message, $ExitCode = $null)
    return New-Object PSObject -Property ([ordered]@{
            Id       = $App.Id
            Name     = $App.Name
            Status   = $Status
            Message  = $Message
            ExitCode = $ExitCode
        })
}

# ---------------------------------------------------------------------------
# interactive picker
# ---------------------------------------------------------------------------
function Show-AppPicker {
    # Returns @{ Cancelled = <bool>; Apps = <chosen app objects> }.
    param([object[]]$Items, [hashtable]$Selected, $Installed)
    $layout = Get-OrderedApps -Items $Items
    $groups = @($layout.Groups)
    $apps = @($layout.Apps)
    $sel = @{}
    foreach ($k in $Selected.Keys) { $sel[$k] = $true }
    $notice = ''

    while ($true) {
        Write-Host ''
        Write-Host ' Lite OS - optional apps' -ForegroundColor Cyan
        Write-Host ' Installed with winget from the official winget source. Nothing is installed until you confirm.' -ForegroundColor DarkGray
        $n = 0
        for ($g = 0; $g -lt $groups.Count; $g++) {
            Write-Host ''
            Write-Host ('  G{0}  {1}' -f ($g + 1), $groups[$g]) -ForegroundColor Cyan
            foreach ($a in $apps) {
                if ($a.Group -ne $groups[$g]) { continue }
                $n++
                $key = $a.Id.ToLowerInvariant()
                $isSel = $sel.ContainsKey($key)
                $mark = '[ ]'
                if ($isSel) { $mark = '[x]' }
                $suffix = ''
                if ($null -ne $Installed -and $Installed.ContainsKey($key)) { $suffix = '  (installed)' }
                $line = '   {0} {1,3}. {2,-34} {3}{4}' -f $mark, $n, $a.Name, $a.Id, $suffix
                if ($isSel) { Write-Host $line -ForegroundColor Green } else { Write-Host $line -ForegroundColor Gray }
            }
        }
        Write-Host ''
        Write-Host (' Selected: {0} of {1}' -f $sel.Count, $apps.Count) -ForegroundColor White
        Write-Host ' Type numbers to toggle (e.g. 1 3 5 or 2-6), G<n> toggles a whole group.' -ForegroundColor DarkGray
        Write-Host ' A = all   N = none   D = defaults   Enter = continue   Q = quit' -ForegroundColor DarkGray
        if ($notice -ne '') { Write-Host (' ' + $notice) -ForegroundColor Yellow; $notice = '' }

        $inputLine = Read-Answer -Prompt ' Choice' -Default ''
        if ($inputLine -eq '') { break }
        foreach ($tok in ($inputLine -split '[,;\s]+')) {
            $t = $tok.Trim().ToLowerInvariant()
            if ($t -eq '') { continue }
            if ($t -eq 'q' -or $t -eq 'quit') { return @{ Cancelled = $true; Apps = @() } }
            if ($t -eq 'a' -or $t -eq 'all') {
                foreach ($a in $apps) { $sel[$a.Id.ToLowerInvariant()] = $true }
                continue
            }
            if ($t -eq 'n' -or $t -eq 'none') { $sel = @{}; continue }
            if ($t -eq 'd' -or $t -eq 'default' -or $t -eq 'defaults') {
                $sel = @{}
                foreach ($a in $apps) { if ($a.Default) { $sel[$a.Id.ToLowerInvariant()] = $true } }
                continue
            }
            if ($t -match '^g(\d+)$') {
                $gi = [int]$Matches[1] - 1
                if ($gi -lt 0 -or $gi -ge $groups.Count) { $notice = "No group $t."; continue }
                $members = @($apps | Where-Object { $_.Group -eq $groups[$gi] })
                $allOn = $true
                foreach ($m in $members) { if (-not $sel.ContainsKey($m.Id.ToLowerInvariant())) { $allOn = $false } }
                foreach ($m in $members) {
                    $k = $m.Id.ToLowerInvariant()
                    if ($allOn) { $sel.Remove($k) } else { $sel[$k] = $true }
                }
                continue
            }
            $from = 0; $to = 0
            if ($t -match '^(\d+)-(\d+)$') {
                $from = [int]$Matches[1]; $to = [int]$Matches[2]
                if ($from -gt $to) { $tmpSwap = $from; $from = $to; $to = $tmpSwap }
            } elseif ($t -match '^\d+$') {
                $from = [int]$t; $to = $from
            } else {
                $notice = "Unknown input '$t'."
                continue
            }
            for ($i = $from; $i -le $to; $i++) {
                if ($i -lt 1 -or $i -gt $apps.Count) { $notice = "No app number $i."; continue }
                $k = $apps[$i - 1].Id.ToLowerInvariant()
                if ($sel.ContainsKey($k)) { $sel.Remove($k) } else { $sel[$k] = $true }
            }
        }
    }

    $chosen = New-Object System.Collections.ArrayList
    foreach ($a in $apps) { if ($sel.ContainsKey($a.Id.ToLowerInvariant())) { [void]$chosen.Add($a) } }
    return @{ Cancelled = $false; Apps = $chosen.ToArray() }
}

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
function Show-Summary {
    param([object[]]$Results, [bool]$RebootNeeded)
    Write-Host ''
    Write-Host ' App install summary' -ForegroundColor Cyan
    Write-Host (' {0,-10} {1,-40} {2}' -f 'STATUS', 'APP', 'DETAILS') -ForegroundColor DarkGray
    foreach ($r in @($Results)) {
        $color = 'Gray'
        switch ($r.Status) {
            'installed' { $color = 'Green' }
            'skipped'   { $color = 'DarkGray' }
            'planned'   { $color = 'Cyan' }
            'failed'    { $color = 'Red' }
        }
        $label = '{0} ({1})' -f $r.Name, $r.Id
        if ($r.Name -eq $r.Id) { $label = $r.Id }
        Write-Host (' {0,-10} {1,-40} {2}' -f $r.Status, $label, $r.Message) -ForegroundColor $color
        Write-AppLog ('RESULT {0} {1} {2}' -f $r.Status, $r.Id, $r.Message) -NoConsole
    }
    $ins = @($Results | Where-Object { $_.Status -eq 'installed' }).Count
    $skp = @($Results | Where-Object { $_.Status -eq 'skipped' }).Count
    $fai = @($Results | Where-Object { $_.Status -eq 'failed' }).Count
    $pln = @($Results | Where-Object { $_.Status -eq 'planned' }).Count
    Write-Host ''
    if ($pln -gt 0) {
        Write-Host (' Dry run: {0} app(s) would be installed, {1} skipped. Nothing was changed.' -f $pln, $skp) -ForegroundColor Cyan
    } else {
        $color = 'Green'
        if ($fai -gt 0) { $color = 'Yellow' }
        Write-Host (' Installed: {0}   Skipped: {1}   Failed: {2}' -f $ins, $skp, $fai) -ForegroundColor $color
    }
    if ($fai -gt 0) {
        Write-Host ' Failed apps can be retried later: Start-LiteOS.cmd > 4, or install them from their official site.' -ForegroundColor Yellow
    }
    if ($RebootNeeded) { Write-Host ' Some apps need a restart to finish installing.' -ForegroundColor Yellow }
    if ($null -ne $script:LogFile) { Write-Host (' Log: {0}' -f $script:LogFile) -ForegroundColor DarkGray }
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
$exitCode = 0
$results = New-Object System.Collections.ArrayList
try {
    Initialize-AppLog
    $interactive = Test-InteractiveHost
    Write-AppLog ('Lite OS app installer started (silent={0}, dryRun={1}, apps={2})' -f (-not $interactive), $script:IsDryRun, ((@($Apps) -join ','))) -NoConsole

    if (-not $CatalogPath) {
        $CatalogPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tweaks\apps-install.json'
    }
    $catalog = $null
    try {
        $catalog = @(Get-AppCatalog -Path $CatalogPath)
    } catch {
        Write-AppLog ('Could not read the app catalog: {0}' -f $_.Exception.Message) -Level Error
        exit 3
    }

    $tokens = @(Split-AppToken $Apps)
    $onlyNone = ($tokens.Count -gt 0)
    foreach ($t in $tokens) { if ($t.ToLowerInvariant() -ne 'none') { $onlyNone = $false } }
    if ($onlyNone -and -not $interactive) {
        Write-AppLog 'App installation skipped (-Apps none).' -Level Muted
        exit 0
    }

    $resolution = Resolve-AppSelection -Catalog $catalog -Tokens $tokens

    # winget must exist before anything else. On a fresh first logon it can take a while to appear.
    $waitSeconds = 15
    if (-not $interactive) { $waitSeconds = 180 }
    if ($script:IsDryRun) { $waitSeconds = 0 }
    $winget = Wait-Winget -TimeoutSeconds $waitSeconds
    if ($null -eq $winget) {
        Show-WingetMissingHelp -Interactive $interactive
        exit 2
    }
    Write-AppLog ('Using winget: {0}' -f $winget) -Level Muted

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ($identity.IsSystem) {
            Write-AppLog 'Running as SYSTEM: winget works best from a normal (administrator) user session.' -Level Warn
        }
    } catch { $null = $_ }

    Write-Host ' Checking which apps are already installed...' -ForegroundColor DarkGray
    $installed = Get-InstalledWingetIds -Winget $winget

    if ($interactive) {
        $pick = Show-AppPicker -Items $resolution.Items -Selected $resolution.Selected -Installed $installed
        if ($pick.Cancelled) {
            Write-AppLog 'Cancelled - nothing was installed.' -Level Muted
            exit 0
        }
        $chosen = @($pick.Apps)
    } else {
        $ordered = Get-OrderedApps -Items $resolution.Items
        $chosen = @($ordered.Apps | Where-Object { $resolution.Selected.ContainsKey($_.Id.ToLowerInvariant()) })
    }
    $chosen = @($chosen)

    if ($chosen.Count -eq 0) {
        Write-AppLog 'No apps selected - nothing to install.' -Level Muted
        exit 0
    }

    if ($interactive -and -not $script:IsDryRun) {
        $answer = Read-Answer -Prompt (' Install {0} app(s) now? [Y/n]' -f $chosen.Count) -Default 'y'
        if ($answer -notmatch '^(y|yes)$') {
            Write-AppLog 'Cancelled - nothing was installed.' -Level Muted
            exit 0
        }
    }

    if (-not $script:IsDryRun) {
        $netWait = 10
        if (-not $interactive) { $netWait = 90 }
        if (-not (Wait-Internet -TimeoutSeconds $netWait)) {
            Write-AppLog 'Could not reach the winget servers. Installs will probably fail; check your connection.' -Level Warn
            if ($interactive) {
                $answer = Read-Answer -Prompt ' Try anyway? [y/N]' -Default 'n'
                if ($answer -notmatch '^(y|yes)$') { exit 1 }
            }
        }
    }

    $rebootNeeded = $false
    $index = 0
    foreach ($app in $chosen) {
        $index++
        $key = $app.Id.ToLowerInvariant()
        try {
            # One "winget export" answered for every app; ask per app only if that failed. If either check
            # misses an installed app, winget install itself reports "already installed" (mapped to skipped).
            if ($null -ne $installed) {
                $already = $installed.ContainsKey($key)
            } else {
                $already = Test-WingetInstalled -Winget $winget -Id $app.Id
            }
            if ($already) {
                [void]$results.Add((New-AppResult -App $app -Status 'skipped' -Message 'already installed'))
                Write-AppLog ('[{0}/{1}] {2} is already installed - skipped.' -f $index, $chosen.Count, $app.Name) -Level Muted
                continue
            }
            if ($script:IsDryRun -or -not $PSCmdlet.ShouldProcess($app.Id, 'winget install')) {
                [void]$results.Add((New-AppResult -App $app -Status 'planned' -Message 'would be installed (dry run)'))
                continue
            }
            Write-AppLog ('[{0}/{1}] Installing {2} ({3})...' -f $index, $chosen.Count, $app.Name, $app.Id) -Level Info
            $code = Invoke-WingetInstall -Winget $winget -Id $app.Id -Location $app.Location -NoInteractivity (-not $interactive)
            $mapped = Convert-WingetResult -Code $code
            if ($mapped.Reboot) { $rebootNeeded = $true }
            [void]$results.Add((New-AppResult -App $app -Status $mapped.Status -Message $mapped.Message -ExitCode $code))
            $lvl = 'Ok'
            if ($mapped.Status -eq 'failed') { $lvl = 'Error' } elseif ($mapped.Status -eq 'skipped') { $lvl = 'Muted' }
            Write-AppLog ('  {0}: {1}' -f $app.Name, $mapped.Message) -Level $lvl
        } catch {
            [void]$results.Add((New-AppResult -App $app -Status 'failed' -Message $_.Exception.Message))
            Write-AppLog ('  {0}: {1}' -f $app.Name, $_.Exception.Message) -Level Error
        }
    }

    $resultArray = $results.ToArray()
    Show-Summary -Results $resultArray -RebootNeeded $rebootNeeded
    if (@($resultArray | Where-Object { $_.Status -eq 'failed' }).Count -gt 0) { $exitCode = 1 }
    if ($PassThru) { $resultArray }
} catch {
    Write-AppLog ('Unexpected error in the app installer: {0}' -f $_.Exception.Message) -Level Error
    $exitCode = 1
}
exit $exitCode

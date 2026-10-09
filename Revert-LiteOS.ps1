#Requires -Version 5.1
<#
.SYNOPSIS
    Reverts Lite OS changes from a backup (the latest one by default).

.DESCRIPTION
    Every Lite OS run writes $env:ProgramData\LiteOS\backup\backup-<yyyyMMdd-HHmmss>.json with the
    previous value of every registry value, service start type and scheduled task it changed.
    This script lists those backups and restores one (newest change first, best effort).

    Removed apps (AppX packages) are NOT reinstalled automatically. Their names are listed at the
    end so you can reinstall them from the Microsoft Store or with winget.

    Lite OS image: a PC installed from a Lite OS ISO also has backup-image.json, the settings the
    Lite OS Builder baked into Windows (plus what SetupComplete applied on the first start).
    Its machine-wide entries are restored for the whole PC. Its per-user entries were baked into the
    Default user profile that every account was created from, so they are restored into the account
    that runs this revert, and (with -DefaultProfile, or when you answer yes) into the Default profile
    used for accounts created later. Other existing accounts keep their settings until they run
    Revert-LiteOS.ps1 -Path <backup-image.json> themselves. Windows components the builder removed
    from the image cannot be put back by a revert.

    Easiest way to run it: Start-LiteOS.cmd -> menu option 5.

.PARAMETER Path
    A specific backup file to restore.

.PARAMETER Silent
    No prompts: restores the latest backup that was not reverted yet (or -Path).

.PARAMETER All
    Restore every backup that was not reverted yet, newest first (goes back to the state before
    the first Lite OS run).

.PARAMETER DryRun
    Show what would be reverted without changing anything.

.PARAMETER DefaultProfile
    Image backups only: also restore the per-user settings into the Default user profile, so
    accounts created later start with stock Windows settings. Without -Silent you are asked.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Revert-LiteOS.ps1

.EXAMPLE
    .\Revert-LiteOS.ps1 -Silent

.EXAMPLE
    .\Revert-LiteOS.ps1 -Path "C:\ProgramData\LiteOS\backup\backup-20261009-120000.json"

.EXAMPLE
    .\Revert-LiteOS.ps1 -Path "C:\ProgramData\LiteOS\backup\backup-image.json" -DefaultProfile
    Undo what the Lite OS image changed, for this account and for accounts created later.
#>
[CmdletBinding()]
param(
    [string]$Path,

    [switch]$Silent,

    [switch]$All,

    [switch]$DryRun,

    [switch]$DefaultProfile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Root = $PSScriptRoot
if ([string]::IsNullOrEmpty($script:Root)) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:EnginePath = Join-Path $script:Root 'src\LiteOS.Engine.psm1'
$script:ExitCode = 0
$script:Context = $null

function Read-Answer {
    param([string]$Prompt)
    $a = $null
    try { $a = Read-Host -Prompt $Prompt } catch { return $null }
    if ($null -eq $a) { return $null }
    return ([string]$a).Trim()
}

function Confirm-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    if ($Silent) { return $Default }
    $suffix = '[y/N]'
    if ($Default) { $suffix = '[Y/n]' }
    $a = Read-Answer ('  {0} {1}' -f $Prompt, $suffix)
    if ($null -eq $a) { return $false }
    if ($a -eq '') { return $Default }
    return ($a -match '^(?i)(y|yes)$')
}

function Format-BackupDate {
    param([string]$Created)
    $d = [datetime]::MinValue
    if ([datetime]::TryParse($Created, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$d)) {
        return $d.ToString('yyyy-MM-dd HH:mm')
    }
    return $Created
}

function Test-ImageBackupFile {
    # True for backup-image.json style backups ("source": "image") written by the Lite OS Builder.
    param([string]$File)
    try {
        $d = Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json
        $p = $d.PSObject.Properties['source']
        return ($null -ne $p -and [string]$p.Value -eq 'image')
    }
    catch { return $false }
}

function Show-ImageBackupNote {
    param([string[]]$Files)
    $who = [string]$script:Context.UserName
    Write-Host ''
    Write-Host '  Lite OS image backup' -ForegroundColor Cyan
    Write-Host '  These are the settings the Lite OS Builder baked into Windows (and what SetupComplete'
    Write-Host '  applied on the first start):'
    Write-Host '   - Machine-wide settings (policies, services, scheduled tasks, boot menu name) are'
    Write-Host '     restored for the whole PC.'
    Write-Host '   - Per-user settings were baked into the Default user profile, which every account on'
    Write-Host ('     this PC was created from. They are restored into YOUR account ({0}).' -f $who)
    Write-Host '   - Optionally also into the Default profile, so accounts created later start with the'
    Write-Host '     stock Windows settings.'
    Write-Host '   - Other existing accounts keep their settings. To revert one of them, sign in as that'
    Write-Host '     account and run (as administrator):'
    foreach ($f in @($Files)) { Write-Host ('       Revert-LiteOS.ps1 -Path "{0}"' -f $f) -ForegroundColor DarkGray }
    Write-Host '   - Apps and Windows components the builder removed from the image are not put back;'
    Write-Host '     reinstall apps from the Microsoft Store or with winget.'
    if ([string]$script:Context.UserSid -eq 'S-1-5-18') {
        Write-Host '   Running as SYSTEM: per-user settings would go to the SYSTEM profile. Run this from' -ForegroundColor Yellow
        Write-Host '   your own (administrator) account instead.' -ForegroundColor Yellow
    }
    Write-Host ''
}

function Show-Backups {
    param([object[]]$Backups)
    Write-Host ('  {0,3}  {1,-16}  {2,-10}  {3,6}  {4,8}  {5}' -f '#', 'Created', 'Level', 'Build', 'Changes', 'State')
    Write-Host ('  ' + ('-' * 66)) -ForegroundColor DarkGray
    $i = 0
    foreach ($b in @($Backups)) {
        $i++
        $state = 'not reverted'
        $color = 'Gray'
        if ($null -ne $b.Restored -and [string]$b.Restored -ne '') { $state = 'reverted ' + (Format-BackupDate ([string]$b.Restored)); $color = 'DarkGray' }
        elseif ($null -ne $b.RestoreAttempted -and [string]$b.RestoreAttempted -ne '') { $state = 'partly reverted - some changes failed, run it again'; $color = 'Yellow' }
        elseif (-not $b.Complete) { $state = 'not reverted (run was interrupted)'; $color = 'Yellow' }
        $lvl = [string]$b.Level
        if (-not $lvl) { $lvl = '-' }
        if ($null -ne $b.PSObject.Properties['Source'] -and [string]$b.Source -eq 'image') {
            $lvl = 'image'
            if ($null -ne $b.PSObject.Properties['Mode'] -and [string]$b.Mode) { $lvl = 'image ' + [string]$b.Mode }
        }
        Write-Host ('  {0,3}  {1,-16}  {2,-10}  {3,6}  {4,8}  {5}' -f $i, (Format-BackupDate ([string]$b.Created)), $lvl, $b.Build, $b.EntryCount, $state) -ForegroundColor $color
    }
    Write-Host ''
}

function Write-AppHints {
    param([object[]]$Results)
    $apps = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($r in @($Results)) {
        if ($null -eq $r -or $null -eq $r.apps) { continue }
        foreach ($a in @($r.apps)) {
            if ($null -eq $a) { continue }
            $dup = $false
            foreach ($x in $apps) { if ($x.name -eq $a.name) { $dup = $true; break } }
            if (-not $dup) { $apps.Add($a) }
        }
    }
    if ($apps.Count -eq 0) { return }
    Write-Host ''
    Write-Host '  Removed apps are not reinstalled automatically. To get one back:' -ForegroundColor Yellow
    Write-Host '    - open the Microsoft Store and search for it, or' -ForegroundColor Yellow
    Write-Host '    - use winget, for example:  winget search "<name>"  then  winget install --id <id> -e' -ForegroundColor Yellow
    foreach ($a in $apps) {
        $line = '    {0}' -f $a.name
        if ($a.familyName) { $line += ('   (Store link: ms-windows-store://pdp/?PFN={0})' -f $a.familyName) }
        Write-Host $line
    }
}

function Invoke-Reboot {
    param([int]$Seconds = 15)
    $exe = Join-Path $env:SystemRoot 'System32\shutdown.exe'
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & $exe /r /t $Seconds /c 'Lite OS: restarting to finish reverting changes.' 2>&1
        if ($LASTEXITCODE -eq 0) { Write-LiteOSLog -Level Warn ('Windows will restart in {0} seconds.' -f $Seconds) }
        else { Write-LiteOSLog -Level Warn 'Could not schedule the restart. Please restart Windows yourself.' }
    }
    finally { $ErrorActionPreference = $prev }
}

try {
    if (-not (Test-Path -LiteralPath $script:EnginePath -PathType Leaf)) {
        throw ('Engine not found: {0}. Keep Revert-LiteOS.ps1 next to the src\ folder.' -f $script:EnginePath)
    }
    Import-Module -Name $script:EnginePath -Force -DisableNameChecking

    if (-not (Test-LiteOSAdmin) -and -not $DryRun) {
        Write-Host ''
        Write-Host '  Reverting needs administrator rights.' -ForegroundColor Yellow
        Write-Host '  Double-click Start-LiteOS.cmd and choose 5 (Revert), or run from an elevated PowerShell:'
        Write-Host ('    powershell -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $script:Root 'Revert-LiteOS.ps1')) -ForegroundColor Cyan
        Write-Host ''
        $script:ExitCode = 1
    }
    else {
        $script:Context = Initialize-LiteOS -LogName 'revert' -DryRun:$DryRun
        Write-Host ''
        Write-Host '  LITE OS - Revert' -ForegroundColor Cyan
        if ($DryRun) { Write-Host '  DRY RUN - nothing will be changed.' -ForegroundColor Magenta }
        Write-Host ('  ' + ('=' * 68)) -ForegroundColor DarkGray

        $targets = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $cancel = $false
        if (-not [string]::IsNullOrEmpty($Path)) {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('Backup file not found: {0}' -f $Path) }
            $targets.Add((Resolve-Path -LiteralPath $Path).ProviderPath)
        }
        else {
            $listed = @(Get-LiteOSBackups -Directory $script:Context.BackupDir)
            $backups = @($listed | Where-Object { $_.Valid })
            foreach ($bad in @($listed | Where-Object { -not $_.Valid })) {
                Write-LiteOSLog -Level Warn ('Skipping {0}: {1}' -f $bad.Name, $bad.Error)
            }
            if ($backups.Count -eq 0) {
                Write-Host ('  No Lite OS backups found in {0}.' -f $script:Context.BackupDir)
                Write-Host '  If you need to go back further, use System Restore (run rstrui.exe).'
                $cancel = $true
            }
            else {
                $pending = @($backups | Where-Object { $null -eq $_.Restored -or [string]$_.Restored -eq '' })
                if ($All) {
                    foreach ($b in $pending) { $targets.Add($b.Path) }
                    if ($targets.Count -eq 0) { Write-Host '  Every backup was already reverted.'; $cancel = $true }
                }
                elseif ($Silent) {
                    if ($pending.Count -gt 0) { $targets.Add($pending[0].Path) }
                    else { Write-Host '  Every backup was already reverted.'; $cancel = $true }
                }
                else {
                    Show-Backups $backups
                    $def = 1
                    if ($pending.Count -gt 0) {
                        for ($i = 0; $i -lt $backups.Count; $i++) { if ($backups[$i].Path -eq $pending[0].Path) { $def = $i + 1; break } }
                    }
                    Write-Host ('  Enter = backup {0}   number = that backup   A = all not-reverted backups, newest first   0 = cancel' -f $def) -ForegroundColor DarkGray
                    $a = Read-Answer '  Restore which backup'
                    if ($null -eq $a -or $a -eq '0') { $cancel = $true }
                    elseif ($a -eq '') { $targets.Add($backups[$def - 1].Path) }
                    elseif ($a -ieq 'a') {
                        foreach ($b in $pending) { $targets.Add($b.Path) }
                        if ($targets.Count -eq 0) { Write-Host '  Every backup was already reverted.'; $cancel = $true }
                    }
                    elseif ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $backups.Count) { $targets.Add($backups[[int]$a - 1].Path) }
                    else { Write-Host '  Not a valid choice.' -ForegroundColor Yellow; $cancel = $true }
                }
            }
        }

        if (-not $cancel -and $targets.Count -gt 0) {
            $changes = 0
            foreach ($t in $targets) {
                try {
                    $d = Get-Content -LiteralPath $t -Raw -Encoding UTF8 | ConvertFrom-Json
                    $p = $d.PSObject.Properties['entries']
                    if ($null -ne $p) { $changes += @($p.Value).Count }
                }
                catch { $null = $_ }
            }
            $imageTargets = @($targets | Where-Object { Test-ImageBackupFile $_ })
            $includeDefault = [bool]$DefaultProfile
            Write-Host ''
            Write-Host ('  {0} backup(s), {1} recorded change(s) will be reverted (newest first).' -f $targets.Count, $changes)
            $go = $true
            if ($imageTargets.Count -gt 0) {
                Show-ImageBackupNote $imageTargets
                if (-not $DefaultProfile -and -not $Silent) {
                    $includeDefault = Confirm-YesNo 'Also restore the Default user profile (used for accounts created later)?' $true
                }
                if ($includeDefault) { Write-Host '  Per-user settings: your account and the Default profile.' -ForegroundColor DarkGray }
                else { Write-Host '  Per-user settings: your account only (add -DefaultProfile for new accounts too).' -ForegroundColor DarkGray }
                Write-LiteOSLog -NoConsole ('Image backup revert: {0}; Default profile included: {1}' -f ($imageTargets -join ', '), $includeDefault)
            }
            if (-not $Silent -and -not (Confirm-YesNo 'Continue?' $true)) { $go = $false }
            if (-not $go) {
                Write-Host '  Cancelled. Nothing was changed.' -ForegroundColor DarkGray
            }
            else {
                $all = New-Object -TypeName 'System.Collections.Generic.List[object]'
                foreach ($t in $targets) {
                    Write-Host ''
                    $isImage = ($imageTargets -contains $t)
                    $res = @(Restore-LiteOSBackup -Path $t -Context $script:Context -IncludeDefaultProfile:($isImage -and $includeDefault))
                    foreach ($r in $res) { $all.Add($r) }
                    $nr = @($res | Where-Object { $_.status -eq 'restored' }).Count
                    $ns = @($res | Where-Object { $_.status -eq 'skipped' }).Count
                    $nf = @($res | Where-Object { $_.status -eq 'failed' }).Count
                    $color = 'Green'
                    if ($nf -gt 0) { $color = 'Yellow' }
                    Write-Host ('  {0}: {1} reverted, {2} skipped, {3} failed' -f [System.IO.Path]::GetFileName($t), $nr, $ns, $nf) -ForegroundColor $color
                    foreach ($r in @($res | Where-Object { $_.status -eq 'failed' })) {
                        Write-Host ('    FAIL {0} [{1}] {2}: {3}' -f $r.tweakId, $r.hive, $r.action, $r.message) -ForegroundColor Red
                    }
                    foreach ($r in @($res | Where-Object { $_.status -eq 'skipped' -and $_.action -ne 'appx-remove' })) {
                        Write-Host ('    skip {0} [{1}] {2}: {3}' -f $r.tweakId, $r.hive, $r.action, $r.message) -ForegroundColor DarkGray
                    }
                }
                $failed = @($all | Where-Object { $_.status -eq 'failed' }).Count
                if ($failed -gt 0) { $script:ExitCode = 2 }
                Write-AppHints $all.ToArray()
                Write-Host ''
                Write-Host ('  Log: {0}' -f $script:Context.LogFile)
                if (-not $DryRun) {
                    Write-Host '  Restart Windows to finish reverting (Explorer, services and policies reload on restart).' -ForegroundColor Yellow
                    Write-Host '  If something still looks wrong, System Restore (rstrui.exe) has a "Lite OS" restore point.' -ForegroundColor DarkGray
                    if (-not $Silent -and (Confirm-YesNo 'Restart Windows now?' $false)) { Invoke-Reboot -Seconds 15 }
                }
            }
        }
    }
}
catch {
    $script:ExitCode = 1
    Write-Host ''
    Write-Host ('  Revert stopped because of an error: {0}' -f $_.Exception.Message) -ForegroundColor Red
    try { Write-LiteOSLog -NoConsole -Level Error ('FATAL: {0} {1}' -f $_.Exception.Message, $_.InvocationInfo.PositionMessage) } catch { $null = $_ }
}
exit $script:ExitCode

<#
    Lite OS - image (v2) tests.

    Static and pure. These tests only READ files under image\, builder\, .github\ and the GUI
    script, and import builder\LiteOS.Image.psm1 / src\LiteOS.Engine.psm1 to call the PURE
    functions Select-LiteOSRemovals and ConvertTo-LiteOSOfflinePath on in-memory data.
    Nothing is mounted, downloaded, applied or written. The GUI XAML is parsed with
    XamlReader in an STA runspace but never shown.

    Compatible with Pester 3.4 (built into Windows) and Pester 5.x (CI):
      - only Describe / Context / It / BeforeAll / AfterAll (BeforeAll inside Describe),
      - no Should at all: assertions are plain "throw" with a readable message,
      - -TestCases / -Skip data is computed in the Describe body (Pester 5 discovery and 3.4 inline).

    Run:  Invoke-Pester -Path .\tests
#>

Describe 'Lite OS image files' {

    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $ImageDir = Join-Path $RepoRoot 'image'
        $GuiPath = Join-Path $RepoRoot 'LiteOS-Builder.ps1'

        $RemovalTypes = @('capability', 'feature', 'package', 'files', 'onedrive', 'edge', 'winre', 'script')
        $RemovalModes = @('lite', 'core')
        $Risks = @('none', 'low', 'medium', 'high')
        $InstallerModes = @('lite', 'core', 'both')

        # Names no removal may touch in ANY mode: Lite OS is a gaming OS in both modes, and the
        # layout pins Store + Xbox, the installers bake VC++ / DirectX / .NET into both modes.
        $AllModesForbidden = [ordered]@{
            'Microsoft Store / App Installer'      = '(?i)windowsstore|storepurchase|desktopappinstaller|\bclipsvc\b|\bwinget\b|\bappxsvc\b'
            'Xbox / Game Pass / Gaming Services'   = '(?i)xbox|gamingapp|gamingservices|\bxbl|gamebar|gameinput'
            'WebView2'                             = '(?i)webview'
            '.NET'                                 = '(?i)netfx|dotnet|\.net\b'
            'VC++ runtimes'                        = '(?i)vclibs|vcredist|vc_redist|vcruntime|msvcp\d'
            'DirectX'                              = '(?i)directx|direct3d|\bd3d|dxgi|directplay|xaudio|xinput'
            'audio'                                = '(?i)audio'
            'networking'                           = '(?i)tcpip|\bwlan|wifi|wi-fi|ethernet|\bdhcp|dnscache|\bndis\b|winsock|nlasvc'
            'Bluetooth'                            = '(?i)bluetooth|bthserv|\bbth'
            'kernel anti-cheat'                    = '(?i)\bvgk\b|\bvgc\b|vanguard|easyanticheat|battleye|\bbeservice\b|\bbedaisy\b|faceit|javelin'
        }
        # Additionally forbidden for Lite entries (the Lite promise: updatable, Defender on, Edge kept,
        # WinRE kept, printing works, VBS / HVCI / TPM state untouched for anti-cheat).
        $LiteForbidden = [ordered]@{
            'Windows Defender / Windows Security'  = '(?i)defender|sechealth|securityhealth|windefend|msmpeng|\bwdfilter\b|\bwdboot\b|wdnis|smartscreen'
            'Windows Update / servicing'           = '(?i)windowsupdate|wuauserv|\busosvc\b|waasmedic|updateorchestrator|servicingstack|trustedinstaller|winsxs|\bwuaueng|mousocore|\bbits\b'
            'Edge browser'                         = '(?i)msedge|microsoftedge|microsoft-edge|\\edge\\|edgeupdate'
            'WinRE'                                = '(?i)winre|windowsre|reagentc'
            'printing'                             = '(?i)spooler|printing-foundation|printtopdf|print-to-pdf'
            'VBS / HVCI / TPM'                     = '(?i)hypervisor|hyper-v|virtualmachineplatform|deviceguard|\bhvci\b|codeintegrity|\btpm\b'
        }
        # A script line is only "destructive" when it also runs one of these.
        $DestructiveRx = '(?i)\b(Remove-\w+|Disable-\w+|Uninstall-\w+|Stop-Service|Set-Service|Clear-\w+|Rename-Item|Move-Item|Set-ItemProperty|New-ItemProperty|rd|rmdir|del|erase|takeown(\.exe)?|icacls(\.exe)?)\b|\breg(\.exe)?\s+(add|delete)\b|\bsc(\.exe)?\s+(config|delete|stop)\b|\bdism(\.exe)?\b'

        # Start / taskbar pins required by the contract. AUMIDs verified read-only with
        # Get-StartApps / Get-AppxPackage on Windows 11 25H2 (build 26200).
        $AumidXbox = 'Microsoft.GamingApp_8wekyb3d8bbwe!Microsoft.Xbox.App'
        $AumidStore = 'Microsoft.WindowsStore_8wekyb3d8bbwe!App'
        $AumidSettings = 'windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel'
        $AumidTerminal = 'Microsoft.WindowsTerminal_8wekyb3d8bbwe!App'
        $AumidRx = '^[A-Za-z0-9][A-Za-z0-9.\-]*_[a-z0-9]{13}![A-Za-z0-9][A-Za-z0-9.\-]*$'
        $LinkRx = '^%(APPDATA|ALLUSERSPROFILE|PROGRAMDATA)%\\Microsoft\\Windows\\Start Menu\\Programs\\[^"<>|?*]+\.lnk$'

        # Hosts that serve the official installers (vendor-owned CDNs and Microsoft redirectors).
        $OfficialInstallerHosts = [ordered]@{
            'aka.ms'                              = 'Microsoft'
            'go.microsoft.com'                    = 'Microsoft'
            'download.microsoft.com'              = 'Microsoft'
            'download.visualstudio.microsoft.com' = 'Microsoft'
            'builds.dotnet.microsoft.com'         = 'Microsoft'
            'dotnetcli.azureedge.net'             = 'Microsoft'
            'cdn.fastly.steamstatic.com'          = 'Valve'
            'cdn.akamai.steamstatic.com'          = 'Valve'
            'cdn.cloudflare.steamstatic.com'      = 'Valve'
            'steamcdn-a.akamaihd.net'             = 'Valve'
        }

        function Test-P {
            param($Object, [string]$Name)
            if ($null -eq $Object) { return $false }
            if (-not ($Object -is [System.Management.Automation.PSCustomObject])) { return $false }
            return ($null -ne $Object.PSObject.Properties[$Name])
        }

        # NOTE: Get-P unrolls arrays like any function; wrap with @() and use Test-PArray for shape checks.
        function Get-P {
            param($Object, [string]$Name)
            if (-not (Test-P $Object $Name)) { return $null }
            return $Object.PSObject.Properties[$Name].Value
        }

        function Test-PArray {
            param($Object, [string]$Name, [switch]$NonEmpty)
            if (-not (Test-P $Object $Name)) { return $false }
            $v = $Object.PSObject.Properties[$Name].Value
            if (-not ($v -is [array])) { return $false }
            if ($NonEmpty -and $v.Count -eq 0) { return $false }
            return $true
        }

        function Test-NonEmptyString {
            param($Value)
            return (($Value -is [string]) -and ($Value.Trim().Length -gt 0))
        }

        function Test-Integer {
            param($Value)
            if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte]) { return $true }
            if ($Value -is [decimal] -or $Value -is [double]) { return ([math]::Truncate($Value) -eq $Value) }
            return $false
        }

        function Read-Json {
            param([string]$Path)
            if (-not (Test-Path -LiteralPath $Path)) { throw ('{0}: file is missing' -f $Path) }
            try {
                return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
            } catch {
                $msg = (($_.Exception.Message -split "`r?`n")[0])
                if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }
                throw ('{0}: invalid JSON - {1}' -f (Split-Path -Leaf $Path), $msg)
            }
        }

        function Read-Xml {
            param([string]$Path)
            if (-not (Test-Path -LiteralPath $Path)) { throw ('{0}: file is missing' -f $Path) }
            $doc = New-Object System.Xml.XmlDocument
            $doc.XmlResolver = $null
            try { $doc.Load($Path) } catch { throw ('{0}: not well-formed XML - {1}' -f (Split-Path -Leaf $Path), $_.Exception.Message) }
            return $doc
        }

        function Assert-NoProblems {
            param([object[]]$Problems, [string]$Title)
            $list = @($Problems | Where-Object { $_ })
            if ($list.Count -gt 0) {
                throw ("{0} ({1}):`n  - {2}" -f $Title, $list.Count, ($list -join "`n  - "))
            }
        }

        function Get-ScriptCodeLines {
            # the script's code without comments, as lines (string contents are kept)
            param([string]$Code)
            $tokens = $null
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$tokens, [ref]$errors)
            $text = $Code
            $comments = @($tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)
            foreach ($c in $comments) {
                $text = $text.Remove($c.Extent.StartOffset, $c.Extent.EndOffset - $c.Extent.StartOffset)
            }
            return @($text -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
        }

        function Get-RemovalLabel {
            param($Entry, [int]$Index)
            $id = Get-P $Entry 'id'
            if (-not $id) { $id = '<no id>' }
            return ('removals[{0}] {1}' -f $Index, $id)
        }

        function Get-RemovalTouchProblems {
            # does the entry's data (match / paths) or a destructive script line name a protected component
            param($Entry, [string]$Where, $Patterns)
            $problems = @()
            $data = @()
            foreach ($f in @('match', 'paths', 'appx')) { foreach ($v in @(Get-P $Entry $f)) { if ($v -is [string]) { $data += $v } } }
            $scriptLines = @()
            $code = Get-P $Entry 'script'
            if (Test-NonEmptyString $code) { $scriptLines = @(Get-ScriptCodeLines $code | Where-Object { $_ -match $DestructiveRx }) }
            foreach ($label in @($Patterns.Keys)) {
                $rx = $Patterns[$label]
                foreach ($d in $data) { if ($d -match $rx) { $problems += ("{0}: '{1}' touches {2}" -f $Where, $d, $label) } }
                foreach ($l in $scriptLines) { if ($l -match $rx) { $problems += ("{0}: script line '{1}' touches {2}" -f $Where, $l.Trim(), $label) } }
            }
            return $problems
        }

        function Get-PinKey {
            # one comparable key per Start pin: 'pkg:<aumid>', 'id:<desktopAppId>' or 'lnk:<path>'
            param($Pin)
            if (Test-P $Pin 'packagedAppId') { return ('pkg:' + [string](Get-P $Pin 'packagedAppId')) }
            if (Test-P $Pin 'desktopAppId') { return ('id:' + [string](Get-P $Pin 'desktopAppId')) }
            if (Test-P $Pin 'desktopAppLink') { return ('lnk:' + [string](Get-P $Pin 'desktopAppLink')) }
            return ''
        }

        function Get-InlineXaml {
            # every string literal in the script that is WPF XAML (Window / UserControl / ResourceDictionary)
            param([string]$Path)
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
            $found = @()
            if ($null -eq $ast) { return $found }
            $nodes = $ast.FindAll({ param($n)
                    ($n -is [System.Management.Automation.Language.StringConstantExpressionAst]) -or
                    ($n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) }, $true)
            foreach ($n in $nodes) {
                $v = [string]$n.Value
                if ($v -notmatch 'http://schemas\.microsoft\.com/winfx/2006/xaml/presentation') { continue }
                if ($n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                    # a double-quoted here-string: neutralise $(...), ${...} and $var so the markup can still be checked
                    $v = $v -replace '\$\([^)]*\)', 'X' -replace '\$\{[^}]*\}', 'X' -replace '\$[A-Za-z_][A-Za-z0-9_:]*', 'X'
                }
                $found += , (New-Object PSObject -Property @{ Line = $n.Extent.StartLineNumber; Xaml = $v })
            }
            return $found
        }

        function Get-WorkflowUploadBlocks {
            # text of every upload-artifact / gh-release step in a workflow (crude but dependency-free YAML scan)
            param([string]$Path)
            $lines = @(Get-Content -LiteralPath $Path)
            $blocks = @()
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -notmatch 'uses:\s*(actions/upload-artifact|softprops/action-gh-release|actions/cache)') { continue }
                $start = $i
                while ($start -gt 0 -and $lines[$start] -notmatch '^\s*-\s') { $start-- }
                $indent = ([regex]::Match($lines[$start], '^\s*')).Length
                $end = $i + 1
                while ($end -lt $lines.Count) {
                    $l = $lines[$end]
                    if ($l.Trim().Length -gt 0) {
                        $li = ([regex]::Match($l, '^\s*')).Length
                        if ($li -lt $indent -or ($li -eq $indent -and $l -match '^\s*-\s')) { break }
                    }
                    $end++
                }
                $blocks += , (New-Object PSObject -Property @{ Line = $start + 1; Text = (($lines[$start..($end - 1)]) -join "`n") })
            }
            return $blocks
        }
    }

    # ---- discovery-time data (Pester 5 runs this during discovery, Pester 3.4 inline) ----
    $wpfAvailable = $false
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        $wpfAvailable = $true
    } catch { $wpfAvailable = $false }

    Context 'Contract files' {

        It 'every v2 file named in the architecture contract exists' {
            $expected = @('LiteOS-Builder.cmd', 'LiteOS-Builder.ps1', 'builder\Build-LiteOS.ps1', 'builder\Get-WindowsIso.ps1',
                'builder\LiteOS.Image.psm1', 'builder\New-IsoFile.ps1', 'builder\autounattend.xml', 'image\removals.json',
                'image\branding.json', 'image\installers.json', 'image\layout\LayoutModification.json',
                'image\layout\TaskbarLayoutModification.xml', '.github\workflows\build-test.yml')
            $missing = @($expected | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepoRoot $_)) })
            if ($missing.Count -gt 0) { throw ('Missing contract files: ' + ($missing -join ', ')) }
        }

        It 'builder\LiteOS.Image.psm1 has no import-time side effects' {
            $path = Join-Path $RepoRoot 'builder\LiteOS.Image.psm1'
            if (-not (Test-Path -LiteralPath $path)) { throw 'builder\LiteOS.Image.psm1 is missing' }
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            if (@($errors).Count -gt 0) { throw 'LiteOS.Image.psm1 does not parse' }
            $sideEffects = @('New-Item', 'Set-Item', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-Item', 'Remove-ItemProperty',
                'Copy-Item', 'Move-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Start-Transcript', 'Start-Process',
                'reg', 'reg.exe', 'dism', 'dism.exe', 'takeown', 'takeown.exe', 'icacls', 'icacls.exe', 'bcdedit', 'bcdedit.exe',
                'Mount-WindowsImage', 'Dismount-WindowsImage', 'Mount-DiskImage', 'Dismount-DiskImage', 'Remove-WindowsCapability',
                'Disable-WindowsOptionalFeature', 'Remove-WindowsPackage', 'Remove-AppxProvisionedPackage', 'Repair-WindowsImage',
                'Invoke-LiteOSImageRemovals', 'Invoke-LiteOSImageCleanup', 'Invoke-LiteOSOfflinePlan', 'Initialize-LiteOS', 'Write-LiteOSLog')
            $problems = @()
            if ($null -ne $ast.EndBlock) {
                foreach ($stmt in @($ast.EndBlock.Statements)) {
                    if ($stmt -is [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }
                    foreach ($c in @($stmt.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
                        $parent = $c.Parent
                        $nested = $false
                        while ($null -ne $parent -and $parent -ne $stmt) {
                            if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
                                $parent -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $nested = $true; break }
                            $parent = $parent.Parent
                        }
                        if ($nested) { continue }
                        $name = $c.GetCommandName()
                        if ($name -and ($sideEffects -contains $name)) { $problems += ('line {0}: {1} runs at import time' -f $c.Extent.StartLineNumber, $name) }
                    }
                }
            }
            Assert-NoProblems $problems 'LiteOS.Image.psm1 has import-time side effects'
        }

        It 'no script wipes, partitions or formats disks (dual-boot safe)' {
            $bad = @('Clear-Disk', 'Initialize-Disk', 'New-Partition', 'Remove-Partition', 'Resize-Partition', 'Set-Partition',
                'Format-Volume', 'Set-Disk', 'diskpart', 'diskpart.exe', 'format', 'format.com')
            $problems = @()
            # (Get-ChildItem -Include is ignored with -LiteralPath in Windows PowerShell 5.1: filter by extension)
            $files = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { @('.ps1', '.psm1') -contains $_.Extension.ToLowerInvariant() -and $_.FullName -notmatch '[\\/]\.git([\\/]|$)' })
            foreach ($f in $files) {
                $tokens = $null
                $errors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
                if ($null -eq $ast) { continue }
                foreach ($c in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
                    $name = $c.GetCommandName()
                    if ($name -and ($bad -contains $name)) {
                        $problems += ('{0} line {1}: {2}' -f $f.FullName.Substring($RepoRoot.Length).TrimStart('\'), $c.Extent.StartLineNumber, $name)
                    }
                }
            }
            foreach ($f in @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
                        Where-Object { @('.cmd', '.bat') -contains $_.Extension.ToLowerInvariant() -and $_.FullName -notmatch '[\\/]\.git([\\/]|$)' })) {
                $n = 0
                foreach ($line in @(Get-Content -LiteralPath $f.FullName)) {
                    $n++
                    if ($line -match '^\s*(@?rem(\s|$)|::)') { continue }
                    if ($line -match '(?i)\bdiskpart\b|\bformat(\.com)?\s+[a-z]:|\bclean\s+all\b') { $problems += ('{0} line {1}: disk wiping command' -f $f.Name, $n) }
                }
            }
            Assert-NoProblems $problems 'Lite OS never touches disks or partitions'
        }
    }

    Context 'image\removals.json' {

        It 'has a non-empty removals array whose entries have valid fields' {
            $doc = Read-Json (Join-Path $ImageDir 'removals.json')
            $problems = @()
            if (-not (Test-PArray $doc 'removals' -NonEmpty)) { throw "'removals' must be a non-empty array" }
            $i = 0
            foreach ($e in @(Get-P $doc 'removals')) {
                $w = Get-RemovalLabel $e $i
                $i++
                if (-not ($e -is [System.Management.Automation.PSCustomObject])) { $problems += "${w}: entry is not an object"; continue }
                foreach ($req in @('id', 'name', 'description', 'mode', 'default', 'risk', 'type')) {
                    if (-not (Test-P $e $req)) { $problems += "${w}: missing required field '$req'" }
                }
                $id = Get-P $e 'id'
                if (-not (Test-NonEmptyString $id) -or $id -cnotmatch '^image\.[a-z0-9]+(-[a-z0-9]+)*$') { $problems += "${w}: id must be 'image.<kebab-name>'" }
                if (-not (Test-NonEmptyString (Get-P $e 'name'))) { $problems += "${w}: 'name' must be a non-empty string" }
                if (-not (Test-NonEmptyString (Get-P $e 'description'))) { $problems += "${w}: 'description' must be a non-empty string" }
                if ($RemovalModes -cnotcontains (Get-P $e 'mode')) { $problems += "${w}: 'mode' must be lite or core" }
                if (-not ((Get-P $e 'default') -is [bool])) { $problems += "${w}: 'default' must be true/false" }
                if ($Risks -cnotcontains (Get-P $e 'risk')) { $problems += "${w}: 'risk' must be one of $($Risks -join ', ')" }
                $type = Get-P $e 'type'
                if ($RemovalTypes -cnotcontains $type) { $problems += "${w}: unknown type '$type' (allowed: $($RemovalTypes -join ', '))"; continue }

                foreach ($f in @('match', 'paths', 'appx', 'conflicts')) {
                    if (-not (Test-P $e $f)) { continue }
                    if (-not (Test-PArray $e $f -NonEmpty)) { $problems += "${w}: '$f' must be a non-empty array of strings"; continue }
                    foreach ($v in @(Get-P $e $f)) { if (-not (Test-NonEmptyString $v)) { $problems += "${w}: '$f' must contain only non-empty strings"; break } }
                }
                if ((Test-P $e 'appx') -and (Get-P $e 'mode') -ne 'core') { $problems += "${w}: 'appx' overrides the protected app list and is Core-only" }
                foreach ($c in @(Get-P $e 'conflicts')) {
                    if ($c -is [string] -and ($c -cnotmatch '^[a-z0-9*?]+(\.[a-z0-9*?]+(-[a-z0-9*?]+)*)+$' -or $c.StartsWith('image.'))) { $problems += "${w}: conflicts entry '$c' must be a tweak id" }
                }
                if ((Test-P $e 'script') -and -not (Test-NonEmptyString (Get-P $e 'script'))) { $problems += "${w}: 'script' must be a non-empty string" }

                switch ($type) {
                    { @('capability', 'feature', 'package') -contains $_ } {
                        if (-not (Test-PArray $e 'match' -NonEmpty)) { $problems += "${w}: type '$type' needs a non-empty 'match' array" }
                        foreach ($m in @(Get-P $e 'match')) {
                            if (-not ($m -is [string])) { continue }
                            if ($m -notmatch '^[A-Za-z0-9.~*?_+-]+$') { $problems += "${w}: match '$m' has characters DISM names never use" }
                            if (($m -replace '[*?]', '').Length -lt 4) { $problems += "${w}: match '$m' is too broad" }
                        }
                    }
                    'files' {
                        if (-not (Test-PArray $e 'paths' -NonEmpty)) { $problems += "${w}: type 'files' needs a non-empty 'paths' array" }
                    }
                    'script' {
                        if (-not (Test-NonEmptyString (Get-P $e 'script'))) { $problems += "${w}: type 'script' needs a non-empty 'script'" }
                    }
                }

                foreach ($p in @(Get-P $e 'paths')) {
                    if (-not ($p -is [string])) { continue }
                    if ($p -match '^[A-Za-z]:|^[\\/]|^%|\$|^~') { $problems += "${w}: path '$p' must be relative to the mounted image" }
                    if ($p -match '(^|[\\/])\.\.([\\/]|$)') { $problems += "${w}: path '$p' must not contain '..'" }
                    if ($p -match '^Windows[\\/]+(System32|SysWOW64)([\\/]|$)') {
                        $documented = ([string](Get-P $e 'description') -match '(?i)System32|SysWOW64') -or ((Get-P $e 'allowSystem32') -eq $true)
                        if (-not $documented) { $problems += "${w}: path '$p' is under Windows\System32 - only explicit, documented entries may touch it" }
                    }
                    if ($p -match '^(Windows|Program Files( \(x86\))?|Users|ProgramData|Windows[\\/]+(System32|SysWOW64|WinSxS))[\\/]*\*?$') { $problems += "${w}: path '$p' is a whole system folder" }
                }

                $code = Get-P $e 'script'
                if (Test-NonEmptyString $code) {
                    $errs = $null
                    $null = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$errs)
                    if (@($errs).Count -gt 0) { $problems += "${w}: 'script' does not parse: $(@($errs)[0].Message)" }
                    if ($code -match '(?i)HKCU:\\|HKEY_CURRENT_USER|HKLM:\\(SOFTWARE|SYSTEM)\\') { $problems += "${w}: script must use the offline hives in `$Hives, not the live HKLM/HKCU" }
                }
            }
            Assert-NoProblems $problems 'removals.json schema problems'
        }

        It 'removal ids are unique and never collide with tweak ids' {
            $doc = Read-Json (Join-Path $ImageDir 'removals.json')
            $seen = @{}
            $problems = @()
            foreach ($e in @(Get-P $doc 'removals')) {
                $id = [string](Get-P $e 'id')
                if (-not $id) { continue }
                $k = $id.ToLowerInvariant()
                if ($seen.ContainsKey($k)) { $problems += "duplicate id '$id'" } else { $seen[$k] = $true }
            }
            foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tweaks') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
                $cat = Get-P (Read-Json $f.FullName) 'category'
                if ($cat -eq 'image') { $problems += "$($f.Name): category 'image' is reserved for image\removals.json" }
            }
            Assert-NoProblems $problems 'Removal id problems'
        }

        It 'Lite entries never touch Defender, Windows Update, Edge, WinRE, printing or VBS / HVCI / TPM' {
            $doc = Read-Json (Join-Path $ImageDir 'removals.json')
            $problems = @()
            $i = 0
            foreach ($e in @(Get-P $doc 'removals')) {
                $w = Get-RemovalLabel $e $i
                $i++
                if ((Get-P $e 'mode') -ne 'lite') { continue }
                $type = [string](Get-P $e 'type')
                if (@('edge', 'winre') -contains $type) { $problems += "${w}: type '$type' is Core-only (Lite keeps Edge and WinRE)" }
                $problems += @(Get-RemovalTouchProblems -Entry $e -Where $w -Patterns $LiteForbidden)
            }
            Assert-NoProblems $problems 'Lite removals break the Lite promise (move them to mode core)'
        }

        It 'no entry (Lite or Core) removes Store, Xbox / Gaming Services, WebView2, runtimes, audio, networking, Bluetooth or anti-cheat' {
            $doc = Read-Json (Join-Path $ImageDir 'removals.json')
            $problems = @()
            $i = 0
            foreach ($e in @(Get-P $doc 'removals')) {
                $w = Get-RemovalLabel $e $i
                $i++
                $problems += @(Get-RemovalTouchProblems -Entry $e -Where $w -Patterns $AllModesForbidden)
            }
            Assert-NoProblems $problems 'Removals break gaming essentials'
        }

        It 'Core entries have risk medium or high and are explained' {
            $doc = Read-Json (Join-Path $ImageDir 'removals.json')
            $problems = @()
            $i = 0
            foreach ($e in @(Get-P $doc 'removals')) {
                $w = Get-RemovalLabel $e $i
                $i++
                if ((Get-P $e 'mode') -ne 'core') { continue }
                if (@('medium', 'high') -notcontains (Get-P $e 'risk')) { $problems += "${w}: Core entries need risk medium or high (got '$(Get-P $e 'risk')')" }
                $d = [string](Get-P $e 'description')
                if ($d.Trim().Length -lt 30) { $problems += "${w}: Core entries must explain the downside in 'description'" }
            }
            Assert-NoProblems $problems 'Core removal problems'
        }

        It 'Lite mode removes something and Core adds to it' {
            $doc = Read-Json (Join-Path $ImageDir 'removals.json')
            $all = @(Get-P $doc 'removals')
            $lite = @($all | Where-Object { (Get-P $_ 'mode') -eq 'lite' -and (Get-P $_ 'default') -eq $true })
            $core = @($all | Where-Object { (Get-P $_ 'mode') -eq 'core' -and (Get-P $_ 'default') -eq $true })
            if ($lite.Count -eq 0) { throw 'removals.json has no default Lite entries' }
            if ($core.Count -eq 0) { throw 'removals.json has no default Core entries' }
        }

        It 'never removes Recall from the image (offline removal breaks the 24H2 File Explorer)' {
            $doc = Read-Json (Join-Path $ImageDir 'removals.json')
            $problems = @()
            $i = 0
            foreach ($e in @(Get-P $doc 'removals')) {
                $w = Get-RemovalLabel $e $i
                $i++
                foreach ($v in @(@(Get-P $e 'match') + @(Get-P $e 'appx') + @(Get-P $e 'paths'))) {
                    if ($v -is [string] -and $v -match '(?i)recall|windowsai|\baix\b') { $problems += "${w}: '$v' removes Recall / Windows AI components - use the ui.recall-off policy tweak instead" }
                }
            }
            Assert-NoProblems $problems 'Recall must not be removed offline'
        }

        It 'conflicts name tweak ids that exist in the catalog' {
            $doc = Read-Json (Join-Path $ImageDir 'removals.json')
            $ids = @()
            foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tweaks') -Filter '*.json' -File)) {
                foreach ($t in @(Get-P (Read-Json $f.FullName) 'tweaks')) { if (Test-P $t 'id') { $ids += [string](Get-P $t 'id') } }
            }
            $problems = @()
            foreach ($e in @(Get-P $doc 'removals')) {
                foreach ($c in @(Get-P $e 'conflicts')) {
                    if (-not ($c -is [string])) { continue }
                    $hit = @($ids | Where-Object { $_ -eq $c -or $_ -like $c })
                    if ($hit.Count -eq 0) { $problems += ("{0}: conflicts entry '{1}' matches no tweak id" -f (Get-P $e 'id'), $c) }
                }
            }
            Assert-NoProblems $problems 'removals.json conflicts problems'
        }

        It 'image.windows-update leaves out the update tweaks that write NoAutoUpdate=0' {
            $doc = Read-Json (Join-Path $ImageDir 'removals.json')
            $wu = @(@(Get-P $doc 'removals') | Where-Object { (Get-P $_ 'id') -eq 'image.windows-update' })
            if ($wu.Count -ne 1) { throw 'image.windows-update is missing' }
            $conf = @(Get-P $wu[0] 'conflicts')
            $problems = @()
            foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tweaks') -Filter '*.json' -File)) {
                foreach ($t in @(Get-P (Read-Json $f.FullName) 'tweaks')) {
                    foreach ($a in @(Get-P $t 'actions')) {
                        if ((Get-P $a 'type') -eq 'registry' -and [string](Get-P $a 'path') -match '(?i)\\WindowsUpdate\\AU$' -and (Get-P $a 'name') -eq 'NoAutoUpdate' -and [int](Get-P $a 'value') -eq 0) {
                            $tid = [string](Get-P $t 'id')
                            if (@($conf | Where-Object { $tid -eq $_ -or $tid -like $_ }).Count -eq 0) { $problems += "$tid writes NoAutoUpdate=0 but is not in image.windows-update conflicts" }
                        }
                    }
                }
            }
            Assert-NoProblems $problems 'Core Windows Update block would be undone by a tweak'
        }

        It 'the image module keeps Winre.wim, OneDriveSetup.exe, Edge Update and WebView2 in the image' {
            $path = Join-Path $RepoRoot 'builder\LiteOS.Image.psm1'
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            $problems = @()
            $fns = @{}
            foreach ($fn in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) { $fns[$fn.Name] = $fn }
            foreach ($name in @('Invoke-ImageWinreType', 'Invoke-ImageOneDriveType')) {
                if (-not $fns.ContainsKey($name)) { $problems += "$name is missing"; continue }
                foreach ($c in @($fns[$name].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
                    $cn = $c.GetCommandName()
                    if ($cn -and $cn -match '^(Remove-ImageItem|Remove-Item|takeown(\.exe)?|icacls(\.exe)?)$') { $problems += ('{0} line {1}: {2} deletes image files (Winre.wim / OneDriveSetup.exe must stay)' -f $name, $c.Extent.StartLineNumber, $cn) }
                }
            }
            if ($fns.ContainsKey('Invoke-ImageEdgeType')) {
                foreach ($m in [regex]::Matches($fns['Invoke-ImageEdgeType'].Body.Extent.Text, 'foreach\s*\(\s*\$leaf\s+in\s+@\(([^)]*)\)')) {
                    if ($m.Groups[1].Value -match '(?i)edgeupdate|webview') { $problems += ("Invoke-ImageEdgeType deletes {0} (Edge Update / WebView2 must stay)" -f $m.Groups[1].Value.Trim()) }
                }
            }
            else { $problems += 'Invoke-ImageEdgeType is missing' }
            Assert-NoProblems $problems 'Image removals delete files that must stay'
        }

        It 'Core script removals never call DISM (they run while the offline hives are loaded)' {
            $path = Join-Path $RepoRoot 'builder\LiteOS.Image.psm1'
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            $problems = @()
            foreach ($fn in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -like 'Invoke-LiteOSCore*' }, $true))) {
                foreach ($c in @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
                    $cn = $c.GetCommandName()
                    if ($cn -and $cn -match '(?i)^(dism(\.exe)?|\w+-Appx\w*|\w+-Windows(Image|Package|Capability|OptionalFeature|Driver))$') { $problems += ('{0} line {1}: {2}' -f $fn.Name, $c.Extent.StartLineNumber, $cn) }
                }
            }
            Assert-NoProblems $problems 'DISM servicing inside Core scripts (use the removal "appx" field, which runs in the DISM stage)'
        }
    }

    Context 'image\branding.json' {

        It 'has every contract field as a non-empty string' {
            $b = Read-Json (Join-Path $ImageDir 'branding.json')
            $problems = @()
            foreach ($f in @('name', 'manufacturer', 'model', 'supportUrl', 'registeredOrganization', 'bootDescription', 'isoLabelPrefix')) {
                if (-not (Test-NonEmptyString (Get-P $b $f))) { $problems += "'$f' must be a non-empty string" }
            }
            Assert-NoProblems $problems 'branding.json problems'
        }

        It 'uses https, a valid ISO label prefix and only the <mode> / <build> placeholders' {
            $b = Read-Json (Join-Path $ImageDir 'branding.json')
            $problems = @()
            $url = [string](Get-P $b 'supportUrl')
            if ($url -notmatch '^https://[A-Za-z0-9.-]+(/[^\s"<>]*)?$') { $problems += "supportUrl must be an https URL (got '$url')" }
            $label = [string](Get-P $b 'isoLabelPrefix')
            if ($label -cnotmatch '^[A-Z0-9_]{1,16}$') { $problems += "isoLabelPrefix must be 1-16 characters A-Z 0-9 _ (ISO 9660 volume label; got '$label')" }
            foreach ($prop in @($b.PSObject.Properties)) {
                if (-not ($prop.Value -is [string])) { continue }
                foreach ($m in [regex]::Matches([string]$prop.Value, '<([^>]*)>')) {
                    if (@('mode', 'build') -notcontains $m.Groups[1].Value) { $problems += ("'{0}' uses unknown placeholder '{1}'" -f $prop.Name, $m.Value) }
                }
                if ([string]$prop.Value -match '["\r\n]') { $problems += ("'{0}' must be one line without quotes (written to the registry and bcdedit)" -f $prop.Name) }
            }
            Assert-NoProblems $problems 'branding.json problems'
        }

        It 'does not impersonate Microsoft or change product identity' {
            $b = Read-Json (Join-Path $ImageDir 'branding.json')
            $problems = @()
            foreach ($f in @('name', 'manufacturer', 'registeredOrganization', 'bootDescription')) {
                if ([string](Get-P $b $f) -match '(?i)microsoft|windows') { $problems += "'$f' must not claim to be Microsoft / Windows" }
            }
            foreach ($prop in @($b.PSObject.Properties)) {
                if ($prop.Name -match '(?i)^(productName|editionId|productId|productKey|currentBuild|displayVersion|compositionEdition)$') {
                    $problems += ("'{0}' must not be branded (changing ProductName / EditionID breaks updates and activation)" -f $prop.Name)
                }
            }
            Assert-NoProblems $problems 'branding.json problems'
        }
    }

    Context 'image\installers.json' {

        It 'has valid, unique installer entries' {
            $doc = Read-Json (Join-Path $ImageDir 'installers.json')
            if (-not (Test-PArray $doc 'installers' -NonEmpty)) { throw "'installers' must be a non-empty array" }
            $problems = @()
            $ids = @{}
            $files = @{}
            $i = 0
            foreach ($e in @(Get-P $doc 'installers')) {
                $w = "installers[$i]"
                $i++
                foreach ($req in @('id', 'name', 'url', 'file', 'args', 'publisher', 'mode', 'default')) {
                    if (-not (Test-P $e $req)) { $problems += "${w}: missing required field '$req'" }
                }
                $id = Get-P $e 'id'
                if (-not (Test-NonEmptyString $id) -or $id -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { $problems += "${w}: 'id' must be lower-case kebab (got '$id')"; continue }
                $w = "installers[$($i - 1)] $id"
                if ($ids.ContainsKey($id)) { $problems += "${w}: duplicate id" } else { $ids[$id] = $true }
                if (-not (Test-NonEmptyString (Get-P $e 'name'))) { $problems += "${w}: 'name' must be a non-empty string" }
                $file = Get-P $e 'file'
                if (-not (Test-NonEmptyString $file) -or $file -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.(exe|msi)$') { $problems += "${w}: 'file' must be a plain .exe/.msi file name (got '$file')" }
                elseif ($files.ContainsKey($file.ToLowerInvariant())) { $problems += "${w}: duplicate file name '$file'" }
                else { $files[$file.ToLowerInvariant()] = $true }
                $args0 = Get-P $e 'args'
                if (-not ($args0 -is [string])) { $problems += "${w}: 'args' must be a string ('' for none)" }
                elseif ($args0 -match '[&|<>^;%`"]') { $problems += "${w}: 'args' must not contain shell metacharacters, quotes or %variables% (got '$args0')" }
                if (-not (Test-NonEmptyString (Get-P $e 'publisher'))) { $problems += "${w}: 'publisher' must be a non-empty string (Authenticode signer check)" }
                if ($InstallerModes -cnotcontains (Get-P $e 'mode')) { $problems += "${w}: 'mode' must be lite, core or both" }
                if (-not ((Get-P $e 'default') -is [bool])) { $problems += "${w}: 'default' must be true/false" }
                if ((Test-P $e 'description') -and -not (Test-NonEmptyString (Get-P $e 'description'))) { $problems += "${w}: optional 'description' must be a non-empty string" }
                if (Test-P $e 'successCodes') {
                    if (-not (Test-PArray $e 'successCodes' -NonEmpty)) { $problems += "${w}: 'successCodes' must be a non-empty array of integers" }
                    else { foreach ($c in @(Get-P $e 'successCodes')) { if (-not (Test-Integer $c)) { $problems += "${w}: 'successCodes' must contain only integers"; break } } }
                }
                if (Test-P $e 'timeoutMinutes') {
                    $tm = Get-P $e 'timeoutMinutes'
                    if (-not (Test-Integer $tm) -or $tm -lt 1 -or $tm -gt 120) { $problems += "${w}: 'timeoutMinutes' must be an integer from 1 to 120" }
                }
                # placeholders the SetupComplete runner (Get-LiteOSInstallerJobs) expands
                $usesDir = ($args0 -is [string]) -and ($args0 -match '\{(extractDir|temp)\}')
                foreach ($m in [regex]::Matches([string]$args0, '\{[^}]*\}')) { if (@('{extractDir}', '{temp}', '{dir}') -notcontains $m.Value) { $problems += "${w}: unknown placeholder '$($m.Value)' in args" } }
                if (Test-P $e 'extract') {
                    $x = Get-P $e 'extract'
                    if (-not ($x -is [System.Management.Automation.PSCustomObject])) { $problems += "${w}: 'extract' must be an object { run, args }" }
                    else {
                        $run = Get-P $x 'run'
                        if (-not (Test-NonEmptyString $run) -or $run -notmatch '^[A-Za-z0-9][A-Za-z0-9._\\-]*\.(exe|msi)$' -or $run -match '\.\.') { $problems += "${w}: extract.run must be a relative .exe/.msi inside the extracted folder (got '$run')" }
                        $xa = Get-P $x 'args'
                        if ((Test-P $x 'args') -and (-not ($xa -is [string]) -or $xa -match '[&|<>^;%`"]')) { $problems += "${w}: extract.args must be a plain string" }
                        if (-not $usesDir) { $problems += "${w}: an installer with 'extract' must extract to '{extractDir}' in 'args'" }
                    }
                } elseif ($usesDir) { $problems += "${w}: '{extractDir}' in args needs an 'extract' object" }
            }
            Assert-NoProblems $problems 'installers.json problems'
        }

        It 'downloads only from official vendor https URLs and checks the matching publisher' {
            $doc = Read-Json (Join-Path $ImageDir 'installers.json')
            $problems = @()
            foreach ($e in @(Get-P $doc 'installers')) {
                $id = [string](Get-P $e 'id')
                $url = [string](Get-P $e 'url')
                $uri = $null
                if (-not [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') { $problems += "${id}: url must be an absolute https URL (got '$url')"; continue }
                if ($uri.UserInfo -or -not $uri.IsDefaultPort) { $problems += "${id}: url must not carry credentials or a custom port" }
                $hostName = $uri.Host.ToLowerInvariant()
                if (-not $OfficialInstallerHosts.Contains($hostName)) { $problems += "${id}: host '$hostName' is not an official vendor download host (add it to the test only after checking it)"; continue }
                $vendor = [string]$OfficialInstallerHosts[$hostName]
                if ([string](Get-P $e 'publisher') -notmatch [regex]::Escape($vendor)) { $problems += "${id}: publisher '$(Get-P $e 'publisher')' does not match the vendor of $hostName ($vendor)" }
            }
            Assert-NoProblems $problems 'installers.json URL problems'
        }

        It 'bakes in the contract defaults: Steam, VC++ x64 + x86, DirectX June 2010, .NET Desktop Runtime 8' {
            $doc = Read-Json (Join-Path $ImageDir 'installers.json')
            $all = @(Get-P $doc 'installers')
            $wanted = [ordered]@{
                'Steam'                      = 'SteamSetup\.exe'
                'VC++ 2015-2022 x64'         = 'vc_redist\.x64\.exe'
                'VC++ 2015-2022 x86'         = 'vc_redist\.x86\.exe'
                'DirectX June 2010'          = 'directx_Jun2010_redist\.exe'
                '.NET Desktop Runtime 8 x64' = 'windowsdesktop-runtime.*8.*x64|dotnet/8\.0/windowsdesktop-runtime-win-x64'
            }
            $problems = @()
            foreach ($k in @($wanted.Keys)) {
                $hit = @($all | Where-Object { ([string](Get-P $_ 'url') + ' ' + [string](Get-P $_ 'file')) -match $wanted[$k] })
                if ($hit.Count -eq 0) { $problems += "$k is missing"; continue }
                if (@($hit | Where-Object { (Get-P $_ 'default') -eq $true -and (Get-P $_ 'mode') -eq 'both' }).Count -eq 0) { $problems += "$k must be default:true in mode both" }
            }
            Assert-NoProblems $problems 'installers.json defaults'
        }
    }

    Context 'Start and taskbar layout' {

        It 'LayoutModification.json uses the documented OEM Start layout format of the Default profile' {
            # Microsoft Learn "Customize the Windows 11 Start menu": in Users\Default\...\Shell Windows reads
            # primaryOEMPins / secondaryOEMPins (4 each) and firstRunOEMPins (1). pinnedList / applyOnce are
            # the ConfigureStartPins POLICY format and are ignored there.
            $doc = Read-Json (Join-Path $ImageDir 'layout\LayoutModification.json')
            $problems = @()
            $limits = [ordered]@{ primaryOEMPins = 4; secondaryOEMPins = 4; firstRunOEMPins = 1 }
            foreach ($prop in @($doc.PSObject.Properties)) {
                if (@('pinnedList', 'applyOnce') -ccontains $prop.Name) { $problems += "'$($prop.Name)' is the ConfigureStartPins policy format; Windows ignores it in the Default profile (use primaryOEMPins / secondaryOEMPins)" }
                elseif (-not $limits.Contains($prop.Name)) { $problems += "unknown top-level member '$($prop.Name)'" }
            }
            $seen = @{}
            $total = 0
            foreach ($member in @($limits.Keys)) {
                if (-not (Test-P $doc $member)) { continue }
                if (-not (Test-PArray $doc $member)) { $problems += "'$member' must be an array"; continue }
                $pins = @(Get-P $doc $member)
                if ($pins.Count -gt $limits[$member]) { $problems += ("'{0}' has {1} items; Windows uses only the first {2}" -f $member, $pins.Count, $limits[$member]) }
                $i = 0
                foreach ($pin in $pins) {
                    $w = "$member[$i]"
                    $i++
                    $total++
                    if (-not ($pin -is [System.Management.Automation.PSCustomObject])) { $problems += "${w}: must be an object"; continue }
                    $keys = @($pin.PSObject.Properties | ForEach-Object { $_.Name })
                    $kinds = @($keys | Where-Object { @('packagedAppId', 'desktopAppId', 'desktopAppLink') -ccontains $_ })
                    $extra = @($keys | Where-Object { @('packagedAppId', 'desktopAppId', 'desktopAppLink') -cnotcontains $_ -and -not ($member -eq 'firstRunOEMPins' -and $_ -ceq 'caption') })
                    if ($kinds.Count -ne 1 -or $extra.Count -gt 0) { $problems += "${w}: needs exactly one of packagedAppId / desktopAppId / desktopAppLink (got: $($keys -join ', '))"; continue }
                    $v = [string](Get-P $pin $kinds[0])
                    switch ($kinds[0]) {
                        'packagedAppId' { if ($v -notmatch $AumidRx) { $problems += "${w}: '$v' is not a packaged app AUMID (Name_PublisherId!AppId)" } }
                        'desktopAppLink' { if ($v -notmatch $LinkRx) { $problems += "${w}: '$v' must be a Start Menu\Programs .lnk under %APPDATA% or %ALLUSERSPROFILE%" } }
                        'desktopAppId' { if (-not (Test-NonEmptyString $v)) { $problems += "${w}: empty desktopAppId" } }
                    }
                    $k = (Get-PinKey $pin).ToLowerInvariant()
                    if ($seen.ContainsKey($k)) { $problems += "${w}: duplicate pin '$v' (an item can only appear once in the Pinned section)" } else { $seen[$k] = $true }
                }
            }
            if ($total -eq 0) { $problems += 'no Start pins at all' }
            Assert-NoProblems $problems 'LayoutModification.json problems'
        }

        It 'Start pins Steam, Xbox, Terminal and Settings on page 1 and no app Windows already pins there' {
            $doc = Read-Json (Join-Path $ImageDir 'layout\LayoutModification.json')
            $keys = @(@(Get-P $doc 'primaryOEMPins') | ForEach-Object { (Get-PinKey $_).ToLowerInvariant() })
            $wanted = [ordered]@{
                'Steam'    = @('lnk:%allusersprofile%\microsoft\windows\start menu\programs\steam\steam.lnk', 'lnk:%programdata%\microsoft\windows\start menu\programs\steam\steam.lnk')
                'Xbox'     = @('pkg:' + $AumidXbox.ToLowerInvariant())
                'Terminal' = @('pkg:' + $AumidTerminal.ToLowerInvariant())
                'Settings' = @('pkg:' + $AumidSettings.ToLowerInvariant())
            }
            $missing = @()
            foreach ($name in @($wanted.Keys)) {
                $ok = $false
                foreach ($candidate in $wanted[$name]) { if ($keys -contains $candidate) { $ok = $true } }
                if (-not $ok) { $missing += $name }
            }
            if ($missing.Count -gt 0) { throw ('primaryOEMPins is missing: ' + ($missing -join ', ')) }
            # Statically pinned by Microsoft on page 1: OEM pins of these are ignored (wasted slots).
            $static = @('pkg:' + $AumidStore.ToLowerInvariant(), 'id:msedge', 'lnk:%allusersprofile%\microsoft\windows\start menu\programs\microsoft edge.lnk',
                'id:microsoft.windows.explorer', 'lnk:%appdata%\microsoft\windows\start menu\programs\file explorer.lnk')
            $wasted = @($keys | Where-Object { $static -contains $_ })
            if ($wasted.Count -gt 0) { throw ('primaryOEMPins wastes slots on apps Windows pins on page 1 itself: ' + ($wasted -join ', ')) }
        }

        It 'TaskbarLayoutModification.xml follows the documented Windows 11 taskbar layout schema' {
            $doc = Read-Xml (Join-Path $ImageDir 'layout\TaskbarLayoutModification.xml')
            $nsLayout = 'http://schemas.microsoft.com/Start/2014/LayoutModification'
            $nsDefault = 'http://schemas.microsoft.com/Start/2014/FullDefaultLayout'
            $nsTaskbar = 'http://schemas.microsoft.com/Start/2014/TaskbarLayout'
            $problems = @()
            $root = $doc.DocumentElement
            if ($root.LocalName -ne 'LayoutModificationTemplate' -or $root.NamespaceURI -ne $nsLayout) { $problems += 'root must be LayoutModificationTemplate in the LayoutModification namespace' }
            if ($root.GetAttribute('Version') -ne '1') { $problems += 'LayoutModificationTemplate needs Version="1"' }
            if ($doc.SelectNodes('//comment()').Count -gt 0) { $problems += 'no XML comments (the Start/taskbar layout parser does not support them)' }
            if ($doc.SelectNodes('//@*[local-name()="PinGeneration"]').Count -gt 0) { $problems += 'PinGeneration needs KB5060829+; without it pins silently fail on older 24H2 ISOs' }
            $coll = @($root.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.LocalName -eq 'CustomTaskbarLayoutCollection' -and $_.NamespaceURI -eq $nsLayout })
            if ($coll.Count -ne 1) { $problems += 'needs exactly one CustomTaskbarLayoutCollection' }
            else {
                if ($coll[0].GetAttribute('PinListPlacement') -ne 'Replace') { $problems += 'CustomTaskbarLayoutCollection must use PinListPlacement="Replace"' }
                $layouts = @($coll[0].ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
                foreach ($l in $layouts) { if ($l.LocalName -ne 'TaskbarLayout' -or $l.NamespaceURI -ne $nsDefault) { $problems += "unexpected element '$($l.Name)' in CustomTaskbarLayoutCollection" } }
                if (@($layouts | Where-Object { -not $_.HasAttribute('Region') }).Count -ne 1) { $problems += 'needs exactly one default (region-less) defaultlayout:TaskbarLayout' }
                foreach ($l in $layouts) {
                    $lists = @($l.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
                    if ($lists.Count -ne 1 -or $lists[0].LocalName -ne 'TaskbarPinList' -or $lists[0].NamespaceURI -ne $nsTaskbar) { $problems += 'each TaskbarLayout needs exactly one taskbar:TaskbarPinList'; continue }
                    foreach ($pin in @($lists[0].ChildNodes | Where-Object { $_.NodeType -eq 'Element' })) {
                        if ($pin.NamespaceURI -ne $nsTaskbar) { $problems += "pin '$($pin.Name)' is not in the taskbar namespace"; continue }
                        if ($pin.LocalName -eq 'UWA') {
                            if ($pin.GetAttribute('AppUserModelID') -notmatch $AumidRx) { $problems += "taskbar:UWA has an invalid AppUserModelID '$($pin.GetAttribute('AppUserModelID'))'" }
                        } elseif ($pin.LocalName -eq 'DesktopApp') {
                            $hasId = $pin.HasAttribute('DesktopApplicationID')
                            $hasLink = $pin.HasAttribute('DesktopApplicationLinkPath')
                            if ($hasId -eq $hasLink) { $problems += 'taskbar:DesktopApp needs exactly one of DesktopApplicationID / DesktopApplicationLinkPath' }
                            if ($hasLink -and $pin.GetAttribute('DesktopApplicationLinkPath') -notmatch $LinkRx) { $problems += "DesktopApplicationLinkPath '$($pin.GetAttribute('DesktopApplicationLinkPath'))' must be a Start Menu\Programs .lnk" }
                        } else { $problems += "unknown pin element '$($pin.Name)'" }
                    }
                }
            }
            Assert-NoProblems $problems 'TaskbarLayoutModification.xml problems'
        }

        It 'taskbar pins File Explorer, Edge, Steam, Xbox and Microsoft Store (same Steam link as Start)' {
            $doc = Read-Xml (Join-Path $ImageDir 'layout\TaskbarLayoutModification.xml')
            $keys = @()
            foreach ($n in @($doc.SelectNodes('//*[local-name()="TaskbarLayout" and not(@Region)]//*[local-name()="UWA" or local-name()="DesktopApp"]'))) {
                if ($n.HasAttribute('AppUserModelID')) { $keys += ('pkg:' + $n.GetAttribute('AppUserModelID')).ToLowerInvariant() }
                if ($n.HasAttribute('DesktopApplicationID')) { $keys += ('id:' + $n.GetAttribute('DesktopApplicationID')).ToLowerInvariant() }
                if ($n.HasAttribute('DesktopApplicationLinkPath')) { $keys += ('lnk:' + $n.GetAttribute('DesktopApplicationLinkPath')).ToLowerInvariant() }
            }
            $start = Read-Json (Join-Path $ImageDir 'layout\LayoutModification.json')
            $startPins = @(@(Get-P $start 'primaryOEMPins') + @(Get-P $start 'secondaryOEMPins') + @(Get-P $start 'firstRunOEMPins') | Where-Object { $null -ne $_ })
            $startSteam = @($startPins | ForEach-Object { (Get-PinKey $_).ToLowerInvariant() } | Where-Object { $_ -like 'lnk:*\steam.lnk' })
            $wanted = [ordered]@{
                'File Explorer'   = @('id:microsoft.windows.explorer', 'lnk:%appdata%\microsoft\windows\start menu\programs\file explorer.lnk')
                'Microsoft Edge'  = @('id:msedge', 'lnk:%allusersprofile%\microsoft\windows\start menu\programs\microsoft edge.lnk')
                'Steam'           = $startSteam
                'Xbox'            = @('pkg:' + $AumidXbox.ToLowerInvariant())
                'Microsoft Store' = @('pkg:' + $AumidStore.ToLowerInvariant())
            }
            $missing = @()
            foreach ($name in @($wanted.Keys)) {
                $ok = $false
                foreach ($candidate in @($wanted[$name])) { if ($candidate -and ($keys -contains $candidate)) { $ok = $true } }
                if (-not $ok) { $missing += $name }
            }
            if ($missing.Count -gt 0) { throw ('Taskbar layout is missing pins: ' + ($missing -join ', ')) }
        }
    }

    Context 'autounattend.xml stays safe in v2' {

        It 'never selects disks, wipes partitions, adds accounts or contains a product key' {
            $doc = Read-Xml (Join-Path $RepoRoot 'builder\autounattend.xml')
            $problems = @()
            foreach ($el in @('DiskConfiguration', 'Disk', 'CreatePartitions', 'ModifyPartitions', 'WillWipeDisk', 'ImageInstall', 'InstallTo',
                    'InstallToAvailablePartition', 'LocalAccounts', 'AutoLogon', 'AdministratorPassword', 'Password')) {
                if ($doc.SelectNodes("//*[local-name()='$el']").Count -gt 0) { $problems += "contains <$el>" }
            }
            foreach ($k in @($doc.SelectNodes("//*[local-name()='ProductKey']//*[local-name()='Key']"))) {
                if (-not [string]::IsNullOrWhiteSpace($k.InnerText)) { $problems += 'ProductKey/Key is not empty' }
            }
            Assert-NoProblems $problems 'autounattend.xml is not safe'
        }

        It 'is shared by both modes, so it never disables Defender, Windows Update or removes components' {
            $text = (Get-Content -LiteralPath (Join-Path $RepoRoot 'builder\autounattend.xml') -Raw) -replace '(?s)<!--.*?-->', ''
            $problems = @()
            foreach ($rx in @('(?i)DisableAntiSpyware|DisableRealtimeMonitoring|Set-MpPreference|WinDefend', '(?i)wuauserv|UsoSvc|WaaSMedic|NoAutoUpdate',
                    '(?i)Remove-Windows(Package|Capability)|Disable-WindowsOptionalFeature|Remove-AppxProvisionedPackage|/Remove-(Package|Capability)',
                    '(?i)bcdedit[^<]*(hypervisorlaunchtype|nointegritychecks|testsigning)')) {
                $m = [regex]::Match($text, $rx)
                if ($m.Success) { $problems += ("contains '{0}' - mode-specific changes belong in the image / SetupComplete, not the shared answer file" -f $m.Value) }
            }
            Assert-NoProblems $problems 'autounattend.xml problems'
        }

        It 'keeps the FirstLogon command and balanced bypass markers' {
            $raw = Get-Content -LiteralPath (Join-Path $RepoRoot 'builder\autounattend.xml') -Raw
            $text = $raw -replace '(?s)<!--.*?-->', ''
            if ($text -notmatch '(?i)<CommandLine>[^<]*C:\\LiteOS\\LiteOS\.ps1[^<]*-FirstLogon') { throw 'FirstLogonCommands must run C:\LiteOS\LiteOS.ps1 -FirstLogon' }
            $begin = @([regex]::Matches($raw, '<!--\s*LITEOS:BYPASS:BEGIN\s*-->')).Count
            $end = @([regex]::Matches($raw, '<!--\s*LITEOS:BYPASS:END\s*-->')).Count
            if ($begin -ne 1 -or $end -ne 1) { throw ("expected one LITEOS:BYPASS:BEGIN and one END marker, found {0} / {1}" -f $begin, $end) }
            if ($raw.IndexOf('LITEOS:BYPASS:END') -lt $raw.IndexOf('LITEOS:BYPASS:BEGIN')) { throw 'LITEOS:BYPASS:END comes before BEGIN' }
        }
    }

    Context 'Lite OS Builder launcher and GUI' {

        It 'LiteOS-Builder.cmd elevates and starts LiteOS-Builder.ps1 in STA with Windows PowerShell' {
            $path = Join-Path $RepoRoot 'LiteOS-Builder.cmd'
            if (-not (Test-Path -LiteralPath $path)) { throw 'LiteOS-Builder.cmd is missing' }
            $text = [System.IO.File]::ReadAllText($path)
            $problems = @()
            if ($text -notmatch '(?i)LiteOS-Builder\.ps1') { $problems += 'does not start LiteOS-Builder.ps1' }
            if ($text -notmatch '(?i)(^|\s)-STA(\s|$)') { $problems += 'must pass -STA (WPF needs a single-threaded apartment)' }
            if ($text -notmatch '(?i)-ExecutionPolicy\s+Bypass') { $problems += 'must pass -ExecutionPolicy Bypass' }
            if ($text -notmatch '(?i)RunAs|fltmc|net\s+session') { $problems += 'does not check for / request administrator rights' }
            if ($text -notmatch '(?i)WindowsPowerShell\\v1\.0\\powershell\.exe|powershell\.exe') { $problems += 'must use Windows PowerShell 5.1 (powershell.exe)' }
            Assert-NoProblems $problems 'LiteOS-Builder.cmd problems'
        }

        It 'LiteOS-Builder.ps1 contains inline WPF XAML titled Lite OS Builder' {
            if (-not (Test-Path -LiteralPath $GuiPath)) { throw 'LiteOS-Builder.ps1 is missing' }
            $x = @(Get-InlineXaml $GuiPath)
            if ($x.Count -eq 0) { throw 'no inline XAML here-string (with the WPF presentation namespace) found in LiteOS-Builder.ps1' }
            $text = [System.IO.File]::ReadAllText($GuiPath)
            if ($text -notmatch 'Lite OS Builder') { throw "the window title 'Lite OS Builder' is not in LiteOS-Builder.ps1" }
            foreach ($item in $x) {
                $xml = New-Object System.Xml.XmlDocument
                $xml.XmlResolver = $null
                try { $xml.LoadXml($item.Xaml) } catch { throw ('XAML at line {0} is not well-formed XML: {1}' -f $item.Line, $_.Exception.Message) }
                $events = @($xml.SelectNodes('//@*') | Where-Object { $_.LocalName -match '^(Click|Checked|Unchecked|Loaded|SelectionChanged|TextChanged|Closing|Closed)$' })
                if ($events.Count -gt 0) { throw ('XAML at line {0} wires event attributes ({1}); XamlReader cannot load them - attach handlers in code' -f $item.Line, (($events | ForEach-Object { $_.LocalName }) -join ', ')) }
                if ($xml.SelectNodes('//@*[local-name()="Class"]').Count -gt 0) { throw ('XAML at line {0} uses x:Class; XamlReader cannot load it' -f $item.Line) }
            }
        }

        It 'the GUI XAML loads with XamlReader (never shown)' -Skip:(-not $wpfAvailable) {
            if (-not (Test-Path -LiteralPath $GuiPath)) { throw 'LiteOS-Builder.ps1 is missing' }
            $x = @(Get-InlineXaml $GuiPath)
            if ($x.Count -eq 0) { throw 'no inline XAML found in LiteOS-Builder.ps1' }
            $rs = [runspacefactory]::CreateRunspace()
            $rs.ApartmentState = [System.Threading.ApartmentState]::STA
            $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
            $rs.Open()
            $problems = @()
            try {
                foreach ($item in $x) {
                    $ps = [powershell]::Create()
                    $ps.Runspace = $rs
                    $failure = $null
                    try {
                        [void]$ps.AddScript({
                                param([string]$Xaml)
                                Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
                                $obj = [Windows.Markup.XamlReader]::Parse($Xaml)
                                $obj.GetType().FullName
                            }).AddArgument($item.Xaml)
                        $out = @($ps.Invoke())
                        if ($ps.Streams.Error.Count -gt 0) { $failure = [string]($ps.Streams.Error | Select-Object -First 1) }
                        elseif ($out.Count -eq 0) { $failure = 'no object was created' }
                    } catch {
                        $ex = $_.Exception
                        while ($null -ne $ex.InnerException) { $ex = $ex.InnerException }
                        $failure = $ex.Message
                    } finally { $ps.Dispose() }
                    if ($failure) { $problems += ('XAML at line {0}: {1}' -f $item.Line, $failure) }
                }
            } finally { $rs.Close(); $rs.Dispose() }
            Assert-NoProblems $problems 'GUI XAML does not load'
        }
    }

    Context 'CI never publishes Windows images' {

        It 'no workflow uploads, caches or releases an ISO / WIM / ESD' {
            $problems = @()
            foreach ($wf in @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot '.github\workflows') -File -ErrorAction SilentlyContinue |
                        Where-Object { @('.yml', '.yaml') -contains $_.Extension.ToLowerInvariant() })) {
                foreach ($b in @(Get-WorkflowUploadBlocks $wf.FullName)) {
                    if ($b.Text -match '(?i)\.(iso|wim|esd|swm|vhdx?)\b') { $problems += ('{0} line {1}: an upload/cache step references a Windows image file' -f $wf.Name, $b.Line) }
                    $wild = @(($b.Text -split "`n") | Where-Object { $_ -match '^\s*(path|files|key):[^\r\n]*\*' -or ($_ -notmatch ':' -and $_ -match '\*') })
                    if ($wild.Count -gt 0) { $problems += ('{0} line {1}: wildcard upload paths could pick up an ISO; upload a folder that only holds reports' -f $wf.Name, $b.Line) }
                }
            }
            Assert-NoProblems $problems 'Workflows must never publish Windows images'
        }

        It 'build-test.yml runs the real builder for Lite and Core and uploads only reports' {
            $path = Join-Path $RepoRoot '.github\workflows\build-test.yml'
            if (-not (Test-Path -LiteralPath $path)) { throw '.github\workflows\build-test.yml is missing' }
            $text = [System.IO.File]::ReadAllText($path)
            $problems = @()
            if ($text -notmatch '(?m)^\s*workflow_dispatch:') { $problems += 'needs workflow_dispatch' }
            if ($text -notmatch '(?m)^\s*-\s*cron:') { $problems += 'needs a weekly schedule (cron)' }
            if ($text -notmatch '(?i)\bLite\b' -or $text -notmatch '(?i)\bCore\b' -or $text -notmatch '(?m)^\s*matrix:') { $problems += 'needs a matrix over Lite and Core' }
            if ($text -notmatch '(?m)^\s*timeout-minutes:\s*\d+') { $problems += 'needs timeout-minutes' }
            if ($text -notmatch 'Build-LiteOS\.ps1') { $problems += 'does not run builder\Build-LiteOS.ps1' }
            foreach ($p in @('-Download', '-Yes', '-ProgressProtocol', '-WorkDir', '-Mode')) { if ($text -notmatch [regex]::Escape($p) + '\b') { $problems += "Build-LiteOS.ps1 call lacks $p" } }
            if ($text -notmatch 'actions/upload-artifact') { $problems += 'does not upload the build report' }
            Assert-NoProblems $problems 'build-test.yml problems'
        }
    }
}

Describe 'Select-LiteOSRemovals' {

    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $ImageModulePath = Join-Path $RepoRoot 'builder\LiteOS.Image.psm1'
        $ImageModuleError = $null
        try {
            # Importing must have no side effects (architecture contract); the module may import the engine itself.
            Import-Module $ImageModulePath -Force -DisableNameChecking -ErrorAction Stop
        } catch { $ImageModuleError = $_.Exception.Message }

        function Assert-ImageModule {
            if ($ImageModuleError) { throw ('builder\LiteOS.Image.psm1 could not be imported: ' + $ImageModuleError) }
            foreach ($c in @('Get-LiteOSRemovals', 'Select-LiteOSRemovals')) {
                if (-not (Get-Command -Name $c -ErrorAction SilentlyContinue)) { throw "LiteOS.Image.psm1 does not export $c" }
            }
        }

        function New-FakeRemoval {
            param([string]$Id, [string]$Mode, [bool]$Default)
            return [pscustomobject][ordered]@{
                id          = $Id
                name        = $Id
                description = 'Fake removal used by the selection tests. Never applied.'
                mode        = $Mode
                default     = $Default
                risk        = 'medium'
                type        = 'capability'
                match       = @('LiteOS.Test.Fake~~~~0.0.1.0')
            }
        }

        $FakeRemovals = @(
            (New-FakeRemoval -Id 'image.lite-on' -Mode 'lite' -Default $true)
            (New-FakeRemoval -Id 'image.lite-off' -Mode 'lite' -Default $false)
            (New-FakeRemoval -Id 'image.core-on' -Mode 'core' -Default $true)
            (New-FakeRemoval -Id 'image.core-off' -Mode 'core' -Default $false)
        )

        function Get-SelectedIds {
            param($Result)
            $ids = @()
            foreach ($r in @($Result)) {
                if ($null -eq $r) { continue }
                if ($r -is [string]) { $ids += $r } else { $ids += [string]$r.id }
            }
            return @($ids | Sort-Object)
        }

        function Assert-IdSet {
            param($Actual, [string[]]$Expected, [string]$Case)
            $a = @(Get-SelectedIds $Actual)
            $e = @($Expected | Sort-Object)
            if (($a -join ',') -ne ($e -join ',')) {
                throw ("{0}: expected [{1}] but got [{2}]" -f $Case, ($e -join ', '), ($a -join ', '))
            }
        }
    }

    AfterAll {
        Remove-Module -Name 'LiteOS.Image' -Force -ErrorAction SilentlyContinue
    }

    It 'exports the image module API' {
        Assert-ImageModule
        foreach ($c in @('Invoke-LiteOSImageRemovals', 'Invoke-LiteOSImageCleanup')) {
            if (-not (Get-Command -Name $c -ErrorAction SilentlyContinue)) { throw "LiteOS.Image.psm1 does not export $c" }
        }
    }

    It 'Lite selects only lite default removals' {
        Assert-ImageModule
        Assert-IdSet (Select-LiteOSRemovals -Removals $FakeRemovals -Mode Lite) @('image.lite-on') 'Lite'
    }

    It 'Core selects Lite plus core default removals' {
        Assert-ImageModule
        Assert-IdSet (Select-LiteOSRemovals -Removals $FakeRemovals -Mode Core) @('image.lite-on', 'image.core-on') 'Core'
    }

    It 'Include adds default:false removals (exact and wildcard)' {
        Assert-ImageModule
        Assert-IdSet (Select-LiteOSRemovals -Removals $FakeRemovals -Mode Lite -Include @('image.lite-off')) @('image.lite-on', 'image.lite-off') 'Lite + Include'
        Assert-IdSet (Select-LiteOSRemovals -Removals $FakeRemovals -Mode Core -Include @('image.core-*')) @('image.lite-on', 'image.core-on', 'image.core-off') 'Core + Include wildcard'
    }

    It 'Exclude removes defaults and wins over Include' {
        Assert-ImageModule
        Assert-IdSet (Select-LiteOSRemovals -Removals $FakeRemovals -Mode Lite -Exclude @('image.lite-on')) @() 'Lite - Exclude'
        Assert-IdSet (Select-LiteOSRemovals -Removals $FakeRemovals -Mode Core -Exclude @('image.*')) @() 'Core - Exclude wildcard'
        Assert-IdSet (Select-LiteOSRemovals -Removals $FakeRemovals -Mode Core -Include @('image.core-off') -Exclude @('image.core-off', 'image.lite-on')) @('image.core-on') 'Exclude wins'
    }

    It 'ignores tweak ids in Include / Exclude (the builder passes one list to both)' {
        Assert-ImageModule
        Assert-IdSet (Select-LiteOSRemovals -Removals $FakeRemovals -Mode Lite -Include @('privacy.telemetry-off', 'ui.*') -Exclude @('gaming.*')) @('image.lite-on') 'Lite with tweak ids'
    }

    It 'is pure: the input objects are not changed' {
        Assert-ImageModule
        $before = $FakeRemovals | ConvertTo-Json -Depth 6 -Compress
        $null = Select-LiteOSRemovals -Removals $FakeRemovals -Mode Core -Include @('image.*') -Exclude @('image.lite-off')
        $after = $FakeRemovals | ConvertTo-Json -Depth 6 -Compress
        if ($before -ne $after) { throw 'Select-LiteOSRemovals modified its input' }
    }

    It 'loads the real removals.json and Core is a superset of Lite' {
        Assert-ImageModule
        $file = Join-Path $RepoRoot 'image\removals.json'
        $removals = $null
        try { $removals = @(Get-LiteOSRemovals) } catch { $removals = $null }
        if ($null -eq $removals -or $removals.Count -eq 0) { $removals = @(Get-LiteOSRemovals -Path $file) }
        $expected = @((Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).removals | ForEach-Object { [string]$_.id } | Sort-Object)
        $got = @($removals | ForEach-Object { [string]$_.id } | Sort-Object)
        if (($got -join ',') -ne ($expected -join ',')) { throw ('Get-LiteOSRemovals returned [{0}], removals.json has [{1}]' -f ($got -join ', '), ($expected -join ', ')) }
        $lite = @(Select-LiteOSRemovals -Removals $removals -Mode Lite)
        $core = @(Select-LiteOSRemovals -Removals $removals -Mode Core)
        if ($lite.Count -eq 0) { throw 'Lite selected nothing from removals.json' }
        $byId = @{}
        foreach ($r in $removals) { $byId[[string]$r.id] = $r }
        $bad = @($lite | Where-Object { [string]$byId[[string]$_.id].mode -ne 'lite' } | ForEach-Object { $_.id })
        if ($bad.Count -gt 0) { throw ('Lite selected Core removals: ' + ($bad -join ', ')) }
        $coreIds = @{}
        foreach ($r in $core) { $coreIds[[string]$r.id] = $true }
        $missing = @($lite | Where-Object { -not $coreIds.ContainsKey([string]$_.id) } | ForEach-Object { $_.id })
        if ($missing.Count -gt 0) { throw ('Core is missing Lite removals: ' + ($missing -join ', ')) }
        if ($core.Count -le $lite.Count) { throw 'Core selects nothing beyond Lite' }
    }
}

Describe 'ConvertTo-LiteOSOfflinePath' {

    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        Import-Module (Join-Path $RepoRoot 'src\LiteOS.Engine.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $Hives = @{ SOFTWARE = 'HKLM\LITE_SOFTWARE'; SYSTEM = 'HKLM\LITE_SYSTEM'; DEFAULT = 'HKLM\LITE_DEFAULT' }
        $Root = 'Registry::HKEY_LOCAL_MACHINE\'

        function Assert-Mapping {
            param([string]$Path, $Expected, [hashtable]$HiveMap = $Hives)
            if (-not (Get-Command -Name 'ConvertTo-LiteOSOfflinePath' -ErrorAction SilentlyContinue)) { throw 'the engine does not export ConvertTo-LiteOSOfflinePath' }
            $got = ConvertTo-LiteOSOfflinePath -Path $Path -Hives $HiveMap
            if ($null -eq $Expected) {
                if (-not [string]::IsNullOrEmpty([string]$got)) { throw ("'{0}' should not be mappable offline (deferred) but became '{1}'" -f $Path, $got) }
                return
            }
            $g = ([string]$got).TrimEnd('\')
            $e = ([string]$Expected).TrimEnd('\')
            if (-not [string]::Equals($g, $e, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw ("'{0}' -> expected '{1}' but got '{2}'" -f $Path, $Expected, $got)
            }
        }
    }

    AfterAll {
        Remove-Module -Name 'LiteOS.Engine' -Force -ErrorAction SilentlyContinue
    }

    It 'maps HKLM:\SOFTWARE to the offline SOFTWARE hive' {
        Assert-Mapping 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' ($Root + 'LITE_SOFTWARE\Policies\Microsoft\Windows\GameDVR')
        Assert-Mapping 'HKLM:\SOFTWARE\Classes\Directory\Background\shell' ($Root + 'LITE_SOFTWARE\Classes\Directory\Background\shell')
        Assert-Mapping 'hklm:\software\Microsoft\Windows\CurrentVersion' ($Root + 'LITE_SOFTWARE\Microsoft\Windows\CurrentVersion')
    }

    It 'maps HKLM:\SYSTEM\CurrentControlSet to ControlSet001 and other SYSTEM keys as-is' {
        Assert-Mapping 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' ($Root + 'LITE_SYSTEM\ControlSet001\Control\GraphicsDrivers')
        Assert-Mapping 'HKLM:\SYSTEM\CurrentControlSet\Services\DiagTrack' ($Root + 'LITE_SYSTEM\ControlSet001\Services\DiagTrack')
        Assert-Mapping 'HKLM:\SYSTEM\CurrentControlSet' ($Root + 'LITE_SYSTEM\ControlSet001')
        Assert-Mapping 'HKLM:\SYSTEM\ControlSet001\Services\SysMain' ($Root + 'LITE_SYSTEM\ControlSet001\Services\SysMain')
        Assert-Mapping 'HKLM:\SYSTEM\Setup\LabConfig' ($Root + 'LITE_SYSTEM\Setup\LabConfig')
    }

    It 'maps HKCU:\ to the Default user hive' {
        Assert-Mapping 'HKCU:\Software\Microsoft\GameBar' ($Root + 'LITE_DEFAULT\Software\Microsoft\GameBar')
        Assert-Mapping 'HKCU:\Control Panel\Mouse' ($Root + 'LITE_DEFAULT\Control Panel\Mouse')
        Assert-Mapping 'HKCU:\System\GameConfigStore' ($Root + 'LITE_DEFAULT\System\GameConfigStore')
    }

    It 'defers HKCU:\Software\Classes (UsrClass.dat) to first logon' {
        Assert-Mapping 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' $null
        Assert-Mapping 'HKCU:\SOFTWARE\CLASSES\Directory' $null
        Assert-Mapping 'HKCU:\Software\Classes' $null
    }

    It 'defers every other root' {
        Assert-Mapping 'HKLM:\HARDWARE\DESCRIPTION\System' $null
        Assert-Mapping 'HKLM:\SAM\SAM' $null
        Assert-Mapping 'HKLM:\SECURITY\Policy' $null
        Assert-Mapping 'HKLM:\SOFTWAREX\Foo' $null
        Assert-Mapping 'HKLM:\SYSTEMX\Foo' $null
        Assert-Mapping 'HKCR:\Directory\shell' $null
        Assert-Mapping 'HKU:\.DEFAULT\Software' $null
    }

    It 'uses the hive names it is given' {
        $custom = @{ SOFTWARE = 'HKLM\OFF_SW'; SYSTEM = 'HKLM\OFF_SYS'; DEFAULT = 'HKLM\OFF_DEF' }
        Assert-Mapping 'HKLM:\SOFTWARE\Microsoft\Windows' ($Root + 'OFF_SW\Microsoft\Windows') $custom
        Assert-Mapping 'HKLM:\SYSTEM\CurrentControlSet\Control' ($Root + 'OFF_SYS\ControlSet001\Control') $custom
        Assert-Mapping 'HKCU:\Software\Microsoft' ($Root + 'OFF_DEF\Software\Microsoft') $custom
    }
}

Describe 'Image removal stages and deferred actions' {

    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        # Both imports have no side effects (architecture contract). Only PURE functions are called
        # below (merge, schema, JSON round trip, string merge); the state-file test writes to TestDrive.
        Import-Module (Join-Path $RepoRoot 'builder\LiteOS.Image.psm1') -Force -DisableNameChecking -ErrorAction Stop
        Import-Module (Join-Path $RepoRoot 'src\LiteOS.Engine.psm1') -Force -DisableNameChecking -ErrorAction Stop
        $ImageModule = Get-Module -Name 'LiteOS.Image'
        $EngineModule = Get-Module -Name 'LiteOS.Engine'

        function New-FakeResult {
            param([string]$Id, [string]$Stage, [string]$Status, [int]$Changes = 0, [object[]]$Deferred = @())
            return [pscustomobject]@{ id = $Id; name = $Id; type = 'script'; mode = 'core'; stage = $Stage; status = $Status
                message = ('{0} {1}' -f $Stage, $Status); changes = $Changes; deferred = @($Deferred); whatIf = $false }
        }
    }

    AfterAll {
        Remove-Module -Name 'LiteOS.Image' -Force -ErrorAction SilentlyContinue
        Remove-Module -Name 'LiteOS.Engine' -Force -ErrorAction SilentlyContinue
    }

    It 'exports Merge-LiteOSRemovalResults and Invoke-LiteOSImageRemovals -Stage' {
        if (-not (Get-Command -Name 'Merge-LiteOSRemovalResults' -ErrorAction SilentlyContinue)) { throw 'LiteOS.Image.psm1 does not export Merge-LiteOSRemovalResults' }
        $p = (Get-Command -Name 'Invoke-LiteOSImageRemovals').Parameters
        if (-not $p.ContainsKey('Stage')) { throw 'Invoke-LiteOSImageRemovals has no -Stage parameter' }
        $set = @($p['Stage'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object { $_.ValidValues })
        if ((@($set | Sort-Object) -join ',') -ne 'All,Dism,Hives') { throw ('-Stage must accept All, Dism, Hives (got {0})' -f ($set -join ', ')) }
    }

    It 'Merge-LiteOSRemovalResults joins the Dism and Hives parts of each removal' {
        $act = [pscustomobject]@{ type = 'service'; name = 'X'; startup = 'Disabled'; stop = $false }
        $in = @(
            (New-FakeResult -Id 'image.a' -Stage 'Dism' -Status 'applied' -Changes 1),
            (New-FakeResult -Id 'image.b' -Stage 'Dism' -Status 'skipped'),
            (New-FakeResult -Id 'image.a' -Stage 'Hives' -Status 'failed' -Changes 2 -Deferred @($act)),
            (New-FakeResult -Id 'image.c' -Stage 'Hives' -Status 'deferred' -Deferred @($act))
        )
        $out = @(Merge-LiteOSRemovalResults -Results $in)
        if ($out.Count -ne 3) { throw ('expected 3 merged results, got {0}' -f $out.Count) }
        $ids = (@($out | ForEach-Object { $_.id }) -join ',')
        if ($ids -ne 'image.a,image.b,image.c') { throw ('order not kept: {0}' -f $ids) }
        if ($out[0].status -ne 'failed') { throw ('image.a: a failed part must fail the removal (got {0})' -f $out[0].status) }
        if ($out[0].changes -ne 3) { throw ('image.a: changes must add up to 3 (got {0})' -f $out[0].changes) }
        if (@($out[0].deferred).Count -ne 1) { throw 'image.a: the deferred action of the Hives part is lost' }
        if ($out[0].stage -ne 'Dism+Hives') { throw ('image.a: stage should be Dism+Hives (got {0})' -f $out[0].stage) }
        if ($out[1].status -ne 'skipped') { throw 'image.b should stay skipped' }
        if ($out[2].status -ne 'deferred') { throw 'image.c should stay deferred' }
        $before = ($in | ConvertTo-Json -Depth 6 -Compress)
        $null = Merge-LiteOSRemovalResults -Results $in
        if (($in | ConvertTo-Json -Depth 6 -Compress) -ne $before) { throw 'Merge-LiteOSRemovalResults modified its input' }
    }

    It 'removal objects keep appx / conflicts; appx is Core-only and conflicts must be tweak ids' {
        $r = & $ImageModule {
            $base = @{ name = 't'; description = 'Test entry; its downside is explained here.'; default = $false; type = 'script'; script = '$null' }
            $make = { param($extra) $h = @{}; foreach ($k in $base.Keys) { $h[$k] = $base[$k] }; foreach ($k in $extra.Keys) { $h[$k] = $extra[$k] }; [pscustomobject]$h }
            $e1 = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $core = ConvertTo-LiteOSRemovalObject -Raw (& $make @{ id = 'image.test-core'; mode = 'core'; risk = 'high'; appx = @('Microsoft.SecHealthUI'); conflicts = @('updates.notify-only') }) -Where 'core' -Errors $e1
            $e2 = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $null = ConvertTo-LiteOSRemovalObject -Raw (& $make @{ id = 'image.test-lite'; mode = 'lite'; risk = 'low'; appx = @('Microsoft.SecHealthUI') }) -Where 'lite' -Errors $e2
            $e3 = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $null = ConvertTo-LiteOSRemovalObject -Raw (& $make @{ id = 'image.test-bad'; mode = 'core'; risk = 'high'; conflicts = @('image.edge') }) -Where 'bad' -Errors $e3
            $e4 = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $null = ConvertTo-LiteOSRemovalObject -Raw (& $make @{ id = 'image.test-broad'; mode = 'core'; risk = 'high'; appx = @('Micro*') }) -Where 'broad' -Errors $e4
            [pscustomobject]@{ Core = $core; CoreErrors = $e1.Count; LiteErrors = $e2.Count; BadErrors = $e3.Count; BroadErrors = $e4.Count }
        }
        if ($r.CoreErrors -ne 0 -or $null -eq $r.Core) { throw 'a valid Core entry with appx / conflicts was refused' }
        if ((@($r.Core.appx) -join ',') -ne 'Microsoft.SecHealthUI') { throw 'appx was not kept on the normalized removal' }
        if ((@($r.Core.conflicts) -join ',') -ne 'updates.notify-only') { throw 'conflicts was not kept on the normalized removal' }
        if ($r.LiteErrors -eq 0) { throw 'a Lite entry with appx (protected-list override) was accepted' }
        if ($r.BadErrors -eq 0) { throw 'a conflicts entry naming a removal id was accepted' }
        if ($r.BroadErrors -eq 0) { throw "an appx pattern as broad as 'Micro*' was accepted" }
    }

    It 'deferred removal actions (WinRE, SecurityHealthService, update services) pass the deferred.json validation' {
        $acts = & $ImageModule {
            @(
                (Get-ImageWinreDeferredAction),
                (New-ImageDeferredRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\SecurityHealthService' -Name 'Start' -Kind 'DWord' -Value 4),
                (New-ImageDeferredService -Name 'wuauserv' -Startup 'Disabled')
            )
        }
        $tw = [pscustomobject]@{ id = 'image.test'; name = 'test'; category = 'image'; level = 'extreme'; reboot = $false; minBuild = $null; maxBuild = $null; actions = @($acts) }
        $json = ConvertTo-LiteOSDeferredJson -Deferred @($tw)
        foreach ($ch in $json.ToCharArray()) { if ([int]$ch -gt 127) { throw 'deferred.json text is not ASCII' } }
        $back = @(Read-LiteOSDeferred -Json $json -Scope Machine)
        if ($back.Count -ne 1) { throw ('expected 1 machine tweak back, got {0}' -f $back.Count) }
        if (@($back[0].actions).Count -ne 3) { throw ('expected 3 valid actions back, got {0} (an action was refused)' -f @($back[0].actions).Count) }
        $ps = @(@($back[0].actions) | Where-Object { $_.type -eq 'powershell' })
        if ($ps.Count -ne 1) { throw 'the WinRE script action is missing' }
        if ([string]$ps[0].script -notmatch 'reagentc' -or [string]$ps[0].script -notmatch '/disable') { throw 'the WinRE action must run reagentc /disable' }
        if ([string]$ps[0].undo -notmatch '/enable') { throw 'the WinRE undo must run reagentc /enable' }
        if ([string]$ps[0].script -match '(?i)\bdiskpart\b|Remove-Partition|Format-Volume') { throw 'the WinRE action must never touch partitions' }
        $user = @(Read-LiteOSDeferred -Json $json -Scope User)
        if ($user.Count -ne 0) { throw 'removal actions must run in the machine (SetupComplete) scope' }
    }

    It 'SettingsPageVisibility is merged, never overwritten, when the Windows Security page is hidden' {
        $r = @(& $ImageModule {
                Get-ImageSettingsPageValue -Current $null -Page 'windowsdefender'
                Get-ImageSettingsPageValue -Current '' -Page 'windowsdefender'
                Get-ImageSettingsPageValue -Current 'hide:about;bluetooth' -Page 'windowsdefender'
                Get-ImageSettingsPageValue -Current 'hide:WindowsDefender' -Page 'windowsdefender'
                Get-ImageSettingsPageValue -Current 'showonly:about' -Page 'windowsdefender'
            })
        $want = @('hide:windowsdefender', 'hide:windowsdefender', 'hide:about;bluetooth;windowsdefender', 'hide:WindowsDefender', 'showonly:about')
        if (($r -join '|') -ne ($want -join '|')) { throw ('expected [{0}] got [{1}]' -f ($want -join '|'), ($r -join '|')) }
    }

    It 'the offline plan defers appx-remove while offline hives are in use (DISM sharing violation)' {
        $act = [pscustomobject]@{ type = 'appx-remove'; packages = @('Microsoft.BingNews') }
        $with = Get-LiteOSOfflineDisposition -Action $act -Hives @{ SOFTWARE = 'HKLM\LITE_SOFTWARE'; SYSTEM = 'HKLM\LITE_SYSTEM' }
        $without = Get-LiteOSOfflineDisposition -Action $act -Hives @{}
        if ($with.Mode -ne 'deferred') { throw ('with hives loaded appx-remove must be deferred (got {0})' -f $with.Mode) }
        if ($without.Mode -ne 'offline') { throw ('without hives appx-remove runs offline (got {0})' -f $without.Mode) }
    }

    It 'Save- / Restore-LiteOSHiveStateFiles round-trip per-hive state files (image backup revert)' {
        $dir = Join-Path $TestDrive ('state-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir -Force
        $f1 = Join-Path $dir 'prev-dx-SwapEffectUpgradeEnable-Default.txt'
        $f2 = Join-Path $dir 'prev-vrr-S-1-5-21-1-2-3-1001.txt'
        [System.IO.File]::WriteAllText($f1, 'saved-default')
        [System.IO.File]::WriteAllText($f2, 'saved-user')
        $r = & $EngineModule {
            param($Dir, $File)
            $kept = Save-LiteOSHiveStateFiles -Directory $Dir -Tag 'Default'
            $count = @($kept).Count
            [System.IO.File]::Delete($File)
            $n = Restore-LiteOSHiveStateFiles -Saved $kept
            $again = Restore-LiteOSHiveStateFiles -Saved $kept
            $none = Restore-LiteOSHiveStateFiles -Saved $null
            $empty = Save-LiteOSHiveStateFiles -Directory $Dir -Tag 'NoSuchTag'
            $emptyRestored = Restore-LiteOSHiveStateFiles -Saved $empty
            [pscustomobject]@{ Count = $count; Restored = $n; Again = $again; None = $none; EmptyCount = @($empty).Count; EmptyRestored = $emptyRestored }
        } $dir $f1
        if ($r.Count -ne 1) { throw ('expected 1 Default state file saved, got {0}' -f $r.Count) }
        if ($r.Restored -ne 1) { throw 'the consumed state file was not put back' }
        if ($r.Again -ne 0) { throw 'an existing state file must not be overwritten' }
        if ($r.None -ne 0 -or $r.EmptyCount -ne 0 -or $r.EmptyRestored -ne 0) { throw 'empty / missing saves must be harmless no-ops' }
        if ([System.IO.File]::ReadAllText($f1) -ne 'saved-default') { throw 'the restored state file has the wrong content' }
        if ([System.IO.File]::ReadAllText($f2) -ne 'saved-user') { throw 'a state file of another hive tag was touched' }
    }
}

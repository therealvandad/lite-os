<#
    Lite OS - tweak catalog tests.

    Static and pure: these tests only READ tweaks\*.json and import the engine module to call
    Select-LiteOSTweaks / Get-LiteOSCatalog on in-memory data. Nothing is ever applied.

    Compatible with Pester 3.4 (built into Windows) and Pester 5.x (CI):
      - only Describe / Context / It / BeforeAll / AfterAll (BeforeAll inside Describe),
      - no Should at all (Pester 5 rejects the legacy "Should Be" syntax, Pester 3.4 lacks "Should -Be"),
        assertions are plain "throw" with a readable message,
      - -TestCases data is computed in the Describe body (works for Pester 5 discovery and Pester 3.4).

    Run:  Invoke-Pester -Path .\tests
#>

Describe 'Lite OS tweak catalog' {

    BeforeAll {
        $RepoRoot   = Split-Path -Parent $PSScriptRoot
        $TweaksDir  = Join-Path $RepoRoot 'tweaks'
        $AppsRemoveFile  = 'apps-remove.json'
        $AppsInstallFile = 'apps-install.json'

        $ExpectedCategoryFiles = @('privacy.json', 'ui.json', 'gaming.json', 'performance.json',
            'network.json', 'services.json', 'updates.json', 'security-extreme.json')

        $Levels      = @('balanced', 'extreme')
        $Risks       = @('none', 'low', 'medium', 'high')
        $RegKinds    = @('DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary')
        $Startups    = @('Disabled', 'Manual', 'Automatic', 'AutomaticDelayed')
        $TaskStates  = @('Disabled', 'Enabled')
        $ActionTypes = @('registry', 'registry-delete', 'service', 'task', 'powershell', 'appx-remove')

        # services that no file may ever touch from services.json, and no balanced tweak anywhere
        $NeverServices = @('wuauserv', 'BITS', 'WinDefend', 'SecurityHealthService', 'mpssvc', 'BFE',
            'vgc', 'vgk', 'EasyAntiCheat*', 'BEService', 'BEDaisy', 'FACEIT*', 'EAAntiCheat*',
            'GamingServices*', 'Xbl*', 'XboxNetApiSvc', 'XboxGipSvc', 'TBS', 'AppXSvc')

        # additionally forbidden for balanced tweaks: Windows Update plumbing, Store / licensing,
        # sign-in, Defender components, Windows Hello, BitLocker, core servicing
        $BalancedForbiddenServices = @('UsoSvc', 'WaaSMedicSvc', 'DoSvc', 'InstallService', 'ClipSVC',
            'LicenseManager', 'wlidsvc', 'TokenBroker', 'CryptSvc', 'TrustedInstaller', 'wscsvc',
            'WdNisSvc', 'WdNisDrv', 'WdFilter', 'WdBoot', 'Sense', 'StateRepository', 'WbioSrvc',
            'NgcSvc', 'NgcCtnrSvc', 'BDESVC')

        # Every package the contract says must survive. The "protected" list in apps-remove.json must
        # cover each of these, and no removal pattern may match any of them.
        $ContractProtectedPackages = @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller',
            'Microsoft.GamingApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxIdentityProvider',
            'Microsoft.Xbox.TCUI', 'Microsoft.XboxSpeechToTextOverlay', 'Microsoft.GamingServices',
            'Microsoft.VCLibs.140.00', 'Microsoft.VCLibs.140.00.UWPDesktop', 'Microsoft.UI.Xaml.2.8',
            'Microsoft.UI.Xaml.CBS', 'Microsoft.NET.Native.Framework.2.2', 'Microsoft.NET.Native.Runtime.2.2',
            'Microsoft.WindowsAppRuntime.1.5', 'Microsoft.WindowsAppRuntime.1.8', 'Microsoft.WindowsAppRuntime.CBS.1.6',
            'Microsoft.WindowsCalculator', 'Microsoft.Windows.Photos', 'Microsoft.WindowsNotepad',
            'Microsoft.WindowsTerminal', 'Microsoft.Paint', 'Microsoft.ScreenSketch', 'Microsoft.SecHealthUI',
            'Microsoft.MicrosoftEdge.Stable', 'Microsoft.Windows.ShellExperienceHost',
            'Microsoft.Windows.StartMenuExperienceHost', 'Microsoft.WidgetsPlatformRuntime')
        $NeverRemovePackages = $ContractProtectedPackages + @('Microsoft.StorePurchaseApp', 'Microsoft.Win32WebViewHost')

        function Test-P {
            param($Object, [string]$Name)
            if ($null -eq $Object) { return $false }
            if (-not ($Object -is [System.Management.Automation.PSCustomObject])) { return $false }
            return ($null -ne $Object.PSObject.Properties[$Name])
        }

        # NOTE: like any PowerShell function, Get-P unrolls arrays; wrap with @() to iterate and
        # use Test-PArray to check that a field really is a JSON array.
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

        function Get-CategoryFiles {
            return @(Get-ChildItem -LiteralPath $TweaksDir -Filter '*.json' -File |
                    Where-Object { $_.Name -ne $AppsRemoveFile -and $_.Name -ne $AppsInstallFile } |
                    Sort-Object Name)
        }

        # one record per tweak: File, Category, Tweak
        function Get-AllTweaks {
            $all = New-Object System.Collections.ArrayList
            foreach ($f in (Get-CategoryFiles)) {
                $doc = Read-Json $f.FullName
                $cat = [string](Get-P $doc 'category')
                foreach ($t in @(Get-P $doc 'tweaks')) {
                    if ($null -eq $t) { continue }
                    [void]$all.Add((New-Object PSObject -Property @{ File = $f.Name; Category = $cat; Tweak = $t }))
                }
            }
            return $all.ToArray()
        }

        function Get-Actions {
            param($Tweak)
            return @(@(Get-P $Tweak 'actions') | Where-Object { $null -ne $_ })
        }

        function Get-TweakLabel {
            param($Record)
            $id = Get-P $Record.Tweak 'id'
            if (-not $id) { $id = '<no id>' }
            return ('{0}:{1}' -f $Record.File, $id)
        }

        function ConvertTo-WildcardRegex {
            param([string]$Pattern)
            return ('^' + ([regex]::Escape($Pattern) -replace '\\\*', '.*' -replace '\\\?', '.') + '$')
        }

        function Test-NameInList {
            # case-insensitive, wildcard-aware: does $Name match any pattern in $List
            param([string]$Name, [string[]]$List)
            foreach ($p in $List) { if ($Name -like $p) { return $true } }
            return $false
        }

        function Test-PatternOverlap {
            # two wildcard patterns overlap if either one matches the other literally
            param([string]$A, [string]$B)
            return (($A -like $B) -or ($B -like $A))
        }

        function Get-ServiceFromRegistryPath {
            param([string]$Path)
            $m = [regex]::Match($Path, '(?i)^HKLM:\\SYSTEM\\(CurrentControlSet|ControlSet\d{3})\\Services\\([^\\]+)')
            if ($m.Success) { return $m.Groups[2].Value }
            return $null
        }

        function Get-ServiceTouchProblems {
            # every way an action can change a service: service action, Services\<name> registry, script
            param($Action, [string[]]$Forbidden)
            $problems = @()
            $type = [string](Get-P $Action 'type')
            if ($type -eq 'service') {
                $n = [string](Get-P $Action 'name')
                if (Test-NameInList $n $Forbidden) { $problems += ("service action on protected service '{0}'" -f $n) }
            } elseif ($type -eq 'registry' -or $type -eq 'registry-delete') {
                $svc = Get-ServiceFromRegistryPath ([string](Get-P $Action 'path'))
                if ($svc -and (Test-NameInList $svc $Forbidden)) {
                    $problems += ("registry action on protected service key '{0}'" -f $svc)
                }
            } elseif ($type -eq 'powershell') {
                $text = [string](Get-P $Action 'script')
                foreach ($f in $Forbidden) {
                    $nameRx = [regex]::Escape($f) -replace '\\\*', '[A-Za-z0-9_]*'
                    $rx = '(?i)(Set-Service|Stop-Service|Suspend-Service|Remove-Service|\bsc(\.exe)?\s+(config|stop|delete))[^\r\n;|]*\b' + $nameRx + '\b'
                    if ($text -match $rx) { $problems += ("script changes protected service '{0}'" -f $f) }
                }
            }
            return $problems
        }

        function Get-BalancedSafetyProblems {
            # Balanced must keep Defender, security updates, Store, Xbox / Game Pass, VBS/HVCI and anti-cheat.
            param($Action)
            $problems = @()
            $problems += @(Get-ServiceTouchProblems -Action $Action -Forbidden ($NeverServices + $BalancedForbiddenServices))
            $type = [string](Get-P $Action 'type')

            if ($type -eq 'registry' -or $type -eq 'registry-delete') {
                $path = [string](Get-P $Action 'path')
                $name = [string](Get-P $Action 'name')
                $value = Get-P $Action 'value'

                # Defender real-time protection / tamper protection / Defender off switches
                if ($path -match '(?i)\\Windows Defender(\\|$)') {
                    if ($path -match '(?i)Real-Time Protection|\\Features(\\|$)' -or
                        $name -match '(?i)^(DisableAntiSpyware|DisableAntiVirus|DisableRealtimeMonitoring|DisableBehaviorMonitoring|DisableOnAccessProtection|DisableIOAVProtection|DisableScanOnRealtimeEnable|ServiceKeepAlive|TamperProtection\w*)$') {
                        $problems += ("touches Defender real-time/tamper protection ({0} {1})" -f $path, $name)
                    }
                }
                # VBS / HVCI / Device Guard / Credential Guard / driver blocklist
                if ($path -match '(?i)\\DeviceGuard(\\|$)|HypervisorEnforcedCodeIntegrity|\\Control\\CI(\\|$)' -or
                    $name -match '(?i)^(EnableVirtualizationBasedSecurity|RequirePlatformSecurityFeatures|HypervisorEnforcedCodeIntegrity|HVCIMATRequired|LsaCfgFlags|RunAsPPL|VulnerableDriverBlocklistEnable|ConfigureSystemGuardLaunch)$') {
                    $problems += ("touches VBS/HVCI/Device Guard ({0} {1})" -f $path, $name)
                }
                # Windows Update blocked or redirected, quality updates paused
                if ($path -match '(?i)\\WindowsUpdate(\\|$)') {
                    $blocking = @('NoAutoUpdate', 'DisableWindowsUpdateAccess', 'DoNotConnectToWindowsUpdateInternetLocations', 'SetDisableUXWUAccess', 'UseWUServer')
                    if ($type -eq 'registry' -and ($blocking -contains $name) -and (Test-Integer $value) -and ($value -ne 0)) {
                        $problems += ("blocks Windows Update ({0} = {1})" -f $name, $value)
                    }
                    if ($name -match '(?i)^(WUServer|WUStatusServer|UpdateServiceUrlAlternate)$') {
                        $problems += ("redirects Windows Update ({0})" -f $name)
                    }
                    if ($name -match '(?i)^(PauseQualityUpdates\w*|PauseUpdates\w*|FlightSettingsMaxPauseDays)$') {
                        $problems += ("pauses security (quality) updates ({0})" -f $name)
                    }
                }
                # Microsoft Store removed / disabled
                if ($path -match '(?i)\\WindowsStore(\\|$)' -and $name -match '(?i)^(RemoveWindowsStore|DisableStoreApps)$') {
                    $problems += ("disables Microsoft Store ({0})" -f $name)
                }
            } elseif ($type -eq 'task') {
                $tp = [string](Get-P $Action 'path')
                $state = [string](Get-P $Action 'state')
                if ($state -eq 'Disabled' -and $tp -match '(?i)\\(WindowsUpdate|UpdateOrchestrator|WaaSMedic|Windows Defender|InstallService|XblGameSave)\\') {
                    $problems += ("disables a protected scheduled task ({0}{1})" -f $tp, (Get-P $Action 'name'))
                }
            } elseif ($type -eq 'powershell') {
                $text = [string](Get-P $Action 'script')
                if ($text -match '(?i)bcdedit[^\r\n]*(hypervisorlaunchtype|vsmlaunchtype|nointegritychecks|testsigning|loadoptions)') {
                    $problems += 'script changes boot security / hypervisor settings via bcdedit'
                }
                if ($text -match '(?i)Set-MpPreference[^\r\n]*-Disable(RealtimeMonitoring|BehaviorMonitoring|IOAVProtection|IntrusionPreventionSystem|ScriptScanning|BlockAtFirstSeen)') {
                    $problems += 'script disables Defender protection via Set-MpPreference'
                }
                if ($text -match '(?i)Edge[^\r\n]*--uninstall|--uninstall[^\r\n]*Edge') {
                    $problems += 'script uninstalls Edge / WebView2'
                }
            }
            return $problems
        }

        function Get-ActionSchemaProblems {
            param($Action, [string]$Where)
            $p = @()
            if (-not ($Action -is [System.Management.Automation.PSCustomObject])) { return @("${Where}: action is not an object") }
            $type = Get-P $Action 'type'
            if (-not (Test-NonEmptyString $type)) { return @("${Where}: action has no 'type'") }
            if ($ActionTypes -notcontains $type) { return @("${Where}: unknown action type '$type'") }

            switch ($type) {
                'registry' {
                    $path = Get-P $Action 'path'
                    if (-not ((Test-NonEmptyString $path) -and ($path -match '^(HKLM|HKCU):\\[^\\]'))) { $p += "${Where}: registry 'path' must start with HKLM:\ or HKCU:\ (got '$path')" }
                    if (-not (Test-P $Action 'name') -or -not ((Get-P $Action 'name') -is [string])) { $p += "${Where}: registry 'name' must be a string ('' = default value)" }
                    elseif ([string](Get-P $Action 'name') -match '^\s*(\((?i:default)\)|@)\s*$') { $p += "${Where}: use `"name`": `"`" for a key's default value, not '$(Get-P $Action 'name')' (the registry API would create a value with that literal name)" }
                    $kind = Get-P $Action 'kind'
                    if ($RegKinds -notcontains $kind) { $p += "${Where}: registry 'kind' must be one of $($RegKinds -join ', ') (got '$kind')" }
                    if (-not (Test-P $Action 'value')) {
                        $p += "${Where}: registry action has no 'value'"
                    } else {
                        $v = Get-P $Action 'value'
                        switch ($kind) {
                            'DWord' {
                                if (-not (Test-Integer $v) -or $v -lt -2147483648 -or $v -gt 4294967295) { $p += "${Where}: DWord value must be an integer in 32-bit range (got '$v')" }
                            }
                            'QWord' {
                                if (-not (Test-Integer $v)) { $p += "${Where}: QWord value must be an integer (got '$v')" }
                            }
                            'String' { if (-not ($v -is [string])) { $p += "${Where}: String value must be a string" } }
                            'ExpandString' { if (-not ($v -is [string])) { $p += "${Where}: ExpandString value must be a string" } }
                            'MultiString' {
                                if (-not (Test-PArray $Action 'value')) { $p += "${Where}: MultiString value must be an array of strings" }
                                else { foreach ($e in @($v)) { if (-not ($e -is [string])) { $p += "${Where}: MultiString value must contain only strings" ; break } } }
                            }
                            'Binary' {
                                $hex = ''
                                if ($v -is [string]) { $hex = $v -replace '[\s,]', '' }
                                if (-not ($v -is [string]) -or $hex -notmatch '^([0-9A-Fa-f]{2})*$') { $p += "${Where}: Binary value must be a hex string such as '01ff00'" }
                            }
                        }
                    }
                }
                'registry-delete' {
                    $path = Get-P $Action 'path'
                    if (-not ((Test-NonEmptyString $path) -and ($path -match '^(HKLM|HKCU):\\[^\\]'))) { $p += "${Where}: registry-delete 'path' must start with HKLM:\ or HKCU:\ (got '$path')" }
                    if ((Test-P $Action 'name') -and -not ((Get-P $Action 'name') -is [string])) { $p += "${Where}: registry-delete 'name' must be a string" }
                    elseif ((Test-P $Action 'name') -and [string](Get-P $Action 'name') -match '^\s*(\((?i:default)\)|@)\s*$') { $p += "${Where}: use `"name`": `"`" for a key's default value" }
                }
                'service' {
                    if (-not (Test-NonEmptyString (Get-P $Action 'name'))) { $p += "${Where}: service action needs 'name'" }
                    $st = Get-P $Action 'startup'
                    if ($Startups -notcontains $st) { $p += "${Where}: service 'startup' must be one of $($Startups -join ', ') (got '$st')" }
                    if ((Test-P $Action 'stop') -and -not ((Get-P $Action 'stop') -is [bool])) { $p += "${Where}: service 'stop' must be true/false" }
                }
                'task' {
                    $tp = Get-P $Action 'path'
                    if (-not ((Test-NonEmptyString $tp) -and $tp.StartsWith('\') -and $tp.EndsWith('\'))) { $p += "${Where}: task 'path' must start and end with a backslash (got '$tp')" }
                    if (-not (Test-NonEmptyString (Get-P $Action 'name'))) { $p += "${Where}: task action needs 'name'" }
                    $ts = Get-P $Action 'state'
                    if ($TaskStates -notcontains $ts) { $p += "${Where}: task 'state' must be Disabled or Enabled (got '$ts')" }
                }
                'powershell' {
                    $code = Get-P $Action 'script'
                    if (-not (Test-NonEmptyString $code)) {
                        $p += "${Where}: powershell action needs a non-empty 'script'"
                    } else {
                        $errs = $null
                        $null = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$errs)
                        if (@($errs).Count -gt 0) { $p += "${Where}: powershell 'script' does not parse: $(@($errs)[0].Message)" }
                    }
                    if (Test-P $Action 'undo') {
                        $undo = Get-P $Action 'undo'
                        if (-not ($undo -is [string])) {
                            $p += "${Where}: powershell 'undo' must be a string"
                        } elseif ($undo.Trim().Length -gt 0) {
                            $errs = $null
                            $null = [System.Management.Automation.Language.Parser]::ParseInput($undo, [ref]$null, [ref]$errs)
                            if (@($errs).Count -gt 0) { $p += "${Where}: powershell 'undo' does not parse: $(@($errs)[0].Message)" }
                        }
                    }
                    $perUser = $false
                    if (Test-P $Action 'perUser') {
                        if (-not ((Get-P $Action 'perUser') -is [bool])) { $p += "${Where}: powershell 'perUser' must be true/false" }
                        else { $perUser = [bool](Get-P $Action 'perUser') }
                    }
                    # HKCU in a script would only reach the elevated user: per-user scripts set
                    # "perUser": true and build paths from $LiteOSUserRoot (engine: current user + Default profile)
                    $both = [string](Get-P $Action 'script') + "`n" + [string](Get-P $Action 'undo')
                    if ($both -match '(?i)HKCU:\\|HKEY_CURRENT_USER') { $p += "${Where}: script hard-codes HKCU; use `"perUser`": true and `$LiteOSUserRoot + '\...'" }
                    if ($perUser -and $both -notmatch '\$LiteOSUserRoot') { $p += "${Where}: perUser script must build its registry paths from `$LiteOSUserRoot" }
                }
                'appx-remove' {
                    if (-not (Test-PArray $Action 'packages' -NonEmpty)) { $p += "${Where}: appx-remove needs a non-empty 'packages' array" }
                    else { foreach ($e in @(Get-P $Action 'packages')) { if (-not (Test-NonEmptyString $e)) { $p += "${Where}: appx-remove 'packages' must contain non-empty strings"; break } } }
                }
            }
            return $p
        }

        function Get-TweakSchemaProblems {
            param($Record)
            $t = $Record.Tweak
            $where = Get-TweakLabel $Record
            $p = @()
            if (-not ($t -is [System.Management.Automation.PSCustomObject])) { return @("${where}: tweak is not an object") }
            foreach ($req in @('id', 'name', 'description', 'level', 'default', 'risk', 'reboot', 'actions')) {
                if (-not (Test-P $t $req)) { $p += "${where}: missing required field '$req'" }
            }
            $id = Get-P $t 'id'
            $idRx = '^' + [regex]::Escape($Record.Category) + '\.[a-z0-9]+(-[a-z0-9]+)*$'
            if (-not (Test-NonEmptyString $id) -or $id -cnotmatch $idRx) { $p += "${where}: id must be '<category>.<kebab-name>' with category '$($Record.Category)'" }
            if (-not (Test-NonEmptyString (Get-P $t 'name'))) { $p += "${where}: 'name' must be a non-empty string" }
            if (-not (Test-NonEmptyString (Get-P $t 'description'))) { $p += "${where}: 'description' must be a non-empty string" }
            if ($Levels -notcontains (Get-P $t 'level')) { $p += "${where}: 'level' must be balanced or extreme" }
            if (-not ((Get-P $t 'default') -is [bool])) { $p += "${where}: 'default' must be true/false" }
            if ($Risks -notcontains (Get-P $t 'risk')) { $p += "${where}: 'risk' must be one of $($Risks -join ', ')" }
            if (-not ((Get-P $t 'reboot') -is [bool])) { $p += "${where}: 'reboot' must be true/false" }
            foreach ($b in @('minBuild', 'maxBuild')) {
                if (Test-P $t $b) {
                    $bv = Get-P $t $b
                    if (-not (Test-Integer $bv) -or $bv -lt 0) { $p += "${where}: '$b' must be a positive integer" }
                }
            }
            if ((Test-P $t 'minBuild') -and (Test-P $t 'maxBuild')) {
                if ((Test-Integer (Get-P $t 'minBuild')) -and (Test-Integer (Get-P $t 'maxBuild')) -and ((Get-P $t 'minBuild') -gt (Get-P $t 'maxBuild'))) {
                    $p += "${where}: minBuild is greater than maxBuild"
                }
            }
            if (-not (Test-PArray $t 'actions' -NonEmpty)) {
                $p += "${where}: 'actions' must be a non-empty array"
            } else {
                $i = 0
                foreach ($a in @(Get-P $t 'actions')) {
                    $p += @(Get-ActionSchemaProblems -Action $a -Where ("{0} action[{1}]" -f $where, $i))
                    $i++
                }
            }
            return $p
        }

        function Assert-NoProblems {
            param([object[]]$Problems, [string]$Title)
            $list = @($Problems | Where-Object { $_ })
            if ($list.Count -gt 0) {
                throw ("{0} ({1}):`n  - {2}" -f $Title, $list.Count, ($list -join "`n  - "))
            }
        }
    }

    # ---- discovery-time data (Pester 5 runs this during discovery, Pester 3.4 inline) ----
    $tweaksDirForCases = Join-Path (Split-Path -Parent $PSScriptRoot) 'tweaks'
    $jsonCases = @()
    if (Test-Path -LiteralPath $tweaksDirForCases) {
        $jsonCases = @(Get-ChildItem -LiteralPath $tweaksDirForCases -Filter '*.json' -File | Sort-Object Name |
                ForEach-Object { @{ File = $_.Name; Path = $_.FullName } })
    }

    Context 'Files' {

        It 'has a tweaks folder with JSON files' {
            if (-not (Test-Path -LiteralPath $TweaksDir)) { throw "Missing folder: $TweaksDir" }
            if (@(Get-ChildItem -LiteralPath $TweaksDir -Filter '*.json' -File).Count -eq 0) { throw 'No tweaks\*.json files found.' }
        }

        It 'has every category file named in the architecture contract' {
            $missing = @($ExpectedCategoryFiles + @($AppsRemoveFile, $AppsInstallFile) |
                    Where-Object { -not (Test-Path -LiteralPath (Join-Path $TweaksDir $_)) })
            if ($missing.Count -gt 0) { throw ('Missing catalog files: ' + ($missing -join ', ')) }
        }

        if ($jsonCases.Count -gt 0) {
            It 'parses as JSON: <File>' -TestCases $jsonCases {
                param($File, $Path)
                $null = Read-Json $Path
            }
        }
    }

    Context 'Category file schema' {

        It 'every category file has category, title and a non-empty tweaks array' {
            $problems = @()
            foreach ($f in (Get-CategoryFiles)) {
                $doc = Read-Json $f.FullName
                if (-not ($doc -is [System.Management.Automation.PSCustomObject])) { $problems += "$($f.Name): top level must be an object"; continue }
                $cat = Get-P $doc 'category'
                if (-not (Test-NonEmptyString $cat) -or $cat -cnotmatch '^[a-z][a-z0-9]*(-[a-z0-9]+)*$') { $problems += "$($f.Name): 'category' must be a lower-case kebab string" }
                if ($cat -eq 'apps') { $problems += "$($f.Name): category 'apps' is reserved for the synthetic apps.remove.* tweaks" }
                if (-not (Test-NonEmptyString (Get-P $doc 'title'))) { $problems += "$($f.Name): 'title' must be a non-empty string" }
                if (-not (Test-PArray $doc 'tweaks' -NonEmpty)) { $problems += "$($f.Name): 'tweaks' must be a non-empty array" }
            }
            Assert-NoProblems $problems 'Category file problems'
        }

        It 'every tweak has the required fields, valid enums and valid actions' {
            $problems = @()
            foreach ($r in (Get-AllTweaks)) { $problems += @(Get-TweakSchemaProblems $r) }
            Assert-NoProblems $problems 'Tweak schema problems'
        }

        It 'tweak ids are unique across all files' {
            $seen = @{}
            $problems = @()
            foreach ($r in (Get-AllTweaks)) {
                $id = [string](Get-P $r.Tweak 'id')
                if (-not $id) { continue }
                $k = $id.ToLowerInvariant()
                if ($seen.ContainsKey($k)) { $problems += ("duplicate id '{0}' in {1} and {2}" -f $id, $seen[$k], $r.File) }
                else { $seen[$k] = $r.File }
            }
            Assert-NoProblems $problems 'Duplicate tweak ids'
        }

        It 'extreme tweaks have risk of at least low and explain the downside' {
            $problems = @()
            foreach ($r in (Get-AllTweaks)) {
                if ((Get-P $r.Tweak 'level') -ne 'extreme') { continue }
                if ((Get-P $r.Tweak 'risk') -eq 'none') { $problems += ("{0}: extreme tweak cannot have risk 'none'" -f (Get-TweakLabel $r)) }
                if (-not (Test-NonEmptyString (Get-P $r.Tweak 'description'))) { $problems += ("{0}: extreme tweak needs a description of its downside" -f (Get-TweakLabel $r)) }
            }
            Assert-NoProblems $problems 'Extreme tweak problems'
        }

        It 'security-extreme.json contains only extreme tweaks' {
            $problems = @()
            foreach ($r in (Get-AllTweaks)) {
                if ($r.File -ne 'security-extreme.json') { continue }
                if ((Get-P $r.Tweak 'level') -ne 'extreme') { $problems += ("{0}: must be level 'extreme'" -f (Get-TweakLabel $r)) }
            }
            Assert-NoProblems $problems 'security-extreme.json problems'
        }
    }

    Context 'Safety rules' {

        It 'services.json never touches Windows Update, Defender, firewall, Xbox/Gaming Services, TPM, AppX or anti-cheat services' {
            $problems = @()
            foreach ($r in (Get-AllTweaks)) {
                if ($r.File -ne 'services.json') { continue }
                foreach ($a in (Get-Actions $r.Tweak)) {
                    foreach ($msg in @(Get-ServiceTouchProblems -Action $a -Forbidden $NeverServices)) { $problems += ('{0}: {1}' -f (Get-TweakLabel $r), $msg) }
                }
            }
            Assert-NoProblems $problems 'services.json touches protected services'
        }

        It 'balanced tweaks keep Defender, security updates, Store, Xbox / Game Pass, VBS/HVCI and anti-cheat intact' {
            $problems = @()
            foreach ($r in (Get-AllTweaks)) {
                if ((Get-P $r.Tweak 'level') -ne 'balanced') { continue }
                foreach ($a in (Get-Actions $r.Tweak)) {
                    foreach ($msg in @(Get-BalancedSafetyProblems -Action $a)) { $problems += ('{0}: {1}' -f (Get-TweakLabel $r), $msg) }
                }
            }
            Assert-NoProblems $problems 'Balanced tweaks break a protected feature (move them to extreme)'
        }

        It 'appx-remove actions in category files never target protected packages' {
            $protected = @()
            $arPath = Join-Path $TweaksDir $AppsRemoveFile
            if (Test-Path -LiteralPath $arPath) { $protected = @(Get-P (Read-Json $arPath) 'protected') }
            $problems = @()
            foreach ($r in (Get-AllTweaks)) {
                foreach ($a in (Get-Actions $r.Tweak)) {
                    if ((Get-P $a 'type') -ne 'appx-remove') { continue }
                    foreach ($pkg in @(Get-P $a 'packages')) {
                        foreach ($pr in $protected) { if (Test-PatternOverlap ([string]$pkg) ([string]$pr)) { $problems += ("{0}: '{1}' overlaps protected '{2}'" -f (Get-TweakLabel $r), $pkg, $pr) } }
                        foreach ($n in $NeverRemovePackages) { if ($n -like [string]$pkg) { $problems += ("{0}: '{1}' would remove '{2}'" -f (Get-TweakLabel $r), $pkg, $n) } }
                    }
                }
            }
            Assert-NoProblems $problems 'appx-remove targets protected packages'
        }
    }

    Context 'apps-remove.json' {

        It 'has title, packages and protected lists with valid entries' {
            $doc = Read-Json (Join-Path $TweaksDir $AppsRemoveFile)
            $problems = @()
            if (-not (Test-NonEmptyString (Get-P $doc 'title'))) { $problems += "'title' must be a non-empty string" }
            $pk = @(Get-P $doc 'packages')
            if (-not (Test-PArray $doc 'packages' -NonEmpty)) { $problems += "'packages' must be a non-empty array" }
            if (-not (Test-PArray $doc 'protected' -NonEmpty)) { $problems += "'protected' must be a non-empty array" }
            else { foreach ($x in @(Get-P $doc 'protected')) { if (-not (Test-NonEmptyString $x)) { $problems += "'protected' must contain only non-empty strings"; break } } }
            $seen = @{}
            $i = 0
            foreach ($e in @($pk)) {
                $w = "packages[$i]"
                $i++
                $m = Get-P $e 'match'
                if (-not (Test-NonEmptyString $m) -or $m -notmatch '^[A-Za-z0-9.*_-]+$') { $problems += "${w}: 'match' must be an AppX package name (letters, digits, . _ - and * wildcards)"; continue }
                if (($m -replace '\*', '').Length -lt 3 -or $m -match '^[A-Za-z0-9]+\.?\*$') { $problems += "${w}: match '$m' is too broad" }
                if ($seen.ContainsKey($m.ToLowerInvariant())) { $problems += "${w}: duplicate match '$m'" } else { $seen[$m.ToLowerInvariant()] = $true }
                if (-not (Test-NonEmptyString (Get-P $e 'name'))) { $problems += "${w} ($m): 'name' must be a non-empty string" }
                if ($Levels -notcontains (Get-P $e 'level')) { $problems += "${w} ($m): 'level' must be balanced or extreme" }
                if (-not ((Get-P $e 'default') -is [bool])) { $problems += "${w} ($m): 'default' must be true/false" }
            }
            Assert-NoProblems $problems 'apps-remove.json problems'
        }

        It 'protected list covers every package the contract protects' {
            $prot = @(Get-P (Read-Json (Join-Path $TweaksDir $AppsRemoveFile)) 'protected' | ForEach-Object { [string]$_ })
            $missing = @($ContractProtectedPackages | Where-Object { -not (Test-NameInList $_ $prot) })
            if ($missing.Count -gt 0) { throw ('protected list does not cover: ' + ($missing -join ', ')) }
        }

        It 'no removal entry matches a protected package' {
            $doc = Read-Json (Join-Path $TweaksDir $AppsRemoveFile)
            $prot = @(Get-P $doc 'protected' | ForEach-Object { [string]$_ })
            $problems = @()
            foreach ($e in @(Get-P $doc 'packages')) {
                $m = [string](Get-P $e 'match')
                if (-not $m) { continue }
                foreach ($p in $prot) { if (Test-PatternOverlap $m $p) { $problems += ("'{0}' overlaps protected '{1}'" -f $m, $p) } }
                foreach ($n in $NeverRemovePackages) { if ($n -like $m) { $problems += ("'{0}' would remove '{1}'" -f $m, $n) } }
            }
            Assert-NoProblems $problems 'apps-remove.json removes protected packages'
        }
    }

    Context 'apps-install.json' {

        It 'has a non-empty apps array with valid, unique winget ids' {
            $doc = Read-Json (Join-Path $TweaksDir $AppsInstallFile)
            $apps = @(Get-P $doc 'apps')
            $problems = @()
            if (-not (Test-PArray $doc 'apps' -NonEmpty)) { $problems += "'apps' must be a non-empty array" }
            $seen = @{}
            $i = 0
            foreach ($a in @($apps)) {
                $w = "apps[$i]"
                $i++
                $id = Get-P $a 'id'
                if (-not (Test-NonEmptyString $id) -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9_+-]*(\.[A-Za-z0-9_+-]+)+$') { $problems += "${w}: 'id' must be an exact winget id like Publisher.Package (got '$id')"; continue }
                if ($seen.ContainsKey($id.ToLowerInvariant())) { $problems += "${w}: duplicate id '$id'" } else { $seen[$id.ToLowerInvariant()] = $true }
                if (-not (Test-NonEmptyString (Get-P $a 'name'))) { $problems += "${w} ($id): 'name' must be a non-empty string" }
                if (-not (Test-NonEmptyString (Get-P $a 'group'))) { $problems += "${w} ($id): 'group' must be a non-empty string" }
                if (-not ((Get-P $a 'default') -is [bool])) { $problems += "${w} ($id): 'default' must be true/false" }
                if (Test-P $a 'location') {
                    $loc = Get-P $a 'location'
                    if (-not (Test-NonEmptyString $loc) -or $loc.Contains('"')) { $problems += "${w} ($id): optional 'location' must be a non-empty path without quotes" }
                }
            }
            Assert-NoProblems $problems 'apps-install.json problems'
        }
    }
}

Describe 'Select-LiteOSTweaks' {

    BeforeAll {
        $RepoRoot   = Split-Path -Parent $PSScriptRoot
        $EnginePath = Join-Path $RepoRoot 'src\LiteOS.Engine.psm1'
        # Importing the engine must have no side effects (architecture contract).
        Import-Module $EnginePath -Force -DisableNameChecking -ErrorAction Stop

        function New-FakeTweak {
            param([string]$Id, [string]$Level, [bool]$Default, $MinBuild = $null, $MaxBuild = $null)
            $h = [ordered]@{
                id          = $Id
                name        = $Id
                description = 'Fake tweak used by the selection tests. Never applied.'
                level       = $Level
                default     = $Default
                risk        = 'low'
                reboot      = $false
                actions     = @([pscustomobject]@{ type = 'registry'; path = 'HKCU:\Software\LiteOS-Test'; name = 'Fake'; kind = 'DWord'; value = 1 })
                category    = 'test'
            }
            if ($null -ne $MinBuild) { $h['minBuild'] = $MinBuild }
            if ($null -ne $MaxBuild) { $h['maxBuild'] = $MaxBuild }
            return [pscustomobject]$h
        }

        $FakeCatalog = @(
            (New-FakeTweak -Id 'test.bal-on'    -Level 'balanced' -Default $true)
            (New-FakeTweak -Id 'test.bal-off'   -Level 'balanced' -Default $false)
            (New-FakeTweak -Id 'test.ext-on'    -Level 'extreme'  -Default $true)
            (New-FakeTweak -Id 'test.ext-off'   -Level 'extreme'  -Default $false)
            (New-FakeTweak -Id 'test.new-build' -Level 'balanced' -Default $true -MinBuild 99999)
            (New-FakeTweak -Id 'test.old-build' -Level 'balanced' -Default $true -MaxBuild 22000)
            (New-FakeTweak -Id 'test.in-range'  -Level 'balanced' -Default $true -MinBuild 26100 -MaxBuild 99999)
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
        Remove-Module -Name 'LiteOS.Engine' -Force -ErrorAction SilentlyContinue
    }

    It 'exports Select-LiteOSTweaks and Get-LiteOSCatalog' {
        foreach ($c in @('Select-LiteOSTweaks', 'Get-LiteOSCatalog')) {
            if (-not (Get-Command -Name $c -ErrorAction SilentlyContinue)) { throw "Engine does not export $c" }
        }
    }

    It 'Balanced selects only balanced default tweaks inside the build range' {
        $r = Select-LiteOSTweaks -Catalog $FakeCatalog -Level Balanced -Build 26200
        Assert-IdSet $r @('test.bal-on', 'test.in-range') 'Balanced'
    }

    It 'Extreme selects Balanced plus extreme default tweaks' {
        $r = Select-LiteOSTweaks -Catalog $FakeCatalog -Level Extreme -Build 26200
        Assert-IdSet $r @('test.bal-on', 'test.in-range', 'test.ext-on') 'Extreme'
    }

    It 'None selects nothing' {
        $r = Select-LiteOSTweaks -Catalog $FakeCatalog -Level None -Build 26200
        Assert-IdSet $r @() 'None'
    }

    It 'Include adds default:false tweaks' {
        $r = Select-LiteOSTweaks -Catalog $FakeCatalog -Level Balanced -Include @('test.bal-off') -Build 26200
        Assert-IdSet $r @('test.bal-on', 'test.in-range', 'test.bal-off') 'Balanced + Include'
        $r = Select-LiteOSTweaks -Catalog $FakeCatalog -Level Extreme -Include @('test.ext-off') -Build 26200
        Assert-IdSet $r @('test.bal-on', 'test.in-range', 'test.ext-on', 'test.ext-off') 'Extreme + Include'
    }

    It 'None plus Include selects exactly the included tweaks (Custom mode)' {
        $r = Select-LiteOSTweaks -Catalog $FakeCatalog -Level None -Include @('test.bal-off', 'test.ext-off') -Build 26200
        Assert-IdSet $r @('test.bal-off', 'test.ext-off') 'None + Include'
    }

    It 'Exclude removes default tweaks' {
        $r = Select-LiteOSTweaks -Catalog $FakeCatalog -Level Balanced -Exclude @('test.bal-on') -Build 26200
        Assert-IdSet $r @('test.in-range') 'Balanced - Exclude'
        $r = Select-LiteOSTweaks -Catalog $FakeCatalog -Level Extreme -Exclude @('test.ext-on', 'test.in-range') -Build 26200
        Assert-IdSet $r @('test.bal-on') 'Extreme - Exclude'
    }

    It 'minBuild and maxBuild limit the selection by Windows build' {
        $r = Select-LiteOSTweaks -Catalog $FakeCatalog -Level Balanced -Build 100000
        Assert-IdSet $r @('test.bal-on', 'test.new-build') 'Build 100000'
        $r = Select-LiteOSTweaks -Catalog $FakeCatalog -Level Balanced -Build 21000
        Assert-IdSet $r @('test.bal-on', 'test.old-build') 'Build 21000'
    }

    It 'the real catalog loads and Balanced never contains extreme tweaks' {
        $tweaksDir = Join-Path $RepoRoot 'tweaks'
        $catalog = @(Get-LiteOSCatalog -Path $tweaksDir)
        if ($catalog.Count -eq 0) { throw 'Get-LiteOSCatalog returned no tweaks' }
        $balanced = @(Select-LiteOSTweaks -Catalog $catalog -Level Balanced -Build 26200)
        $extreme  = @(Select-LiteOSTweaks -Catalog $catalog -Level Extreme -Build 26200)
        if ($balanced.Count -eq 0) { throw 'Balanced selected nothing from the real catalog' }
        $bad = @($balanced | Where-Object { $_.level -ne 'balanced' } | ForEach-Object { $_.id })
        if ($bad.Count -gt 0) { throw ('Balanced selected non-balanced tweaks: ' + ($bad -join ', ')) }
        $extIds = @{}
        foreach ($t in $extreme) { $extIds[[string]$t.id] = $true }
        $missing = @($balanced | Where-Object { -not $extIds.ContainsKey([string]$_.id) } | ForEach-Object { $_.id })
        if ($missing.Count -gt 0) { throw ('Extreme is missing Balanced tweaks: ' + ($missing -join ', ')) }
    }
}

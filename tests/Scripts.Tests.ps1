<#
    Lite OS - script hygiene tests.

    Static only: files are read and parsed, never executed.
      - every .ps1/.psm1/.psd1 parses with zero errors (run under Windows PowerShell 5.1 in CI)
      - no PowerShell 7-only syntax or parameters
      - every .ps1/.psm1/.psd1/.cmd/.bat/.json/.xml file is pure ASCII (no BOM, no smart quotes)
      - every .json parses
      - builder\autounattend.xml parses and never wipes or partitions disks
      - no file contains anything that looks like a product key, and no Windows binaries are shipped
      - entry scripts use StrictMode + ErrorActionPreference Stop
      - importing the engine module has no top-level side effects

    Compatible with Pester 3.4 and 5.x (plain throw assertions, BeforeAll inside Describe).
#>

Describe 'Lite OS scripts' {

    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot

        function Get-RepoFiles {
            param([string[]]$Extensions)
            $all = Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '[\\/]\.git([\\/]|$)' }
            if ($Extensions) {
                $ext = @($Extensions | ForEach-Object { $_.ToLowerInvariant() })
                $all = $all | Where-Object { $ext -contains $_.Extension.ToLowerInvariant() }
            }
            return @($all | Sort-Object FullName)
        }

        function Get-RelPath {
            param([string]$FullName)
            return $FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
        }

        function Assert-NoProblems {
            param([object[]]$Problems, [string]$Title)
            $list = @($Problems | Where-Object { $_ })
            if ($list.Count -gt 0) {
                throw ("{0} ({1}):`n  - {2}" -f $Title, $list.Count, ($list -join "`n  - "))
            }
        }

        function Get-ParsedAst {
            param([string]$Path)
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
            return @{ Ast = $ast; Tokens = $tokens; Errors = $errors }
        }

        # 5x5 groups of upper-case letters/digits, the shape of a Windows product key
        $ProductKeyPattern = '(?<![A-Z0-9])[A-Z0-9]{5}(-[A-Z0-9]{5}){4}(?![A-Z0-9])'
    }

    # ---- discovery-time data ----
    $rootForCases = Split-Path -Parent $PSScriptRoot
    $allForCases = @(Get-ChildItem -LiteralPath $rootForCases -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/]\.git([\\/]|$)' } | Sort-Object FullName)
    $psCases = @($allForCases | Where-Object { @('.ps1', '.psm1', '.psd1') -contains $_.Extension.ToLowerInvariant() } |
            ForEach-Object { @{ File = $_.FullName.Substring($rootForCases.Length).TrimStart('\', '/'); Path = $_.FullName } })
    $asciiCases = @($allForCases | Where-Object { @('.ps1', '.psm1', '.psd1', '.cmd', '.bat', '.json', '.xml') -contains $_.Extension.ToLowerInvariant() } |
            ForEach-Object { @{ File = $_.FullName.Substring($rootForCases.Length).TrimStart('\', '/'); Path = $_.FullName } })
    $jsonCases = @($allForCases | Where-Object { $_.Extension -eq '.json' } |
            ForEach-Object { @{ File = $_.FullName.Substring($rootForCases.Length).TrimStart('\', '/'); Path = $_.FullName } })

    Context 'PowerShell syntax' {

        if ($psCases.Count -gt 0) {
            It 'parses with zero errors: <File>' -TestCases $psCases {
                param($File, $Path)
                $r = Get-ParsedAst $Path
                $errs = @($r.Errors)
                if ($errs.Count -gt 0) {
                    $msgs = @($errs | Select-Object -First 10 | ForEach-Object { 'line {0}: {1}' -f $_.Extent.StartLineNumber, $_.Message })
                    throw ("{0} has {1} parse error(s):`n  {2}" -f $File, $errs.Count, ($msgs -join "`n  "))
                }
            }
        }

        It 'uses no PowerShell 7-only syntax, parameters or variables' {
            # Tokens/parameters that Windows PowerShell 5.1 does not support. The 5.1 parser already
            # rejects ?? ?. ?: && || - the token check also catches them when tests run under pwsh 7.
            $badTokens = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')
            $badParams = @{
                'ConvertFrom-Json'  = @('AsHashtable', 'Depth', 'NoEnumerate')
                'ConvertTo-Json'    = @('AsArray', 'EnumsAsStrings', 'EscapeHandling')
                'ForEach-Object'    = @('Parallel', 'ThrottleLimit', 'AsJob')
                'Get-Content'       = @('AsByteStream')
                'Set-Content'       = @('AsByteStream')
                'Add-Content'       = @('AsByteStream')
                'Invoke-WebRequest' = @('SkipCertificateCheck', 'Authentication', 'Resume', 'SkipHttpErrorCheck')
                'Invoke-RestMethod' = @('SkipCertificateCheck', 'Authentication', 'Resume', 'SkipHttpErrorCheck', 'StatusCodeVariable')
                'Join-Path'         = @('AdditionalChildPath')
                'Select-String'     = @('Raw', 'NoEmphasis')
            }
            $badCommands = @('Test-Json', 'Get-Error', 'ConvertFrom-Markdown', 'Join-String', 'Get-Uptime', 'Remove-Service', 'ConvertTo-CliXml')
            $badVariables = @('IsWindows', 'IsLinux', 'IsMacOS', 'IsCoreCLR')
            $problems = @()
            foreach ($f in (Get-RepoFiles @('.ps1', '.psm1', '.psd1'))) {
                $rel = Get-RelPath $f.FullName
                $r = Get-ParsedAst $f.FullName
                foreach ($t in @($r.Tokens)) {
                    if ($badTokens -contains $t.Kind.ToString()) { $problems += ('{0} line {1}: PS7-only operator {2}' -f $rel, $t.Extent.StartLineNumber, $t.Text) }
                }
                if ($null -eq $r.Ast) { continue }
                $cmds = $r.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
                foreach ($c in $cmds) {
                    $name = $c.GetCommandName()
                    if (-not $name) { continue }
                    if ($badCommands -contains $name) { $problems += ('{0} line {1}: {2} does not exist in Windows PowerShell 5.1' -f $rel, $c.Extent.StartLineNumber, $name) }
                    $positional = 0
                    $skipNext = $false
                    $elements = @($c.CommandElements)
                    for ($i = 1; $i -lt $elements.Count; $i++) {
                        $e = $elements[$i]
                        if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                            foreach ($key in $badParams.Keys) {
                                if ($name -eq $key -and ($badParams[$key] -contains $e.ParameterName)) {
                                    $problems += ('{0} line {1}: {2} -{3} is PowerShell 7 only' -f $rel, $e.Extent.StartLineNumber, $name, $e.ParameterName)
                                }
                            }
                            if ($e.ParameterName -eq 'Encoding') {
                                # only literal values matter: -Encoding utf8NoBOM / 'utf8BOM' / Ansi (PS 6+/7.4+ names)
                                $valueAst = $e.Argument
                                if ($null -eq $valueAst -and $i + 1 -lt $elements.Count) { $valueAst = $elements[$i + 1] }
                                if ($valueAst -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                                    $valueAst.Value -match '^(?i)(utf8NoBOM|utf8BOM|ansi)$') {
                                    $problems += ('{0} line {1}: -Encoding {2} is PowerShell 7 only' -f $rel, $e.Extent.StartLineNumber, $valueAst.Value)
                                }
                            }
                            $skipNext = ($null -eq $e.Argument -and $i + 1 -lt $elements.Count -and -not ($elements[$i + 1] -is [System.Management.Automation.Language.CommandParameterAst]))
                            continue
                        }
                        if ($skipNext) { $skipNext = $false; continue }
                        $positional++
                    }
                    # Join-Path in 5.1 accepts exactly Path + ChildPath; more positional args fail at runtime
                    if ($name -eq 'Join-Path' -and $positional -gt 2) {
                        $problems += ('{0} line {1}: Join-Path with more than 2 path arguments is PowerShell 7 only' -f $rel, $c.Extent.StartLineNumber)
                    }
                }
                $vars = $r.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
                foreach ($v in $vars) {
                    if ($badVariables -contains $v.VariablePath.UserPath) { $problems += ('{0} line {1}: ${2} does not exist in Windows PowerShell 5.1' -f $rel, $v.Extent.StartLineNumber, $v.VariablePath.UserPath) }
                }
            }
            Assert-NoProblems $problems 'PowerShell 7-only constructs found'
        }

        It 'entry scripts use Set-StrictMode and ErrorActionPreference Stop' {
            $entries = @('LiteOS.ps1', 'Revert-LiteOS.ps1', 'builder\Build-LiteOS.ps1', 'src\Install-Apps.ps1',
                'LiteOS-Builder.ps1', 'builder\Get-WindowsIso.ps1', 'builder\Test-LiteOSImage.ps1', 'builder\New-IsoFile.ps1')
            $problems = @()
            foreach ($rel in $entries) {
                $path = Join-Path $RepoRoot $rel
                if (-not (Test-Path -LiteralPath $path)) { $problems += "$rel is missing"; continue }
                $text = Get-Content -LiteralPath $path -Raw
                if ($text -notmatch '(?im)^\s*Set-StrictMode\s+-Version\s+(2(\.0)?|3(\.0)?|Latest)\b') { $problems += "${rel}: missing 'Set-StrictMode -Version 2.0'" }
                if ($text -notmatch '(?im)^\s*\$ErrorActionPreference\s*=\s*[''"]Stop[''"]') { $problems += "${rel}: missing `$ErrorActionPreference = 'Stop'" }
            }
            Assert-NoProblems $problems 'Entry script problems'
        }

        It 'never creates a List[object] with New-Object (PS 5.1: @() on a PSObject-wrapped List[object] throws)' {
            # Windows PowerShell 5.1 (5.1.26100): @($x) throws "Argument types do not match" when $x is a
            # List[object] wrapped in a PSObject - which New-Object returns, also for an empty list.
            # [System.Collections.Generic.List[object]]::new() returns the bare list and is safe.
            $rx = '(?i)New-Object\b[^\r\n]*Generic\.List\[\s*(object|System\.Object|psobject|System\.Management\.Automation\.PSObject)\s*\]'
            $problems = @()
            foreach ($f in (Get-RepoFiles @('.ps1', '.psm1'))) {
                $rel = Get-RelPath $f.FullName
                $lines = @(Get-Content -LiteralPath $f.FullName)
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    $line = [string]$lines[$i]
                    if ($line.TrimStart().StartsWith('#')) { continue }
                    if ($line -match $rx) { $problems += ('{0} line {1}: {2}' -f $rel, ($i + 1), $line.Trim()) }
                }
            }
            Assert-NoProblems $problems 'Use [System.Collections.Generic.List[object]]::new() instead'
        }

        It 'importing the engine module has no top-level side effects' {
            $path = Join-Path $RepoRoot 'src\LiteOS.Engine.psm1'
            if (-not (Test-Path -LiteralPath $path)) { throw 'src\LiteOS.Engine.psm1 is missing' }
            $r = Get-ParsedAst $path
            if (@($r.Errors).Count -gt 0) { throw 'LiteOS.Engine.psm1 does not parse' }
            $sideEffects = @('New-Item', 'Set-Item', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-Item', 'Remove-ItemProperty',
                'Set-Content', 'Add-Content', 'Out-File', 'Start-Transcript', 'Set-Service', 'Stop-Service', 'Start-Service',
                'reg', 'reg.exe', 'schtasks', 'schtasks.exe', 'powercfg', 'powercfg.exe', 'bcdedit', 'bcdedit.exe', 'dism', 'dism.exe',
                'Initialize-LiteOS', 'Write-LiteOSLog', 'Invoke-LiteOSTweak', 'Invoke-LiteOSPlan', 'New-LiteOSRestorePoint',
                'Restore-LiteOSBackup', 'Checkpoint-Computer', 'Enable-ComputerRestore')
            $problems = @()
            if ($null -eq $r.Ast.EndBlock) { return }
            foreach ($stmt in @($r.Ast.EndBlock.Statements)) {
                if ($stmt -is [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }
                $cmds = $stmt.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
                foreach ($c in $cmds) {
                    # commands inside nested function definitions / script blocks assigned to variables are fine
                    $parent = $c.Parent
                    $insideFunction = $false
                    while ($null -ne $parent -and $parent -ne $stmt) {
                        if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
                            $parent -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $insideFunction = $true; break }
                        $parent = $parent.Parent
                    }
                    if ($insideFunction) { continue }
                    $name = $c.GetCommandName()
                    if ($name -and ($sideEffects -contains $name)) { $problems += ('line {0}: {1} runs at import time' -f $c.Extent.StartLineNumber, $name) }
                }
            }
            Assert-NoProblems $problems 'LiteOS.Engine.psm1 has import-time side effects'
        }
    }

    Context 'Encoding' {

        if ($asciiCases.Count -gt 0) {
            It 'is pure ASCII: <File>' -TestCases $asciiCases {
                param($File, $Path)
                $bytes = [System.IO.File]::ReadAllBytes($Path)
                $line = 1
                $col = 0
                for ($i = 0; $i -lt $bytes.Length; $i++) {
                    $b = $bytes[$i]
                    if ($b -eq 10) { $line++; $col = 0; continue }
                    $col++
                    if ($b -gt 127 -or $b -eq 0) {
                        $what = 'non-ASCII byte 0x{0:X2}' -f $b
                        if ($i -eq 0 -and $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $what = 'UTF-8 BOM' }
                        if ($i -le 1 -and $bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) { $what = 'UTF-16 BOM' }
                        if ($b -eq 0) { $what = 'NUL byte (UTF-16 file?)' }
                        throw ('{0}: {1} at line {2}, column {3}. Windows PowerShell 5.1 reads BOM-less files as ANSI; use plain ASCII (straight quotes, - instead of dashes).' -f $File, $what, $line, $col)
                    }
                }
            }
        }

        if ($jsonCases.Count -gt 0) {
            It 'parses as JSON: <File>' -TestCases $jsonCases {
                param($File, $Path)
                try {
                    $null = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                } catch {
                    $msg = (($_.Exception.Message -split "`r?`n")[0])
                    if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }
                    throw ('{0}: invalid JSON - {1}' -f $File, $msg)
                }
            }
        }
    }

    Context 'Unattend safety' {

        It 'builder\autounattend.xml is well-formed XML' {
            $path = Join-Path $RepoRoot 'builder\autounattend.xml'
            if (-not (Test-Path -LiteralPath $path)) { throw 'builder\autounattend.xml is missing' }
            try {
                $doc = New-Object System.Xml.XmlDocument
                $doc.XmlResolver = $null
                $doc.Load($path)
            } catch {
                throw ('autounattend.xml is not well-formed: {0}' -f $_.Exception.Message)
            }
        }

        It 'never configures, wipes or auto-selects disks or partitions' {
            $path = Join-Path $RepoRoot 'builder\autounattend.xml'
            $doc = New-Object System.Xml.XmlDocument
            $doc.XmlResolver = $null
            $doc.Load($path)
            $problems = @()
            foreach ($el in @('DiskConfiguration', 'Disk', 'CreatePartitions', 'CreatePartition', 'ModifyPartitions', 'ModifyPartition',
                    'WillWipeDisk', 'InstallTo', 'InstallToAvailablePartition')) {
                $nodes = $doc.SelectNodes("//*[local-name()='$el']")
                if ($null -ne $nodes -and $nodes.Count -gt 0) { $problems += "contains <$el> ($($nodes.Count)x)" }
            }
            $text = (Get-Content -LiteralPath $path -Raw) -replace '(?s)<!--.*?-->', ''
            if ($text -match '(?i)diskpart|clean\s+all|format(\.com)?\s+[a-z]:') { $problems += 'contains disk wiping commands' }
            Assert-NoProblems $problems 'autounattend.xml must leave disk selection to the user'
        }

        It 'has no product key: only an empty ProductKey/Key in windowsPE UserData' {
            $path = Join-Path $RepoRoot 'builder\autounattend.xml'
            $doc = New-Object System.Xml.XmlDocument
            $doc.XmlResolver = $null
            $doc.Load($path)
            $problems = @()
            foreach ($pk in @($doc.SelectNodes("//*[local-name()='ProductKey']"))) {
                $ud = $pk.ParentNode
                $comp = $ud.ParentNode
                $pass = $comp.ParentNode
                if ($ud.LocalName -ne 'UserData' -or $comp.LocalName -ne 'component' -or $comp.GetAttribute('name') -ne 'Microsoft-Windows-Setup' -or
                    $pass.LocalName -ne 'settings' -or $pass.GetAttribute('pass') -ne 'windowsPE') {
                    $problems += 'ProductKey outside windowsPE / Microsoft-Windows-Setup / UserData'
                }
                if (-not [string]::IsNullOrWhiteSpace($pk.InnerText)) { $problems += ("ProductKey is not empty: '{0}'" -f $pk.InnerText.Trim()) }
            }
            foreach ($el in @('LocalAccounts', 'AutoLogon', 'AdministratorPassword')) {
                if ($doc.SelectNodes("//*[local-name()='$el']").Count -gt 0) { $problems += "contains <$el>" }
            }
            Assert-NoProblems $problems 'autounattend.xml must not contain keys or accounts'
        }

        It 'runs the playbook on first logon' {
            $text = (Get-Content -LiteralPath (Join-Path $RepoRoot 'builder\autounattend.xml') -Raw) -replace '(?s)<!--.*?-->', ''
            if ($text -notmatch '(?i)FirstLogonCommands') { throw 'autounattend.xml has no FirstLogonCommands' }
            if ($text -notmatch '(?i)LiteOS\.ps1[^<]*-FirstLogon') { throw 'FirstLogonCommands must run LiteOS.ps1 -FirstLogon' }
        }
    }

    Context 'Distribution rules' {

        It 'no file contains a product key' {
            $problems = @()
            foreach ($f in (Get-RepoFiles)) {
                if ($f.Length -gt 5MB) { continue }
                $text = [System.IO.File]::ReadAllText($f.FullName)
                $m = [regex]::Match($text, $ProductKeyPattern)
                if ($m.Success) {
                    $lineNo = ($text.Substring(0, $m.Index) -split "`n").Count
                    $problems += ('{0} line {1}: looks like a product key' -f (Get-RelPath $f.FullName), $lineNo)
                }
            }
            Assert-NoProblems $problems 'Product keys must never be shipped'
        }

        It 'ships no Windows binaries or images' {
            $binary = @('.exe', '.dll', '.sys', '.msi', '.msu', '.cab', '.wim', '.esd', '.swm', '.iso', '.img', '.vhd', '.vhdx',
                '.appx', '.appxbundle', '.msix', '.msixbundle', '.efi', '.mui', '.ocx', '.cat')
            $found = @(Get-RepoFiles $binary | ForEach-Object { Get-RelPath $_.FullName })
            if ($found.Count -gt 0) { throw ('Binary payloads are not allowed in the repo: ' + ($found -join ', ')) }
        }

        It 'contains no activation tooling' {
            # patterns are assembled from pieces so this test file does not match itself
            $patterns = @(('sl' + 'mgr'), ('ospp' + '\.vbs'), ('mass' + 'grave'), ('KMS' + '_?VL'), ('HWID' + '_?Activation'),
                ('get' + '\.activated'), ('/sk' + 'ms\b'), ('/at' + 'o\b'), ('/ip' + 'k\b'), ('TS' + 'forge'), ('oh' + 'ook'))
            $rx = '(?i)(' + ($patterns -join '|') + ')'
            $problems = @()
            foreach ($f in (Get-RepoFiles @('.ps1', '.psm1', '.psd1', '.cmd', '.bat', '.json', '.xml'))) {
                $text = [System.IO.File]::ReadAllText($f.FullName)
                $m = [regex]::Match($text, $rx)
                if ($m.Success) { $problems += ('{0}: contains "{1}"' -f (Get-RelPath $f.FullName), $m.Value) }
            }
            Assert-NoProblems $problems 'Lite OS never activates Windows - bring your own license'
        }
    }
}

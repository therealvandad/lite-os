<#
    Lite OS - builder script tests: download sources, the Media Creation Tool catalog (ESD route),
    the read-only image verifier and the parameter contracts between the GUI, Build-LiteOS.ps1,
    Get-WindowsIso.ps1, Test-LiteOSImage.ps1 and build-test.yml.

    Static and pure. Functions are copied out of the scripts' syntax trees into dynamic modules, so
    no script body ever runs: nothing is downloaded, mounted, attached or written. Catalog data is
    an inline sample products.xml.

    Compatible with Pester 3.4 (built into Windows) and Pester 5.x (CI): plain "throw" assertions,
    BeforeAll inside Describe, no -TestCases.

    Run:  Invoke-Pester -Path .\tests
#>

Describe 'Lite OS builder scripts' {

    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $GetIsoPath = Join-Path $RepoRoot 'builder\Get-WindowsIso.ps1'
        $BuildPath = Join-Path $RepoRoot 'builder\Build-LiteOS.ps1'
        $VerifyPath = Join-Path $RepoRoot 'builder\Test-LiteOSImage.ps1'
        $GuiPath = Join-Path $RepoRoot 'LiteOS-Builder.ps1'
        $WorkflowPath = Join-Path $RepoRoot '.github\workflows\build-test.yml'

        function Assert-NoProblems {
            param([object[]]$Problems, [string]$Title)
            $list = @($Problems | Where-Object { $_ })
            if ($list.Count -gt 0) {
                throw ("{0} ({1}):`n  - {2}" -f $Title, $list.Count, ($list -join "`n  - "))
            }
        }

        function Get-ScriptAst {
            param([string]$Path)
            if (-not (Test-Path -LiteralPath $Path)) { throw ('{0} is missing' -f $Path) }
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
            if (@($errors).Count -gt 0) { throw ('{0} does not parse' -f (Split-Path -Leaf $Path)) }
            return $ast
        }

        function New-ScriptFunctionModule {
            # Copies the named top-level functions and $script: assignments of a script into a dynamic
            # module (the script itself never runs). Call them with: & $Module { ... }
            param([string]$Path, [string[]]$Functions, [string[]]$Variables = @())
            $ast = Get-ScriptAst $Path
            $parts = New-Object System.Collections.Generic.List[string]
            $found = @{}
            foreach ($st in @($ast.EndBlock.Statements)) {
                if ($st -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    if ($Functions -contains $st.Name) { $parts.Add($st.Extent.Text); $found[$st.Name] = $true }
                    continue
                }
                if ($st -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $st.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    $vn = [string]$st.Left.VariablePath.UserPath
                    if ($Variables -contains $vn) { $parts.Add($st.Extent.Text); $found[$vn] = $true }
                }
            }
            $missing = @(@($Functions) + @($Variables) | Where-Object { $_ -and -not $found.ContainsKey($_) })
            if ($missing.Count -gt 0) { throw ('not found at the top level of {0}: {1}' -f (Split-Path -Leaf $Path), ($missing -join ', ')) }
            $code = "Set-StrictMode -Version 2.0`n" + ($parts.ToArray() -join "`n`n") + "`nExport-ModuleMember -Function *"
            return (New-Module -Name ('LiteOSTest_' + [guid]::NewGuid().ToString('N')) -ScriptBlock ([scriptblock]::Create($code)))
        }

        function Get-ScriptParamInfo {
            # name -> ValidateSet values (string[]) or $null, from the script's param block.
            param([string]$Path)
            $ast = Get-ScriptAst $Path
            $result = @{}
            if ($null -eq $ast.ParamBlock) { return $result }
            foreach ($prm in @($ast.ParamBlock.Parameters)) {
                $set = $null
                foreach ($at in @($prm.Attributes)) {
                    if ($at -is [System.Management.Automation.Language.AttributeAst] -and $at.TypeName.Name -match '^ValidateSet$') {
                        $set = @(@($at.PositionalArguments) | ForEach-Object { [string]$_.SafeGetValue() })
                    }
                }
                $result[[string]$prm.Name.VariablePath.UserPath] = $set
            }
            return $result
        }

        function Get-FunctionSwitches {
            # '-Name' string constants used inside one function (the arguments it builds for a child script).
            param([string]$Path, [string]$Function)
            $ast = Get-ScriptAst $Path
            $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Function }, $true)
            if ($null -eq $fn) { throw ('{0} has no function {1}' -f (Split-Path -Leaf $Path), $Function) }
            $names = @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
                    ForEach-Object { [string]$_.Value } | Where-Object { $_ -match '^-[A-Za-z][A-Za-z0-9]*$' } | ForEach-Object { $_.Substring(1) } | Select-Object -Unique)
            return $names
        }

        function Get-WorkflowSwitches {
            # The -Switches passed to "-File <Script>" in build-test.yml (up to the 2>&1 redirect).
            param([string]$Text, [string]$Script)
            $call = '-File ' + $Script
            $i = $Text.IndexOf($call)
            if ($i -lt 0) { throw ('build-test.yml does not run {0}' -f $call) }
            $end = $Text.IndexOf('2>&1', $i)
            if ($end -lt 0) { $end = [Math]::Min($Text.Length, $i + 600) }
            $chunk = $Text.Substring($i + $call.Length, $end - $i - $call.Length)
            return @([regex]::Matches($chunk, '(?<=\s)-([A-Za-z][A-Za-z0-9]*)\b') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        }

        # A small products.xml in the Media Creation Tool catalog format (catalog 2.1 uses <Sha256>,
        # older catalogs <Sha1>). Hashes and links are made up but shaped like the real ones.
        $h64a = ('a' * 64); $h64b = ('b' * 64); $h64c = ('c' * 64); $h64d = ('d' * 64); $h64e = ('e' * 64); $h64f = ('f' * 64)
        $h40 = ('1' * 40)
        $dl = 'http://dl.delivery.mp.microsoft.com/filestreamingservice/files/00000000-0000-0000-0000-000000000000/'
        $rel = '26300.9457.260913-1737.26h2_ge_release_svc_refresh_'
        $old = '26100.4349.250607-1500.ge_release_svc_refresh_'
        $fileXml = {
            param([string]$Name, [string]$Code, [string]$Lang, [string]$Edition, [string]$Arch, [string]$HashTag, [string]$Hash, [string]$Url)
            if (-not $Url) { $Url = $dl + $Name }
            return ('<File id=""><FileName>{0}</FileName><LanguageCode>{1}</LanguageCode><Language>{2}</Language><Edition>{3}</Edition><Architecture>{4}</Architecture><Size>6205178813</Size><{5}>{6}</{5}><FilePath>{7}</FilePath><Key /></File>' -f $Name, $Code, $Lang, $Edition, $Arch, $HashTag, $Hash, $Url)
        }
        $files = @(
            (& $fileXml ($rel + 'CLIENTCONSUMER_RET_x64FRE_en-us.esd') 'en-us' 'English (United States)' 'Professional' 'x64' 'Sha256' $h64a),
            (& $fileXml ($rel + 'CLIENTCONSUMER_RET_x64FRE_en-us.esd') 'en-us' 'English (United States)' 'ProfessionalN' 'x64' 'Sha256' $h64a),
            (& $fileXml ($old + 'CLIENTCONSUMER_RET_x64FRE_en-us.esd') 'en-us' 'English (United States)' 'Professional' 'x64' 'Sha1' $h40),
            (& $fileXml ($rel + 'CLIENTCONSUMER_RET_x64FRE_en-gb.esd') 'en-gb' 'English (United Kingdom)' 'Professional' 'x64' 'Sha256' $h64b),
            (& $fileXml ($rel + 'CLIENTCONSUMER_RET_x64FRE_de-de.esd') 'de-de' 'German (Germany)' 'Professional' 'x64' 'Sha256' $h64c),
            (& $fileXml ($rel + 'CLIENTCONSUMER_RET_A64FRE_de-de.esd') 'de-de' 'German (Germany)' 'Professional' 'ARM64' 'Sha256' $h64d),
            (& $fileXml ($rel + 'CLIENTCONSUMER_RET_x64FRE_pt-br.esd') 'pt-br' 'Portuguese (Brazil)' 'Professional' 'x64' 'Sha256' $h64e),
            (& $fileXml ($rel + 'CLIENTCONSUMER_RET_x64FRE_nb-no.esd') 'nb-no' ('Norwegian Bokm' + [char]0x00E5 + 'l (Norway)') 'Professional' 'x64' 'Sha256' $h64f),
            (& $fileXml ($rel + 'CLIENTCHINA_RET_x64FRE_zh-cn.esd') 'zh-cn' 'Chinese (China)' 'CoreCountrySpecific' 'x64' 'Sha256' $h64a),
            (& $fileXml ('22631.2861.231204-0538.23h2_ni_release_svc_refresh_CLIENTCONSUMER_RET_x64FRE_fr-fr.esd') 'fr-fr' 'French (France)' 'Professional' 'x64' 'Sha256' $h64b),
            (& $fileXml ($rel + 'CLIENTCONSUMER_RET_x64FRE_it-it.esd') 'it-it' 'Italian (Italy)' 'Professional' 'x64' 'Sha256' $h64c ('http://dl.delivery.example.com/' + $rel + 'CLIENTCONSUMER_RET_x64FRE_it-it.esd')),
            (& $fileXml ($rel + 'CLIENTCONSUMER_RET_x64FRE_es-es.esd') 'es-es' 'Spanish (Spain)' 'Professional' 'x64' 'Sha256' 'not-a-hash'),
            (& $fileXml '..\evil.esd' 'ja-jp' 'Japanese (Japan)' 'Professional' 'x64' 'Sha256' $h64d)
        )
        $SampleCatalogXml = '<?xml version="1.0" encoding="UTF-8"?><MCT><Catalogs><Catalog version="2.1"><PublishedMedia id="" release=""><Files>' + ($files -join '') + '</Files></PublishedMedia></Catalog></Catalogs></MCT>'

        $GetIsoModule = New-ScriptFunctionModule -Path $GetIsoPath -Functions @(
            'Get-IsoProp', 'ConvertTo-IsoAscii', 'Test-EsdOfficialUrl', 'Get-EsdXmlText', 'ConvertFrom-EsdCatalog',
            'Get-EsdCandidates', 'Get-EsdLanguages', 'Resolve-EsdLanguageCode', 'Select-EsdFile', 'Test-EsdLayout',
            'Get-EsdVolumeLabel') -Variables @('script:EsdLanguageCodes', 'script:EsdMinBuild')
        $VerifyModule = New-ScriptFunctionModule -Path $VerifyPath -Functions @(
            'Get-Prop', 'Test-Prop', 'Test-IdMatch', 'Test-LikeAny', 'Get-ServiceStartText', 'Get-BackupServiceNames',
            'Get-BackupTweakIds', 'Get-DeferredActions', 'Test-DeferredService')
        $GuiModule = New-ScriptFunctionModule -Path $GuiPath -Functions @('Get-GuiDownloadNeed') -Variables @(
            'script:WorkNeededBytes', 'script:IsoNeededBytes', 'script:EsdPeakBytes', 'script:EsdIsoBytes')
    }

    Context 'Get-WindowsIso.ps1: Media Creation Tool catalog (ESD route)' {

        It 'parses products.xml: one entry per ESD file, editions merged, build / hash / link read' {
            $r = & $GetIsoModule {
                param([string]$XmlText)
                $doc = New-Object System.Xml.XmlDocument
                $doc.XmlResolver = $null
                $doc.LoadXml($XmlText)
                # the function returns one array object (return , $list): assign it, do not wrap it in @()
                $entries = ConvertFrom-EsdCatalog -Xml $doc
                , $entries
            } $SampleCatalogXml
            $entries = @($r)
            $problems = @()
            # 13 <File> nodes: the duplicate en-us 26300 file merges, the "..\evil.esd" name is dropped.
            if ($entries.Count -ne 11) { $problems += ('expected 11 entries, got {0}' -f $entries.Count) }
            $us = @($entries | Where-Object { $_.LanguageCode -eq 'en-us' -and $_.Build -eq 26300 })
            if ($us.Count -ne 1) { $problems += 'the en-us 26300 ESD is not exactly one entry' }
            else {
                if (@($us[0].Editions) -join ',' -ne 'Professional,ProfessionalN') { $problems += ('editions not merged: {0}' -f (@($us[0].Editions) -join ',')) }
                if ($us[0].Ubr -ne 9457) { $problems += ('UBR {0}, expected 9457' -f $us[0].Ubr) }
                if ($us[0].HashAlgorithm -ne 'SHA256' -or $us[0].Hash -ne ('a' * 64)) { $problems += 'SHA-256 not read' }
                if ($us[0].Size -ne 6205178813) { $problems += 'size not read as int64' }
                if ($us[0].Url -notmatch '^http://dl\.delivery\.mp\.microsoft\.com/') { $problems += 'link not read' }
            }
            $old = @($entries | Where-Object { $_.LanguageCode -eq 'en-us' -and $_.Build -eq 26100 })
            if ($old.Count -ne 1 -or $old[0].HashAlgorithm -ne 'SHA1') { $problems += 'an older catalog entry with <Sha1> is not read as SHA1' }
            $nb = @($entries | Where-Object { $_.LanguageCode -eq 'nb-no' })
            if ($nb.Count -ne 1 -or $nb[0].Language -ne 'Norwegian Bokmal (Norway)') { $problems += 'catalog language names are not turned into plain ASCII' }
            if (@($entries | Where-Object { $_.FileName -match '\\|/|\.\.' }).Count -gt 0) { $problems += 'a file name with a path was accepted' }
            $es = @($entries | Where-Object { $_.LanguageCode -eq 'es-es' })
            if ($es.Count -ne 1 -or $es[0].Hash -ne '' -or $es[0].HashAlgorithm -ne '') { $problems += 'a malformed hash was not dropped' }
            Assert-NoProblems $problems 'ConvertFrom-EsdCatalog'
        }

        It 'keeps only released x64 consumer images of 24H2+ with a hash and a Microsoft link' {
            $r = & $GetIsoModule {
                param([string]$XmlText)
                $doc = New-Object System.Xml.XmlDocument
                $doc.XmlResolver = $null
                $doc.LoadXml($XmlText)
                $cands = Get-EsdCandidates -Entries (ConvertFrom-EsdCatalog -Xml $doc)
                , $cands
            } $SampleCatalogXml
            $codes = @(@($r) | ForEach-Object { '{0}/{1}' -f $_.LanguageCode, $_.Build } | Sort-Object)
            $want = @('de-de/26300', 'en-gb/26300', 'en-us/26100', 'en-us/26300', 'nb-no/26300', 'pt-br/26300')
            if (($codes -join ' ') -ne ($want -join ' ')) {
                throw ('candidates [{0}], expected [{1}] (ARM64, CLIENTCHINA, 23H2, non-Microsoft link and no-hash entries must be dropped)' -f ($codes -join ' '), ($want -join ' '))
            }
        }

        It 'picks the newest build for a language given as page name, culture code or catalog name' {
            $r = & $GetIsoModule {
                param([string]$XmlText)
                $doc = New-Object System.Xml.XmlDocument
                $doc.XmlResolver = $null
                $doc.LoadXml($XmlText)
                $entries = ConvertFrom-EsdCatalog -Xml $doc
                $out = @{}
                foreach ($l in @('English (United States)', 'en-US', 'English', 'English International', 'en-GB', 'German', 'de-DE', 'German (Germany)',
                        'Brazilian Portuguese', 'pt-BR', 'Norwegian', 'Norwegian Bokmal (Norway)', '')) {
                    $p = Select-EsdFile -Entries $entries -Language $l
                    $out[$l] = ('{0}/{1}' -f $p.LanguageCode, $p.Build)
                }
                $out
            } $SampleCatalogXml
            $want = [ordered]@{
                'English (United States)' = 'en-us/26300'; 'en-US' = 'en-us/26300'; 'English' = 'en-us/26300'; '' = 'en-us/26300'
                'English International' = 'en-gb/26300'; 'en-GB' = 'en-gb/26300'
                'German' = 'de-de/26300'; 'de-DE' = 'de-de/26300'; 'German (Germany)' = 'de-de/26300'
                'Brazilian Portuguese' = 'pt-br/26300'; 'pt-BR' = 'pt-br/26300'
                'Norwegian' = 'nb-no/26300'; 'Norwegian Bokmal (Norway)' = 'nb-no/26300'
            }
            $problems = @()
            foreach ($k in @($want.Keys)) {
                if ([string]$r[$k] -ne [string]$want[$k]) { $problems += ("'{0}' -> {1}, expected {2}" -f $k, $r[$k], $want[$k]) }
            }
            Assert-NoProblems $problems 'Select-EsdFile language choice'
        }

        It 'refuses a language the catalog does not have, and a catalog without consumer images' {
            $r = & $GetIsoModule {
                param([string]$XmlText)
                $doc = New-Object System.Xml.XmlDocument
                $doc.XmlResolver = $null
                $doc.LoadXml($XmlText)
                $entries = ConvertFrom-EsdCatalog -Xml $doc
                $res = @{ Missing = ''; Empty = '' }
                try { $null = Select-EsdFile -Entries $entries -Language 'Japanese' } catch { $res.Missing = $_.Exception.Message }
                try { $null = Select-EsdFile -Entries @() -Language 'English' } catch { $res.Empty = $_.Exception.Message }
                $res
            } $SampleCatalogXml
            if ($r.Missing -notmatch 'not in it') { throw ('a missing language must throw a clear error, got: {0}' -f $r.Missing) }
            if ($r.Empty -notmatch 'CLIENTCONSUMER_RET') { throw ('an empty catalog must throw a clear error, got: {0}' -f $r.Empty) }
        }

        It 'maps every GUI language to its own Media Creation Tool language code' {
            $guiAst = Get-ScriptAst $GuiPath
            $assign = $guiAst.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Left.VariablePath.UserPath -eq 'script:IsoLanguages' }, $true)
            if ($null -eq $assign) { throw 'LiteOS-Builder.ps1 has no $script:IsoLanguages list' }
            $names = @($assign.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { [string]$_.Value })
            if ($names.Count -lt 30) { throw ('only {0} GUI languages found' -f $names.Count) }
            $r = & $GetIsoModule {
                param([string[]]$Names)
                # every code the alias table knows, as a full catalog would list them
                $avail = @(@($script:EsdLanguageCodes.Values) | Select-Object -Unique | ForEach-Object { [pscustomobject]@{ Code = $_; Name = $_ } })
                $map = [ordered]@{}
                foreach ($n in $Names) { $map[$n] = Resolve-EsdLanguageCode -Language $n -Available $avail }
                $map
            } $names
            $problems = @()
            $seen = @{}
            foreach ($n in $names) {
                $c = $r[$n]
                if (-not $c) { $problems += ("'{0}' maps to no catalog code" -f $n); continue }
                if ($seen.ContainsKey($c)) { $problems += ("'{0}' and '{1}' both map to {2}" -f $seen[$c], $n, $c) } else { $seen[$c] = $n }
            }
            Assert-NoProblems $problems 'GUI language -> ESD language code'
        }

        It 'accepts only Microsoft hosts for catalog and ESD links' {
            $r = & $GetIsoModule {
                $urls = [ordered]@{
                    'http://dl.delivery.mp.microsoft.com/filestreamingservice/files/x/a.esd' = $true
                    'https://download.microsoft.com/download/a/products.cab'                 = $true
                    'https://microsoft.com/x'                                                = $true
                    'http://dl.delivery.mp.microsoft.com.evil.example/a.esd'                 = $false
                    'http://evilmicrosoft.com/a.esd'                                         = $false
                    'ftp://dl.delivery.mp.microsoft.com/a.esd'                               = $false
                    'file://C:/a.esd'                                                        = $false
                    'not a url'                                                              = $false
                    ''                                                                       = $false
                }
                $bad = @()
                foreach ($u in @($urls.Keys)) { if ([bool](Test-EsdOfficialUrl $u) -ne [bool]$urls[$u]) { $bad += $u } }
                , $bad
            }
            if (@($r).Count -gt 0) { throw ('wrong verdict for: ' + (@($r) -join ' | ')) }
        }

        It 'checks the ESD image layout and names the ISO volume like Microsoft' {
            $r = & $GetIsoModule {
                $good = @(
                    [pscustomobject]@{ Index = 1; Name = 'Windows Setup Media' },
                    [pscustomobject]@{ Index = 2; Name = 'Microsoft Windows PE (amd64)' },
                    [pscustomobject]@{ Index = 3; Name = 'Microsoft Windows Setup (amd64)' },
                    [pscustomobject]@{ Index = 4; Name = 'Windows 11 Home' },
                    [pscustomobject]@{ Index = 5; Name = 'Windows 11 Pro' })
                $short = @($good[0], $good[1], $good[2])
                $wrong = @([pscustomobject]@{ Index = 1; Name = 'Windows 11 Pro' }, $good[1], $good[2], $good[3])
                @{ Good = (Test-EsdLayout -Images $good); Short = (Test-EsdLayout -Images $short); Wrong = (Test-EsdLayout -Images $wrong)
                    Label = (Get-EsdVolumeLabel 'en-us'); LabelSr = (Get-EsdVolumeLabel 'sr-latn-rs'); LabelNone = (Get-EsdVolumeLabel '') }
            }
            $problems = @()
            if ($r.Good -ne '') { $problems += ('a Media Creation Tool layout was refused: {0}' -f $r.Good) }
            if (-not $r.Short) { $problems += 'an ESD with only 3 images was accepted' }
            if (-not $r.Wrong) { $problems += 'an ESD whose image 1 is not Windows Setup Media was accepted' }
            if ($r.Label -ne 'CCCOMA_X64FRE_EN-US_DV9') { $problems += ('volume label {0}' -f $r.Label) }
            if ($r.LabelSr -ne 'CCCOMA_X64FRE_SR-LATN-RS_DV9') { $problems += ('volume label {0}' -f $r.LabelSr) }
            if ($r.LabelNone -ne 'CCCOMA_X64FRE_EN-US_DV9') { $problems += ('default volume label {0}' -f $r.LabelNone) }
            Assert-NoProblems $problems 'ESD layout / volume label'
        }
    }

    Context 'Download source contract (GUI -> Build-LiteOS.ps1 -> Get-WindowsIso.ps1 -> CI)' {

        It 'every script offers the same download sources: Auto, Website, Esd' {
            $want = 'Auto,Website,Esd'
            $problems = @()
            $iso = Get-ScriptParamInfo $GetIsoPath
            if (-not $iso.ContainsKey('Source')) { $problems += 'Get-WindowsIso.ps1 has no -Source' }
            elseif ((@($iso['Source']) -join ',') -ne $want) { $problems += ('Get-WindowsIso.ps1 -Source offers {0}' -f (@($iso['Source']) -join ',')) }
            $build = Get-ScriptParamInfo $BuildPath
            if (-not $build.ContainsKey('DownloadSource')) { $problems += 'Build-LiteOS.ps1 has no -DownloadSource' }
            elseif ((@($build['DownloadSource']) -join ',') -ne $want) { $problems += ('Build-LiteOS.ps1 -DownloadSource offers {0}' -f (@($build['DownloadSource']) -join ',')) }
            $gui = Get-ScriptParamInfo $GuiPath
            if (-not $gui.ContainsKey('DownloadSource')) { $problems += 'LiteOS-Builder.ps1 has no -DownloadSource' }
            elseif ((@($gui['DownloadSource']) -join ',') -ne $want) { $problems += ('LiteOS-Builder.ps1 -DownloadSource offers {0}' -f (@($gui['DownloadSource']) -join ',')) }
            # the GUI dropdown values
            $guiAst = Get-ScriptAst $GuiPath
            $assign = $guiAst.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Left.VariablePath.UserPath -eq 'script:DownloadSources' }, $true)
            if ($null -eq $assign) { $problems += 'LiteOS-Builder.ps1 has no $script:DownloadSources list' }
            else {
                $values = @($assign.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) | ForEach-Object {
                        foreach ($kv in $_.KeyValuePairs) { if ([string]$kv.Item1.SafeGetValue() -eq 'Value') { [string]$kv.Item2.Extent.Text.Trim("'", '"', ' ') } } })
                if (($values -join ',') -ne $want) { $problems += ('GUI dropdown values {0}' -f ($values -join ',')) }
            }
            # the workflow_dispatch choice
            $yml = [System.IO.File]::ReadAllText($WorkflowPath)
            $m = [regex]::Match($yml, '(?ms)download_source:.*?options:\s*\n((?:\s+-\s+\S+\s*\n)+)')
            if (-not $m.Success) { $problems += 'build-test.yml has no download_source choice input' }
            else {
                $opts = @([regex]::Matches($m.Groups[1].Value, '-\s+(\S+)') | ForEach-Object { $_.Groups[1].Value })
                if (($opts -join ',') -ne $want) { $problems += ('build-test.yml download_source options {0}' -f ($opts -join ',')) }
            }
            Assert-NoProblems $problems 'Download source values differ'
        }

        It 'the GUI only passes parameters the child scripts declare' {
            $problems = @()
            $build = Get-ScriptParamInfo $BuildPath
            foreach ($s in @(Get-FunctionSwitches -Path $GuiPath -Function 'Get-GuiBuildArgs')) {
                if (-not $build.ContainsKey($s)) { $problems += ('Get-GuiBuildArgs passes -{0}, which Build-LiteOS.ps1 does not declare' -f $s) }
            }
            $iso = Get-ScriptParamInfo $GetIsoPath
            foreach ($s in @(Get-FunctionSwitches -Path $GuiPath -Function 'Get-GuiDownloadArgs')) {
                if (-not $iso.ContainsKey($s)) { $problems += ('Get-GuiDownloadArgs passes -{0}, which Get-WindowsIso.ps1 does not declare' -f $s) }
            }
            Assert-NoProblems $problems 'GUI -> script parameter mismatch'
        }

        It 'Build-LiteOS.ps1 only splats parameters Get-WindowsIso.ps1 declares' {
            $ast = Get-ScriptAst $BuildPath
            $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-WindowsIsoDownload' }, $true)
            if ($null -eq $fn) { throw 'Build-LiteOS.ps1 has no Invoke-WindowsIsoDownload' }
            $keys = New-Object System.Collections.Generic.List[string]
            foreach ($ix in @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.IndexExpressionAst] -and
                            $n.Target -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Target.VariablePath.UserPath -eq 'splat' }, $true))) {
                if ($ix.Index -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $keys.Add([string]$ix.Index.Value) }
            }
            foreach ($ht in @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                            $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -eq 'splat' }, $true))) {
                foreach ($h in @($ht.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true))) {
                    foreach ($kv in $h.KeyValuePairs) { $keys.Add([string]$kv.Item1.SafeGetValue()) }
                }
            }
            if ($keys.Count -lt 3) { throw ('could not read the splat keys of Invoke-WindowsIsoDownload ({0})' -f ($keys -join ',')) }
            $iso = Get-ScriptParamInfo $GetIsoPath
            $missing = @($keys | Select-Object -Unique | Where-Object { -not $iso.ContainsKey($_) })
            if ($missing.Count -gt 0) { throw ('Get-WindowsIso.ps1 does not declare: ' + ($missing -join ', ')) }
        }

        It 'build-test.yml calls Build-LiteOS.ps1 and Test-LiteOSImage.ps1 with declared parameters' {
            $yml = [System.IO.File]::ReadAllText($WorkflowPath)
            $problems = @()
            $build = Get-ScriptParamInfo $BuildPath
            $bs = @(Get-WorkflowSwitches -Text $yml -Script 'builder\Build-LiteOS.ps1')
            foreach ($s in @('Download', 'DownloadSource', 'Mode', 'Yes', 'ProgressProtocol', 'WorkDir', 'OutputPath')) { if ($bs -notcontains $s) { $problems += ('the build step does not pass -{0}' -f $s) } }
            foreach ($s in $bs) { if (-not $build.ContainsKey($s)) { $problems += ('the build step passes -{0}, which Build-LiteOS.ps1 does not declare' -f $s) } }
            $verify = Get-ScriptParamInfo $VerifyPath
            $vs = @(Get-WorkflowSwitches -Text $yml -Script 'builder\Test-LiteOSImage.ps1')
            foreach ($s in @('IsoPath', 'Mode', 'ReportPath')) { if ($vs -notcontains $s) { $problems += ('the verify step does not pass -{0}' -f $s) } }
            foreach ($s in $vs) { if (-not $verify.ContainsKey($s)) { $problems += ('the verify step passes -{0}, which Test-LiteOSImage.ps1 does not declare' -f $s) } }
            Assert-NoProblems $problems 'build-test.yml parameter mismatch'
        }

        It 'the GUI plans the right free space for each download source' {
            $r = & $GuiModule {
                @{ Web = (Get-GuiDownloadNeed -Source 'Website'); Esd = (Get-GuiDownloadNeed -Source 'Esd'); Auto = (Get-GuiDownloadNeed -Source 'Auto'); Work = $script:WorkNeededBytes }
            }
            $problems = @()
            if ([int64]$r.Web.Peak -ne 8GB -or [int64]$r.Web.Keep -ne 8GB -or $r.Web.Esd) { $problems += 'Website: expected 8 GB peak and kept' }
            foreach ($k in @('Esd', 'Auto')) {
                if ([int64]$r[$k].Peak -lt 20GB) { $problems += ('{0}: the ESD route needs about 25 GB while it converts (got {1:N0} GB)' -f $k, ([int64]$r[$k].Peak / 1GB)) }
                if ([int64]$r[$k].Keep -lt 10GB) { $problems += ('{0}: the ISO the ESD route leaves is about 10-12 GB (got {1:N0} GB)' -f $k, ([int64]$r[$k].Keep / 1GB)) }
                if (-not $r[$k].Esd) { $problems += ('{0}: must be planned like the ESD route' -f $k) }
            }
            if ([int64]$r.Work -ne 30GB) { $problems += 'the work drive needs 30 GB like Build-LiteOS.ps1' }
            Assert-NoProblems $problems 'Get-GuiDownloadNeed'
        }
    }

    Context 'Module API contract (engine / image module <- entry scripts)' {

        It 'entry scripts call engine and image module functions that exist, are exported and take those parameters' {
            $common = @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'ErrorVariable', 'WarningVariable', 'OutVariable',
                'OutBuffer', 'PipelineVariable', 'InformationAction', 'InformationVariable', 'WhatIf', 'Confirm')
            $defs = @{}
            foreach ($m in @('src\LiteOS.Engine.psm1', 'builder\LiteOS.Image.psm1')) {
                $ast = Get-ScriptAst (Join-Path $RepoRoot $m)
                $exported = @()
                $em = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Export-ModuleMember' }, $true)
                if ($null -ne $em) { $exported = @($em.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and [string]$n.StringConstantType -ne 'BareWord' }, $true) | ForEach-Object { [string]$_.Value }) }
                foreach ($fn in @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })) {
                    $names = @()
                    $cmdlet = $false
                    if ($null -ne $fn.Body.ParamBlock) {
                        $names = @($fn.Body.ParamBlock.Parameters | ForEach-Object { [string]$_.Name.VariablePath.UserPath })
                        $cmdlet = (@($fn.Body.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }).Count -gt 0)
                    }
                    $defs[$fn.Name] = @{ Params = $names; Cmdlet = $cmdlet; Exported = ($exported -contains $fn.Name); File = $m }
                }
            }
            $problems = @()
            foreach ($s in @('builder\Build-LiteOS.ps1', 'LiteOS.ps1', 'Revert-LiteOS.ps1', 'LiteOS-Builder.ps1', 'src\Install-Apps.ps1')) {
                $ast = Get-ScriptAst (Join-Path $RepoRoot $s)
                $local = @{}
                foreach ($fn in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) { $local[$fn.Name] = $true }
                foreach ($c in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
                    $name = $c.GetCommandName()
                    if (-not $name -or $local.ContainsKey($name) -or -not $defs.ContainsKey($name)) { continue }
                    $d = $defs[$name]
                    $line = $c.Extent.StartLineNumber
                    if (-not $d.Exported) { $problems += ('{0} line {1}: {2} is not exported by {3}' -f $s, $line, $name, $d.File) }
                    foreach ($e in @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] })) {
                        $pn = $e.ParameterName
                        if (@($d.Params | Where-Object { $_ -ieq $pn }).Count -gt 0) { continue }
                        if (@($d.Params | Where-Object { $_ -like ($pn + '*') }).Count -eq 1) { continue }
                        if ($d.Cmdlet -and ($common -contains $pn)) { continue }
                        $problems += ('{0} line {1}: {2} has no -{3} ({4})' -f $s, $line, $name, $pn, ($d.Params -join ', '))
                    }
                }
            }
            Assert-NoProblems $problems 'Engine / image module API mismatch'
        }
    }

    Context 'Test-LiteOSImage.ps1 (read-only image verifier)' {

        It 'only mounts read-only, always discards, and never changes an image or this PC' {
            $ast = Get-ScriptAst $VerifyPath
            $problems = @()
            $forbidden = @('Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Set-Acl', 'Remove-AppxProvisionedPackage',
                'Add-AppxProvisionedPackage', 'Remove-WindowsCapability', 'Add-WindowsCapability', 'Disable-WindowsOptionalFeature',
                'Enable-WindowsOptionalFeature', 'Remove-WindowsPackage', 'Add-WindowsPackage', 'Save-WindowsImage', 'Repair-WindowsImage',
                'Export-WindowsImage', 'Set-Service', 'Stop-Service', 'icacls', 'icacls.exe', 'takeown', 'takeown.exe', 'bcdedit', 'bcdedit.exe',
                'schtasks', 'schtasks.exe', 'dism', 'dism.exe', 'Invoke-LiteOSImageRemovals', 'Invoke-LiteOSOfflinePlan')
            foreach ($c in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
                $name = $c.GetCommandName()
                if (-not $name) { continue }
                $params = @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
                $line = $c.Extent.StartLineNumber
                if ($forbidden -contains $name) { $problems += ('line {0}: {1}' -f $line, $name) }
                if ($name -eq 'Mount-WindowsImage' -and $params -notcontains 'ReadOnly') { $problems += ('line {0}: Mount-WindowsImage without -ReadOnly' -f $line) }
                if ($name -eq 'Dismount-WindowsImage' -and ($params -notcontains 'Discard' -or $params -contains 'Save')) { $problems += ('line {0}: Dismount-WindowsImage must use -Discard (never -Save)' -f $line) }
                if ($name -eq 'Mount-DiskImage') {
                    $text = $c.Extent.Text
                    if ($text -notmatch '(?i)-Access\s+ReadOnly') { $problems += ('line {0}: Mount-DiskImage without -Access ReadOnly' -f $line) }
                }
            }
            # reg.exe is only used for query / load / unload, and only on the LITE_VERIFY_* hive copies.
            foreach ($s in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                            [string]$n.StringConstantType -ne 'BareWord' }, $true))) {
                $v = [string]$s.Value
                if (@('add', 'delete', 'import', 'restore', 'copy', 'save') -contains $v.ToLowerInvariant()) { $problems += ("line {0}: reg verb '{1}'" -f $s.Extent.StartLineNumber, $v) }
                if ($v -match 'LITE_(?!VERIFY_)') { $problems += ("line {0}: '{1}' names a hive other than LITE_VERIFY_*" -f $s.Extent.StartLineNumber, $v) }
            }
            Assert-NoProblems $problems 'Test-LiteOSImage.ps1 must stay read-only'
        }

        It 'reads deferred.json and backup-image.json the way the builder writes them' {
            $r = & $VerifyModule {
                $deferred = [pscustomobject]@{ tweaks = @(
                        [pscustomobject]@{ id = 'image.windows-update'; actions = @(
                                [pscustomobject]@{ type = 'service'; name = 'wuauserv'; startup = 'Disabled'; stop = $false },
                                [pscustomobject]@{ type = 'registry'; path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; name = 'NoAutoUpdate'; kind = 'DWord'; value = 1 }) },
                        [pscustomobject]@{ id = 'image.defender'; actions = @(
                                [pscustomobject]@{ type = 'registry'; path = 'HKLM:\SYSTEM\CurrentControlSet\Services\SecurityHealthService'; name = 'Start'; kind = 'DWord'; value = 4 }) },
                        [pscustomobject]@{ id = 'image.winre'; actions = @([pscustomobject]@{ type = 'powershell'; script = 'reagentc /disable'; undo = '' }) }) }
                $backup = [pscustomobject]@{ source = 'image'; entries = @(
                        [pscustomobject]@{ tweakId = 'services.sysmain-off'; hive = 'Machine'; action = [pscustomobject]@{ type = 'service'; name = 'SysMain' } },
                        [pscustomobject]@{ tweakId = 'services.sysmain-off'; hive = 'Machine'; action = [pscustomobject]@{ type = 'service'; name = 'sysmain' } },
                        [pscustomobject]@{ tweakId = 'privacy.telemetry-off'; hive = 'Machine'; action = [pscustomobject]@{ type = 'registry'; path = 'HKLM:\SOFTWARE\X'; name = 'Y' } }) }
                $acts = @(Get-DeferredActions -Deferred $deferred)
                @{
                    Count      = $acts.Count
                    Owners     = (@($acts | ForEach-Object { $_.Owner } | Select-Object -Unique) -join ',')
                    Wu         = (Test-DeferredService -Actions $acts -Service 'wuauserv')
                    Shs        = (Test-DeferredService -Actions $acts -Service 'SecurityHealthService')
                    Uso        = (Test-DeferredService -Actions $acts -Service 'UsoSvc')
                    Svcs       = (@(Get-BackupServiceNames -Backup $backup) -join ',')
                    Tweaks     = (@(Get-BackupTweakIds -Backup $backup) -join ',')
                    NoDeferred = @(Get-DeferredActions -Deferred $null).Count
                    Match      = @((Test-IdMatch -Id 'updates.notify-only' -Patterns @('updates.*')), (Test-IdMatch -Id 'updates.notify-only' -Patterns @('updates.notify')), (Test-IdMatch -Id 'image.edge' -Patterns @('image.edge')))
                    Start      = @((Get-ServiceStartText 4 $null), (Get-ServiceStartText 2 1), (Get-ServiceStartText $null $null))
                }
            }
            $problems = @()
            if ($r.Count -ne 4) { $problems += ('expected 4 deferred actions, got {0}' -f $r.Count) }
            if ($r.Owners -ne 'image.windows-update,image.defender,image.winre') { $problems += ('owners {0}' -f $r.Owners) }
            if (-not $r.Wu) { $problems += 'a deferred service action with startup Disabled is not seen' }
            if (-not $r.Shs) { $problems += 'the deferred SecurityHealthService Start=4 registry action is not seen' }
            if ($r.Uso) { $problems += 'UsoSvc is reported as disabled although nothing disables it' }
            if ($r.Svcs -ne 'sysmain') { $problems += ('backup service names {0} (lower-case, unique expected)' -f $r.Svcs) }
            if ($r.Tweaks -ne 'services.sysmain-off,privacy.telemetry-off') { $problems += ('backup tweak ids {0}' -f $r.Tweaks) }
            if ($r.NoDeferred -ne 0) { $problems += 'a missing deferred.json must give no actions' }
            if ((@($r.Match) -join ',') -ne 'True,False,True') { $problems += ('Test-IdMatch {0} (exact or wildcard only)' -f (@($r.Match) -join ',')) }
            if ((@($r.Start) -join '|') -ne '4 (Disabled)|2 (Automatic, delayed)|missing') { $problems += ('Get-ServiceStartText {0}' -f (@($r.Start) -join '|')) }
            Assert-NoProblems $problems 'verifier helpers'
        }

        It 'checks the files and values the builder writes' {
            $verify = [System.IO.File]::ReadAllText($VerifyPath)
            $build = [System.IO.File]::ReadAllText($BuildPath)
            $problems = @()
            # where the builder puts them (Build-LiteOS.ps1) -> where the verifier looks (Test-LiteOSImage.ps1)
            $pairs = [ordered]@{
                'Windows\OEM\TaskbarLayoutModification.xml'                                   = "TaskbarOemPath\s*=\s*'C:\\Windows\\OEM\\TaskbarLayoutModification\.xml'"
                'Users\Default\AppData\Local\Microsoft\Windows\Shell\LayoutModification.json' = "Join-Path\s+\`$shellDir\s+'LayoutModification\.json'"
                'Windows\Setup\Scripts\SetupComplete.cmd'                                     = "Join-Path\s+\`$scriptsDir\s+'SetupComplete\.cmd'"
                'LiteOS\deferred.json'                                                        = "Join-Path\s+\`$payloadDir\s+'deferred\.json'"
                'ProgramData\LiteOS\backup\backup-image.json'                                 = "Join-Path\s+\`$stateDir\s+'backup\\backup-image\.json'"
                'ProgramData\LiteOS\build-info.json'                                          = "Join-Path\s+\`$stateDir\s+'build-info\.json'"
                'ProgramData\LiteOS\config.json'                                              = "Join-Path\s+\`$stateDir\s+'config\.json'"
            }
            foreach ($rel in @($pairs.Keys)) {
                if (-not $verify.Contains($rel)) { $problems += ('Test-LiteOSImage.ps1 does not check {0}' -f $rel) }
                if ($build -notmatch $pairs[$rel]) { $problems += ('Build-LiteOS.ps1 does not write {0} (pattern {1})' -f $rel, $pairs[$rel]) }
            }
            # build-info.json / config.json fields the verifier reads
            foreach ($f in @('removals', 'removalsInclude', 'removalsExclude', 'removedProvisionedApps', 'imageName', 'mode', 'builtAt', 'builder')) {
                if ($verify -notmatch ("'{0}'" -f $f)) { $problems += ('the verifier does not read build-info {0}' -f $f) }
                if ($build -notmatch ('(?m)^\s+{0}\s+=' -f $f)) { $problems += ('Build-LiteOS.ps1 build-info has no {0}' -f $f) }
            }
            if ($build -notmatch "(?m)^\s+level\s+=\s+\`$level" -or $build -notmatch "(?m)^\s+exclude\s+=\s+\[string\[\]\]\`$tweakExclude") { $problems += 'config.json has no level / exclude (the verifier reads both)' }
            if ($build -notmatch "-DestinationName\s+\`$wimName") { $problems += 'the builder does not name the WIM image (the verifier checks "Lite OS <Mode>")' }
            if ($build -notmatch 'LiteOS\.ps1 -SetupComplete') { $problems += 'SetupComplete.cmd does not run LiteOS.ps1 -SetupComplete' }
            Assert-NoProblems $problems 'builder / verifier mismatch'
        }
    }
}

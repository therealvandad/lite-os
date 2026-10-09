<#
.SYNOPSIS
    Downloads the official Windows 11 x64 ISO straight from Microsoft.

.DESCRIPTION
    Get-WindowsIso.ps1 asks Microsoft's public software-download service (the same one the page
    https://www.microsoft.com/software-download/windows11 uses) for a download link to the
    "Windows 11 (multi-edition ISO for x64 devices)" in the language you choose, then downloads it
    with BITS (resumable, retried by Windows) or, if BITS is not available, with a streaming
    HttpClient download that resumes a .part file.

    The flow is the one used by Rufus / Fido (Pete Batard, https://github.com/pbatard/Fido, GPLv3):
      1. product edition id from the download page HTML (fallback: a known id)
      2. a new session id (GUID) whitelisted through vlscppe.microsoft.com/tags and the
         ov-df.microsoft.com mdt.js handshake
      3. getskuinformationbyproductedition -> list of languages (SKUs)
      4. GetProductDownloadLinksBySku (with the download page as Referer) -> official link on
         *.download.prss.microsoft.com, valid for 24 hours
    This file is an independent implementation of those public endpoints; no Fido code is copied.

    Nothing is modified on this PC except the downloaded file, a .part/.bits temp file next to it,
    a temporary BITS job (removed when done or cancelled) and the log file.

    If Microsoft refuses the request (message code 715-123130: blocked country/region, network or
    too many requests), the script explains why, opens the Microsoft download page in your browser
    (unless -NoBrowser or a non-interactive session) and - in an interactive console - lets you type
    the path of the ISO you downloaded yourself (or paste the official link from that page).

    The last object written to the pipeline is the full path of the ISO (or the URL with -UrlOnly).
    Everything else goes to the host and to the log file.

.PARAMETER Language
    ISO language. Accepts Microsoft's names ("English (United States)", "English International",
    "German", "Chinese Simplified", ...), the API names ("English", "English (United Kingdom)") or
    a culture name ("en-US", "de-DE", "pt-BR"). Default: "English (United States)".

.PARAMETER OutFile
    Where to save the ISO. A folder (existing, or ending with \) keeps Microsoft's file name.
    Default: your Downloads folder with Microsoft's file name. An existing valid Windows ISO at that
    path is reused (no download) unless -Force.

.PARAMETER UrlOnly
    Only print the official download URL (valid for 24 hours); do not download.

.PARAMETER ProgressProtocol
    Emit "##LITEOS-PROGRESS <0-100> <message>" lines for the Lite OS Builder GUI. Never prompts.

.PARAMETER ProgressStart
    With -ProgressProtocol: percent reported at the start (lets a caller map the download into a
    part of its own progress range). Default 0.

.PARAMETER ProgressEnd
    With -ProgressProtocol: percent reported when the ISO is ready. Default 100.

.PARAMETER Url
    An official Microsoft download link you copied from the download page in your browser
    (https://...microsoft.com/...). Skips the Microsoft API and downloads that link.

.PARAMETER ListLanguages
    List the languages Microsoft offers for the current Windows 11 release and exit.

.PARAMETER NoBits
    Do not use BITS; download with HttpClient (resumable .part file).

.PARAMETER NoBrowser
    Never open the Microsoft download page in a browser (the GUI shows its own button).

.PARAMETER Force
    Download again even if a valid ISO already exists at -OutFile (it is replaced).

.PARAMETER ProductEditionId
    Override the product edition id (normally read from Microsoft's download page).

.PARAMETER LogPath
    Log file. Default: %TEMP%\LiteOS\Get-WindowsIso-<timestamp>.log

.EXAMPLE
    .\Get-WindowsIso.ps1
    Downloads the English (United States) Windows 11 x64 ISO to your Downloads folder.

.EXAMPLE
    .\Get-WindowsIso.ps1 -Language German -OutFile D:\ISO\
    Downloads the German ISO into D:\ISO with Microsoft's file name.

.EXAMPLE
    .\Get-WindowsIso.ps1 -Language "English International" -UrlOnly
    Prints the official 24-hour download link only.

.NOTES
    Lite OS. Windows PowerShell 5.1 compatible, ASCII only. Uses only Microsoft's official servers.
    Lite OS never hosts, uploads or modifies Windows ISO files and never ships product keys.
#>
[CmdletBinding()]
param(
    [string]$Language = 'English (United States)',

    [string]$OutFile,

    [switch]$UrlOnly,

    [switch]$ProgressProtocol,

    [ValidateRange(0, 100)]
    [int]$ProgressStart = 0,

    [ValidateRange(0, 100)]
    [int]$ProgressEnd = 100,

    [string]$Url,

    [switch]$ListLanguages,

    [switch]$NoBits,

    [switch]$NoBrowser,

    [switch]$Force,

    [int]$ProductEditionId = 0,

    [string]$LogPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------
# Constants (public values used by Microsoft's own download page; see Fido for their history)
# ---------------------------------------------------------------------------------------------
$script:GetIsoVersion     = '2.0.0'
$script:DownloadPage      = 'https://www.microsoft.com/software-download/windows11'
$script:DownloadPageEnUs  = 'https://www.microsoft.com/en-us/software-download/windows11'
$script:ApiBase           = 'https://www.microsoft.com/software-download-connector/api'
$script:ApiLocale         = 'en-US'
$script:ProfileId         = '606624d44113'
$script:OrgId             = 'y6jn8c31'
$script:OvDfInstanceId    = '560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175'
# Windows 11 26H2 (build 26300) "multi-edition ISO for x64 devices", as listed on the page in 2026-10.
$script:FallbackEditionId = 3813
$script:BitsDisplayName   = 'LiteOS-WindowsIso'
$script:MinIsoBytes       = [int64]3GB
$script:HttpTimeoutSec    = 30
$script:StallSeconds      = 600
$script:BlockedCode       = '715-123130'

# ---------------------------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------------------------
$script:LogFile        = $null
$script:LastPct        = -1
$script:LastPctTime    = [DateTime]::MinValue
$script:BlockedText    = $null
$script:PageBlocked    = $false
$script:ErrorShown     = $false
$script:SessionId      = ''
$script:Interactive    = $false
$script:PStart         = $ProgressStart
$script:PEnd           = $ProgressEnd

# Language aliases -> Microsoft's API "Language" value (en-US query locale).
$script:LanguageAliases = @{
    'en-us' = 'English'; 'english (us)' = 'English'; 'english us' = 'English'; 'english (united states)' = 'English'
    'en-gb' = 'English (United Kingdom)'; 'english international' = 'English (United Kingdom)'; 'english (uk)' = 'English (United Kingdom)'
    'pt-br' = 'Brazilian Portuguese'; 'portuguese (brazil)' = 'Brazilian Portuguese'
    'pt-pt' = 'Portuguese'; 'portuguese (portugal)' = 'Portuguese'
    'zh-cn' = 'Chinese (Simplified)'; 'zh-hans' = 'Chinese (Simplified)'; 'chinese simplified' = 'Chinese (Simplified)'
    'zh-tw' = 'Chinese (Traditional)'; 'zh-hant' = 'Chinese (Traditional)'; 'zh-hk' = 'Chinese (Traditional)'; 'chinese traditional' = 'Chinese (Traditional)'
    'fr-ca' = 'French Canadian'; 'french (canada)' = 'French Canadian'
    'es-mx' = 'Spanish (Mexico)'; 'es-419' = 'Spanish (Mexico)'
    'sr-latn' = 'Serbian Latin'; 'sr-latn-rs' = 'Serbian Latin'; 'serbian (latin)' = 'Serbian Latin'
    'nb-no' = 'Norwegian'; 'nb' = 'Norwegian'; 'no' = 'Norwegian'; 'norwegian bokmal' = 'Norwegian'
}

# ---------------------------------------------------------------------------------------------
# Output / logging
# ---------------------------------------------------------------------------------------------
function Write-IsoLog {
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Message,
        [Parameter(Position = 1)][ValidateSet('Info', 'Warn', 'Error', 'Ok')][string]$Level = 'Info'
    )
    $tag = 'INFO '
    $color = 'Gray'
    switch ($Level) {
        'Warn'  { $tag = 'WARN '; $color = 'Yellow' }
        'Error' { $tag = 'ERROR'; $color = 'Red' }
        'Ok'    { $tag = 'OK   '; $color = 'Green' }
    }
    if ($null -ne $script:LogFile) {
        try {
            $line = '{0} [{1}] {2}{3}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $tag, $Message, [Environment]::NewLine
            [System.IO.File]::AppendAllText($script:LogFile, $line, (New-Object System.Text.UTF8Encoding -ArgumentList $false))
        }
        catch { $null = $_ }
    }
    $prefix = '[Windows ISO] '
    if ($Level -eq 'Warn') { $prefix = '[Windows ISO] WARNING: ' }
    elseif ($Level -eq 'Error') { $prefix = '[Windows ISO] ERROR: ' }
    Write-Host ($prefix + $Message) -ForegroundColor $color
}

function Write-IsoProgress {
    # Percent is this script's own 0-100; it is mapped into ProgressStart..ProgressEnd.
    param([double]$Percent, [string]$Message, [switch]$Always)
    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    $mapped = [int][math]::Floor($script:PStart + (($script:PEnd - $script:PStart) * $Percent / 100.0))
    $now = [DateTime]::UtcNow
    if (-not $Always -and $mapped -eq $script:LastPct -and ($now - $script:LastPctTime).TotalSeconds -lt 2) { return }
    $script:LastPct = $mapped
    $script:LastPctTime = $now
    $msg = ([string]$Message -replace '[\r\n]+', ' ').Trim()
    if ($ProgressProtocol) {
        Write-Host ('##LITEOS-PROGRESS {0} {1}' -f $mapped, $msg)
    }
    elseif ($script:Interactive) {
        Write-Progress -Activity 'Windows 11 ISO' -Status $msg -PercentComplete ([int][math]::Floor($Percent))
    }
}

function Format-IsoBytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} bytes' -f $Bytes)
}

function Format-IsoUrlForLog {
    # Download links carry a signed, expiring token: log host + path only.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $q = $Text.IndexOf('?')
    if ($q -gt 0) { return ($Text.Substring(0, $q) + '?...') }
    return $Text
}

function Get-IsoProp {
    # StrictMode-safe property read for PSCustomObjects from ConvertFrom-Json.
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function Test-IsoInteractive {
    if ($ProgressProtocol) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    if ($env:CI -or $env:GITHUB_ACTIONS -or $env:TF_BUILD) { return $false }
    foreach ($a in [Environment]::GetCommandLineArgs()) {
        if ($a -match '^(?i)[-/]noni') { return $false }
    }
    if ($null -eq $Host -or $Host.Name -ne 'ConsoleHost') { return $false }
    return $true
}

function Test-IsoEntryScript {
    # True when this file is the script powershell.exe was started with (-File <this file>).
    $me = ''
    try { $me = [System.IO.Path]::GetFileName([string]$PSCommandPath) } catch { $me = '' }
    if ([string]::IsNullOrEmpty($me)) { return $false }
    $argv = @([Environment]::GetCommandLineArgs())
    for ($i = 1; $i -lt $argv.Count; $i++) {
        if ($argv[$i] -match '^(?i)[-/]f(ile)?$' -and $i + 1 -lt $argv.Count) {
            $f = ''
            try { $f = [System.IO.Path]::GetFileName($argv[$i + 1].Trim('"')) } catch { $f = '' }
            return ($f -ieq $me)
        }
    }
    return $false
}

function Initialize-IsoLog {
    $path = $LogPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        $tmp = [System.IO.Path]::GetTempPath()
        $path = Join-Path (Join-Path $tmp 'LiteOS') ('Get-WindowsIso-{0}.log' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
    }
    try {
        $dir = [System.IO.Path]::GetDirectoryName($path)
        if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
        [System.IO.File]::AppendAllText($path, '', (New-Object System.Text.UTF8Encoding -ArgumentList $false))
        $script:LogFile = $path
    }
    catch {
        $script:LogFile = $null
        Write-Host ('[Windows ISO] WARNING: cannot write log file {0}: {1}' -f $path, $_.Exception.Message) -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------------------------
# Network helpers
# ---------------------------------------------------------------------------------------------
function Initialize-IsoNetwork {
    try {
        $proto = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        if ([enum]::IsDefined([System.Net.SecurityProtocolType], 'Tls13')) {
            $proto = $proto -bor [System.Net.SecurityProtocolType]'Tls13'
        }
        [System.Net.ServicePointManager]::SecurityProtocol = $proto
    }
    catch { Write-IsoLog ('Could not enable TLS 1.2/1.3: {0}' -f $_.Exception.Message) 'Warn' }
    try {
        if ($null -ne [System.Net.WebRequest]::DefaultWebProxy) {
            [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
        }
    }
    catch { $null = $_ }
}

function Invoke-IsoGet {
    # Small GET with retries. Returns @{ Status; Text; Headers }. Throws after the last attempt.
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers,
        [int]$Attempts = 3,
        [switch]$NoRedirect
    )
    $ProgressPreference = 'SilentlyContinue'
    $last = $null
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            $p = @{ Uri = $Uri; UseBasicParsing = $true; TimeoutSec = $script:HttpTimeoutSec; ErrorAction = 'Stop' }
            if ($NoRedirect) { $p['MaximumRedirection'] = 0 }
            if ($null -ne $Headers -and $Headers.Count -gt 0) { $p['Headers'] = $Headers }
            $r = Invoke-WebRequest @p
            $text = ''
            try { $text = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
            catch { $text = [string]$r.Content }
            return @{ Status = [int]$r.StatusCode; Text = $text; Headers = $r.Headers }
        }
        catch {
            $last = $_
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
            # 4xx (except 408/429) will not get better by retrying.
            if ($status -ge 400 -and $status -lt 500 -and $status -ne 408 -and $status -ne 429) { break }
            if ($i -lt $Attempts) { Start-Sleep -Seconds (2 * $i) }
        }
    }
    throw $last
}

function Test-IsoBlockedText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return ($Text -match '(?i)your request has been blocked|715-123130|sentinel')
}

function Test-IsoOfficialUrl {
    # Only https links on Microsoft's own domains are accepted (software.download.prss.microsoft.com etc.).
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $u = $null
    if (-not [System.Uri]::TryCreate($Text.Trim(), [System.UriKind]::Absolute, [ref]$u)) { return $false }
    if ($u.Scheme -ne 'https') { return $false }
    $h = $u.Host.ToLowerInvariant()
    return ($h -eq 'microsoft.com' -or $h.EndsWith('.microsoft.com'))
}

function Get-IsoFileNameFromUrl {
    param([string]$Text)
    try {
        $u = New-Object System.Uri -ArgumentList $Text
        $name = [System.Uri]::UnescapeDataString([System.IO.Path]::GetFileName($u.AbsolutePath))
        foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $name = $name.Replace([string]$c, '_') }
        if ($name -match '(?i)\.iso$') { return $name }
    }
    catch { $null = $_ }
    return 'Windows11_x64.iso'
}

function Get-IsoRemoteSize {
    # HEAD request; returns the Content-Length or 0 when unknown. Never downloads the body.
    param([string]$Link)
    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($Link)
        $req.Method = 'HEAD'
        $req.Timeout = $script:HttpTimeoutSec * 1000
        $req.AllowAutoRedirect = $true
        $resp = $req.GetResponse()
        $len = [int64]$resp.ContentLength
        if ($len -gt 0) { return $len }
    }
    catch { Write-IsoLog ('Could not read the ISO size from the server: {0}' -f $_.Exception.Message) 'Warn' }
    finally { if ($null -ne $resp) { $resp.Close() } }
    return [int64]0
}

# ---------------------------------------------------------------------------------------------
# Microsoft software-download API
# ---------------------------------------------------------------------------------------------
function Read-IsoDownloadPage {
    # Reads the en-US download page: product edition id + Microsoft's own 715-123130 text.
    $editionId = 0
    try {
        $r = Invoke-IsoGet -Uri $script:DownloadPageEnUs
        $html = $r.Text -replace "[\r\n]+", ' '
        if (Test-IsoBlockedText ($html.Substring(0, [math]::Min(4000, $html.Length)))) { $script:PageBlocked = $true }
        $m = [regex]::Match($html, '<input[^>]*id="msg-01"[^>]*value="([^"]*)"')
        if ($m.Success) {
            $t = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
            $t = [System.Net.WebUtility]::HtmlDecode($t)
            $t = ($t -replace '<[^>]+>', ' ' -replace '[\u2010-\u2015]', '-' -replace '[^\x20-\x7E]', ' ' -replace '\s+', ' ').Trim()
            # The page fills in the session id after "... message code 715-123130 and"; we print it ourselves.
            $t = ($t -replace '\s+and\s*$', '.').Trim()
            if ($t) { $script:BlockedText = $t }
        }
        $best = $null
        foreach ($o in [regex]::Matches($html, '<option[^>]*value="(\d+)"[^>]*>([^<]*)</option>')) {
            $label = [System.Net.WebUtility]::HtmlDecode($o.Groups[2].Value).Trim()
            if ($label -notmatch '(?i)Windows 11') { continue }
            if ($label -match '(?i)china|arm64|arm ') { continue }
            if ($label -match '(?i)x64') { $best = $o; break }
            if ($null -eq $best) { $best = $o }
        }
        if ($null -ne $best) {
            $editionId = [int]$best.Groups[1].Value
            Write-IsoLog ('Microsoft download page lists "{0}" (product edition {1})' -f ([System.Net.WebUtility]::HtmlDecode($best.Groups[2].Value).Trim()), $editionId)
        }
        elseif ($script:PageBlocked) {
            Write-IsoLog 'The Microsoft download page answered with "Your request has been blocked".' 'Warn'
        }
        else {
            Write-IsoLog 'Could not find the Windows 11 x64 ISO entry on the Microsoft download page.' 'Warn'
        }
    }
    catch {
        Write-IsoLog ('Could not read the Microsoft download page: {0}' -f $_.Exception.Message) 'Warn'
    }
    return $editionId
}

function New-IsoSession {
    # New session id, whitelisted the same way the download page does it. Both handshake calls are
    # best effort: if they fail, Microsoft rejects the link request later and we report that.
    $sid = [guid]::NewGuid().ToString()
    try {
        $null = Invoke-IsoGet -Uri ('https://vlscppe.microsoft.com/tags?org_id={0}&session_id={1}' -f $script:OrgId, $sid) -NoRedirect
    }
    catch { Write-IsoLog ('Session whitelisting (vlscppe) failed: {0}' -f $_.Exception.Message) 'Warn' }
    try {
        $js = Invoke-IsoGet -Uri ('https://ov-df.microsoft.com/mdt.js?instanceId={0}&PageId=si&session_id={1}' -f $script:OvDfInstanceId, $sid) -NoRedirect
        $w = $null
        $rticks = $null
        $mw = [regex]::Match($js.Text, '[?&]w=([A-F0-9]+)')
        if ($mw.Success) { $w = $mw.Groups[1].Value }
        $mt = [regex]::Match($js.Text, 'rticks\="\+?(\d+)')
        if ($mt.Success) { $rticks = $mt.Groups[1].Value }
        if ($w -and $rticks) {
            $ms = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
            $reply = 'https://ov-df.microsoft.com/?session_id={0}&CustomerId={1}&PageId=si&w={2}&mdt={3}&rticks={4}' -f $sid, $script:OvDfInstanceId, $w, $ms, $rticks
            $null = Invoke-IsoGet -Uri $reply -NoRedirect
        }
        else {
            Write-IsoLog 'Session handshake (ov-df) returned no parameters.' 'Warn'
        }
    }
    catch { Write-IsoLog ('Session handshake (ov-df) failed: {0}' -f $_.Exception.Message) 'Warn' }
    $script:SessionId = $sid
    return $sid
}

function ConvertFrom-IsoApiText {
    # API answers are JSON served as text/plain; a blocked request answers with an HTML page.
    param([string]$Text, [string]$What)
    $t = ([string]$Text).Trim()
    if ($t.StartsWith('<')) {
        if (Test-IsoBlockedText $t) { return [pscustomobject]@{ Errors = @([pscustomobject]@{ Key = 'HtmlBlocked'; Value = 'Your request has been blocked.'; Type = 9 }) } }
        throw ('Microsoft returned a web page instead of {0}.' -f $What)
    }
    try { return (ConvertFrom-Json -InputObject $t) }
    catch { throw ('Microsoft returned an unreadable answer for {0}: {1}' -f $What, $_.Exception.Message) }
}

function Get-IsoApiErrors {
    param($Json)
    $list = @()
    foreach ($e in @(Get-IsoProp $Json 'Errors' @())) { if ($null -ne $e) { $list += $e } }
    $vc = Get-IsoProp $Json 'ValidationContainer'
    foreach ($e in @(Get-IsoProp $vc 'Errors' @())) { if ($null -ne $e) { $list += $e } }
    return , $list
}

function Test-IsoBlockedError {
    param($ApiError)
    $key = [string](Get-IsoProp $ApiError 'Key' '')
    $val = [string](Get-IsoProp $ApiError 'Value' '')
    $type = 0
    try { $type = [int](Get-IsoProp $ApiError 'Type' 0) } catch { $type = 0 }
    if ($key -match '(?i)sentinel|blocked') { return $true }
    if ($val -match '(?i)sentinel|715-123130|blocked') { return $true }
    return ($type -eq 8 -or $type -eq 9)
}

function New-IsoBlockedException {
    $nl = [Environment]::NewLine
    $text = 'Microsoft refused to hand out a Windows 11 download link (message code {0}, session {1}).' -f $script:BlockedCode, $script:SessionId
    if ($script:BlockedText) { $text += $nl + 'Microsoft says: ' + $script:BlockedText }
    $text += $nl + 'This happens when Microsoft blocks downloads for your country/region or network (VPN, proxy or hosting IP), or after many download requests in a short time.'
    $text += $nl + 'What you can do: open ' + $script:DownloadPage + ' in your browser, download "Windows 11 (multi-edition ISO for x64 devices)" in your language, then use that file (Lite OS Builder: "Use my Windows 11 ISO"; command line: Build-LiteOS.ps1 -IsoPath <file>). Or try again later.'
    $ex = New-Object System.InvalidOperationException -ArgumentList $text
    $ex.Data['LiteOSBlocked'] = $true
    return $ex
}

function Get-IsoSkus {
    param([int]$EditionId, [string]$SessionId)
    $uri = '{0}/getskuinformationbyproductedition?profile={1}&productEditionId={2}&SKU=undefined&friendlyFileName=undefined&Locale={3}&sessionID={4}' -f $script:ApiBase, $script:ProfileId, $EditionId, $script:ApiLocale, $SessionId
    $lastErr = 'no answer'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Seconds 2 }
        $r = Invoke-IsoGet -Uri $uri
        $json = ConvertFrom-IsoApiText -Text $r.Text -What 'the language list'
        $errs = Get-IsoApiErrors $json
        if ($errs.Count -gt 0) {
            foreach ($e in $errs) { if (Test-IsoBlockedError $e) { throw (New-IsoBlockedException) } }
            $lastErr = [string](Get-IsoProp $errs[0] 'Value' 'unknown error')
            continue
        }
        $skus = @(@(Get-IsoProp $json 'Skus' @()) | Where-Object { $null -ne $_ -and (Get-IsoProp $_ 'Id') })
        if ($skus.Count -gt 0) { return , $skus }
        $lastErr = 'the language list is empty'
    }
    throw ('Microsoft did not return the Windows 11 language list: {0}' -f $lastErr)
}

function Resolve-IsoSku {
    # Pure: picks the SKU for a language given as Microsoft name, API name or culture name.
    param([object[]]$Skus, [string]$Language)
    $want = ([string]$Language).Trim()
    if ([string]::IsNullOrEmpty($want)) { $want = 'English (United States)' }
    $wl = $want.ToLowerInvariant()
    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($wl)
    if ($script:LanguageAliases.ContainsKey($wl)) { $candidates.Add(([string]$script:LanguageAliases[$wl]).ToLowerInvariant()) }
    if ($want -match '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$') {
        try {
            $ci = [System.Globalization.CultureInfo]::GetCultureInfo($want)
            $candidates.Add($ci.EnglishName.ToLowerInvariant())
            $root = ($ci.EnglishName -replace '\s*\(.*$', '').Trim().ToLowerInvariant()
            if ($root) { $candidates.Add($root) }
        }
        catch { $null = $_ }
    }
    foreach ($c in $candidates) {
        foreach ($s in @($Skus)) {
            $a = ([string](Get-IsoProp $s 'Language' '')).ToLowerInvariant()
            $b = ([string](Get-IsoProp $s 'LocalizedLanguage' '')).ToLowerInvariant()
            if ($c -eq $a -or $c -eq $b) { return $s }
        }
    }
    return $null
}

function Get-IsoDownloadLink {
    param([string]$SkuId, [string]$SessionId)
    $uri = '{0}/GetProductDownloadLinksBySku?profile={1}&productEditionId=undefined&SKU={2}&friendlyFileName=undefined&Locale={3}&sessionID={4}' -f $script:ApiBase, $script:ProfileId, $SkuId, $script:ApiLocale, $SessionId
    # Microsoft refuses this call without the download page as Referer.
    $r = Invoke-IsoGet -Uri $uri -Headers @{ Referer = $script:DownloadPage } -Attempts 2
    $json = ConvertFrom-IsoApiText -Text $r.Text -What 'the download link'
    $errs = Get-IsoApiErrors $json
    if ($errs.Count -gt 0) {
        foreach ($e in $errs) {
            Write-IsoLog ('Microsoft answered: {0} ({1}, type {2})' -f (Get-IsoProp $e 'Value' ''), (Get-IsoProp $e 'Key' ''), (Get-IsoProp $e 'Type' '')) 'Warn'
            if (Test-IsoBlockedError $e) { throw (New-IsoBlockedException) }
        }
        throw ('Microsoft did not return a download link: {0}' -f (Get-IsoProp $errs[0] 'Value' 'unknown error'))
    }
    $options = @(@(Get-IsoProp $json 'ProductDownloadOptions' @()) | Where-Object { $null -ne $_ -and (Get-IsoProp $_ 'Uri') })
    if ($options.Count -eq 0) { throw 'Microsoft returned no download links for this language.' }
    $pick = $null
    foreach ($o in $options) {
        $type = -1
        try { $type = [int](Get-IsoProp $o 'DownloadType' -1) } catch { $type = -1 }
        if ($type -eq 1 -or ([string](Get-IsoProp $o 'Uri' '')) -match '(?i)x64') { $pick = $o; break }
    }
    if ($null -eq $pick) { $pick = $options[0] }
    $link = [string](Get-IsoProp $pick 'Uri' '')
    if (-not (Test-IsoOfficialUrl $link)) { throw ('Refusing a download link that is not on a Microsoft server: {0}' -f (Format-IsoUrlForLog $link)) }
    $expires = [string](Get-IsoProp $json 'DownloadExpirationDatetime' '')
    return [pscustomobject]@{ Url = $link; FileName = (Get-IsoFileNameFromUrl $link); Expires = $expires }
}

function Get-IsoOfficialLink {
    # Full API flow. Returns @{ Url; FileName; Expires; Language }.
    Write-IsoProgress 0 'Contacting Microsoft' -Always
    $edition = $ProductEditionId
    $fromPage = Read-IsoDownloadPage
    if ($edition -le 0) { $edition = $fromPage }
    if ($edition -le 0) {
        $edition = $script:FallbackEditionId
        Write-IsoLog ('Using the known product edition id {0}.' -f $edition) 'Warn'
    }
    $sid = New-IsoSession
    Write-IsoLog ('Session {0}' -f $sid)
    Write-IsoProgress 1 'Asking Microsoft for the language list' -Always
    $skus = Get-IsoSkus -EditionId $edition -SessionId $sid
    $sku = Resolve-IsoSku -Skus $skus -Language $Language
    if ($null -eq $sku) {
        $names = @($skus | ForEach-Object { [string](Get-IsoProp $_ 'LocalizedLanguage' (Get-IsoProp $_ 'Language' '')) })
        throw ("Language '{0}' is not offered by Microsoft. Available: {1}" -f $Language, ($names -join ', '))
    }
    $langName = [string](Get-IsoProp $sku 'LocalizedLanguage' (Get-IsoProp $sku 'Language' ''))
    Write-IsoLog ('{0} - {1} (SKU {2})' -f (Get-IsoProp $sku 'LocalizedProductDisplayName' (Get-IsoProp $sku 'ProductDisplayName' 'Windows 11')), $langName, (Get-IsoProp $sku 'Id' ''))
    Write-IsoProgress 2 'Asking Microsoft for the download link' -Always
    $link = Get-IsoDownloadLink -SkuId ([string](Get-IsoProp $sku 'Id' '')) -SessionId $sid
    $link | Add-Member -NotePropertyName Language -NotePropertyValue $langName -Force
    Write-IsoLog ('Official link: {0}' -f (Format-IsoUrlForLog $link.Url)) 'Ok'
    if ($link.Expires) { Write-IsoLog ('The link is valid until {0}' -f $link.Expires) }
    return $link
}

# ---------------------------------------------------------------------------------------------
# ISO verification (reads the volume descriptors; never mounts anything)
# ---------------------------------------------------------------------------------------------
function Test-WindowsIsoFile {
    <#
        Checks size, the ISO 9660 primary volume descriptor ("CD001", volume label) and the UDF
        volume recognition sequence ("NSR02"/"NSR03") that Windows setup ISOs carry, and refuses
        ARM64 media. The builder does the full check (install.wim, build) after mounting.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int64]$MinBytes = $script:MinIsoBytes,
        [int64]$ExpectedBytes = 0
    )
    $res = [ordered]@{ Path = $Path; Valid = $false; Reason = ''; Size = [int64]0; Label = ''; Iso9660 = $false; Udf = $false; Arch = 'unknown'; Warning = '' }
    if (-not [System.IO.File]::Exists($Path)) { $res.Reason = 'file not found'; return [pscustomobject]$res }
    $fi = New-Object System.IO.FileInfo -ArgumentList $Path
    $res.Size = [int64]$fi.Length
    if ($ExpectedBytes -gt 0 -and $fi.Length -ne $ExpectedBytes) {
        $res.Reason = ('size is {0} bytes, the server announced {1} bytes (incomplete download)' -f $fi.Length, $ExpectedBytes)
        return [pscustomobject]$res
    }
    if ($fi.Length -lt $MinBytes) {
        $res.Reason = ('file is only {0}; a Windows 11 ISO is 5 GB or more' -f (Format-IsoBytes $fi.Length))
        return [pscustomobject]$res
    }
    $sector = 2048
    $first = 16
    $count = 32
    $buf = New-Object byte[] ($sector * $count)
    $read = 0
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($fs.Length -ge (($first + 1) * $sector)) {
            [void]$fs.Seek($first * $sector, [System.IO.SeekOrigin]::Begin)
            while ($read -lt $buf.Length) {
                $n = $fs.Read($buf, $read, $buf.Length - $read)
                if ($n -le 0) { break }
                $read += $n
            }
        }
    }
    catch {
        $res.Reason = ('cannot read the file: {0}' -f $_.Exception.Message)
        return [pscustomobject]$res
    }
    finally { if ($null -ne $fs) { $fs.Dispose() } }
    $ascii = [System.Text.Encoding]::ASCII
    for ($i = 0; $i -lt [int][math]::Floor($read / $sector); $i++) {
        $off = $i * $sector
        $id = $ascii.GetString($buf, $off + 1, 5)
        if ($id -eq 'CD001') {
            $res.Iso9660 = $true
            if ($buf[$off] -eq 1 -and -not $res.Label) { $res.Label = $ascii.GetString($buf, $off + 40, 32).Trim() }
        }
        elseif ($id -eq 'NSR02' -or $id -eq 'NSR03') { $res.Udf = $true }
    }
    if (-not $res.Iso9660 -and -not $res.Udf) { $res.Reason = 'not an ISO image (no ISO 9660 / UDF volume descriptors)'; return [pscustomobject]$res }
    if (-not $res.Udf) { $res.Reason = 'not a Windows setup ISO (no UDF file system)'; return [pscustomobject]$res }
    $label = [string]$res.Label
    if ($label -match '(?i)(^|_)(A64|ARM64)') { $res.Arch = 'arm64' }
    elseif ($label -match '(?i)X64') { $res.Arch = 'x64' }
    elseif ($label -match '(?i)(^|_)X86') { $res.Arch = 'x86' }
    if ($res.Arch -eq 'arm64' -or $res.Arch -eq 'x86') {
        $res.Reason = ('this is an {0} ISO (volume label {1}); Lite OS needs the x64 ISO' -f $res.Arch, $label)
        return [pscustomobject]$res
    }
    if ($label -notmatch '(?i)FRE|CCCOMA|CPBA|CCSA|CENA') {
        $res.Warning = ("volume label '{0}' does not look like a Microsoft Windows ISO; the builder checks the image after mounting" -f $label)
    }
    $res.Valid = $true
    return [pscustomobject]$res
}

# ---------------------------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------------------------
function Get-IsoDownloadsFolder {
    try {
        $p = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop
        $v = Get-IsoProp $p '{374DE290-123F-4565-9164-39C4925E467B}'
        if ($v) {
            $x = [Environment]::ExpandEnvironmentVariables([string]$v)
            if ([System.IO.Directory]::Exists($x)) { return $x }
        }
    }
    catch { $null = $_ }
    $d = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
    if ([System.IO.Directory]::Exists($d)) { return $d }
    return (Get-Location).ProviderPath
}

function Resolve-IsoTarget {
    # -OutFile as given -> @{ Path; IsFolder }. A folder (existing or ending with \) keeps MS's name.
    param([string]$Requested)
    if ([string]::IsNullOrWhiteSpace($Requested)) {
        return @{ Path = (Get-IsoDownloadsFolder); IsFolder = $true }
    }
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Requested)
    if ($Requested.EndsWith('\') -or $Requested.EndsWith('/') -or [System.IO.Directory]::Exists($full)) {
        return @{ Path = $full.TrimEnd('\', '/'); IsFolder = $true }
    }
    return @{ Path = $full; IsFolder = $false }
}

function Get-IsoFreeBytes {
    param([string]$Folder)
    try {
        $root = [System.IO.Path]::GetPathRoot($Folder)
        if ([string]::IsNullOrEmpty($root) -or $root.StartsWith('\\')) { return [int64]-1 }
        $di = New-Object System.IO.DriveInfo -ArgumentList $root
        return [int64]$di.AvailableFreeSpace
    }
    catch { return [int64]-1 }
}

function Write-IsoTransferProgress {
    param([int64]$Done, [int64]$Total, [System.Diagnostics.Stopwatch]$Clock, [int64]$StartBytes = 0, [string]$Via = '')
    $pct = 0.0
    if ($Total -gt 0) { $pct = [math]::Min(100.0, 100.0 * $Done / $Total) }
    $speed = 0.0
    $secs = $Clock.Elapsed.TotalSeconds
    if ($secs -gt 0.5) { $speed = ($Done - $StartBytes) / $secs }
    $msg = 'Downloading Windows 11'
    if ($Total -gt 0) { $msg += (': {0} of {1}' -f (Format-IsoBytes $Done), (Format-IsoBytes $Total)) }
    else { $msg += (': {0}' -f (Format-IsoBytes $Done)) }
    if ($speed -gt 0) {
        $msg += (', {0}/s' -f (Format-IsoBytes $speed))
        if ($Total -gt $Done) {
            $left = ($Total - $Done) / $speed
            if ($left -ge 90) { $msg += (', about {0} min left' -f [int][math]::Ceiling($left / 60)) }
            else { $msg += (', about {0} s left' -f [int][math]::Ceiling($left)) }
        }
    }
    if ($Via) { $msg += (' ({0})' -f $Via) }
    # download = 3..97 of this script's range
    Write-IsoProgress (3 + 94 * $pct / 100.0) $msg
}

function Remove-IsoStaleBitsJobs {
    try {
        foreach ($j in @(Get-BitsTransfer -ErrorAction Stop | Where-Object { $_.DisplayName -eq $script:BitsDisplayName })) {
            Write-IsoLog ('Removing an unfinished Lite OS BITS download from an earlier run ({0}).' -f $j.JobState) 'Warn'
            try { Remove-BitsTransfer -BitsJob $j -ErrorAction Stop } catch { Write-IsoLog ('Could not remove BITS job: {0}' -f $_.Exception.Message) 'Warn' }
        }
    }
    catch { $null = $_ }
}

function Save-IsoWithBits {
    param([string]$Link, [string]$Destination, [int64]$ExpectedBytes)
    Import-Module BitsTransfer -ErrorAction Stop
    Remove-IsoStaleBitsJobs
    $tmp = $Destination + '.bits'
    if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) }
    $job = Start-BitsTransfer -Source $Link -Destination $tmp -Asynchronous -DisplayName $script:BitsDisplayName `
        -Description 'Lite OS: official Windows 11 ISO from Microsoft' -Priority Foreground -RetryInterval 60 -RetryTimeout 900 -ErrorAction Stop
    Write-IsoLog ('BITS download started (job {0}).' -f $job.JobId)
    $finished = $false
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $lastBytes = [int64]-1
    $lastChange = [DateTime]::UtcNow
    try {
        while ($true) {
            try {
                $fresh = Get-BitsTransfer -JobId $job.JobId -ErrorAction Stop
                if ($null -ne $fresh) { $job = $fresh }
            }
            catch { $null = $_ }
            $state = [string]$job.JobState
            $total = [int64]0
            $rawTotal = [uint64]$job.BytesTotal
            if ($rawTotal -ne [uint64]::MaxValue -and $rawTotal -lt [uint64][int64]::MaxValue) { $total = [int64]$rawTotal }
            if ($total -le 0) { $total = $ExpectedBytes }
            $done = [int64][uint64]$job.BytesTransferred
            if ($done -ne $lastBytes) { $lastBytes = $done; $lastChange = [DateTime]::UtcNow }
            Write-IsoTransferProgress -Done $done -Total $total -Clock $clock -Via 'BITS'
            if ($state -eq 'Transferred') {
                Complete-BitsTransfer -BitsJob $job -ErrorAction Stop
                $finished = $true
                break
            }
            if ($state -eq 'Acknowledged') { $finished = $true; break }
            if ($state -eq 'Error' -or $state -eq 'Cancelled') {
                $desc = ('{0} {1}' -f (Get-IsoProp $job 'ErrorContextDescription' ''), (Get-IsoProp $job 'ErrorDescription' '')).Trim()
                throw ('BITS transfer failed ({0}): {1}' -f $state, $desc)
            }
            if ($state -eq 'Suspended') { $null = Resume-BitsTransfer -BitsJob $job -Asynchronous -ErrorAction Stop }
            if (([DateTime]::UtcNow - $lastChange).TotalSeconds -gt $script:StallSeconds) {
                $desc = ([string](Get-IsoProp $job 'ErrorDescription' '')).Trim()
                throw ('BITS made no progress for {0} minutes ({1}) {2}' -f [int]($script:StallSeconds / 60), $state, $desc)
            }
            Start-Sleep -Milliseconds 700
        }
    }
    finally {
        if (-not $finished) {
            try { Remove-BitsTransfer -BitsJob $job -ErrorAction Stop } catch { $null = $_ }
            if ([System.IO.File]::Exists($tmp)) { try { [System.IO.File]::Delete($tmp) } catch { $null = $_ } }
        }
    }
    return $tmp
}

function Get-IsoPartSidecar {
    # <file>.part.json remembers which server file a .part belongs to, so a partial download of an
    # older Windows release is never resumed with a newer link (that would splice two ISOs).
    param([string]$Part)
    $side = $Part + '.json'
    if (-not [System.IO.File]::Exists($side)) { return $null }
    try { return (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($side))) } catch { return $null }
}

function Set-IsoPartSidecar {
    param([string]$Part, [string]$RemotePath, [int64]$Size, [string]$ETag)
    $o = [ordered]@{ remotePath = $RemotePath; size = $Size; etag = $ETag; started = (Get-Date).ToString('s') }
    try { [System.IO.File]::WriteAllText(($Part + '.json'), (ConvertTo-Json -InputObject $o -Compress)) }
    catch { Write-IsoLog ('Could not write {0}.json: {1}' -f $Part, $_.Exception.Message) 'Warn' }
}

function Remove-IsoPart {
    param([string]$Part)
    foreach ($f in @($Part, ($Part + '.json'))) {
        if ([System.IO.File]::Exists($f)) { [System.IO.File]::Delete($f) }
    }
}

function Test-IsoPartMatches {
    # A .part may only be resumed for the same server file name and size.
    param([string]$Part, [string]$RemotePath, [int64]$ExpectedBytes)
    $side = Get-IsoPartSidecar -Part $Part
    if ($null -eq $side) { return $false }
    if ([string](Get-IsoProp $side 'remotePath' '') -ine $RemotePath) { return $false }
    $size = [int64]0
    try { $size = [int64](Get-IsoProp $side 'size' 0) } catch { $size = 0 }
    if ($ExpectedBytes -gt 0 -and $size -gt 0 -and $size -ne $ExpectedBytes) { return $false }
    return $true
}

function Save-IsoWithHttp {
    param([string]$Link, [string]$Destination, [int64]$ExpectedBytes)
    Add-Type -AssemblyName System.Net.Http
    $part = $Destination + '.part'
    $remotePath = ''
    try { $remotePath = (New-Object System.Uri -ArgumentList $Link).AbsolutePath } catch { $remotePath = '' }
    if ([System.IO.File]::Exists($part) -and -not (Test-IsoPartMatches -Part $part -RemotePath $remotePath -ExpectedBytes $ExpectedBytes)) {
        Write-IsoLog 'A partial download of a different Windows release was found; starting over.' 'Warn'
        Remove-IsoPart -Part $part
    }
    $handler = $null
    try {
        Add-Type -AssemblyName System.Net.Http.WebRequest
        $handler = New-Object System.Net.Http.WebRequestHandler
        $handler.ReadWriteTimeout = 120000
    }
    catch { $handler = New-Object System.Net.Http.HttpClientHandler }
    $handler.AllowAutoRedirect = $true
    $client = New-Object System.Net.Http.HttpClient -ArgumentList $handler
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    $buffer = New-Object byte[] (1MB)
    $maxAttempts = 10
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $startBytes = [int64]0
    if ([System.IO.File]::Exists($part)) { $startBytes = (New-Object System.IO.FileInfo -ArgumentList $part).Length }
    try {
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            $have = [int64]0
            if ([System.IO.File]::Exists($part)) { $have = (New-Object System.IO.FileInfo -ArgumentList $part).Length }
            if ($ExpectedBytes -gt 0 -and $have -eq $ExpectedBytes) { break }
            if ($ExpectedBytes -gt 0 -and $have -gt $ExpectedBytes) { Remove-IsoPart -Part $part; $have = 0 }
            $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList ([System.Net.Http.HttpMethod]::Get), $Link
            if ($have -gt 0) {
                $req.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue -ArgumentList $have, $null
                # If-Range: if the file changed on the server, it answers 200 with the whole file.
                $etag = [string](Get-IsoProp (Get-IsoPartSidecar -Part $part) 'etag' '')
                if ($etag) {
                    try { $req.Headers.IfRange = New-Object System.Net.Http.Headers.RangeConditionHeaderValue -ArgumentList (New-Object System.Net.Http.Headers.EntityTagHeaderValue -ArgumentList $etag) }
                    catch { $null = $_ }
                }
                Write-IsoLog ('Resuming the download at {0}.' -f (Format-IsoBytes $have))
            }
            $resp = $null
            $stream = $null
            $fileStream = $null
            $total = $ExpectedBytes
            $ended = $false
            # HttpClient.Timeout is infinite (the body takes long): a separate 120 s limit applies to the
            # response HEADERS only, so a connection that stalls before answering is retried instead of
            # blocking forever. The token is disposed right after the headers arrive (it must never cut
            # the body; body reads have their own ReadWriteTimeout / ReadTimeout).
            $cts = New-Object System.Threading.CancellationTokenSource
            try {
                $cts.CancelAfter(120000)
                try {
                    $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token).GetAwaiter().GetResult()
                }
                catch [System.OperationCanceledException] {
                    throw 'no response from the download server within 120 seconds'
                }
                finally { $cts.Dispose() }
                $code = [int]$resp.StatusCode
                if ($code -eq 416 -and $have -gt 0) {
                    Write-IsoLog 'The server refused to resume; starting over.' 'Warn'
                    Remove-IsoPart -Part $part
                    continue
                }
                if ($code -eq 403 -or $code -eq 404 -or $code -eq 410) {
                    throw ('the server answered HTTP {0}; the download link has probably expired (links are valid for 24 hours). Run the download again for a new link.' -f $code)
                }
                if ($code -ne 200 -and $code -ne 206) { throw ('the server answered HTTP {0} {1}' -f $code, $resp.ReasonPhrase) }
                $mode = [System.IO.FileMode]::Create
                if ($code -eq 206 -and $have -gt 0) {
                    $cr = $resp.Content.Headers.ContentRange
                    if ($null -ne $cr -and $cr.HasRange -and [int64]$cr.From -eq $have) {
                        $mode = [System.IO.FileMode]::Append
                        if ($cr.HasLength) { $total = [int64]$cr.Length }
                    }
                    else {
                        Write-IsoLog 'The server sent an unexpected range; starting over.' 'Warn'
                        $resp.Dispose()
                        $resp = $null
                        Remove-IsoPart -Part $part
                        continue
                    }
                }
                else {
                    $have = 0
                    $cl = $resp.Content.Headers.ContentLength
                    if ($null -ne $cl -and [int64]$cl -gt 0) { $total = [int64]$cl }
                    $tag = ''
                    if ($null -ne $resp.Headers.ETag) { $tag = [string]$resp.Headers.ETag.Tag }
                    Set-IsoPartSidecar -Part $part -RemotePath $remotePath -Size $total -ETag $tag
                }
                if ($ExpectedBytes -le 0 -and $total -gt 0) { $ExpectedBytes = $total }
                $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                # The plain HttpClientHandler fallback has no ReadWriteTimeout: a stalled body read must
                # still end (and be retried) instead of hanging the download.
                try { if ($stream.CanTimeout) { $stream.ReadTimeout = 120000 } } catch { $null = $_ }
                $fileStream = New-Object System.IO.FileStream -ArgumentList $part, $mode, ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::Read), 1048576
                $done = $have
                $nextReport = [int64]0
                while ($true) {
                    $n = $stream.Read($buffer, 0, $buffer.Length)
                    if ($n -le 0) { $ended = $true; break }
                    $fileStream.Write($buffer, 0, $n)
                    $done += $n
                    if ($done -ge $nextReport) {
                        Write-IsoTransferProgress -Done $done -Total $total -Clock $clock -StartBytes $startBytes -Via 'HTTP'
                        $nextReport = $done + 8MB
                    }
                }
            }
            catch {
                $msg = $_.Exception.Message
                if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
                if ($msg -match 'link has probably expired' -or $attempt -ge $maxAttempts) { throw ('HTTP download failed: {0}' -f $msg) }
                Write-IsoLog ('Download interrupted (attempt {0} of {1}): {2}' -f $attempt, $maxAttempts, $msg) 'Warn'
                Start-Sleep -Seconds ([math]::Min(30, 3 * $attempt))
                continue
            }
            finally {
                if ($null -ne $fileStream) { $fileStream.Dispose() }
                if ($null -ne $stream) { $stream.Dispose() }
                if ($null -ne $resp) { $resp.Dispose() }
            }
            $now = (New-Object System.IO.FileInfo -ArgumentList $part).Length
            if ($ExpectedBytes -gt 0 -and $now -eq $ExpectedBytes) { break }
            if ($ExpectedBytes -le 0 -and $ended) { break }
            Write-IsoLog ('The connection ended early at {0}; resuming.' -f (Format-IsoBytes $now)) 'Warn'
            if ($attempt -ge $maxAttempts) { throw 'HTTP download failed: the connection kept ending early. Run it again to resume.' }
        }
    }
    finally { $client.Dispose() }
    $final = [int64]0
    if ([System.IO.File]::Exists($part)) { $final = (New-Object System.IO.FileInfo -ArgumentList $part).Length }
    if ($ExpectedBytes -gt 0 -and $final -ne $ExpectedBytes) {
        # Keep the .part: the next run resumes it.
        throw ('HTTP download incomplete ({0} of {1}). Run it again to resume.' -f (Format-IsoBytes $final), (Format-IsoBytes $ExpectedBytes))
    }
    $side = $part + '.json'
    if ([System.IO.File]::Exists($side)) { try { [System.IO.File]::Delete($side) } catch { $null = $_ } }
    return $part
}

function Save-IsoFile {
    # Downloads $Link to $Destination (verified). BITS first, HttpClient as fallback.
    param([string]$Link, [string]$Destination)
    $dir = [System.IO.Path]::GetDirectoryName($Destination)
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $expected = Get-IsoRemoteSize -Link $Link
    if ($expected -gt 0) { Write-IsoLog ('Size: {0} ({1} bytes)' -f (Format-IsoBytes $expected), $expected) }
    $partLen = [int64]0
    if ([System.IO.File]::Exists($Destination + '.part')) { $partLen = (New-Object System.IO.FileInfo -ArgumentList ($Destination + '.part')).Length }
    $need = [int64]8GB
    if ($expected -gt 0) { $need = $expected - $partLen + 256MB }
    $free = Get-IsoFreeBytes -Folder $dir
    if ($free -ge 0 -and $free -lt $need) {
        throw ('Not enough free space on {0}: {1} free, {2} needed for the Windows 11 ISO.' -f ([System.IO.Path]::GetPathRoot($dir)), (Format-IsoBytes $free), (Format-IsoBytes $need))
    }
    $tmp = $null
    $usedBits = $false
    if (-not $NoBits -and $partLen -eq 0) {
        try {
            $tmp = Save-IsoWithBits -Link $Link -Destination $Destination -ExpectedBytes $expected
            $usedBits = $true
        }
        catch {
            Write-IsoLog ('BITS download did not work, switching to a direct download: {0}' -f $_.Exception.Message) 'Warn'
            $tmp = $null
        }
    }
    elseif ($partLen -gt 0) {
        Write-IsoLog ('Found a partial download ({0}); resuming it directly.' -f (Format-IsoBytes $partLen))
    }
    if ($null -eq $tmp) { $tmp = Save-IsoWithHttp -Link $Link -Destination $Destination -ExpectedBytes $expected }
    Write-IsoProgress 98 'Checking the downloaded ISO' -Always
    $check = Test-WindowsIsoFile -Path $tmp -ExpectedBytes $expected
    if (-not $check.Valid) {
        try { [System.IO.File]::Delete($tmp) } catch { $null = $_ }
        throw ('The downloaded file is not a valid Windows 11 ISO: {0}. It was deleted; please try again.' -f $check.Reason)
    }
    if ($check.Warning) { Write-IsoLog $check.Warning 'Warn' }
    if ([System.IO.File]::Exists($Destination)) { [System.IO.File]::Delete($Destination) }
    [System.IO.File]::Move($tmp, $Destination)
    $via = 'HTTP'
    if ($usedBits) { $via = 'BITS' }
    Write-IsoLog ('Downloaded {0} via {1} (volume {2}).' -f (Format-IsoBytes $check.Size), $via, $check.Label) 'Ok'
    return $Destination
}

# ---------------------------------------------------------------------------------------------
# Fallback when Microsoft refuses: explain, open the page, let the user pick the file
# ---------------------------------------------------------------------------------------------
function Open-IsoDownloadPage {
    if ($NoBrowser) { return }
    if ($env:CI -or $env:GITHUB_ACTIONS -or $env:TF_BUILD) { return }
    if (-not [Environment]::UserInteractive) { return }
    try {
        # explorer.exe hands the URL to the signed-in user's default browser (not elevated).
        Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList $script:DownloadPage
        Write-IsoLog ('Opened {0} in your browser.' -f $script:DownloadPage)
    }
    catch { Write-IsoLog ('Could not open the browser: {0}' -f $_.Exception.Message) 'Warn' }
}

function Read-IsoManualSource {
    # Interactive console only. Returns a verified ISO path, or $null when the user gives up.
    for ($i = 0; $i -lt 5; $i++) {
        Write-Host ''
        Write-Host 'Download "Windows 11 (multi-edition ISO for x64 devices)" from the Microsoft page in your browser.' -ForegroundColor Cyan
        Write-Host 'Then type the path of the .iso file here (or paste the download link from that page).' -ForegroundColor Cyan
        $answer = Read-Host 'ISO path or link (Enter = cancel)'
        if ([string]::IsNullOrWhiteSpace($answer)) { return $null }
        $answer = $answer.Trim().Trim('"')
        if ($answer -match '^(?i)https?://') {
            if (-not (Test-IsoOfficialUrl $answer)) { Write-IsoLog 'Only https links on microsoft.com are accepted.' 'Warn'; continue }
            return @{ Url = $answer }
        }
        $check = Test-WindowsIsoFile -Path $answer
        if ($check.Valid) {
            if ($check.Warning) { Write-IsoLog $check.Warning 'Warn' }
            return @{ Path = (Resolve-Path -LiteralPath $answer).ProviderPath }
        }
        Write-IsoLog ('{0}: {1}' -f $answer, $check.Reason) 'Warn'
    }
    return $null
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------
if ($ProgressEnd -lt $ProgressStart) { throw '-ProgressEnd must be >= -ProgressStart.' }
$script:Interactive = Test-IsoInteractive
Initialize-IsoLog
Write-IsoLog ('Get-WindowsIso {0} | PowerShell {1} | Windows {2} | log {3}' -f $script:GetIsoVersion, $PSVersionTable.PSVersion, [Environment]::OSVersion.Version, $script:LogFile)
Initialize-IsoNetwork

try {
    if ($ListLanguages) {
        $edition = $ProductEditionId
        if ($edition -le 0) { $edition = Read-IsoDownloadPage }
        if ($edition -le 0) { $edition = $script:FallbackEditionId }
        $sid = New-IsoSession
        $skus = Get-IsoSkus -EditionId $edition -SessionId $sid
        foreach ($s in $skus) {
            [pscustomobject]@{
                Language          = [string](Get-IsoProp $s 'LocalizedLanguage' '')
                ApiLanguage       = [string](Get-IsoProp $s 'Language' '')
                SkuId             = [string](Get-IsoProp $s 'Id' '')
                Product           = [string](Get-IsoProp $s 'LocalizedProductDisplayName' (Get-IsoProp $s 'ProductDisplayName' ''))
            }
        }
        return
    }

    $target = Resolve-IsoTarget -Requested $OutFile

    # A valid ISO already at the requested file path: reuse it (a 7 GB download is never silent).
    if (-not $UrlOnly -and -not $target.IsFolder -and [System.IO.File]::Exists($target.Path)) {
        $existing = Test-WindowsIsoFile -Path $target.Path
        if ($existing.Valid -and -not $Force) {
            Write-IsoLog ('Using the Windows ISO already at {0} ({1}, volume {2}). Use -Force to download again.' -f $target.Path, (Format-IsoBytes $existing.Size), $existing.Label) 'Ok'
            Write-IsoProgress 100 'Windows 11 ISO ready (downloaded earlier)' -Always
            Write-Output $target.Path
            return
        }
        if (-not $existing.Valid -and -not $Force) {
            throw ('{0} already exists and is not a valid Windows 11 ISO ({1}). Delete it, choose another -OutFile, or use -Force.' -f $target.Path, $existing.Reason)
        }
    }

    $link = $null
    if (-not [string]::IsNullOrWhiteSpace($Url)) {
        if (-not (Test-IsoOfficialUrl $Url)) { throw 'The -Url must be an https link on microsoft.com (copy it from the Microsoft download page).' }
        $link = [pscustomobject]@{ Url = $Url.Trim(); FileName = (Get-IsoFileNameFromUrl $Url); Expires = ''; Language = $Language }
        Write-IsoLog ('Using the link you provided: {0}' -f (Format-IsoUrlForLog $link.Url))
    }
    else {
        try {
            $link = Get-IsoOfficialLink
        }
        catch {
            $apiError = $_
            $blocked = $false
            try { $blocked = [bool]$apiError.Exception.Data['LiteOSBlocked'] } catch { $blocked = $false }
            if (-not $blocked) { throw $apiError }
            foreach ($l in ($apiError.Exception.Message -split "`r?`n")) { Write-IsoLog $l 'Warn' }
            $script:ErrorShown = $true
            Open-IsoDownloadPage
            if ($UrlOnly -or -not $script:Interactive) { throw $apiError }
            $manual = Read-IsoManualSource
            if ($null -eq $manual) { throw $apiError }
            if ($manual.ContainsKey('Path')) {
                Write-IsoLog ('Using {0}' -f $manual.Path) 'Ok'
                Write-IsoProgress 100 'Windows 11 ISO ready' -Always
                Write-Output $manual.Path
                return
            }
            $link = [pscustomobject]@{ Url = $manual.Url; FileName = (Get-IsoFileNameFromUrl $manual.Url); Expires = ''; Language = $Language }
        }
    }

    if ($UrlOnly) {
        Write-IsoProgress 100 'Download link ready' -Always
        Write-Output $link.Url
        return
    }

    $dest = $target.Path
    if ($target.IsFolder) { $dest = Join-Path $target.Path $link.FileName }
    if ([System.IO.File]::Exists($dest) -and -not $Force) {
        $existing = Test-WindowsIsoFile -Path $dest
        if ($existing.Valid) {
            Write-IsoLog ('Using the Windows ISO already at {0} ({1}). Use -Force to download again.' -f $dest, (Format-IsoBytes $existing.Size)) 'Ok'
            Write-IsoProgress 100 'Windows 11 ISO ready (downloaded earlier)' -Always
            Write-Output $dest
            return
        }
        throw ('{0} already exists and is not a valid Windows 11 ISO ({1}). Delete it or use -Force.' -f $dest, $existing.Reason)
    }
    Write-IsoLog ('Saving to {0}' -f $dest)
    Write-IsoProgress 3 'Starting the download from Microsoft' -Always
    $saved = Save-IsoFile -Link $link.Url -Destination $dest
    Write-IsoProgress 100 'Windows 11 ISO downloaded and checked' -Always
    if ($script:Interactive) { Write-Progress -Activity 'Windows 11 ISO' -Completed }
    Write-Output $saved
}
catch {
    $fatal = $_
    if ($script:ErrorShown) { Write-IsoLog ('Stopped: Microsoft refused the download ({0}).' -f $script:BlockedCode) 'Error' }
    else { Write-IsoLog ($fatal.Exception.Message -replace "`r?`n", ' | ') 'Error' }
    if ($script:LogFile) { Write-Host ('[Windows ISO] Log: {0}' -f $script:LogFile) }
    # Started directly (powershell.exe -File Get-WindowsIso.ps1, e.g. by the GUI): the message is
    # already printed, so just set exit code 1. Called from another script: terminating error.
    if (Test-IsoEntryScript) { exit 1 }
    throw $fatal
}

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

    Microsoft's download page often refuses cloud / datacenter addresses (GitHub runners, VPNs) and
    some countries (message code 715-123130). -Source Esd (and -Source Auto, the default, after the
    download page failed) uses the other official channel instead: the Windows 11 image (ESD) that
    Microsoft's Media Creation Tool downloads.
      1. the Media Creation Tool catalog (products.cab): first from the Microsoft Update metadata
         service the current Media Creation Tool queries (fe3.delivery.mp.microsoft.com, product
         Windows.Products.Cab.amd64; the catalog is checked against the SHA-256 that service
         publishes; in 2026-10 it lists Windows 11 26H2), then from the static Windows 11 catalog
         link https://go.microsoft.com/fwlink/?LinkId=2156292 (download.microsoft.com; an older
         24H2 catalog - Windows Update brings that install up to date)
      2. products.xml (expand.exe): the newest released x64 consumer image (CLIENTCONSUMER_RET:
         Home, Pro, Education, ...) in your language, with its size and SHA-256 (SHA-1 in older
         catalogs)
      3. the ESD from dl.delivery.mp.microsoft.com (BITS, or a resumable HttpClient download),
         checked against that hash (Microsoft serves it over plain http; the hash is the check)
      4. DISM turns it into Windows setup media: image 1 (Windows Setup Media) is applied to a
         folder, images 2 (Windows PE) and 3 (Windows Setup, bootable) are exported to
         sources\boot.wim, the editions (images 4+) to sources\install.wim (fast compression; the
         Lite OS builder exports the edition it keeps again)
      5. builder\New-IsoFile.ps1 writes a bootable ISO from that folder; the ESD and the folder are
         deleted afterwards. If New-IsoFile.ps1 is missing, the setup media folder is the result
         (Build-LiteOS.ps1 -IsoPath accepts such a folder too).
    The ESD route needs administrator rights (DISM) and about 4x the ESD size (roughly 20-25 GB)
    of free space next to -OutFile while it works (work folder <OutFile folder>\LiteOS-ESD). A
    downloaded, checked ESD is kept there for the next run when a later step fails.

    If Microsoft refuses the request (message code 715-123130: blocked country/region, network or
    too many requests) and no other source works, the script explains why, opens the Microsoft
    download page in your browser (unless -NoBrowser or a non-interactive session) and - in an
    interactive console - lets you type the path of the ISO you downloaded yourself (or paste the
    official link from that page).

    The last object written to the pipeline is the full path of the ISO (or the URL with -UrlOnly,
    or the setup media folder in the ESD fallback described above). Everything else goes to the
    host and to the log file.

.PARAMETER Language
    ISO language. Accepts Microsoft's names ("English (United States)", "English International",
    "German", "Chinese Simplified", ...), the API names ("English", "English (United Kingdom)") or
    a culture name ("en-US", "de-DE", "pt-BR"). Default: "English (United States)".

.PARAMETER OutFile
    Where to save the ISO. A folder (existing, or ending with \) keeps Microsoft's file name.
    Default: your Downloads folder with Microsoft's file name. An existing valid Windows ISO at that
    path is reused (no download) unless -Force.

.PARAMETER Source
    Where Windows 11 comes from (every source is an official Microsoft server):
      Auto (default)  the Microsoft download page; if that fails (for example 715-123130), the
                      Media Creation Tool image (ESD).
      Website         only the Microsoft download page (the multi-edition ISO).
      Esd             only the Media Creation Tool image (ESD), turned into an ISO on this PC.

.PARAMETER EsdCatalog
    With the ESD source: use this Media Creation Tool catalog instead of asking Microsoft for it -
    a products.cab / products.xml file, or an https link on microsoft.com. The image it lists must
    still be on a Microsoft server and is checked against the SHA-256 / SHA-1 in the catalog.

.PARAMETER UrlOnly
    Only print the official download URL (the ISO link is valid for 24 hours; with the ESD source
    the link of the ESD file); do not download.

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

.EXAMPLE
    .\Get-WindowsIso.ps1 -Source Esd -OutFile D:\ISO\
    (elevated) Downloads Microsoft's Media Creation Tool image for English (United States) and
    turns it into D:\ISO\Windows11-<build>-en-us-x64.iso.

.NOTES
    Lite OS. Windows PowerShell 5.1 compatible, ASCII only. Uses only Microsoft's official servers.
    Lite OS never hosts, uploads or modifies Windows ISO files and never ships product keys.
#>
[CmdletBinding()]
param(
    [string]$Language = 'English (United States)',

    [string]$OutFile,

    [ValidateSet('Auto', 'Website', 'Esd')]
    [string]$Source = 'Auto',

    [string]$EsdCatalog,

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
$script:GetIsoVersion     = '2.1.0'
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

# Media Creation Tool image (ESD). Since 25H2 the Media Creation Tool asks the Microsoft Update
# metadata service (FE3) for its catalog (product Windows.Products.Cab.amd64); the static fwlink is
# the Windows 11 catalog of the 24H2 Media Creation Tool (download.microsoft.com, checked 2026-10).
$script:EsdFe3Uri         = 'https://fe3.delivery.mp.microsoft.com/UpdateMetadataService/updates/search/v1/bydeviceinfo'
$script:EsdFe3Product     = 'PN=Windows.Products.Cab.amd64&V=26100.0.0.0'
$script:EsdFwlink         = 'https://go.microsoft.com/fwlink/?LinkId=2156292'
$script:EsdMinBuild       = 26100
$script:EsdWorkName       = 'LiteOS-ESD'
$script:EsdDismExe        = Join-Path $env:SystemRoot 'System32\dism.exe'
$script:EsdNoIsoMarker    = 'liteos-esd-media.txt'
# Free space while the ESD is turned into setup media + ISO: about 3.8 x the ESD size + 1 GB.
$script:EsdSpaceFactor    = 3.8

# Download progress: this script's percent range for the transfer and its message.
$script:XferBase          = 3.0
$script:XferSpan          = 94.0
$script:XferWhat          = 'Downloading Windows 11'

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
# Folder of this script (builder\New-IsoFile.ps1 is looked up next to it).
$script:IsoScriptDir   = $PSScriptRoot
if ([string]::IsNullOrEmpty($script:IsoScriptDir)) {
    try { $script:IsoScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { $script:IsoScriptDir = '' }
}

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

# Language names (download page API names, page names, common aliases) -> Media Creation Tool
# catalog language codes (products.xml LanguageCode).
$script:EsdLanguageCodes = @{
    'english' = 'en-us'; 'english (united states)' = 'en-us'; 'english (us)' = 'en-us'; 'english us' = 'en-us'; 'en' = 'en-us'
    'english international' = 'en-gb'; 'english (united kingdom)' = 'en-gb'; 'english (uk)' = 'en-gb'
    'arabic' = 'ar-sa'; 'bulgarian' = 'bg-bg'; 'croatian' = 'hr-hr'; 'czech' = 'cs-cz'; 'danish' = 'da-dk'
    'dutch' = 'nl-nl'; 'estonian' = 'et-ee'; 'finnish' = 'fi-fi'; 'french' = 'fr-fr'; 'german' = 'de-de'
    'greek' = 'el-gr'; 'hebrew' = 'he-il'; 'hungarian' = 'hu-hu'; 'italian' = 'it-it'; 'japanese' = 'ja-jp'
    'korean' = 'ko-kr'; 'latvian' = 'lv-lv'; 'lithuanian' = 'lt-lt'; 'polish' = 'pl-pl'; 'romanian' = 'ro-ro'
    'russian' = 'ru-ru'; 'slovak' = 'sk-sk'; 'slovenian' = 'sl-si'; 'spanish' = 'es-es'; 'swedish' = 'sv-se'
    'thai' = 'th-th'; 'turkish' = 'tr-tr'; 'ukrainian' = 'uk-ua'
    'brazilian portuguese' = 'pt-br'; 'portuguese (brazil)' = 'pt-br'; 'portuguese' = 'pt-pt'; 'portuguese (portugal)' = 'pt-pt'
    'chinese (simplified)' = 'zh-cn'; 'chinese simplified' = 'zh-cn'; 'zh-hans' = 'zh-cn'; 'zh-sg' = 'zh-cn'
    'chinese (traditional)' = 'zh-tw'; 'chinese traditional' = 'zh-tw'; 'zh-hant' = 'zh-tw'; 'zh-hk' = 'zh-tw'
    'french canadian' = 'fr-ca'; 'french (canada)' = 'fr-ca'
    'spanish (mexico)' = 'es-mx'; 'es-419' = 'es-mx'
    'serbian latin' = 'sr-latn-rs'; 'serbian (latin)' = 'sr-latn-rs'; 'sr-latn' = 'sr-latn-rs'
    'norwegian' = 'nb-no'; 'norwegian bokmal' = 'nb-no'; 'nb' = 'nb-no'; 'no' = 'nb-no'
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
    $msg = $script:XferWhat
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
    # ISO download = 3..97 of this script's range (the ESD route uses a smaller part of it)
    Write-IsoProgress ($script:XferBase + $script:XferSpan * $pct / 100.0) $msg
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
    param([string]$Link, [string]$Destination, [int64]$ExpectedBytes, [string]$Description = 'Lite OS: official Windows 11 ISO from Microsoft')
    Import-Module BitsTransfer -ErrorAction Stop
    Remove-IsoStaleBitsJobs
    $tmp = $Destination + '.bits'
    if ([System.IO.File]::Exists($tmp)) { [System.IO.File]::Delete($tmp) }
    $job = Start-BitsTransfer -Source $Link -Destination $tmp -Asynchronous -DisplayName $script:BitsDisplayName `
        -Description $Description -Priority Foreground -RetryInterval 60 -RetryTimeout 900 -ErrorAction Stop
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
# Media Creation Tool image (ESD): catalog -> ESD -> Windows setup media -> ISO
# ---------------------------------------------------------------------------------------------
function Test-IsoAdmin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal -ArgumentList $id
        return [bool]$pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Test-EsdOfficialUrl {
    # Microsoft serves the ESDs (dl.delivery.mp.microsoft.com) and the FE3 catalog file over plain
    # http (its CDN certificate does not cover those host names), so http is accepted here - but only
    # on Microsoft's own domains, and every such file is checked against a hash Microsoft publishes.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $u = $null
    if (-not [System.Uri]::TryCreate($Text.Trim(), [System.UriKind]::Absolute, [ref]$u)) { return $false }
    if ($u.Scheme -ne 'https' -and $u.Scheme -ne 'http') { return $false }
    $h = $u.Host.ToLowerInvariant()
    return ($h -eq 'microsoft.com' -or $h.EndsWith('.microsoft.com'))
}

function ConvertTo-IsoAscii {
    # Catalog names like "Norwegian Bokmal (Norway)" carry accents: logs and the GUI get plain ASCII.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.Normalize([System.Text.NormalizationForm]::FormD).ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -eq [System.Globalization.UnicodeCategory]::NonSpacingMark) { continue }
        if ([int]$ch -ge 32 -and [int]$ch -le 126) { [void]$sb.Append($ch) }
    }
    return $sb.ToString().Trim()
}

function Format-IsoDuration {
    param([TimeSpan]$Span)
    if ($Span.TotalMinutes -ge 1) { return ('{0} min {1:00} s' -f [int][math]::Floor($Span.TotalMinutes), $Span.Seconds) }
    return ('{0} s' -f [int][math]::Floor($Span.TotalSeconds))
}

function Get-IsoSmallFile {
    # GET of a small file (a catalog) into memory, with retries. Returns @{ Bytes; FinalUri }.
    param([Parameter(Mandatory = $true)][string]$Uri, [int64]$MaxBytes = 32MB)
    $ProgressPreference = 'SilentlyContinue'
    $last = $null
    for ($i = 1; $i -le 3; $i++) {
        try {
            $r = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
            $bytes = [byte[]]$r.RawContentStream.ToArray()
            $final = $Uri
            try { $final = [string]$r.BaseResponse.ResponseUri.AbsoluteUri } catch { $final = $Uri }
            if ($bytes.Length -gt $MaxBytes) { throw ('{0} is {1}, far more than a catalog' -f (Format-IsoUrlForLog $final), (Format-IsoBytes $bytes.Length)) }
            return @{ Bytes = $bytes; FinalUri = $final }
        }
        catch {
            $last = $_
            if ($i -lt 3) { Start-Sleep -Seconds (2 * $i) }
        }
    }
    throw $last
}

function Join-EsdArgs {
    # Merges two hashtables (the second wins) - argument sets for Invoke-EsdStep.
    param([hashtable]$First, [hashtable]$Second)
    $h = @{}
    foreach ($k in @($First.Keys)) { $h[$k] = $First[$k] }
    foreach ($k in @($Second.Keys)) { $h[$k] = $Second[$k] }
    return $h
}

function Get-EsdFe3Attributes {
    # Device attributes for the FE3 catalog query. Variant 1 describes a released (retail) Windows 11
    # 24H2+ PC; variant 2 is the attribute set the MediaCreationTool.bat forks send (checked against
    # the live service in 2026-09). The service answers every context with the same global catalog,
    # and Get-EsdCandidates keeps released builds only.
    param([int]$Variant = 1)
    $a = @('App=Setup360', 'AppVer=10.0', 'AttrDataVer=338', 'DUScan=1', 'DUInternal=0', 'HotPatchEligible=0',
        'InstallationType=Client', 'IsoCountryShortCode=US', 'OfflineAttributesOnly=0', 'OSArchitecture=AMD64',
        'OSSKUId=48', 'OSVersion=10.0.26100.1', 'LCUVersion=10.0.26100.1', 'MediaVersion=10.0.26100.1', 'EditionId=Professional')
    if ($Variant -le 1) {
        $a += @('CompositionEditionId=Professional', 'MediaBranch=ge_release', 'CurrentBranch=ge_release', 'FlightRing=Retail', 'BuildFlighting=0', 'PreviewBuilds=0')
    }
    else {
        $a += @('CompositionEditionId=Enterprise', 'MediaBranch=br_release', 'CurrentBranch=br_release', 'FlightRing=External', 'FlightingBranchName=CanaryChannel', 'BuildFlighting=1', 'PreviewBuilds=1')
    }
    return ($a -join ';')
}

function Add-EsdFileLocations {
    # Collects the objects that carry a 'Url' (FE3 "FileLocations" entries) from a parsed JSON answer.
    param($Node, [System.Collections.ArrayList]$Into, [int]$Depth = 0)
    if ($null -eq $Node -or $Depth -gt 8) { return }
    if ($Node -is [string] -or $Node -is [System.ValueType]) { return }
    if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [System.Management.Automation.PSCustomObject])) {
        foreach ($x in $Node) { Add-EsdFileLocations -Node $x -Into $Into -Depth ($Depth + 1) }
        return
    }
    $u = Get-IsoProp $Node 'Url'
    if ($u -is [string] -and $u) { [void]$Into.Add($Node) }
    foreach ($p in @($Node.PSObject.Properties)) { Add-EsdFileLocations -Node $p.Value -Into $Into -Depth ($Depth + 1) }
}

function Get-EsdCatalogFe3 {
    # products.cab from the Microsoft Update metadata service (what the 25H2 Media Creation Tool
    # uses). The catalog comes over http and is checked against the SHA-256 the service publishes.
    param([Parameter(Mandatory = $true)][string]$TempDir)
    $ProgressPreference = 'SilentlyContinue'
    $locs = New-Object System.Collections.ArrayList
    foreach ($variant in @(1, 2)) {
        $body = ConvertTo-Json -Compress -InputObject ([ordered]@{ Products = $script:EsdFe3Product; DeviceAttributes = (Get-EsdFe3Attributes -Variant $variant) })
        $r = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $r = Invoke-WebRequest -Uri $script:EsdFe3Uri -Method Post -ContentType 'application/json' -Body $body -Headers @{ Accept = '*/*' } -UseBasicParsing -TimeoutSec $script:HttpTimeoutSec -ErrorAction Stop
                break
            }
            catch {
                $err = $_
                $status = 0
                try { $status = [int]$err.Exception.Response.StatusCode } catch { $status = 0 }
                # An HTTP answer (e.g. 400) will not change; a network hiccup (DNS, reset) may.
                if ($status -gt 0 -or $attempt -ge 3) { throw $err }
                Write-IsoLog ('The Microsoft Update catalog service did not answer (attempt {0} of 3): {1}' -f $attempt, $err.Exception.Message) 'Warn'
                Start-Sleep -Seconds (3 * $attempt)
            }
        }
        $text = ([System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())).Trim()
        if ($text) { Add-EsdFileLocations -Node (ConvertFrom-Json -InputObject $text) -Into $locs }
        if ($locs.Count -gt 0) { break }
        Write-IsoLog ('The Microsoft Update catalog service listed no Media Creation Tool catalog (request {0} of 2).' -f $variant) 'Warn'
    }
    if ($locs.Count -eq 0) { throw 'the service listed no Media Creation Tool catalog' }
    $loc = $null
    foreach ($l in $locs) {
        $n = [string](Get-IsoProp $l 'FileName' '')
        $u = [string](Get-IsoProp $l 'Url' '')
        if ($n -match '(?i)\.cab$' -or $u -match '(?i)\.cab(\?|$)') { $loc = $l; break }
    }
    if ($null -eq $loc) { $loc = $locs[0] }
    $url = [string](Get-IsoProp $loc 'Url' '')
    if (-not (Test-EsdOfficialUrl $url)) { throw ('the catalog link is not on a Microsoft server: {0}' -f (Format-IsoUrlForLog $url)) }
    $digest = ([string](Get-IsoProp $loc 'Digest' '')).Trim()
    if (-not $digest) { throw 'the answer has no SHA-256 digest for the catalog; an unverified catalog is not used' }
    $dl = Get-IsoSmallFile -Uri $url
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $have = [Convert]::ToBase64String($sha.ComputeHash([byte[]]$dl.Bytes)) } finally { $sha.Clear() }
    if ($have -ne $digest) { throw ('the downloaded catalog does not match the SHA-256 Microsoft published ({0}, expected {1})' -f $have, $digest) }
    $cab = Join-Path $TempDir 'products-fe3.cab'
    [System.IO.File]::WriteAllBytes($cab, [byte[]]$dl.Bytes)
    Write-IsoLog ('Catalog from the Microsoft Update service: {0} ({1}, SHA-256 matches)' -f (Format-IsoUrlForLog $url), (Format-IsoBytes $dl.Bytes.Length))
    return $cab
}

function Get-EsdCatalogFwlink {
    # The static Windows 11 Media Creation Tool catalog link (https, download.microsoft.com).
    param([Parameter(Mandatory = $true)][string]$TempDir)
    $dl = Get-IsoSmallFile -Uri $script:EsdFwlink
    if (-not (Test-IsoOfficialUrl $dl.FinalUri)) { throw ('the catalog link led away from microsoft.com: {0}' -f (Format-IsoUrlForLog $dl.FinalUri)) }
    $cab = Join-Path $TempDir 'products-fwlink.cab'
    [System.IO.File]::WriteAllBytes($cab, [byte[]]$dl.Bytes)
    Write-IsoLog ('Catalog from {0} ({1})' -f (Format-IsoUrlForLog $dl.FinalUri), (Format-IsoBytes $dl.Bytes.Length))
    return $cab
}

function Get-EsdCatalogCustom {
    # -EsdCatalog: a products.cab / products.xml file, or an https link on microsoft.com.
    param([Parameter(Mandatory = $true)][string]$TempDir)
    $c = $EsdCatalog.Trim().Trim('"')
    if ($c -match '^(?i)[a-z]+://') {
        if (-not (Test-IsoOfficialUrl $c)) { throw '-EsdCatalog must be a file or an https link on microsoft.com' }
        $dl = Get-IsoSmallFile -Uri $c
        if (-not (Test-IsoOfficialUrl $dl.FinalUri)) { throw ('the catalog link led away from microsoft.com: {0}' -f (Format-IsoUrlForLog $dl.FinalUri)) }
        $path = Join-Path $TempDir 'products-custom.bin'
        [System.IO.File]::WriteAllBytes($path, [byte[]]$dl.Bytes)
        return $path
    }
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($c)
    if (-not [System.IO.File]::Exists($full)) { throw ('file not found: {0}' -f $full) }
    Write-IsoLog ('Catalog from {0}' -f $full)
    return $full
}

function Read-EsdCatalogFile {
    # products.cab (unpacked with expand.exe) or products.xml -> XmlDocument (no DTDs / entities).
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$TempDir)
    $head = New-Object byte[] 4
    $n = 0
    $fs = [System.IO.File]::OpenRead($Path)
    try { $n = $fs.Read($head, 0, 4) } finally { $fs.Dispose() }
    $xmlPath = $Path
    if ($n -eq 4 -and [System.Text.Encoding]::ASCII.GetString($head) -eq 'MSCF') {
        $exe = Join-Path $env:SystemRoot 'System32\expand.exe'
        if (-not [System.IO.File]::Exists($exe)) { throw ('{0} was not found' -f $exe) }
        $xmlPath = Join-Path $TempDir ('products-{0}.xml' -f [guid]::NewGuid().ToString('N'))
        # "expand <cab> <file>": products.cab holds products.xml only. (With a folder as target,
        # expand.exe names a single-file cab's content after the cab itself.)
        $out = @()
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $out = @(& $exe $Path $xmlPath 2>&1 | ForEach-Object { [string]$_ }) }
        finally { $ErrorActionPreference = $eap }
        $code = $LASTEXITCODE
        if ($code -ne 0 -or -not [System.IO.File]::Exists($xmlPath)) {
            $tail = @($out | Where-Object { $_.Trim() } | Select-Object -Last 2) -join ' '
            throw ('expand.exe could not unpack the catalog (exit {0}): {1}' -f $code, $tail)
        }
    }
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $doc = New-Object System.Xml.XmlDocument
    $doc.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($xmlPath, $settings)
    try { $doc.Load($reader) } finally { $reader.Close() }
    return , $doc
}

function Get-EsdXmlText {
    param($Node, [string]$Name)
    $c = $Node.SelectSingleNode(("*[local-name()='{0}']" -f $Name))
    if ($null -eq $c) { return '' }
    return ([string]$c.InnerText).Trim()
}

function ConvertFrom-EsdCatalog {
    # Pure: products.xml -> one entry per ESD file (Editions = the editions the catalog lists for it).
    param([Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Xml)
    $byName = @{}
    $list = New-Object System.Collections.ArrayList
    foreach ($f in @($Xml.SelectNodes("//*[local-name()='File']"))) {
        $name = Get-EsdXmlText $f 'FileName'
        # The name becomes a local file name: plain characters only, no folders.
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.esd$') { continue }
        $edition = Get-EsdXmlText $f 'Edition'
        if ($byName.ContainsKey($name)) {
            if ($edition -and -not $byName[$name].Editions.Contains($edition)) { [void]$byName[$name].Editions.Add($edition) }
            continue
        }
        $size = [int64]0
        if (-not [int64]::TryParse((Get-EsdXmlText $f 'Size'), [ref]$size)) { $size = [int64]0 }
        $build = 0
        $ubr = 0
        $m = [regex]::Match($name, '^(\d{5,})\.(\d+)\.')
        if ($m.Success) { $build = [int]$m.Groups[1].Value; $ubr = [int]$m.Groups[2].Value }
        # Catalog 2.1 (FE3, 26H2+) lists <Sha256>, older catalogs <Sha1>.
        $algo = ''
        $hash = (Get-EsdXmlText $f 'Sha256').ToLowerInvariant()
        if ($hash -match '^[0-9a-f]{64}$') { $algo = 'SHA256' }
        else {
            $hash = (Get-EsdXmlText $f 'Sha1').ToLowerInvariant()
            if ($hash -match '^[0-9a-f]{40}$') { $algo = 'SHA1' } else { $hash = '' }
        }
        $entry = [pscustomobject]@{
            FileName      = $name
            LanguageCode  = (Get-EsdXmlText $f 'LanguageCode').ToLowerInvariant()
            Language      = (ConvertTo-IsoAscii (Get-EsdXmlText $f 'Language'))
            Architecture  = (Get-EsdXmlText $f 'Architecture')
            Size          = $size
            HashAlgorithm = $algo
            Hash          = $hash
            Url           = (Get-EsdXmlText $f 'FilePath')
            Build         = $build
            Ubr           = $ubr
            Editions      = (New-Object System.Collections.ArrayList)
        }
        if ($edition) { [void]$entry.Editions.Add($edition) }
        $byName[$name] = $entry
        [void]$list.Add($entry)
    }
    return , $list.ToArray()
}

function Get-EsdCandidates {
    # Pure: the released x64 consumer images (CLIENTCONSUMER_RET: Home, Pro, Education ...) of
    # Windows 11 24H2 or newer that carry a SHA-256 / SHA-1 and a Microsoft link.
    param([object[]]$Entries)
    $list = @(@($Entries) | Where-Object {
            $null -ne $_ -and $_.Architecture -ieq 'x64' -and $_.FileName -match '(?i)_CLIENTCONSUMER_RET_' -and
            $_.FileName -notmatch '(?i)prerelease' -and $_.Build -ge $script:EsdMinBuild -and $_.LanguageCode -and
            $_.HashAlgorithm -and $_.Hash -and (Test-EsdOfficialUrl $_.Url)
        })
    return , $list
}

function Get-EsdLanguages {
    # Pure: distinct languages of the candidates -> objects { Code; Name }, sorted by code.
    param([object[]]$Candidates)
    $seen = @{}
    $list = New-Object System.Collections.ArrayList
    foreach ($c in @($Candidates)) {
        if ($null -eq $c -or $seen.ContainsKey($c.LanguageCode)) { continue }
        $seen[$c.LanguageCode] = $true
        [void]$list.Add([pscustomobject]@{ Code = $c.LanguageCode; Name = $c.Language })
    }
    return , @($list | Sort-Object -Property Code)
}

function Resolve-EsdLanguageCode {
    # Pure: -Language as a culture code ("en-US"), Microsoft's ISO language name ("English
    # International", "Chinese Simplified"), the catalog's name ("German (Germany)") or a bare
    # language ("de", "German") -> one of the catalog's language codes, or $null.
    param([string]$Language, [object[]]$Available)
    $want = ([string]$Language).Trim().ToLowerInvariant()
    if (-not $want) { $want = 'english (united states)' }
    $codes = New-Object System.Collections.Generic.List[string]
    foreach ($a in @($Available)) {
        $c = ([string](Get-IsoProp $a 'Code' '')).ToLowerInvariant()
        if ($c -and -not $codes.Contains($c)) { $codes.Add($c) }
    }
    if ($codes.Contains($want)) { return $want }
    if ($script:EsdLanguageCodes.ContainsKey($want)) {
        $alias = [string]$script:EsdLanguageCodes[$want]
        if ($codes.Contains($alias)) { return $alias }
    }
    foreach ($a in @($Available)) {
        $c = ([string](Get-IsoProp $a 'Code' '')).ToLowerInvariant()
        $nm = ([string](Get-IsoProp $a 'Name' '')).ToLowerInvariant()
        if ($nm -and $want -eq $nm) { return $c }
        $en = ''
        try { $en = (ConvertTo-IsoAscii ([System.Globalization.CultureInfo]::GetCultureInfo($c).EnglishName)).ToLowerInvariant() } catch { $en = '' }
        if ($en -and $want -eq $en) { return $c }
    }
    # A bare language: that language's catalog code, preferring the matching region (de-de, en-us).
    $lang = ''
    $mm = [regex]::Match($want, '^([a-z]{2,3})(-|$)')
    if ($mm.Success) { $lang = $mm.Groups[1].Value }
    else {
        try {
            foreach ($ci in [System.Globalization.CultureInfo]::GetCultures([System.Globalization.CultureTypes]::NeutralCultures)) {
                if ((ConvertTo-IsoAscii $ci.EnglishName).ToLowerInvariant() -eq $want) { $lang = $ci.TwoLetterISOLanguageName.ToLowerInvariant(); break }
            }
        }
        catch { $lang = '' }
    }
    if (-not $lang) { return $null }
    $same = @($codes | Where-Object { $_.StartsWith($lang + '-') } | Sort-Object)
    if ($same.Count -eq 0) { return $null }
    $pref = $lang + '-' + $lang
    if ($lang -eq 'en') { $pref = 'en-us' }
    if ($same -contains $pref) { return $pref }
    return [string]$same[0]
}

function Select-EsdFile {
    # Pure: the newest released x64 consumer ESD for -Language, or a clear error.
    param([object[]]$Entries, [string]$Language)
    $cands = Get-EsdCandidates -Entries $Entries
    if ($cands.Count -eq 0) { throw 'it lists no released Windows 11 x64 consumer image (CLIENTCONSUMER_RET)' }
    $langs = Get-EsdLanguages -Candidates $cands
    $code = Resolve-EsdLanguageCode -Language $Language -Available $langs
    if (-not $code) {
        $names = @($langs | ForEach-Object { [string]$_.Code })
        throw ("language '{0}' is not in it (it has {1}; -ListLanguages shows their names)" -f $Language, ($names -join ', '))
    }
    $pick = @($cands | Where-Object { $_.LanguageCode -eq $code } |
            Sort-Object -Property @{ Expression = { $_.Build }; Descending = $true }, @{ Expression = { $_.Ubr }; Descending = $true }) | Select-Object -First 1
    return $pick
}

function Get-EsdCatalogEntries {
    # Tries the catalog sources in order (Microsoft Update service, then the static link; only
    # -EsdCatalog when given). Returns @{ Entries; Name; Pick } of the first usable catalog - with
    # -ForLanguage the first one that offers that language (Pick = its ESD entry).
    param([string]$ForLanguage)
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('LiteOS-esd-catalog-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($temp)
    $why = New-Object System.Collections.Generic.List[string]
    $kinds = @('fe3', 'fwlink')
    if (-not [string]::IsNullOrWhiteSpace($EsdCatalog)) { $kinds = @('custom') }
    try {
        foreach ($kind in $kinds) {
            $label = '-EsdCatalog'
            if ($kind -eq 'fe3') { $label = 'Microsoft Update catalog service' }
            elseif ($kind -eq 'fwlink') { $label = 'Windows 11 Media Creation Tool catalog link' }
            try {
                $file = $null
                if ($kind -eq 'fe3') { $file = Get-EsdCatalogFe3 -TempDir $temp }
                elseif ($kind -eq 'fwlink') { $file = Get-EsdCatalogFwlink -TempDir $temp }
                else { $file = Get-EsdCatalogCustom -TempDir $temp }
                $xml = Read-EsdCatalogFile -Path $file -TempDir $temp
                $entries = ConvertFrom-EsdCatalog -Xml $xml
                $cands = Get-EsdCandidates -Entries $entries
                if ($cands.Count -eq 0) { throw 'it lists no released Windows 11 x64 consumer image (CLIENTCONSUMER_RET)' }
                $newest = $cands | Sort-Object -Property Build, Ubr -Descending | Select-Object -First 1
                Write-IsoLog ('{0}: {1} Windows 11 x64 consumer images, newest build {2}.{3}' -f $label, $cands.Count, $newest.Build, $newest.Ubr)
                $res = @{ Entries = $entries; Name = $label; Pick = $null }
                if ($ForLanguage) { $res.Pick = Select-EsdFile -Entries $entries -Language $ForLanguage }
                return $res
            }
            catch {
                $msg = ($_.Exception.Message -replace '[\r\n]+', ' ').Trim()
                $why.Add(('{0}: {1}' -f $label, $msg))
                Write-IsoLog ('{0} could not be used: {1}' -f $label, $msg) 'Warn'
            }
        }
    }
    finally {
        try { [System.IO.Directory]::Delete($temp, $true) } catch { $null = $_ }
    }
    throw ('Microsoft''s Media Creation Tool catalog could not be used ({0}).' -f ($why -join ' | '))
}

function Get-EsdLanguageList {
    # -ListLanguages for the ESD source.
    $cat = Get-EsdCatalogEntries
    $cands = Get-EsdCandidates -Entries $cat.Entries
    foreach ($l in (Get-EsdLanguages -Candidates $cands)) {
        $newest = $cands | Where-Object { $_.LanguageCode -eq $l.Code } | Sort-Object -Property Build, Ubr -Descending | Select-Object -First 1
        [pscustomobject]@{
            Language     = [string]$l.Name
            LanguageCode = [string]$l.Code
            Build        = ('{0}.{1}' -f $newest.Build, $newest.Ubr)
            Source       = 'Media Creation Tool image (ESD)'
        }
    }
}

# Script blocks run by Invoke-EsdStep in a separate runspace (so this script can report progress
# while DISM works). Each one uses the DISM cmdlets, or dism.exe when $UseExe.
$script:EsdHashScript = {
    param([string]$Path, [string]$Algorithm)
    $ErrorActionPreference = 'Stop'
    (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash
}

$script:EsdInfoScript = {
    param([string]$Esd, [bool]$UseExe, [string]$Dism, [string]$LogPath, [string]$Scratch)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    if (-not $UseExe) {
        foreach ($i in @(Get-WindowsImage -ImagePath $Esd -LogPath $LogPath -ScratchDirectory $Scratch)) { '{0}|{1}' -f $i.ImageIndex, $i.ImageName }
        return
    }
    $ErrorActionPreference = 'Continue'
    $out = @(& $Dism '/English' '/Get-WimInfo' ('/WimFile:' + $Esd) ('/LogPath:' + $LogPath) 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw ('dism.exe /Get-WimInfo failed (exit {0}): {1}' -f $LASTEXITCODE, (@($out | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' ')) }
    $idx = ''
    foreach ($l in $out) {
        if ($l -match '^\s*Index\s*:\s*(\d+)') { $idx = $Matches[1] }
        elseif ($idx -and $l -match '^\s*Name\s*:\s*(.+?)\s*$') { '{0}|{1}' -f $idx, $Matches[1]; $idx = '' }
    }
}

$script:EsdApplyScript = {
    param([string]$Esd, [int]$Index, [string]$ApplyDir, [bool]$UseExe, [string]$Dism, [string]$LogPath, [string]$Scratch)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    if (-not $UseExe) {
        $null = Expand-WindowsImage -ImagePath $Esd -Index $Index -ApplyPath $ApplyDir -LogPath $LogPath -ScratchDirectory $Scratch
        return
    }
    $ErrorActionPreference = 'Continue'
    $out = @(& $Dism '/English' '/Apply-Image' ('/ImageFile:' + $Esd) ('/Index:' + $Index) ('/ApplyDir:' + $ApplyDir) ('/LogPath:' + $LogPath) ('/ScratchDir:' + $Scratch) 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw ('dism.exe /Apply-Image failed (exit {0}): {1}' -f $LASTEXITCODE, (@($out | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' ')) }
}

$script:EsdExportScript = {
    param([string]$Esd, [int]$Index, [string]$Destination, [string]$Compression, [bool]$Bootable, [bool]$UseExe, [string]$Dism, [string]$LogPath, [string]$Scratch)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    if (-not $UseExe) {
        $p = @{ SourceImagePath = $Esd; SourceIndex = $Index; DestinationImagePath = $Destination; LogPath = $LogPath; ScratchDirectory = $Scratch }
        if ($Compression) { $p['CompressionType'] = $Compression }
        if ($Bootable) { $p['Setbootable'] = $true }
        $null = Export-WindowsImage @p
        return
    }
    $a = @('/English', '/Export-Image', ('/SourceImageFile:' + $Esd), ('/SourceIndex:' + $Index), ('/DestinationImageFile:' + $Destination), ('/LogPath:' + $LogPath), ('/ScratchDir:' + $Scratch))
    if ($Compression) { $a += ('/Compress:' + $Compression) }
    if ($Bootable) { $a += '/Bootable' }
    $ErrorActionPreference = 'Continue'
    $out = @(& $Dism @a 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw ('dism.exe /Export-Image failed (exit {0}): {1}' -f $LASTEXITCODE, (@($out | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' ')) }
}

$script:EsdIsoScript = {
    param([string]$Tool, [string]$Source, [string]$Output, [string]$Label)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $null = & $Tool -SourcePath $Source -OutputPath $Output -VolumeLabel $Label -Force
}

function Invoke-EsdStep {
    # Runs one long step (hash, DISM, ISO writer) in a separate runspace and reports progress every
    # 20 s, so the GUI / log show it is still working. Returns the step's output as strings; its
    # Write-Host lines go to the log. Throws "<Message> failed: <reason>".
    param([Parameter(Mandatory = $true)][string]$Message, [double]$Percent, [Parameter(Mandatory = $true)][scriptblock]$Script, [hashtable]$Arguments)
    Write-IsoLog $Message
    Write-IsoProgress $Percent $Message -Always
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $handle = $null
    try {
        [void]$ps.AddScript($Script.ToString())
        if ($null -ne $Arguments -and $Arguments.Count -gt 0) { [void]$ps.AddParameters($Arguments) }
        $handle = $ps.BeginInvoke()
        $nextBeat = 20
        while (-not $handle.AsyncWaitHandle.WaitOne(500)) {
            if ($clock.Elapsed.TotalSeconds -ge $nextBeat) {
                Write-IsoProgress $Percent ('{0} ({1})' -f $Message, (Format-IsoDuration $clock.Elapsed)) -Always
                $nextBeat += 20
            }
        }
        $out = $null
        try { $out = $ps.EndInvoke($handle) }
        catch {
            $e = $_.Exception
            if ($e -is [System.Management.Automation.MethodInvocationException] -and $null -ne $e.InnerException) { $e = $e.InnerException }
            $why = $e.Message
            if ($e -is [System.Management.Automation.RuntimeException] -and $null -ne $e.ErrorRecord -and $null -ne $e.ErrorRecord.Exception) { $why = $e.ErrorRecord.Exception.Message }
            throw ('{0} failed: {1}' -f $Message, (($why -replace '[\r\n]+', ' ').Trim()))
        }
        finally {
            foreach ($rec in @($ps.Streams.Information)) {
                $t = ([string]$rec.MessageData).Trim()
                if ($t) { Write-IsoLog ('  ' + $t) }
            }
        }
        Write-IsoLog ('Done in {0}.' -f (Format-IsoDuration $clock.Elapsed))
        $list = New-Object System.Collections.Generic.List[string]
        foreach ($o in @($out)) { if ($null -ne $o) { $list.Add([string]$o) } }
        return , $list.ToArray()
    }
    finally {
        if ($null -ne $handle -and -not $handle.IsCompleted) { try { $ps.Stop() } catch { $null = $_ } }
        $ps.Dispose()
    }
}

function Test-EsdHash {
    # The file's SHA-256 / SHA-1 against the value in Microsoft's catalog.
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Hash,
        [ValidateSet('SHA256', 'SHA1')][string]$Algorithm = 'SHA256', [double]$Percent = 74)
    $label = 'SHA-256'
    if ($Algorithm -eq 'SHA1') { $label = 'SHA-1' }
    $out = Invoke-EsdStep -Message ('Checking the image against the {0} in Microsoft''s catalog' -f $label) -Percent $Percent -Script $script:EsdHashScript -Arguments @{ Path = $Path; Algorithm = $Algorithm }
    $have = ''
    if ($out.Count -gt 0) { $have = ([string]$out[$out.Count - 1]).Trim().ToLowerInvariant() }
    if ($have -and $have -eq $Hash.ToLowerInvariant()) { Write-IsoLog ('{0} {1} matches the catalog.' -f $label, $have) 'Ok'; return $true }
    Write-IsoLog ('{0} mismatch: the file has {1}, the catalog says {2}.' -f $label, $have, $Hash) 'Warn'
    return $false
}

function Save-EsdFile {
    # Downloads the catalog's ESD into the work folder (BITS first, resumable HttpClient fallback)
    # and checks size + SHA-256 / SHA-1. A complete, verified ESD from an earlier run is reused.
    param([Parameter(Mandatory = $true)]$Entry, [Parameter(Mandatory = $true)][string]$WorkDir)
    $esd = Join-Path $WorkDir $Entry.FileName
    foreach ($f in @([System.IO.Directory]::GetFiles($WorkDir))) {
        $n = [System.IO.Path]::GetFileName($f)
        if ($n -match '(?i)\.esd(\.part|\.part\.json|\.bits)?$' -and -not $n.StartsWith($Entry.FileName, [StringComparison]::OrdinalIgnoreCase)) {
            Write-IsoLog ('Removing {0} (an older Windows image from an earlier run).' -f $n) 'Warn'
            try { [System.IO.File]::Delete($f) } catch { Write-IsoLog ('Could not delete {0}: {1}' -f $f, $_.Exception.Message) 'Warn' }
        }
    }
    if ([System.IO.File]::Exists($esd)) {
        $len = (New-Object System.IO.FileInfo -ArgumentList $esd).Length
        if (($Entry.Size -le 0 -or $len -eq $Entry.Size) -and (Test-EsdHash -Path $esd -Hash $Entry.Hash -Algorithm $Entry.HashAlgorithm)) {
            Write-IsoLog ('Using the Windows image downloaded earlier: {0}' -f $esd) 'Ok'
            return $esd
        }
        Write-IsoLog 'The Windows image from an earlier run is incomplete or damaged; downloading it again.' 'Warn'
        [System.IO.File]::Delete($esd)
    }
    $partLen = [int64]0
    if ([System.IO.File]::Exists($esd + '.part')) { $partLen = (New-Object System.IO.FileInfo -ArgumentList ($esd + '.part')).Length }
    $tmp = $null
    $via = 'HTTP'
    if (-not $NoBits -and $partLen -eq 0) {
        try {
            $tmp = Save-IsoWithBits -Link $Entry.Url -Destination $esd -ExpectedBytes $Entry.Size -Description 'Lite OS: official Windows 11 image (ESD) from Microsoft'
            $via = 'BITS'
        }
        catch {
            Write-IsoLog ('BITS download did not work, switching to a direct download: {0}' -f $_.Exception.Message) 'Warn'
            $tmp = $null
        }
    }
    elseif ($partLen -gt 0) {
        Write-IsoLog ('Found a partial download ({0}); resuming it directly.' -f (Format-IsoBytes $partLen))
    }
    if ($null -eq $tmp) { $tmp = Save-IsoWithHttp -Link $Entry.Url -Destination $esd -ExpectedBytes $Entry.Size }
    $got = (New-Object System.IO.FileInfo -ArgumentList $tmp).Length
    if ($Entry.Size -gt 0 -and $got -ne $Entry.Size) {
        Remove-IsoPart -Part $tmp
        throw ('The Windows image download is incomplete ({0} of {1}). It was deleted; please try again.' -f (Format-IsoBytes $got), (Format-IsoBytes $Entry.Size))
    }
    if (-not (Test-EsdHash -Path $tmp -Hash $Entry.Hash -Algorithm $Entry.HashAlgorithm)) {
        Remove-IsoPart -Part $tmp
        throw 'The downloaded Windows image does not match the hash in Microsoft''s catalog (damaged download). It was deleted; please try again.'
    }
    [System.IO.File]::Move($tmp, $esd)
    Write-IsoLog ('Downloaded {0} via {1}.' -f (Format-IsoBytes $got), $via) 'Ok'
    return $esd
}

function Test-EsdLayout {
    # Pure: a Media Creation Tool ESD holds 1 = Windows Setup Media, 2 = Windows PE, 3 = Windows
    # Setup, 4+ = the editions. Returns '' when the image list fits, else the reason.
    param([object[]]$Images)
    $list = @($Images)
    if ($list.Count -lt 4) { return ('the ESD holds {0} images; a Media Creation Tool ESD has at least 4' -f $list.Count) }
    for ($k = 0; $k -lt $list.Count; $k++) {
        if ([int]$list[$k].Index -ne ($k + 1)) { return 'the image numbers in the ESD are not 1, 2, 3, ...' }
    }
    if ([string]$list[0].Name -notmatch '(?i)setup media') { return ("image 1 is '{0}', not Windows Setup Media" -f $list[0].Name) }
    if ([string]$list[1].Name -notmatch '(?i)\bPE\b') { return ("image 2 is '{0}', not Windows PE" -f $list[1].Name) }
    if ([string]$list[2].Name -notmatch '(?i)setup') { return ("image 3 is '{0}', not Windows Setup" -f $list[2].Name) }
    for ($k = 3; $k -lt $list.Count; $k++) {
        if ([string]$list[$k].Name -notmatch '(?i)windows') { return ("image {0} is '{1}', not a Windows edition" -f $list[$k].Index, $list[$k].Name) }
    }
    return ''
}

function Get-EsdDismLog {
    if ($script:LogFile) { return [System.IO.Path]::ChangeExtension($script:LogFile, '.dism.log') }
    return (Join-Path ([System.IO.Path]::GetTempPath()) ('LiteOS-Get-WindowsIso-dism-{0}.log' -f (Get-Date).ToString('yyyyMMdd-HHmmss')))
}

function Convert-EsdToMedia {
    # ESD -> Windows setup media folder with the layout of Microsoft's ISO. Returns the edition names.
    param([Parameter(Mandatory = $true)][string]$Esd, [Parameter(Mandatory = $true)][string]$MediaDir, [Parameter(Mandatory = $true)][string]$ScratchDir)
    $useExe = $false
    foreach ($c in @('Get-WindowsImage', 'Expand-WindowsImage', 'Export-WindowsImage')) {
        if ($null -eq (Get-Command -Name $c -ErrorAction SilentlyContinue)) { $useExe = $true }
    }
    $dism = $script:EsdDismExe
    if ($useExe) {
        if (-not [System.IO.File]::Exists($dism)) { throw 'Neither the DISM PowerShell module nor dism.exe is available on this PC.' }
        Write-IsoLog 'The DISM PowerShell module is not available; using dism.exe.' 'Warn'
    }
    foreach ($d in @($MediaDir, $ScratchDir)) { [void][System.IO.Directory]::CreateDirectory($d) }
    $dismLog = Get-EsdDismLog
    Write-IsoLog ('DISM log: {0}' -f $dismLog)
    $common = @{ UseExe = $useExe; Dism = $dism; LogPath = $dismLog; Scratch = $ScratchDir }

    $lines = Invoke-EsdStep -Message 'Reading the list of images in the ESD' -Percent 75 -Script $script:EsdInfoScript -Arguments (Join-EsdArgs $common @{ Esd = $Esd })
    $found = New-Object System.Collections.ArrayList
    foreach ($l in $lines) {
        $m = [regex]::Match([string]$l, '^(\d+)\|(.*)$')
        if ($m.Success) { [void]$found.Add([pscustomobject]@{ Index = [int]$m.Groups[1].Value; Name = $m.Groups[2].Value.Trim() }) }
    }
    $images = @($found | Sort-Object -Property Index)
    foreach ($i in $images) { Write-IsoLog ('  image {0}: {1}' -f $i.Index, $i.Name) }
    $bad = Test-EsdLayout -Images $images
    if ($bad) { throw ('This is not the expected Media Creation Tool image: {0}.' -f $bad) }

    $null = Invoke-EsdStep -Message 'Unpacking the Windows setup files (image 1)' -Percent 76 -Script $script:EsdApplyScript -Arguments (Join-EsdArgs $common @{ Esd = $Esd; Index = 1; ApplyDir = $MediaDir })
    $sources = Join-Path $MediaDir 'sources'
    if (-not [System.IO.Directory]::Exists($sources)) { [void][System.IO.Directory]::CreateDirectory($sources) }
    foreach ($n in @('boot.wim', 'install.wim', 'install.esd')) {
        $p = Join-Path $sources $n
        if ([System.IO.File]::Exists($p)) { Write-IsoLog ('Replacing sources\{0} from image 1.' -f $n) 'Warn'; [System.IO.File]::Delete($p) }
    }
    # boot.wim like Microsoft's ISO: 1 = Windows PE, 2 = Windows Setup (the boot image).
    $boot = Join-Path $sources 'boot.wim'
    $null = Invoke-EsdStep -Message 'Writing sources\boot.wim: Windows PE (image 2)' -Percent 78 -Script $script:EsdExportScript -Arguments (Join-EsdArgs $common @{ Esd = $Esd; Index = 2; Destination = $boot; Compression = 'max'; Bootable = $false })
    $null = Invoke-EsdStep -Message 'Writing sources\boot.wim: Windows Setup (image 3, bootable)' -Percent 80 -Script $script:EsdExportScript -Arguments (Join-EsdArgs $common @{ Esd = $Esd; Index = 3; Destination = $boot; Compression = ''; Bootable = $true })
    # install.wim: every edition, fast compression (the builder exports the edition it keeps again).
    $install = Join-Path $sources 'install.wim'
    $editions = @($images | Where-Object { $_.Index -ge 4 })
    $k = 0
    foreach ($e in $editions) {
        $k++
        $comp = ''
        if ($k -eq 1) { $comp = 'fast' }
        $pct = 82 + 8.0 * ($k - 1) / $editions.Count
        $null = Invoke-EsdStep -Message ('Writing sources\install.wim: {0} (edition {1} of {2})' -f $e.Name, $k, $editions.Count) -Percent $pct -Script $script:EsdExportScript -Arguments (Join-EsdArgs $common @{ Esd = $Esd; Index = [int]$e.Index; Destination = $install; Compression = $comp; Bootable = $false })
    }
    foreach ($need in @('setup.exe', 'sources\boot.wim', 'sources\install.wim', 'efi\microsoft\boot\efisys.bin')) {
        if (-not [System.IO.File]::Exists((Join-Path $MediaDir $need))) { throw ('The Windows setup media made from the ESD is incomplete: {0} is missing.' -f $need) }
    }
    return , @($editions | ForEach-Object { [string]$_.Name })
}

function Remove-EsdFolder {
    # Deletes one of this script's own work folders; never fails the run.
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path) -or -not [System.IO.Directory]::Exists($Path)) { return }
    for ($i = 1; $i -le 3; $i++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        }
        catch {
            if ($i -ge 3) { Write-IsoLog ('Could not delete {0}: {1}' -f $Path, $_.Exception.Message) 'Warn'; return }
            # The ISO writer's COM streams (IMAPI2 / ADODB) keep boot files open until collected.
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            Start-Sleep -Seconds 2
        }
    }
}

function Get-EsdFolderBytes {
    param([string]$Path)
    $sum = [int64]0
    foreach ($f in [System.IO.Directory]::GetFiles($Path, '*', [System.IO.SearchOption]::AllDirectories)) { $sum += (New-Object System.IO.FileInfo -ArgumentList $f).Length }
    return $sum
}

function Get-EsdVolumeLabel {
    # Pure: the volume label Microsoft's own media use, e.g. CCCOMA_X64FRE_EN-US_DV9.
    param([string]$LanguageCode)
    $code = ([string]$LanguageCode).ToUpperInvariant() -replace '[^A-Z0-9\-]', ''
    if (-not $code) { $code = 'EN-US' }
    return ('CCCOMA_X64FRE_{0}_DV9' -f $code)
}

function New-EsdIsoFile {
    # Setup media folder -> bootable ISO with builder\New-IsoFile.ps1 (oscdimg or IMAPI2).
    param([string]$Tool, [string]$MediaDir, [string]$Destination, [string]$Label)
    $a = @{ Tool = $Tool; Source = $MediaDir; Output = $Destination; Label = $Label }
    try {
        $null = Invoke-EsdStep -Message ('Writing the bootable ISO {0}' -f $Destination) -Percent 91 -Script $script:EsdIsoScript -Arguments $a
    }
    catch {
        if ($_.Exception.Message -notmatch '(?i)execution polic|not digitally signed|running scripts is disabled') { throw }
        Write-IsoLog 'The helper runspace may not run scripts here; writing the ISO in this PowerShell instead.' 'Warn'
        $ProgressPreference = 'SilentlyContinue'
        $null = & $Tool -SourcePath $MediaDir -OutputPath $Destination -VolumeLabel $Label -Force
    }
    if (-not [System.IO.File]::Exists($Destination)) { throw 'builder\New-IsoFile.ps1 did not write the ISO.' }
}

function Invoke-EsdRoute {
    # The ESD source end to end: catalog -> ESD -> setup media -> ISO. Returns the ISO path (the
    # ESD link with -UrlOnly; the setup media folder when builder\New-IsoFile.ps1 is missing).
    param([Parameter(Mandatory = $true)][hashtable]$Target)
    # 2: after the download page's own 0..2 when -Source Auto falls back to this route.
    Write-IsoProgress 2 'Reading Microsoft''s Media Creation Tool catalog' -Always
    $lang = ([string]$Language).Trim()
    if (-not $lang) { $lang = 'English (United States)' }
    $cat = Get-EsdCatalogEntries -ForLanguage $lang
    $entry = $cat.Pick
    $buildText = '{0}.{1}' -f $entry.Build, $entry.Ubr
    Write-IsoLog ('Media Creation Tool image: {0} ({1}, Windows 11 build {2}, {3}; from the {4})' -f $entry.FileName, (Format-IsoBytes $entry.Size), $buildText, $entry.Language, $cat.Name) 'Ok'
    Write-IsoLog ('Official link: {0} ({1} {2})' -f $entry.Url, $entry.HashAlgorithm, $entry.Hash)
    if ($entry.Build -lt 26200) { Write-IsoLog ('This catalog offers build {0} (Windows 11 24H2); Windows Update brings the installed system up to date.' -f $buildText) 'Warn' }
    if ($UrlOnly) {
        Write-IsoProgress 100 'Download link ready' -Always
        return [string]$entry.Url
    }

    $dest = $Target.Path
    if ($Target.IsFolder) { $dest = Join-Path $Target.Path ('Windows11-{0}-{1}-x64.iso' -f $buildText, $entry.LanguageCode) }
    if ([System.IO.File]::Exists($dest) -and -not $Force) {
        $existing = Test-WindowsIsoFile -Path $dest
        if ($existing.Valid) {
            Write-IsoLog ('Using the Windows ISO already at {0} ({1}). Use -Force to make it again.' -f $dest, (Format-IsoBytes $existing.Size)) 'Ok'
            Write-IsoProgress 100 'Windows 11 ISO ready (made earlier)' -Always
            return $dest
        }
        throw ('{0} already exists and is not a valid Windows 11 ISO ({1}). Delete it or use -Force.' -f $dest, $existing.Reason)
    }
    if (-not (Test-IsoAdmin)) {
        throw 'Turning Microsoft''s ESD image into Windows setup media uses DISM, which needs administrator rights. Run this from an elevated PowerShell (Lite OS Builder and Build-LiteOS.ps1 already run elevated).'
    }
    $destDir = [System.IO.Path]::GetDirectoryName($dest)
    if (-not [System.IO.Directory]::Exists($destDir)) { [void][System.IO.Directory]::CreateDirectory($destDir) }
    $work = Join-Path $destDir $script:EsdWorkName
    [void][System.IO.Directory]::CreateDirectory($work)
    $media = Join-Path $work 'media'
    $scratch = Join-Path $work 'scratch'
    foreach ($d in @($media, $scratch)) {
        if ([System.IO.Directory]::Exists($d)) { Write-IsoLog ('Removing {0} left over from an earlier run.' -f $d) 'Warn'; Remove-EsdFolder $d }
    }

    # Space: the ESD, the setup media made from it (about 1.9 x the ESD) and the ISO (the same again);
    # the ESD is deleted before the ISO is written when space is short.
    $esdSize = [int64]$entry.Size
    if ($esdSize -le 0) { $esdSize = [int64]5GB }
    $haveEsd = [int64]0
    $esdFinal = Join-Path $work $entry.FileName
    if ([System.IO.File]::Exists($esdFinal)) { $haveEsd = (New-Object System.IO.FileInfo -ArgumentList $esdFinal).Length }
    elseif ([System.IO.File]::Exists($esdFinal + '.part')) { $haveEsd = (New-Object System.IO.FileInfo -ArgumentList ($esdFinal + '.part')).Length }
    $need = [int64]($script:EsdSpaceFactor * $esdSize) + [int64]1GB - $haveEsd
    $free = Get-IsoFreeBytes -Folder $work
    if ($free -ge 0 -and $free -lt $need) {
        throw ('Not enough free space on {0}: {1} free, about {2} needed to download Microsoft''s Windows image ({3}) and turn it into an ISO. Free up space or choose an -OutFile on another drive.' -f ([System.IO.Path]::GetPathRoot($work)), (Format-IsoBytes $free), (Format-IsoBytes $need), (Format-IsoBytes $esdSize))
    }
    Write-IsoLog ('Work folder: {0}' -f $work)

    $script:XferBase = 3.0
    $script:XferSpan = 70.0
    $script:XferWhat = 'Downloading the Windows 11 image (ESD)'
    $esd = $null
    $ok = $false
    $result = $null
    $readyText = 'Windows 11 ISO ready'
    try {
        Write-IsoProgress 3 'Starting the download from Microsoft' -Always
        $esd = Save-EsdFile -Entry $entry -WorkDir $work
        $editions = Convert-EsdToMedia -Esd $esd -MediaDir $media -ScratchDir $scratch
        Write-IsoLog ('Windows setup media ready ({0} editions).' -f $editions.Count) 'Ok'
        Remove-EsdFolder $scratch
        $tool = ''
        if (-not [string]::IsNullOrEmpty($script:IsoScriptDir)) { $tool = Join-Path $script:IsoScriptDir 'New-IsoFile.ps1' }
        if (-not $tool -or -not [System.IO.File]::Exists($tool)) {
            # No ISO writer next to this script: the setup media folder is the result.
            $folder = Join-Path $destDir ([System.IO.Path]::GetFileNameWithoutExtension($dest))
            $marker = $folder + '.' + $script:EsdNoIsoMarker
            if ([System.IO.Directory]::Exists($folder)) {
                if (-not [System.IO.File]::Exists($marker)) { throw ('{0} already exists; move it away (the Windows setup media would be put there).' -f $folder) }
                Remove-EsdFolder $folder
            }
            [System.IO.Directory]::Move($media, $folder)
            [System.IO.File]::WriteAllText($marker, ('Windows setup media made by Lite OS Get-WindowsIso.ps1 from Microsoft''s {0}. Delete this file together with the folder.' -f $entry.FileName))
            Write-IsoLog ('builder\New-IsoFile.ps1 was not found, so no ISO was written. The Windows setup media folder is {0} (Build-LiteOS.ps1 -IsoPath accepts it).' -f $folder) 'Warn'
            $result = $folder
            $readyText = 'Windows 11 setup media ready'
        }
        else {
            $mediaBytes = Get-EsdFolderBytes $media
            $free = Get-IsoFreeBytes -Folder $work
            if ($free -ge 0 -and $free -lt ($mediaBytes + 512MB)) {
                Write-IsoLog 'Deleting the ESD now to make room for the ISO.' 'Warn'
                [System.IO.File]::Delete($esd)
                $free = Get-IsoFreeBytes -Folder $work
                if ($free -ge 0 -and $free -lt ($mediaBytes + 512MB)) {
                    throw ('Not enough free space for the ISO on {0}: {1} free, {2} needed.' -f ([System.IO.Path]::GetPathRoot($work)), (Format-IsoBytes $free), (Format-IsoBytes ($mediaBytes + 512MB)))
                }
            }
            New-EsdIsoFile -Tool $tool -MediaDir $media -Destination $dest -Label (Get-EsdVolumeLabel $entry.LanguageCode)
            Write-IsoProgress 98 'Checking the new ISO' -Always
            $check = Test-WindowsIsoFile -Path $dest
            if (-not $check.Valid) {
                try { [System.IO.File]::Delete($dest) } catch { $null = $_ }
                throw ('The ISO written from Microsoft''s image is not valid ({0}); it was deleted.' -f $check.Reason)
            }
            if ($check.Warning) { Write-IsoLog $check.Warning 'Warn' }
            Write-IsoLog ('Windows 11 ISO made from Microsoft''s image: {0} ({1}, volume {2}).' -f $dest, (Format-IsoBytes $check.Size), $check.Label) 'Ok'
            $result = $dest
        }
        $ok = $true
    }
    finally {
        $script:XferBase = 3.0
        $script:XferSpan = 94.0
        $script:XferWhat = 'Downloading Windows 11'
        Remove-EsdFolder $media
        Remove-EsdFolder $scratch
        if ($ok) {
            if ($null -ne $esd -and [System.IO.File]::Exists($esd)) {
                try { [System.IO.File]::Delete($esd); Write-IsoLog 'Deleted the ESD (no longer needed).' }
                catch { Write-IsoLog ('Could not delete {0}: {1}' -f $esd, $_.Exception.Message) 'Warn' }
            }
            try { if (@([System.IO.Directory]::GetFileSystemEntries($work)).Count -eq 0) { [System.IO.Directory]::Delete($work) } } catch { $null = $_ }
        }
        elseif ($null -ne $esd -and [System.IO.File]::Exists($esd)) {
            Write-IsoLog ('The checked Windows image stays at {0}, so the next run does not download it again (delete the folder {1} if you do not need it).' -f $esd, $work) 'Warn'
        }
    }
    Write-IsoProgress 100 $readyText -Always
    return $result
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

function Invoke-IsoManualFallback {
    # Microsoft refused: open its download page and - in an interactive console only - let the user
    # give the ISO (or the official link) instead. Returns @{ Path } / @{ Url }, or $null.
    Open-IsoDownloadPage
    if ($UrlOnly -or -not $script:Interactive) { return $null }
    return (Read-IsoManualSource)
}

function ConvertTo-IsoOneLine {
    param($ErrorRecord)
    $m = ''
    try { $m = [string]$ErrorRecord.Exception.Message } catch { $m = [string]$ErrorRecord }
    return (($m -replace '[\r\n]+', ' ') -replace '\s+', ' ').Trim()
}

function New-IsoCombinedError {
    # Auto: both official sources failed -> one message with both reasons.
    param($PageError, $EsdError, [bool]$Blocked)
    $text = ('Windows 11 could not be downloaded from Microsoft. Download page: {0} Media Creation Tool image (ESD): {1}' -f (ConvertTo-IsoOneLine $PageError), (ConvertTo-IsoOneLine $EsdError))
    $ex = New-Object System.InvalidOperationException -ArgumentList $text
    if ($Blocked) { $ex.Data['LiteOSBlocked'] = $true }
    return $ex
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
    Write-IsoLog ('Source: {0}' -f $Source)
    if ($ListLanguages) {
        $listed = $false
        if ($Source -ne 'Esd') {
            try {
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
                $listed = $true
            }
            catch {
                if ($Source -eq 'Website') { throw }
                Write-IsoLog ('Microsoft''s download page did not list its languages: {0}' -f (ConvertTo-IsoOneLine $_)) 'Warn'
                Write-IsoLog 'Listing the languages of the Media Creation Tool image (ESD) instead.' 'Warn'
            }
        }
        if (-not $listed) { Get-EsdLanguageList }
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($Url) -and $Source -eq 'Esd') { throw 'Use either -Url (an ISO link from the Microsoft download page) or -Source Esd, not both.' }
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
    $pageError = $null
    $pageBlocked = $false
    if (-not [string]::IsNullOrWhiteSpace($Url)) {
        if (-not (Test-IsoOfficialUrl $Url)) { throw 'The -Url must be an https link on microsoft.com (copy it from the Microsoft download page).' }
        $link = [pscustomobject]@{ Url = $Url.Trim(); FileName = (Get-IsoFileNameFromUrl $Url); Expires = ''; Language = $Language }
        Write-IsoLog ('Using the link you provided: {0}' -f (Format-IsoUrlForLog $link.Url))
    }
    elseif ($Source -ne 'Esd') {
        try {
            $link = Get-IsoOfficialLink
        }
        catch {
            $apiError = $_
            $blocked = $false
            try { $blocked = [bool]$apiError.Exception.Data['LiteOSBlocked'] } catch { $blocked = $false }
            if ($Source -eq 'Website') {
                if (-not $blocked) { throw $apiError }
                foreach ($l in ($apiError.Exception.Message -split "`r?`n")) { Write-IsoLog $l 'Warn' }
                $script:ErrorShown = $true
                $manual = Invoke-IsoManualFallback
                if ($null -eq $manual) { throw $apiError }
                if ($manual.ContainsKey('Path')) {
                    Write-IsoLog ('Using {0}' -f $manual.Path) 'Ok'
                    Write-IsoProgress 100 'Windows 11 ISO ready' -Always
                    Write-Output $manual.Path
                    return
                }
                $link = [pscustomobject]@{ Url = $manual.Url; FileName = (Get-IsoFileNameFromUrl $manual.Url); Expires = ''; Language = $Language }
            }
            else {
                # Auto: the Media Creation Tool image is the next official source.
                if ($blocked) { foreach ($l in ($apiError.Exception.Message -split "`r?`n")) { Write-IsoLog $l 'Warn' } }
                else { Write-IsoLog ('Microsoft''s download page did not work: {0}' -f (ConvertTo-IsoOneLine $apiError)) 'Warn' }
                $pageError = $apiError
                $pageBlocked = $blocked
            }
        }
    }

    if ($null -eq $link) {
        # -Source Esd, or -Source Auto after the download page failed.
        if ($null -ne $pageError) { Write-IsoLog 'Trying the official Media Creation Tool image (ESD) from Microsoft''s servers instead.' 'Warn' }
        $esdResult = $null
        try {
            $esdResult = Invoke-EsdRoute -Target $target
        }
        catch {
            $esdError = $_
            if ($null -eq $pageError) { throw $esdError }
            Write-IsoLog ('The Media Creation Tool image did not work either: {0}' -f (ConvertTo-IsoOneLine $esdError)) 'Warn'
            $manual = $null
            if ($pageBlocked) { $manual = Invoke-IsoManualFallback }
            if ($null -eq $manual) { throw (New-IsoCombinedError -PageError $pageError -EsdError $esdError -Blocked $pageBlocked) }
            if ($manual.ContainsKey('Path')) {
                Write-IsoLog ('Using {0}' -f $manual.Path) 'Ok'
                Write-IsoProgress 100 'Windows 11 ISO ready' -Always
                Write-Output $manual.Path
                return
            }
            $link = [pscustomobject]@{ Url = $manual.Url; FileName = (Get-IsoFileNameFromUrl $manual.Url); Expires = ''; Language = $Language }
        }
        if ($null -eq $link) {
            if ($script:Interactive) { Write-Progress -Activity 'Windows 11 ISO' -Completed }
            Write-Output $esdResult
            return
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
    $saved = $null
    try {
        $saved = Save-IsoFile -Link $link.Url -Destination $dest
        Write-IsoProgress 100 'Windows 11 ISO downloaded and checked' -Always
    }
    catch {
        # Auto: a download page link that cannot be downloaded (e.g. refused for this network) ->
        # the Media Creation Tool image. Not for -Url or a link the user pasted after both failed.
        $dlError = $_
        if ($Source -ne 'Auto' -or -not [string]::IsNullOrWhiteSpace($Url) -or $null -ne $pageError) { throw $dlError }
        Write-IsoLog ('The ISO download from Microsoft''s download page failed: {0}' -f (ConvertTo-IsoOneLine $dlError)) 'Warn'
        Write-IsoLog 'Trying the official Media Creation Tool image (ESD) from Microsoft''s servers instead.' 'Warn'
        try { $saved = Invoke-EsdRoute -Target $target }
        catch { throw (New-IsoCombinedError -PageError $dlError -EsdError $_ -Blocked $false) }
        # The partial ISO download is of no use any more.
        try { Remove-IsoPart -Part ($dest + '.part') } catch { Write-IsoLog ('Could not delete {0}.part: {1}' -f $dest, $_.Exception.Message) 'Warn' }
    }
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

<#
    Lite OS - WIM image name rewrite tests (Get-LiteOSWimInfo / Set-LiteOSWimInfo).

    Static and pure: builds a tiny synthetic WIM (header + dummy payload + XML resource) in
    TestDrive and checks the rename only appends a new XML resource and repoints the header.
    Nothing outside TestDrive is read or written. Pester 3.4 and 5.x compatible (no Should).
#>

Describe 'WIM image names' {

    BeforeAll {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        Import-Module (Join-Path $RepoRoot 'builder\LiteOS.Image.psm1') -Force -DisableNameChecking -ErrorAction Stop

        function New-FakeWim {
            param([string]$Path, [string]$Name = 'Windows 11 Pro')
            $payloadLen = 1000
            $xmlOffset = 208 + $payloadLen
            $xml = ('<WIM><TOTALBYTES>{0}</TOTALBYTES><IMAGE INDEX="1"><NAME>{1}</NAME><DESCRIPTION>{1}</DESCRIPTION>' +
                    '<DISPLAYNAME>{1}</DISPLAYNAME><DISPLAYDESCRIPTION>{1}</DISPLAYDESCRIPTION></IMAGE></WIM>') -f $xmlOffset, $Name
            $body = [System.Text.Encoding]::Unicode.GetBytes($xml)
            $xmlBytes = New-Object byte[] ($body.Length + 2)
            $xmlBytes[0] = 0xFF; $xmlBytes[1] = 0xFE
            [Array]::Copy($body, 0, $xmlBytes, 2, $body.Length)

            $hdr = New-Object byte[] 208
            $tag = [System.Text.Encoding]::ASCII.GetBytes('MSWIM')
            [Array]::Copy($tag, 0, $hdr, 0, $tag.Length)
            [Array]::Copy([BitConverter]::GetBytes([uint32]208), 0, $hdr, 0x08, 4)
            [Array]::Copy([BitConverter]::GetBytes([uint16]1), 0, $hdr, 0x28, 2)
            [Array]::Copy([BitConverter]::GetBytes([uint16]1), 0, $hdr, 0x2A, 2)
            [Array]::Copy([BitConverter]::GetBytes([uint32]1), 0, $hdr, 0x2C, 4)
            [Array]::Copy([BitConverter]::GetBytes([int64]$xmlBytes.Length), 0, $hdr, 0x48, 7)
            $hdr[0x4F] = 0x00
            [Array]::Copy([BitConverter]::GetBytes([int64]$xmlOffset), 0, $hdr, 0x50, 8)
            [Array]::Copy([BitConverter]::GetBytes([int64]$xmlBytes.Length), 0, $hdr, 0x58, 8)

            $payload = New-Object byte[] $payloadLen
            for ($i = 0; $i -lt $payloadLen; $i++) { $payload[$i] = 0xAB }

            $all = New-Object byte[] (208 + $payloadLen + $xmlBytes.Length)
            [Array]::Copy($hdr, 0, $all, 0, 208)
            [Array]::Copy($payload, 0, $all, 208, $payloadLen)
            [Array]::Copy($xmlBytes, 0, $all, $xmlOffset, $xmlBytes.Length)
            [System.IO.File]::WriteAllBytes($Path, $all)
        }
    }

    It 'reads NAME and DISPLAYNAME from a WIM' {
        $p = Join-Path $TestDrive 'read.wim'
        New-FakeWim -Path $p
        $i = Get-LiteOSWimInfo -Path $p -Index 1
        if ($i.Name -ne 'Windows 11 Pro' -or $i.DisplayName -ne 'Windows 11 Pro') { throw ('unexpected names: {0} / {1}' -f $i.Name, $i.DisplayName) }
    }

    It 'renames NAME + DISPLAYNAME and keeps every earlier byte except the XML pointer' {
        $p = Join-Path $TestDrive 'rename.wim'
        New-FakeWim -Path $p
        $before = [System.IO.File]::ReadAllBytes($p)
        $r = Set-LiteOSWimInfo -Path $p -Index 1 -Name 'Lite OS Core' -Description 'Lite OS Core - test'
        if ($r.status -ne 'applied') { throw ('rename did not apply: ' + $r.message) }
        $i = Get-LiteOSWimInfo -Path $p -Index 1
        if ($i.Name -ne 'Lite OS Core') { throw ('NAME is ' + $i.Name) }
        if ($i.DisplayName -ne 'Lite OS Core') { throw ('DISPLAYNAME is ' + $i.DisplayName) }
        if ($i.DisplayDescription -ne 'Lite OS Core - test') { throw ('DISPLAYDESCRIPTION is ' + $i.DisplayDescription) }
        $after = [System.IO.File]::ReadAllBytes($p)
        if ($after.Length -le $before.Length) { throw 'the new XML was not appended' }
        for ($k = 0; $k -lt $before.Length; $k++) {
            $inPointer = ($k -ge 0x48 -and $k -lt 0x60)
            if (-not $inPointer -and $after[$k] -ne $before[$k]) { throw ('byte {0} changed outside the XML pointer' -f $k) }
        }
        if ($after[0x4F] -ne $before[0x4F]) { throw 'the XML resource flags byte changed' }
        # TOTALBYTES now points at the new XML resource
        $fs = [System.IO.File]::OpenRead($p)
        try {
            $off = [BitConverter]::ToInt64($after, 0x50)
            $len = [BitConverter]::ToInt64($after, 0x58)
            if ($off -ne $before.Length) { throw ('new XML offset {0}, expected {1}' -f $off, $before.Length) }
            $buf = New-Object byte[] $len
            [void]$fs.Seek($off, 'Begin'); [void]$fs.Read($buf, 0, $len)
            [xml]$x = [System.Text.Encoding]::Unicode.GetString($buf, 2, $len - 2)
            if ($x.WIM.TOTALBYTES -ne [string]$before.Length) { throw ('TOTALBYTES is ' + $x.WIM.TOTALBYTES) }
        } finally { $fs.Dispose() }
    }

    It 'leaves a non-WIM file untouched and reports failed' {
        $p = Join-Path $TestDrive 'not.wim'
        [System.IO.File]::WriteAllBytes($p, (New-Object byte[] 512))
        $r = Set-LiteOSWimInfo -Path $p -Index 1 -Name 'Lite OS Lite'
        if ($r.status -ne 'failed') { throw ('expected failed, got ' + $r.status) }
        $b = [System.IO.File]::ReadAllBytes($p)
        if ($b.Length -ne 512 -or @($b | Where-Object { $_ -ne 0 }).Count -ne 0) { throw 'the file was modified' }
    }

    It 'fails cleanly for a missing image index and does not change the file' {
        $p = Join-Path $TestDrive 'idx.wim'
        New-FakeWim -Path $p
        $before = [System.IO.File]::ReadAllBytes($p)
        $r = Set-LiteOSWimInfo -Path $p -Index 3 -Name 'Lite OS Lite'
        if ($r.status -ne 'failed') { throw ('expected failed, got ' + $r.status) }
        $after = [System.IO.File]::ReadAllBytes($p)
        if ($after.Length -ne $before.Length) { throw 'file length changed' }
        for ($k = 0; $k -lt $before.Length; $k++) { if ($after[$k] -ne $before[$k]) { throw ('byte {0} changed' -f $k) } }
    }

    It 'does nothing with -WhatIf' {
        $p = Join-Path $TestDrive 'whatif.wim'
        New-FakeWim -Path $p
        $before = [System.IO.File]::ReadAllBytes($p)
        $r = Set-LiteOSWimInfo -Path $p -Index 1 -Name 'Lite OS Lite' -WhatIf
        if ($r.status -ne 'skipped') { throw ('expected skipped, got ' + $r.status) }
        $after = [System.IO.File]::ReadAllBytes($p)
        if ($after.Length -ne $before.Length) { throw 'file changed under -WhatIf' }
    }
}

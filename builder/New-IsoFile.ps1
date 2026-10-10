<#
.SYNOPSIS
    Writes a bootable (BIOS + UEFI) UDF ISO from a Windows setup folder.

.DESCRIPTION
    New-IsoFile.ps1 packs a folder laid out like Windows installation media (boot\, efi\,
    sources\, setup.exe ...) into a bootable ISO:

      - oscdimg.exe from the Windows ADK "Deployment Tools" is used when it is found:
            oscdimg -m -o -u2 -udfver102 -l<label>
                    -bootdata:2#p0,e,b<boot\etfsboot.com>#pEF,e,b<efi\microsoft\boot\efisys.bin>
                    <source> <iso>
      - otherwise the IMAPI2 file system COM API built into Windows is used
        (IMAPI2FS.MsftFileSystemImage, UDF 1.02 only, El Torito entries for BIOS (platform 0x00)
        and UEFI (platform 0xEF)); the result stream is written with a small inline C# helper.

    UDF only, so install.wim files larger than 4 GB are fine. By default the UEFI boot image is
    efisys.bin, which shows "Press any key to boot from CD or DVD": media left in the drive will
    not restart Windows Setup by itself. -NoPrompt uses efisys_noprompt.bin instead.

    This script only reads the source folder and writes the output file. It needs no admin rights.

.PARAMETER SourcePath
    Folder with the setup files (for example the builder's work\iso folder).

.PARAMETER OutputPath
    ISO file to create.

.PARAMETER Label
    Volume label (letters, digits, '_' and '-', max 32 characters). Default LITEOS.
    Other characters are replaced with '_'.

.PARAMETER VolumeLabel
    Same as -Label (the name Build-LiteOS.ps1 uses). When both are given, -VolumeLabel wins.

.PARAMETER NoPrompt
    Use efisys_noprompt.bin (no "Press any key" prompt when booting the ISO/DVD in UEFI mode).

.PARAMETER OscdimgPath
    Explicit path to oscdimg.exe. Default: search PATH and the Windows ADK install folders.

.PARAMETER UseImapi
    Skip oscdimg and always use IMAPI2.

.PARAMETER Force
    Overwrite OutputPath if it exists.

.EXAMPLE
    .\New-IsoFile.ps1 -SourcePath C:\LiteOS-Build\iso -OutputPath .\LiteOS.iso -VolumeLabel LITEOS_26100

.NOTES
    Lite OS builder helper. Windows PowerShell 5.1 compatible, ASCII only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$Label = 'LITEOS',

    [string]$VolumeLabel,

    [switch]$NoPrompt,

    [string]$OscdimgPath,

    [switch]$UseImapi,

    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-IsoLog {
    param([Parameter(Mandatory = $true)][string]$Message, [string]$Color = 'Gray')
    Write-Host ('  ' + $Message) -ForegroundColor $Color
}

function Test-PathUnder {
    param([string]$Child, [string]$Parent)
    $c = $Child.TrimEnd('\') + '\'
    $p = $Parent.TrimEnd('\') + '\'
    return $c.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)
}

function Get-HostArch {
    $a = [string]$env:PROCESSOR_ARCHITECTURE
    if ($a -eq 'ARM64') { return 'arm64' }
    if ($a -eq 'x86') {
        if ([string]$env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') { return 'amd64' }
        return 'x86'
    }
    return 'amd64'
}

function Find-Oscdimg {
    param([string]$Explicit)
    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit -PathType Leaf) { return (Resolve-Path -LiteralPath $Explicit).ProviderPath }
        throw "oscdimg.exe not found at '$Explicit'."
    }
    $onPath = Get-Command 'oscdimg.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Path }

    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($rk in @('HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots')) {
        try {
            $v = (Get-ItemProperty -LiteralPath $rk -Name 'KitsRoot10' -ErrorAction Stop).KitsRoot10
            if ($v -and -not $roots.Contains($v)) { $roots.Add($v) }
        } catch { Write-Verbose ('No Windows Kits root at ' + $rk) }
    }
    foreach ($pf in @([Environment]::GetEnvironmentVariable('ProgramFiles(x86)'), [Environment]::GetEnvironmentVariable('ProgramFiles'))) {
        if ($pf) {
            $r = Join-Path $pf 'Windows Kits\10'
            if (-not $roots.Contains($r)) { $roots.Add($r) }
        }
    }
    $hostArch = Get-HostArch
    $archs = @($hostArch)
    if ($hostArch -ne 'amd64') { $archs += 'amd64' }
    if ($hostArch -ne 'x86') { $archs += 'x86' }
    foreach ($root in $roots) {
        foreach ($a in $archs) {
            $candidate = Join-Path $root ('Assessment and Deployment Kit\Deployment Tools\{0}\Oscdimg\oscdimg.exe' -f $a)
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    return $null
}

function Get-BootFile {
    param([Parameter(Mandatory = $true)][string]$Source, [string]$OscdimgExe, [bool]$WantNoPrompt)
    $extraDir = $null
    if ($OscdimgExe) { $extraDir = Split-Path -Parent $OscdimgExe }

    $bios = Join-Path $Source 'boot\etfsboot.com'
    if (-not (Test-Path -LiteralPath $bios -PathType Leaf)) {
        $bios = $null
        if ($extraDir -and (Test-Path -LiteralPath (Join-Path $extraDir 'etfsboot.com'))) { $bios = Join-Path $extraDir 'etfsboot.com' }
    }

    $names = @('efisys.bin')
    if ($WantNoPrompt) { $names = @('efisys_noprompt.bin', 'efisys.bin') }
    $uefi = $null
    foreach ($n in $names) {
        foreach ($dir in @((Join-Path $Source 'efi\microsoft\boot'), $extraDir)) {
            if (-not $dir) { continue }
            $c = Join-Path $dir $n
            if (Test-Path -LiteralPath $c -PathType Leaf) { $uefi = $c; break }
        }
        if ($uefi) { break }
    }
    if (-not $uefi) { throw "UEFI boot image not found (efi\microsoft\boot\efisys.bin). Is '$Source' Windows setup media?" }
    if ($WantNoPrompt -and ((Split-Path -Leaf $uefi) -ne 'efisys_noprompt.bin')) {
        Write-IsoLog -Color Yellow -Message 'efisys_noprompt.bin not found; using efisys.bin (keeps the "Press any key" prompt).'
    }
    if (-not $bios) { Write-IsoLog -Color Yellow -Message 'boot\etfsboot.com not found; the ISO will boot in UEFI mode only.' }
    return New-Object PSObject -Property @{ Bios = $bios; Uefi = $uefi }
}

function ConvertTo-ArgPath {
    # Quote for a raw command line; never leave a trailing backslash in front of a quote.
    param([Parameter(Mandatory = $true)][string]$Path)
    $p = $Path
    if ($p.Length -gt 3) { $p = $p.TrimEnd('\') }
    if ($p -match '\s') { return '"' + $p + '"' }
    return $p
}

function Invoke-Oscdimg {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$VolumeLabel,
        [Parameter(Mandatory = $true)]$Boot
    )
    if ($Boot.Bios) {
        $bootData = '2#p0,e,b{0}#pEF,e,b{1}' -f (ConvertTo-ArgPath $Boot.Bios), (ConvertTo-ArgPath $Boot.Uefi)
    } else {
        $bootData = '1#pEF,e,b{0}' -f (ConvertTo-ArgPath $Boot.Uefi)
    }
    $argLine = '-m -o -u2 -udfver102 -l{0} -bootdata:{1} {2} {3}' -f $VolumeLabel, $bootData, (ConvertTo-ArgPath $Source), (ConvertTo-ArgPath $Target)
    Write-IsoLog -Message ('oscdimg {0}' -f $argLine)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
    $code = $proc.ExitCode
    $proc.Dispose()
    if ($code -ne 0) { throw "oscdimg.exe failed with exit code $code." }
}

function Initialize-StreamCopier {
    if ('LiteOS.Builder.IsoStreamCopier' -as [type]) { return }
    $source = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace LiteOS.Builder
{
    public static class IsoStreamCopier
    {
        // Copies up to maxBytes from a COM IStream (IMAPI2 result image) into a .NET stream.
        // Returns the number of bytes copied (0 = end of stream).
        public static long Copy(object comStream, Stream target, long maxBytes, int bufferSize)
        {
            IStream source = (IStream)comStream;
            byte[] buffer = new byte[bufferSize];
            IntPtr bytesRead = Marshal.AllocHGlobal(sizeof(int));
            long total = 0;
            try
            {
                while (total < maxBytes)
                {
                    int want = (int)Math.Min((long)bufferSize, maxBytes - total);
                    Marshal.WriteInt32(bytesRead, 0);
                    source.Read(buffer, want, bytesRead);
                    int got = Marshal.ReadInt32(bytesRead);
                    if (got <= 0) { break; }
                    target.Write(buffer, 0, got);
                    total += got;
                }
            }
            finally
            {
                Marshal.FreeHGlobal(bytesRead);
            }
            return total;
        }
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp
}

function Initialize-BootOption {
    # $Streams collects the ADODB streams: the caller closes them after the ISO is written (an open
    # stream keeps etfsboot.com / efisys.bin locked, which breaks deleting the source folder).
    param([Parameter(Mandatory = $true)][string]$File, [Parameter(Mandatory = $true)][int]$PlatformId, [System.Collections.ArrayList]$Keep, [System.Collections.ArrayList]$Streams)
    $stream = New-Object -ComObject ADODB.Stream
    $stream.Type = 1          # adTypeBinary
    $stream.Open()
    if ($null -ne $Streams) { [void]$Streams.Add($stream) }
    $stream.LoadFromFile($File)
    [void]$Keep.Add($stream)
    $boot = New-Object -ComObject IMAPI2FS.BootOptions
    $boot.AssignBootImage($stream)
    $boot.PlatformId = $PlatformId   # 0 = x86 BIOS, 0xEF = EFI
    $boot.Emulation = 0              # no emulation
    $boot.Manufacturer = 'Microsoft'
    [void]$Keep.Add($boot)
    return $boot
}

function Invoke-ImapiIsoWrite {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$VolumeLabel,
        [Parameter(Mandatory = $true)]$Boot
    )
    Initialize-StreamCopier
    $keep = New-Object System.Collections.ArrayList
    $streams = New-Object System.Collections.ArrayList
    $fsi = $null; $result = $null; $imageStream = $null; $file = $null
    try {
        $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        $fsi.ChooseImageDefaultsForMediaType(12)   # IMAPI_MEDIA_TYPE_DISK: no media size limit
        $fsi.FileSystemsToCreate = 4               # FsiFileSystemUDF only (files > 4 GB allowed)
        $fsi.UDFRevision = 0x102                   # UDF 1.02, same as oscdimg -udfver102
        $fsi.FreeMediaBlocks = 0                   # 0 = unlimited
        $fsi.VolumeName = $VolumeLabel

        $entries = New-Object System.Collections.ArrayList
        if ($Boot.Bios) { [void]$entries.Add((Initialize-BootOption -File $Boot.Bios -PlatformId 0 -Keep $keep -Streams $streams)) }
        $uefiBoot = Initialize-BootOption -File $Boot.Uefi -PlatformId 0xEF -Keep $keep -Streams $streams
        [void]$entries.Add($uefiBoot)
        # The COM array must hold the raw COM objects (not PSObject wrappers) or IMAPI2 rejects it.
        $array = New-Object 'object[]' $entries.Count
        for ($i = 0; $i -lt $entries.Count; $i++) { $array[$i] = $entries[$i].PSObject.BaseObject }
        try {
            $fsi.BootImageOptionsArray = $array
        } catch {
            Write-IsoLog -Color Yellow -Message ('IMAPI2 rejected the BIOS+UEFI boot array ({0}); writing a UEFI-only boot entry.' -f $_.Exception.Message)
            $fsi.BootImageOptions = $uefiBoot
        }

        Write-IsoLog -Message ('Adding files from {0} ...' -f $Source)
        $fsi.Root.AddTree($Source, $false)
        Write-IsoLog -Message 'Building the image layout ...'
        $result = $fsi.CreateResultImage()
        $imageStream = $result.ImageStream
        $total = [int64]$result.TotalBlocks * [int64]$result.BlockSize

        $file = New-Object System.IO.FileStream($Target, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1048576)
        $done = [int64]0
        $chunk = [int64]64MB
        while ($done -lt $total) {
            $want = [Math]::Min($chunk, $total - $done)
            $n = [LiteOS.Builder.IsoStreamCopier]::Copy($imageStream, $file, $want, 1048576)
            if ($n -le 0) { break }
            $done += $n
            $pct = [int][Math]::Floor(100.0 * $done / $total)
            Write-Progress -Activity 'Writing ISO (IMAPI2)' -Status ('{0:N0} of {1:N0} MB' -f ($done / 1MB), ($total / 1MB)) -PercentComplete $pct
        }
        Write-Progress -Activity 'Writing ISO (IMAPI2)' -Completed
        $file.Flush()
        if ($done -ne $total) { throw ('IMAPI2 stream ended early ({0} of {1} bytes).' -f $done, $total) }
    } finally {
        if ($file) { $file.Dispose() }
        # Close the boot-file streams before releasing them (ReleaseComObject alone leaves the
        # files open until the process exits).
        foreach ($st in @($streams.ToArray())) {
            try { if ([int]$st.State -ne 0) { $st.Close() } } catch { Write-Verbose ('ADODB stream close failed: {0}' -f $_.Exception.Message) }
        }
        foreach ($o in @($imageStream, $result, $fsi) + @($keep.ToArray())) {
            if ($null -ne $o) {
                try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($o) } catch { Write-Verbose 'COM release failed.' }
            }
        }
        $keep.Clear(); $streams.Clear()
        $imageStream = $null; $result = $null; $fsi = $null
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
}

# =============================================================================================
# Main
# =============================================================================================
$partial = $null
try {
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) { throw "SourcePath '$SourcePath' is not a folder." }
    $src = (Resolve-Path -LiteralPath $SourcePath).ProviderPath
    $out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    if (Test-PathUnder -Child $out -Parent $src) { throw 'OutputPath must not be inside SourcePath.' }
    if ((Test-Path -LiteralPath $out) -and -not $Force) { throw "Output file already exists: $out (use -Force)." }
    $outDir = Split-Path -Parent $out
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    $wantedLabel = $Label
    if (-not [string]::IsNullOrEmpty($VolumeLabel)) { $wantedLabel = $VolumeLabel }
    $cleanLabel = ($wantedLabel -replace '[^A-Za-z0-9_\-]', '_')
    if ($cleanLabel.Length -gt 32) { $cleanLabel = $cleanLabel.Substring(0, 32) }
    if (-not $cleanLabel) { $cleanLabel = 'LITEOS' }
    Write-IsoLog -Message ('Volume label: {0}' -f $cleanLabel)

    $oscdimg = $null
    if (-not $UseImapi) { $oscdimg = Find-Oscdimg -Explicit $OscdimgPath }
    $boot = Get-BootFile -Source $src -OscdimgExe $oscdimg -WantNoPrompt ([bool]$NoPrompt)
    Write-IsoLog -Message ('BIOS boot : {0}' -f $(if ($boot.Bios) { $boot.Bios } else { '(none)' }))
    Write-IsoLog -Message ('UEFI boot : {0}' -f $boot.Uefi)

    $partial = $out + '.partial'
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }

    if ($oscdimg) {
        Write-IsoLog -Message ('Using oscdimg: {0}' -f $oscdimg)
        Invoke-Oscdimg -Exe $oscdimg -Source $src -Target $partial -VolumeLabel $cleanLabel -Boot $boot
    } else {
        if (-not $UseImapi) { Write-IsoLog -Message 'oscdimg.exe (Windows ADK Deployment Tools) not found; using the built-in IMAPI2 API.' }
        Invoke-ImapiIsoWrite -Source $src -Target $partial -VolumeLabel $cleanLabel -Boot $boot
    }

    if (-not (Test-Path -LiteralPath $partial -PathType Leaf) -or (Get-Item -LiteralPath $partial).Length -lt 1MB) { throw 'ISO creation produced no usable file.' }
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
    Move-Item -LiteralPath $partial -Destination $out
    $partial = $null
    $iso = Get-Item -LiteralPath $out
    Write-IsoLog -Color Green -Message ('ISO written: {0} ({1:N1} GB)' -f $iso.FullName, ($iso.Length / 1GB))
    $iso
}
catch {
    if ($partial -and (Test-Path -LiteralPath $partial)) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
    throw
}

# Lite OS Builder

The Lite OS Builder makes **Lite OS**: Windows 11 with everything Lite OS does already **baked
into the image** - removed apps and components, gaming tweaks, Lite OS branding, Start and
taskbar pins, and Steam plus the game runtimes preinstalled. You install it like any Windows
ISO and it boots straight into Lite OS; nothing has to run "on top" afterwards.

Lite OS is distributed **as scripts only**. The builder downloads the **official Windows 11 ISO
from Microsoft** (or uses one you downloaded) and assembles the Lite OS ISO **on your own PC**.
Lite OS never hosts or uploads Windows ISOs or images, never ships product keys or activators and
never patches Microsoft files. You need your own Windows license.

* **GUI:** double-click `LiteOS-Builder.cmd` in the Lite OS folder (one window, three steps).
* **CLI:** `builder\Build-LiteOS.ps1` (this page) - the GUI runs exactly this script.

---

## What you need

| | |
|---|---|
| PC to build on | Windows 10 or 11 (Windows 11 recommended), 64-bit |
| PowerShell | Windows PowerShell 5.1, **run as Administrator** (built into Windows) |
| Free space | **30 GB** on an NTFS drive for the work folder (**40 GB** with `-Download`, about 45 GB when the ESD catalog is used), plus about 7 GB for the ISO |
| Internet | Only for `-Download` (about 6-7 GB from Microsoft) and the installers (about 200 MB) |
| Windows ISO | Official Windows 11 **24H2 / 25H2 or newer** (build 26100+), x64 - or let the builder download it |
| USB stick | 8 GB or larger (everything on it is erased when you flash it) |
| Optional | [Windows ADK](https://learn.microsoft.com/windows-hardware/get-started/adk-install) **Deployment Tools** for `oscdimg.exe`. Without it the builder uses the IMAPI2 API built into Windows. |

A build takes about 30-60 minutes (plus the download), mostly DISM work.

---

## Modes

| Mode | Tweaks | Image removals | What you get |
|---|---|---|---|
| **Lite** (default) | Balanced | `image\removals.json` entries with `mode: lite` | Stays updatable (Windows Update, Microsoft Store), **Defender on**, Xbox app / Game Pass / Gaming Services and kernel anti-cheat (Vanguard, EAC, BattlEye, FACEIT ...) keep working. |
| **Core** (opt-in) | Extreme | Lite + `mode: core` | Windows X-Lite style: Defender, the Windows Update stack, the Edge browser (WebView2 and its updater are kept) and Windows RE (disabled after Setup) are removed or disabled. Smallest and fastest, but **not serviceable**: no Windows Update - to update, build again from a newer ISO. Lower security; some anti-cheat, Store / Game Pass or work apps may not work. You must confirm it (type `CORE`, or pass `-Yes`). |

---

## Build with the CLI

1. Get the Lite OS release `.zip`, right-click it, **Properties**, tick **Unblock**, extract it
   (for example to `C:\Tools\LiteOS`). The builder needs the whole folder (`LiteOS.ps1`, `src\`,
   `tweaks\`, `image\`, `builder\` ...).
2. Open **Windows PowerShell as administrator** and run one of:

   ```powershell
   cd C:\Tools\LiteOS

   # download Windows 11 from Microsoft and build Lite OS (Lite mode)
   powershell -NoProfile -ExecutionPolicy Bypass -File .\builder\Build-LiteOS.ps1 -Download

   # use an ISO you downloaded from https://www.microsoft.com/software-download/windows11
   powershell -NoProfile -ExecutionPolicy Bypass -File .\builder\Build-LiteOS.ps1 -IsoPath "$env:USERPROFILE\Downloads\Win11_25H2_English_x64.iso"
   ```

3. Wait for the numbered steps (`[1/22]` ... `[22/22]`). At the end you get, in the current
   folder (or `-OutputPath`):
   * `LiteOS-<Mode>-<build>-<language>.iso`, e.g. `LiteOS-Lite-26100.4349-en-US.iso`
   * `...iso.sha256` - its SHA256
   * `...report.json` - what was removed, baked in and installed (also written when a build fails)
   * `LiteOS-build-<time>.log` (+ `.dism.log`, `.download.log`)

### Options

| Parameter | What it does |
|---|---|
| `-IsoPath <file or folder>` | The official ISO (or a folder with its extracted contents). |
| `-Download` | Download the official Windows 11 x64 multi-edition ISO from Microsoft (`Get-WindowsIso.ps1`). |
| `-Language "<name>"` | Language for `-Download`, default `"English (United States)"` (also `German`, `en-GB`, ...). |
| `-DownloadSource Auto\|Website\|Esd` | Where `-Download` gets Windows 11 (passed to `Get-WindowsIso.ps1 -Source`). `Auto` (default): the Microsoft download page, and if Microsoft refuses it (error 715-123130, common on VPN / cloud addresses) the official ESD catalog the Media Creation Tool uses. `Website`: only the download page. `Esd`: only the Media Creation Tool catalog. Both are Microsoft's own servers. |
| `-Edition "<name>"` | Edition to keep, default `"Windows 11 Pro"`. Use the edition your license is for, e.g. `"Windows 11 Home"`. |
| `-Mode Lite\|Core` | See **Modes**. Default `Lite`. |
| `-Include <ids>` / `-Exclude <ids>` | Add or skip tweaks (ids from `docs\TWEAKS.md`) **and** image removals (`image.*` ids from `image\removals.json`). Exact ids or wildcards, comma separated; Exclude wins. Example: `-Mode Core -Exclude image.edge` keeps Edge. |
| `-Installers default\|none\|all\|<ids>` | Official installers baked in and run silently before the first sign-in (`image\installers.json`): default = Steam, Visual C++ 2015-2022 x64 + x86, DirectX End-User Runtime (June 2010), .NET Desktop Runtime 8. Example: `-Installers steam,vcredist-x64`. |
| `-Apps none\|default\|all\|<ids>` | Extra apps installed with winget at the first sign-in (`tweaks\apps-install.json`). Default `none`. |
| `-NoBypassRequirements` | Do **not** bypass the TPM / Secure Boot / RAM / storage / CPU checks. |
| `-KeepAutoEncryption` | Keep Windows' automatic device encryption (by default only the *automatic* encryption is prevented; you can turn BitLocker on yourself). |
| `-OutputPath <file.iso or folder>` | Where to write the ISO (a path ending in `.iso` is a file, anything else a folder). |
| `-WorkDir <folder>` | Work folder, default `C:\LiteOS-Build`. Use another NTFS drive if C: is short on space. |
| `-Yes` | Never prompt (GUI / CI): Core is accepted, an existing ISO gets a new name (`-2`, `-3` ...) instead of being overwritten, a missing edition is an error. |
| `-ProgressProtocol` | Machine-readable progress for the GUI (see below). Implies no prompts. |
| `-NoPrompt` | Boot the ISO in UEFI mode without "Press any key to boot from CD or DVD". |
| `-SplitWim` | Split `install.wim` into parts smaller than 4 GB (FAT32 USB sticks). |
| `-KeepDownload` | Keep the ISO (or, from the ESD catalog, the setup files) downloaded by `-Download` in `<WorkDir>\download` (the next `-Download` build reuses an ISO; a kept folder can be passed to `-IsoPath`). |
| `-KeepWorkDir` | Keep the work folder for troubleshooting. |
| `-Force` | Overwrite an existing output ISO and skip the interactive Core confirmation. |

### Progress protocol (`-ProgressProtocol`)

Used by `LiteOS-Builder.ps1`, which runs the builder as a child `powershell.exe` and reads its
standard output:

```
##LITEOS-PROGRESS <0-100> <message>        one per step (never goes backwards)
##LITEOS-RESULT ok <iso path> <sha256>      last line on success
##LITEOS-RESULT error <message>             last line on failure
```

Every other line is the human-readable log. The exit code is `0` on success, `1` otherwise.

---

## What the builder does

In this order (DISM servicing always runs while the offline registry is **not** loaded, because
DISM loads the same hive files itself):

1. **Checks:** administrator, 64-bit PowerShell, DISM cmdlets, free space, catalogs
   (`tweaks\*.json`, `image\removals.json`) - errors stop the build before anything is downloaded.
2. **Source:** downloads the official ISO from Microsoft (`-Download`) or checks yours.
3. **Edition:** keeps **one** edition, exported as **"Lite OS Lite"** / **"Lite OS Core"**.
4. **Installers:** downloads the official Steam / VC++ / DirectX / .NET installers on this PC and
   keeps only files whose Authenticode signature is **Valid** and signed by the expected publisher
   (Valve, Microsoft Corporation). A failed installer is a warning, not a failed build.
5. **Apps:** removes the provisioned apps of `tweaks\apps-remove.json` for the mode. Protected apps
   (Microsoft Store, App Installer / winget, Xbox app, Game Bar, Xbox identity and overlays, Gaming
   Services, runtimes, Calculator, Photos, Notepad, Terminal, Paint, Snipping Tool, Windows
   Security, Edge / WebView2 and shell components) are **never** removed.
6. **Components:** `image\removals.json` (capabilities, features, packages and Core app overrides
   before the hives are loaded, then OneDrive, files, Edge browser, WinRE and scripted removals - Core only for
   the last three; WinRE is disabled after Setup because Windows 11 Setup needs Winre.wim).
7. **Tweaks:** the tweak catalog is baked into the offline registry and services of the image
   (Balanced for Lite, Extreme for Core, plus `-Include` minus `-Exclude`). Every change is recorded
   in `C:\ProgramData\LiteOS\backup\backup-image.json`, so `Revert-LiteOS.ps1` on the installed
   system can undo baked tweaks. Things that can only run on the live system (scheduled tasks,
   machine scripts, `HKCU\Software\Classes`) go to `C:\LiteOS\deferred.json`.
8. **Settings, branding, layout:**
   * `BypassNRO` (local account), no consumer-feature / sponsored app installs, no automatic
     Outlook (new) / Dev Home install, `PreventDeviceEncryption` (unless `-KeepAutoEncryption`),
     Windows 11 requirement bypass (unless `-NoBypassRequirements`)
   * branding from `image\branding.json`: Settings > About shows **Lite OS** as manufacturer and
     `Lite OS <Mode> (<build>)` as model, registered organization, support link. (Windows itself is
     not renamed: `ProductName` / edition stay Microsoft's, so updates and activation keep working.)
   * Start pins (`image\layout\LayoutModification.json`) and taskbar pins
     (`image\layout\TaskbarLayoutModification.xml`) for new accounts (Start uses the documented OEM format): Steam, Xbox,
     Terminal and Settings on Start (Windows itself pins File Explorer, Store and Edge); taskbar: File Explorer, Edge (not in Core), Steam, Xbox, Store. The taskbar file is also copied
     to `C:\Windows\OEM\` and referenced by `LayoutXMLPath`, as Microsoft documents for Windows 11.
9. **Payload:** copies Lite OS to `C:\LiteOS` (playbook, revert, tweak catalog, `image\branding.json`,
   `installers\` + manifest, `deferred.json`), writes `C:\ProgramData\LiteOS\config.json` and
   `build-info.json`, and `C:\Windows\Setup\Scripts\SetupComplete.cmd`. Both Lite OS folders get a
   protected ACL (only SYSTEM and Administrators can change them).
10. **Cleanup:** `DISM /Cleanup-Image /StartComponentCleanup /ResetBase` (both modes), save the image.
11. **Setup media:** requirement bypass in `boot.wim`, `install.wim` re-exported with maximum
    compression, `autounattend.xml` added, bootable BIOS + UEFI ISO written, SHA256 + report.

The PC you build on is not changed: the builder only mounts the ISO and the image inside its work
folder and cleans everything up when it finishes (also when it fails or you cancel; a leftover
mount or registry hive from a killed build is cleaned up by the next build).

### After installation

* **SetupComplete** (as SYSTEM, before the first sign-in): applies the deferred machine tweaks,
  sets the boot menu name to *Lite OS*, installs Steam and the runtimes silently.
* **First sign-in** (`LiteOS.ps1 -FirstLogon`): applies the few per-user leftovers to your account
  and installs the optional winget apps. It only restarts when something needs it (60 s notice).
* Later: `C:\LiteOS\Start-LiteOS.cmd` (menu, extra tweaks, revert), logs in
  `C:\ProgramData\LiteOS\logs`.

### autounattend.xml

The answer file on the ISO **never** contains disk or partition settings, product keys, accounts,
passwords or AutoLogon (the only `ProductKey` element has an empty `Key`, which Setup requires).
It bypasses the hardware checks in Setup (unless `-NoBypassRequirements`), allows a local account
(`BypassNRO`, online account screens hidden) and runs `LiteOS.ps1 -FirstLogon` once.

---

## Write the ISO to a USB stick with Rufus

1. Download Rufus from **https://rufus.ie** (official site).
2. Insert the USB stick. **Everything on it will be erased.**
3. In Rufus: **Device** = your USB stick, **Boot selection** = the `LiteOS-....iso`,
   **Partition scheme** = **GPT**, **Target system** = **UEFI (non CSM)**. Leave the file system as
   Rufus suggests (NTFS when `install.wim` is larger than 4 GB).
4. Click **START**. When Rufus shows the **"Windows User Experience"** dialog, **untick every
   option** and click OK - Lite OS already has its own answer file.

Prefer FAT32? Build with `-SplitWim` and choose FAT32 in Rufus.

## BIOS / UEFI notes

* Open the one-time **boot menu** (usually **F8, F11, F12 or Esc**) and choose the **"UEFI:"**
  entry of your USB stick. Install in **UEFI mode**; turn off **CSM / Legacy boot** if needed.
* **Keep Secure Boot and TPM (fTPM / Intel PTT) on.** Kernel anti-cheat (Riot Vanguard, FACEIT ...)
  needs them on Windows 11. Lite OS never changes firmware settings; the requirement bypass only
  matters for older PCs that do not have them.
* **Dual boot / other disks are safe:** Setup always asks where to install. Choose **Custom:
  Install Windows only** and pick the partition or unallocated space yourself. If other drives use
  BitLocker, have their recovery keys at hand. Unplugging drives you do not install to is safest.

## Installing

1. Choose language and keyboard, then **Install**.
2. **Product key:** enter your key, or click **"I don't have a product key"**. A PC that had
   Windows 11 activated re-activates automatically with its digital license.
3. The edition is the one you built (the image holds only that edition).
4. Pick the disk / partition (see above).
5. After the restart choose region and keyboard, connect to a network if you want (optional) and
   create your **local account**. No Microsoft account is required.
6. Before the first sign-in Windows shows "Getting ready" a little longer while Lite OS installs
   Steam and the runtimes. Then you are on the Lite OS desktop.

---

## Download Windows 11 only (`Get-WindowsIso.ps1`)

`-Download` (and the GUI) use `builder\Get-WindowsIso.ps1`, which you can also run on its own:

```powershell
# the multi-edition ISO into your Downloads folder (download page, ESD route if Microsoft refuses it)
powershell -NoProfile -ExecutionPolicy Bypass -File .\builder\Get-WindowsIso.ps1 -Language German -OutFile D:\ISO\

# only the Media Creation Tool image, turned into an ISO on this PC (elevated: it uses DISM)
powershell -NoProfile -ExecutionPolicy Bypass -File .\builder\Get-WindowsIso.ps1 -Source Esd -OutFile D:\ISO\
```

| Parameter | What it does |
|---|---|
| `-Source Auto\|Website\|Esd` | `Auto` (default): Microsoft's download page; if that fails (for example error 715-123130 on VPN / cloud addresses or in blocked regions) the Media Creation Tool image. `Website`: only the download page (multi-edition ISO). `Esd`: only the Media Creation Tool image (ESD). |
| `-EsdCatalog <file or link>` | With the ESD route: use this Media Creation Tool catalog (`products.cab` / `products.xml`, or an https link on microsoft.com) instead of asking Microsoft for it. The image it lists must still be on a Microsoft server and is checked against the catalog's SHA-256 / SHA-1. |
| `-Language`, `-OutFile`, `-UrlOnly`, `-ListLanguages`, `-Force`, `-NoBits`, `-LogPath` | Language (Microsoft's name or a culture code like `de-DE`), target file or folder, print the official link only, list the languages, download again, no BITS, log file. |

The ESD route downloads the official image from `dl.delivery.mp.microsoft.com` (Microsoft serves it
over plain http; it must match the SHA-256 in Microsoft's catalog), then DISM turns it into setup
files and `New-IsoFile.ps1` into an ISO. It needs administrator rights and about 25 GB free next to
`-OutFile` while it works; the ISO it leaves is about 10-12 GB (the editions are stored with fast
compression). The ESD is deleted on success and kept for the next run when a later step fails.

## Check a finished ISO (`Test-LiteOSImage.ps1`)

`builder\Test-LiteOSImage.ps1` checks a Lite OS ISO **read-only** (elevated Windows PowerShell):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\builder\Test-LiteOSImage.ps1 -IsoPath .\LiteOS-Lite-26200.6584-en-US.iso
```

It attaches the ISO read-only, checks the boot files and `autounattend.xml` (no disk, key or
account settings), then `install.wim`: exactly one image named **"Lite OS <Mode>"**, x64, build
26100 or newer. It mounts that image with `Mount-WindowsImage -ReadOnly` (always discarded) and
checks the `C:\LiteOS` payload, `SetupComplete.cmd`, `config.json`, `build-info.json`,
`backup-image.json`, `deferred.json`, their protected ACLs, the Default-profile Start layout, the
taskbar layout, that `Winre.wim` and WebView2 are still there, that the removed apps are really gone
and that Store / App Installer / Xbox apps are kept. Registry checks use **copies** of the image's
SYSTEM and SOFTWARE hives: in **Lite** the Defender, Windows Update, Store and Xbox services must
not be disabled or changed and no policy may block Windows Update or Defender; in **Core**
`WinDefend` must be `Start=4`, the update services disabled (or disabled by SetupComplete) and
`NoAutoUpdate=1` with no conflicting tweak baked in.

Results go to `<iso>.verify.json`, `.verify.md` and `.verify.log` (or `-ReportPath`), plus copies of
the small image files in `<name>-files\`. Exit code `0` = all checks passed (warnings allowed),
`1` = a check failed, `2` = the check could not run. Options: `-Mode Lite|Core` (default: from the
image name), `-WorkDir` (mount folder, NTFS, about 1 GB), `-NoMount` (ISO and WIM metadata only),
`-MinBuild`.

## CI

`.github/workflows/build-test.yml` runs a real build on a GitHub `windows-latest` runner for Lite
and Core (manually, on pushes to the `v2-wip` branch that touch the builder / image / engine /
tweaks, and weekly): `Build-LiteOS.ps1 -Download -DownloadSource Auto -Mode Lite|Core -Yes
-ProgressProtocol -WorkDir <drive with the most free space>`, then `Test-LiteOSImage.ps1` on the
result. It uploads **only** the logs, the build report, `build-info.json`, the verification report
and the ISO size / SHA256 - also when the build fails. The ISO, WIM and ESD are **never** uploaded.

## License and legal

* Lite OS does not include Windows. The builder downloads it from Microsoft's own servers on your
  PC, and you need a **valid Windows license** for the edition you install.
* **No product keys are included** - not even the public generic install keys - and no activation
  tools of any kind. Activation is between you and Microsoft.
* The baked-in installers (Steam, Visual C++, DirectX, .NET) are downloaded from their publishers'
  official URLs on your PC and checked with their publishers' digital signatures; they are not
  redistributed by Lite OS.
* Lite OS is not affiliated with or endorsed by Microsoft or Valve. Windows is a trademark of
  Microsoft; Steam is a trademark of Valve.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Run this script from an elevated PowerShell" | Start PowerShell with **Run as administrator** (the GUI does this for you). |
| "Not enough free space" | Free space or use `-WorkDir D:\LiteOS-Build` on another NTFS drive. |
| "Windows 11 could not be downloaded from Microsoft" | Microsoft sometimes refuses automated downloads (error 715-123130: region, VPN / proxy, too many requests). Try `-DownloadSource Esd` (Media Creation Tool catalog), or download the ISO in your browser from https://www.microsoft.com/software-download/windows11 and build with `-IsoPath` (GUI: "Use my ISO"). |
| "Edition ... not found" | Pass `-Edition` with a name (or index number) from the list in the log. |
| "Core removals need confirmation" | Add `-Yes` (or type `CORE` when asked) after reading the warnings. |
| An installer was not baked in | The report lists why (download failed, signature not valid). The build itself is fine; install it later yourself. |
| The ISO gets no drive letter | Extract the ISO with Explorer/7-Zip to a folder and pass that folder as `-IsoPath`. |
| Build stopped half-way / "image already mounted" | Just build again (the builder discards leftovers in its work folder). Manually: `Get-WindowsImage -Mounted`, `dism /Unmount-Image /MountDir:<path> /Discard`, `dism /Cleanup-Wim`, and `reg unload HKLM\LITE_SOFTWARE` (also `LITE_SYSTEM`, `LITE_DEFAULT`, `LITE_BOOTSYSTEM`). |
| Setup still asks for a Microsoft account | Microsoft keeps removing the local-account routes. Lite OS sets `BypassNRO` and hides the online account screens, which works on retail 24H2 / 25H2. Otherwise unplug the network **before** the network page, or sign in and switch to a local account later in **Settings > Accounts > Your info**. |
| Lite OS did not finish at first sign-in | Run `C:\LiteOS\Start-LiteOS.cmd` as administrator; logs are in `C:\ProgramData\LiteOS\logs`. Make sure no Rufus "Windows User Experience" options were ticked. |
| Check the ISO | Compare `Get-FileHash LiteOS-....iso` with the `.sha256` file next to it, and run `builder\Test-LiteOSImage.ps1 -IsoPath <iso>` (read-only checks of the image). |

`New-IsoFile.ps1` can also pack any Windows setup folder into a bootable ISO:

```powershell
.\builder\New-IsoFile.ps1 -SourcePath C:\LiteOS-Build\iso -OutputPath .\custom.iso -VolumeLabel LITEOS
```

Credits: the offline image approach follows the public work of
[tiny11builder](https://github.com/ntdevlabs/tiny11builder) (ntdevlabs) and the Microsoft download
flow used by [Fido / Rufus](https://github.com/pbatard/Fido) (Pete Batard); no code is copied.

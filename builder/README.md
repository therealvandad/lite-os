# Lite OS ISO builder

`Build-LiteOS.ps1` turns an **official Windows 11 ISO that you download yourself** into a Lite OS
ISO. After installation, Lite OS applies its gaming tweaks automatically at the first sign-in.

Lite OS is **scripts only**. It never ships Windows files, modified Windows images, product keys
or activators. You bring your own ISO from Microsoft and your own Windows license.

---

## What you need

| | |
|---|---|
| PC to build on | Windows 10 or 11 (Windows 11 recommended), 64-bit |
| PowerShell | Windows PowerShell 5.1, **run as Administrator** (it is built into Windows) |
| Free space | **25 GB or more** on an NTFS drive for the work folder, plus about 7 GB for the ISO |
| Windows ISO | Official Windows 11 **24H2 or 25H2** (build 26100 or newer), x64 |
| USB stick | 8 GB or larger (everything on it is erased when you flash it) |
| Optional | [Windows ADK](https://learn.microsoft.com/windows-hardware/get-started/adk-install) with only the **Deployment Tools** feature, for `oscdimg.exe`. Without it the builder uses the IMAPI2 API that is built into Windows. |

Building takes about 15 to 40 minutes, mostly for DISM to export and compress the image.

---

## Step 1 - Download the official Windows 11 ISO

1. Open **https://www.microsoft.com/software-download/windows11**
2. Under **"Download Windows 11 Disk Image (ISO) for x64 devices"** choose
   **Windows 11 (multi-edition ISO for x64 devices)**, then your language, then **64-bit Download**.
3. Optional but recommended: compare the file's SHA256 with the hash list Microsoft shows on
   the same page:

   ```powershell
   Get-FileHash "$env:USERPROFILE\Downloads\Win11_25H2_English_x64.iso" -Algorithm SHA256
   ```

Do not use ISOs from other websites. The builder checks that the image is Windows 11
(build 22000 or newer) and warns if it is older than 24H2 (26100).

## Step 2 - Get Lite OS

Download the Lite OS release `.zip`, right-click it, choose **Properties**, tick **Unblock**,
then extract it, for example to `C:\Tools\LiteOS`. The builder needs the whole folder
(`LiteOS.ps1`, `src\`, `tweaks\`, `builder\` ...), not just the `builder` folder.

## Step 3 - Build the ISO

1. Open **Start**, type `PowerShell`, right-click **Windows PowerShell** and choose
   **Run as administrator**.
2. Run:

   ```powershell
   cd C:\Tools\LiteOS
   powershell -NoProfile -ExecutionPolicy Bypass -File .\builder\Build-LiteOS.ps1 -IsoPath "$env:USERPROFILE\Downloads\Win11_25H2_English_x64.iso"
   ```

3. Wait for the numbered steps (`[1/15]` ... `[15/15]`) to finish. At the end you get
   `LiteOS-<build>.iso`, a `.sha256` file and a build log in the current folder.

If the edition you asked for is not in the ISO, the builder lists the editions it found and
asks you to pick one.

### Options

| Parameter | What it does |
|---|---|
| `-IsoPath <file or folder>` | **Required.** The official ISO (or a folder with its extracted contents). |
| `-OutputPath <file>` | Where to write the ISO. Default `.\LiteOS-<build>.iso`. |
| `-Edition "<name>"` | Edition to keep, default `"Windows 11 Pro"`. Use the edition your license is for, e.g. `"Windows 11 Home"`. |
| `-Level Balanced\|Extreme` | Default **Balanced** (keeps Defender, Windows Update, Store, Xbox / Game Pass, Game Bar and anti-cheat working). **Extreme** removes more and can break some of these; you must type `EXTREME` to confirm (or pass `-Force`). |
| `-Apps default\|none\|all\|<ids>` | Gaming apps installed with winget at first sign-in. Default `default`. Example: `-Apps Valve.Steam,Discord.Discord`. |
| `-Include <ids>` / `-Exclude <ids>` | Add or skip individual tweaks by id (see `docs\TWEAKS.md`). `apps.remove.*` ids also control which preinstalled apps the builder removes. |
| `-NoBypassRequirements` | Do **not** bypass the TPM / Secure Boot / RAM / storage / CPU checks. Use this if your PC meets the Windows 11 requirements and you want an image that is as close to stock as possible. |
| `-KeepAutoEncryption` | Keep Windows' automatic device encryption. By default Lite OS prevents *automatic* encryption; you can still turn on BitLocker yourself at any time. |
| `-WorkDir <folder>` | Work folder (default `C:\LiteOS-Build`). Use another NTFS drive if C: is short on space. |
| `-NoPrompt` | Boot the ISO in UEFI mode without "Press any key to boot from CD or DVD" (matters for DVDs and virtual machines). |
| `-SplitWim` | Split `install.wim` into parts smaller than 4 GB, so the files fit on a FAT32 USB stick. |
| `-KeepWorkDir` | Keep the work folder for troubleshooting. |
| `-Force` | Overwrite an existing output ISO and skip the Extreme confirmation. |

### What the builder changes in the image

* Keeps **one** edition only and recompresses `install.wim`.
* Removes the preinstalled apps listed in `tweaks\apps-remove.json` for your level. Protected
  apps (Microsoft Store, App Installer / winget, Xbox app, Game Bar, Xbox identity and overlays,
  Gaming Services, runtimes, Calculator, Photos, Notepad, Terminal, Paint, Snipping Tool,
  Windows Security, Edge / WebView2 and shell components) are **never** removed.
* Offline registry settings:
  * `OOBE\BypassNRO = 1` (lets you finish setup with a local account / without network)
  * no consumer-feature auto-installs, no sponsored apps or Start suggestions for new users
  * no automatic Outlook (new) / Dev Home install during setup
  * `PreventDeviceEncryption = 1` (unless `-KeepAutoEncryption`)
  * Windows 11 requirement bypass (`LabConfig`, `MoSetup`) in the image **and** in Windows
    Setup (`boot.wim`), unless `-NoBypassRequirements`
* Copies the Lite OS playbook to `C:\LiteOS` and writes `C:\ProgramData\LiteOS\config.json`
  (your level / apps). A list of everything the builder changed is saved in
  `C:\ProgramData\LiteOS\build-info.json` on the installed system.
* Adds `autounattend.xml` to the ISO. It **never** contains disk or partition settings, product
  keys or accounts (the only `ProductKey` element has an empty `Key`, which Setup requires).

The PC you build on is not changed: the builder only mounts the ISO and the image inside its
work folder and cleans everything up when it finishes (also when it fails).

---

## Step 4 - Write the ISO to a USB stick with Rufus

1. Download Rufus from **https://rufus.ie** (official site).
2. Insert the USB stick. **Everything on it will be erased.**
3. In Rufus: **Device** = your USB stick, **Boot selection** = the `LiteOS-<build>.iso`,
   **Partition scheme** = **GPT**, **Target system** = **UEFI (non CSM)**. Leave the file system
   as Rufus suggests (it picks NTFS when `install.wim` is larger than 4 GB).
4. Click **START**. When Rufus shows the **"Windows User Experience"** dialog,
   **untick every option** and click OK. Lite OS already has its own answer file; Rufus'
   options would add a second one and can stop Lite OS from running at first sign-in.

Prefer FAT32? Build with `-SplitWim` and choose FAT32 in Rufus.

## Step 5 - BIOS / UEFI notes

* Open the one-time **boot menu** while the PC starts (usually **F8, F11, F12 or Esc**; check
  your motherboard manual) and choose the entry that starts with **"UEFI:"** and your USB stick.
* Install in **UEFI mode**. Turn off **CSM / Legacy boot** if your board boots the stick in
  legacy mode.
* **Keep Secure Boot and TPM (fTPM / Intel PTT) turned on.** Kernel anti-cheat (for example
  Riot Vanguard and FACEIT) needs them on Windows 11, and Lite OS never changes firmware settings.
  The requirement bypass only matters for older PCs that do not have them.
* If the stick does not boot with Secure Boot on, update Rufus and your BIOS first; if you rebuilt
  with `-SplitWim` and used FAT32, the stick boots like normal Windows media.
* **Dual boot / other disks are safe:** Setup always asks where to install. Choose
  **Custom: Install Windows only**, then pick the partition or unallocated space yourself.
  Only delete partitions you are sure about. If other drives use BitLocker, have their recovery
  keys at hand. Unplugging drives you do not install to is the safest option.

## Step 6 - Installing

1. Choose language and keyboard, then **Install Windows 11**.
2. **Product key:** enter your key, or click **"I don't have a product key"**. If this PC
   already had Windows 11 activated, it re-activates automatically with its digital license.
   (The answer file has an *empty* `<ProductKey><Key /></ProductKey>` element only because
   Windows Setup refuses to start without one - it is not a key. If Setup does not show the key
   page on your media, Windows activates with your digital license, or you enter your key later
   in **Settings > System > Activation**.)
3. The edition is the one you built (no edition list).
4. Pick the disk / partition (see Step 5).
5. In the setup screens after the restart, choose region and keyboard, connect to a network if
   you want (optional) and create your **local account** (name, password, security questions).
   No Microsoft account is required; you can add one later in Settings.
6. At the **first sign-in** a PowerShell window opens and runs Lite OS at the level you chose.
   **Do not close it.** The PC restarts once when it is done. Logs are in
   `C:\ProgramData\LiteOS\logs`.

To change things later, run `C:\LiteOS\Start-LiteOS.cmd` (menu, revert, gaming apps).

---

## License and legal

* Lite OS does not include or download Windows. You need a **valid Windows license** for the
  edition you install.
* **No product keys are included** - not even the public "generic install keys" - and no
  activation tools of any kind. Activation is between you and Microsoft.
* Lite OS is not affiliated with or endorsed by Microsoft. Windows is a trademark of Microsoft.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| "Run this script from an elevated PowerShell" | Start PowerShell with **Run as administrator**. |
| "Not enough free space" | Free space or use `-WorkDir D:\LiteOS-Build` on another NTFS drive. |
| "Edition ... not found" | Pick from the list, or pass `-Edition` with a name (or index number) from the list. |
| The ISO gets no drive letter | Extract the ISO with Explorer/7-Zip to a folder and pass that folder as `-IsoPath`. |
| Build stopped half-way / DISM "image already mounted" | Run `Get-WindowsImage -Mounted`, then `dism /Unmount-Image /MountDir:<path> /Discard` and `dism /Cleanup-Wim`. Leftover registry hives: `reg unload HKLM\LITE_SOFTWARE` (also `LITE_SYSTEM`, `LITE_DEFAULT`, `LITE_BOOTSYSTEM`). Then run the builder again. |
| Setup still asks for a Microsoft account | Microsoft keeps removing the local-account routes from OOBE (the `oobe\bypassnro` script and `ms-cxh:localonly` are already gone in Insider builds). Lite OS sets `BypassNRO` and hides the online account screens, which works on retail 24H2 / 25H2 today. If your build still insists: unplug the network cable (and do not join Wi-Fi) **before** the network page, so Setup offers "I don't have internet" / a local account; otherwise sign in with a Microsoft account and switch to a local one afterwards in **Settings > Accounts > Your info > Sign in with a local account instead**. |
| Lite OS did not run at first sign-in | Run `C:\LiteOS\Start-LiteOS.cmd` as administrator. Make sure no Rufus "Windows User Experience" options were ticked. |
| Want to check the ISO | Compare `Get-FileHash LiteOS-<build>.iso` with the `.sha256` file written next to it. |

`New-IsoFile.ps1` can also be used on its own to pack any Windows setup folder into a
bootable ISO:

```powershell
.\builder\New-IsoFile.ps1 -SourcePath C:\LiteOS-Build\iso -OutputPath .\custom.iso -Label LITEOS
```

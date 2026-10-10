# Lite OS

**A gaming Windows 11 you build yourself, in one click.**

[![CI](https://github.com/therealvandad/lite-os/actions/workflows/ci.yml/badge.svg)](https://github.com/therealvandad/lite-os/actions/workflows/ci.yml)
[![Build test](https://github.com/therealvandad/lite-os/actions/workflows/build-test.yml/badge.svg)](https://github.com/therealvandad/lite-os/actions/workflows/build-test.yml)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

Lite OS is Windows 11 (24H2 / 25H2, build 26100 or newer) rebuilt for gaming: the bloat, ads, nags and
background noise taken out, gaming defaults, Steam and the game runtimes put in. You install it fresh from a
USB stick, like any operating system - it boots as **Lite OS**, with its own Start menu, taskbar and branding.

The difference from pre-made "lite" ISOs: **you never download Windows from us.** The **Lite OS Builder**
downloads the official Windows 11 ISO from Microsoft on your own PC and bakes everything into the image there.
What you flash is your own `LiteOS.iso`, built from Microsoft's original files by scripts you can read.

- **Plays everything Windows plays**: Steam, Epic, Battle.net, EA app, Ubisoft Connect, GOG, Xbox app and Game Pass.
- **Kernel anti-cheat works** in the default **Lite** mode (Vanguard, Easy Anti-Cheat, BattlEye, Ricochet,
  FACEIT, EA Javelin).
- **Stays safe and updatable** in Lite: Windows Update, Defender and the Microsoft Store keep working.
- **Ready to game on first boot**: Steam, Visual C++ 2015-2022 (x64 + x86), DirectX (June 2010) and
  .NET Desktop Runtime 8 are already installed.
- **Open and reversible**: every removal and tweak is a line in a JSON file; baked tweaks can be reverted on the
  installed system.
- **No Windows files, no product keys, no activators** in this repository. Bring your own license.

## Lite or Core?

| | **Lite** (default, recommended) | **Core** (opt-in, X-Lite style) |
|---|---|---|
| Meant for | Your main gaming PC | Enthusiasts and dedicated gaming rigs that accept the trade-offs below |
| Bloat, ads, Copilot / Recall, sponsored apps, OneDrive auto-install | Removed / turned off | Removed / turned off |
| Tweaks baked in | Balanced ([list](docs/TWEAKS.md)) | Extreme ([list](docs/TWEAKS.md)) |
| Windows Update | **Works** - monthly security updates install as usual | **Removed. Core is not serviceable**: no security patches; to update you rebuild from a newer official ISO and reinstall |
| Windows Defender | **On** | **Removed / disabled** - you have no built-in antivirus |
| Microsoft Store, Xbox app, Game Pass | **Work** | Installed, but Store and Game Pass installs and updates need the Windows Update service and fail |
| Microsoft Edge | Kept | Browser removed (WebView2 and its updater stay, so launchers keep working) - pick Firefox or Brave as a first-logon app |
| Recovery (WinRE, "Reset this PC") | Kept | Disabled after Setup - keep a Lite OS USB stick for repairs |
| Kernel anti-cheat | **Works** | Usually works, but games that require Defender, up-to-date Windows, VBS or memory integrity may refuse to start - more of them over time |
| Undo | Revert baked tweaks with `Revert-LiteOS.ps1` | Revert tweaks; removed components only come back by reinstalling |

**Pick Lite unless you know exactly why you want Core.** Core trades security and updates for a slightly
smaller, quieter system. The Builder shows the full Core warning list and asks you to confirm it.
Everything removed in each mode is listed in [docs/IMAGE.md](docs/IMAGE.md).

## Honest expectations

Lite OS will not double your FPS. On a healthy PC the gains are mostly smaller and more practical: less
background CPU and disk activity, fewer interruptions while you play, smoother frame times on some systems, and
a cleaner, quieter Windows. Your GPU driver, game settings and hardware still matter far more than any tweak.
If someone promises +50% FPS from a "lite" Windows, be skeptical - including of us.

## Quick start: build and install Lite OS

You need a Windows 10 or 11 PC (64-bit) to build on, an administrator account, about **30 GB** free disk space (plus about 8-25 GB when the Builder downloads Windows for you, see below),
an internet connection, and an **8 GB or larger USB stick** (it will be erased).

1. **Download** the latest `LiteOS-<version>.zip` from [Releases](https://github.com/therealvandad/lite-os/releases).
   Optionally check its SHA256 against the release page: `(Get-FileHash .\LiteOS-<version>.zip -Algorithm SHA256).Hash`
2. **Unblock** it: right-click the zip > **Properties** > tick **Unblock** > **OK**. Then extract it.
3. **Double-click `LiteOS-Builder.cmd`** and accept the administrator prompt. The Lite OS Builder opens.
4. **Build**:
   - *Source*: **Download Windows 11 from Microsoft** (pick the language) or **Use my ISO** (an official ISO you
     already have).
   - *Options*: **Lite** or **Core**, the edition (default Windows 11 Pro), what to preinstall (Steam and the
     runtimes are ticked), optional apps for the first sign-in, **Smaller ISO** (ticked by default, see below)
     and **Customize** if you want to keep or remove single items.
   - Click **Build**. The progress bar and live log show every step; it takes about 45-120 minutes, mostly for
     downloading and compressing. **Cancel** stops cleanly at any time. At the end you get `LiteOS.iso`, its
     SHA256 and an **Open folder** button.

   **ISO size:** with **Smaller ISO (ESD compression, slower build)** ticked (the default, `-Compression Esd`)
   Windows is stored as `sources\install.esd` with the same solid LZMS compression Microsoft's Media Creation
   Tool uses, and Windows Setup installs from it directly. That usually makes the ISO about 1-2 GB smaller (an
   estimate until the CI builds measure it; an `install.wim` ISO of build 26300 Pro is 7.9 GB) and adds roughly
   20-60 minutes to the build, depending on the PC. Untick it (`-Compression Max`) for a faster build with
   `install.wim`. PCs with less than 8 GB of RAM build `install.wim` anyway, and if the ESD compression fails or
   runs past its time limit, the Builder stops it and falls back to `install.wim` by itself.
5. **Flash** `LiteOS.iso` to the USB stick with [Rufus](https://rufus.ie). When Rufus asks about
   "Windows User Experience" options, **untick all of them** - Lite OS has its own answer file. The Builder
   never writes to USB drives itself.
6. **Install**: boot the PC from the stick and install as usual. **You choose the disk and partition** on the
   "Where do you want to install Windows?" screen - Lite OS never wipes or partitions disks on its own, so it is
   safe next to Linux or another Windows. You create a local account in setup (a Microsoft account can be added
   later).
7. **First boot**: before the first sign-in Lite OS finishes the setup (Steam, runtimes, boot entry); after you
   sign in it applies the last per-user settings and the optional apps. Then it is ready to game.

Command line (elevated Windows PowerShell in the extracted folder) does the same as the GUI:

```powershell
# Lite, downloaded from Microsoft, defaults for everything
powershell -ExecutionPolicy Bypass -File .\builder\Build-LiteOS.ps1 -Download

# Core from an ISO you already have, keep OneDrive, no preinstalled runtimes
powershell -ExecutionPolicy Bypass -File .\builder\Build-LiteOS.ps1 -IsoPath D:\Win11_25H2_English_x64.iso -Mode Core -Exclude image.onedrive -Installers steam
```

Useful options: `-Language "English (United States)"`, `-Edition "Windows 11 Home"`, `-Include` / `-Exclude <ids>`
(tweak and removal ids, wildcards allowed), `-Installers default|none|<ids>`, `-Apps default|none|<ids>`,
`-NoBypassRequirements` (keep Microsoft's TPM / CPU checks), `-KeepAutoEncryption`, `-Compression Esd|Max`
(default `Esd` = smaller ISO with `install.esd`; `Max` = faster build with `install.wim`), `-OutputPath`, `-WorkDir`,
`-Yes` (never prompt). Details: [builder/README.md](builder/README.md).

> Running Windows 11 on hardware that does not meet Microsoft's requirements is not supported by Microsoft.
> Some anti-cheat systems (for example Riot Vanguard) require TPM 2.0 and Secure Boot no matter how Windows
> was installed, so a requirement bypass does not help those games.

### Download blocked? (Iran and other regions)

Microsoft's download page refuses some countries and networks (error 715-123130 and similar). With the default
download source **Automatic** the Builder then uses the other official channel by itself: the Windows 11 image
(ESD) that Microsoft's Media Creation Tool downloads, checked against the SHA-256 in Microsoft's catalog and turned
into an ISO on your PC (this needs about 25 GB free while it works). If that is blocked too, the Builder tells you
why and opens [microsoft.com/software-download/windows11](https://www.microsoft.com/software-download/windows11):
download the ISO there (a VPN may be needed) or from a friend who did, check its SHA256 against Microsoft's list
on that page, then choose **Use my ISO**. Never use ISOs from random websites. See the [FAQ](docs/FAQ.md#microsoft-blocks-the-download-in-my-country-iran-etc).

## What is baked in

Everything is defined in plain JSON / XML in [`image/`](image) and listed in [docs/IMAGE.md](docs/IMAGE.md):

- **Removed from the image**: preinstalled bloat apps ([tweaks/apps-remove.json](tweaks/apps-remove.json)) and
  unneeded Windows components ([image/removals.json](image/removals.json)), per mode.
- **Tweaks**: the Balanced (Lite) or Extreme (Core) set from [docs/TWEAKS.md](docs/TWEAKS.md), applied offline
  to the image and recorded so `Revert-LiteOS.ps1` can undo them later.
- **Preinstalled**: Steam, VC++ 2015-2022 x64 + x86, DirectX June 2010, .NET Desktop Runtime 8
  ([image/installers.json](image/installers.json)). The Builder downloads each one from the vendor's official
  URL and only bakes it in when its digital signature is valid and from the expected publisher.
- **Branding**: Lite OS as OEM name, model, support link, boot menu entry, image name and ISO label
  ([image/branding.json](image/branding.json)). Microsoft binaries, `ProductName` and `EditionID` are never
  changed, so updates and activation keep working.
- **Layout**: Start pins File Explorer, Steam, Xbox, Microsoft Store, Settings, Terminal and Edge (Lite);
  taskbar pins File Explorer, Edge, Steam, Xbox and Microsoft Store ([image/layout](image/layout)). You can
  rearrange everything afterwards.
- **Setup**: local account allowed without internet, no EULA or online-account screens. Language, keyboard,
  disk and account stay your choice.

## Lite OS Tweaks: for the Windows you already have

Do not want to reinstall? The same tweak engine runs on an existing Windows 11 24H2 / 25H2 install.

1. Extract the zip (see steps 1-2 above) and double-click **`Start-LiteOS.cmd`**. Accept the administrator prompt.
2. Choose **1 - Balanced (recommended)**. Lite OS creates a System Restore point and a backup, applies the tweaks
   and prints a summary. Restart when it asks.

The menu also has **2 Extreme**, **3 Custom** (pick categories or single tweaks), **4 Install gaming apps**,
**5 Revert**, **6 View log**. Image-level removals (Windows components, Edge, Defender) are only done by the
Builder - on a running system Lite OS only removes apps and changes settings.

```powershell
# preview everything Balanced would do, change nothing
powershell -ExecutionPolicy Bypass -File .\LiteOS.ps1 -Level Balanced -DryRun

# apply Balanced without prompts, keep Widgets, add the classic right-click menu, install the default apps
powershell -ExecutionPolicy Bypass -File .\LiteOS.ps1 -Level Balanced -Silent -Exclude ui.widgets-off -Include ui.classic-context-menu -Apps default
```

### What Lite / Balanced never touches

- Windows Defender (real-time and tamper protection) and Windows Security
- Windows Update security updates
- Microsoft Store, App Installer (winget)
- Xbox app, Game Pass, Gaming Services, Game Bar and the Xbox sign-in components
- Edge and WebView2 (many launchers and apps need WebView2)
- Windows Hello, TPM, BitLocker (if you turn it on), VBS / HVCI / memory integrity
- Kernel anti-cheat drivers and services: Vanguard, Easy Anti-Cheat, BattlEye, Ricochet, FACEIT, EA Javelin
- Your disks and partitions, Secure Boot and firmware settings

These rules are enforced by automated tests on every change ([tests/](tests)).

## Updates

- **Lite**: Windows Update works normally, including security updates. Big feature updates (for example 25H2 to
  the next version) can bring back some apps or reset settings - run `Start-LiteOS.cmd` > Balanced afterwards,
  or build a fresh Lite OS from the new ISO.
- **Core**: no Windows Update. Build a new Core ISO from the latest official ISO every few months and reinstall.
- **Lite OS itself**: download the new release zip; your installed system keeps working without it.

## Undo and safety

- **Baked tweaks** are recorded in the image (`%ProgramData%\LiteOS\backup\backup-image.json`); run
  `C:\LiteOS\Start-LiteOS.cmd` > 5 Revert to undo them on the installed system.
- **Tweaks applied later** get a restore point and a backup each; `Revert-LiteOS.ps1` restores the latest one.
- **Removed apps and components** cannot be restored automatically. Reinstall apps from Microsoft Store or winget;
  components removed from the image come back only with a reinstall.
- **Logs**: `%ProgramData%\LiteOS\logs` on the installed system (a copy of the build log is in the image too);
  the Builder shows its live log while it builds.
- Lite OS itself collects and sends no data.

## Documentation

- [docs/IMAGE.md](docs/IMAGE.md) - everything removed, preinstalled and branded, per mode (generated)
- [docs/TWEAKS.md](docs/TWEAKS.md) - every tweak, its level, risk and what it does (generated)
- [docs/FAQ.md](docs/FAQ.md) - ISO download, updates, anti-cheat, activation, dual-boot, blocked regions
- [builder/README.md](builder/README.md) - the Builder in detail
- [CONTRIBUTING.md](CONTRIBUTING.md) - how to add or change a tweak or removal
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) - how the pieces fit together

## Legal

Lite OS is an independent community project. It is **not affiliated with, endorsed by or sponsored by
Microsoft**. Windows, Xbox, Game Pass and related names are trademarks of Microsoft Corporation; Steam is a
trademark of Valve Corporation; all other trademarks belong to their owners.

**Lite OS does not distribute Windows.** This repository and its releases contain only scripts, JSON and
documentation - no ISO or WIM images, no Windows files, no product keys and no activation tools. Every Lite OS
image is built on the user's own PC from the official ISO Microsoft provides to that user, and our CI never
uploads one. You need a valid Windows license; Lite OS never changes or bypasses activation.

The software is provided as is, without warranty of any kind. Back up your data before installing an operating
system.

## License

[GPL-3.0](LICENSE). Contributions are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md).

# Lite OS

**A gaming-focused Windows 11, built from your own official Microsoft ISO.**

[![CI](https://github.com/therealvandad/lite-os/actions/workflows/ci.yml/badge.svg)](https://github.com/therealvandad/lite-os/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

Lite OS is real Windows 11 (24H2 / 25H2, build 26100 or newer) with the ads, nags, bloat and background noise
taken out and gaming-friendly defaults put in. It is **not** a Linux distribution and **not** a re-packaged
Windows download: it is a set of open, readable PowerShell scripts and JSON files that you run on Windows
you already own.

- Plays everything Windows plays: Steam, Epic, Battle.net, EA app, Ubisoft Connect, GOG, Xbox app and Game Pass.
- Keeps kernel anti-cheat working in the default **Balanced** level (Vanguard, Easy Anti-Cheat, BattlEye,
  Ricochet, FACEIT, EA Javelin).
- Keeps you safe in Balanced: Windows Defender and security updates stay on.
- Everything it changes is logged, backed up and can be reverted.
- No Windows files, no product keys, no activators. Bring your own ISO and your own license.

## Honest expectations

Lite OS will not double your FPS. On a healthy PC the gains are mostly smaller and more practical:
less background CPU and disk activity, fewer interruptions while you play, smoother frame times on some
systems, and a cleaner, quieter Windows. Your GPU driver, game settings and hardware still matter far more
than any tweak. If someone promises +50% FPS from registry tweaks, be skeptical - including of us.

## Two ways to use it

| | Playbook | ISO builder |
|---|---|---|
| What it does | Tweaks the Windows install you are running now | Turns an official Windows 11 ISO into a Lite OS ISO for a fresh install |
| You need | Windows 11 24H2 / 25H2, an administrator account | An official Windows 11 ISO from [microsoft.com](https://www.microsoft.com/software-download/windows11), 25 GB free disk space |
| Start with | `Start-LiteOS.cmd` | `builder\Build-LiteOS.ps1` |
| Undo | `Revert-LiteOS.ps1` or menu option 5, plus a System Restore point | Same tools are installed to `C:\LiteOS` |

Both use the same tweak engine (`src/`) and the same tweak catalog (`tweaks/*.json`).

## Quick start: playbook (your current Windows)

1. Download the latest `LiteOS-<version>.zip` from [Releases](https://github.com/therealvandad/lite-os/releases).
   Optionally check its SHA256 against the one on the release page:
   `(Get-FileHash .\LiteOS-<version>.zip -Algorithm SHA256).Hash`
2. Right-click the zip > **Properties** > tick **Unblock** > **OK**. This removes the "downloaded from the
   internet" mark so Windows does not block the scripts.
3. Extract the zip, open the folder and double-click **`Start-LiteOS.cmd`**. Accept the administrator prompt.
4. Choose **1 - Balanced (recommended)**. Lite OS creates a System Restore point and a backup, applies the
   tweaks and prints a summary. Restart when it asks.

The menu also has **2 Extreme**, **3 Custom** (pick categories or single tweaks), **4 Install gaming apps**,
**5 Revert**, **6 View log**.

Command line (run from an elevated PowerShell in the extracted folder):

```powershell
# preview everything Balanced would do, change nothing
powershell -ExecutionPolicy Bypass -File .\LiteOS.ps1 -Level Balanced -DryRun

# apply Balanced without prompts, keep Widgets, add the classic right-click menu, install the default apps
powershell -ExecutionPolicy Bypass -File .\LiteOS.ps1 -Level Balanced -Silent -Exclude ui.widgets-off -Include ui.classic-context-menu -Apps default

# just the optional apps (interactive picker)
powershell -ExecutionPolicy Bypass -File .\src\Install-Apps.ps1
```

Tweak ids are listed in [docs/TWEAKS.md](docs/TWEAKS.md).

## Quick start: ISO builder (fresh install)

1. Download the official Windows 11 ISO from [microsoft.com/software-download/windows11](https://www.microsoft.com/software-download/windows11).
2. From an elevated PowerShell in the extracted Lite OS folder:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\builder\Build-LiteOS.ps1 -IsoPath "$env:USERPROFILE\Downloads\Win11_25H2_English_x64.iso"
   ```

3. Write the resulting `LiteOS-<build>.iso` to a USB stick (for example with Rufus or Ventoy) or use it in a VM.
4. Boot it and install as usual. **You choose the disk and partition in Setup** - Lite OS never wipes or
   partitions disks on its own, so it is safe next to other operating systems. You create a local account in
   setup (you can add a Microsoft account later). On the first logon Lite OS applies the level you picked and
   restarts once.

Useful options: `-Edition "Windows 11 Home"`, `-Level Extreme`, `-Apps none|default|all|<ids>`,
`-NoBypassRequirements` (keep Microsoft's TPM / CPU checks), `-KeepAutoEncryption` (keep automatic device
encryption), `-SplitWim` (for FAT32 USB sticks). Full details: [builder/README.md](builder/README.md).

> Running Windows 11 on hardware that does not meet Microsoft's requirements is not supported by Microsoft.
> Some anti-cheat systems (for example Riot Vanguard) require TPM 2.0 and Secure Boot on Windows 11 no matter
> how Windows was installed, so a requirement bypass does not help those games.

## Balanced vs Extreme

| | **Balanced** (recommended) | **Extreme** |
|---|---|---|
| Meant for | Everyone, including your main gaming PC | Enthusiasts and test rigs that accept the trade-offs |
| Ads, suggestions, sponsored apps, Copilot / Recall, web results in Start | Off | Off |
| Telemetry | Reduced to the minimum your edition allows | Reduced further where possible |
| Preinstalled bloat apps | Removed (Store and Xbox apps are kept) | More removed |
| Gaming and performance defaults | Applied | Applied, plus riskier extras |
| Windows Defender | **On** | May be weakened or turned off |
| Security updates | **Keep installing** | May be paused or blocked |
| Memory integrity (VBS / HVCI) | **Untouched** | May be turned off |
| Microsoft Store, Xbox app, Game Pass, Game Bar | **Work** | May break |
| Kernel anti-cheat | **Works** | Some games may refuse to start |
| Revert | Yes | Yes |

Extreme always shows the full list of what it will do and asks you to type `EXTREME` first. Every Extreme
tweak explains its downside in [docs/TWEAKS.md](docs/TWEAKS.md). Tweaks marked "opt-in" are never applied
unless you pick them.

### What Balanced never touches

- Windows Defender (real-time and tamper protection) and Windows Security
- Windows Update security updates
- Microsoft Store, App Installer (winget)
- Xbox app, Game Pass, Gaming Services, Game Bar and the Xbox sign-in components
- Edge and WebView2 (many launchers and apps need WebView2)
- Windows Hello, TPM, BitLocker (if you turn it on), VBS / HVCI / memory integrity
- Kernel anti-cheat drivers and services: Vanguard, Easy Anti-Cheat, BattlEye, Ricochet, FACEIT, EA Javelin
- Your disks and partitions, Secure Boot and firmware settings

These rules are enforced by automated tests on every change ([tests/Catalog.Tests.ps1](tests/Catalog.Tests.ps1)).

## Undo and safety

- **Restore point**: created before anything changes (unless you pass `-SkipRestorePoint`).
- **Backup**: every change is recorded in `%ProgramData%\LiteOS\backup\backup-<date>.json`.
  `Revert-LiteOS.ps1` (or menu option 5) restores the latest backup in reverse order.
- **Removed apps** cannot be restored automatically - reinstall them from Microsoft Store or with winget.
  The revert tool tells you which ones were removed.
- **Logs**: `%ProgramData%\LiteOS\logs`.
- **Dry run**: `-DryRun` shows every change without making it.
- Lite OS itself collects and sends no data.

## Game compatibility

Lite OS is regular Windows 11, so anything that runs on Windows 11 runs on Lite OS: launchers, mods,
emulators, VR, streaming tools and kernel anti-cheat games. Balanced is designed to keep competitive games
with kernel anti-cheat (Valorant, Fortnite, Apex Legends, Call of Duty, Rainbow Six Siege, PUBG, EA FC,
Battlefield, FACEIT CS2) working. Extreme can break some of them, mostly because it may turn off security
features those games check for. If a game complains after Extreme, revert or re-run with Balanced.

Publishers change their requirements over time. If a game breaks on Balanced, please
[open an issue](https://github.com/therealvandad/lite-os/issues) with the log - that is a bug.

## Optional gaming apps

`src/Install-Apps.ps1` offers game launchers, runtimes, chat and tools from [tweaks/apps-install.json](tweaks/apps-install.json),
installed with winget from the official winget source. Nothing is installed unless you choose it (menu option 4,
`-Apps`, or at ISO build time). Already-installed apps are skipped, and one failed app never stops the rest.

## Documentation

- [docs/TWEAKS.md](docs/TWEAKS.md) - every tweak, its level, risk and what it does (generated from the catalog)
- [docs/FAQ.md](docs/FAQ.md) - games, activation, updates, undo, dual-boot, laptops
- [builder/README.md](builder/README.md) - building a Lite OS ISO
- [CONTRIBUTING.md](CONTRIBUTING.md) - how to add or change a tweak
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) - how the pieces fit together

## Legal

Lite OS is an independent community project. It is **not affiliated with, endorsed by or sponsored by
Microsoft**. Windows, Xbox, Game Pass and related names are trademarks of Microsoft Corporation; all other
trademarks belong to their owners.

Lite OS distributes **no Windows files, no ISO images, no product keys and no activation tools**. You need your
own official Windows 11 media from Microsoft and a valid Windows license. Lite OS never changes your activation.

The software is provided as is, without warranty of any kind. Back up your data before changing your system.

## License

[GPL-3.0](LICENSE). Contributions are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md).

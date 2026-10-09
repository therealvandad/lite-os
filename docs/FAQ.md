# Lite OS FAQ

- [Is Lite OS a real operating system? Is it Linux?](#is-lite-os-a-real-operating-system-is-it-linux)
- [Why is there no direct Lite OS ISO download?](#why-is-there-no-direct-lite-os-iso-download)
- [How does the Builder get Windows?](#how-does-the-builder-get-windows)
- [Microsoft blocks the download in my country (Iran, etc.)](#microsoft-blocks-the-download-in-my-country-iran-etc)
- [Lite or Core?](#lite-or-core)
- [Do Windows updates still work?](#do-windows-updates-still-work)
- [Do anti-cheat games work (Valorant, Fortnite, CS2 / FACEIT, Call of Duty...)?](#do-anti-cheat-games-work-valorant-fortnite-cs2--faceit-call-of-duty)
- [How much FPS will I gain?](#how-much-fps-will-i-gain)
- [Do I need a license? What about activation?](#do-i-need-a-license-what-about-activation)
- [How do I undo Lite OS?](#how-do-i-undo-lite-os)
- [Can I dual-boot? Will it wipe my disk?](#can-i-dual-boot-will-it-wipe-my-disk)
- [I do not want to reinstall. Can I use Lite OS on my current Windows?](#i-do-not-want-to-reinstall-can-i-use-lite-os-on-my-current-windows)
- [Is it OK on a laptop?](#is-it-ok-on-a-laptop)
- [Home or Pro?](#home-or-pro)
- [Can I still use a Microsoft account, OneDrive, Edge, the Store?](#can-i-still-use-a-microsoft-account-onedrive-edge-the-store)
- [Which Windows versions are supported?](#which-windows-versions-are-supported)
- [My antivirus or SmartScreen warns about the scripts](#my-antivirus-or-smartscreen-warns-about-the-scripts)
- [Where are the logs? How do I report a problem?](#where-are-the-logs-how-do-i-report-a-problem)

## Is Lite OS a real operating system? Is it Linux?

Lite OS is Windows 11 - Microsoft's own 24H2 / 25H2 code - rebuilt for gaming. You install it from a USB stick
like any operating system, and it boots and identifies itself as Lite OS (boot menu, OEM information, Start and
taskbar layout). Underneath it is unmodified Windows: there is no custom kernel, no patched system file and no
replacement shell. That is exactly why drivers, games, Game Pass and kernel anti-cheat keep working.

It is not Linux and not a fork you have to trust blindly: what gets removed, changed and preinstalled is listed in
[IMAGE.md](IMAGE.md) and [TWEAKS.md](TWEAKS.md) and defined in readable JSON files.

## Why is there no direct Lite OS ISO download?

Because a downloadable "lite" ISO is either illegal, untrustworthy or both:

1. **Legal**: Windows images are Microsoft's copyrighted software. Redistributing modified Windows images is not
   allowed by Microsoft's license, so we do not do it - not on GitHub, not as a CI artifact, not anywhere. The
   Lite OS Builder builds the image on **your** PC from the ISO Microsoft gives **you**.
2. **Trust**: you cannot check what is inside a random pre-modified ISO, and that is a classic way to spread
   malware and miners. With Lite OS you start from Microsoft's original files, and every change is a readable
   line in this repository. The Builder prints the SHA256 of your ISO so you can verify your stick.
3. **Freshness**: building from the current official ISO gives you the latest Windows build and security fixes,
   instead of an image someone made months ago.

It costs you one click and some waiting: the Builder downloads, builds and checks everything by itself.

## How does the Builder get Windows?

**Download Windows 11 from Microsoft** uses the same public Microsoft download service that the
microsoft.com download page, Rufus and Fido use. It asks Microsoft for the official Windows 11 x64
multi-edition ISO in your language, downloads it from Microsoft's own servers
(`software.download.prss.microsoft.com`) and checks that the file really is a Windows 11 ISO. Nothing comes
from Lite OS servers - we do not have any.

**Use my ISO** builds from an official ISO you downloaded yourself.

## Microsoft blocks the download in my country (Iran, etc.)

Microsoft does not serve Windows downloads to some countries and networks (for example Iran, and sometimes VPN
or data-center IP addresses). You then see an error such as **715-123130** or "your request was blocked". The
Builder explains this and opens [microsoft.com/software-download/windows11](https://www.microsoft.com/software-download/windows11)
for you. Then:

1. Download the ISO from that page manually - from another network, with a VPN, or ask a friend abroad to
   download it for you. Choose **Windows 11 (multi-edition ISO for x64 devices)** and your language.
2. Check it: compare `Get-FileHash <file>.iso -Algorithm SHA256` with the hash list Microsoft shows on the same
   download page.
3. In the Builder choose **Use my ISO** (or `Build-LiteOS.ps1 -IsoPath <file>.iso`). Building itself needs no
   connection to Microsoft; only the optional installers (Steam, runtimes) are downloaded from their vendors -
   untick them if those are blocked too, and install them later.

Do not use ISOs from random websites or Telegram channels - you cannot know what was changed in them.

## Lite or Core?

**Lite** (default) is for your main PC: it removes bloat and bakes in the Balanced tweaks, but keeps Windows
Update, Defender, the Microsoft Store, Edge, WinRE and everything games and anti-cheat need.

**Core** is for people who want an X-Lite-style minimal system and accept the cost: it also removes or disables
Windows Defender, the Windows Update stack, the Edge browser (WebView2 stays) and the recovery environment, and
uses the Extreme tweaks. A Core system gets **no security updates**, has **no built-in antivirus**, cannot
"Reset this PC", and some games may stop working when they start to require newer Windows or security features.
The full list is in [IMAGE.md](IMAGE.md#core-removals). If you are unsure, use Lite.

## Do Windows updates still work?

- **Lite: yes.** Windows Update and security updates keep working. The image is cleaned with
  `/StartComponentCleanup /ResetBase`, which only means updates that were already in the ISO cannot be
  uninstalled. Big feature updates (for example to the next yearly version) can bring back some apps or reset
  settings: run `C:\LiteOS\Start-LiteOS.cmd` > Balanced afterwards, or build a fresh Lite OS from the new ISO.
- **Core: no.** Core is not serviceable on purpose. To get a newer Windows build, build a new Core ISO from the
  latest official ISO and reinstall. Plan to do that every few months, and keep your games on a separate drive or
  partition so a reinstall is quick.
- **Drivers**: Lite keeps getting drivers through Windows Update unless you picked the opt-in tweak that turns
  that off. On Core, install your GPU, chipset and network drivers from the vendors.
- **Store apps** (Xbox app, Gaming Services) update through the Microsoft Store in Lite. In Core, Store and Game
  Pass downloads depend on the removed Windows Update service and can fail.

## Do anti-cheat games work (Valorant, Fortnite, CS2 / FACEIT, Call of Duty...)?

**In Lite, yes.** Lite is designed - and automatically tested - to leave alone everything games and kernel
anti-cheat rely on: Defender, VBS / memory integrity, TPM, Secure Boot, Xbox / Game Pass / Gaming Services, Game
Bar, Edge WebView2, and the drivers and services of Vanguard, Easy Anti-Cheat, BattlEye, Ricochet, FACEIT and EA
Javelin. If a game breaks on Lite, that is a bug - please open an issue with your log.

**In Core, usually - but not guaranteed.** Anti-cheat systems increasingly check for an up-to-date Windows,
Secure Boot, TPM 2.0, memory integrity (HVCI) or a running antivirus. Core removes Windows Update and Defender, so
games can start refusing to run after a while.

Either way: some anti-cheat (for example Riot Vanguard, EA Javelin for Battlefield) needs **TPM 2.0 and Secure
Boot enabled in your firmware**. The Builder's requirement bypass lets Setup install on older PCs, but it cannot
make those games run without TPM / Secure Boot.

## How much FPS will I gain?

Usually not much in average FPS, and anyone who promises big numbers from a "lite" Windows is guessing. What you
can expect is less background activity (telemetry, suggestions, indexing, sponsored app installs), fewer pop-ups
and interruptions, and on some systems smoother frame times. GPU drivers, in-game settings, cooling and hardware
matter much more. If you measure a real difference, we would love to see the numbers
(see [CONTRIBUTING.md](../CONTRIBUTING.md)).

## Do I need a license? What about activation?

Yes, you need a valid Windows 11 license, exactly as with any Windows install. Lite OS never touches activation
and ships no product keys or activation tools; it does not change `ProductName` or `EditionID` either. If your PC
came with Windows or you linked your license to your Microsoft account, Windows activates itself after
installation (Settings > System > Activation). Otherwise enter your own product key there. Setup also lets you
choose "I don't have a product key" and activate later.

## How do I undo Lite OS?

- **Tweaks baked into the image** are recorded in `%ProgramData%\LiteOS\backup\backup-image.json` on the
  installed system. Run `C:\LiteOS\Start-LiteOS.cmd` > 5 Revert (or `Revert-LiteOS.ps1`) to undo them.
- **Tweaks applied later** (Lite OS Tweaks) get a System Restore point and their own backup; Revert restores the
  latest one, older ones can be picked too (`Get-Help .\Revert-LiteOS.ps1 -Detailed`).
- **Removed apps** can be reinstalled from Microsoft Store or with `winget install <id>`.
- **Components removed from the image** (and everything Core removes) only come back by installing Windows (or a
  Lite OS build without that removal) again.

## Can I dual-boot? Will it wipe my disk?

Yes, you can dual-boot, and no, nothing is wiped automatically. The Lite OS answer file never contains disk or
partition settings: Windows Setup stops at "Where do you want to install Windows?" exactly like the normal
Microsoft installer, and you pick the disk or partition yourself. Lite OS never touches Secure Boot, TPM or
firmware settings, and the Builder never writes to USB drives - you flash the ISO yourself with Rufus.

Tips: install Windows first and the other OS second, back up first, and if the other OS needs to read your
Windows drive, turn off Fast Startup (Control Panel > Power Options > "Choose what the power buttons do").

## I do not want to reinstall. Can I use Lite OS on my current Windows?

Yes: **Lite OS Tweaks** (`Start-LiteOS.cmd`) applies the same tweak catalog to the Windows 11 24H2 / 25H2 you are
running now - Balanced, Extreme or Custom - with a restore point, a backup and a revert. It removes preinstalled
apps and changes settings, but it does not do the image-level removals (Windows components, Edge, Defender, WinRE);
those only happen in the Builder.

## Is it OK on a laptop?

Yes, with two things to know:

- Some performance tweaks favor responsiveness over battery life. On a laptop, look at the performance category
  in [TWEAKS.md](TWEAKS.md) and use **Customize** in the Builder (or `-Exclude <id>`) for anything you do not want.
- Many laptops encrypt the drive automatically (BitLocker device encryption). The Builder turns off *automatic*
  device encryption for fresh installs unless you choose **Keep automatic encryption** (`-KeepAutoEncryption`);
  you can still turn BitLocker on yourself at any time. If BitLocker is on, make sure you have your recovery key
  (https://aka.ms/myrecoverykey) before changing anything.

## Home or Pro?

Both work - pick the edition your license is for (the Builder defaults to Windows 11 Pro). Pro gives you a few
more policy controls. On every edition Microsoft keeps a minimum ("Required") level of diagnostic data; Lite OS
sets that minimum and turns off what it can around it, but no honest tool can promise "zero telemetry" on Home or
Pro.

## Can I still use a Microsoft account, OneDrive, Edge, the Store?

- **Microsoft account**: yes. Setup lets you create a local account; sign in with a Microsoft account later in
  Settings > Accounts.
- **Store, Xbox app, Game Pass**: kept in both modes (in Core, Store downloads may fail - see above).
- **Edge**: kept in Lite. Core removes the Edge browser but keeps WebView2, which launchers and apps need; pick
  Firefox or Brave as a first-logon app, or install any browser later.
- **OneDrive**: removed from the image by default (see [IMAGE.md](IMAGE.md)). Install it again any time with
  `winget install Microsoft.OneDrive`, or exclude its removal when you build.

## Which Windows versions are supported?

- **Image**: official Windows 11 24H2 and 25H2 ISOs (build 26100 and newer), x64. Older ISOs are refused or
  warned about; ARM64 is untested.
- **Build PC**: Windows 10 or 11, 64-bit, with the built-in Windows PowerShell 5.1, administrator rights and about
  30 GB free space (40 GB when it downloads Windows).
- **Lite OS Tweaks**: Windows 11 24H2 / 25H2. Windows 10 and Windows 11 23H2 or older are not supported.

## My antivirus or SmartScreen warns about the scripts

Scripts downloaded from the internet carry a "mark of the web". Unblock the zip before extracting it
(right-click > Properties > Unblock). Some third-party antivirus products are nervous about any script that
changes system settings or Windows images; everything Lite OS does is plain text you can read in `builder/`,
`image/`, `src/` and `tweaks/`. Only download Lite OS from the official
[GitHub releases](https://github.com/therealvandad/lite-os/releases) and check the SHA256.

## Where are the logs? How do I report a problem?

- **Builder**: the live log in the Builder window; a copy of the build log is also placed in the image under
  `%ProgramData%\LiteOS`.
- **Installed system**: logs in `%ProgramData%\LiteOS\logs`, backups in `%ProgramData%\LiteOS\backup`.

Please open an [issue](https://github.com/therealvandad/lite-os/issues) with your Windows build (`winver`), the
mode (Lite / Core) or level you used, the log files and what broke.

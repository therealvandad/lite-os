# Lite OS FAQ

- [Is Lite OS a different operating system or a Linux distro?](#is-lite-os-a-different-operating-system-or-a-linux-distro)
- [Will it break my games?](#will-it-break-my-games)
- [How much FPS will I gain?](#how-much-fps-will-i-gain)
- [Do I need a license? What about activation?](#do-i-need-a-license-what-about-activation)
- [Do Windows updates still work?](#do-windows-updates-still-work)
- [How do I undo Lite OS?](#how-do-i-undo-lite-os)
- [Why don't you just share a ready-made ISO?](#why-dont-you-just-share-a-ready-made-iso)
- [Can I dual-boot?](#can-i-dual-boot)
- [Is it OK on a laptop?](#is-it-ok-on-a-laptop)
- [Home or Pro?](#home-or-pro)
- [Can I still use a Microsoft account, OneDrive, Edge, the Store?](#can-i-still-use-a-microsoft-account-onedrive-edge-the-store)
- [Which Windows versions are supported?](#which-windows-versions-are-supported)
- [My antivirus or SmartScreen warns about the scripts](#my-antivirus-or-smartscreen-warns-about-the-scripts)
- [Where are the logs? How do I report a problem?](#where-are-the-logs-how-do-i-report-a-problem)

## Is Lite OS a different operating system or a Linux distro?

No. Lite OS is Windows 11 - the same Windows you get from Microsoft - with a curated set of settings changed
and some preinstalled apps removed. There is no custom kernel, no patched system files and no replacement
shell. That is exactly why games, drivers and anti-cheat keep working.

## Will it break my games?

With **Balanced**, it should not. Balanced is designed (and automatically tested) to leave alone everything
games and anti-cheat depend on: Windows Defender, VBS / memory integrity, TPM, Secure Boot, Xbox / Game Pass /
Gaming Services, Game Bar, Edge WebView2, and the drivers and services of Vanguard, Easy Anti-Cheat, BattlEye,
Ricochet, FACEIT and EA Javelin.

**Extreme** is different: it may turn off security features that some anti-cheat systems check for, and it
removes more apps. Some games may refuse to start after Extreme. Every Extreme tweak says so in
[TWEAKS.md](TWEAKS.md). If a game stops working, revert (menu option 5) or run Balanced instead.

If a game breaks on Balanced, that is a bug - please open an issue with your log.

## How much FPS will I gain?

Usually not much in average FPS, and anyone who promises big numbers from registry tweaks is guessing. What
you can expect is less background activity (telemetry, suggestions, indexing, sponsored app installs), fewer
pop-ups and interruptions, and on some systems smoother frame times. GPU drivers, in-game settings, cooling
and hardware matter much more. If you measure a real difference, we would love to see the numbers
(see [CONTRIBUTING.md](../CONTRIBUTING.md)).

## Do I need a license? What about activation?

Yes, you need a valid Windows 11 license, exactly as with any Windows install. Lite OS never touches
activation and ships no product keys or activation tools. If your PC came with Windows or you linked your
license to your Microsoft account, Windows activates itself after installation (Settings > System >
Activation). Otherwise enter your own product key there.

## Do Windows updates still work?

Yes. In **Balanced**, Windows Update and security updates keep working; Lite OS only changes how updates
behave (for example no peer-to-peer sharing of update files with other PCs, and no surprise restarts while
you are signed in). Optional tweaks let you defer feature updates or keep driver updates out of
Windows Update - they are off unless you pick them.

**Extreme** can reduce Windows Update to "notify only" or similar. You are then responsible for installing
security updates yourself.

Big feature updates (for example 24H2 to 25H2) can reset some settings and bring back some apps. Just run
Lite OS again afterwards - a new backup is created for every run.

## How do I undo Lite OS?

- **Revert**: run `Revert-LiteOS.ps1` (or `Start-LiteOS.cmd` > 5). It restores the latest backup from
  `%ProgramData%\LiteOS\backup\` in reverse order. Older backups can be chosen too; see
  `Get-Help .\Revert-LiteOS.ps1 -Detailed`.
- **System Restore**: Lite OS creates a restore point before it changes anything (unless you used
  `-SkipRestorePoint`). Open "Create a restore point" > System Restore to roll back.
- **Removed apps** are not restored automatically. Reinstall them from Microsoft Store or with
  `winget install <id>`; the revert tool lists what was removed.

## Why don't you just share a ready-made ISO?

Three reasons:

1. **Legal**: Microsoft's license does not allow redistributing modified Windows images. We only ship scripts;
   Windows comes from Microsoft.
2. **Trust**: you cannot easily check what is inside a random pre-modified ISO, and that is a classic way to
   spread malware. With Lite OS you start from an ISO you downloaded from microsoft.com yourself, and every
   change is a readable line in a script or JSON file.
3. **Freshness**: building from the latest official ISO gives you the latest Windows build and security fixes.

## Can I dual-boot?

Yes. The ISO builder never adds disk or partition settings to the installer: Windows Setup asks you where to
install, exactly like the normal Microsoft installer, and nothing is wiped automatically. The playbook only
changes the Windows you run it on. Lite OS never touches Secure Boot, TPM or firmware settings.

Tips: install Windows first and the other OS second, keep a backup, and if the other OS needs to read your
Windows drive, turn off Fast Startup (Control Panel > Power Options > "Choose what the power buttons do").

## Is it OK on a laptop?

Yes, with two things to know:

- Some performance tweaks favor responsiveness over battery life. On a laptop, look at the performance
  category in [TWEAKS.md](TWEAKS.md) and use **Custom** mode or `-Exclude <id>` for anything you do not want.
- Many laptops encrypt the drive automatically (BitLocker device encryption). The playbook leaves BitLocker
  alone. The ISO builder turns off *automatic* device encryption for fresh installs unless you pass
  `-KeepAutoEncryption`; you can still turn BitLocker on yourself at any time. If BitLocker is on, make sure
  you have your recovery key (https://aka.ms/myrecoverykey) before changing anything.

## Home or Pro?

Both work. Pro gives you a few more policy controls. On every edition Microsoft keeps a minimum
("Required") level of diagnostic data; Lite OS sets that minimum and turns off what it can around it, but no
honest tool can promise "zero telemetry" on Home or Pro.

## Can I still use a Microsoft account, OneDrive, Edge, the Store?

Yes. Lite OS does not remove the Store, Edge, WebView2 or the Xbox components, and it does not block
Microsoft accounts. The ISO lets you create a local account during setup; you can sign in with a Microsoft
account later in Settings > Accounts.

## Which Windows versions are supported?

Windows 11 24H2 and 25H2 (build 26100 and newer) on x64 PCs. Lite OS warns you on older builds; Windows 10 and
Windows 11 23H2 or older are not supported. ARM64 PCs are untested.

## My antivirus or SmartScreen warns about the scripts

Scripts downloaded from the internet carry a "mark of the web". Unblock the zip before extracting it
(right-click > Properties > Unblock). Some third-party antivirus products are nervous about any script that
changes system settings; everything Lite OS does is plain text you can read in `src/`, `tweaks/` and
`builder/`. Only download Lite OS from the official
[GitHub releases](https://github.com/therealvandad/lite-os/releases) and check the SHA256.

## Where are the logs? How do I report a problem?

Logs are in `%ProgramData%\LiteOS\logs`, backups in `%ProgramData%\LiteOS\backup`. Please open an
[issue](https://github.com/therealvandad/lite-os/issues) with your Windows build (`winver`), the level you
used, the log file and what broke.

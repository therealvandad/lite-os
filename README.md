# Atlas OS

A gaming-first Linux distribution based on Arch Linux.

- **Console mode**: boots straight into Steam's console UI (gamescope), controller-friendly, like a Steam Deck / console.
- **Desktop mode**: in Steam, use *Power → Switch to Desktop* to get a full KDE Plasma desktop. *Return to Console* switches back.
- NVIDIA (open kernel modules, RTX 20-series and newer), AMD and Intel GPUs out of the box.
- Steam + Proton, Lutris, Wine, GameMode, MangoHud preinstalled.
- Gaming tweaks: zram, BBR networking, split-lock mitigation off, max_map_count raised.
- **Offline installer** with two modes: **dual-boot** next to Windows, or **erase a whole disk**.

## Install

1. Download the ISO from [Releases](../../releases) and join the parts (see the release notes).
2. Flash it to a USB stick (8 GB+) with [Rufus](https://rufus.ie) or balenaEtcher.
3. In your BIOS: **disable Secure Boot** and boot the USB in **UEFI** mode.
4. *Dual-boot only:* first, in Windows, open Disk Management → shrink a volume → create an empty partition (100 GB+), and turn off Fast Startup.
5. In the live desktop, double-click **Install Atlas OS**.

On every boot a GRUB menu lets you pick Atlas OS or Windows.

## Build it yourself

GitHub Actions builds the ISO on every push. To build locally on Arch Linux:

```bash
sudo pacman -S archiso grub
sudo ./build.sh
```

## Layout

| Path | What it does |
|---|---|
| `packages.x86_64` | Packages included in the ISO |
| `overlay/` | Files copied into the system (sessions, tweaks, installer) |
| `services.txt` | systemd units enabled on the ISO |
| `build.sh` | Builds the ISO on top of archiso's `releng` profile |

## License

GPL-3.0 for the Atlas OS scripts. Bundled packages keep their own licenses.

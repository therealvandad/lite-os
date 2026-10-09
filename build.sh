#!/bin/bash
# Builds the Lite OS ISO. Run as root on Arch Linux (CI uses an archlinux container).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
P=/tmp/lite-profile; W=/tmp/lite-work; OUT=${OUT:-$HERE/out}
rm -rf "$P" "$W"; cp -r /usr/share/archiso/configs/releng "$P"

# Profile metadata
sed -i -e 's/^iso_name=.*/iso_name="liteos"/' \
       -e 's/^iso_label=.*/iso_label="LITE_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"/' \
       -e 's/^iso_publisher=.*/iso_publisher="Lite OS <https:\/\/github.com\/therealvandad\/lite-os>"/' \
       -e 's/^iso_application=.*/iso_application="Lite OS Live\/Install"/' "$P/profiledef.sh"
cat >> "$P/profiledef.sh" <<'X'
file_permissions+=(
  ["/usr/bin/lite-console"]="0:0:755"
  ["/usr/bin/lite-firstrun"]="0:0:755"
  ["/usr/bin/lite-session-set"]="0:0:755"
  ["/usr/bin/steamos-session-select"]="0:0:755"
  ["/usr/local/bin/lite-install"]="0:0:755"
  ["/usr/local/bin/lite-live-setup"]="0:0:755"
  ["/etc/sudoers.d/10-lite"]="0:0:440"
)
X
# multilib for Steam / 32-bit drivers
sed -i '/^#\[multilib\]/{N;s/#\[multilib\]\n#Include/[multilib]\nInclude/}' "$P/pacman.conf"
cp "$HERE/packages.x86_64" "$P/packages.x86_64"

# Drop releng's console-only bits (tty autologin, networkd/iwd, etc.)
rm -rf "$P/airootfs/etc/systemd/system/getty@tty1.service.d" "$P/airootfs/etc/systemd/network"
find "$P/airootfs/etc/systemd/system" -maxdepth 1 -name '*.wants' -exec rm -rf {} +
rm -f "$P/airootfs/etc/systemd/system/"*.service.d/* 2>/dev/null || true

# Our overlay + services
cp -rT "$HERE/overlay" "$P/airootfs"
SD="$P/airootfs/etc/systemd/system"
while IFS= read -r l; do
  [ -z "$l" ] && continue
  if [[ "$l" == *=* ]]; then ln -sf "/usr/lib/systemd/system/${l#*=}" "$SD/${l%%=*}"
  else mkdir -p "$SD/$(dirname "$l")"
       u=$(basename "$l"); src=/usr/lib/systemd/system/$u
       [ -f "$P/airootfs/etc/systemd/system/$u" ] && src=/etc/systemd/system/$u
       ln -sf "$src" "$SD/$l"; fi
done < "$HERE/services.txt"
ln -sf /usr/lib/systemd/system/graphical.target "$SD/default.target"

# Branding in boot menus
grep -rl 'Arch Linux' "$P/efiboot" "$P/syslinux" "$P/grub" 2>/dev/null | xargs -r sed -i 's/Arch Linux/Lite OS/g'

mkdir -p "$OUT"
mkarchiso -v -w "$W" -o "$OUT" "$P"
cd "$OUT" && sha256sum liteos-*.iso > SHA256SUMS && ls -lh

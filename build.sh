#!/bin/bash
# Builds the Atlas OS ISO. Run as root on Arch Linux (CI uses an archlinux container).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
P=/tmp/atlas-profile; W=/tmp/atlas-work; OUT=${OUT:-$HERE/out}
rm -rf "$P" "$W"; cp -r /usr/share/archiso/configs/releng "$P"

# Profile metadata
sed -i -e 's/^iso_name=.*/iso_name="atlasos"/' \
       -e 's/^iso_label=.*/iso_label="ATLAS_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"/' \
       -e 's/^iso_publisher=.*/iso_publisher="Atlas OS <https:\/\/github.com\/therealvandad\/atlas-os>"/' \
       -e 's/^iso_application=.*/iso_application="Atlas OS Live\/Install"/' "$P/profiledef.sh"
cat >> "$P/profiledef.sh" <<'X'
file_permissions+=(
  ["/usr/bin/atlas-console"]="0:0:755"
  ["/usr/bin/atlas-session-set"]="0:0:755"
  ["/usr/bin/steamos-session-select"]="0:0:755"
  ["/usr/local/bin/atlas-install"]="0:0:755"
  ["/usr/local/bin/atlas-live-setup"]="0:0:755"
  ["/etc/sudoers.d/10-atlas"]="0:0:440"
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
grep -rl 'Arch Linux' "$P/efiboot" "$P/syslinux" "$P/grub" 2>/dev/null | xargs -r sed -i 's/Arch Linux/Atlas OS/g'

mkdir -p "$OUT"
mkarchiso -v -w "$W" -o "$OUT" "$P"
cd "$OUT" && sha256sum atlasos-*.iso > SHA256SUMS && ls -lh

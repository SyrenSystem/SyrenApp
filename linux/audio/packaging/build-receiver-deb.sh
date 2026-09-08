#!/bin/sh
set -eu

source_directory="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
output_directory="${1:-$source_directory/../../build/debian}"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
package_root="$temporary_directory/package"
install -d "$package_root/DEBIAN" "$package_root/usr/lib/syren-rtp/templates" \
  "$package_root/usr/lib/systemd/system" "$package_root/usr/sbin"
for module in common compatibility graph shared_graph ingress session worker receiver; do
  install -m 644 "$source_directory/$module.py" "$package_root/usr/lib/syren-rtp/$module.py"
done
chmod 755 "$package_root/usr/lib/syren-rtp/receiver.py"
install -m 644 "$source_directory/compatibility.json" "$package_root/usr/lib/syren-rtp/compatibility.json"
install -m 644 "$source_directory"/templates/receiver.conf.in "$source_directory"/templates/shared-receiver.conf.in "$source_directory"/templates/pulse.conf "$package_root/usr/lib/syren-rtp/templates/"
install -m 644 "$source_directory"/packaging/*.service "$source_directory"/packaging/*.socket "$package_root/usr/lib/systemd/system/"
install -m 755 "$source_directory/packaging/configure-receiver.py" "$package_root/usr/sbin/syren-rtp-configure"
install -m 755 "$source_directory/packaging/receiver-maintenance" "$package_root/usr/lib/syren-rtp/maintenance"
for action in preinst postinst prerm postrm; do
  {
    printf '#!/bin/sh\nset -eu\n'
    if [ "$action" = postrm ]; then
      printf 'systemctl daemon-reload\n'
    elif [ "$action" = preinst ]; then
      printf 'if [ -x /usr/lib/syren-rtp/maintenance ]; then\n  if [ -e /etc/syrensystem/receiver.json ]; then\n    timeout 20 systemctl start syren-rtp-broker.socket\n  fi\n  /usr/lib/syren-rtp/maintenance %s\nfi\n' "$action"
    else
      printf '/usr/lib/syren-rtp/maintenance %s\n' "$action"
    fi
  } > "$package_root/DEBIAN/$action"
  chmod 755 "$package_root/DEBIAN/$action"
done
cat > "$package_root/DEBIAN/control" <<'CONTROL'
Package: syren-rtp-receiver
Version: 1.1.2
Section: sound
Priority: optional
Architecture: all
Depends: python3, systemd, pipewire-bin, snapclient, libpipewire-0.3-modules, libspa-0.2-modules, alsa-utils, openssh-server
Maintainer: SyrenSystem
Description: Opt in single receiver RTP audio for a trusted LAN
 Low latency, validation incomplete. Playback starts only by explicit request.
CONTROL
mkdir -p "$output_directory"
dpkg-deb --root-owner-group --build "$package_root" "$output_directory/syren-rtp-receiver_1.1.2_all.deb"

#!/bin/sh
set -eu
source_directory="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
output_directory="${1:-$source_directory/../../build/debian}"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
package_root="$temporary_directory/package"
install -d "$package_root/DEBIAN" "$package_root/usr/lib/syren-sessions/templates" "$package_root/usr/lib/systemd/system"
for module in common graph ingress session_control session_graph session_selection session_receiver; do
  install -m 644 "$source_directory/$module.py" "$package_root/usr/lib/syren-sessions/$module.py"
done
install -m 644 "$source_directory/templates/session-output.conf.in" "$source_directory/templates/pulse.conf" "$package_root/usr/lib/syren-sessions/templates/"
install -m 644 "$source_directory/packaging/syren-session-receiver.service" "$package_root/usr/lib/systemd/system/"
install -d "$package_root/usr/lib/NetworkManager/conf.d"
cat > "$package_root/usr/lib/NetworkManager/conf.d/syren-session-receiver.conf" <<'NETWORK'
# WiFi power saving holds audio packets back and delivers them in bursts.
[connection]
wifi.powersave=2
NETWORK
chmod 644 "$package_root/usr/lib/NetworkManager/conf.d/syren-session-receiver.conf"
for unit in snapclient.service syren-rtp-audio.service syren-rtp-broker.service syren-rtp-broker.socket; do
  install -d "$package_root/usr/lib/systemd/system/$unit.d"
  printf '[Unit]\nConditionPathExists=!/etc/syrensystem/profile-sessions.active\n' > "$package_root/usr/lib/systemd/system/$unit.d/profile-sessions.conf"
done
cat > "$package_root/DEBIAN/control" <<'CONTROL'
Package: syren-session-receiver
Version: 3.4.0
Section: sound
Priority: optional
Architecture: all
Depends: python3, python3-paho-mqtt (>= 2.0), systemd, pipewire-bin, snapclient (>= 0.35.0), libpipewire-0.3-modules, libspa-0.2-modules, alsa-utils
Maintainer: SyrenSystem
Description: Profile session selection and persistent mixed speaker output
 Requires coordinated protocol version 3 activation and Snapclient Pulse support.
CONTROL
cat > "$package_root/DEBIAN/postinst" <<'INSTALL'
#!/bin/sh
set -eu
getent passwd syren-rtp >/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin --groups audio syren-rtp
systemctl daemon-reload
# NetworkManager applies the WiFi setting on the next connection, so it is also switched off now.
if command -v iw >/dev/null 2>&1; then
  for wireless in /sys/class/net/*/wireless; do
    [ -e "$wireless" ] || continue
    iw dev "$(basename "$(dirname "$wireless")")" set power_save off || true
  done
fi
INSTALL
chmod 755 "$package_root/DEBIAN/postinst"
mkdir -p "$output_directory"
dpkg-deb --root-owner-group --build "$package_root" "$output_directory/syren-session-receiver_3.4.0_all.deb"

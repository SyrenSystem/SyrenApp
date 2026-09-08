#!/bin/sh
set -eu

[ "$(id -u)" = 0 ] || { echo 'Run this installer with sudo.' >&2; exit 1; }
receiver_state=$(systemctl is-active syren-rtp.service || true)
case "$receiver_state" in
    inactive|failed|unknown) ;;
    *) echo 'Stop the prototype before updating its files.' >&2; exit 1 ;;
esac
source_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_version=$(apt-cache policy pipewire-bin | sed -n 's/^  Candidate: //p')
case "$package_version" in
    1.4.2-*) ;;
    *) echo "Expected distribution PipeWire 1.4.2, found $package_version. Review compatibility first." >&2; exit 1 ;;
esac
apt-get install --no-install-recommends \
    "pipewire-bin=$package_version" \
    "libpipewire-0.3-modules=$package_version" \
    "libspa-0.2-modules=$package_version" alsa-utils python3
install -d -m 755 /usr/local/lib/syren-rtp/templates
install -m 755 "$source_directory/pi.py" /usr/local/lib/syren-rtp/pi.py
install -m 644 "$source_directory/templates/receiver.conf.in" /usr/local/lib/syren-rtp/templates/receiver.conf.in
echo 'Receiver installed. No service or routing has been enabled.'

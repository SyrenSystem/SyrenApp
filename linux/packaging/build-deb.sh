#!/bin/sh
set -eu

project_directory="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$project_directory"

machine_architecture="$(uname -m)"
case "$machine_architecture" in
  x86_64) bundle_architecture="x64" ;;
  aarch64) bundle_architecture="arm64" ;;
  *)
    printf 'Unsupported machine architecture: %s\n' "$machine_architecture" >&2
    exit 1
    ;;
esac

flutter build linux --release

version="$(sed -n 's/^version: \([^+]*\).*/\1/p' pubspec.yaml)"
architecture="$(dpkg --print-architecture)"
package_directory="$(mktemp -d)"
trap 'rm -rf "$package_directory"' EXIT
package_root="$package_directory/syren-app_${version}_${architecture}"
bundle_directory="build/linux/$bundle_architecture/release/bundle"
output_directory="$project_directory/build/debian"

install -d \
  "$package_root/DEBIAN" \
  "$package_root/opt/syren-app" \
  "$package_root/usr/bin" \
  "$package_root/usr/lib/syrensystem" \
  "$package_root/usr/lib/systemd/user" \
  "$package_root/usr/share/applications" \
  "$package_root/usr/share/icons/hicolor/512x512/apps"

cp -a "$bundle_directory/." "$package_root/opt/syren-app/"
find "$package_root" -type d -exec chmod 755 {} +
ln -s /opt/syren-app/syren_app "$package_root/usr/bin/syren-app"
install -m 755 linux/packaging/syren-audio-control "$package_root/usr/bin/syren-audio-control"
install -m 755 linux/packaging/syren-laptop-audio-sender "$package_root/usr/lib/syrensystem/syren-laptop-audio-sender"
install -m 644 linux/packaging/syren-laptop-audio.service "$package_root/usr/lib/systemd/user/syren-laptop-audio.service"
install -m 644 linux/packaging/com.syrensystem.app.desktop "$package_root/usr/share/applications/com.syrensystem.app.desktop"
install -m 644 assets/pics/icon.png "$package_root/usr/share/icons/hicolor/512x512/apps/com.syrensystem.app.png"

installed_size="$(du -sk "$package_root" | awk '{ print $1 }')"
cat > "$package_root/DEBIAN/control" <<CONTROL
Package: syren-app
Version: $version
Section: sound
Priority: optional
Architecture: $architecture
Installed-Size: $installed_size
Depends: libgtk-3-0t64, libserialport0, pipewire-pulse, pipewire-bin, pulseaudio-utils, netcat-openbsd | netcat-traditional
Maintainer: SyrenSystem
Description: Desktop control application for SyrenSystem
 Configure speakers, playback groups, source priority, and volume.
CONTROL

cat > "$package_root/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
POSTINST
chmod 755 "$package_root/DEBIAN/postinst"

mkdir -p "$output_directory"
dpkg-deb --root-owner-group --build "$package_root" "$output_directory/syren-app_${version}_${architecture}.deb"
printf '%s\n' "$output_directory/syren-app_${version}_${architecture}.deb"

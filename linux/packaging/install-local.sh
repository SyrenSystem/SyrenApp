#!/bin/sh
set -eu

project_directory="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
local_root="${XDG_DATA_HOME:-$HOME/.local/share}"
local_binary_directory="$HOME/.local/bin"
local_library_directory="$HOME/.local/lib/syrensystem"
application_directory="$HOME/.local/opt/syren-app"
user_service_directory="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

machine_architecture="$(uname -m)"
case "$machine_architecture" in
  x86_64) bundle_architecture="x64" ;;
  aarch64) bundle_architecture="arm64" ;;
  *)
    printf 'Unsupported machine architecture: %s\n' "$machine_architecture" >&2
    exit 1
    ;;
esac
bundle_directory="build/linux/$bundle_architecture/release/bundle"

cd "$project_directory"
flutter build linux --release

mkdir -p \
  "$local_binary_directory" \
  "$local_library_directory" \
  "$application_directory" \
  "$local_root/applications" \
  "$local_root/icons/hicolor/512x512/apps" \
  "$user_service_directory"

cp -a "$bundle_directory/." "$application_directory/"
ln -sfn "$application_directory/syren_app" "$local_binary_directory/syren-app"
install -m 755 linux/packaging/syren-audio-control "$local_binary_directory/syren-audio-control"
install -m 755 linux/packaging/syren-laptop-audio-sender "$local_library_directory/syren-laptop-audio-sender"
escaped_binary_directory="$(printf '%s' "$local_binary_directory" | sed 's/[&|\\]/\\&/g')"
sed \
  "s|^Exec=syren-app$|Exec=$escaped_binary_directory/syren-app|" \
  linux/packaging/com.syrensystem.app.desktop \
  > "$local_root/applications/com.syrensystem.app.desktop"
chmod 644 "$local_root/applications/com.syrensystem.app.desktop"
install -m 644 assets/pics/icon.png "$local_root/icons/hicolor/512x512/apps/com.syrensystem.app.png"
escaped_library_directory="$(printf '%s' "$local_library_directory" | sed 's/[&|\\]/\\&/g')"
sed \
  "s|ExecStart=/usr/lib/syrensystem/syren-laptop-audio-sender|ExecStart=$escaped_library_directory/syren-laptop-audio-sender|" \
  linux/packaging/syren-laptop-audio.service \
  > "$user_service_directory/syren-laptop-audio.service"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q "$local_root/applications" || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f "$local_root/icons/hicolor" || true
fi
systemctl --user daemon-reload

missing_audio_commands=""
for required_command in pactl pw-record nc; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    missing_audio_commands="$missing_audio_commands $required_command"
  fi
done
if [ -n "$missing_audio_commands" ]; then
  printf 'Laptop audio needs these missing commands:%s\n' "$missing_audio_commands" >&2
  printf '%s\n' 'Install them with: sudo apt install pulseaudio-utils pipewire-bin netcat-openbsd' >&2
fi
printf '%s\n' "Installed SyrenSystem for $USER"

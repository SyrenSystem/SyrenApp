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

maintenance_marker="${XDG_STATE_HOME:-$HOME/.local/state}/syrensystem/rtp/disabled"
# A marker left by an earlier cutover keeps the old laptop sender off, so only a marker made by this drain is removed.
marker_existed=no
[ -f "$maintenance_marker" ] && marker_existed=yes
if [ -f "$local_library_directory/rtp/laptop.py" ]; then
  python3 "$local_library_directory/rtp/laptop.py" '{"version":1,"action":"drain"}'
fi

mkdir -p \
  "$(dirname "$application_directory")" \
  "$local_binary_directory" \
  "$local_library_directory" \
  "$local_root/applications" \
  "$local_root/icons/hicolor/512x512/apps" \
  "$user_service_directory"

# A running app keeps its open files, so the new bundle is swapped in instead of copied over them.
rm -rf "$application_directory.new" "$application_directory.old"
cp -a "$bundle_directory" "$application_directory.new"
if [ -d "$application_directory" ]; then
  mv "$application_directory" "$application_directory.old"
fi
mv "$application_directory.new" "$application_directory"
rm -rf "$application_directory.old"
ln -sfn "$application_directory/syren_app" "$local_binary_directory/syren-app"
install -m 755 linux/packaging/syren-audio-control "$local_binary_directory/syren-audio-control"
install -m 755 linux/packaging/syren-laptop-audio-sender "$local_library_directory/syren-laptop-audio-sender"
install -d "$local_library_directory/rtp/templates"
for module in common compatibility pairing routing laptop; do
  install -m 644 "linux/audio/$module.py" "$local_library_directory/rtp/$module.py"
done
install -m 644 linux/audio/compatibility.json "$local_library_directory/rtp/compatibility.json"
install -m 644 linux/audio/templates/sender.conf.in "$local_library_directory/rtp/templates/sender.conf.in"
if [ "$marker_existed" = no ]; then
  rm -f "$maintenance_marker"
fi
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
for required_command in pactl parec pw-record nc; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    missing_audio_commands="$missing_audio_commands $required_command"
  fi
done
if [ -n "$missing_audio_commands" ]; then
  printf 'Laptop audio needs these missing commands:%s\n' "$missing_audio_commands" >&2
  printf '%s\n' 'Install them with: sudo apt install pulseaudio-utils pipewire-bin netcat-openbsd' >&2
fi
printf '%s\n' "Installed SyrenSystem for $USER"

# Real time priority is always the last step, so PC audio never runs without it.
if [ "$(systemctl show "user@$(id -u).service" -p LimitRTPRIO --value)" -lt 95 ]; then
  printf '%s\n' 'Allowing real time audio priority for this user; sudo asks for your password.'
  sudo mkdir -p "/etc/systemd/system/user@$(id -u).service.d" || true
  sudo tee "/etc/systemd/system/user@$(id -u).service.d/syrensystem-realtime.conf" >/dev/null <<'LIMITS' || true
[Service]
# PipeWire takes 88 for its audio threads and SyrenSystem audio runs just below it.
LimitRTPRIO=95
LimitNICE=40
LIMITS
  sudo systemctl daemon-reload || true
  printf '%s\n' 'Log out and in again, or reboot, before enabling PC audio so it runs at real time priority.' >&2
fi
printf 'Real time priority limit for this login: %s\n' "$(systemctl show "user@$(id -u).service" -p LimitRTPRIO --value)"

#!/bin/sh
set -eu

application_directory="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
audio_runtime="$(mktemp -d)"
export XDG_RUNTIME_DIR="$audio_runtime"
export PIPEWIRE_RUNTIME_DIR="$audio_runtime"
unset PULSE_RUNTIME_PATH
export PULSE_SERVER="unix:$audio_runtime/pulse/native"
audio_pipewire_pid=
audio_pulse_pid=
cleanup() {
    if [ -n "$audio_pulse_pid" ]; then kill "$audio_pulse_pid" 2>/dev/null || true; fi
    if [ -n "$audio_pipewire_pid" ]; then kill "$audio_pipewire_pid" 2>/dev/null || true; fi
    wait || true
    rm -rf "$audio_runtime"
}
trap cleanup EXIT HUP INT TERM
python3 - "$audio_runtime/pipewire.conf" <<'PY'
from pathlib import Path
import sys
configuration = Path('/usr/share/pipewire/pipewire.conf').read_text()
configuration = configuration.replace('context.objects = [',
    'context.objects = [\n    { factory = metadata args = { metadata.name = default } }', 1)
Path(sys.argv[1]).write_text(configuration)
PY
pipewire -c "$audio_runtime/pipewire.conf" > "$audio_runtime/pipewire.log" 2>&1 &
audio_pipewire_pid=$!
pipewire-pulse > "$audio_runtime/pulse.log" 2>&1 &
audio_pulse_pid=$!
audio_attempt=0
until pactl info >/dev/null 2>&1; do
    audio_attempt=$((audio_attempt + 1))
    if [ "$audio_attempt" -ge 100 ]; then
        cat "$audio_runtime/pipewire.log" "$audio_runtime/pulse.log"
        exit 1
    fi
    sleep .05
done
pactl load-module module-null-sink sink_name=syren_gate_default >/dev/null
pactl set-default-sink syren_gate_default
python3 "$application_directory/scripts/audio_gate.py" --scope signal

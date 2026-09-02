#!/bin/sh
set -eu

test_directory="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
audio_control="$test_directory/../syren-audio-control"
temp_directory="$(mktemp -d)"
trap 'rm -rf "$temp_directory"' EXIT

fake_bin="$temp_directory/bin"
mkdir -p "$fake_bin"
{
  printf '#!/bin/sh\nfake_root=%s\n' "'$temp_directory'"
  cat <<'FAKE'
printf '%s\n' "$*" >> "$fake_root/pactl.log"
command_name="${1:-}"
shift
case "$command_name" in
  get-default-sink)
    cat "$fake_root/FAKE_DEFAULT_SINK"
    ;;
  list)
    case "${2:-}" in
      sinks)
        awk '{ print NR "\t" $1 "\tmodule-alsa-card.c\ts16le 2ch 48000Hz\tRUNNING" }' "$fake_root/FAKE_SINKS"
        ;;
      sink-inputs)
        awk '{ print $1 "\t1\t5\tprotocol-native.c\ts16le 2ch 48000Hz" }' "$fake_root/FAKE_SINK_INPUTS"
        ;;
      *)
        printf 'fake pactl: unsupported list %s\n' "${2:-}" >&2
        exit 1
        ;;
    esac
    ;;
  set-default-sink)
    printf '%s\n' "$1" > "$fake_root/FAKE_DEFAULT_SINK"
    ;;
  move-sink-input)
    if [ "${FAKE_MOVE_FAIL:-0}" = 1 ]; then
      printf 'Failure: No such entity\n' >&2
      exit 1
    fi
    if [ -n "${FAKE_STATE_FILE:-}" ]; then
      if [ "$(sed -n '1p' "$FAKE_STATE_FILE" 2>/dev/null)" = enabled ]; then
        printf 'move after state\n' >> "$fake_root/order.log"
      else
        printf 'move before state\n' >> "$fake_root/order.log"
      fi
    fi
    ;;
  load-module)
    for module_argument in "$@"; do
      case "$module_argument" in
        sink_name=*) printf '%s\n' "${module_argument#sink_name=}" >> "$fake_root/FAKE_SINKS" ;;
      esac
    done
    printf '536870913\n'
    ;;
  *)
    printf 'fake pactl: unsupported command %s\n' "$command_name" >&2
    exit 1
    ;;
esac
FAKE
} > "$fake_bin/pactl"
chmod 755 "$fake_bin/pactl"

PATH="$fake_bin:$PATH"
export PATH
XDG_CONFIG_HOME="$temp_directory/config"
export XDG_CONFIG_HOME
state_file="$XDG_CONFIG_HOME/syrensystem/laptop-audio-state"
stderr_log="$temp_directory/stderr.log"

passes=0
failures=0
case_name=""
control_status=0

write_lines() {
  output_file="$1"
  shift
  : > "$output_file"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$output_file"
  done
}

start_case() {
  case_name="$1"
  : > "$temp_directory/pactl.log"
  : > "$stderr_log"
  rm -f "$state_file"
  rm -f "$temp_directory/order.log"
  unset FAKE_MOVE_FAIL
  unset FAKE_STATE_FILE
}

set_default_sink() {
  printf '%s\n' "$1" > "$temp_directory/FAKE_DEFAULT_SINK"
}

set_sinks() {
  write_lines "$temp_directory/FAKE_SINKS" "$@"
}

set_sink_inputs() {
  write_lines "$temp_directory/FAKE_SINK_INPUTS" "$@"
}

write_state_file() {
  mkdir -p "$(dirname "$state_file")"
  printf '%s\n%s\n' "$1" "$2" > "$state_file"
}

run_control() {
  control_status=0
  control_output="$("$audio_control" "$@" 2>>"$stderr_log")" || control_status=$?
}

assert_equal() {
  description="$1"
  expected="$2"
  actual="$3"
  if [ "$expected" = "$actual" ]; then
    passes=$((passes + 1))
  else
    failures=$((failures + 1))
    printf 'FAIL [%s] %s\n  expected: %s\n  actual:   %s\n' "$case_name" "$description" "$expected" "$actual" >&2
  fi
}

changing_calls() {
  grep -E '^(set-default-sink|move-sink-input|load-module) ' "$temp_directory/pactl.log" || true
}

assert_changing_calls() {
  assert_equal "pactl calls that change state" "$1" "$(changing_calls)"
}

assert_exit_status() {
  assert_equal "exit status" "$1" "$control_status"
}

assert_state() {
  if [ -f "$state_file" ]; then
    assert_equal "state line 1" "$1" "$(sed -n '1p' "$state_file")"
    assert_equal "state line 2" "$2" "$(sed -n '2p' "$state_file")"
  else
    assert_equal "state file" "$1 / $2" "missing"
  fi
}

assert_state_absent() {
  if [ -f "$state_file" ]; then
    assert_equal "state file" "absent" "$(tr '\n' ' ' < "$state_file")"
  else
    passes=$((passes + 1))
  fi
}

start_case "apply with no state file changes nothing"
set_default_sink alsa_output
set_sinks alsa_output SyrenSystem
set_sink_inputs 7 9
run_control apply
assert_exit_status 0
assert_changing_calls ""
assert_state_absent

start_case "apply with disabled state changes nothing"
set_default_sink alsa_output
set_sinks alsa_output SyrenSystem
set_sink_inputs 7 9
write_state_file disabled alsa_output
run_control apply
assert_exit_status 0
assert_changing_calls ""
assert_state disabled alsa_output

start_case "apply with enabled state sets the default and moves streams"
set_default_sink alsa_output
set_sinks alsa_output SyrenSystem
set_sink_inputs 7 9
write_state_file enabled alsa_output
run_control apply
assert_exit_status 0
assert_changing_calls "set-default-sink SyrenSystem
move-sink-input 7 SyrenSystem
move-sink-input 9 SyrenSystem"
assert_state enabled alsa_output

start_case "enable writes enabled state even when a move fails"
set_default_sink alsa_output
set_sinks alsa_output SyrenSystem
set_sink_inputs 7
FAKE_MOVE_FAIL=1
export FAKE_MOVE_FAIL
run_control enable
assert_exit_status 0
assert_changing_calls "set-default-sink SyrenSystem
move-sink-input 7 SyrenSystem"
assert_state enabled alsa_output
assert_equal "move failure is reported" "Could not move stream 7" "$(grep 'Could not move stream' "$stderr_log" || true)"

start_case "enable writes the state file before moving streams"
set_default_sink alsa_output
set_sinks alsa_output SyrenSystem
set_sink_inputs 7 9
FAKE_STATE_FILE="$state_file"
export FAKE_STATE_FILE
run_control enable
assert_exit_status 0
assert_equal "move order" "move after state move after state" "$(tr '\n' ' ' < "$temp_directory/order.log" | sed 's/ $//')"
assert_state enabled alsa_output

start_case "enable keeps the previous sink when SyrenSystem is already the default"
set_default_sink SyrenSystem
set_sinks alsa_output SyrenSystem
set_sink_inputs
write_state_file enabled alsa_output
run_control enable
assert_exit_status 0
assert_changing_calls "set-default-sink SyrenSystem"
assert_state enabled alsa_output

start_case "disable leaves an unrelated default untouched"
set_default_sink hdmi_output
set_sinks alsa_output hdmi_output SyrenSystem
set_sink_inputs 7
write_state_file enabled alsa_output
run_control disable
assert_exit_status 0
assert_changing_calls ""
assert_state disabled alsa_output

start_case "disable restores the previous sink when SyrenSystem is the default"
set_default_sink SyrenSystem
set_sinks alsa_output SyrenSystem
set_sink_inputs 7 9
write_state_file enabled alsa_output
run_control disable
assert_exit_status 0
assert_changing_calls "set-default-sink alsa_output
move-sink-input 7 alsa_output
move-sink-input 9 alsa_output"
assert_state disabled alsa_output

start_case "disable falls back to the first physical sink when the previous one is gone"
set_default_sink SyrenSystem
set_sinks alsa_output SyrenSystem
set_sink_inputs 7
write_state_file enabled usb_output
run_control disable
assert_exit_status 0
assert_changing_calls "set-default-sink alsa_output
move-sink-input 7 alsa_output"
assert_state disabled usb_output

start_case "ensure-sink loads the module only when the sink is missing"
set_default_sink alsa_output
set_sinks alsa_output
set_sink_inputs
run_control ensure-sink
assert_exit_status 0
assert_equal "first ensure-sink output" created "$control_output"
run_control ensure-sink
assert_exit_status 0
assert_equal "second ensure-sink output" present "$control_output"
assert_changing_calls "load-module module-null-sink sink_name=SyrenSystem sink_properties=device.description=SyrenSystem"
assert_equal "sink list after ensure-sink" "alsa_output SyrenSystem" "$(tr '\n' ' ' < "$temp_directory/FAKE_SINKS" | sed 's/ $//')"
assert_state_absent

printf '%s assertions passed, %s failed\n' "$passes" "$failures"
if [ "$failures" -ne 0 ]; then
  exit 1
fi

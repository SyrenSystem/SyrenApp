# Local audio protocol version 1

`syren-audio-control rtp '<JSON object>'` reads a versioned request and writes one JSON object. All requests carry integer `version: 1` and an `action`. A failure has an `error` string and a nonzero CLI exit code. Status may also include an error while reporting the current state. A major mismatch rejects startup before route changes; during ownership it mutes and tears down. `stop`, `close` and `status` remain minimal stable operations across supported upgrades.

| Action | Fields | Result |
| --- | --- | --- |
| `status` | none | Current receiver state and persisted preferences |
| `preflight` | none | `ready`, separate compatibility, module, device and protocol checks, actionable errors |
| `pair-discover` | `snapclient_id`, `name` | Resolved hostname and suggested local login, or saved details for the same receiver; no login, key pinning or preference changes |
| `pair-probe` | `snapclient_id`, `name`, `host`, `user`, `port`, optional `key` | Fingerprint, five minute verification challenge and changed key indication |
| `pair` | `challenge`, `verified_fingerprint`, explicit `repair_changed_key` when needed | Persisted pairing, without enabling playback |
| `opt-in` | boolean `enabled` | Persisted opt in preference |
| `start` | `app_pid` | Asynchronous muted startup status, including the session identity before background preparation begins |
| `app-heartbeat` | `app_pid` | Extends only the current app's three second heartbeat |
| `mute` | none | Priority receiver mute/readback, generation invalidation |
| `unmute` | `session`, `generation` | Explicit unmute only from current confirmed ready state |
| `standby` | `session`, `generation`, optional boolean `muted` | Select Snapcast while RTP keeps advancing; invalidate older source requests |
| `volume` | `session`, `generation`, integer `percent` | Confirmed gain, increases limited to 10 points |
| `stop` | none | Asynchronous restoration |
| `close` | `app_pid` | Stop only if this native app owns the session |
| `recover` | optional explicit `confirm_snapclient_restore` | Retry journals; the confirmation resolves ambiguous previous Snapcast services only after operator inspection |
| `diagnostics` | none | Cached receiver diagnostics and bounded desktop routing/gain inspection |
| `drain` | none | Disable new starts, synchronously restore and exit, used by package hooks |

The local controller socket lives at `$XDG_RUNTIME_DIR/syren-rtp-controller/control.sock`, mode 0600, and verifies same user Unix credentials. A daemon launched to answer status does not start playback. The parent app sends one heartbeat each second and native GTK delete and shutdown callbacks signal `close`.

The SSH receiver entry point is `/usr/lib/syren-rtp/receiver.py request --payload '<JSON>'`. It connects to the socket activated root broker. Receiver startup additionally requires the paired `snapclient_id`, a random 32 digit hex `session`, pinned `sender_address` and target `latency`. Subsequent mutations require the owning Unix user and session. A persistent `channel` accepts only authenticated session `heartbeat`; its EOF sends `disconnect`. A separate persistent `priority` channel accepts only `mute`. Diagnostics, gain and lifecycle requests cannot occupy that channel.

The broker forwards operations to the unprivileged worker, using a separate priority mute socket. The worker's 50 ms monitor does not perform health inspection commands. The audio account may only report `worker-failed` to the broker, which kills the fixed audio cgroup and starts restoration. It cannot use general broker operations. Root and the installation selected control group can use the bounded fixed control interface; session ownership still applies.

State and mute are not optimistic client values. `muted: null` means no confirmed readback, even if `worker_terminated: true` establishes that the owned audio process has exited. `generation` changes on mute and recovery. The app ignores older generations and never replays a queued unmute after recovery.

The speaker switch combines opt in, start and the first unmute into one explicit user gesture. The app binds that gesture to the returned session and generation 1, and discards it on mute, stop, recovery, session change, app disposal or a 60 second deadline. Recovery polls never replay that gesture. An enabled switch retains an app lifetime intent for normal group priority handoffs, using the existing source order. Normal source changes use the current healthy shared session. Standby increments the generation and reports `selected_source: snapcast`; unmute selects RTP only with current ownership, confirmed gain and stable reception. Recovery keeps the app lifetime intent; once the rebuilt receiver reports `readyMuted`, the app confirms volume again and unmutes or selects standby by priority. Restart never restores that intent. The `shared_output` capability is required before startup. Status includes `output_muted` for the selected branch separately from RTP `muted`. Before that first unmute, the app confirms the saved group volume multiplied by the speaker level. A configured group mute suppresses unmute. A gain failure drops the intent. An interrupted startup never replays its unmute; the recovered receiver is unmuted only after a fresh confirmed ramp. The backend still accepts unmute only with current session and generation ownership.

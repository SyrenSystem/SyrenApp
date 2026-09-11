# Opt in laptop RTP audio

The speaker card presents one **Low-latency laptop audio** switch, labelled experimental. Validation remains incomplete. Snapcast remains the default. This implementation handles one laptop, one paired Snapclient identity and one receiver. It does not implement synchronized RTP groups, multiple receivers, or a server protocol change. Passing software tests does not establish movie lip sync or release acceptance.

## Install and pair

Build the laptop and receiver packages from `SyrenApp`:

```sh
sh linux/packaging/build-deb.sh
sh linux/audio/packaging/build-receiver-deb.sh
```

The results are in `build/debian`. The laptop package includes the Flutter app, Snapcast sender and Python RTP controller. The architecture independent receiver package contains the broker, unprivileged audio worker, ingress filter and systemd units. Measurement programs and recordings stay in `linux/experiments/rtp` and are not packaged. `linux/packaging/install-local.sh` also installs the laptop helpers and drains any previous session first.

Install the receiver package in a visible receiver terminal with interactive sudo. No password is collected or stored by the app. Select the receiver interface address, discovered Snapclient ID, SSH user and control group during configuration:

```sh
sudo apt install ./syren-rtp-receiver_1.2.0_all.deb
sudo syren-rtp-configure --address 192.168.1.50 --snapclient-id RECEIVER_ID --control-user LISTENER --control-group syren-audio
```

Substitute the receiver's IPv4 address, discovered identity and existing SSH user. The supplied device configuration targets `hw:sndrpihifiberry,0`. Its fixed ALSA parameter path is `/proc/asound/sndrpihifiberry/pcm0p/sub0/hw_params`. Configuration is root owned at `/etc/syrensystem/receiver.json`. Use a new SSH login after group membership changes. Installation enables the control socket only; it never starts RTP audio. Do not enable `syren-rtp-audio.service` at boot.

In Speakers, use **Low-latency laptop audio** on a speaker already added through **+ Speaker**. A saved connection is reused immediately. Only the first connection opens setup for that selected speaker; it does not ask the user to add the speaker again. The app resolves the discovered Snapclient hostname through local DNS or mDNS and fills in the SSH host. It suggests the laptop login name as the SSH user; edit that if the receiver uses another account. Discovery does not verify an SSH account or grant access. If name resolution is unavailable, enter the receiver address manually. Saved connection details are reused only for the same receiver identity. Port and optional absolute private key path are under **Advanced SSH settings**. Leaving the key empty uses the existing SSH agent. The host must resolve to the selected receiver interface address. Pairing retains the discovered name and ID while Snapclient is stopped and releases ALSA.

Compare the displayed SHA256 fingerprint against a trusted receiver terminal:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
```

Only pin the key after that comparison. The scan itself is unauthenticated. Pairing writes an app specific `known_hosts` under `$XDG_CONFIG_HOME/syrensystem/rtp` (default `~/.config/syrensystem/rtp`). Changed keys block routine operation and require explicit re-pairing and verification. Routine SSH uses strict checking, batch mode, a pinned address, no connection sharing, bounded deadlines and no hidden prompts. Unlock a selected key or agent in a terminal if credentials are unavailable. No SSH password or sudo password is accepted by the JSON interface.

## Operation

Turn on **Low-latency laptop audio**. The app handles preflight and muted startup internally, then unmutes the initial ready generation for that explicit switch gesture. Later unmutes come from the same switch intent after a recovery or a source handoff, each with a fresh confirmed volume ramp. Preflight checks endpoint identity, the control protocol, PipeWire compatibility, required modules, interface binding and device presence. Actual ALSA format and period negotiation are checked muted after Snapclient releases its device. Receiver startup precedes the laptop sender and desktop routing. A journal records every intended ownership or routing change before it is attempted.

The receiver uses 48 kHz stereo L16, payload type 127 and 2.5 ms packets (120 stereo frames, 492 bytes including the RTP header). The target is 20 ms, with 128 frame ALSA periods and three periods. If that negotiation fails, 256 frames is tried and reported. Both negotiated cases require S32_LE stereo at 48 kHz. The isolated receiver explicitly links FL and FR and retains adaptive resampling and RTP timestamps. The desktop sender leaves port management to WirePlumber and does not set `adapter.auto-port-config`.

The switch shows **Connecting...**, then **Playing laptop audio**. Turning it off cancels pending startup or stops playback and restores the previous output. New sessions are prepared at 10%, muted. Before unmuting, the app applies and confirms the saved group master volume multiplied by the speaker level, using steps of at most 10 percentage points. A muted group stays muted. Each session unmutes only after its first generation is ready. While the switch remains on in this app instance, normal group priority changes select between two connected inputs in one shared output graph. A recovery rebuilds the receiver muted at 10%. While the switch stays on, the app confirms the saved volume again and unmutes, or hands off to Spotify by priority. A pending startup gesture is discarded by recovery rather than replayed, and an explicit group mute outranks the automatic resume. Restarting the app never resumes playback on its own; saving the group editor with the mute off resumes a paused session. Increases are limited to one explicit step of at most 10 percentage points. Decreases are allowed immediately. Receiver gain and mute are accepted only after readback. Programme stream gains are preserved, and no hardware mixer command is issued. The prototype quiet clip's 80% calibration is never a programme default.

The app shows **Muting** immediately. If confirmation has not arrived after one second it shows **Mute unconfirmed** and disables unmute. A killed audio process proves silence but is not presented as a successful mute readback. Status and mute remain accessible while other operations are running, including when the Syren server is offline. The speaker shows its laptop connection without protocol IDs or a separate control panel. Existing group master volume, speaker volume and group mute controls target the active receiver. Group volume and speaker level remain separate saved settings in both transports. Explicit level changes apply their product to the RTP receiver, using confirmed gain steps; moving one slider does not change the other. Speaker level changes persist as the normal speaker trim. Group controls still affect their Snapcast members; this does not synchronize RTP with those members. The existing group source priority also chooses between RTP laptop playback and Snapcast sources. The app uses the existing server source activity reports and checks laptop output streams each second. A running, unmuted desktop stream counts as active; this is not an acoustic silence detector. When another source wins, the receiver mutes the RTP branch and selects the Snapcast branch. Both keep advancing through the same hardware output, so switching does not restart the sender, receiver, or Snapclient. Muted laptop packets are consumed and discarded rather than queued for later playback. When laptop audio wins again, current gain and reception are checked before selecting it. The switch shows **Connected · Following group priority** while Spotify has priority. When no source in the group priority is active and laptop audio is included, RTP stays selected and unmuted unless the group is muted. The switch continues to show **Playing laptop audio** between sounds. Short sounds and resumed playback do not wait for the desktop activity poll. Active sources still follow the saved priority order. It shows **Reconnected · Resuming** while a recovered receiver waits for its volume confirmation, **Paused · Snapcast selected** when laptop audio is held muted without an active intent, and **Muted** only when the selected output itself is muted. There are no additional buttons or source priority settings. Turning it off stops the shared session and restores the original Snapclient service. A recovery failure, closing the app, or restarting cancels automatic return. Server disconnection or an activity probe failure prevents new automatic decisions. Location based gain remains part of Snapcast playback. Connection failures appear in the switch status. The speaker card has no separate error panel, connection details, or recovery buttons. Turn the switch off and on to reconnect.

Closing the native window or quitting sends a controller stop request. Minimizing keeps the session alive. There is no tray mode. The controller checks app process identity and a three second app heartbeat deadline. The sender guardian reacts to controller pipe death. Restarting the app, logging in or upgrading does not resume RTP, even when the preference remains enabled.

## Recovery and ownership

The explicit receiver states are `idle`, `preparing`, `readyMuted`, `playing`, `recoveringMuted`, `stopping` and `recoveryPending`. Status includes session ID, recovery generation, confirmed gain and mute, ingress reception times, rejection counts, negotiation, graph health and errors. Only a current session and generation may unmute. Mute invalidates queued unmute requests.

The receiver monitor checks every 50 ms. After 250 ms without valid advancing RTP it closes the forwarding gate and requests mute. Mute has a further 250 ms implementation deadline. If control or readback cannot confirm mute, the owned PipeWire worker is terminated, then killed if needed; failure to confirm process termination escalates to the fixed audio systemd cgroup. These are implementation deadlines requiring validation on the receiver, not guaranteed real time performance.

An authenticated control heartbeat runs each second. Explicit control disconnect starts recovery immediately; three seconds without a heartbeat does the same even with healthy UDP. A separate 12 second lease ends ownership and restores Snapclient. The laptop attempts to reconnect its pinned control endpoint within that lease. Recovery never silently changes the pinned addresses or RTP tuple.

Recovery closes ingress, mutes, destroys the PipeWire graph and both forwarding and ingress sockets, and discards queued datagrams. It recreates a muted graph, reopens ingress and requires one second of advancing packets without a gap over 100 ms, healthy graph parameters and current control ownership. It then stays `readyMuted` until another explicit unmute. Sender restart, source tuple or timestamp identity change, lease expiry, protocol mismatch and failed graph recreation require teardown and a fresh start. A paused player normally leaves silent RTP running; an actual transmission pause follows the same loss rules.

Startup and each cleanup attempt are bounded at 60 seconds. Independent desktop restoration is attempted before contacting an unreachable receiver. Only matching stream serials and still owned destinations are restored. Later manual route changes are preserved. Ambiguous service ownership remains pending until the operator inspects service history and explicitly confirms restoration. **Try again** repeats cleanup; ambiguous ownership can be reconciled through the versioned recovery command with explicit confirmation after that inspection. New starts are blocked while a journal remains.

Laptop journals are under `$XDG_STATE_HOME/syrensystem/rtp` (default `~/.local/state/syrensystem/rtp`); receiver journals are root owned under `/var/lib/syren-rtp`. Receiver broker startup reconciles the durable journal before accepting a session. `BindsTo` stops the audio service when the broker exits, and broker `ExecStopPost` restores owned Snapclient state. The broker permits only fixed operations, verifies Unix peer credentials and uses the installation selected control group. It cannot execute arbitrary client supplied commands or manage arbitrary services.

Package preinstall and preremoval hooks disable new starts and invoke the old helper before replacing or removing it. Failed restoration aborts the package action and retains the old helper and recovery files. Interrupted actions can be retried after reconciliation. The laptop restoration marker starts the old Snapcast sender without applying routing again, and the unit scoped kill fallback remains available for senders that ignore termination. Package fixtures exercise muted and audible simulated sessions; hardware package failure exercises remain release work.

## Compatibility and security limitations

`compatibility.json` has three classes: `tested`, `untested` and `known incompatible`. PipeWire 1.4.2 starts as tested using the recorded prototype configuration evidence and transport regression tests. Unknown versions are reported as untested and blocked for enablement, not described as inherently incompatible. Add transport and configuration probe evidence and passing regression checks to the shipped matrix before marking another version tested. This classification is separate from module availability, control protocol, device presence and actual negotiation. A tested transport configuration is not a latency acceptance result.

The selected security model is a **trusted LAN restriction**. UDP programme audio is unencrypted and unauthenticated. A participant capable of source spoofing on that LAN may inject audio or force recovery. IP, port and SSRC filtering is not authentication.

The unprivileged ingress process binds only the installation selected address on UDP 46000. It accepts only the session pinned sender IPv4 address and fixed RTP header, payload and packet sizes. During a bounded startup window it latches the first valid source port and SSRC. Later tuple changes, stale or duplicate sequence values, and inconsistent advancing timestamps are rejected and counted. It never silently relearns during playback.

Accepted datagrams retain their bytes and timestamps and are forwarded on loopback. For PipeWire 1.4.2, the filter binds a loopback forwarding socket at `127.0.0.2` and the native connected receiver socket resolves to `127.0.0.1` on the same private ephemeral port. The smoke test checks that no wildcard native socket remains. This arrangement accounts for the native module's source port filtering; see the [PipeWire 1.4.2 receiver implementation](https://github.com/PipeWire/pipewire/blob/1.4.2/src/modules/module-rtp-source.c). Only ingress is exposed to the LAN.

## Diagnostics and validation

Diagnostics contain effective software gains, routing identities, reception and rejection counts, negotiated periods, graph health and recovery actions. Laptop diagnostics rotate at 1 MiB with three backups; receiver telemetry uses the same bound and PipeWire graph logs rotate at 10 MiB with three backups. Logs contain no credentials or captured programme audio. Graph directories are disposed when replaced. The JSON diagnostics action collects current desktop gains independently of the mute path.

Run software verification from `SyrenApp`:

```sh
python3 -m unittest discover -s linux/audio/tests -v
python3 -m unittest discover -s linux/experiments/rtp/tests -v
sh linux/packaging/tests/test-audio-control.sh
python3 linux/audio/tests/smoke_pipewire.py
python3 linux/audio/tests/smoke_desktop.py
flutter test
flutter analyze
systemd-analyze verify linux/audio/packaging/*.service linux/audio/packaging/*.socket
systemd-analyze --user verify linux/packaging/syren-laptop-audio.service
sh linux/packaging/build-deb.sh
sh linux/audio/packaging/build-receiver-deb.sh
```

The smoke tests use silent isolated output or a dedicated desktop sink and do not change the default playback route. The desktop test sends its synthetic signal only to a loopback test receiver.

The measurement recorder now requires an absent `--marker-file`. Its duration starts only after both screen and microphone readiness and an explicit operator marker. Create that file when starting the clip after readiness is printed. For example:

```sh
python3 linux/experiments/rtp/capture.py --output results/rtp20.mkv --path rtp20 --duration 600 --marker-file /tmp/syren-capture-start --distances 0.15 0.50
```

In a second terminal, after readiness and when starting the clip, run `touch /tmp/syren-capture-start`. Choose an absent marker for each recording. The sidecar records readiness, operator wall and monotonic times, and the marker's pipeline timestamp. Capture readiness and marker waiting are separately bounded to five minutes. Recorder exclusivity and bounded shutdown remain in place. Earlier recordings and historical prototype measurements are preserved; the ingress filter requires fresh measurements.

Release acceptance remains outstanding: median added delay at most 30 ms, p95 at most 50 ms, calibrated uncertainty, physical picture to sound measurements, no audible glitches or growing delay, ten minute 20/15/10 ms candidates with 30/40 ms fallback if needed, failure exercises, and two hours of live F1. No change of default transport or verified movie lip sync claim follows from software verification. See `VALIDATION.md` for the checks actually run for this implementation.

### Shared receiver output

Receiver package 1.1.0 runs an isolated PipeWire output with two software gain stages. The owned Snapclient uses a private Unix Pulse socket in the audio worker directory, under the same unprivileged account. The existing Snapclient ID and server endpoint are retained. The endpoint comes from root owned receiver configuration or the existing `/etc/default/snapclient`; `syren-rtp-configure --snapserver-host HOST --snapserver-port PORT` can set it explicitly. No system Pulse server, desktop session manager, or external audio socket is installed.

Only one source stage is audible at a time. Group mute silences both stages, while status distinguishes muted RTP from muted selected output. The hardware mixer is never changed. During normal source changes, the graph and RTP tuple remain intact. Recovery still discards and recreates the graph, invalidates old source requests, and requires explicit authorization before RTP resumes. Worker failure stops all its child processes and the journal restores the original Snapclient service. Package upgrades drain that same ownership before replacing the helper.

The laptop preflight requires the receiver `shared_output` capability, so an older receiver cannot silently fall back to disconnecting. Software verification includes `python3 linux/audio/tests/smoke_shared.py`, which uses synthetic tones, a virtual device, a real private Pulse frontend, and a simulated Snapclient source. It verifies independent source silence, discarded old RTP audio, and unchanged process identities. Physical source switching time and the shared path's added delay remain unmeasured.

### Startup correction in app 1.0.6 and receiver 1.1.1

Snapclient 0.31.0 rejects an explicit channel count in `--sampleformat`. The shared receiver now uses `48000:16:*`, preserving the source channel count. Its previous `48000:16:2` argument caused Snapclient to exit and the receiver to stop the whole session. Control status retains receiver errors and startup failures no longer display Connecting alongside an error.

Validation on the paired HiFiBerry: an 18 second muted startup exercise reached `readyMuted` in generation 1, retained healthy reception without control errors, then stopped and restored Snapclient. This verifies startup and restoration, not audible switching or physical latency. Python tests (63), Flutter tests (84), analysis, and both package builds passed.

### Prompt source handoff in app 1.0.7

The server listens to Snapserver's existing WebSocket `Stream.OnUpdate` notifications and immediately schedules reconciliation using the group's existing source priority. The five second poll remains as a fallback if the event connection fails. The app processes changes arriving during a handoff without waiting for its next timer.

Live validation on the paired HiFiBerry: Spotify Play selected Snapcast 792 ms after its source event; Pause returned to RTP after 772 ms. Both transitions retained the same RTP session without recovery or errors. These timings measure confirmed control status, not acoustic output. Server tests (75), Flutter tests (85), analysis, server image and Linux package builds passed.

### Snapclient port recreation in app 1.0.8 and receiver 1.1.2

Snapclient disconnects its Pulse stream after extended silence and creates new ports when playback resumes. A cached node ID previously caused the shared receiver to skip those new ports, leaving Spotify silent even though priority selected Snapcast. Receiver health checks now compare current output and input port links and recreate missing connections, including ports replaced on the same node.

Verification includes regression fixtures for recreated ports and individual missing links, the shared graph signal isolation smoke test, and real Spotify on the paired receiver. Transient peak metering found nonzero signal at both Snapclient output and the Snapcast gain monitor during a fresh shared session and after a seven second pause and resume in the same session. No programme audio was saved. This extends the previous handoff validation, which checked control status but did not verify signal at the output.

### Laptop scheduling correction

On the XPS under CPU pressure, the live sender data thread was running with the normal scheduler while the desktop audio thread used round robin priority 20. Giving the sender the same priority immediately stopped the rapid timing error growth, and the user confirmed clear playback. Receiver captures before and after contained approximately 17,863 versus 16 zero valued stereo frames over 8.02 seconds, with no clipping. These were different programme excerpts, so their waveform statistics alone do not establish causality; the thread inspection, error counter and user confirmation support the diagnosis.

The sender template explicitly requests `rt.prio = 20`, `nice.level = -11`, and `rtportal.enabled = false`, using RTKit on this Debian desktop. The installed template was updated without restarting playback. The transport smoke test checks actual scheduler policy and positive realtime priority on the sender's data threads, masking the kernel's reset on fork flag. No new application version is required for this local configuration correction.

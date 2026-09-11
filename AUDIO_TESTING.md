# Audio regression gate

Run from SyrenApp with SyrenServer alongside it:

```sh
python3 scripts/audio_gate.py
```

The command returns failure if any check fails or a prerequisite is missing. It saves individual logs, command durations, checkout revisions, working tree status, and an overall JSON report under `build/audio-gate/`. It runs sequentially so tests using native audio ports do not compete. The default includes the full Flutter suite and analysis, Python receiver and measurement suites, shell routing fixtures, the full server suite, and the real PipeWire signal check. The server runs through the installed .NET SDK or the .NET 10 SDK container if Podman is available.

For separate checkouts or CI:

```sh
python3 scripts/audio_gate.py --scope app
dbus-run-session -- sh scripts/isolated_audio_gate.sh
```

The second command creates a temporary PipeWire/Pulse session and virtual sink. It does not start WirePlumber, discover sound cards, change the desktop's default sink, connect to the production Snapserver, or contact Spotify. All temporary audio processes belong to this test. On an existing desktop, `python3 scripts/audio_gate.py --scope signal` can also run the private shared graph directly.

Prerequisites are Linux, Python 3, Flutter 3.44.3, libserialport, dpkg tooling, PipeWire and its Pulse server and command line tools, Pulse client tools, and .NET 10 or Podman. CI runs the signal check in Debian trixie with a private D-Bus session. Missing sound tools fail the gate instead of skipping it.

## Required behavior

The group's ordered source list selects the programme. Low latency changes the laptop transport only. When Spotify is first and playing, enabling low latency must not steal priority. When Spotify pauses or fails and laptop audio remains active, laptop playback should return through RTP if connected, otherwise through Snapcast. A muted group stays silent through all handoffs. When every source is idle and laptop audio is included in the group priority, enabled RTP stays selected between sounds. Pausing and resuming laptop audio must not issue a branch switch or wait for an activity poll in this state.

Normal priority and settings changes must preserve the receiver graph, sender session, and Snapcast connection. They must use current group master volume, speaker level, and laptop source level. Settings arriving during startup must be applied before the first unmute. Repeated unchanged configuration must not issue gain or transport commands. Stop and explicit mute invalidate pending starts and stale gain or unmute commands.

## Automated coverage

| Layer | Checks |
| --- | --- |
| Dart to production Python controls | `test/audio_handoff_contract_test.dart` starts `test/support/audio_receiver.py`, which runs the actual `Session`, `SharedAudioGraph`, software gain readback, and `PacketFilter`. Only device commands and packet delivery are simulated. |
| Priority matrix | Both source orders, single source lists, both activity states, mute and unmute, and one connected session across 32 combinations. The expected winner is computed independently of the application selector. |
| Setting sequences | 200 repeatable transitions with seed 904119 change source activity, order, mute, master, speaker, and source levels. Every step must converge in one refresh without graph teardown. |
| Races | Held gain responses allow mute, Spotify activation, a volume edit, and disable to land during startup or handoff. Assertions check receiver state, the commands sent, and the first audible gain. |
| Lifecycle | Twelve explicit enable/disable cycles require fresh sessions; recovery returns to the current priority winner with confirmed saved gain; moving a speaker between groups applies its new volume. |
| Existing app tests | Widget controls, delayed status, mute confirmation, stale generations, priority edits and removal, offline activity probes, heartbeat errors, cancellation, source balance, and queueing another coordinator refresh. |
| Receiver and routing | Packet identity, loss, deadlines, muted recovery, invalid control requests, graph link repair after port recreation, sender/guardian death, route restoration, ambiguous ownership, and package upgrades/removal. Package tests discover the built package rather than hard-coding an old version. |
| Server | Both ordered meta stream definitions, 100 activity changes per order, every changed runtime notification, duplicate suppression, 20 settings edits, and no unnecessary stream replacement or client reassignment. Existing event tests cover fragmented source notifications and ignoring volume events. |
| Real signal | `linux/audio/tests/smoke_shared.py` runs real PipeWire, Pulse, RTP sockets, and a virtual hardware sink with synthetic tones. It checks 24 source selections, source isolation, confirmed mute, fresh audio on return, advancing packets, and unchanged process identities. |

The real signal test fails when a branch control command takes 250 ms or more, a captured handoff contains 250 ms or more of continuous digital silence, the selected tone is missing, the other tone leaks, mute is audible, or a process is replaced. These are branch switching regression limits, not measurements of Spotify event delivery or physical acoustic latency. The test uses a simulated Snapclient frontend and cannot validate Spotify authentication or the real Snapclient implementation.

## CI and completion

Both workflows run on pushes, pull requests, merge queues, and manual dispatch, without path filters. App CI retains logs and JSON evidence even on failure. Use these exact required status checks in repository branch protection or rulesets:

- SyrenApp: `Audio regression gate (app)` and `Audio regression gate (signal)`.
- SyrenServer: `Audio regression gate (server)` and `Audio recovery build`.

The workflow files and repository AGENTS.md instructions establish the local and CI completion contract. Server-side branch protection has not been configured by these files; a repository maintainer must require the checks after the workflows are published. A green app-only check does not qualify an untested server revision.

Do not hide a regression with a retry, test exclusion, larger timeout, or mocked selection result. Fix the cause and retain the failing sequence. Re-run the gate after the final code change, and attach its report to the review.

## Physical acceptance still required

Software tests cannot certify audible continuity of the real laptop, network, Snapserver/librespot, Snapclient, and HiFiBerry. Before claiming those paths are fixed, capture the actual output and event timestamps for the following scenarios with the same revisions recorded in the software report:

1. With Spotify above laptop, play both sources, pause Spotify, then resume it. Repeat with laptop first and verify the selected programme and transport after every change.
2. Toggle low latency on and off while laptop audio plays, then while Spotify plays. Repeat at least 20 times. Record output silence and elapsed time from gesture to the correct audible programme. Require return within one second and no gap of 250 ms or more. These are acceptance targets, not results already established.
3. Change group master, speaker level, source balance, mute, source order, group membership, and manual/automatic volume mode while each programme plays. Include combined edits and rapid repeated changes. Unchanged saves must preserve playback.
4. Pause Spotify long enough for Snapclient to recreate its ports, then resume. Check actual sound on both channels, not just the selected-source status.
5. Interrupt RTP and control separately, then restore them. Confirm current priority and saved gain on return. Explicit disable or mute during the interruption must cancel stale playback intent.
6. Exercise an actual Spotify connection failure when reproducible. Recovery means the music resumes on SyrenSystem without reselection or pressing Play. Reauthentication, rediscovery, or a running process alone do not pass. A deliberate pause or device transfer must remain respected. Fault injection can test a recovery mechanism but does not reproduce an unexplained upstream failure.
7. Run the existing calibrated latency and long playback acceptance in `linux/audio/VALIDATION.md`, including a two hour session and CPU pressure.

The current enable/disable implementation tears down shared output and restores the original Snapclient service. Its software lifecycle checks do not prove the physical transition meets the above gap and timing targets. That remains a known validation gap, and may require a transport lifecycle change if measurement fails.

## Spotify incident on 2026-09-09

At 16:01:14 CEST, the running librespot 0.8.0 logged `Connection to server closed.` Audio key timeouts followed, then a Connect shutdown and a broken pipe. It reauthenticated around 16:01:19, reported an empty active device, and the Spotify stream later became idle. Snapserver remained running and the speaker stayed connected. No reliable reproduction or cause for the remote connection closing was established.

A proposed process supervisor was removed before deployment because restarting and reauthenticating did not establish that music would resume. Upstream [issue 1419](https://github.com/librespot-org/librespot/issues/1419) describes a similar failure sequence. On the user's subsequent request, [PR 1692](https://github.com/librespot-org/librespot/pull/1692), still unmerged upstream, was applied to current librespot development revision `a1b66d3c8a14e55a9572a9e17467150dca618c9a`. The patch preserves playback state across reconnects. All 26 upstream workspace tests passed. A real recurrence followed by automatic audible playback remains required to verify recovery from the observed incident.

The server's `Audio recovery build` also runs `deploy/snapserver/smoke_snapserver.py` against the native Snapserver binary. It checks 12 source activity transitions and 31 priority stream removals while synthetic PCM continues. This caught Snapserver 0.35.0 dereferencing a deleted iterator in `Stream.RemoveStream`, then calling a deleted meta stream when source activity changed. The image carries a source patch for both. These checks use private ports and do not contact Spotify or the production server. Version and patch checksums are recorded in the server's `deploy/snapserver/versions.json`.

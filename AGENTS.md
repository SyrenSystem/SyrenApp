# Audio completion gate

Before declaring any feature or fix complete, run `python3 scripts/audio_gate.py` with the sibling SyrenServer checkout present. This runs app analysis and tests, production receiver tests, routing and measurement tests, server tests, and the isolated shared output signal check. Missing prerequisites and failures block completion. Keep the logs and report under `build/audio-gate` and report any unfinished hardware acceptance separately.

For an isolated app checkout, `--scope app` and `--scope signal` are the CI equivalents. Both app checks and the server check must pass for changes spanning the system. Do not skip tests, relax timing limits, or replace production code with a mock to make this gate pass. Add a regression for every audio handoff bug before fixing it.

Read `AUDIO_TESTING.md` for the coverage and physical acceptance contract. Software checks do not qualify real Spotify playback, physical output continuity during transport enable or disable, or acoustic latency.

# SyrenApp

App for the SyrenSystem.

Before completing a feature or fix, run `python3 scripts/audio_gate.py`. See [the audio regression gate](AUDIO_TESTING.md) for coverage, CI checks, and physical acceptance requirements.

The SyrenApp allows the user to inspect sensor distances, configure logical speakers, create playback groups, order audio source priority, and control group and speaker volume. In the background, it reads SyrenSensor distances and propagates them to SyrenServer.

## Platform support

- Android supports USB serial measurements, MQTT, positioning, speaker setup, playback groups, and volume control.
- Linux supports serial measurements, MQTT, positioning, speaker setup, playback groups, volume control, and sending desktop audio to SyrenSystem.
- iOS supports MQTT, positioning, speaker connection, settings, and volume control. The current Silicon Labs sensor firmware exposes ordinary USB serial, which iOS cannot use through the app. Use Android or Linux to collect and publish measurements until the sensor provides a transport that iOS supports, such as Bluetooth Low Energy.

## Install on Debian

The Debian package (`linux/packaging/build-deb.sh`), the local install script, the laptop audio sender, and the stack user services are described in the SyrenDocs guide [Laptop audio and playback groups](https://github.com/SyrenSystem/SyrenDocs/blob/main/LaptopAudioAndPlaybackGroups.md).

Linux also offers an experimental **Low-latency laptop audio** switch on each configured speaker. Snapcast remains the default. See [RTP installation, pairing, operation and recovery](linux/audio/README.md), the [versioned control interface](linux/audio/PROTOCOL.md), and [software verification and outstanding release evidence](linux/audio/VALIDATION.md). Turning the switch on checks the connection and applies the saved group volume and speaker level before playback begins. A muted group stays muted. Existing speaker and group volume controls adjust the active receiver; the existing group mute control mutes it. While enabled, the existing group source priority switches between laptop audio and Spotify automatically while both remain connected to a shared receiver output. No additional controls are needed. After a connection recovery the receiver comes back muted, and the app confirms the saved volume again and resumes on its own while the switch stays on. Only a failed recovery needs the switch again. Closing the window restores prior owned playback state.

## Build for iOS

Building and signing the iOS 13 or newer app requires macOS with Xcode. From the project directory:

```sh
flutter pub get
flutter build ios --no-codesign
open ios/Runner.xcworkspace
```

In Xcode, select the Runner target, choose an Apple development team, and run the app on an iPhone. The first connection to the MQTT broker prompts for local network access.

### Source balance and installed version

Open a group's edit dialog and use **Source balance** to lower Spotify or Laptop Audio independently. Both start at 100%. The saved levels multiply the group master and speaker level, so the master remains the main volume control. This does not normalize individual desktop apps. Source balance follows the existing source priority, including the shared low latency receiver. Snapcast volume updates follow the server's source status reconciliation.

Settings displays the version from the installed Flutter bundle. Every change, including a bug fix or a small adjustment, gets its own minor version, so 1.1.0 is followed by 1.2.0. Build numbers are not used. Version 1.1.0 includes low latency laptop audio and source balance. Software tests cover volume composition, source selection, initial RTP gain, persistence, and version display; they do not establish physical switching latency or loudness normalization.

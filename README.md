# SyrenApp

App for the SyrenSystem.

The SyrenApp allows the user to inspect sensor distances, configure logical speakers, create playback groups, order audio source priority, and control group and speaker volume. In the background, it reads SyrenSensor distances and propagates them to SyrenServer.

## Platform support

- Android supports USB serial measurements, MQTT, positioning, speaker setup, playback groups, and volume control.
- Linux supports serial measurements, MQTT, positioning, speaker setup, playback groups, volume control, and sending desktop audio to SyrenSystem.
- iOS supports MQTT, positioning, speaker connection, settings, and volume control. The current Silicon Labs sensor firmware exposes ordinary USB serial, which iOS cannot use through the app. Use Android or Linux to collect and publish measurements until the sensor provides a transport that iOS supports, such as Bluetooth Low Energy.

## Install on Debian

The Debian package (`linux/packaging/build-deb.sh`), the local install script, the laptop audio sender, and the stack user services are described in the SyrenDocs guide [Laptop audio and playback groups](https://github.com/SyrenSystem/SyrenDocs/blob/main/LaptopAudioAndPlaybackGroups.md).

## Build for iOS

Building and signing the iOS 13 or newer app requires macOS with Xcode. From the project directory:

```sh
flutter pub get
flutter build ios --no-codesign
open ios/Runner.xcworkspace
```

In Xcode, select the Runner target, choose an Apple development team, and run the app on an iPhone. The first connection to the MQTT broker prompts for local network access.

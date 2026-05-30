# iOS Device Install Notes

For PocketWorld builds that the user will launch manually from the iPhone
SpringBoard, install a release/profile app, not a Flutter debug app.

Flutter debug builds on modern iOS must be launched while attached to
`flutter run` or Xcode. Installing a debug `Runner.app` with `devicectl` and
then opening it from the phone home screen can look like an instant crash.

Use:

```sh
flutter build ios --release -t lib/main.dart
xcrun devicectl device install app --device <UDID> build/ios/iphoneos/Runner.app
```

Use debug only when keeping the tool attached:

```sh
flutter run -d <UDID> -t lib/main.dart
```

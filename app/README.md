# VaultBridge app

The Flutter client for [VaultBridge](../README.md): edit and preview `shared.md`
on your phone, with Obsidian-style rendering, attachments, search and PDF export.

Runs on **iOS, Android and macOS**.

## Run it

```sh
flutter pub get
flutter run            # pick a device; on first launch enter the endpoint URL and API key
flutter test           # unit and widget tests
flutter analyze
```

You need a deployed backend first. See [Deploy the backend](../README.md#1-deploy-the-backend).

## Build a release

```sh
flutter build apk --release          # Android -> build/app/outputs/flutter-apk/app-release.apk
flutter build appbundle --release    # Android -> Play Store bundle
flutter build ios --release          # iOS (then archive/sign in Xcode)
flutter build macos --release        # macOS
```

The Android release build is signed with the debug key until you add your own
(see the [Flutter docs](https://docs.flutter.dev/deployment/android#sign-the-app)).
The application ID is `dev.vansh.vault_bridge` (Android) and `dev.vansh.vaultBridge` (iOS).
Change both before publishing under your own name.

## Layout

```
lib/
  data/       API clients, sync repository, attachments cache
  markdown/   the Obsidian renderer (callouts, wikilinks, math, mermaid, find-in-note)
  export/     PDF export of the preview
  ui/         screens and widgets
  theme/      colors, type and spacing tokens
test/         unit and widget tests
tool/         screenshot and icon generators (flutter test tool/capture_screens_test.dart)
```

## Screenshots

`CAPTURE_DIR=/tmp/shots flutter test tool/capture_screens_test.dart` renders every
screen in light and dark with demo data.

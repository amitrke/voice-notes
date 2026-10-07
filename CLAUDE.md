# Voice Notes: working notes

Flutter app (Android and iOS). Users bring their own API key (Sarvam, OpenAI or Gemini); notes are stored
locally. See README.md for the architecture and docs/RELEASING.md for the release pipeline.

## Branches and releases (same model as amitrke/relay-player)

- `main` is the default branch. It releases nothing on its own.
- `develop` is the test channel: **pushing to it ships a test build to Play internal testing and TestFlight.**
  Only push there when testers should get the build.
- Work on a feature branch, open a pull request, merge. Do not push work-in-progress to `develop`.
- A release is: merge `develop` into `main`, tag that commit `vX.Y.Z` (it must equal `pubspec.yaml`'s version),
  push the tag, then bump `pubspec.yaml` on `develop`.
- The build number is `github.run_number + 100`, shared by both stores. Never rename or recreate
  `.github/workflows/release.yml`: that restarts the run number, which the stores reject.
- Manual builds for sideloading: run the "Build" workflow (no secrets involved).

## Before pushing

```bash
flutter analyze
flutter test
```

CI pins Flutter 3.47.0 (`FLUTTER_VERSION` in the workflows). Change it in all three workflows together.

## Secrets

Never commit `android/key.properties`, `*.jks`, `.p8` files or API keys. The upload keystore lives in
`C:\Users\amitr\dev\keystores\voice-notes\`. CI gets keys only from GitHub secrets, and only `release.yml`.

## Identifiers

Android package and iOS bundle ID: `com.subnext.voicenotes` (permanent once published).
Apple team `BTSKP77HML`. App Store name "Basic Voice Notes"; Play name "Voice Notes".

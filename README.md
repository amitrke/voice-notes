# Voice Notes

A Flutter app (Android and iOS) that records or imports voice notes, transcribes them in the language
spoken, translates them to English, and gives each note a title and summary. You bring your own API
key; nothing goes through any server of ours.

## Providers

| Provider | Transcription | English | Language detection | Recording format |
|---|---|---|---|---|
| Sarvam | `saaras:v3` | `translate` mode | yes (`unknown` → detected) | 16 kHz mono WAV, split into 25 s chunks (sync API limit is ~30 s) |
| OpenAI | `whisper-1` | Whisper translations endpoint | yes | m4a (25 MB limit) |
| Google Gemini | `gemini-2.5-flash` | one prompt returns both | yes | m4a (about 14 MB inline limit) |

Model names are editable in Settings, so you do not need an app update when providers rename models.
Imported non-WAV files with Sarvam use its asynchronous batch job API (up to 2 hours of audio).

## Privacy

- API keys are stored with `flutter_secure_storage` (Android Keystore / iOS Keychain).
- Notes live in a local SQLite database; audio is kept in the app's documents folder.
- Audio is uploaded only to the provider you selected.

## Run

```bash
flutter pub get
flutter run            # on a connected Android device / emulator, or an iOS simulator
flutter test
```

Open Settings, pick a provider, paste its API key, then tap Record.

## Layout

- `lib/providers/` – `AiProvider` interface, Sarvam / OpenAI / Gemini implementations, WAV chunking
- `lib/data/` – SQLite notes, settings and key storage, `AppState` (processing and retry)
- `lib/ui/` – home list, record sheet, note detail, settings
- `sarvam_transcribe.ipynb` – the original Colab prototype

## Known gaps

- Verified so far: unit tests with mocked HTTP, `flutter analyze`, and an Android debug build. It has
  not been run against the real provider APIs or on a device or emulator.
- Sarvam batch job upload/download response shapes are only partly documented; the parser is
  deliberately tolerant and covered by tests against assumed shapes.
- iOS is configured (microphone permission) but has not been built.

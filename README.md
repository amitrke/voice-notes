# Voice Notes

A Flutter app (Android and iOS) that records or imports voice notes, transcribes them in the language
spoken, translates them to English, and gives each note a title and summary. You bring your own API
key; nothing goes through any server of ours.

## Providers

| Provider | Transcription | English | Language detection | Recording format |
|---|---|---|---|---|
| Sarvam | `saaras:v3` | `translate` mode | yes (`unknown` → detected) | 16 kHz mono WAV, split into 25 s chunks (sync API limit is ~30 s) |
| OpenAI | `whisper-1` | Whisper translations endpoint | yes | m4a (25 MB limit) |
| Google Gemini | `gemini-3.5-flash` | one prompt returns both | yes | m4a (about 14 MB inline limit) |
| On this device | Whisper base / small / turbo (sherpa-onnx, int8) | Whisper `translate` task (not turbo) | yes | 16 kHz mono WAV, split by voice detection |

Model names are editable in Settings, so you do not need an app update when providers rename models.
Imported non-WAV files with Sarvam are first decoded on the device to 16 kHz mono WAV (Android
`MediaCodec`, iOS `AVAudioConverter`) and then sent through the same chunked sync API as recordings. Sarvam's
batch job API returned empty transcripts for raw m4a, so it is only the fallback when decoding fails.

### Offline transcription

"On this device" runs Whisper through [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) in a background
isolate. Models are not bundled: Settings downloads one (Base ~160 MB, Small ~360 MB, Turbo ~1 GB) from
Hugging Face URLs pinned to a commit, plus Silero voice detection (~0.6 MB). Files go to the app support folder
(excluded from iCloud backup) as `.part`, resume with Range requests, and are checked against SHA-256 before
use (`lib/services/model_store.dart`).

Indian-language models sit beside the Whisper ones in the same list: Meta's Omnilingual ASR 300M (Apache-2.0, many
languages, ~365 MB) and AI4Bharat IndicConformer for Hindi (~198 MB), Tamil, Telugu and Malayalam (MIT, ~137 MB
each), one language each. They only transcribe: no language detection for Omnilingual, no English translation. The
IndicConformer files are community conversions for sherpa-onnx (`csndhanasekar/...`; Hindi from
`ngiftsun/indicconformer-hi-int8-sherpa`, CC-BY-4.0), not published by AI4Bharat. Omnilingual tends to write Hindi
speech in Urdu script, and its CTC model takes no language hint, so Hindi speakers should use the Hindi model. The
IndicConformer models have not been run on a device yet. Voice detection cuts recordings into pieces of at most 20 s (Whisper reads
30 s at a time); each piece is one timestamped line. It has no text model, so titles and summaries need a
separate enrichment provider.

Timestamped lines (on-device and OpenAI) drive the note screen's follow-along highlighting, tap-to-seek, and
SRT export.

### Dictionary, speakers, folders, find and replace

- **Custom dictionary** (Settings): terms are sent as a hint to OpenAI (`prompt`) and Gemini, and "sounds like"
  spellings are corrected in every new transcript with any provider (`lib/data/dictionary.dart`).
- **Identify speakers** (Settings): Gemini returns speaker turns with approximate times; "On this device" runs
  sherpa-onnx diarization (pyannote segmentation + a speaker embedding, about 30 MB, downloaded from Settings)
  and labels each line by overlap (`lib/providers/speaker_assign.dart`). Speakers can be renamed per note.
  Others (Sarvam, OpenAI) do not label speakers. Recordings over 45 minutes are not diarized on the device.
- **Folders**: one folder per note, filter chips on the home screen. Database version 5.
- **Tags** (Settings > Tags): many per note, separate from folders (`tags` and `note_tags` tables, database
  version 6, seeded with Grocery, To-do, Work, Health, Ideas). The summary prompt passes the approved tags and the
  model picks from them; tags outside the list are dropped. If none fit it may suggest one, which is stored
  unapproved and linked to the note but hidden until approved in Settings (rejecting deletes it). Editing a note's
  tags by hand sets `tags_edited`, after which regenerating leaves them alone. On-device has no text model, so
  tagging there is manual.
- **Find and replace** across notes (home screen), previewing the notes it will change.
- **Delete audio after transcribing** (Settings): keeps the text, removes the file.
- **Share to the app** (Android): audio and video shared from other apps become notes
  (`SharedAudio.kt`, `lib/services/share_intake.dart`). iOS has no share extension yet.

### Enrichment (titles, summaries, clinical notes)

Text work can use a different provider from transcription (Settings > Enrichment). OpenRouter is available
there as a text-only option (default model `openrouter/free`, which picks an available free model). It cannot
transcribe audio, so it is not offered as the transcription provider.

### Clinical mode

Settings > "I use this for" > Clinical work adds a "Create clinical note" button to each transcript: an
interpretation, a clinical note in English and the spoken language, and items to verify, with TXT export.
Output is an AI-generated draft and must be reviewed by a clinician.

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

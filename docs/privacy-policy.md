# Privacy Policy for Voice Notes

**Effective date:** [DATE]
**Developer:** [DEVELOPER NAME]
**Contact:** [CONTACT EMAIL]

Voice Notes ("the app") records or imports voice notes, turns them into text, translates them to English, and
summarises them. This policy explains what the app does with your data. In short: **we run no servers and
collect nothing about you. Your notes stay on your device, and your audio goes only to the AI provider you
choose, using your own API key.**

## What the app stores on your device

- **Voice notes:** the audio you record or import, stored in the app's private storage.
- **Transcripts, translations, titles and summaries** generated for each note, stored in a local database.
- **Your API keys and settings:** API keys are kept in the operating system's secure storage (Android Keystore
  or iOS Keychain). Other settings (selected provider, model names, toggles) are stored in the app's local
  preferences.

This data never leaves your device except as described in the next section. Deleting a note removes its
transcript and its audio file. Uninstalling the app removes everything it stored.

## What is sent to AI providers

The app has no account system and no backend. To transcribe a note, the app sends **the audio** (and, for titles
and summaries, **the transcript text**) directly from your device to the provider you selected in Settings,
authenticated with **your** API key:

| Provider | What is sent | Their privacy policy |
|---|---|---|
| Sarvam AI | audio for transcription and translation; transcript text for summaries | https://www.sarvam.ai |
| OpenAI | audio for transcription and translation; transcript text for summaries | https://openai.com/policies/privacy-policy |
| Google (Gemini API) | audio for transcription and translation; transcript text for summaries | https://policies.google.com/privacy |

Only the provider you have selected receives your data, and only when you record, import, retry or summarise a
note. Each provider handles that data under its own terms and privacy policy, and your account with them is
between you and them (including any charges for your usage). We do not receive a copy, and we cannot see your
API keys, audio or transcripts.

Please do not record anything you are not comfortable sending to the provider you select.

## What we do not do

- We do not collect, store, sell or share your personal information.
- We do not use analytics, advertising or tracking SDKs.
- We do not require you to create an account.
- We do not access your contacts, location, photos or other files. The app asks for **microphone** access to
  record, and reads only the audio files you choose to import.

## Permissions

- **Microphone:** used only while you are recording a note.
- **Internet:** used only to send requests to the provider you selected.

## Children

The app is not directed at children under 13 and we do not knowingly collect information from anyone.

## Security

API keys are held in platform secure storage and are sent only to the provider they belong to, over HTTPS.
Notes are stored in the app's private storage and are protected by your device's own security (screen lock,
device encryption). If your device is shared or compromised, so are the notes on it.

## Your choices

You can delete any note in the app, remove or replace your API keys in Settings, or uninstall the app to erase all
local data. To delete data held by an AI provider, contact that provider.

## Changes to this policy

If this policy changes, we will update the effective date above and publish the new version at the same address.

## Contact

Questions about this policy: [CONTACT EMAIL]

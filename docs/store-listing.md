# Store listing drafts

Character limits are noted per field and every field is within its limit.

---

## Google Play ("Voice Notes")

**App name (30):** Voice Notes

**Short description (80):**
Record voice notes in any language. Get text, English translation and a summary.

**Full description (4000):**

Speak, and Voice Notes does the rest. Record a note or import an audio file, and the app turns it into text in the language you spoke, an English translation, and a short title and summary, all saved in a searchable notes library.

BRING YOUR OWN AI KEY
Voice Notes does not run its own servers and has no subscription. You add an API key from the AI provider you prefer, and the app talks to that provider directly from your phone. You pay the provider for what you use, at their rates. Choose between:
• Sarvam, built for Indian languages
• OpenAI
• Google Gemini
You can switch provider at any time in Settings.

WHAT YOU GET
• Record in the app, or import m4a, mp3, wav and other audio files
• Automatic transcript in the language that was spoken
• Optional English translation shown next to the original
• Automatic title and summary for every note
• Search across all your notes
• Play the original audio back from each note
• Copy any transcript or translation
• Retry a transcription if your connection drops. Your recording is saved first, so nothing is lost

PRIVATE BY DESIGN
• Notes and audio are stored on your device only
• Your API key is kept in your phone's secure storage
• No account, no ads, no analytics, no tracking
• Audio is sent only to the provider you choose, and only when you transcribe a note

GOOD TO KNOW
• An API key and an internet connection are needed to transcribe
• Language support and accuracy depend on the provider and model you pick
• Provider usage may be billed by that provider

Voice Notes is a simple, no-frills tool for turning speech into searchable text, in the language you actually speak.

**Category:** Productivity (alternative: Tools)

**Tags / keywords to consider:** voice notes, transcription, speech to text, translate, Hindi, multilingual

---

## Apple App Store ("Basic Voice Notes")

**Name (30):** Basic Voice Notes

**Subtitle (30):** Speech to text, any language

**Promotional text (170):**
Record or import audio and get a transcript, an English translation and a summary. Use your own Sarvam, OpenAI or Gemini key. Your notes stay on your device.

**Keywords (100, comma-separated, no spaces):**
voice,notes,transcribe,speech,text,translate,Hindi,dictation,recorder,audio,summary,multilingual

**Description (4000):**

Speak, and Basic Voice Notes does the rest. Record a note or import an audio file, and the app turns it into text in the language you spoke, an English translation, and a short title and summary, all saved in a searchable notes library.

BRING YOUR OWN AI KEY
Basic Voice Notes has no servers and no subscription. You add an API key from the AI provider you prefer, and the app talks to that provider directly from your iPhone. You pay the provider for what you use, at their rates. Choose between:
• Sarvam, built for Indian languages
• OpenAI
• Google Gemini
Switch provider at any time in Settings.

WHAT YOU GET
• Record in the app, or import m4a, mp3, wav and other audio files
• Automatic transcript in the language that was spoken
• Optional English translation shown next to the original
• Automatic title and summary for every note
• Search across all your notes
• Play the original audio back from each note
• Copy any transcript or translation
• Retry a transcription if your connection drops. Your recording is saved first, so nothing is lost

PRIVATE BY DESIGN
• Notes and audio are stored on your device only
• Your API key is kept in the iOS Keychain
• No account, no ads, no analytics, no tracking
• Audio is sent only to the provider you choose, and only when you transcribe a note

GOOD TO KNOW
• An API key and an internet connection are needed to transcribe
• Language support and accuracy depend on the provider and model you pick
• Provider usage may be billed by that provider

A simple, no-frills tool for turning speech into searchable text, in the language you actually speak.

**Primary category:** Productivity. **Secondary:** Utilities.

**Support URL:** https://github.com/amitrke/voice-notes/issues  **Privacy policy URL:** https://amitrke.github.io/voice-notes/privacy/

**Marketing URL:** https://amitrke.github.io/voice-notes/  **Copyright:** 2026 Amit Kumar

### App Review notes (important)

The app cannot transcribe without an API key, so a reviewer who has none is stuck. Version 1.0 was submitted
without a developer-supplied key (no free paid-provider key was available), so the notes send reviewers to the
free Gemini key guide and a screen recording is attached under App Review Information > Attachment. Notes as
submitted (sign-in required: off):

> Basic Voice Notes is a bring-your-own-key app. There is no account or sign-in, and the developer runs no
> server. The app sends audio directly from the device to an AI provider that the user chooses (Sarvam, OpenAI
> or Google Gemini), using the user's own API key, so a key is needed to transcribe.
>
> The developer cannot supply a paid test key. The quickest free option is a Google Gemini key, which has a free
> tier and takes about two minutes to create: https://amitrke.github.io/voice-notes/api-keys/
>
> To test:
> 1. Open Settings (gear icon, top right) and choose "Gemini" as the provider.
> 2. Paste the key into "API key" and tap Save, then return to Notes.
> 3. Tap Record, say a sentence, then tap stop. (Or tap the import icon and choose an audio file.)
> 4. After a few seconds the note shows a transcript, an English translation and a summary.
>
> Without a key the app still opens normally. A banner on the notes screen explains that a key is needed.
>
> Permissions: the app asks only for microphone access, when recording. It also has an optional "Clinical work"
> setting, off by default, that drafts a clinical note from a transcript. The app is not a medical device.
>
> Contact: amitrke+vnotes@gmail.com
>
> A 1-minute screen recording of the full flow is attached (import a Hindi voice clip, then the transcript,
> English translation and summary), for reviewers who prefer not to create a key.

If a reviewer rejects the app for being untestable, the fix is to put a dedicated, free-tier Gemini key in these
notes (not a personal key) and revoke it after approval.

### Other App Store Connect settings submitted for 1.0

- Price: Free, in every storefront. Release: automatic after approval.
- Availability: all countries and regions except China mainland (needs a local ICP filing and generative-AI
  approvals), Russia and Belarus (sanctions and data-localisation concerns). Re-add them in Pricing and
  Availability > Manage Availability if that changes.
- Content rights: the app does not contain, show or access third-party content.
- Age rating: 13+ in most regions (12+ in Vietnam and South Korea). Everything is None or No except "Medical or
  Treatment Information", answered Infrequent because Clinical mode ships. Answering Frequent would trigger the
  regulated-medical-device declaration.
- App Privacy: "Data Not Collected" (the developer receives nothing; audio goes from the device to the provider
  the user chose). Published 8 October 2026.
- Export compliance: `ITSAppUsesNonExemptEncryption` is `false` in `ios/Runner/Info.plist`.
- Screenshots: `docs/store-assets/ios/iphone` (1206x2622) and `docs/store-assets/ios/ipad` (2064x2752). The
  iPad app stretches to full width, so those screens look sparse; a tablet width limit would improve them.

---

## Store questionnaires: how the app behaves

Use these facts when answering. Check the wording of each question yourself, since the stores' definitions of
"collected" and "shared" are specific.

- The developer operates no server and receives no user data.
- Audio and transcript text are sent from the device to a third-party AI provider chosen by the user, using the
  user's own key, only when the user triggers transcription or summarisation.
- No analytics, advertising or crash-reporting SDKs. No account system. No location, contacts or photos.
- Permission requested: microphone. Data stored on device: notes, audio, settings; API keys in secure storage.
- Google Play Data safety: audio is transferred to a third party at the user's direction. Review Google's
  guidance on "sharing" and its exemption for user-initiated transfers before choosing "No data shared".
- Apple App Privacy: answered "No, we do not collect data from this app" (Apple counts data as collected only if
  the developer or a bundled third-party SDK can access it beyond serving the request; the providers are
  services the user connects to with their own key). The conservative alternative is "Yes" with audio data and
  user content, not linked to identity and not used for tracking. Revisit this if an SDK is ever added.
- Age rating: no objectionable content, but the app can transcribe anything the user records. User-generated
  content is "No" because nothing is shared with other users. See the submitted settings above for the answers
  used on Apple.

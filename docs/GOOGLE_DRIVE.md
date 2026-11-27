# Google Drive backups: one-time setup

The app can keep its automatic backup in a "Voice Notes" folder in the user's Google Drive
(Settings › Backup folder › Google Drive). An Android phone and an iPhone signed in to the same Google
account then share their backups, which a folder on the phone cannot do.

The code is in `lib/services/drive_backup_folder.dart`. It uses Google sign-in (`google_sign_in`) and the
Drive v3 REST API (`googleapis`) with the **`drive.file`** scope only: the app sees and changes only the files
it created, and the user can see the folder in Drive. That scope is non-sensitive, so Google does not need
a security assessment, only the normal brand check of the consent screen.

Until the client IDs below are filled in, the Google Drive option shows as "Not available in this version
of the app yet" and nothing else changes. These steps happen in Google's consoles and cannot be done from
code.

## 1. Google Cloud project

1. Go to <https://console.cloud.google.com/> and create a project, for example "Voice Notes". Use **one**
   project for every client below. Drive links `drive.file` files to the project, so an Android client
   and an iOS client in different projects would not see each other's backups.
2. APIs & Services › Library › **Google Drive API** › Enable.

## 2. OAuth consent screen (Google Auth Platform)

1. Google Auth Platform › Branding:
   - App name: **Voice Notes**. User support email and developer contact: the owner's address.
   - App home page: `https://amitrke.github.io/voice-notes/`
   - Privacy policy: `https://amitrke.github.io/voice-notes/privacy/`. The Backups section added with this
     change says what the app does with Drive and has the Limited Use statement Google asks for. Publish
     the site (merge to `main`) before you ask for verification.
   - Authorised domain: `amitrke.github.io`. Verify ownership in Google Search Console, for example with an
     HTML file in `site/`.
   - A logo is optional. Leave it off unless you want it: adding one makes brand verification a longer review.
2. Audience: **External**.
3. Data access › Add or remove scopes: add `https://www.googleapis.com/auth/drive.file` ("See, edit,
   create and delete only the specific Google Drive files you use with this app"). Add no other scopes.
4. While the app is in **Testing**, only the test users you list (up to 100) can sign in, and Google asks
   them to sign in again every 7 days. That is fine for Play internal testing and TestFlight: add the testers'
   Google accounts under Audience › Test users.
5. Before a production release: Audience › **Publish app**. If Google asks, submit brand verification. With
   only `drive.file` this is a check of the domain, home page and privacy policy, usually a few working
   days, with no security assessment.

## 3. OAuth clients (Google Auth Platform › Clients)

Create these, all in the same project.

| Client type | Settings | Where its ID goes |
| --- | --- | --- |
| **Web application** | Name "Voice Notes (Android sign-in)". No origins or redirect URIs. | `webClientId` in `lib/services/google_config.dart` |
| **Android** (upload key) | Package `com.subnext.voicenotes`, SHA-1 of the upload key | nowhere: Google matches it by package and signature |
| **Android** (Play app signing) | Package `com.subnext.voicenotes`, SHA-1 of Google Play's app-signing key | nowhere |
| **Android** (debug, optional) | Package `com.subnext.voicenotes`, SHA-1 of `~/.android/debug.keystore`, for `flutter run` | nowhere |
| **iOS** | Bundle ID `com.subnext.voicenotes`, Team ID `BTSKP77HML` | `iosClientId` in `google_config.dart`, and the reversed ID in `ios/Flutter/Google.xcconfig` |

Android sign-in needs the Web client even though the app has no server: without it, sign-in fails with
"serverClientId must be provided". If the SHA-1 of the key that signed the build has no Android client,
sign-in fails too, often with only a generic error.

Each Android client takes one SHA-1, so the upload key and the Play app-signing key need a client each.
Builds from Play internal testing and production are re-signed by Google with the **app-signing** key; builds
from the "Build" workflow and local release builds are signed with the upload key.

Getting the SHA-1s:

- Upload key (the keystore in `C:\Users\amitr\dev\keystores\voice-notes\`; the alias is in
  `android/key.properties`):

  ```powershell
  keytool -list -v -keystore C:\Users\amitr\dev\keystores\voice-notes\<upload-keystore>.jks -alias <alias>
  ```

- Play app-signing key: Play Console › Voice Notes › Test and release › App integrity › App signing ›
  "App signing key certificate" › SHA-1.
- Debug key: `keytool -list -v -keystore $env:USERPROFILE\.android\debug.keystore -alias androiddebugkey -storepass android`

## 4. Put the IDs in the app

Client IDs are not secrets (they ship in every copy of the app), so they are committed. Do not put a client
*secret* anywhere: mobile clients have none, and the Web client's secret is not used.

1. `lib/services/google_config.dart`: set the `defaultValue` of `webClientId` to the Web client ID and of
   `iosClientId` to the iOS client ID (both end in `.apps.googleusercontent.com`).
2. `ios/Flutter/Google.xcconfig`: set `GOOGLE_REVERSED_CLIENT_ID` to the iOS client ID reversed. For
   example, `1234-abcd.apps.googleusercontent.com` becomes `com.googleusercontent.apps.1234-abcd`.
   `Info.plist` already registers it as a URL scheme, so Google's sign-in page can return to the app.
3. Open a pull request into `develop`. Merging it ships a test build to Play internal testing and
   TestFlight.

## 5. Check it on real phones

1. Android (from Play internal testing): Settings › Backup folder › Google Drive › choose the account ›
   allow access. The folder row should read "Google Drive › Voice Notes, signed in as …", and a
   `voice-notes-<phone>-<id>.json` should appear in My Drive › Voice Notes.
2. iPhone (TestFlight), same account: Google Drive › sign in › Restore. The Android phone's backup should be
   listed. Restore it, then check that the iPhone adds its own file beside it.
3. Sign out of Google Drive on one phone. Backups go back to the phone's own folder and the files stay
   in Drive.

## 6. Store forms

- Play Console › App content › Data safety, and App Store Connect › App Privacy: backups go from the phone
  to the user's own Google Drive and never to the developer. Check the current wording of both forms. If
  they ask about data sent off the device, it is "Notes, user-initiated, not collected by the developer".
- Play may ask for the reason the app uses Google sign-in: backups to the user's Google Drive.

## How it works

- `DriveBackupFolder` implements the same `BackupFolder` interface as the native folder, so `BackupSync`
  (one file per phone, debounced, restore list) is unchanged.
- `BackupDestinations` switches between the folder on the phone and Drive and remembers the choice in
  SharedPreferences (`backupDestination`).
- On first use it looks for a "Voice Notes" folder the app can see (made by this phone or another one on
  the same account) and creates one if there is none.
- Tokens come from the platform's sign-in SDK each time and are never stored by the app. On a 401 the
  token is discarded and the call is retried once. If the user has signed out or removed access, the
  backup status says so, and choosing Google Drive again signs them in.

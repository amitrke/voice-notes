# Releasing to testers

`.github/workflows/release.yml` builds and ships test builds to Google Play internal testing and TestFlight.
It is adapted from the workflow in `amitrke/relay-player`, which has shipped both stores the same way.

| Trigger | Result |
|---|---|
| push to `develop` | a test build, named `pubspec version (build number)` |
| push of tag `v1.0.0` | a release build; the tag must match `pubspec.yaml`'s version |
| manual run | same, with a choice of store and Play status |

`main` releases nothing on its own. The build number is `github.run_number + 100` on both stores. The offset
leaves room for the first bundle, which was uploaded to Play by hand with versionCode 1.

### Rules, enforced in the workflow's version step so they fail in seconds, not after a build

- `pubspec.yaml` holds the version being tested. Bump it straight after a release.
- A tag must match it: `v1.0.1` on a commit whose pubspec says `1.0.0` fails.
- Once a version's tag exists, test builds of that version stop with an error telling you to bump pubspec.
- Anything that is not `MAJOR.MINOR.PATCH` fails.

### To release

Merge `develop` into `main`, tag that commit with the version in its pubspec, push the tag, then bump
`pubspec.yaml` on `develop`.

### Choosing the stores

Set the repository variable `RELEASE_ANDROID` or `RELEASE_IOS` to `false` to skip that store on every push and
tag until it is removed (for example while TestFlight signing is broken). A manual run can also narrow one run
with its `platforms` input. Unset means on.

### Other workflows

- **Build** (manual): analyse, test and make sideloadable APKs. Needs no secrets.
- **Publish site to GitHub Pages**: publishes `site/` (privacy policy and support page) when it changes on `main`.

## One-time setup

### Repository variables (not secret)

| Name | Value |
|---|---|
| `ANDROID_UPLOAD_KEY_ALIAS` | `upload` |
| `APP_STORE_CONNECT_API_KEY_ID` | the App Store Connect API key's ID |
| `APP_STORE_CONNECT_ISSUER_ID` | the team's issuer ID (same for every key on the team) |

### Repository secrets

| Name | Value |
|---|---|
| `ANDROID_UPLOAD_KEYSTORE_BASE64` | the upload keystore, base64-encoded |
| `ANDROID_UPLOAD_KEYSTORE_PASSWORD` | its store password |
| `ANDROID_UPLOAD_KEY_PASSWORD` | its key password (the same value for this keystore) |
| `APP_STORE_CONNECT_API_KEY_P8` | the whole `.p8` file, including the BEGIN/END lines |
| `PLAY_SERVICE_ACCOUNT_JSON` | JSON key of a service account invited to this app in Play Console |

The upload key lives outside the repo (`C:\Users\amitr\dev\keystores\voice-notes\`). Back it up: losing it
means asking Google to reset the upload key.

### Android: the first bundle goes up by hand

Play's API cannot create an app's first release. Upload `app-release.aab` once in Play Console
(Internal testing → Create new release). The workflow also keeps every bundle it builds as an artifact.
After that, CI uploads automatically. Invite the service account under Users and permissions with only
"Release apps to testing tracks" for this app.

### iOS: cloud-managed signing

No certificate or provisioning profile is stored. `xcodebuild -allowProvisioningUpdates` with the API key lets
Apple create and manage them. The key must have the **Admin** role; App Manager can upload but not sign.
Revoke it in App Store Connect (Users and Access → Integrations) if it ever leaks.

Team `BTSKP77HML`, bundle ID `com.subnext.voicenotes`.

## Notes

- A green iOS job means Apple accepted the upload. The build then spends 10 to 30 minutes processing before
  TestFlight offers it; a rejection at that stage arrives by email.
- Internal TestFlight testers must be App Store Connect users and need no Apple review. Anyone else is an
  external tester and needs Beta App Review.
- Re-running a failed run reuses its build number, so a run that got as far as uploading cannot just be re-run.

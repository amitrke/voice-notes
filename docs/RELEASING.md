# Releasing

`.github/workflows/release.yml` builds and ships test builds to Google Play internal testing and TestFlight.
`.github/workflows/promote.yml` sends a tested build to production on both stores (see "To release").
It is adapted from the workflow in `amitrke/relay-player`, which has shipped both stores the same way.

| Trigger | Result |
|---|---|
| push to `develop` | a test build, named `pubspec version (build number)` |
| push of tag `v1.0.0` | a test build of that version; the tag must match `pubspec.yaml`'s version. Releases no longer need this (see "To release") |
| manual run | same, with a choice of store and Play status |

`main` releases nothing on its own. The build number is `github.run_number + 100` on both stores. The offset
leaves room for the first bundle, which was uploaded to Play by hand with versionCode 1.

### Rules, enforced in the workflow's version step so they fail in seconds, not after a build

- `pubspec.yaml` holds the version being tested. Bump it straight after a release.
- A tag must match it: `v1.0.1` on a commit whose pubspec says `1.0.0` fails.
- Once a version's tag exists, test builds of that version stop with an error telling you to bump pubspec.
- Anything that is not `MAJOR.MINOR.PATCH` fails.

### To release

Production gets the build testers already have; nothing is rebuilt.

1. Note the build number testers approved: the number in brackets in TestFlight and Play Console, e.g. `145`
   in `1.0.1 (145)`. It is the same on both stores.
2. Update the release notes: `fastlane/metadata/android/en-US/changelogs/default.txt` (500 characters at most)
   and `fastlane/metadata/ios/en-US/release_notes.txt`. Change any listing text that is out of date too.
3. Merge `develop` into `main`.
4. Run **Promote to production** from `main` with action `release` and that build number, then approve it in
   the `production` environment. It:
   - moves the build from Play internal testing to production, at the `rollout` percentage (100 is everyone),
     and uploads the Play listing and release notes;
   - sends the TestFlight build to App Review with the App Store listing and release notes, set to go live
     automatically once Apple approves it;
   - tags the commit `vX.Y.Z` once every store it covered has succeeded.
5. Bump `pubspec.yaml` on `develop`.

Do not push the tag yourself. A pushed tag makes `release.yml` upload a new test build, which replaces the
tested one on Play's internal track, and the promotion then cannot find it. The workflow's own tag does not start
`release.yml`.

To widen a staged Play rollout, run the workflow again (`release`, same build, `android`) with a higher
`rollout`. If one store fails, fix it and run again for that store only: the tag waits until both have
succeeded, and a re-run accepts its own tag.

### Store listings

The listing text for both stores lives in `fastlane/metadata`, one file per field, with `android/` (Play, "Voice
Notes") and `ios/` (App Store, "Basic Voice Notes"). Screenshots and images are not managed there yet. Edit
the files in a pull request like any other change.

- `release` uploads the listings with each release.
- `listing` uploads them alone. On Play they go live once Google accepts them. On the App Store most fields can
  change only on a version being prepared, so `listing` creates or updates the version in pubspec without
  submitting it; promotional text, description, URLs and release notes can also change on the live version.
- `check` downloads the live listings and prints how they differ from the repository (in the run's summary),
  except App Review details, which it lists by file name only (see below). It
  changes nothing, but it still needs the store keys, so like the other actions it runs from `main` only and
  waits for approval. It compares the listings on `main`, so merge listing edits there before checking them.
  Run it before the first `release` or `listing`, and whenever someone may have edited a listing in a console,
  since an upload overwrites the console's text.

App Review notes are in `fastlane/metadata/ios/review_information/notes.txt`. Contact details are left out on
purpose, so App Store Connect keeps the ones already there. Each upload removes the App Review attachment unless
there is a file at `fastlane/review_attachment.mp4`, so the notes must not promise one that is not in the repo.

The repository and its Actions logs are public, so nothing private goes in either:

- A key for reviewers to test with lives in the `production` environment secret `APP_REVIEW_GEMINI_KEY`
  (optional). Uploads add it to the end of the notes, from a temporary copy of the metadata, so deliver's printed
  summary never contains it. Use a dedicated free-tier key, never a personal one, and revoke it after approval.
- `check` lists the App Review and trade representative files by name only and never prints what is in them.
  The first `check` (29 October 2026) did print them, before this rule, so the reviewer key that was in the live
  notes then is public and must stay revoked.

To run a lane on your own machine (Ruby and Bundler needed): `bundle install`, then for example
`bundle exec fastlane lanes`. The lanes read their keys from `PLAY_JSON_KEY_PATH`, `ASC_KEY_ID`,
`ASC_ISSUER_ID` and `ASC_KEY_PATH`.

### Choosing the stores

Set the repository variable `RELEASE_ANDROID` or `RELEASE_IOS` to `false` to skip that store on every push and
tag until it is removed (for example while TestFlight signing is broken). A manual run can also narrow one run
with its `platforms` input. Unset means on.

### Other workflows

- **Promote to production** (manual): see "To release" and "Store listings" above.
- **Build** (manual): analyse, test and make sideloadable APKs. Needs no secrets.
- **Dependabot** (`.github/dependabot.yml`): one grouped pull request a week each for pub, GitHub Actions and
  Bundler, into `develop`. Merging one ships a test build like any other merge.
- **CodeQL** (GitHub's default setup, configured in Settings → Code security): scans the workflows, Kotlin,
  Ruby and Python. Dart is not supported, so `flutter analyze` remains the app's main check.
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

### Android: the shared Play service account

One service account serves every Android app on the Play developer account:
`play-release@subnext-play-release.iam.gserviceaccount.com`, in its own Cloud project `subnext-play-release`
(Google Play Android Developer API enabled, no Cloud roles). In Play Console it has these **account-level**
permissions, which cover every app, including future ones: "Release to production, exclude devices, and use
Play App Signing", "Release apps to testing tracks", "Manage testing tracks and edit tester lists", "Manage
store presence", "Manage policy declarations" and "Manage deep links" (checked 29 October 2026).

So the same key uploads test builds (`release.yml`) and promotes them and edits the listing (`promote.yml`).
It can also publish any app on the account to production, so treat a leaked key as serious and revoke it at
once (below). What stops a test build reaching production by mistake is the workflows, not the key:
`release.yml` only ever writes to the internal track, and `promote.yml` needs approval in the `production`
environment.

Give another app's repo its own key, so each can be revoked alone:

```bash
gcloud iam service-accounts keys create key.json \
  --iam-account=play-release@subnext-play-release.iam.gserviceaccount.com \
  --project subnext-play-release
gh secret set PLAY_SERVICE_ACCOUNT_JSON -R <owner>/<repo> < key.json
rm key.json
```

Revoke one repo's key with `gcloud iam service-accounts keys list` then `keys delete <KEY_ID>` (the key ID is in the
JSON's `private_key_id`). Keys must not be committed; delete the downloaded file as shown.

### Production: the environment

`promote.yml` runs every store job in a GitHub environment named `production`. Create it under Settings →
Environments, add yourself as a required reviewer (leave "Prevent self-review" off, since you start the runs
too), and limit it to the `main` branch, so nothing reaches production without your approval. That limit is why
every action, `check` included, runs from `main` only. (Done for this repo on 29 October 2026.)

No extra keys are needed. Play reuses `PLAY_SERVICE_ACCOUNT_JSON`, whose service account already has production
and store-listing permissions (above). The App Store side reuses `APP_STORE_CONNECT_API_KEY_P8`, whose Admin
role can already submit for review.

### Android: the first bundle goes up by hand

Play's API cannot create an app's first release. Upload `app-release.aab` once in Play Console
(Internal testing → Create new release). The workflow also keeps every bundle it builds as an artifact.
After that, CI uploads automatically. The service account needs no invitation per app: its account-level
permissions (above) already cover new apps.

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

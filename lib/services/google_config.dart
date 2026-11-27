/// Google Cloud OAuth client IDs for backing up to Google Drive.
///
/// These are not secrets: they ship inside every copy of the app. They come
/// from the Google Cloud project described in docs/GOOGLE_DRIVE.md. While
/// they are empty, Google Drive shows as unavailable in Settings and the
/// rest of the app works as before.
///
/// Each can also be given at build time, for example
/// `--dart-define=GOOGLE_WEB_CLIENT_ID=…`.
abstract final class GoogleConfig {
  /// The *Web application* client. Android's sign-in needs it (as the
  /// "server client ID") even though the app has no server.
  static const webClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
    defaultValue: '',
  );

  /// The *iOS* client. Its reversed form must also be a URL scheme in
  /// ios/Flutter/Google.xcconfig.
  static const iosClientId = String.fromEnvironment(
    'GOOGLE_IOS_CLIENT_ID',
    defaultValue: '',
  );
}

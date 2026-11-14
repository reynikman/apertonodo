class AppEnv {
  /// Public build values. Key is intentionally omitted: this list is what
  /// is safe to display, and its contents are verified by a test.
  static const keys = ['MUSIC_ENV', 'MUSIC_API_BASE_URL', 'MUSIC_HEALTH_PATH'];

  static const env = String.fromEnvironment('MUSIC_ENV', defaultValue: 'dev');
  static const apiBaseUrl = String.fromEnvironment(
    'MUSIC_API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8088',
  );
  static const healthPath = String.fromEnvironment(
    'MUSIC_HEALTH_PATH',
    defaultValue: '/v1/health',
  );
}

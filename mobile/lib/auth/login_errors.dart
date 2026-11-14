import '../l10n/l10n.dart';

enum LoginError {
  timeout,
  unauthorized,
  badCertificate,
  network,
  badCode,
  weakPassword,
}

String loginErrorText(LoginError error, AppLocalizations text) =>
    switch (error) {
      LoginError.timeout => text.loginErrorTimeout,
      LoginError.unauthorized => text.loginErrorUnauthorized,
      LoginError.badCertificate => text.loginErrorBadCertificate,
      LoginError.network => text.loginErrorNetwork,
      LoginError.badCode => text.loginErrorBadCode,
      LoginError.weakPassword => text.loginErrorWeakPassword,
    };

class LoginFailed implements Exception {
  const LoginFailed(this.reason);
  final LoginError reason;
}

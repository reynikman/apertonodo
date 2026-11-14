import '../server_kind.dart';

/// Login to foreign server (Navidrome, Jellyfin): where and under what username.
class ForeignLogin {
  const ForeignLogin({
    required this.kind,
    required this.base,
    required this.username,
    required this.password,
  });

  final ServerKind kind;
  final Uri base;
  final String username;
  final String password;

  @override
  String toString() => 'ForeignLogin(${kind.name}, $base, $username)';
}

import 'package:music_stream/auth/session_store.dart';

Future<void> seedTestSession() async {
  const token = String.fromEnvironment('FLOWTUNE_TEST_TOKEN');
  if (token.isEmpty) {
    throw StateError(
      'This scenario needs FLOWTUNE_TEST_TOKEN (run it through '
      'scripts/with_branch_server.sh or give the token of a CI user for the public address).',
    );
  }
  await SessionStore().saveToken(token);
}

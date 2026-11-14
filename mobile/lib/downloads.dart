import 'package:http/http.dart' as http;

import 'auth/token_provider.dart';

final http.Client _downloadClient = http.Client();
const _redirectStatuses = {301, 302, 303, 307, 308};

Future<http.StreamedResponse> openDownload(
  Uri uri, {
  required TokenProvider tokens,
  http.Client? client,
}) async {
  final transport = client ?? _downloadClient;
  var current = uri;
  for (var redirects = 0; ; redirects++) {
    final request = http.Request('GET', current)..followRedirects = false;
    request.headers.addAll(tokens.headersFor(current));
    final response = await transport.send(request);
    if (response.statusCode == 401) await tokens.onUnauthorized();
    final location = response.headers['location'];
    if (!_redirectStatuses.contains(response.statusCode) ||
        location == null ||
        redirects >= 5) {
      return response;
    }
    await response.stream.drain<void>();
    current = current.resolve(location);
  }
}

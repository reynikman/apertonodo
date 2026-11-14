import 'package:shared_preferences/shared_preferences.dart';

import 'listen_outbox.dart';
import 'server_api.dart' show ServerApi;

/// Player reports → buffer on device → `POST /v1/history` with run
/// id (D1). A new run is detected when player counter resets: another track
/// or value less than previous (repeat of one, same track again).
class ListenReports {
  ListenReports(ServerApi server, ListenBox box) {
    outbox = ListenOutbox(port: _Port(server, _artwork), box: box);
  }

  late final ListenOutbox outbox;

  /// Artwork is only for the history row; not saved in the device buffer.
  final _artwork = <String, String>{};
  static const _artworkLimit = 500;

  Listen? _listen;
  int _last = 0;

  Future<void> heard(String trackId, int ms, {String artworkUrl = ''}) async {
    if (artworkUrl.isNotEmpty) {
      _artwork.remove(trackId);
      _artwork[trackId] = artworkUrl;
      if (_artwork.length > _artworkLimit) _artwork.remove(_artwork.keys.first);
    }
    if (_listen?.trackId != trackId || ms < _last) {
      _listen = outbox.begin(trackId, paused: false);
    }
    _last = ms;
    final listen = _listen;
    if (listen != null) await outbox.report(listen, ms);
  }

  /// Logout: buffer of this user is not sent under the next user's name.
  Future<void> clear() async {
    _listen = null;
    await outbox.clear();
  }
}

class _Port implements ListenPort {
  _Port(this._server, this._artwork);

  final ServerApi _server;
  final Map<String, String> _artwork;

  @override
  Future<ListenSent> send(ListenReport report) =>
      _server.sendListen(report, artworkUrl: _artwork[report.trackId] ?? '');
}

/// Buffer in device preferences, separate for each account.
class PrefsListenBox implements ListenBox {
  PrefsListenBox(this.key);

  final String key;

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> write(String value) async =>
      (await SharedPreferences.getInstance()).setString(key, value);
}

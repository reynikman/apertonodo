import '../playback.dart';
import 'foreign_library.dart';

/// Audio from foreign server: stream URL contains credentials inside, our token not needed.
class ForeignPlayback implements PlaybackPort {
  ForeignPlayback(this.library);

  final ForeignLibrary library;

  @override
  Future<String> start(String trackId, {bool prepare = false}) async =>
      library.streamUrl(trackId).toString();

  /// Downloads from foreign server — after beta.
  @override
  Future<bool> isLocal(String trackId) async => false;

  /// Foreign server has no report endpoint; our server does not receive foreign URLs.
  @override
  Future<void> failed(String url) async {}
}

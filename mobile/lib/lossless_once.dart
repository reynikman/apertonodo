/// One-time request "this track lossless" (FT-809): user tapped option
/// in player sheet, and the next Play of this track asks for lossless, regardless
/// of quality setting in preferences. In-memory only: nothing written to disk.
class LosslessOnce {
  final _asked = <String>{};

  void ask(String trackId) => _asked.add(trackId);

  /// Whether there was a request for [trackId]; clears it at the same time.
  bool take(String trackId) => _asked.remove(trackId);
}

/// The `audio` block of Play response: format of the real file and gain adjustment.
class AudioInfo {
  final String format;
  final double? gainDb;

  const AudioInfo(this.format, {this.gainDb});

  /// Lossless formats.
  bool get lossless => format == 'flac' || format == 'wav';

  /// Parse the `audio` block of server response.
  ///
  /// Non-map, unknown format, or format is not a string -> null.
  /// Invalid gain or gain exceeding 60 dB is discarded,
  /// preserving format.
  static AudioInfo? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final formatRaw = json['format'];
    if (formatRaw is! String) {
      return null;
    }
    final format = formatRaw.trim().toLowerCase();
    const allowedFormats = {'flac', 'mp3', 'opus', 'ogg', 'm4a', 'aac', 'wav'};
    if (!allowedFormats.contains(format)) {
      return null;
    }

    double? gainDb;
    final gainRaw = json['gain_db'];
    if (gainRaw is num && gainRaw.isFinite) {
      final gainValue = gainRaw.toDouble();
      if (gainValue.abs() <= 60.0) {
        gainDb = gainValue;
      }
    }

    return AudioInfo(format, gainDb: gainDb);
  }
}

class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.durationMs,
    required this.artworkUrl,
    this.playable = true,
    this.missing = false,
  });

  final String id;
  final String title;
  final String artist;
  final int durationMs;
  final String artworkUrl;

  /// Whether it plays from own release list (catalog, "My Music"). Unplayable
  /// appears dim and does not disappear. Search output has no field — plays.
  final bool playable;

  /// Unresolved import row: its id is a playlist row, not a catalog track.
  final bool missing;

  Track withArtwork(String url) => Track(
    id: id,
    title: title,
    artist: artist,
    durationMs: durationMs,
    artworkUrl: url,
    playable: playable,
    missing: missing,
  );

  factory Track.fromJson(Map<String, dynamic> json) {
    return Track(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String,
      durationMs: json['duration_ms'] as int,
      artworkUrl: json['artwork_url'] as String? ?? '',
      playable: json['playable'] as bool? ?? true,
      missing: json['missing'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'duration_ms': durationMs,
    'artwork_url': artworkUrl,
  };
}

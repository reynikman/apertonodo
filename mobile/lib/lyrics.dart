/// Track lyrics (FT-623, Р-A77): LRC parsing and response of `lyrics` extension
/// (`contracts/lyrics-api.md`).
class LyricLine {
  const LyricLine(this.at, this.text);

  final Duration at;
  final String text;
}

final _mark = RegExp(r'^\[(\d+):(\d{1,2})(?:[.:](\d{1,3}))?\]');
final _offset = RegExp(r'^\[offset:\s*([+-]?\d+)\s*\]', caseSensitive: false);

List<LyricLine> parseLrc(String text) {
  var offsetMs = 0;
  final raw = <LyricLine>[];
  for (final source in text.split('\n')) {
    var line = source.trim();
    final off = _offset.firstMatch(line);
    if (off != null) {
      offsetMs = int.parse(off.group(1)!);
      continue;
    }
    final ats = <Duration>[];
    for (
      var m = _mark.firstMatch(line);
      m != null;
      m = _mark.firstMatch(line)
    ) {
      final frac = (m.group(3) ?? '').padRight(3, '0');
      ats.add(
        Duration(
          minutes: int.parse(m.group(1)!),
          seconds: int.parse(m.group(2)!),
          milliseconds: int.parse(frac),
        ),
      );
      line = line.substring(m.end);
    }
    final words = line.trim();
    for (final at in ats) {
      raw.add(LyricLine(at, words));
    }
  }
  final shift = Duration(milliseconds: offsetMs);
  final lines = [
    for (final l in raw)
      LyricLine(l.at > shift ? l.at - shift : Duration.zero, l.text),
  ];
  // Stable sort by index: equal timestamps remain in file order.
  final indexed = [for (var i = 0; i < lines.length; i++) (i, lines[i])];
  indexed.sort((a, b) {
    final c = a.$2.at.compareTo(b.$2.at);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// Last line with `at <= position`, otherwise -1.
int currentLine(List<LyricLine> lines, Duration position) {
  var lo = 0;
  var hi = lines.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (lines[mid].at <= position) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo - 1;
}

class Lyrics {
  const Lyrics({
    required this.found,
    required this.instrumental,
    required this.plain,
    required this.lines,
  });

  factory Lyrics.fromJson(Map<String, dynamic> json) {
    final synced = json['synced'];
    return Lyrics(
      found: json['found'] == true,
      instrumental: json['instrumental'] == true,
      plain: json['plain'] as String?,
      lines: synced is String ? parseLrc(synced) : const [],
    );
  }

  final bool found;
  final bool instrumental;
  final String? plain;
  final List<LyricLine> lines;
}

/// The server answered that this song has no lyrics. No answer at all (network, error) is
/// not "no": the button stays ordinary and the sheet asks again.
bool lyricsMissing(Lyrics? lyrics) => lyrics != null && !lyrics.found;

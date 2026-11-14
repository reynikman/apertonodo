import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/book_position.dart';

/// Lead check FT-670: audiobook progress position — single record per book (contract D5).

final _t0 = DateTime.utc(2026, 10, 1, 12);
final _t1 = DateTime.utc(2026, 10, 1, 12, 0, 1);

BookPosition _at(
  int part,
  int positionMs, {
  bool finished = false,
  DateTime? when,
}) => BookPosition(
  part: part,
  positionMs: positionMs,
  finished: finished,
  updatedAt: when ?? _t0,
);

Map<String, Object?> _json({
  Object? part = 2,
  Object? positionMs = 65000,
  Object? finished = false,
  Object? updatedAt = '2026-10-01T12:00:00.000Z',
}) => {
  'part': part,
  'position_ms': positionMs,
  'finished': finished,
  'updated_at': updatedAt,
};

void main() {
  test('constants', () {
    expect(bookResumeBackMs, 3000);
    expect(bookResumeMinMs, 10000);
    expect(maxBookParts, 3000);
    expect(maxBookPartMs, 30 * 24 * 3600 * 1000);
  });

  group('record', () {
    test('JSON contains four fields, time in UTC with letter Z', () {
      final position = BookPosition(
        part: 2,
        positionMs: 65000,
        finished: false,
        updatedAt: DateTime.parse('2026-10-01T15:00:00+03:00'),
      );
      expect(position.toJson(), {
        'part': 2,
        'position_ms': 65000,
        'finished': false,
        'updated_at': '2026-10-01T12:00:00.000Z',
      });
    });

    test('time is stored in UTC regardless of input timezone', () {
      final position = _at(1, 0, when: DateTime(2026, 10, 1, 12));
      expect(position.updatedAt.isUtc, isTrue);
      expect(
        position.updatedAt.isAtSameMomentAs(DateTime(2026, 10, 1, 12)),
        isTrue,
      );
    });

    test('round-trip through JSON preserves entry', () {
      final position = _at(7, 123456, finished: true);
      expect(BookPosition.fromJson(position.toJson()), position);
    });

    test('reads all four fields from JSON', () {
      final position = BookPosition.fromJson(_json())!;
      expect(position.part, 2);
      expect(position.positionMs, 65000);
      expect(position.finished, isFalse);
      expect(position.updatedAt, DateTime.utc(2026, 10, 1, 12));
    });

    test('valid boundary values are parsed', () {
      expect(BookPosition.fromJson(_json(part: 1, positionMs: 0)), isNotNull);
      expect(
        BookPosition.fromJson(
          _json(part: maxBookParts, positionMs: maxBookPartMs),
        ),
        isNotNull,
      );
      expect(BookPosition.fromJson(_json(finished: true))!.finished, isTrue);
    });

    for (final (name, json) in <(String, Object?)>[
      ('не словарь', 'x'),
      ('пусто', null),
      ('список', <Object?>[]),
      ('часть ноль', _json(part: 0)),
      ('часть меньше нуля', _json(part: -1)),
      ('частей больше предела', _json(part: maxBookParts + 1)),
      ('часть дробью', _json(part: 2.0)),
      ('часть строкой', _json(part: '2')),
      ('части нет', _json(part: null)),
      ('место меньше нуля', _json(positionMs: -1)),
      ('место дальше предела', _json(positionMs: maxBookPartMs + 1)),
      ('место дробью', _json(positionMs: 1.5)),
      ('место строкой', _json(positionMs: '10')),
      ('места нет', _json(positionMs: null)),
      ('«дослушана» числом', _json(finished: 1)),
      ('«дослушана» строкой', _json(finished: 'true')),
      ('«дослушана» нет', _json(finished: null)),
      ('время без Z', _json(updatedAt: '2026-10-01T12:00:00.000')),
      ('время со сдвигом', _json(updatedAt: '2026-10-01T12:00:00+03:00')),
      ('время — не время', _json(updatedAt: 'вчераZ')),
      ('время числом', _json(updatedAt: 1790000000)),
      ('времени нет', _json(updatedAt: null)),
    ]) {
      test('invalid entry ($name) fails to parse', () {
        expect(BookPosition.fromJson(json), isNull);
      });
    }

    test('equality covers all four fields', () {
      expect(_at(2, 5), _at(2, 5));
      expect(_at(2, 5).hashCode, _at(2, 5).hashCode);
      expect(_at(2, 5), isNot(_at(3, 5)));
      expect(_at(2, 5), isNot(_at(2, 6)));
      expect(_at(2, 5), isNot(_at(2, 5, finished: true)));
      expect(_at(2, 5), isNot(_at(2, 5, when: _t1)));
    });

    test('entry string contains neither part nor position', () {
      expect(_at(17, 654321).toString(), 'BookPosition');
    });
  });

  group('which record is newer', () {
    test('later timestamp wins even if position is earlier', () {
      final late = _at(1, 0, when: _t1);
      final early = _at(9, 99999, finished: true);
      expect(newerBookPosition(late, early), same(late));
      expect(newerBookPosition(early, late), same(late));
    });

    test('timestamps equal: completed record wins', () {
      final done = _at(1, 0, finished: true);
      final going = _at(9, 99999);
      expect(newerBookPosition(done, going), same(done));
      expect(newerBookPosition(going, done), same(done));
    });

    test('time and completed equal: later part wins', () {
      final far = _at(3, 0);
      final near = _at(2, 99999);
      expect(newerBookPosition(far, near), same(far));
      expect(newerBookPosition(near, far), same(far));
    });

    test('same part: further playback position wins', () {
      final far = _at(3, 2000);
      final near = _at(3, 1000);
      expect(newerBookPosition(far, near), same(far));
      expect(newerBookPosition(near, far), same(far));
    });

    test('all fields equal: keeps first entry', () {
      final a = _at(3, 1000);
      final b = _at(3, 1000);
      expect(newerBookPosition(a, b), same(a));
      expect(newerBookPosition(b, a), same(b));
    });
  });

  group('where to resume playback', () {
    test('no record: resume from start of book', () {
      expect(bookResume(null, partCount: 5), (part: 1, positionMs: 0));
    });

    test('book completed: restart from beginning', () {
      expect(bookResume(_at(5, 70000, finished: true), partCount: 5), (
        part: 1,
        positionMs: 0,
      ));
    });

    test('typical case: same part, rewind by three seconds', () {
      expect(bookResume(_at(3, 70000), partCount: 5), (
        part: 3,
        positionMs: 67000,
      ));
    });

    test('exactly ten seconds: rewind offset applied', () {
      expect(bookResume(_at(3, 10000), partCount: 5), (
        part: 3,
        positionMs: 7000,
      ));
    });

    test('under ten seconds: starts from beginning of part', () {
      expect(bookResume(_at(3, 9999), partCount: 5), (part: 3, positionMs: 0));
    });

    test('last part: valid to resume', () {
      expect(bookResume(_at(5, 70000), partCount: 5), (
        part: 5,
        positionMs: 67000,
      ));
    });

    test('part number no longer in book: resume from start', () {
      expect(bookResume(_at(6, 70000), partCount: 5), (part: 1, positionMs: 0));
    });

    test('book has no parts: responds without error', () {
      expect(bookResume(_at(1, 70000), partCount: 0), (part: 1, positionMs: 0));
    });
  });

  group('next part', () {
    test('available for all except last part', () {
      expect(nextBookPart(1, partCount: 3), 2);
      expect(nextBookPart(2, partCount: 3), 3);
      expect(nextBookPart(3, partCount: 3), isNull);
    });

    test('nonexistent part has no next part', () {
      expect(nextBookPart(0, partCount: 3), isNull);
      expect(nextBookPart(-1, partCount: 3), isNull);
      expect(nextBookPart(4, partCount: 3), isNull);
      expect(nextBookPart(1, partCount: 0), isNull);
    });
  });

  group('part finished playing', () {
    test('not last part: advances to next, book not completed', () {
      expect(bookPartEnded(2, partCount: 3, now: _t1), _at(3, 0, when: _t1));
    });

    test('last part: book marked as completed', () {
      expect(
        bookPartEnded(3, partCount: 3, now: _t1),
        _at(3, 0, finished: true, when: _t1),
      );
    });

    test('single part audiobook', () {
      expect(
        bookPartEnded(1, partCount: 1, now: _t1),
        _at(1, 0, finished: true, when: _t1),
      );
    });

    test('part index exceeds count: completed, part is last', () {
      expect(
        bookPartEnded(9, partCount: 3, now: _t1),
        _at(3, 0, finished: true, when: _t1),
      );
    });

    test('part number less than one treated as first part', () {
      expect(bookPartEnded(0, partCount: 3, now: _t1), _at(2, 0, when: _t1));
    });

    test('book has no parts: record is still valid', () {
      final ended = bookPartEnded(1, partCount: 0, now: _t1);
      expect(ended, _at(1, 0, finished: true, when: _t1));
      expect(BookPosition.fromJson(ended.toJson()), ended);
    });
  });

  group('listened progress fraction', () {
    test('no record: zero progress', () {
      expect(bookFraction(null, partCount: 4), 0);
    });

    test('completed: returns 1.0 regardless of durations', () {
      expect(bookFraction(_at(1, 0, finished: true), partCount: 4), 1);
      expect(
        bookFraction(
          _at(1, 0, finished: true),
          partCount: 2,
          durationsMs: [1000, 1000],
        ),
        1,
      );
    });

    test('book has no parts: zero progress', () {
      expect(bookFraction(_at(1, 5000), partCount: 0), 0);
      expect(bookFraction(_at(1, 5000, finished: true), partCount: 0), 0);
    });

    test('durations unknown: proportional to part count', () {
      expect(bookFraction(_at(1, 99999), partCount: 4), 0);
      expect(bookFraction(_at(3, 0), partCount: 4), 0.5);
      expect(bookFraction(_at(4, 99999), partCount: 4), 0.75);
    });

    test('durations known: proportional to elapsed time', () {
      expect(
        bookFraction(
          _at(2, 500),
          partCount: 3,
          durationsMs: [1000, 2000, 1000],
        ),
        closeTo(1500 / 4000, 1e-9),
      );
    });

    test('position beyond part duration clamped to part end', () {
      expect(
        bookFraction(
          _at(2, 999999),
          partCount: 3,
          durationsMs: [1000, 2000, 1000],
        ),
        closeTo(3000 / 4000, 1e-9),
      );
    });

    for (final (name, lengths) in <(String, List<int?>)>[
      ('одной нет', [1000, null, 1000]),
      ('одна нулевая', [1000, 0, 1000]),
      ('одна меньше нуля', [1000, -5, 1000]),
      ('длин меньше, чем частей', [1000, 1000]),
      ('длин больше, чем частей', [1000, 1000, 1000, 1000]),
      ('список пуст', []),
    ]) {
      test('invalid durations ($name): based on part count', () {
        expect(
          bookFraction(_at(2, 500), partCount: 3, durationsMs: lengths),
          closeTo(1 / 3, 1e-9),
        );
      });
    }

    test('part index past total count: treated as last, zero offset', () {
      expect(bookFraction(_at(9, 500), partCount: 4), 0.75);
      expect(
        bookFraction(
          _at(9, 500),
          partCount: 3,
          durationsMs: [1000, 2000, 1000],
        ),
        closeTo(3000 / 4000, 1e-9),
      );
    });

    test('position at very end of last part returns 1.0', () {
      expect(
        bookFraction(
          _at(3, 1000),
          partCount: 3,
          durationsMs: [1000, 2000, 1000],
        ),
        1,
      );
    });
  });
}

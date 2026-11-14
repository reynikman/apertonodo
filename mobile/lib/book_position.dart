import 'package:flutter/foundation.dart';

const int bookResumeBackMs = 3000;
const int bookResumeMinMs = 10000;
const int maxBookParts = 3000;
const int maxBookPartMs = 30 * 24 * 3600 * 1000;

@immutable
class BookPosition {
  final int part;
  final int positionMs;
  final bool finished;
  final DateTime updatedAt;

  BookPosition({
    required this.part,
    required this.positionMs,
    required this.finished,
    required DateTime updatedAt,
  }) : updatedAt = updatedAt.toUtc();

  Map<String, Object?> toJson() => {
    'part': part,
    'position_ms': positionMs,
    'finished': finished,
    'updated_at': updatedAt.toIso8601String(),
  };

  static BookPosition? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }

    final part = json['part'];
    if (part is! int || part < 1 || part > maxBookParts) {
      return null;
    }

    final positionMs = json['position_ms'];
    if (positionMs is! int || positionMs < 0 || positionMs > maxBookPartMs) {
      return null;
    }

    final finished = json['finished'];
    if (finished is! bool) {
      return null;
    }

    final updatedAtRaw = json['updated_at'];
    if (updatedAtRaw is! String || !updatedAtRaw.endsWith('Z')) {
      return null;
    }

    final updatedAt = DateTime.tryParse(updatedAtRaw);
    if (updatedAt == null) {
      return null;
    }

    return BookPosition(
      part: part,
      positionMs: positionMs,
      finished: finished,
      updatedAt: updatedAt,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BookPosition &&
        other.part == part &&
        other.positionMs == positionMs &&
        other.finished == finished &&
        other.updatedAt.isAtSameMomentAs(updatedAt);
  }

  @override
  int get hashCode =>
      Object.hash(part, positionMs, finished, updatedAt.microsecondsSinceEpoch);

  @override
  String toString() => 'BookPosition';
}

BookPosition newerBookPosition(BookPosition a, BookPosition b) {
  if (a.updatedAt.isAfter(b.updatedAt)) {
    return a;
  }
  if (b.updatedAt.isAfter(a.updatedAt)) {
    return b;
  }
  if (a.finished != b.finished) {
    return a.finished ? a : b;
  }
  if (a.part != b.part) {
    return a.part > b.part ? a : b;
  }
  if (a.positionMs != b.positionMs) {
    return a.positionMs > b.positionMs ? a : b;
  }
  return a;
}

({int part, int positionMs}) bookResume(
  BookPosition? position, {
  required int partCount,
}) {
  if (position == null ||
      position.finished ||
      position.part < 1 ||
      position.part > partCount) {
    return (part: 1, positionMs: 0);
  }

  if (position.positionMs < bookResumeMinMs) {
    return (part: position.part, positionMs: 0);
  }

  return (
    part: position.part,
    positionMs: position.positionMs - bookResumeBackMs,
  );
}

int? nextBookPart(int part, {required int partCount}) {
  if (part < 1 || part >= partCount) {
    return null;
  }
  return part + 1;
}

BookPosition bookPartEnded(
  int part, {
  required int partCount,
  required DateTime now,
}) {
  if (partCount <= 0) {
    return BookPosition(part: 1, positionMs: 0, finished: true, updatedAt: now);
  }

  final effectivePart = part < 1 ? 1 : part;

  if (effectivePart >= partCount) {
    return BookPosition(
      part: partCount,
      positionMs: 0,
      finished: true,
      updatedAt: now,
    );
  }

  return BookPosition(
    part: effectivePart + 1,
    positionMs: 0,
    finished: false,
    updatedAt: now,
  );
}

double bookFraction(
  BookPosition? position, {
  required int partCount,
  List<int?>? durationsMs,
}) {
  if (position == null || partCount <= 0) {
    return 0.0;
  }
  if (position.finished) {
    return 1.0;
  }

  final isBeyondLast = position.part > partCount;
  final effectivePart = position.part < 1
      ? 1
      : (isBeyondLast ? partCount : position.part);

  if (durationsMs != null && durationsMs.length == partCount) {
    final posMs = isBeyondLast
        ? 0
        : (position.positionMs < 0 ? 0 : position.positionMs);

    var total = 0;
    var elapsed = 0;
    var valid = true;

    for (var i = 0; i < partCount; i++) {
      final d = durationsMs[i];
      if (d == null || d <= 0) {
        valid = false;
        break;
      }
      total += d;
      if (i < effectivePart - 1) {
        elapsed += d;
      } else if (i == effectivePart - 1) {
        elapsed += posMs > d ? d : posMs;
      }
    }

    if (valid && total > 0) {
      return (elapsed / total).clamp(0.0, 1.0);
    }
  }

  return ((effectivePart - 1) / partCount).clamp(0.0, 1.0);
}

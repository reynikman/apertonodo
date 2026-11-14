const preparingDelay = Duration(milliseconds: 1500);

bool showPreparing({
  required DateTime? since,
  required DateTime now,
  required bool playedOnce,
}) {
  if (since == null) {
    return false;
  }
  if (!playedOnce) {
    return true;
  }
  return now.difference(since) > preparingDelay;
}

Duration? preparingRecheck({
  required DateTime? since,
  required DateTime now,
  required bool playedOnce,
}) {
  if (since == null || !playedOnce) {
    return null;
  }
  final elapsed = now.difference(since);
  if (elapsed > preparingDelay) {
    return null;
  }
  return preparingDelay - elapsed + const Duration(milliseconds: 1);
}

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/system_session.dart';

// H6-10 (FT-744): notification "previous", Play/pause, and "next" maintain
// fixed positions. Previously "next" vanished at queue end, shifting pause
// under user's finger.
void main() {
  test('three buttons in fixed slots, pause while playing', () {
    expect(SystemSession.controlsFor(playing: true), [
      MediaControl.skipToPrevious,
      MediaControl.pause,
      MediaControl.skipToNext,
    ]);
  });

  test('when paused, Play is in the same slot', () {
    expect(SystemSession.controlsFor(playing: false), [
      MediaControl.skipToPrevious,
      MediaControl.play,
      MediaControl.skipToNext,
    ]);
  });

  test('all three visible in collapsed notification', () {
    expect(SystemSession.compactIndices, [0, 1, 2]);
  });

  test('next at queue end does nothing without crashing', () async {
    final session = SystemSession();
    var previous = 0;
    session.setSkips(previous: () async => previous++);
    await session.skipToNext();
    await session.skipToPrevious();
    expect(previous, 1);
  });

  test('without queue both buttons are inactive', () async {
    final session = SystemSession()..setSkips();
    await session.skipToNext();
    await session.skipToPrevious();
  });

  test('next advances queue when items available', () async {
    final session = SystemSession();
    var next = 0;
    session.setSkips(next: () async => next++);
    await session.skipToNext();
    expect(next, 1);
  });
}

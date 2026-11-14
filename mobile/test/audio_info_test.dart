import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/audio_info.dart';

/// B7 (FT-749): Play response carries `audio: {format, gain_db}` (D2, server —
/// `server/app/play_audio.py`). Format badge takes `format` from there, rather than
/// guessing. Missing or malformed block — app behaves as before.
void main() {
  test('format and volume', () {
    final info = AudioInfo.fromJson({'format': 'flac', 'gain_db': -6.5});
    expect(info, isNotNull);
    expect(info!.format, 'flac');
    expect(info.gainDb, -6.5);
  });

  test('format only: no volume', () {
    final info = AudioInfo.fromJson({'format': 'opus'})!;
    expect(info.format, 'opus');
    expect(info.gainDb, isNull);
  });

  test('integer volume is also a number', () {
    expect(AudioInfo.fromJson({'format': 'mp3', 'gain_db': 3})!.gainDb, 3.0);
  });

  test('each server format recognized regardless of case or spaces', () {
    for (final format in ['flac', 'mp3', 'opus', 'ogg', 'm4a', 'aac', 'wav']) {
      expect(AudioInfo.fromJson({'format': format})?.format, format);
    }
    expect(AudioInfo.fromJson({'format': ' FLAC '})?.format, 'flac');
  });

  test('no block or not a map: empty', () {
    for (final json in <Object?>[null, 'flac', 3, <Object?>[], true]) {
      expect(AudioInfo.fromJson(json), isNull, reason: '$json');
    }
  });

  test('unknown, empty or non-string format yields nothing', () {
    for (final format in <Object?>[
      null,
      '',
      '  ',
      'flac.part',
      'magnet:?xt=urn:btih:abc',
      'Kino - Gruppa krovi [FLAC]',
      7,
      true,
    ]) {
      expect(AudioInfo.fromJson({'format': format}), isNull, reason: '$format');
    }
    expect(AudioInfo.fromJson({'gain_db': -3.0}), isNull);
  });

  test('invalid volume discarded, format preserved', () {
    for (final gain in <Object?>[
      double.nan,
      double.infinity,
      double.negativeInfinity,
      '-6',
      true,
      61.0,
      -60.5,
      <Object?>[],
    ]) {
      final info = AudioInfo.fromJson({'format': 'flac', 'gain_db': gain});
      expect(info?.format, 'flac', reason: '$gain');
      expect(info?.gainDb, isNull, reason: '$gain');
    }
    expect(AudioInfo.fromJson({'format': 'flac', 'gain_db': 60})!.gainDb, 60);
    expect(AudioInfo.fromJson({'format': 'flac', 'gain_db': -60})!.gainDb, -60);
  });

  test('lossless: flac and wav', () {
    expect(AudioInfo.fromJson({'format': 'flac'})!.lossless, isTrue);
    expect(AudioInfo.fromJson({'format': 'wav'})!.lossless, isTrue);
    expect(AudioInfo.fromJson({'format': 'opus'})!.lossless, isFalse);
    expect(AudioInfo.fromJson({'format': 'mp3'})!.lossless, isFalse);
  });
}

import 'package:flutter/services.dart';

import 'device_library.dart';

/// Channel to Android (`apertono/media`, FT-783): reading audio files
/// from MediaStore and checking/requesting permissions.
class ChannelDeviceMedia implements DeviceMediaPort {
  ChannelDeviceMedia([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('apertono/media');

  final MethodChannel _channel;

  @override
  Future<DeviceAccess> access() async {
    try {
      final res = await _channel.invokeMethod<String>('access');
      return _parseAccess(res);
    } on MissingPluginException {
      return DeviceAccess.denied;
    } on PlatformException {
      return DeviceAccess.denied;
    }
  }

  @override
  Future<DeviceAccess> request() async {
    try {
      final res = await _channel.invokeMethod<String>('request');
      return _parseAccess(res);
    } on MissingPluginException {
      return DeviceAccess.denied;
    } on PlatformException {
      return DeviceAccess.denied;
    }
  }

  @override
  Future<List<DeviceSong>> songs() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('songs');
      if (raw is! List) return const [];
      final result = <DeviceSong>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final uri = item['uri'];
        if (uri is! String || uri.isEmpty) continue;
        final title = item['title'] is String ? item['title'] as String : '';
        final artist = item['artist'] is String ? item['artist'] as String : '';
        final album = item['album'] is String ? item['album'] as String : '';
        final albumId = item['albumId'] != null
            ? item['albumId'].toString()
            : '';
        final durationMs = (item['durationMs'] as num?)?.toInt() ?? 0;
        final track = (item['track'] as num?)?.toInt();
        final path = item['path'] is String ? item['path'] as String : '';
        result.add(
          DeviceSong(
            uri: uri,
            title: title,
            artist: artist,
            album: album,
            albumId: albumId,
            durationMs: durationMs,
            track: track,
            path: path,
          ),
        );
      }
      return result;
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Open app's system settings on the phone.
  Future<void> openSettings() async {
    try {
      await _channel.invokeMethod<void>('openSettings');
    } on MissingPluginException {
      // Tests and platforms without the channel.
    } on PlatformException {
      // System did not open settings — user stays on the screen.
    }
  }

  static DeviceAccess _parseAccess(String? res) => switch (res) {
    'granted' => DeviceAccess.granted,
    'denied_forever' => DeviceAccess.deniedForever,
    _ => DeviceAccess.denied,
  };
}

import 'package:flutter/material.dart';

import '../server_api.dart';
import 'parts.dart';

/// Round artist photo. When no [photo] is provided, a circle with letters like [ArtistSquare].
class ArtistAvatar extends StatelessWidget {
  const ArtistAvatar({
    super.key,
    required this.name,
    this.photo,
    this.server,
    this.size = 64,
  });

  final String name;
  final String? photo;
  final ServerApi? server;
  final double size;

  @override
  Widget build(BuildContext context) {
    final photo = this.photo;
    final server = this.server;
    final fallback = ClipOval(child: ArtistSquare(name, size: size));
    final child = photo == null || server == null
        ? fallback
        : Image.network(
            server.url(photo),
            headers: server.headers,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallback,
          );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

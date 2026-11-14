import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../rated_list.dart';
import '../ratings.dart';
import '../server_ports.dart';
import 'parts.dart';
import 'rated_view.dart';

/// "Liked" or "Disliked" from "My Music" (FT-642). List
/// loads on open; tapping plays the track.
class RatedScreen extends StatefulWidget {
  const RatedScreen({
    super.key,
    required this.services,
    required this.store,
    this.disliked = false,
  });

  final Services services;
  final RatingsStore store;
  final bool disliked;

  @override
  State<RatedScreen> createState() => _RatedScreenState();
}

class _RatedScreenState extends State<RatedScreen> {
  late final _list = RatedList(
    ServerRatedPort(widget.services.server),
    widget.store,
    disliked: widget.disliked,
  )..load().ignore();

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.disliked ? text.ratingDislike : text.libraryRated),
      ),
      body: RatedView(
        list: _list,
        store: widget.store,
        onOpen: (track) {
          final tracks = _list.tracks.toList();
          final (queue, start) = queueFrom(tracks, tracks.indexOf(track));
          widget.services.play(queue, start);
        },
      ),
    );
  }
}

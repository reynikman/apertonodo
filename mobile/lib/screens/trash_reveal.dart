import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'swipe_row.dart' show swipeEdgeGuard;

const _buttonWidth = 64.0;

/// Swipe left reveals trash button on the right (FT-790).
///
/// The swipe itself does not remove the row — deletion occurs only on tapping
/// trash. Edge-of-screen gesture is left to system.
class TrashReveal extends StatefulWidget {
  const TrashReveal({
    super.key,
    required this.child,
    required this.label,
    required this.onRemove,
  });

  final Widget child;
  final String label;
  final VoidCallback onRemove;

  @override
  State<TrashReveal> createState() => _TrashRevealState();
}

class _TrashRevealState extends State<TrashReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Animation<double>? _animation;
  double _offset = 0.0;
  double _target = 0.0;
  bool _ignored = false;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 200),
        )..addListener(() {
          setState(() {
            _offset = _controller.isCompleted
                ? _target
                : (_animation?.value ?? 0.0);
          });
        });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _animateTo(double target) {
    if (_offset == target) return;
    _target = target;
    _animation = Tween<double>(
      begin: _offset,
      end: target,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _controller.reset();
    _controller.forward();
  }

  bool _isNearEdge(double x) {
    final mediaQuery = MediaQuery.maybeOf(context);
    final width = mediaQuery?.size.width ?? 360.0;
    final insets = mediaQuery?.systemGestureInsets ?? EdgeInsets.zero;
    final leftGuard = math.max(swipeEdgeGuard, insets.left);
    final rightGuard = math.max(swipeEdgeGuard, insets.right);
    return x < leftGuard || x > width - rightGuard;
  }

  void _handleDragDown(DragDownDetails details) {
    _ignored = _isNearEdge(details.globalPosition.dx);
    if (!_ignored && _controller.isAnimating) {
      _controller.stop();
    }
  }

  void _handleDragStart(DragStartDetails details) {
    if (_isNearEdge(details.globalPosition.dx)) {
      _ignored = true;
    }
    if (_ignored) return;
    if (_controller.isAnimating) {
      _controller.stop();
    }
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (_ignored) return;
    final delta = details.primaryDelta ?? 0.0;
    setState(() {
      _offset = (_offset - delta).clamp(0.0, _buttonWidth);
    });
  }

  void _handleDragEnd(DragEndDetails details) {
    if (_ignored) {
      _ignored = false;
      return;
    }
    if (_offset > _buttonWidth / 2) {
      _animateTo(_buttonWidth);
    } else {
      _animateTo(0.0);
    }
  }

  void _handleDragCancel() {
    if (_ignored) {
      _ignored = false;
      return;
    }
    if (_offset > _buttonWidth / 2) {
      _animateTo(_buttonWidth);
    } else {
      _animateTo(0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: GestureDetector(
        dragStartBehavior: DragStartBehavior.down,
        behavior: HitTestBehavior.opaque,
        onHorizontalDragDown: _handleDragDown,
        onHorizontalDragStart: _handleDragStart,
        onHorizontalDragUpdate: _handleDragUpdate,
        onHorizontalDragEnd: _handleDragEnd,
        onHorizontalDragCancel: _handleDragCancel,
        child: Stack(
          children: [
            if (_offset > 0)
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: _buttonWidth,
                child: SizedBox.expand(
                  child: IconButton(
                    key: const Key('trash-reveal-button'),
                    tooltip: widget.label,
                    icon: const Icon(
                      Icons.delete_outline,
                      color: ApertonoColors.error,
                    ),
                    onPressed: widget.onRemove,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                  ),
                ),
              ),
            Transform.translate(
              offset: Offset(-_offset, 0),
              child: widget.child,
            ),
          ],
        ),
      ),
    );
  }
}

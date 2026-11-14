import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

const swipeThreshold = 0.3;
const swipeEdgeGuard = 24.0;

class SwipeRow extends StatefulWidget {
  const SwipeRow({
    super.key,
    required this.child,
    required this.label,
    this.onPlayNext,
  });

  final Widget child;
  final String label;
  final VoidCallback? onPlayNext;

  @override
  State<SwipeRow> createState() => _SwipeRowState();
}

class _SwipeRowState extends State<SwipeRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Animation<double>? _animation;
  double _offset = 0.0;
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
            _offset = _animation?.value ?? 0.0;
          });
        });
  }

  @override
  void didUpdateWidget(covariant SwipeRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onPlayNext == null && _offset > 0) {
      _controller.stop();
      _offset = 0.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _animateToZero() {
    if (_offset <= 0) {
      if (_offset != 0) {
        setState(() {
          _offset = 0;
        });
      }
      return;
    }
    _animation = Tween<double>(
      begin: _offset,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _controller.reset();
    _controller.forward();
  }

  void _handleDragDown(DragDownDetails details) {
    if (widget.onPlayNext == null) return;
    _ignored = details.globalPosition.dx < swipeEdgeGuard;
    if (!_ignored && _controller.isAnimating) {
      _controller.stop();
    }
  }

  void _handleDragStart(DragStartDetails details) {
    if (widget.onPlayNext == null) return;
    if (details.globalPosition.dx < swipeEdgeGuard) {
      _ignored = true;
    }
    if (_ignored) return;
    if (_controller.isAnimating) {
      _controller.stop();
    }
  }

  void _handleDragUpdate(DragUpdateDetails details, double maxWidth) {
    if (widget.onPlayNext == null || _ignored) return;
    final delta = details.primaryDelta ?? 0.0;
    setState(() {
      _offset = (_offset + delta).clamp(0.0, maxWidth);
    });
  }

  void _handleDragEnd(DragEndDetails details, double maxWidth) {
    if (widget.onPlayNext == null) return;
    if (_ignored) {
      _ignored = false;
      return;
    }
    final reached = _offset >= swipeThreshold * maxWidth;
    if (reached) {
      widget.onPlayNext?.call();
    }
    _animateToZero();
  }

  void _handleDragCancel() {
    if (widget.onPlayNext == null) return;
    _ignored = false;
    _animateToZero();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      customSemanticsActions: widget.onPlayNext == null
          ? null
          : {CustomSemanticsAction(label: widget.label): widget.onPlayNext!},
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : (MediaQuery.maybeSizeOf(context)?.width ?? 360.0);

          return GestureDetector(
            dragStartBehavior: DragStartBehavior.down,
            behavior: HitTestBehavior.opaque,
            onHorizontalDragDown: widget.onPlayNext == null
                ? null
                : _handleDragDown,
            onHorizontalDragStart: widget.onPlayNext == null
                ? null
                : _handleDragStart,
            onHorizontalDragUpdate: widget.onPlayNext == null
                ? null
                : (details) => _handleDragUpdate(details, width),
            onHorizontalDragEnd: widget.onPlayNext == null
                ? null
                : (details) => _handleDragEnd(details, width),
            onHorizontalDragCancel: widget.onPlayNext == null
                ? null
                : _handleDragCancel,
            child: Stack(
              children: [
                if (_offset > 0)
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: Text(widget.label),
                      ),
                    ),
                  ),
                Transform.translate(
                  offset: Offset(_offset, 0),
                  child: widget.child,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

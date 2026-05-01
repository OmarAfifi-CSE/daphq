import 'package:flutter/material.dart';
import '../../core/app_colors.dart';

class CustomSnackBar {
  static OverlayEntry? _entry;
  static final ValueNotifier<SnackBarData?> _dataNotifier = ValueNotifier(null);

  static void show(
    BuildContext context, {
    required String message,
    Color backgroundColor = AppColors.snackBarBackground,
    Duration duration = const Duration(seconds: 4),
    SnackBarAction? action,
  }) {
    _dataNotifier.value = SnackBarData(
      message: message,
      backgroundColor: backgroundColor,
      duration: duration,
      action: action,
    );

    if (_entry == null) {
      _entry = OverlayEntry(
        builder: (context) => _GlobalSnackBarWidget(
          notifier: _dataNotifier,
          onDismiss: () {
            _entry?.remove();
            _entry = null;
          },
        ),
      );
      Overlay.of(context).insert(_entry!);
    }
  }

  static void hide([BuildContext? context]) {
    _dataNotifier.value = null;
  }
}

class SnackBarData {
  final String message;
  final Color backgroundColor;
  final Duration duration;
  final SnackBarAction? action;
  final DateTime timestamp;

  SnackBarData({
    required this.message,
    required this.backgroundColor,
    required this.duration,
    this.action,
  }) : timestamp = DateTime.now();
}

class _GlobalSnackBarWidget extends StatefulWidget {
  final ValueNotifier<SnackBarData?> notifier;
  final VoidCallback onDismiss;

  const _GlobalSnackBarWidget({
    required this.notifier,
    required this.onDismiss,
  });

  @override
  State<_GlobalSnackBarWidget> createState() => _GlobalSnackBarWidgetState();
}

class _GlobalSnackBarWidgetState extends State<_GlobalSnackBarWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  SnackBarData? _currentData;
  bool _isVisible = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutBack,
    );

    widget.notifier.addListener(_onDataChanged);
    _onDataChanged();
  }

  void _onDataChanged() {
    final newData = widget.notifier.value;

    if (newData == null) {
      if (_isVisible) {
        _isVisible = false;
        _controller.reverse().then((_) {
          if (mounted && widget.notifier.value == null) {
            widget.onDismiss();
          }
        });
      }
      return;
    }

    setState(() => _currentData = newData);

    if (!_isVisible) {
      _isVisible = true;
      _controller.forward();
    }

    // Auto-dismiss logic
    final timestamp = newData.timestamp;
    Future.delayed(newData.duration, () {
      if (mounted && widget.notifier.value?.timestamp == timestamp) {
        widget.notifier.value = null;
      }
    });
  }

  @override
  void dispose() {
    widget.notifier.removeListener(_onDataChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        if (_controller.isDismissed && widget.notifier.value == null) {
          return const SizedBox.shrink();
        }
        return Positioned(
          bottom: 50 + (10 * (1 - _animation.value)),
          left: 20,
          right: 20,
          child: Opacity(
            opacity: _animation.value.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: 0.9 + (0.1 * _animation.value),
              child: child,
            ),
          ),
        );
      },
      child: _currentData == null
          ? const SizedBox.shrink()
          : Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: _currentData!.backgroundColor,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 15,
                      offset: const Offset(0, 8),
                    ),
                  ],
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _currentData!.message,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                    if (_currentData!.action != null) ...[
                      const SizedBox(width: 4),
                      TextButton(
                        style: TextButton.styleFrom(padding: EdgeInsets.zero),
                        onPressed: () {
                          _currentData!.action!.onPressed();
                          widget.notifier.value = null;
                        },
                        child: Text(
                          _currentData!.action!.label,
                          style: TextStyle(
                            color:
                                _currentData!.action!.textColor ??
                                Colors.blueAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}

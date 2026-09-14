import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

mixin BandSelection<T extends StatefulWidget> on State<T> {
  final GlobalKey bandStackKey = GlobalKey();
  final Map<String, GlobalKey> bandCardKeys = {};
  final Set<String> multiSelected = {};

  Offset? _bandStart;
  Offset? _bandCurrent;
  bool _bandMoved = false;
  bool _banding = false;

  ScrollController? bandScrollController;
  Timer? _bandScrollTimer;
  double _bandScrollVelocity = 0;
  double _bandStartScrollOffset = 0;
  bool _bandScrolled = false;

  Timer? _bandArmTimer;
  Offset _bandArmPosition = Offset.zero;
  static const _armDelay = Duration(milliseconds: 350);
  static const _armSlop = 18.0;

  bool get _isTouch =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  ScrollPhysics? get bandScrollPhysics =>
      _isTouch && _banding ? const NeverScrollableScrollPhysics() : null;

  GlobalKey bandCardKey(String key) =>
      bandCardKeys.putIfAbsent(key, () => GlobalKey());

  bool pointOverCard(Offset globalPosition) {
    for (final key in bandCardKeys.values) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) continue;
      final local = box.globalToLocal(globalPosition);
      if (local.dx >= 0 &&
          local.dy >= 0 &&
          local.dx <= box.size.width &&
          local.dy <= box.size.height) {
        return true;
      }
    }
    return false;
  }

  Rect bandRectLocal() {
    final box = bandStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || _bandStart == null || _bandCurrent == null) {
      return Rect.zero;
    }
    final a = box.globalToLocal(_bandStart!);
    final b = box.globalToLocal(_bandCurrent!);
    return Rect.fromPoints(a, b);
  }

  Widget bandOverlay() {
    if (!_banding) {
      return Positioned.fromRect(
        rect: Rect.zero,
        child: const SizedBox.shrink(),
      );
    }
    return Positioned.fromRect(
      rect: bandRectLocal(),
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0x335B9DF7),
            border: Border.all(color: const Color(0xFF5B9DF7)),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }

  void onBandPointerDown(PointerDownEvent event) {
    if ((event.buttons & 1) == 0) return;
    if (pointOverCard(event.position)) return;
    if (_isTouch) {
      _bandArmPosition = event.position;
      _bandArmTimer?.cancel();
      _bandArmTimer = Timer(_armDelay, () {
        if (!mounted) return;
        _startBand(_bandArmPosition);
      });
      return;
    }
    _startBand(event.position);
  }

  void _startBand(Offset position) {
    _bandArmTimer?.cancel();
    _bandArmTimer = null;
    _bandStart = position;
    _bandCurrent = position;
    _bandMoved = false;
    _banding = true;
    _bandScrolled = false;
    final controller = bandScrollController;
    _bandStartScrollOffset = controller != null && controller.hasClients
        ? controller.position.pixels
        : 0;
    setState(() {});
  }

  void _cancelBandArm() {
    _bandArmTimer?.cancel();
    _bandArmTimer = null;
  }

  void onBandPointerMove(PointerMoveEvent event) {
    if (!_banding) {
      if (_bandArmTimer != null &&
          (event.position - _bandArmPosition).distance > _armSlop) {
        _cancelBandArm();
      }
      return;
    }
    if (_bandStart == null) return;
    _updateBandScrollVelocity(event.position);
    if ((event.position - _bandStart!).distance > 4) {
      _bandMoved = true;
      _bandCurrent = event.position;
      _applyBandHits();
    }
  }

  void onBandPointerCancel(PointerCancelEvent event) {
    _cancelBandArm();
    _bandScrollTimer?.cancel();
    _bandScrollTimer = null;
    _bandScrollVelocity = 0;
    if (!_banding) return;
    _banding = false;
    _bandStart = null;
    _bandCurrent = null;
    setState(() {});
  }

  void _applyBandHits() {
    final controller = bandScrollController;
    if (controller != null &&
        controller.hasClients &&
        controller.position.pixels != _bandStartScrollOffset) {
      _bandScrolled = true;
    }
    final replace =
        !_bandScrolled && !HardwareKeyboard.instance.isControlPressed;
    final next = bandHitCards();
    final newSet = replace ? next : {...multiSelected, ...next};
    if (!setEquals(newSet, multiSelected)) {
      setState(() {
        multiSelected
          ..clear()
          ..addAll(newSet);
      });
    } else {
      setState(() {});
    }
  }

  void _updateBandScrollVelocity(Offset position) {
    final box = bandStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(position);
    const edge = 48.0;
    final double velocity;
    if (local.dy < edge) {
      velocity = -(edge - local.dy) / edge * 14.0;
    } else if (local.dy > box.size.height - edge) {
      velocity = (local.dy - (box.size.height - edge)) / edge * 14.0;
    } else {
      velocity = 0;
    }
    _bandScrollVelocity = velocity;
    if (velocity == 0) {
      _bandScrollTimer?.cancel();
      _bandScrollTimer = null;
      return;
    }
    _bandScrollTimer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _bandScrollTick(),
    );
  }

  void _bandScrollTick() {
    final controller = bandScrollController;
    if (!_banding ||
        controller == null ||
        !controller.hasClients ||
        _bandScrollVelocity == 0) {
      return;
    }
    final position = controller.position;
    final target = (position.pixels + _bandScrollVelocity).clamp(
      0.0,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    controller.jumpTo(target);
    _applyBandHits();
  }

  void onBandPointerUp(PointerUpEvent event) {
    _cancelBandArm();
    _bandScrollTimer?.cancel();
    _bandScrollTimer = null;
    _bandScrollVelocity = 0;
    if (!_banding) return;
    _banding = false;
    _bandStart = null;
    _bandCurrent = null;
    if (!_bandMoved && multiSelected.isNotEmpty) {
      setState(multiSelected.clear);
    } else if (_bandMoved) {
      setState(() {});
    }
  }

  Set<String> bandHitCards() {
    if (_bandStart == null || _bandCurrent == null) return {};
    var rect = Rect.fromPoints(_bandStart!, _bandCurrent!);
    final controller = bandScrollController;
    if (controller != null && controller.hasClients) {
      final delta = controller.position.pixels - _bandStartScrollOffset;
      if (delta > 0) {
        rect = Rect.fromLTRB(
          rect.left,
          double.negativeInfinity,
          rect.right,
          rect.bottom,
        );
      } else if (delta < 0) {
        rect = Rect.fromLTRB(rect.left, rect.top, rect.right, double.infinity);
      }
    }
    final hits = <String>{};
    for (final entry in bandCardKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) continue;
      final cardRect = box.localToGlobal(Offset.zero) & box.size;
      if (cardRect.overlaps(rect)) hits.add(entry.key);
    }
    return hits;
  }
}

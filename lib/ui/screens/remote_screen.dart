import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/host_protocol.dart';
import '../../core/remote/key_mapping.dart';
import '../../core/remote/remote_session.dart';
import '../state/providers.dart';
import '../theme/app_colors.dart';
import '../utils/context_menu.dart';

class RemoteScreen extends ConsumerWidget {
  const RemoteScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(remoteManagerProvider);
    final sessions = manager.sessions;

    if (sessions.isEmpty) {
      return const _RemoteEmptyState();
    }

    final active = manager.active ?? sessions.last;

    // Session tabs live in the window title bar, so the viewport fills the
    // whole section.
    return _RemoteViewport(
      key: ValueKey(active.id),
      session: active,
      onClose: () => manager.close(active.id),
      onReconnect: () => manager.reconnect(active.id),
      onResize: (width, height) => manager.resize(active.id, width, height),
    );
  }
}

class _RemoteEmptyState extends StatelessWidget {
  const _RemoteEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.desktop_windows_outlined,
            size: 48,
            color: AppColors.textSecondary,
          ),
          const SizedBox(height: 14),
          Text(
            'No remote desktop sessions',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Connect to an RDP or VNC host to open a session here.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

IconData _protocolIcon(HostProtocol protocol) => switch (protocol) {
  HostProtocol.rdp => Icons.desktop_windows_outlined,
  HostProtocol.vnc => Icons.screen_share_outlined,
  HostProtocol.telnet => Icons.terminal,
  HostProtocol.ssh => Icons.terminal,
};

class _RemoteViewport extends StatefulWidget {
  const _RemoteViewport({
    super.key,
    required this.session,
    required this.onClose,
    required this.onReconnect,
    required this.onResize,
  });

  final RemoteSession session;
  final VoidCallback onClose;
  final VoidCallback onReconnect;
  final void Function(int width, int height) onResize;

  @override
  State<_RemoteViewport> createState() => _RemoteViewportState();
}

class _RemoteViewportState extends State<_RemoteViewport> {
  final FocusNode _focusNode = FocusNode();
  int _buttons = 0;
  bool _keyboardLocked = false;
  bool _typeTextOpen = false;

  /// Accumulated two-finger scroll distance, in logical pixels.
  double _scrollAccum = 0;

  /// Accumulated macOS trackpad scroll distance, delivered as pan/zoom events.
  double _trackpadAccum = 0;

  /// Virtual remote cursor position, in desktop pixels, for touch input. It
  /// only changes by the finger's delta so the pointer does not jump under the
  /// finger the way an absolute pointer would.
  (double, double)? _cursorDesktop;
  (int, int) _cursorSize = (0, 0);
  Offset? _lastFocalLocal;

  @override
  void dispose() {
    if (_keyboardLocked) {
      _keyboardLocked = false;
      unawaited(_setNativeKeyboardLock(false));
    }
    _focusNode.dispose();
    super.dispose();
  }

  RemoteSession get _session => widget.session;

  void _sendPointer(Offset local, Size size) {
    final desktop = _toDesktop(local, size);
    if (desktop == null) return;
    _session.sendPointer(_buttons, desktop.$1, desktop.$2);
  }

  (int, int)? _toDesktop(Offset local, Size size) {
    final dw = _session.desktopWidth;
    final dh = _session.desktopHeight;
    if (dw <= 0 || dh <= 0) return null;
    final scale = _scaleFor(size, dw, dh);
    final drawW = dw * scale;
    final drawH = dh * scale;
    final offsetX = (size.width - drawW) / 2;
    final offsetY = (size.height - drawH) / 2;
    final x = ((local.dx - offsetX) / scale).round().clamp(0, dw - 1);
    final y = ((local.dy - offsetY) / scale).round().clamp(0, dh - 1);
    return (x, y);
  }

  double _scaleFor(Size size, int dw, int dh) {
    final scaleX = size.width / dw;
    final scaleY = size.height / dh;
    return scaleX < scaleY ? scaleX : scaleY;
  }

  int _maskFromButtons(int buttons) {
    var mask = 0;
    if (buttons & kPrimaryMouseButton != 0) mask |= 1;
    if (buttons & kSecondaryMouseButton != 0) mask |= 2;
    if (buttons & kMiddleMouseButton != 0) mask |= 4;
    return mask;
  }

  /// Touch devices get a trackpad-style gesture layer instead of the raw
  /// mouse listener: tap = left click, hold = right click, one-finger drag =
  /// move the cursor (no button), two-finger drag = scroll.
  bool get _isTouch =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  void _handlePointerSignal(PointerSignalEvent event, Size size) {
    if (event is! PointerScrollEvent) return;
    final desktop = _toDesktop(event.localPosition, size);
    if (desktop == null) return;
    final delta = event.scrollDelta.dy > 0 ? -1 : 1;
    _session.sendWheel(_buttons, desktop.$1, desktop.$2, delta);
  }

  /// macOS delivers two-finger trackpad scrolling as pan/zoom events rather
  /// than [PointerScrollEvent]; translate the vertical pan into wheel notches.
  /// This follows natural scrolling: fingers down scroll toward the top.
  void _handleTrackpadPanZoom(PointerPanZoomUpdateEvent event, Size size) {
    final desktop = _toDesktop(event.localPosition, size);
    if (desktop == null) return;
    final dy = event.localPanDelta.dy;
    if (dy == 0) return;
    const step = 24.0;
    _trackpadAccum += dy;
    while (_trackpadAccum >= step) {
      _trackpadAccum -= step;
      _session.sendWheel(0, desktop.$1, desktop.$2, 1);
    }
    while (_trackpadAccum <= -step) {
      _trackpadAccum += step;
      _session.sendWheel(0, desktop.$1, desktop.$2, -1);
    }
  }

  /// The remote cursor for touch input, created at the desktop centre and
  /// reset whenever the desktop size changes.
  (double, double) _ensureCursor() {
    final dw = _session.desktopWidth;
    final dh = _session.desktopHeight;
    if (_cursorDesktop == null || _cursorSize != (dw, dh)) {
      _cursorSize = (dw, dh);
      _cursorDesktop = (dw / 2, dh / 2);
    }
    return _cursorDesktop!;
  }

  (int, int) _cursorPoint() {
    final cursor = _ensureCursor();
    final x = cursor.$1.round().clamp(0, _session.desktopWidth - 1);
    final y = cursor.$2.round().clamp(0, _session.desktopHeight - 1);
    return (x, y);
  }

  /// A full press-and-release at the cursor: tap (left) or hold (right).
  void _touchClick(int button) {
    final point = _cursorPoint();
    _session.sendPointer(button, point.$1, point.$2);
    _session.sendPointer(0, point.$1, point.$2);
  }

  /// Moves the cursor by the finger's delta instead of jumping to it.
  void _touchMoveBy(Offset local, Size size) {
    final last = _lastFocalLocal;
    _lastFocalLocal = local;
    if (last == null) return;
    final dw = _session.desktopWidth;
    final dh = _session.desktopHeight;
    if (dw <= 0 || dh <= 0) return;
    final scale = _scaleFor(size, dw, dh);
    if (scale <= 0) return;
    final cursor = _ensureCursor();
    final x = (cursor.$1 + (local.dx - last.dx) / scale).clamp(
      0.0,
      (dw - 1).toDouble(),
    );
    final y = (cursor.$2 + (local.dy - last.dy) / scale).clamp(
      0.0,
      (dh - 1).toDouble(),
    );
    _cursorDesktop = (x, y);
    _session.sendPointer(0, x.round(), y.round());
  }

  void _touchPress() {
    final point = _cursorPoint();
    _session.sendPointer(2, point.$1, point.$2);
  }

  void _touchRelease() {
    final point = _cursorPoint();
    _session.sendPointer(0, point.$1, point.$2);
  }

  /// Right click is a press at the cursor; release wherever it currently is.
  void _releaseRight() => _touchRelease();

  void _touchScroll(double dy) {
    if (dy == 0) return;
    final point = _cursorPoint();
    const step = 24.0;
    _scrollAccum += dy;
    while (_scrollAccum >= step) {
      _scrollAccum -= step;
      _session.sendWheel(0, point.$1, point.$2, 1);
    }
    while (_scrollAccum <= -step) {
      _scrollAccum += step;
      _session.sendWheel(0, point.$1, point.$2, -1);
    }
  }

  Widget _desktopInput(Size size, Widget child) {
    return Listener(
      onPointerDown: (event) {
        _focusNode.requestFocus();
        var mask = _maskFromButtons(event.buttons);
        // Some embedders report no buttons on the down event; assume the
        // primary button so clicks work.
        if (mask == 0) mask = 1;
        _buttons |= mask;
        _sendPointer(event.localPosition, size);
      },
      onPointerMove: (event) {
        final mask = _maskFromButtons(event.buttons);
        // Keep a held button during a drag even if the platform reports an
        // empty mask mid-move.
        if (mask != 0 || _buttons == 0) _buttons = mask;
        _sendPointer(event.localPosition, size);
      },
      onPointerUp: (event) {
        final remaining = _maskFromButtons(event.buttons);
        // If the platform still reports the released bit, nothing changed, so
        // clear the buttons outright.
        _buttons = remaining == _buttons ? 0 : remaining;
        _sendPointer(event.localPosition, size);
      },
      onPointerHover: (event) {
        _buttons = 0;
        _sendPointer(event.localPosition, size);
      },
      onPointerSignal: (event) => _handlePointerSignal(event, size),
      onPointerPanZoomStart: (_) => _trackpadAccum = 0,
      onPointerPanZoomUpdate: (event) => _handleTrackpadPanZoom(event, size),
      onPointerPanZoomEnd: (_) => _trackpadAccum = 0,
      child: child,
    );
  }

  Widget _touchInput(Size size, Widget child) {
    final connected = _session.status == RemoteStatus.connected;
    return Listener(
      onPointerDown: (_) => _focusNode.requestFocus(),
      onPointerSignal: (event) => _handlePointerSignal(event, size),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: connected ? (_) => _touchClick(1) : null,
        onLongPressStart: connected ? (_) => _touchPress() : null,
        onLongPressEnd: connected ? (_) => _releaseRight() : null,
        onLongPressCancel: connected ? _releaseRight : null,
        onScaleStart: connected
            ? (details) {
                _scrollAccum = 0;
                _lastFocalLocal = details.localFocalPoint;
              }
            : null,
        onScaleUpdate: connected
            ? (details) {
                if (details.pointerCount >= 2) {
                  _touchScroll(details.focalPointDelta.dy);
                } else {
                  _touchMoveBy(details.localFocalPoint, size);
                }
              }
            : null,
        onScaleEnd: connected
            ? (_) {
                _lastFocalLocal = null;
                _scrollAccum = 0;
              }
            : null,
        child: child,
      ),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final locked = _keyboardLocked;
    final meta = HardwareKeyboard.instance.isMetaPressed;
    final ctrl = HardwareKeyboard.instance.isControlPressed;

    // Type-through is always on. While the keyboard is NOT locked, macOS
    // Command shortcuts stay on this computer instead of being forwarded.
    if (!locked && meta) return KeyEventResult.ignored;

    // Locked VNC: intercept paste so the local clipboard is typed into the
    // remote. RDP uses CLIPRDR, which keeps the remote clipboard in sync
    // (including files), so Ctrl+V is forwarded untouched.
    if (locked &&
        _session.protocol == HostProtocol.vnc &&
        (ctrl || meta) &&
        event.logicalKey == LogicalKeyboardKey.keyV) {
      if (event is KeyDownEvent) _pasteFromClipboard();
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _session.sendKey(mapKey(_remoteKey(event.logicalKey, locked)), true);
    } else if (event is KeyUpEvent) {
      _session.sendKey(mapKey(_remoteKey(event.logicalKey, locked)), false);
    } else {
      return KeyEventResult.ignored;
    }

    // Consume the event so it does not also drive local focus navigation;
    // while locked this additionally blocks local shortcuts (Command, etc.),
    // which are sent to the remote host instead.
    return KeyEventResult.handled;
  }

  /// While the keyboard is locked, the Mac's Command modifier stands in for
  /// the remote's Control modifier (⌘C → Ctrl+C, …), so map the Command key
  /// events to Control before translating to protocol scancodes/keysyms.
  LogicalKeyboardKey _remoteKey(LogicalKeyboardKey key, bool locked) {
    if (!locked) return key;
    if (key == LogicalKeyboardKey.metaLeft) {
      return LogicalKeyboardKey.controlLeft;
    }
    if (key == LogicalKeyboardKey.metaRight) {
      return LogicalKeyboardKey.controlRight;
    }
    return key;
  }

  static const MethodChannel _keyboardChannel = MethodChannel(
    'connexia/keyboard',
  );

  void _toggleKeyboardLock() {
    setState(() => _keyboardLocked = !_keyboardLocked);
    if (_keyboardLocked) _focusNode.requestFocus();
    unawaited(_setNativeKeyboardLock(_keyboardLocked));
  }

  void _toggleTypeText() {
    setState(() => _typeTextOpen = !_typeTextOpen);
    if (!_typeTextOpen) _focusNode.requestFocus();
  }

  void _closeTypeText() {
    setState(() => _typeTextOpen = false);
    _focusNode.requestFocus();
  }

  /// On macOS the system menu's key equivalents (⌘Q, ⌘W, ⌘H, …) are handled
  /// by AppKit before Flutter sees the event. Tell the native window to clear
  /// them while locked so those keys reach the remote host instead of the Mac.
  Future<void> _setNativeKeyboardLock(bool locked) async {
    if (!Platform.isMacOS) return;
    try {
      await _keyboardChannel.invokeMethod('setLocked', locked);
    } catch (_) {
      // The channel is only present on macOS; ignore everywhere else.
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _session.typeText(text);
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Container(
      color: AppColors.terminalBackground,
      child: Column(
        children: [
          ListenableBuilder(
            listenable: session,
            builder: (context, _) => _RemoteToolbar(
              session: session,
              keyboardLocked: _keyboardLocked,
              typeTextOpen: _typeTextOpen,
              onToggleKeyboardLock: _toggleKeyboardLock,
              onToggleTypeText: _toggleTypeText,
              onClose: widget.onClose,
              onResize: widget.onResize,
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: session,
              builder: (context, _) {
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final size = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    final content = Stack(
                      fit: StackFit.expand,
                      children: [
                        _FramebufferView(session: session),
                        if (session.clipboardTransfer != null)
                          _ClipboardTransferOverlay(
                            transfer: session.clipboardTransfer!,
                            speed: session.clipboardTransferSpeed,
                            onCancel: session.clipboardTransfer!.sending
                                ? () => session.cancelClipboardTransfer()
                                : null,
                          ),
                        if (session.status != RemoteStatus.connected)
                          _RemoteStatusOverlay(
                            session: session,
                            onReconnect: widget.onReconnect,
                            onClose: widget.onClose,
                          ),
                      ],
                    );
                    final input = Focus(
                      focusNode: _focusNode,
                      autofocus: true,
                      onKeyEvent: _onKey,
                      child: MouseRegion(
                        cursor: session.status == RemoteStatus.connected
                            ? SystemMouseCursors.none
                            : SystemMouseCursors.basic,
                        child: _isTouch
                            ? _touchInput(size, content)
                            : _desktopInput(size, content),
                      ),
                    );
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        input,
                        if (_typeTextOpen &&
                            session.status == RemoteStatus.connected)
                          Positioned(
                            top: 12,
                            right: 12,
                            child: _TypeTextPanel(
                              onClose: _closeTypeText,
                              onType: session.typeTextPaced,
                            ),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FramebufferView extends StatelessWidget {
  const _FramebufferView({required this.session});

  final RemoteSession session;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _FramebufferPainter(session),
      size: Size.infinite,
    );
  }
}

class _FramebufferPainter extends CustomPainter {
  _FramebufferPainter(this.session) : super(repaint: session.framebuffer);

  final RemoteSession session;

  @override
  void paint(Canvas canvas, Size size) {
    final image = session.framebuffer.image;
    if (image == null) return;
    final dw = session.desktopWidth.toDouble();
    final dh = session.desktopHeight.toDouble();
    if (dw <= 0 || dh <= 0) return;
    final scaleX = size.width / dw;
    final scaleY = size.height / dh;
    final scale = scaleX < scaleY ? scaleX : scaleY;
    final drawW = dw * scale;
    final drawH = dh * scale;
    final dst = Rect.fromLTWH(
      (size.width - drawW) / 2,
      (size.height - drawH) / 2,
      drawW,
      drawH,
    );
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(covariant _FramebufferPainter oldDelegate) =>
      oldDelegate.session != session;
}

/// Card shown over the session while clipboard files are being transferred, so
/// the wait is visible instead of a bare busy cursor.
class _ClipboardTransferOverlay extends StatelessWidget {
  const _ClipboardTransferOverlay({
    required this.transfer,
    this.speed,
    this.onCancel,
  });

  final ClipboardTransferInfo transfer;

  /// Smoothed rate in bytes/second, when known.
  final double? speed;

  /// Invoked when the user aborts the transfer; `null` when not cancellable.
  final VoidCallback? onCancel;

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = value >= 10 || unit == 0 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }

  String? _formatSpeed(double? bytesPerSecond) {
    if (bytesPerSecond == null || bytesPerSecond <= 0) return null;
    const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
    var value = bytesPerSecond;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = value >= 10 ? 1 : 2;
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }

  @override
  Widget build(BuildContext context) {
    final sending = transfer.sending;
    final percent = (transfer.fraction * 100).round();
    final speedLabel = transfer.complete ? null : _formatSpeed(speed);
    final fileLabel = transfer.fileCount > 1
        ? '${transfer.fileName} (${transfer.index} of ${transfer.fileCount})'
        : transfer.fileName;

    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        minimum: const EdgeInsets.all(16),
        child: Container(
          width: 380,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          decoration: BoxDecoration(
            color: AppColors.elevated.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    sending ? Icons.file_upload : Icons.file_download,
                    size: 18,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      sending
                          ? 'Sending to remote computer'
                          : 'Receiving from remote computer',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    transfer.complete ? 'Done' : '$percent%',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                  if (onCancel != null && !transfer.complete) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: onCancel,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        foregroundColor: AppColors.danger,
                        backgroundColor: AppColors.danger.withValues(
                          alpha: 0.12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                          side: BorderSide(
                            color: AppColors.danger.withValues(alpha: 0.4),
                          ),
                        ),
                      ),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: transfer.complete ? 1.0 : transfer.fraction,
                  minHeight: 6,
                  backgroundColor: AppColors.border,
                  valueColor: AlwaysStoppedAnimation(AppColors.accent),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                fileLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
              if (transfer.total > 0 || speedLabel != null) ...[
                const SizedBox(height: 2),
                Text(
                  [
                    if (transfer.total > 0)
                      '${_formatBytes(transfer.transferred)} of ${_formatBytes(transfer.total)}',
                    ?speedLabel,
                  ].join('   ·   '),
                  style: TextStyle(color: AppColors.textFaint, fontSize: 11.5),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RemoteStatusOverlay extends StatelessWidget {
  const _RemoteStatusOverlay({
    required this.session,
    required this.onReconnect,
    required this.onClose,
  });

  final RemoteSession session;
  final VoidCallback onReconnect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    if (session.status == RemoteStatus.connecting) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }

    final isError = session.status == RemoteStatus.error;
    return ColoredBox(
      color: AppColors.terminalBackground.withValues(alpha: 0.88),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isError ? Icons.error_outline : Icons.link_off,
                color: isError ? AppColors.danger : AppColors.warning,
                size: 34,
              ),
              const SizedBox(height: 12),
              Text(
                isError ? 'Connection failed' : 'Disconnected',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (session.error != null) ...[
                const SizedBox(height: 8),
                Text(
                  session.error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: onClose,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 38),
                      textStyle: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text('Close'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: onReconnect,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 38),
                      textStyle: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Reconnect'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RemoteToolbar extends StatelessWidget {
  const _RemoteToolbar({
    required this.session,
    required this.keyboardLocked,
    required this.typeTextOpen,
    required this.onToggleKeyboardLock,
    required this.onToggleTypeText,
    required this.onClose,
    required this.onResize,
  });

  final RemoteSession session;
  final bool keyboardLocked;
  final bool typeTextOpen;
  final VoidCallback onToggleKeyboardLock;
  final VoidCallback onToggleTypeText;
  final VoidCallback onClose;
  final void Function(int width, int height) onResize;

  @override
  Widget build(BuildContext context) {
    final connected = session.status == RemoteStatus.connected;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.terminalChrome,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Icon(
            _protocolIcon(session.protocol),
            size: 16,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              session.title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (keyboardLocked) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.accentMuted,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.accentBorder),
              ),
              child: Text(
                'KEYBOARD LOCKED',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: AppColors.accent,
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          _ResolutionButton(
            session: session,
            enabled: connected && session.protocol == HostProtocol.rdp,
            onSelected: onResize,
          ),
          const SizedBox(width: 8),
          _ToolbarButton(
            icon: Icons.text_fields,
            tooltip:
                'Type text on the remote host — works on login screens where '
                'clipboard paste is unavailable.',
            active: typeTextOpen,
            onPressed: connected ? onToggleTypeText : null,
          ),
          const SizedBox(width: 8),
          _ToolbarButton(
            icon: keyboardLocked
                ? Icons.keyboard_hide_outlined
                : Icons.keyboard_outlined,
            tooltip: keyboardLocked
                ? 'Keyboard locked — Command and other shortcuts go to the '
                      'remote host. Click to release.'
                : 'Keyboard active. Command shortcuts work locally; click to '
                      'lock everything to the remote host.',
            active: keyboardLocked,
            onPressed: connected ? onToggleKeyboardLock : null,
          ),
          _ToolbarButton(
            icon: Icons.close,
            tooltip: 'Close',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }

}

class _TypeTextPanel extends StatefulWidget {
  const _TypeTextPanel({required this.onClose, required this.onType});

  final VoidCallback onClose;
  final Future<void> Function(String text) onType;

  @override
  State<_TypeTextPanel> createState() => _TypeTextPanelState();
}

class _TypeTextPanelState extends State<_TypeTextPanel> {
  final _controller = TextEditingController();
  bool _hide = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text;
    if (text.isEmpty) return;
    await widget.onType(text);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.terminalChrome,
      elevation: 8,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 360,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.text_fields, size: 16, color: AppColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Type on remote host',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                InkWell(
                  onTap: widget.onClose,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close,
                      size: 16,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Sent as keystrokes, so it works on login screens where '
              'clipboard paste is unavailable. A newline presses Enter.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 11.5),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _controller,
              autofocus: true,
              obscureText: _hide,
              minLines: 1,
              maxLines: _hide ? 1 : 4,
              style: TextStyle(color: AppColors.textPrimary, fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'Text to type',
                isDense: true,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Checkbox(
                  value: _hide,
                  onChanged: (value) => setState(() => _hide = value ?? false),
                ),
                Text(
                  'Hide text',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _submit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 34),
                    textStyle: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('Type'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ResolutionButton extends StatelessWidget {
  const _ResolutionButton({
    required this.session,
    required this.enabled,
    required this.onSelected,
  });

  final RemoteSession session;
  final bool enabled;
  final void Function(int width, int height) onSelected;

  /// Common desktop resolutions offered when reconnecting the session.
  static const List<(int, int)> _presets = [
    (1280, 720),
    (1280, 800),
    (1366, 768),
    (1600, 900),
    (1920, 1080),
    (1920, 1200),
    (2560, 1440),
    (3840, 2160),
  ];

  Future<void> _showMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final current = '${session.requestedWidth}x${session.requestedHeight}';
    final value = await showContextMenuAt<String>(
      context: context,
      globalPosition: box.localToGlobal(box.size.bottomLeft(Offset.zero)),
      items: [
        for (final (width, height) in _presets)
          PopupMenuItem(
            value: '$width x $height',
            child: Row(
              children: [
                Icon(
                  '$width x $height' == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 15,
                  color: '$width x $height' == current
                      ? AppColors.accent
                      : AppColors.textSecondary,
                ),
                const SizedBox(width: 8),
                Text('$width x $height', style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
      ],
    );
    if (value == null) return;
    final parts = value.split(' x ');
    if (parts.length != 2) return;
    final width = int.tryParse(parts[0]);
    final height = int.tryParse(parts[1]);
    if (width == null || height == null) return;
    onSelected(width, height);
  }

  @override
  Widget build(BuildContext context) {
    final color = enabled ? AppColors.textSecondary : AppColors.textFaint;
    return Tooltip(
      message: enabled
          ? 'Resolution — reconnect at a different desktop size'
          : 'Resolution',
      child: InkWell(
        onTap: enabled ? () => _showMenu(context) : null,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.aspect_ratio, size: 14, color: color),
              const SizedBox(width: 6),
              Text(
                '${session.requestedWidth}x${session.requestedHeight}',
                style: TextStyle(color: color, fontSize: 11.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final color = !enabled
        ? AppColors.textSecondary.withValues(alpha: 0.4)
        : active
        ? AppColors.accent
        : AppColors.textSecondary;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: active ? AppColors.accentMuted : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active ? AppColors.accentBorder : Colors.transparent,
            ),
          ),
          child: Icon(icon, size: 17, color: color),
        ),
      ),
    );
  }
}

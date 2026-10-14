import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../widgets/tv_focus.dart';
import 'app_update_controller.dart';

class AppUpdateCard extends ConsumerStatefulWidget {
  const AppUpdateCard({super.key});

  @override
  ConsumerState<AppUpdateCard> createState() => _AppUpdateCardState();
}

class _AppUpdateCardState extends ConsumerState<AppUpdateCard> {
  final _entry = FocusNode(debugLabel: 'app-update-entry');

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appUpdateProvider);
    if (!state.supported) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: TvFocusable(
        focusNode: _entry,
        onActivate: () async {
          final controller = ref.read(appUpdateProvider.notifier);
          if (state.apkPath == null && !state.busy) {
            unawaited(controller.check());
          }
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => const AppUpdateDialog(),
          );
          if (mounted) _entry.requestFocus();
        },
        builder: (_, focused) => TvFocusRing(
          focused: focused,
          selected: false,
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              const Icon(Icons.system_update_alt, size: 32),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('软件更新', style: AppTypography.title),
                    const SizedBox(height: 6),
                    Text(state.status, style: AppTypography.body),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.chevron_right, size: 28),
            ],
          ),
        ),
      ),
    );
  }
}

class AppUpdateDialog extends ConsumerStatefulWidget {
  const AppUpdateDialog({super.key});

  @override
  ConsumerState<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends ConsumerState<AppUpdateDialog>
    with WidgetsBindingObserver {
  final _primary = FocusNode(debugLabel: 'app-update-primary');
  final _close = FocusNode(debugLabel: 'app-update-close');
  final _notes = FocusNode(debugLabel: 'app-update-notes');
  final _notesScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _focusPrimary() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        _primary.requestFocus();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(appUpdateProvider.notifier).resumed());
      _focusPrimary();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _primary.dispose();
    _close.dispose();
    _notes.dispose();
    _notesScroll.dispose();
    super.dispose();
  }

  void _leave() => Navigator.of(context).pop();

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.gameButtonB) {
      _leave();
      return KeyEventResult.handled;
    }
    final directions = {
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
    };
    if (!directions.contains(key)) return KeyEventResult.ignored;
    if (_notes.hasFocus && _notesScroll.hasClients) {
      final position = _notesScroll.position;
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown) {
        final down = key == LogicalKeyboardKey.arrowDown;
        if (down && position.pixels >= position.maxScrollExtent - 1) {
          _primary.requestFocus();
        } else {
          _notesScroll.jumpTo(
            (position.pixels +
                    (down ? 1 : -1) *
                        math.min(100, position.viewportDimension * .8))
                .clamp(0.0, position.maxScrollExtent),
          );
        }
      } else {
        (key == LogicalKeyboardKey.arrowRight ? _close : _primary)
            .requestFocus();
      }
      return KeyEventResult.handled;
    }
    final hasNotes =
        ref.read(appUpdateProvider).release?.releaseNotes.isNotEmpty ?? false;
    final vertical = MediaQuery.sizeOf(context).width < 520;
    if (key == LogicalKeyboardKey.arrowUp) {
      if (vertical && _close.hasFocus) {
        _primary.requestFocus();
      } else if (hasNotes) {
        _notes.requestFocus();
      }
    } else if (key == LogicalKeyboardKey.arrowDown) {
      if (vertical) _close.requestFocus();
    } else {
      (key == LogicalKeyboardKey.arrowLeft ? _primary : _close).requestFocus();
    }
    return KeyEventResult.handled;
  }

  String _label(AppUpdateState state) => switch (state.phase) {
    UpdatePhase.checking => '取消检查',
    UpdatePhase.downloading => '取消下载',
    UpdatePhase.verifying => '取消校验',
    UpdatePhase.permissionRequired => '前往授权',
    UpdatePhase.installing => '等待系统安装',
    _ when state.apkPath != null => '安装更新',
    _ when state.release != null =>
      state.phase == UpdatePhase.error ? '重新下载' : '下载更新',
    _ => '检查更新',
  };

  void _activate(AppUpdateState state) {
    final controller = ref.read(appUpdateProvider.notifier);
    switch (state.phase) {
      case UpdatePhase.checking:
      case UpdatePhase.downloading:
      case UpdatePhase.verifying:
        controller.cancelTransfer();
      case UpdatePhase.permissionRequired:
        unawaited(controller.openPermissionSettings());
      case UpdatePhase.installing:
        break;
      default:
        if (state.apkPath != null) {
          unawaited(controller.install());
        } else if (state.release != null) {
          unawaited(controller.download());
        } else {
          unawaited(controller.check());
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appUpdateProvider);
    ref.listen(appUpdateProvider, (previous, next) {
      if (previous?.phase != next.phase &&
          (next.phase != UpdatePhase.downloading || _notes.hasFocus)) {
        _focusPrimary();
      }
    });
    final release = state.release;
    final size = MediaQuery.sizeOf(context);
    final padding = size.width < 520 ? 20.0 : 32.0;
    final primary = _UpdateButton(
      focusNode: _primary,
      autofocus: true,
      label: _label(state),
      onActivate: () => _activate(state),
    );
    final close = _UpdateButton(
      focusNode: _close,
      label:
          state.phase == UpdatePhase.downloading ||
              state.phase == UpdatePhase.verifying
          ? '取消并返回'
          : release == null || state.phase == UpdatePhase.installing
          ? '返回'
          : '稍后',
      onActivate: _leave,
    );
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) ref.read(appUpdateProvider.notifier).leaveDialog();
      },
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: _onKey,
        child: Dialog(
          insetPadding: const EdgeInsets.all(24),
          backgroundColor: AppColors.cardBackground,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 720,
              maxHeight: size.height - 48,
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.all(padding),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('软件更新', style: AppTypography.headline2),
                  if (state.installedVersion != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      '当前版本 v${state.installedVersion}',
                      style: AppTypography.body,
                    ),
                  ],
                  const SizedBox(height: 20),
                  Text(state.status, style: AppTypography.title),
                  if (release != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'v${release.versionName} · ${(release.size / (1024 * 1024)).toStringAsFixed(1)} MB',
                      style: AppTypography.body,
                    ),
                    if (release.releaseNotes.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      TvFocusable(
                        focusNode: _notes,
                        handleActivation: false,
                        builder: (_, focused) => TvFocusRing(
                          focused: focused,
                          selected: false,
                          padding: const EdgeInsets.all(16),
                          child: SizedBox(
                            height: math.min(
                              160,
                              math.max(48, size.height - 580),
                            ),
                            child: SingleChildScrollView(
                              controller: _notesScroll,
                              child: Text(
                                release.releaseNotes,
                                style: AppTypography.body,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text('↑ 查看更新说明，方向键滚动', style: AppTypography.body),
                    ],
                    // Reserve this space throughout the transfer, keeping the
                    // remote actions in place when progress appears/disappears.
                    const SizedBox(height: 20),
                    SizedBox(
                      height:
                          12 + MediaQuery.textScalerOf(context).scale(18) * 3,
                      child: state.phase == UpdatePhase.downloading
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                LinearProgressIndicator(
                                  value: state.received / release.size,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '${(100 * state.received / release.size).toStringAsFixed(0)}% · '
                                  '${(state.received / (1024 * 1024)).toStringAsFixed(1)} / '
                                  '${(release.size / (1024 * 1024)).toStringAsFixed(1)} MB',
                                  style: AppTypography.body,
                                ),
                              ],
                            )
                          : null,
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (size.width < 520)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [primary, const SizedBox(height: 12), close],
                    )
                  else
                    Row(
                      children: [
                        Expanded(child: primary),
                        const SizedBox(width: 16),
                        Expanded(child: close),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UpdateButton extends StatelessWidget {
  final FocusNode focusNode;
  final String label;
  final VoidCallback onActivate;
  final bool autofocus;

  const _UpdateButton({
    required this.focusNode,
    required this.label,
    required this.onActivate,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: TvFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      onActivate: onActivate,
      builder: (_, focused) => TvFocusRing(
        focused: focused,
        selected: false,
        background: AppColors.elevatedSurface,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: AppTypography.title,
        ),
      ),
    ),
  );
}

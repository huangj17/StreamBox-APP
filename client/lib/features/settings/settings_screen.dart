import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/image/image_cache_manager.dart';
import '../../core/platform/platform_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/cover/providers.dart';
import '../../widgets/tv_focus.dart';
import '../home/providers/categories_provider.dart';
import '../source/source_manage_page.dart';
import '../favorites/favorites_screen.dart';
import '../history/history_screen.dart';
part 'settings_panels.dart';

/// 设置页 — 左右分栏布局
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

enum _SettingsSection { source, player, cover, favorites, history, about }

extension on _SettingsSection {
  String get label => switch (this) {
    _SettingsSection.source => '配置源管理',
    _SettingsSection.player => '播放器设置',
    _SettingsSection.cover => '封面补全',
    _SettingsSection.favorites => '我的收藏',
    _SettingsSection.history => '播放历史',
    _SettingsSection.about => '关于',
  };

  IconData get icon => switch (this) {
    _SettingsSection.source => Icons.dns_outlined,
    _SettingsSection.player => Icons.play_circle_outline,
    _SettingsSection.cover => Icons.image_search,
    _SettingsSection.favorites => Icons.favorite_outline,
    _SettingsSection.history => Icons.history,
    _SettingsSection.about => Icons.info_outline,
  };
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  _SettingsSection? _selected;
  bool _detailFocused = false;
  final _sidebarNodes = {
    for (final section in _SettingsSection.values)
      section: FocusNode(debugLabel: 'settings-nav-${section.name}'),
  };
  final _backFocus = FocusNode(debugLabel: 'settings-back');
  final _sourceEntry = FocusNode(debugLabel: 'source-group-builtin');
  final _rightAnchor = FocusNode(
    debugLabel: 'settings-content',
    skipTraversal: true,
    canRequestFocus: false,
  );

  _SettingsSection get _effectiveSelected =>
      _selected ?? _SettingsSection.source;
  bool get _compact =>
      !PlatformService.isTv && MediaQuery.sizeOf(context).width < 720;

  @override
  void dispose() {
    for (final node in _sidebarNodes.values) {
      node.dispose();
    }
    _backFocus.dispose();
    _sourceEntry.dispose();
    _rightAnchor.dispose();
    super.dispose();
  }

  void _selectSection(_SettingsSection section) {
    setState(() => _selected = section);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (section == _SettingsSection.source) {
        _sourceEntry.requestFocus();
      } else {
        _rightAnchor.nextFocus();
      }
    });
  }

  void _returnToNavigation() {
    final section = _effectiveSelected;
    if (_compact) {
      setState(() => _selected = null);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sidebarNodes[section]!.requestFocus();
      });
    } else {
      _sidebarNodes[section]!.requestFocus();
    }
  }

  void _leaveSettings() {
    _backFocus.requestFocus();
    // Let PopScope observe the changed focus before a pointer-triggered pop.
    setState(() => _detailFocused = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.maybePop(context);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.gameButtonB) {
      if (_detailFocused || (_compact && _selected != null)) {
        _returnToNavigation();
      } else {
        Navigator.maybePop(context);
      }
      return KeyEventResult.handled;
    }
    final index = _SettingsSection.values.indexWhere(
      (s) => _sidebarNodes[s]!.hasFocus,
    );
    if (index < 0) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowRight) {
      _selectSection(_SettingsSection.values[index]);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _sidebarNodes[_SettingsSection.values[(index + 1).clamp(0, 5)]]!
          .requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (index == 0) {
        _backFocus.requestFocus();
      } else {
        _sidebarNodes[_SettingsSection.values[index - 1]]!.requestFocus();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _compact ? _selected == null : !_detailFocused,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _returnToNavigation();
      },
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: _onKey,
        child: _compact ? _buildCompact() : _buildWide(),
      ),
    );
  }

  Widget _sidebarItem(_SettingsSection section, {bool compact = false}) =>
      _SidebarItem(
        icon: section.icon,
        label: section.label,
        isSelected: !compact && _effectiveSelected == section,
        focusNode: _sidebarNodes[section],
        autofocus:
            PlatformService.needsFocusSystem && _effectiveSelected == section,
        onTap: () => _selectSection(section),
      );

  Widget _buildCompact() {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selected?.label ?? '设置'),
        leading: IconButton(
          focusNode: _backFocus,
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: '返回',
          onPressed: _selected == null
              ? () => Navigator.maybePop(context)
              : _returnToNavigation,
        ),
      ),
      body: SafeArea(
        child: _selected == null
            ? ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final section in _SettingsSection.values)
                    _sidebarItem(section, compact: true),
                ],
              )
            : _content(),
      ),
    );
  }

  Widget _buildWide() {
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(PlatformService.isTv ? 24 : 16),
          child: Row(
            children: [
              Container(
                width: width >= 1200 ? 256 : 224,
                decoration: BoxDecoration(
                  color: const Color(0xFF141416),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 16, 12, 24),
                      child: _SidebarItem(
                        icon: Icons.arrow_back_rounded,
                        label: '设置',
                        isSelected: false,
                        focusNode: _backFocus,
                        onTap: _leaveSettings,
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Column(
                          children: [
                            for (final section in _SettingsSection.values) ...[
                              if (section == _SettingsSection.about)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  child: Divider(color: AppColors.divider),
                                ),
                              _sidebarItem(section),
                            ],
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(
                        'STREAMBOX',
                        style: AppTypography.caption.copyWith(
                          letterSpacing: 3,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: _content()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content() => FocusTraversalGroup(
    policy: ReadingOrderTraversalPolicy(),
    child: Focus(
      focusNode: _rightAnchor,
      onFocusChange: (focused) {
        if (mounted && focused != _detailFocused) {
          setState(() => _detailFocused = focused);
        }
      },
      child: switch (_effectiveSelected) {
        _SettingsSection.source => SourceManagePage(
          embedded: true,
          entryFocusNode: _sourceEntry,
          onBackToNavigation: _returnToNavigation,
        ),
        _SettingsSection.player => const _PlayerSettingsPanel(),
        _SettingsSection.cover => const _CoverSettingsPanel(),
        _SettingsSection.favorites => const FavoritesScreen(embedded: true),
        _SettingsSection.history => const HistoryScreen(embedded: true),
        _SettingsSection.about => const _AboutPanel(),
      },
    ),
  );
}

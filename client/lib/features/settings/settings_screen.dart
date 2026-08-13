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
  /// 手机：null 表示在「列表」状态，非空表示已进入某个二级页
  /// 桌面/平板：null 时视为默认选中「配置源」，由 `_effectiveSelected` 统一处理
  _SettingsSection? _selected;

  _SettingsSection get _effectiveSelected =>
      _selected ?? _SettingsSection.source;

  /// 右栏 traversal 锚点 — 不参与遍历但作为 [nextFocus] 起点。
  /// 不用 [FocusScope]：FocusScope 是 directional traversal 边界，会让 ← 进不到左栏。
  final FocusNode _rightAnchor = FocusNode(
    debugLabel: 'settings-right-anchor',
    skipTraversal: true,
    canRequestFocus: false,
  );

  @override
  void dispose() {
    _rightAnchor.dispose();
    super.dispose();
  }

  void _selectSection(_SettingsSection s) {
    setState(() => _selected = s);
    if (!PlatformService.needsFocusSystem) return;
    // 等右栏内容重建后再请求焦点
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _rightAnchor.nextFocus();
    });
  }

  static const _sections = [
    _SettingsSection.source,
    _SettingsSection.player,
    _SettingsSection.cover,
    _SettingsSection.favorites,
    _SettingsSection.history,
  ];

  @override
  Widget build(BuildContext context) {
    final isCompact = MediaQuery.sizeOf(context).width < 600;

    if (isCompact) {
      return _buildCompact();
    }
    return _buildWide();
  }

  Widget _buildCompact() {
    // 手机端：未选中时显示列表；已选中时显示详情面板（带返回）
    if (_selected == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: ListView(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          children: [
            for (final s in _sections)
              _SidebarItem(
                icon: s.icon,
                label: s.label,
                isSelected: false,
                onTap: () => _selectSection(s),
              ),
            const Padding(
              padding: EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Divider(color: AppColors.divider),
            ),
            _SidebarItem(
              icon: _SettingsSection.about.icon,
              label: _SettingsSection.about.label,
              isSelected: false,
              onTap: () => _selectSection(_SettingsSection.about),
            ),
          ],
        ),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() => _selected = null);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_selected!.label),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() => _selected = null),
          ),
        ),
        body: _buildDetailPanel(),
      ),
    );
  }

  Widget _buildWide() {
    // TV / 桌面键盘模式下进页面把默认焦点放在当前选中的侧栏项上，
    // 不然用户按方向键不知道从哪儿开始
    final autofocusSidebar = PlatformService.needsFocusSystem;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Row(
        children: [
          SizedBox(
            width: AppSpacing.settingsSidebarWidth,
            child: Container(
              color: AppColors.cardBackground,
              child: FocusTraversalGroup(
                policy: OrderedTraversalPolicy(),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                  children: [
                    for (final s in _sections)
                      _SidebarItem(
                        icon: s.icon,
                        label: s.label,
                        isSelected: _effectiveSelected == s,
                        autofocus: autofocusSidebar && _effectiveSelected == s,
                        onTap: () => _selectSection(s),
                      ),
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.sm,
                      ),
                      child: Divider(color: AppColors.divider),
                    ),
                    _SidebarItem(
                      icon: _SettingsSection.about.icon,
                      label: _SettingsSection.about.label,
                      isSelected: _effectiveSelected == _SettingsSection.about,
                      autofocus:
                          autofocusSidebar &&
                          _effectiveSelected == _SettingsSection.about,
                      onTap: () => _selectSection(_SettingsSection.about),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const VerticalDivider(width: 1, color: AppColors.divider),
          Expanded(
            child: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: Focus(
                focusNode: _rightAnchor,
                skipTraversal: true,
                canRequestFocus: false,
                child: _buildDetailPanel(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailPanel() {
    switch (_effectiveSelected) {
      case _SettingsSection.source:
        return const _SourcePanel();
      case _SettingsSection.player:
        return const _PlayerSettingsPanel();
      case _SettingsSection.cover:
        return const _CoverSettingsPanel();
      case _SettingsSection.favorites:
        return const FavoritesScreen(embedded: true);
      case _SettingsSection.history:
        return const HistoryScreen(embedded: true);
      case _SettingsSection.about:
        return const _AboutPanel();
    }
  }
}

/// 左侧栏项目

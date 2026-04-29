import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/platform/platform_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/cover/providers.dart';
import '../home/providers/categories_provider.dart';
import '../source/source_manage_page.dart';
import '../favorites/favorites_screen.dart';
import '../history/history_screen.dart';

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
                onTap: () => setState(() => _selected = s),
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
              onTap: () =>
                  setState(() => _selected = _SettingsSection.about),
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
              child: ListView(
                padding:
                    const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                children: [
                  for (final s in _sections)
                    _SidebarItem(
                      icon: s.icon,
                      label: s.label,
                      isSelected: _effectiveSelected == s,
                      autofocus:
                          autofocusSidebar && _effectiveSelected == s,
                      onTap: () => setState(() => _selected = s),
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
                    autofocus: autofocusSidebar &&
                        _effectiveSelected == _SettingsSection.about,
                    onTap: () =>
                        setState(() => _selected = _SettingsSection.about),
                  ),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1, color: AppColors.divider),
          Expanded(child: _buildDetailPanel()),
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
class _SidebarItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final bool autofocus;

  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = widget.isSelected || _focused;
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Material(
        color: _focused
            ? AppColors.netflixRed.withAlpha(40)
            : (widget.isSelected ? AppColors.surface : Colors.transparent),
        child: InkWell(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: widget.isSelected || _focused
                      ? AppColors.netflixRed
                      : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  widget.icon,
                  color: highlighted
                      ? AppColors.primaryText
                      : AppColors.secondaryText,
                  size: 22,
                ),
                const SizedBox(width: AppSpacing.md),
                Text(
                  widget.label,
                  style: AppTypography.body.copyWith(
                    color: highlighted
                        ? AppColors.primaryText
                        : AppColors.secondaryText,
                    fontWeight:
                        highlighted ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 配置源面板（复用 SourceManagePage 的内容，去掉 Scaffold）
class _SourcePanel extends StatelessWidget {
  const _SourcePanel();

  @override
  Widget build(BuildContext context) {
    return const SourceManagePage(embedded: true);
  }
}

/// 播放器设置面板
class _PlayerSettingsPanel extends ConsumerStatefulWidget {
  const _PlayerSettingsPanel();

  @override
  ConsumerState<_PlayerSettingsPanel> createState() =>
      _PlayerSettingsPanelState();
}

class _PlayerSettingsPanelState extends ConsumerState<_PlayerSettingsPanel> {
  @override
  Widget build(BuildContext context) {
    final storage = ref.watch(playerSettingsStorageProvider);

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text('播放器设置', style: AppTypography.headline2),
        const SizedBox(height: AppSpacing.lg),

        // 硬件解码开关
        //
        // 移动 / TV 端走 video_player（ExoPlayer / AVPlayer），默认就是系统
        // 硬解，该开关无意义 → 置灰。桌面端走 media_kit (libmpv)，开关控制
        // libmpv 的 `hwdec` 属性（auto-safe vs no）。
        () {
          final isNative =
              PlatformService.isMobile || PlatformService.isTv;
          return _SettingsTile(
            icon: Icons.memory,
            title: '硬件解码',
            subtitle: isNative
                ? '移动 / TV 端始终硬解'
                : storage.hardwareDecode
                    ? '已开启（推荐）'
                    : '已关闭（使用软件解码）',
            trailing: Switch(
              value: isNative ? true : storage.hardwareDecode,
              activeThumbColor: AppColors.netflixRed,
              activeTrackColor: AppColors.netflixRed.withAlpha(102),
              onChanged: isNative
                  ? null
                  : (v) {
                      setState(() => storage.hardwareDecode = v);
                    },
            ),
          );
        }(),
        const Divider(color: AppColors.divider),

        // 默认播放倍速
        _SettingsTile(
          icon: Icons.speed,
          title: '默认播放倍速',
          subtitle: '${storage.defaultSpeed}x',
          trailing: _SpeedSelector(
            value: storage.defaultSpeed,
            onChanged: (v) {
              setState(() => storage.defaultSpeed = v);
            },
          ),
        ),
      ],
    );
  }
}

/// 封面补全面板：配置第三方封面查询（TMDB）
class _CoverSettingsPanel extends ConsumerStatefulWidget {
  const _CoverSettingsPanel();

  @override
  ConsumerState<_CoverSettingsPanel> createState() =>
      _CoverSettingsPanelState();
}

class _CoverSettingsPanelState extends ConsumerState<_CoverSettingsPanel> {
  late final TextEditingController _tmdbCtrl;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    final storage = ref.read(appSettingsStorageProvider);
    _tmdbCtrl = TextEditingController(text: storage.tmdbApiKey);
  }

  @override
  void dispose() {
    _tmdbCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text('封面补全', style: AppTypography.headline2),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '片源没有封面时，StreamBox 会按「豆瓣 → TMDB → Bing 图片」依次搜索。'
          '豆瓣和 Bing 国内可直连、无需配置；TMDB 对海外片更精准但需要能访问 '
          'themoviedb.org（国内常不通，建议留空跳过，或填 key 并配合代理）。'
          '都查不到时使用渐变首字海报占位。',
          style: AppTypography.body.copyWith(color: AppColors.secondaryText),
        ),
        const SizedBox(height: AppSpacing.xl),

        Text('TMDB API Key', style: AppTypography.title),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '免费申请：https://www.themoviedb.org/settings/api',
          style: AppTypography.caption
              .copyWith(color: AppColors.hintText),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _tmdbCtrl,
          obscureText: _obscure,
          style: AppTypography.body,
          decoration: InputDecoration(
            hintText: '粘贴 TMDB v3 API Key（32 位）',
            hintStyle: AppTypography.body
                .copyWith(color: AppColors.hintText),
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide.none,
            ),
            suffixIcon: IconButton(
              icon: Icon(
                _obscure ? Icons.visibility_off : Icons.visibility,
                color: AppColors.hintText,
                size: 20,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          onChanged: (v) {
            ref.read(appSettingsStorageProvider).tmdbApiKey = v;
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '国内直连不通时留空即可，链路会跳过 TMDB 直接用豆瓣 / Bing。',
          style: AppTypography.caption
              .copyWith(color: AppColors.hintText),
        ),
        const SizedBox(height: AppSpacing.xl),
        const Divider(color: AppColors.divider),
        const SizedBox(height: AppSpacing.lg),

        Text('封面缓存', style: AppTypography.title),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '修改 API Key 后，先前查不到的封面会被缓存 24 小时。点击下方按钮立即清除，'
          '页面会自动重试解析。',
          style: AppTypography.caption
              .copyWith(color: AppColors.hintText),
        ),
        const SizedBox(height: AppSpacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('清除封面缓存并重试'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.surface,
              foregroundColor: AppColors.primaryText,
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: 10),
            ),
            onPressed: () async {
              await ref.read(coverCacheProvider).clearMisses();
              ref.read(coverCacheVersionProvider.notifier).state++;
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('封面缓存已清除，已自动重新拉取'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          Icon(icon, color: AppColors.secondaryText, size: 24),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTypography.title),
                const SizedBox(height: AppSpacing.xs),
                Text(subtitle,
                    style: AppTypography.caption
                        .copyWith(color: AppColors.secondaryText)),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}

class _SpeedSelector extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const _SpeedSelector({required this.value, required this.onChanged});

  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    return DropdownButton<double>(
      value: _speeds.contains(value) ? value : 1.0,
      dropdownColor: AppColors.surface,
      underline: const SizedBox.shrink(),
      items: _speeds
          .map((s) => DropdownMenuItem(
                value: s,
                child: Text('${s}x',
                    style: AppTypography.body.copyWith(
                        color: s == value
                            ? AppColors.netflixRed
                            : AppColors.primaryText)),
              ))
          .toList(),
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

/// 关于面板
class _AboutPanel extends StatefulWidget {
  const _AboutPanel();

  @override
  State<_AboutPanel> createState() => _AboutPanelState();
}

class _AboutPanelState extends State<_AboutPanel> {
  int _imageCacheBytes = 0;
  int _tempCacheBytes = 0;
  bool _loading = true;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _calcCacheSize();
  }

  Future<void> _calcCacheSize() async {
    setState(() => _loading = true);

    int imageBytes = 0;
    int tempBytes = 0;

    try {
      // 图片缓存（cached_network_image 使用 flutter_cache_manager）
      final cacheDir = await getTemporaryDirectory();
      imageBytes = await _dirSize(cacheDir);
    } catch (_) {}

    try {
      // 应用文档目录中的 Hive 临时文件（.lock）
      final docDir = await getApplicationDocumentsDirectory();
      final lockFiles = docDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.lock'));
      for (final f in lockFiles) {
        tempBytes += await f.length();
      }
    } catch (_) {}

    if (mounted) {
      setState(() {
        _imageCacheBytes = imageBytes;
        _tempCacheBytes = tempBytes;
        _loading = false;
      });
    }
  }

  Future<int> _dirSize(Directory dir) async {
    int total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          total += await entity.length();
        }
      }
    } catch (_) {}
    return total;
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _clearCache() async {
    setState(() => _clearing = true);

    try {
      // 清除图片缓存
      await DefaultCacheManager().emptyCache();
      // 清除临时目录
      final cacheDir = await getTemporaryDirectory();
      if (cacheDir.existsSync()) {
        await for (final entity
            in cacheDir.list(recursive: false, followLinks: false)) {
          try {
            await entity.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}

    // 重新计算
    await _calcCacheSize();

    if (mounted) {
      setState(() => _clearing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('缓存已清除')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalBytes = _imageCacheBytes + _tempCacheBytes;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        // App 信息
        Center(
          child: Column(
            children: [
              Text(
                'StreamBox',
                style: AppTypography.display
                    .copyWith(color: AppColors.netflixRed),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'v1.0',
                style: AppTypography.headline2
                    .copyWith(color: AppColors.secondaryText),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Netflix 风格流媒体播放器',
                style: AppTypography.body
                    .copyWith(color: AppColors.secondaryText),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '基于苹果 CMS API + media_kit',
                style: AppTypography.caption
                    .copyWith(color: AppColors.hintText),
              ),
            ],
          ),
        ),

        const SizedBox(height: AppSpacing.xxl),
        const Divider(color: AppColors.divider),
        const SizedBox(height: AppSpacing.lg),

        // 缓存管理
        Text('存储', style: AppTypography.headline2),
        const SizedBox(height: AppSpacing.lg),

        _SettingsTile(
          icon: Icons.cached,
          title: '缓存大小',
          subtitle: _loading ? '计算中...' : _formatSize(totalBytes),
          trailing: ElevatedButton(
            onPressed: _clearing || _loading ? null : _clearCache,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.surface,
              foregroundColor: AppColors.primaryText,
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 8),
            ),
            child: _clearing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.netflixRed,
                    ),
                  )
                : const Text('清除缓存'),
          ),
        ),

        if (!_loading && _imageCacheBytes > 0) ...[
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: Text(
              '图片缓存: ${_formatSize(_imageCacheBytes)}',
              style: AppTypography.caption
                  .copyWith(color: AppColors.hintText),
            ),
          ),
        ],

        const SizedBox(height: AppSpacing.xxl),
        Center(
          child: Text(
            'Built with Flutter',
            style: AppTypography.caption
                .copyWith(color: AppColors.hintText),
          ),
        ),
      ],
    );
  }
}

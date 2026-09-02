part of 'settings_screen.dart';

class _SidebarItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  final bool autofocus;

  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.focusNode,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        selected: isSelected,
        child: TvFocusable(
          focusNode: focusNode,
          autofocus: autofocus,
          onActivate: onTap,
          builder: (context, focused) => AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            constraints: const BoxConstraints(minHeight: 60),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: focused
                  ? const Color(0xFF333338)
                  : isSelected
                  ? const Color(0xFF341A20)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: focused ? Colors.white : Colors.transparent,
                width: 2,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 23,
                  color: isSelected
                      ? const Color(0xFFFF5360)
                      : focused
                      ? Colors.white
                      : AppColors.secondaryText,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: AppTypography.body.copyWith(
                      color: focused || isSelected
                          ? Colors.white
                          : AppColors.secondaryText,
                      fontWeight: focused || isSelected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
                if (isSelected)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(
                      Icons.circle,
                      size: 6,
                      color: Color(0xFFFF5360),
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

    final isNative = PlatformService.isMobile || PlatformService.isTv;
    final hwdecEnabled = isNative ? true : storage.hardwareDecode;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text('播放器设置', style: AppTypography.headline2),
        const SizedBox(height: AppSpacing.lg),

        // 硬件解码开关 — TV 端 OK 切换；移动/TV 平台始终硬解时禁用
        TvFocusable(
          debugLabel: 'hwdec-toggle',
          onActivate: isNative
              ? null
              : () => setState(() => storage.hardwareDecode = !hwdecEnabled),
          builder: (context, focused) {
            return _FocusableTile(
              focused: focused,
              icon: Icons.memory,
              title: '硬件解码',
              subtitle: isNative
                  ? '移动 / TV 端始终硬解'
                  : hwdecEnabled
                  ? '已开启（推荐）'
                  : '已关闭（使用软件解码）',
              trailing: ExcludeFocus(
                child: Switch(
                  value: hwdecEnabled,
                  activeThumbColor: AppColors.netflixRed,
                  activeTrackColor: AppColors.netflixRed.withAlpha(102),
                  onChanged: isNative
                      ? null
                      : (v) => setState(() => storage.hardwareDecode = v),
                ),
              ),
            );
          },
        ),
        const Divider(color: AppColors.divider),

        // 默认播放倍速 — 横向 Chip 行，方向键选择
        _SpeedRow(
          value: storage.defaultSpeed,
          onChanged: (v) => setState(() => storage.defaultSpeed = v),
        ),
      ],
    );
  }
}

/// 设置页内带焦点高亮的一行
class _FocusableTile extends StatelessWidget {
  final bool focused;
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;

  const _FocusableTile({
    required this.focused,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: focused ? AppColors.netflixRed : Colors.transparent,
          width: 1,
        ),
        boxShadow: focused
            ? [
                BoxShadow(
                  color: AppColors.netflixRed.withAlpha(80),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
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
                Text(
                  subtitle,
                  style: AppTypography.caption.copyWith(
                    color: AppColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}

/// 倍速横向 Chip 行 — 替换原 DropdownButton（TV 上 Dropdown 体验差）
class _SpeedRow extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const _SpeedRow({required this.value, required this.onChanged});

  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.speed, color: AppColors.secondaryText, size: 24),
              const SizedBox(width: AppSpacing.md),
              Text('默认播放倍速', style: AppTypography.title),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.only(left: 36),
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final s in _speeds)
                  _SpeedChip(
                    speed: s,
                    selected: s == value,
                    onActivate: () => onChanged(s),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SpeedChip extends StatelessWidget {
  final double speed;
  final bool selected;
  final VoidCallback onActivate;

  const _SpeedChip({
    required this.speed,
    required this.selected,
    required this.onActivate,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      debugLabel: 'speed-${speed}x',
      onActivate: onActivate,
      builder: (context, focused) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? AppColors.netflixRed : AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: focused
                  ? AppColors.netflixRed
                  : (selected ? AppColors.netflixRed : AppColors.divider),
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: AppColors.netflixRed.withAlpha(100),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Text(
            '${speed}x',
            style: AppTypography.caption.copyWith(
              color: selected ? Colors.white : AppColors.primaryText,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        );
      },
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
  final FocusNode _tmdbFocus = FocusNode(debugLabel: 'tmdb-key');
  bool _obscure = true;
  bool _tmdbFocused = false;

  @override
  void initState() {
    super.initState();
    final storage = ref.read(appSettingsStorageProvider);
    _tmdbCtrl = TextEditingController(text: storage.tmdbApiKey);
    _tmdbFocus.addListener(_onTmdbFocus);
  }

  @override
  void dispose() {
    _tmdbFocus.removeListener(_onTmdbFocus);
    _tmdbFocus.dispose();
    _tmdbCtrl.dispose();
    super.dispose();
  }

  void _onTmdbFocus() {
    if (_tmdbFocus.hasFocus == _tmdbFocused) return;
    setState(() => _tmdbFocused = _tmdbFocus.hasFocus);
  }

  Future<void> _clearCoverCache() async {
    await ref.read(coverCacheProvider).clearMisses();
    ref.read(coverCacheVersionProvider.notifier).state++;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('封面缓存已清除，已自动重新拉取'),
        duration: Duration(seconds: 2),
      ),
    );
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
          style: AppTypography.caption.copyWith(color: AppColors.hintText),
        ),
        const SizedBox(height: AppSpacing.sm),
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            boxShadow: _tmdbFocused
                ? [
                    BoxShadow(
                      color: AppColors.netflixRed.withAlpha(100),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: TextField(
            controller: _tmdbCtrl,
            focusNode: _tmdbFocus,
            obscureText: _obscure,
            style: AppTypography.body,
            decoration: InputDecoration(
              hintText: '粘贴 TMDB v3 API Key（32 位）',
              hintStyle: AppTypography.body.copyWith(color: AppColors.hintText),
              filled: true,
              fillColor: AppColors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(
                  color: AppColors.netflixRed,
                  width: 1.5,
                ),
              ),
              suffixIcon: ExcludeFocus(
                child: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility_off : Icons.visibility,
                    color: AppColors.hintText,
                    size: 20,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            onChanged: (v) {
              ref.read(appSettingsStorageProvider).tmdbApiKey = v;
            },
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '国内直连不通时留空即可，链路会跳过 TMDB 直接用豆瓣 / Bing。',
          style: AppTypography.caption.copyWith(color: AppColors.hintText),
        ),
        const SizedBox(height: AppSpacing.xl),
        const Divider(color: AppColors.divider),
        const SizedBox(height: AppSpacing.lg),

        Text('封面缓存', style: AppTypography.title),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '修改 API Key 后，先前查不到的封面会被缓存 24 小时。点击下方按钮立即清除，'
          '页面会自动重试解析。',
          style: AppTypography.caption.copyWith(color: AppColors.hintText),
        ),
        const SizedBox(height: AppSpacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: _ActionButton(
            icon: Icons.refresh,
            label: '清除封面缓存并重试',
            onActivate: _clearCoverCache,
          ),
        ),
      ],
    );
  }
}

/// TV 焦点感知的次级按钮（图标 + 文本）
class _ActionButton extends StatelessWidget {
  final IconData? icon;
  final String label;
  final VoidCallback? onActivate;
  final Widget? leading;

  const _ActionButton({
    this.icon,
    required this.label,
    required this.onActivate,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      debugLabel: 'action-$label',
      onActivate: onActivate,
      builder: (context, focused) {
        final disabled = onActivate == null;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 10,
          ),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: focused ? AppColors.netflixRed : Colors.transparent,
              width: 1,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: AppColors.netflixRed.withAlpha(100),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: AppSpacing.sm),
              ] else if (icon != null) ...[
                Icon(
                  icon,
                  size: 18,
                  color: disabled ? AppColors.hintText : AppColors.primaryText,
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              Text(
                label,
                style: AppTypography.body.copyWith(
                  color: disabled ? AppColors.hintText : AppColors.primaryText,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        );
      },
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
                Text(
                  subtitle,
                  style: AppTypography.caption.copyWith(
                    color: AppColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
          trailing,
        ],
      ),
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
  String _version = '0.2.0';

  @override
  void initState() {
    super.initState();
    _calcCacheSize();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = info.version);
    } catch (error) {
      debugPrint('读取应用版本失败: $error');
    }
  }

  Future<void> _calcCacheSize() async {
    setState(() => _loading = true);

    int imageBytes = 0;
    int tempBytes = 0;

    try {
      // 图片缓存（cached_network_image 使用 flutter_cache_manager）
      imageBytes = await _dirSize(await _imageCacheDirectory());
    } catch (error) {
      debugPrint('计算图片缓存失败: $error');
    }

    try {
      // 应用文档目录中的 Hive 临时文件（.lock）
      final docDir = await getApplicationDocumentsDirectory();
      final lockFiles = docDir.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.lock'),
      );
      for (final f in lockFiles) {
        tempBytes += await f.length();
      }
    } catch (error) {
      debugPrint('计算临时文件失败: $error');
    }

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
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          total += await entity.length();
        }
      }
    } catch (error) {
      debugPrint('遍历缓存目录失败: $error');
    }
    return total;
  }

  Future<Directory> _imageCacheDirectory() async {
    final temporary = await getTemporaryDirectory();
    return Directory(
      '${temporary.path}${Platform.pathSeparator}${AppImageCacheManager.key}',
    );
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
      // ResolvableCover 使用专用 CacheManager；只清它的目录，避免误删
      // video_player、插件或系统放在临时目录中的活跃文件。
      await AppImageCacheManager().emptyCache();
    } catch (error) {
      debugPrint('清除图片缓存失败: $error');
    }

    // 重新计算
    await _calcCacheSize();

    if (mounted) {
      setState(() => _clearing = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('缓存已清除')));
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
                style: AppTypography.display.copyWith(
                  color: AppColors.netflixRed,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'v$_version',
                style: AppTypography.headline2.copyWith(
                  color: AppColors.secondaryText,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Netflix 风格流媒体播放器',
                style: AppTypography.body.copyWith(
                  color: AppColors.secondaryText,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '基于苹果 CMS API + media_kit',
                style: AppTypography.caption.copyWith(
                  color: AppColors.hintText,
                ),
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
          trailing: _ActionButton(
            label: _clearing ? '清除中...' : '清除缓存',
            leading: _clearing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.netflixRed,
                    ),
                  )
                : const Icon(
                    Icons.delete_sweep_outlined,
                    size: 18,
                    color: AppColors.primaryText,
                  ),
            onActivate: _clearing || _loading ? null : _clearCache,
          ),
        ),

        if (!_loading && _imageCacheBytes > 0) ...[
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: Text(
              '图片缓存: ${_formatSize(_imageCacheBytes)}',
              style: AppTypography.caption.copyWith(color: AppColors.hintText),
            ),
          ),
        ],

        const SizedBox(height: AppSpacing.xxl),
        Center(
          child: Text(
            'Built with Flutter',
            style: AppTypography.caption.copyWith(color: AppColors.hintText),
          ),
        ),
      ],
    );
  }
}

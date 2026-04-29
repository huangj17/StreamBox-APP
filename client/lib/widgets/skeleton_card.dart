import 'package:flutter/material.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_radius.dart';
import '../core/theme/app_spacing.dart';
import '../core/platform/platform_service.dart';

/// 骨架屏卡片（加载态占位）
class SkeletonCard extends StatefulWidget {
  final double width;
  final double height;

  const SkeletonCard({
    super.key,
    this.width = AppSpacing.cardWidth,
    this.height = AppSpacing.cardHeight,
  });

  @override
  State<SkeletonCard> createState() => _SkeletonCardState();
}

class _SkeletonCardState extends State<SkeletonCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.3, end: 0.6).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: AppRadius.cardBorder,
            color: AppColors.cardBackground.withAlpha((_animation.value * 255).round()),
          ),
        );
      },
    );
  }
}

/// 骨架屏 Banner（Netflix 风格加载占位）
class SkeletonBanner extends StatefulWidget {
  const SkeletonBanner({super.key});

  @override
  State<SkeletonBanner> createState() => _SkeletonBannerState();
}

class _SkeletonBannerState extends State<SkeletonBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.15, end: 0.35).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = PlatformService.isMobile;
    final bannerHeight = isMobile ? 320.0 : AppSpacing.heroBannerHeight;
    final leftInset = isMobile ? AppSpacing.lg : AppSpacing.xl + 56;
    final bottomInset = isMobile ? AppSpacing.lg : AppSpacing.xxl;
    final titleW = isMobile ? 200.0 : 280.0;
    final titleH = isMobile ? 24.0 : 36.0;
    final subtitleW = isMobile ? 140.0 : 180.0;
    final desc1W = isMobile ? 220.0 : 320.0;
    final desc2W = isMobile ? 160.0 : 240.0;
    final btnW = isMobile ? 76.0 : 100.0;
    final btnH = isMobile ? 32.0 : 40.0;

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          height: bannerHeight,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppColors.cardBackground.withAlpha((_animation.value * 255).round()),
                AppColors.cardBackground,
              ],
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                left: leftInset,
                bottom: bottomInset,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: titleW,
                      height: titleH,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        color: Colors.white.withAlpha((_animation.value * 80).round()),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: subtitleW,
                      height: 16,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        color: Colors.white.withAlpha((_animation.value * 50).round()),
                      ),
                    ),
                    if (!isMobile) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: desc1W,
                        height: 14,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          color: Colors.white.withAlpha((_animation.value * 40).round()),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: desc2W,
                        height: 14,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          color: Colors.white.withAlpha((_animation.value * 40).round()),
                        ),
                      ),
                    ],
                    SizedBox(height: isMobile ? 12 : 20),
                    Row(
                      children: [
                        Container(
                          width: btnW,
                          height: btnH,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            color: Colors.white.withAlpha((_animation.value * 60).round()),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          width: btnW,
                          height: btnH,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            color: Colors.white.withAlpha((_animation.value * 40).round()),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 骨架屏行（一行多个骨架卡片）
class SkeletonRail extends StatelessWidget {
  final int cardCount;

  const SkeletonRail({super.key, this.cardCount = 6});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppSpacing.cardHeight + AppSpacing.lg + 28, // 卡片高 + 行标题
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题骨架
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.xl),
            child: Container(
              width: 120,
              height: 28,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: AppColors.cardBackground,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          // 卡片行骨架
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
              itemCount: cardCount,
              separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
              itemBuilder: (_, _) => const SkeletonCard(),
            ),
          ),
        ],
      ),
    );
  }
}

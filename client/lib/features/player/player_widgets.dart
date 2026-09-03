part of 'player_screen.dart';

class _LoadingOverlay extends StatelessWidget {
  final String title;
  final String episodeName;
  final String sourceName;
  final int bufferingSeconds;
  final int? speedBps;

  const _LoadingOverlay({
    required this.title,
    required this.episodeName,
    required this.sourceName,
    this.bufferingSeconds = 0,
    this.speedBps,
  });

  @override
  Widget build(BuildContext context) {
    final parts = <String>['正在缓冲'];
    if (bufferingSeconds >= 2) parts.add('等待 $bufferingSeconds 秒');
    final speedLabel = NetworkSpeedMonitor.format(speedBps);
    if (speedLabel.isNotEmpty) parts.add('应用下行 $speedLabel');
    final statusLine = parts.join(' · ');

    return SizedBox.expand(
      child: Container(
        color: Colors.black54,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.headline2,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(episodeName, style: AppTypography.body),
            const SizedBox(height: AppSpacing.lg),
            const SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                color: AppColors.netflixRed,
                strokeWidth: 3,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(sourceName, style: AppTypography.caption),
            if (statusLine.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                statusLine,
                style: AppTypography.caption.copyWith(
                  color: AppColors.secondaryText,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RebufferIndicator extends StatelessWidget {
  final int bufferingSeconds;
  final int? speedBps;

  const _RebufferIndicator({
    required this.bufferingSeconds,
    required this.speedBps,
  });

  @override
  Widget build(BuildContext context) {
    final parts = <String>['正在缓冲'];
    if (bufferingSeconds >= 2) parts.add('等待 $bufferingSeconds 秒');
    final speedLabel = NetworkSpeedMonitor.format(speedBps);
    if (speedLabel.isNotEmpty) parts.add('应用下行 $speedLabel');
    return Align(
      alignment: Alignment.topRight,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.only(
            top: AppSpacing.sm,
            right: AppSpacing.md,
            left: AppSpacing.md,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.70),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  color: AppColors.netflixRed,
                  strokeWidth: 2,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Text(
                  parts.join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.caption.copyWith(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

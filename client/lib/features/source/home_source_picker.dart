import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../data/models/source_health.dart';
import '../../widgets/tv_button.dart';
import '../home/providers/categories_provider.dart';
import 'providers/source_library_provider.dart';
import 'providers/source_provider.dart';

class HomeSourcePicker extends ConsumerWidget {
  const HomeSourcePicker({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sites = ref.watch(sitesProvider);
    final selected = ref.watch(homeSitesProvider).firstOrNull;
    if (sites.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: TvActionButton.text(
          icon: Icons.swap_horiz,
          label: '首页片源：${selected?.name ?? '暂无可用源'}',
          onActivate: () => showDialog<void>(
            context: context,
            builder: (_) => Consumer(
              builder: (context, dialogRef, _) {
                final health = dialogRef.watch(sourceHealthProvider);
                final current = dialogRef.watch(homeSitesProvider).firstOrNull;
                return SimpleDialog(
                  title: const Text('选择首页片源'),
                  children: [
                    for (final site in dialogRef.watch(sitesProvider))
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: TvActionButton.text(
                          icon: current?.identity == site.identity
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                          label: site.name,
                          onActivate:
                              health[site.api]?.status ==
                                  SourceHealthStatus.unavailable
                              ? null
                              : () {
                                  dialogRef
                                      .read(sourceLibraryProvider.notifier)
                                      .selectHome(site);
                                  Navigator.pop(context);
                                },
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '搜索仍使用所有已启用片源',
                        style: AppTypography.caption.copyWith(
                          color: AppColors.secondaryText,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

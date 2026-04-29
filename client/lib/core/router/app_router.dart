import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:go_router/go_router.dart';
import '../../data/models/site.dart';
import '../../data/models/category.dart';
import '../../data/models/episode.dart';
import '../../features/home/home_screen.dart';
import '../../features/home/category_detail_screen.dart';
import '../../features/detail/detail_screen.dart';
import '../../features/player/player_screen.dart';
import '../../features/search/search_screen.dart';
import '../../features/source/source_manage_page.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/favorites/favorites_screen.dart';
import '../../features/history/history_screen.dart';

/// StreamBox 路由配置
final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      pageBuilder: (context, state) => _buildPage(
        const HomeScreen(),
        state,
      ),
    ),
    GoRoute(
      path: '/detail',
      pageBuilder: (context, state) {
        final extra = state.extra as Map<String, dynamic>;
        return _buildPage(
          DetailScreen(
            site: extra['site'] as Site,
            videoId: extra['videoId'] as String,
            initialGroupIndex: extra['initialGroupIndex'] as int?,
            initialEpisodeIndex: extra['initialEpisodeIndex'] as int?,
            initialPositionMs: extra['initialPositionMs'] as int?,
          ),
          state,
        );
      },
    ),
    GoRoute(
      path: '/player',
      pageBuilder: (context, state) {
        final extra = state.extra as Map<String, dynamic>;
        return _buildPage(
          PlayerScreen(
            videoId: extra['videoId'] as String,
            siteKey: extra['siteKey'] as String,
            videoTitle: extra['videoTitle'] as String,
            cover: extra['cover'] as String? ?? '',
            episodeGroups:
                extra['episodeGroups'] as List<List<Episode>>,
            sourceNames:
                (extra['sourceNames'] as List).cast<String>(),
            initialGroupIndex: extra['initialGroupIndex'] as int? ?? 0,
            initialEpisodeIndex: extra['initialEpisodeIndex'] as int? ?? 0,
            initialPositionMs: extra['initialPositionMs'] as int? ?? 0,
            category: extra['category'] as String?,
          ),
          state,
        );
      },
    ),
    GoRoute(
      path: '/category',
      pageBuilder: (context, state) {
        final extra = state.extra as Map<String, dynamic>;
        return _buildPage(
          CategoryDetailScreen(
            category: extra['category'] as Category,
            site: extra['site'] as Site,
          ),
          state,
        );
      },
    ),
    GoRoute(
      path: '/search',
      pageBuilder: (context, state) => _buildPage(
        const SearchScreen(),
        state,
      ),
    ),
    GoRoute(
      path: '/source',
      pageBuilder: (context, state) => _buildPage(
        const SourceManagePage(),
        state,
      ),
    ),
    GoRoute(
      path: '/settings',
      pageBuilder: (context, state) => _buildPage(
        const SettingsScreen(),
        state,
      ),
    ),
    GoRoute(
      path: '/favorites',
      pageBuilder: (context, state) => _buildPage(
        const FavoritesScreen(),
        state,
      ),
    ),
    GoRoute(
      path: '/history',
      pageBuilder: (context, state) => _buildPage(
        const HistoryScreen(),
        state,
      ),
    ),
  ],
);

/// 统一页面转场动画
/// iOS：使用 CupertinoPage，获得原生右滑返回手势
/// 其他平台（Android / 桌面 / TV）：300ms easeOut 右滑入 / 200ms easeIn 右滑出
Page<dynamic> _buildPage(Widget child, GoRouterState state) {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    return CupertinoPage<dynamic>(key: state.pageKey, child: child);
  }
  return CustomTransitionPage<dynamic>(
    key: state.pageKey,
    child: child,
    transitionDuration: const Duration(milliseconds: 300),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1.0, 0.0),
          end: Offset.zero,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: Curves.easeOut,
          reverseCurve: Curves.easeIn,
        )),
        child: child,
      );
    },
  );
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/models/site.dart';
import '../../../data/models/cms_video_detail.dart';
import '../../home/providers/categories_provider.dart';

/// 详情数据 Provider（autoDispose：离开详情页后释放缓存）
final videoDetailProvider =
    FutureProvider.autoDispose.family<CmsVideoDetail?, ({Site site, String videoId})>(
  (ref, params) async {
    final api = ref.read(cmsApiProvider);
    return api.fetchVideoDetail(site: params.site, videoId: params.videoId);
  },
);

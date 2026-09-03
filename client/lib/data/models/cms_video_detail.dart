import 'episode.dart';
import 'video_item.dart';

class CmsVideoDetail {
  // Bridge plugins may use paths or slugs, e.g. "1618.html", as video IDs.
  final String vodId;
  final String vodName;
  final String vodPic;
  final String vodContent;
  final String vodPlayFrom;
  final String vodPlayUrl;
  final String vodPlayParse;
  final bool isBridge;
  final String? vodYear;
  final String? vodClass;
  final String? vodRemarks;
  final String? vodArea;
  final String? vodLang;
  final String? vodDirector;
  final String? vodActor;
  final String? vodScore;
  final String? vodDoubanScore;

  CmsVideoDetail({
    required this.vodId,
    required this.vodName,
    required this.vodPic,
    required this.vodContent,
    required this.vodPlayFrom,
    required this.vodPlayUrl,
    this.vodPlayParse = '',
    this.isBridge = false,
    this.vodYear,
    this.vodClass,
    this.vodRemarks,
    this.vodArea,
    this.vodLang,
    this.vodDirector,
    this.vodActor,
    this.vodScore,
    this.vodDoubanScore,
  });

  factory CmsVideoDetail.fromJson(
    Map<String, dynamic> json, {
    bool isBridge = false,
  }) {
    return CmsVideoDetail(
      vodId: json['vod_id']?.toString() ?? '',
      vodName: json['vod_name']?.toString() ?? '',
      vodPic: VideoItem.fixCoverUrl(json['vod_pic']?.toString() ?? ''),
      vodContent: _stripHtml(json['vod_content']?.toString() ?? ''),
      vodPlayFrom: json['vod_play_from']?.toString() ?? '',
      vodPlayUrl: json['vod_play_url']?.toString() ?? '',
      vodPlayParse: json['parse']?.toString() ?? '',
      isBridge: isBridge,
      vodYear: json['vod_year']?.toString(),
      vodClass: json['vod_class']?.toString(),
      vodRemarks: json['vod_remarks']?.toString(),
      vodArea: json['vod_area']?.toString(),
      vodLang: json['vod_lang']?.toString(),
      vodDirector: json['vod_director']?.toString(),
      vodActor: json['vod_actor']?.toString(),
      vodScore: json['vod_score']?.toString(),
      vodDoubanScore: json['vod_douban_score']?.toString(),
    );
  }

  /// 从源名称中检测画质等级（分数越高画质越好）
  static int _qualityScore(String name) {
    final lower = name.toLowerCase();
    if (RegExp(r'4k|uhd|2160').hasMatch(lower)) return 4;
    if (RegExp(r'1080|fhd|蓝光|bluray').hasMatch(lower)) return 3;
    if (RegExp(r'超清|720|(?<![a-z])hd(?![a-z])').hasMatch(lower)) return 2;
    if (RegExp(r'高清|480').hasMatch(lower)) return 1;
    if (RegExp(r'标清|360').hasMatch(lower)) return 0;
    return -1; // 无画质信息
  }

  /// 画质等级文字标签（用于 UI 展示）
  static String? _qualityLabel(String name) {
    final lower = name.toLowerCase();
    if (RegExp(r'4k|uhd|2160').hasMatch(lower)) return '4K';
    if (RegExp(r'1080|fhd|蓝光|bluray').hasMatch(lower)) return '1080P';
    if (RegExp(r'超清|720|(?<![a-z])hd(?![a-z])').hasMatch(lower)) return '720P';
    if (RegExp(r'高清|480').hasMatch(lower)) return '480P';
    if (RegExp(r'标清|360').hasMatch(lower)) return '标清';
    return null;
  }

  /// 原始源名列表（未排序）
  List<String> get _rawSourceNames {
    if (vodPlayFrom.isEmpty) return [];
    return vodPlayFrom.split(r'$$$').map((e) => e.trim()).toList();
  }

  /// 原始剧集分组（未排序，按 vodPlayUrl 顺序）
  List<List<Episode>> get _rawEpisodeGroups {
    if (vodPlayUrl.isEmpty) return [];
    final sources = vodPlayUrl.split(r'$$$');
    final flags = _rawSourceNames;
    final parseFlags = vodPlayParse.split(r'$$$');
    return sources.asMap().entries.map((entry) {
      final sourceIndex = entry.key;
      final source = entry.value;
      final sourceFlag = sourceIndex < flags.length ? flags[sourceIndex] : '';
      final parseFlag = parseFlags.length == 1
          ? parseFlags.first
          : sourceIndex < parseFlags.length
          ? parseFlags[sourceIndex]
          : '';
      final requiresResolve = parseFlag.trim() == '1';
      return source.split('#').where((ep) => ep.isNotEmpty).map((ep) {
        final dollarIndex = ep.indexOf(r'$');
        if (dollarIndex == -1) {
          return Episode(
            name: ep,
            url: '',
            sourceFlag: sourceFlag,
            requiresResolve: requiresResolve,
          );
        }
        final url = ep.substring(dollarIndex + 1);
        final scheme = Uri.tryParse(url)?.scheme;
        return Episode(
          name: ep.substring(0, dollarIndex),
          url: url,
          sourceFlag: sourceFlag,
          requiresResolve:
              requiresResolve ||
              (isBridge && scheme != 'http' && scheme != 'https'),
        );
      }).toList();
    }).toList();
  }

  /// 按画质从高到低排序的源索引
  late final List<int> _sortedIndices = () {
    final raw = _rawSourceNames;
    final indices = List.generate(raw.length, (i) => i);
    indices.sort((a, b) {
      final sa = _qualityScore(raw[a]);
      final sb = _qualityScore(raw[b]);
      // 画质高的排前面；相同画质保持原顺序
      return sb.compareTo(sa);
    });
    return indices;
  }();

  /// Play source names, sorted by quality (highest first).
  /// 技术标识符替换为「线路 N」，有画质信息时追加标签（如「线路 1 · 1080P」）
  List<String> get sourceNames {
    final raw = _rawSourceNames;
    if (raw.isEmpty) return [];
    return _sortedIndices.map((origIdx) {
      final name = raw[origIdx];
      final isTechId = RegExp(r'^[a-zA-Z0-9_\-\.]+$').hasMatch(name);
      final displayName = isTechId ? '线路 ${origIdx + 1}' : name;
      final label = _qualityLabel(name);
      return label != null ? '$displayName · $label' : displayName;
    }).toList();
  }

  /// Episodes grouped by source, sorted by quality (highest first).
  List<List<Episode>> get episodeGroups {
    final raw = _rawEpisodeGroups;
    if (raw.isEmpty) return [];
    return _sortedIndices
        .where((i) => i < raw.length)
        .map((i) => raw[i])
        .toList();
  }

  static String _stripHtml(String html) {
    return html.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  }
}

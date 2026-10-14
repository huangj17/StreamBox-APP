import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:streambox/data/live/live_repository.dart';
import 'package:streambox/data/local/live_storage.dart';
import 'package:streambox/data/local/player_settings_storage.dart';
import 'package:streambox/data/models/live_channel.dart';
import 'package:streambox/data/models/live_source_catalog.dart';
import 'package:streambox/features/player/engine/video_engine.dart';

const liveTestRecommendation = LiveSubscription(
  name: 'Guovin IPTV · IPv4',
  url:
      'https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/ipv4/result.m3u',
  fallbackUrls: [
    'https://cdn.jsdelivr.net/gh/Guovin/iptv-api@gd/output/ipv4/result.m3u',
  ],
);
const liveTestSubscriptions = [
  LiveSubscription(
    name: 'ngo5 IPTV · IPv4',
    url: 'https://raw.githubusercontent.com/ngo5/IPTV/main/m3u/ipv4.m3u',
  ),
  LiveSubscription(
    name: 'ngo5 IPTV · IPv6',
    url: 'https://raw.githubusercontent.com/ngo5/IPTV/main/m3u/ipv6.m3u',
  ),
  liveTestRecommendation,
];

LiveSourceCatalog liveTestCatalog() => LiveSourceCatalog.fromJson([
  {...liveTestRecommendation.toJson(), 'id': 'guovin-ipv4'},
  {...liveTestSubscriptions[0].toJson(), 'id': 'ngo5-ipv4'},
  {...liveTestSubscriptions[1].toJson(), 'id': 'ngo5-ipv6'},
]);

List<LiveChannel> liveChannels({int count = 30}) => List.generate(
  count,
  (i) => LiveChannel(
    name: '测试频道 ${i + 1}',
    group: i < 3 ? '央视频道' : '卫视频道',
    url: 'https://video.example/channel/$i.m3u8',
  ),
);

class FakeLiveStorage extends LiveStorage {
  List<LiveSubscription> items = [...liveTestSubscriptions.take(2)];
  String? selection = liveTestSubscriptions.first.url;
  final cacheData = <String, LivePlaylist>{};
  final last = <String, String>{};
  final lastDetails = <String, LiveChannel>{};
  String? playedUrl;
  LiveSourceCatalog? catalog;
  DateTime? syncedAt;
  final hidden = <String>{};
  @override
  LiveSourceCatalog? get officialCatalog => catalog;
  @override
  DateTime? get officialSyncedAt => syncedAt;
  @override
  Set<String> get hiddenOfficialIds => hidden;
  @override
  Future<void> hideOfficial(String id) async {
    hidden.add(id);
  }

  @override
  Future<void> restoreOfficial() async {
    hidden.clear();
  }

  @override
  Future<void> applyCatalog(
    LiveSourceCatalog value, {
    String? currentSelected,
  }) async {
    final custom = items.where((s) => s.id == null).toList();
    items = [
      ...value.subscriptions.where(
        (s) =>
            s.isEnabled &&
            !hidden.contains(s.id) &&
            !custom.any((c) => c.url == s.url),
      ),
      ...custom,
    ];
    selection = currentSelected ?? selection;
    if (!items.any((s) => s.url == selection)) {
      selection = items.firstOrNull?.url;
    }
    catalog = value;
    syncedAt = DateTime.now();
  }

  @override
  String? get lastPlayedUrl => playedUrl;
  @override
  List<LiveSubscription> get subscriptions => items;
  @override
  String? get selectedUrl => selection;
  @override
  Future<void> saveSubscriptions(List<LiveSubscription> items) async {
    this.items = items;
  }

  @override
  Future<void> select(String? url) async {
    selection = url;
  }

  @override
  LivePlaylist? cached(String url) => cacheData[url];
  @override
  Future<void> cache(String url, LivePlaylist playlist) async {
    cacheData[url] = playlist;
  }

  @override
  Future<void> removeCache(String url) async {
    cacheData.remove(url);
    last.remove(url);
    lastDetails.remove(url);
    if (playedUrl == url) playedUrl = null;
  }

  @override
  String? lastChannel(String url) => last[url];
  @override
  LiveChannel? lastChannelDetails(String url) {
    final details = lastDetails[url];
    if (details != null && details.identity == last[url]) return details;
    final parts = last[url]?.split('\u0000');
    if (parts?.length != 3) return null;
    return LiveChannel(group: parts![0], name: parts[1], url: parts[2]);
  }

  @override
  Future<void> rememberChannel(String url, LiveChannel channel) async {
    last[url] = channel.identity;
    lastDetails[url] = channel;
    playedUrl = url;
  }
}

class FakeLiveRepository extends LiveRepository {
  final requests = <String>[];
  final tokens = <CancelToken>[];
  final catalogTokens = <CancelToken>[];
  Future<LiveSourceCatalog> Function()? catalogResponse;
  @override
  Future<LiveSourceCatalog> fetchCatalog({required CancelToken cancelToken}) {
    catalogTokens.add(cancelToken);
    return catalogResponse?.call() ??
        Future.error(const FormatException('测试未提供远程配置'));
  }

  Future<LivePlaylist> Function(String)? response;
  FakeLiveRepository() : super(Dio());
  @override
  Future<LivePlaylist> fetch(
    String url, {
    required CancelToken cancelToken,
    List<String> fallbackUrls = const [],
  }) {
    requests.add(url);
    tokens.add(cancelToken);
    return response?.call(url) ??
        Future.value(
          LivePlaylist(channels: liveChannels(), updatedAt: DateTime.now()),
        );
  }
}

class FakeLiveSettings extends PlayerSettingsStorage {
  @override
  bool get hardwareDecode => true;
}

class FakeLiveEngine implements VideoEngine {
  final positions = StreamController<Duration>.broadcast();
  final buffers = StreamController<bool>.broadcast();
  final errors = StreamController<String>.broadcast();
  final opens = <String>[];
  final headers = <Map<String, String>?>[];
  Completer<void>? pendingOpen;
  Future<void> Function(String)? openResponse;
  bool disposed = false;
  int pauseCount = 0;
  int seekCount = 0;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration> get durationStream => const Stream.empty();
  @override
  Stream<bool> get bufferingStream => buffers.stream;
  @override
  Stream<bool> get playingStream => const Stream.empty();
  @override
  Stream<Duration> get bufferedStream => const Stream.empty();
  @override
  Stream<String> get errorStream => errors.stream;
  @override
  Stream<List<VideoQuality>> get qualitiesStream => const Stream.empty();
  @override
  Stream<VideoQuality> get currentQualityStream => const Stream.empty();
  @override
  Widget buildVideoView() => const ColoredBox(color: Color(0xFF102126));
  @override
  Future<void> open(String url, {Map<String, String>? headers}) async {
    opens.add(url);
    this.headers.add(headers);
    await openResponse?.call(url);
    await pendingOpen?.future;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await Future.wait([positions.close(), buffers.close(), errors.close()]);
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {
    pauseCount++;
  }

  @override
  Future<void> playOrPause() async {}
  @override
  Future<void> seek(Duration position) async {
    seekCount++;
  }

  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double v01) async {}
  @override
  Future<void> setQuality(VideoQuality q) async {}
}

import 'dart:async';

/// User-facing failures never echo raw engine errors or signed stream URLs.
String livePlaybackErrorMessage(Object? error, String url) {
  final reason = error?.toString().toLowerCase() ?? '';
  if (RegExp(r'\b(401|403)\b').hasMatch(reason)) {
    return '直播服务器拒绝访问，地址可能已过期，请刷新或更换订阅';
  }
  if (RegExp(r'\b404\b').hasMatch(reason)) {
    return '直播地址已失效，请返回刷新或更换订阅';
  }
  if (reason.contains('failed host lookup') ||
      reason.contains('nodename nor servname') ||
      reason.contains('name or service not known')) {
    return '无法解析直播服务器域名，请检查网络或更换订阅';
  }
  if (reason.contains('decoder') || reason.contains('unsupported codec')) {
    return '当前设备无法解码这个频道，请尝试其他频道';
  }
  final host = Uri.tryParse(url)?.host ?? '';
  if (host.contains(':')) {
    return 'IPv6 频道连接失败，请确认网络支持 IPv6，或更换 IPv4 订阅';
  }
  if (host == 'ottrrs.hl.chinamobile.com' || host == 'ott.mobaibox.com') {
    return '该运营商频道连接失败，可尝试 Guovin IPTV · IPv4 订阅';
  }
  if (error is TimeoutException ||
      reason.contains('timed out') ||
      reason.contains('timeout')) {
    return '直播连接超时，请尝试其他频道或更换订阅';
  }
  return '无法播放这个直播地址，请重试或更换订阅';
}

enum SourceHealthStatus { checking, available, unavailable, unverified }

class SourceHealth {
  final SourceHealthStatus status;
  final String message;
  final DateTime? checkedAt;

  const SourceHealth({
    required this.status,
    required this.message,
    this.checkedAt,
  });

  const SourceHealth.checking()
    : status = SourceHealthStatus.checking,
      message = '正在检测播放链路',
      checkedAt = null;

  SourceHealth.available({this.message = '播放链路正常'})
    : status = SourceHealthStatus.available,
      checkedAt = DateTime.now();

  SourceHealth.unavailable({required this.message})
    : status = SourceHealthStatus.unavailable,
      checkedAt = DateTime.now();

  SourceHealth.unverified({required this.message})
    : status = SourceHealthStatus.unverified,
      checkedAt = DateTime.now();
}

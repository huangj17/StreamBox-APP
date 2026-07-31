class Episode {
  final String name;
  final String url;
  final String sourceFlag;
  final bool requiresResolve;
  final Map<String, String>? headers;

  const Episode({
    required this.name,
    required this.url,
    this.sourceFlag = '',
    this.requiresResolve = false,
    this.headers,
  });
}

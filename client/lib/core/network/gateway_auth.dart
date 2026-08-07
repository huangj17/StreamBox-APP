class GatewayAuth {
  /// Personal deployments can inject the token without putting it in source
  /// URLs: `flutter run --dart-define=STREAMBOX_GATEWAY_TOKEN=your-token`
  static const token = String.fromEnvironment('STREAMBOX_GATEWAY_TOKEN');

  static Map<String, dynamic>? get headers => token.isEmpty
      ? null
      : const <String, dynamic>{'Authorization': 'Bearer $token'};
}

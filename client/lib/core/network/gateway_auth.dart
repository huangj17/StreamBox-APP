import '../config/production_gateway.dart';

class GatewayAuth {
  /// Personal deployments can inject the token without putting it in source
  /// URLs: `flutter run --dart-define=STREAMBOX_GATEWAY_TOKEN=your-token`
  static const token = String.fromEnvironment('STREAMBOX_GATEWAY_TOKEN');

  static Map<String, dynamic>? get headers => token.isEmpty
      ? null
      : const <String, dynamic>{'Authorization': 'Bearer $token'};

  /// The public production service must never receive a personal server token.
  static Map<String, dynamic>? headersFor(Uri uri) =>
      ProductionGateway.isOrigin(uri) ? null : headers;
}

import 'package:dio/dio.dart';

enum ApiErrorKind {
  network,
  timeout,
  unauthorized,
  forbidden,
  notFound,
  conflict,
  validation,
  server,
  unknown,
}

/// Every failure from the backend, in one shape. `code` is the backend's machine-readable error code
/// (e.g. `insufficient_stock`, `slot_full`, `payment_provider_not_configured`); `message` is safe to show to the customer.
class ApiException implements Exception {
  ApiException({
    required this.kind,
    required this.message,
    this.status,
    this.code,
    this.details = const [],
  });

  final ApiErrorKind kind;
  final String message;
  final int? status;
  final String? code;
  final List<Map<String, dynamic>> details;

  bool get isUnauthorized => kind == ApiErrorKind.unauthorized;
  bool get isNetwork =>
      kind == ApiErrorKind.network || kind == ApiErrorKind.timeout;

  factory ApiException.fromDio(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return ApiException(
          kind: ApiErrorKind.timeout,
          message: 'The server took too long to respond. Please try again.',
        );
      case DioExceptionType.connectionError:
        return ApiException(
          kind: ApiErrorKind.network,
          message: 'Cannot reach the server. Check your internet connection.',
        );
      case DioExceptionType.cancel:
        return ApiException(
          kind: ApiErrorKind.unknown,
          message: 'The request was cancelled.',
        );
      default:
        break;
    }
    final res = e.response;
    if (res == null) {
      return ApiException(
        kind: ApiErrorKind.network,
        message: 'Cannot reach the server. Check your internet connection.',
      );
    }
    final status = res.statusCode ?? 0;
    String? code;
    String? message;
    var details = <Map<String, dynamic>>[];
    final data = res.data;
    if (data is Map && data['error'] is Map) {
      final err = data['error'] as Map;
      code = err['code'] as String?;
      message = err['message'] as String?;
      final d = err['details'];
      if (d is List) {
        details = d
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
      }
    }
    final kind = switch (status) {
      401 => ApiErrorKind.unauthorized,
      403 => ApiErrorKind.forbidden,
      404 => ApiErrorKind.notFound,
      409 => ApiErrorKind.conflict,
      400 || 422 => ApiErrorKind.validation,
      >= 500 => ApiErrorKind.server,
      _ => ApiErrorKind.unknown,
    };
    return ApiException(
      kind: kind,
      status: status,
      code: code,
      details: details,
      message:
          message ??
          (kind == ApiErrorKind.server
              ? 'Something went wrong on our side. Please try again.'
              : 'The request could not be completed.'),
    );
  }

  @override
  String toString() => 'ApiException($status $code: $message)';
}

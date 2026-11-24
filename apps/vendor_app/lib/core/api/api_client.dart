import 'dart:async';

import 'package:dio/dio.dart';

import 'api_exception.dart';

typedef TokenReader = Future<String?> Function();
typedef TokenRefresher = Future<String?> Function();

/// The ONLY place that talks HTTP. Attaches the Supabase access token as `Authorization: Bearer`, refreshes it once on a 401, applies
/// timeouts, and converts every failure to [ApiException]. Repositories never see Dio.
class ApiClient {
  ApiClient({
    required String baseUrl,
    required this.readToken,
    this.refreshToken,
    this.onSessionExpired,
    Dio? dio,
  }) : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = baseUrl
      ..connectTimeout = const Duration(seconds: 15)
      ..receiveTimeout = const Duration(seconds: 30)
      ..sendTimeout = const Duration(seconds: 30)
      ..headers = {'Accept': 'application/json'}
      ..validateStatus = (s) => s != null && s >= 200 && s < 300;
  }

  final Dio _dio;
  final TokenReader readToken;
  final TokenRefresher? refreshToken;
  final void Function()? onSessionExpired;

  Future<dynamic> get(
    String path, {
    Map<String, dynamic>? query,
    bool auth = true,
  }) => _send('GET', path, query: query, auth: auth);
  Future<dynamic> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
  }) => _send('POST', path, body: body, query: query, headers: headers);
  Future<dynamic> put(String path, {Object? body}) =>
      _send('PUT', path, body: body);
  Future<dynamic> patch(String path, {Object? body}) =>
      _send('PATCH', path, body: body);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    bool auth = true,
    bool retried = false,
  }) async {
    try {
      final token = auth ? await readToken() : null;
      final res = await _dio.request<dynamic>(
        path,
        data: body,
        queryParameters: _clean(query),
        options: Options(
          method: method,
          headers: {
            ...?headers,
            if (token != null) 'Authorization': 'Bearer $token',
          },
        ),
      );
      return res.data;
    } on DioException catch (e) {
      final err = ApiException.fromDio(e);
      if (auth && err.isUnauthorized && !retried && refreshToken != null) {
        final fresh = await refreshToken!();
        if (fresh != null) {
          return _send(
            method,
            path,
            body: body,
            query: query,
            headers: headers,
            auth: auth,
            retried: true,
          );
        }
      }
      if (auth && err.isUnauthorized) onSessionExpired?.call();
      throw err;
    }
  }

  /// Drop null/empty query values so optional filters never reach the URL.
  static Map<String, dynamic>? _clean(Map<String, dynamic>? q) {
    if (q == null) return null;
    final out = <String, dynamic>{};
    q.forEach((k, v) {
      if (v == null || (v is String && v.isEmpty)) return;
      out[k] = v is bool || v is num ? v.toString() : v;
    });
    return out;
  }
}

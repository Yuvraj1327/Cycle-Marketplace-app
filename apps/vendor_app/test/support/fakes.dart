import 'dart:async';
import 'dart:convert';

import 'package:vendor_app/core/auth/auth_service.dart';
import 'package:dio/dio.dart';

/// In-memory identity provider for tests (no Supabase).
class FakeAuthService implements AuthService {
  FakeAuthService({String? token = 'tok-1', this.failSignInWith})
    : _token = token;
  String? _token;
  final String? failSignInWith;
  final _changes = StreamController<bool>.broadcast();
  int refreshCalls = 0;
  String? refreshedTo;
  int signInCalls = 0;
  bool signedOut = false;

  @override
  bool get isSignedIn => _token != null;
  @override
  String? get userId => _token == null ? null : 'user-1';
  @override
  Stream<bool> get signedInChanges => _changes.stream;
  @override
  Future<String?> accessToken() async => _token;
  @override
  Future<String?> refreshAccessToken() async {
    refreshCalls++;
    _token = refreshedTo;
    return refreshedTo;
  }

  @override
  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) async {
    signInCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (failSignInWith != null) throw AuthFailure(failSignInWith!);
    _token = 'tok-1';
    _changes.add(true);
  }

  @override
  Future<SignUpResult> signUp({
    required String email,
    required String password,
    required String fullName,
    String? phone,
  }) async => const SignUpResult(signedIn: false);
  @override
  Future<void> sendPasswordReset(String email) async {}
  @override
  Future<void> signOut() async {
    signedOut = true;
    _token = null;
    _changes.add(false);
  }
}

typedef Responder = ResponseBody Function(RequestOptions o);

/// Dio adapter that answers from a function, recording every request.
class StubAdapter implements HttpClientAdapter {
  StubAdapter(this.responder);
  final Responder responder;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return responder(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(Object? body, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

Map<String, dynamic> meJson({
  String role = 'vendor',
  String status = 'active',
}) => {
  'id': 'user-1',
  'email': 'owner@example.com',
  'phone': null,
  'role': role,
  'status': status,
  'profile': {
    'id': 'user-1',
    'full_name': 'Owner Name',
    'role': role,
    'status': status,
  },
};

Map<String, dynamic> vendorJson({
  String status = 'approved',
  String? reason,
  Map<String, dynamic>? hours,
}) => {
  'id': 'v-1',
  'business_name': 'Spoke & Co',
  'business_types': ['bicycle_shop', 'service_provider'],
  'description': null,
  'address_line1': '1 MG Road',
  'address_line2': null,
  'city': 'Pune',
  'state': 'Maharashtra',
  'postal_code': '411001',
  'contact_phone': '+919800000001',
  'contact_email': null,
  'operating_hours':
      hours ??
      {
        'mon': {'closed': false, 'open': '09:00', 'close': '18:00'},
      },
  'shop_image_paths': <String>[],
  'service_area_postal_codes': ['411001'],
  'service_radius_km': null,
  'pickup_available': true,
  'verification_status': status,
  'rejection_reason': reason,
  'reviewed_at': null,
  'created_at': '2026-01-01T00:00:00+00:00',
  'updated_at': '2026-01-01T00:00:00+00:00',
};

class FakeImageStorage implements ImageStorage {
  final uploads = <String>[];
  @override
  Future<String> upload({
    required ImageBucket bucket,
    required String userId,
    required String folder,
    required List<int> bytes,
    required String extension,
    required String contentType,
  }) async {
    final p = '$userId/$folder/f.$extension';
    uploads.add('${bucket.id}/$p');
    return p;
  }

  @override
  String publicUrl(ImageBucket bucket, String path) =>
      'https://img.test/${bucket.id}/$path';
}

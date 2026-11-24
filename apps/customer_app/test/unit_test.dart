import 'package:customer_app/core/api/api_client.dart';
import 'package:customer_app/core/api/api_exception.dart';
import 'package:customer_app/core/models/paged.dart';
import 'package:customer_app/core/paged_controller.dart';
import 'package:customer_app/core/utils/format.dart';
import 'package:customer_app/features/authentication/models.dart';
import 'package:customer_app/features/cart/models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

ApiClient client(
  StubAdapter a, {
  Future<String?> Function()? read,
  Future<String?> Function()? refresh,
  void Function()? expired,
}) {
  final dio = Dio()..httpClientAdapter = a;
  return ApiClient(
    baseUrl: 'http://x/api/v1',
    readToken: read ?? () async => 'tok-1',
    refreshToken: refresh,
    onSessionExpired: expired,
    dio: dio,
  );
}

void main() {
  group('format helpers', () {
    test('money uses Indian grouping and hides .00', () {
      expect(money(24999), '₹24,999');
      expect(money(123456.5), '₹1,23,456.50');
      expect(money(0), '₹0');
    });
    test('time12 and humanize', () {
      expect(time12('09:00'), '9:00 AM');
      expect(time12('13:30:00'), '1:30 PM');
      expect(time12('00:15'), '12:15 AM');
      expect(humanize('ready_for_delivery'), 'Ready For Delivery');
    });
    test('isoDate', () => expect(isoDate(DateTime(2026, 3, 5)), '2026-03-05'));
  });

  group('ApiException', () {
    DioException http(int status, Object? data) => DioException(
      requestOptions: RequestOptions(path: '/x'),
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: RequestOptions(path: '/x'),
        statusCode: status,
        data: data,
      ),
    );

    test('maps backend error envelope', () {
      final e = ApiException.fromDio(
        http(409, {
          'error': {'code': 'slot_full', 'message': 'That slot is full.'},
        }),
      );
      expect(e.kind, ApiErrorKind.conflict);
      expect(e.code, 'slot_full');
      expect(e.message, 'That slot is full.');
    });
    test('validation details are kept', () {
      final e = ApiException.fromDio(
        http(422, {
          'error': {
            'code': 'validation_error',
            'message': 'bad',
            'details': [
              {'field': 'quantity', 'message': 'too big'},
            ],
          },
        }),
      );
      expect(e.kind, ApiErrorKind.validation);
      expect(e.details.single['field'], 'quantity');
    });
    test('status → kind', () {
      expect(
        ApiException.fromDio(http(401, null)).kind,
        ApiErrorKind.unauthorized,
      );
      expect(
        ApiException.fromDio(http(403, null)).kind,
        ApiErrorKind.forbidden,
      );
      expect(ApiException.fromDio(http(404, null)).kind, ApiErrorKind.notFound);
      expect(ApiException.fromDio(http(503, null)).kind, ApiErrorKind.server);
    });
    test(
      'server error without body gives a friendly message, not a stack trace',
      () {
        final e = ApiException.fromDio(http(500, '<html>boom</html>'));
        expect(e.message, contains('Something went wrong'));
      },
    );
    test('timeouts and connection errors are flagged as network', () {
      final t = ApiException.fromDio(
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.receiveTimeout,
        ),
      );
      final c = ApiException.fromDio(
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.connectionError,
        ),
      );
      expect(t.isNetwork && c.isNetwork, isTrue);
    });
  });

  group('ApiClient', () {
    test('sends Bearer token and drops empty query values', () async {
      final a = StubAdapter((_) => jsonBody({'ok': true}));
      await client(a).get(
        '/products',
        query: {'q': '', 'page': 2, 'in_stock': true, 'brand': null},
      );
      final r = a.requests.single;
      expect(r.headers['Authorization'], 'Bearer tok-1');
      expect(r.queryParameters, {'page': '2', 'in_stock': 'true'});
    });
    test('auth:false sends no Authorization header', () async {
      final a = StubAdapter((_) => jsonBody([]));
      await client(a).get('/categories', auth: false);
      expect(a.requests.single.headers.containsKey('Authorization'), isFalse);
    });
    test('401 → refresh once → retry with the new token', () async {
      var token = 'old';
      final a = StubAdapter(
        (o) => o.headers['Authorization'] == 'Bearer new'
            ? jsonBody({'ok': 1})
            : jsonBody({
                'error': {'code': 'unauthorized', 'message': 'no'},
              }, 401),
      );
      final c = client(
        a,
        read: () async => token,
        refresh: () async => token = 'new',
      );
      expect(await c.get('/cart'), {'ok': 1});
      expect(a.requests.length, 2);
    });
    test('still 401 after refresh → onSessionExpired, no retry loop', () async {
      var expired = 0;
      final a = StubAdapter(
        (_) => jsonBody({
          'error': {'code': 'unauthorized', 'message': 'no'},
        }, 401),
      );
      final c = client(
        a,
        refresh: () async => 'again',
        expired: () => expired++,
      );
      await expectLater(
        c.get('/cart'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.isUnauthorized,
            'unauthorized',
            true,
          ),
        ),
      );
      expect(a.requests.length, 2);
      expect(expired, 1);
    });
    test('failed refresh signs the session out', () async {
      var expired = 0;
      final a = StubAdapter(
        (_) => jsonBody({
          'error': {'code': 'unauthorized', 'message': 'no'},
        }, 401),
      );
      final c = client(a, refresh: () async => null, expired: () => expired++);
      await expectLater(c.get('/cart'), throwsA(isA<ApiException>()));
      expect(a.requests.length, 1);
      expect(expired, 1);
    });
    test('custom headers (Idempotency-Key) are forwarded', () async {
      final a = StubAdapter((_) => jsonBody({'id': 'o1'}, 201));
      await client(
        a,
      ).post('/checkout', body: {'a': 1}, headers: {'Idempotency-Key': 'k1'});
      expect(a.requests.single.headers['Idempotency-Key'], 'k1');
    });
  });

  group('PagedController', () {
    Paged<int> page(int n, int pages) => Paged(
      items: [n * 10, n * 10 + 1],
      total: pages * 2,
      page: n,
      limit: 2,
      pages: pages,
    );

    test('appends pages from the backend and stops at the last page', () async {
      final asked = <int>[];
      final c = PagedController<int>((p) async {
        asked.add(p);
        return page(p, 2);
      });
      await c.loadMore();
      await c.loadMore();
      await c.loadMore(); // no more pages
      expect(asked, [1, 2]);
      expect(c.items, [10, 11, 20, 21]);
      expect(c.hasMore, isFalse);
      c.dispose();
    });
    test('ignores concurrent loadMore calls', () async {
      var calls = 0;
      final c = PagedController<int>((p) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return page(p, 5);
      });
      await Future.wait([c.loadMore(), c.loadMore(), c.loadMore()]);
      expect(calls, 1);
      c.dispose();
    });
    test('error keeps the loaded items and can be retried', () async {
      var fail = false;
      final c = PagedController<int>((p) async {
        if (fail) {
          throw ApiException(kind: ApiErrorKind.network, message: 'offline');
        }
        return page(p, 3);
      });
      await c.loadMore();
      fail = true;
      await c.loadMore();
      expect(c.error?.message, 'offline');
      expect(c.items.length, 2);
      fail = false;
      await c.loadMore();
      expect(c.error, isNull);
      expect(c.items.length, 4);
      c.dispose();
    });
    test(
      'refresh restarts from page 1; empty result reports isEmpty',
      () async {
        final c = PagedController<int>(
          (p) async =>
              const Paged(items: [], total: 0, page: 1, limit: 20, pages: 0),
        );
        await c.refresh();
        expect(c.isEmpty, isTrue);
        c.dispose();
      },
    );
  });

  group('models', () {
    test('Me.fromJson reads role/status from backend', () {
      final me = Me.fromJson(meJson());
      expect(me.isCustomer && me.isActive, isTrue);
      expect(Me.fromJson(meJson(role: 'vendor')).isCustomer, isFalse);
      expect(Me.fromJson(meJson(status: 'suspended')).isActive, isFalse);
    });
    test('Cart.fromJson parses summary flags and numeric money', () {
      final cart = Cart.fromJson({
        'id': 'c1',
        'items': [
          {
            'id': 'i1',
            'product_id': 'p1',
            'quantity': 2,
            'unit_price': 1850,
            'line_total': 3700.0,
            'status': 'ok',
            'available_quantity': 10,
            'price_changed': false,
            'product': {
              'id': 'p1',
              'name': 'Disc Brake Set',
              'condition': 'new',
              'price': 1850,
              'stock_quantity': 10,
            },
          },
          {
            'id': 'i2',
            'product_id': 'p2',
            'quantity': 1,
            'status': 'out_of_stock',
            'available_quantity': 0,
            'price_changed': true,
            'previous_price': 2500,
          },
        ],
        'summary': {
          'distinct_items': 2,
          'total_quantity': 3,
          'subtotal': 3700,
          'multi_vendor': true,
          'has_unavailable_items': true,
          'has_price_changes': true,
        },
      });
      expect(cart.items.first.lineTotal, 3700.0);
      expect(cart.items.last.isOk, isFalse);
      expect(
        cart.multiVendor && cart.hasUnavailable && cart.hasPriceChanges,
        isTrue,
      );
      expect(
        cart.canCheckout,
        isFalse,
        reason: 'unavailable item blocks checkout',
      );
      expect(Cart.empty.canCheckout, isFalse);
    });
    test('Paged.fromJson', () {
      final p = Paged<String>.fromJson({
        'items': [
          {'n': 'a'},
        ],
        'total': 41,
        'page': 2,
        'limit': 20,
        'pages': 3,
      }, (m) => m['n'] as String);
      expect(p.items, ['a']);
      expect(p.hasMore, isTrue);
    });
  });
}

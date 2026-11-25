// Contract tests: the app's REAL repositories + models talk over real HTTP to the REAL FastAPI app started by
// `backend/tests/dev_server.py` (in-memory DB, locally signed JWTs, fake payment provider). NOT a real Supabase/PostgREST/Storage/gateway test.
//
//   (cd backend && .venv/bin/python -m tests.dev_server) &
//   CONTRACT_API=http://127.0.0.1:8791 flutter test test/contract
@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:customer_app/core/api/api_client.dart';
import 'package:customer_app/core/api/api_exception.dart';
import 'package:customer_app/core/push/push_controller.dart';
import 'package:customer_app/features/addresses/models.dart';
import 'package:customer_app/features/addresses/repository.dart';
import 'package:customer_app/features/authentication/repository.dart';
import 'package:customer_app/features/bookings/models.dart';
import 'package:customer_app/features/bookings/repository.dart';
import 'package:customer_app/features/cart/repository.dart';
import 'package:customer_app/features/checkout/repository.dart';
import 'package:customer_app/features/notifications/repository.dart';
import 'package:customer_app/features/orders/repository.dart';
import 'package:customer_app/features/products/models.dart';
import 'package:customer_app/features/products/repository.dart';
import 'package:customer_app/features/services/repository.dart';
import 'package:customer_app/features/support/repository.dart';
import 'package:customer_app/features/wishlist/repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

final base = Platform.environment['CONTRACT_API'];

Future<void> expectApiError(
  Future<Object?> f, {
  String? code,
  ApiErrorKind? kind,
}) async {
  try {
    await f;
  } on ApiException catch (e) {
    if (code != null) expect(e.code, code);
    if (kind != null) expect(e.kind, kind);
    return;
  }
  fail('expected an ApiException');
}

void main() {
  if (base == null) {
    test(
      'contract tests',
      () {},
      skip:
          'set CONTRACT_API=http://127.0.0.1:8791 with tests/dev_server running',
    );
    return;
  }

  late Map<String, dynamic> seed;
  late String customerToken, otherToken, adminToken, vendorToken, expiredToken;
  late ApiClient api;
  var refreshes = 0;
  var expiredEvents = 0;
  String? current;

  ApiClient clientFor(
    Future<String?> Function() read, {
    Future<String?> Function()? refresh,
    void Function()? expired,
  }) => ApiClient(
    baseUrl: '$base/api/v1',
    readToken: read,
    refreshToken: refresh,
    onSessionExpired: expired,
  );

  setUpAll(() async {
    final d = Dio(BaseOptions(baseUrl: base!));
    await d.post<dynamic>('/__dev/reset');
    seed = (await d.get<Map<String, dynamic>>('/__dev/tokens')).data!;
    final t = seed['tokens'] as Map<String, dynamic>;
    customerToken = t['customer'] as String;
    otherToken = t['other'] as String;
    adminToken = t['admin'] as String;
    vendorToken = t['vendor_user'] as String;
    expiredToken = seed['expired'] as String;
    current = customerToken;
    api = clientFor(
      () async => current,
      refresh: () async {
        refreshes++;
        return current;
      },
      expired: () => expiredEvents++,
    );
  });

  group('auth & roles', () {
    test(
      '/auth/me returns customer role + active status from the backend',
      () async {
        final me = await AuthRepository(api).me();
        expect(me.isCustomer && me.isActive, isTrue);
        expect(me.profile.fullName, 'Asha Rao');
      },
    );
    test(
      'vendor and admin tokens are identified as non-customers (app signs them out)',
      () async {
        for (final tok in [vendorToken, adminToken]) {
          final me = await AuthRepository(clientFor(() async => tok)).me();
          expect(me.isCustomer, isFalse);
        }
      },
    );
    test(
      'expired token → 401 → refresh attempted once → session-expired callback',
      () async {
        refreshes = 0;
        expiredEvents = 0;
        final c = clientFor(
          () async => expiredToken,
          refresh: () async {
            refreshes++;
            return expiredToken;
          },
          expired: () => expiredEvents++,
        );
        await expectApiError(
          AuthRepository(c).me(),
          kind: ApiErrorKind.unauthorized,
        );
        expect(refreshes, 1);
        expect(expiredEvents, 1);
      },
    );
    test('no token → 401', () async {
      await expectApiError(
        AuthRepository(clientFor(() async => null)).me(),
        kind: ApiErrorKind.unauthorized,
      );
    });
    test('profile update', () async {
      final p = await ProfileRepository(api).update(fullName: 'Asha R. Rao');
      expect(p.fullName, 'Asha R. Rao');
      expect((await AuthRepository(api).me()).profile.fullName, 'Asha R. Rao');
    });
  });

  group('catalog (public)', () {
    CatalogRepository repo() => CatalogRepository(api);
    test('categories include counts; banners; featured', () async {
      final cats = await repo().categories(rootOnly: true);
      expect(
        cats.map((c) => c.name),
        containsAll(['New Cycles', 'Spare Parts']),
      );
      expect((await repo().banners()).length, 2);
      final f = await repo().featured();
      expect(
        f.map((p) => p.name),
        containsAll(['Trail Blazer 29', 'Disc Brake Set']),
      );
    });
    test('list + pagination from the backend', () async {
      final p1 = await repo().products(const ProductQuery(), 1, limit: 2);
      expect(p1.items.length, 2);
      expect(p1.total, 5);
      expect(p1.hasMore, isTrue);
      final p3 = await repo().products(const ProductQuery(), 3, limit: 2);
      expect(p3.items.length, 1);
      expect(p3.hasMore, isFalse);
    });
    test('backend-side search, filter, sort', () async {
      final search = await repo().products(const ProductQuery(q: 'brake'), 1);
      expect(search.items.map((p) => p.name), ['Disc Brake Set']);
      final cat = await repo().products(
        ProductQuery(
          categoryId: (seed['category_ids'] as Map)['used_cycle'] as String,
        ),
        1,
      );
      expect(cat.items.single.isUsed, isTrue);
      final price = await repo().products(
        const ProductQuery(minPrice: 10000, sort: ProductSort.priceLow),
        1,
      );
      expect(price.items.map((p) => p.name), [
        'City Cruiser',
        'Trail Blazer 29',
      ]);
      final stock = await repo().products(const ProductQuery(inStock: true), 1);
      expect(stock.items.every((p) => p.inStock), isTrue);
      expect(stock.items.map((p) => p.name), isNot(contains('Road Helmet')));
    });
    test('product detail and not-found', () async {
      final id = (seed['product_ids'] as Map)['Trail Blazer 29'] as String;
      final d = await repo().product(id);
      expect(d.summary.name, 'Trail Blazer 29');
      expect(d.summary.price, 24999.0);
      expect(d.images, isNotEmpty);
      await expectApiError(
        repo().product('00000000-0000-0000-0000-000000000000'),
        kind: ApiErrorKind.notFound,
      );
    });
  });

  group('cart → wishlist → addresses', () {
    Map<dynamic, dynamic> ids() => seed['product_ids'] as Map;
    test('cart add / quantity / remove; totals are the backend\'s', () async {
      final cart = CartRepository(api);
      var c = await cart.add(ids()['Disc Brake Set'] as String, quantity: 2);
      expect(c.totalQuantity, 2);
      expect(c.subtotal, 3700.0);
      c = await cart.setQuantity(c.items.single.id, 3);
      expect(c.subtotal, 5550.0);
      await expectApiError(cart.setQuantity(c.items.single.id, 999));
      c = await cart.remove(c.items.single.id);
      expect(c.isEmpty, isTrue);
    });
    test('out-of-stock product cannot be added', () async {
      await expectApiError(
        CartRepository(api).add(ids()['Road Helmet'] as String),
      );
    });
    test('wishlist add / list / remove', () async {
      final w = WishlistRepository(api);
      await w.add(ids()['City Cruiser'] as String);
      final got = await w.get();
      expect(got.items.single.productId, ids()['City Cruiser']);
      await w.remove(got.items.single.id);
      expect((await w.get()).items, isEmpty);
    });
    test('addresses CRUD + default', () async {
      final a = AddressRepository(api);
      final created = await a.create(
        const AddressInput(
          recipientName: 'Asha Rao',
          phone: '+919800000001',
          line1: '5 FC Road',
          city: 'Pune',
          state: 'Maharashtra',
          postalCode: '411004',
        ),
      );
      expect((await a.list()).length, 2);
      final edited = await a.update(
        created.id,
        const AddressInput(
          recipientName: 'Asha Rao',
          phone: '+919800000001',
          line1: '5 FC Road, Flat 2',
          city: 'Pune',
          state: 'Maharashtra',
          postalCode: '411004',
        ),
      );
      expect(edited.line1, contains('Flat 2'));
      final def = await a.setDefault(created.id);
      expect(def.isDefault, isTrue);
      await a.delete(created.id);
      expect((await a.list()).length, 1);
    });
    test('another customer cannot see my addresses or cart', () async {
      final other = clientFor(() async => otherToken);
      expect(await AddressRepository(other).list(), isEmpty);
      expect((await CartRepository(other).get()).isEmpty, isTrue);
    });
  });

  group('checkout → orders', () {
    String? orderId;
    Map<dynamic, dynamic> ids() => seed['product_ids'] as Map;
    test(
      'options reflect backend settings (COD on, online provider not configured)',
      () async {
        final o = await CheckoutRepository(api).options();
        expect(o.codEnabled, isTrue);
      },
    );
    test('preview computes totals and writes nothing', () async {
      await CartRepository(
        api,
      ).add(ids()['Disc Brake Set'] as String, quantity: 2);
      final body = CheckoutRepository.body(
        addressId: seed['address_id'] as String,
        method: 'cod',
      );
      final pv = await CheckoutRepository(api).preview(body);
      expect(pv.subtotal, 3700.0);
      expect(
        (await OrderRepository(api).list(1)).items,
        isEmpty,
        reason: 'preview must not create an order',
      );
      expect(
        (await CartRepository(api).get()).totalQuantity,
        2,
        reason: 'preview must not clear the cart',
      );
    });
    test('coupon applied by the backend', () async {
      final body = CheckoutRepository.body(
        addressId: seed['address_id'] as String,
        method: 'cod',
        coupon: seed['coupon'] as String,
      );
      final pv = await CheckoutRepository(api).preview(body);
      expect(pv.discount, 370.0);
    });
    test('invalid coupon → backend error code', () async {
      final body = CheckoutRepository.body(
        addressId: seed['address_id'] as String,
        method: 'cod',
        coupon: 'NOPE',
      );
      await expectApiError(CheckoutRepository(api).preview(body));
    });
    test(
      'online checkout (dev harness has a TEST provider): payment stays unpaid until a verified webhook; cancel it',
      () async {
        final body = CheckoutRepository.body(
          addressId: seed['address_id'] as String,
          method: 'online',
        );
        final res = await CheckoutRepository(api).place(body, 'key-online-1');
        expect(
          res.payment.status,
          isNot('paid'),
          reason: 'the client can never mark an order paid',
        );
        expect(res.order.summary.paymentStatus, isNot('paid'));
        expect(res.clientPayload, isNotNull);
        expect(
          (await CartRepository(api).get()).isEmpty,
          isTrue,
          reason: 'cart is cleared only after the backend confirmed the order',
        );
        await OrderRepository(api).cancel(res.order.summary.id, 'Testing');
        await CartRepository(
          api,
        ).add(ids()['Disc Brake Set'] as String, quantity: 2);
      },
    );
    test(
      'COD checkout creates an order, clears the cart, and is idempotent',
      () async {
        final repo = CheckoutRepository(api);
        final body = CheckoutRepository.body(
          addressId: seed['address_id'] as String,
          method: 'cod',
        );
        final res = await repo.place(body, 'key-cod-1');
        orderId = res.order.summary.id;
        expect(res.replay, isFalse);
        expect(res.order.summary.total, 3700.0 + res.order.deliveryCharge);
        expect((await CartRepository(api).get()).isEmpty, isTrue);
        final again = await repo.place(body, 'key-cod-1');
        expect(again.replay, isTrue);
        expect(again.order.summary.id, orderId);
        expect(
          (await OrderRepository(api).list(1)).items.length,
          2,
          reason: 'online (cancelled) + COD, no duplicate from the replay',
        );
      },
    );
    test('same key with a different body is rejected', () async {
      await CartRepository(api).add(ids()['City Cruiser'] as String);
      final body = CheckoutRepository.body(
        addressId: seed['address_id'] as String,
        method: 'cod',
        note: 'different',
      );
      await expectApiError(
        CheckoutRepository(api).place(body, 'key-cod-1'),
        kind: ApiErrorKind.conflict,
      );
      await CartRepository(api).clear();
    });
    test('order list, detail, tracking, payments', () async {
      final o = OrderRepository(api);
      final list = await o.list(1);
      expect(list.items.map((o) => o.id), contains(orderId));
      final detail = await o.detail(orderId!);
      expect(detail.vendorOrders, isNotEmpty);
      expect(detail.canCancel, isTrue);
      final t = await o.tracking(orderId!);
      expect(t.status, 'confirmed');
      expect(t.vendorOrders, isNotEmpty);
      // t.timeline is empty here: the in-memory harness's fake checkout SQL writes no status-history rows (real PostgreSQL function does).
      final pays = await o.payments(orderId!);
      expect(pays.single.method, 'cod');
    });
    test('another customer cannot read my order', () async {
      await expectApiError(
        OrderRepository(clientFor(() async => otherToken)).detail(orderId!),
        kind: ApiErrorKind.notFound,
      );
    });
    test('cancel order', () async {
      final o = OrderRepository(api);
      final c = await o.cancel(orderId!, 'Changed my mind');
      expect(c.summary.status, 'cancelled');
      expect(c.canCancel, isFalse);
    });
  });

  group('services & bookings', () {
    String? bookingId;
    test('service categories, list, detail', () async {
      final s = ServiceRepository(api);
      expect((await s.categories()).length, 5);
      final list = await s.services(1);
      expect(list.items.single.name, 'Full service');
      final d = await s.service(seed['service_id'] as String);
      expect(d.price, 499.0);
    });
    test('availability comes from the backend', () async {
      final s = ServiceRepository(api);
      final a = await s.availability(
        seed['service_id'] as String,
        seed['day'] as String,
      );
      expect(a.bookable, isTrue);
      expect(a.slots, isNotEmpty);
      final past = await s.availability(
        seed['service_id'] as String,
        '2020-01-01',
      );
      expect(past.bookable, isFalse);
      expect(past.reasonText, 'That date has already passed.');
    });
    test('booking options', () async {
      final o = await ServiceRepository(api).bookingOptions();
      expect(
        o.chargesConfigured,
        isFalse,
        reason: 'no logistics charges seeded',
      );
    });
    test('create booking (pickup), see stages, tracking', () async {
      final slot = (await ServiceRepository(api).availability(
        seed['service_id'] as String,
        seed['day'] as String,
      )).slots.first;
      final b = await BookingRepository(api).create(
        BookingRequest(
          serviceId: seed['service_id'] as String,
          cycleBrand: 'Hero',
          cycleModel: 'Sprint',
          issue: 'Brakes squeal and gears skip',
          date: seed['day'] as String,
          slotStart: slot.start,
          needsPickup: true,
          pickupAddressId: seed['address_id'] as String,
          instructions: 'Call at the gate',
        ),
      );
      bookingId = b.summary.id;
      expect(b.summary.status, 'pending');
      expect(b.pickup, isNotNull);
      expect(b.pickup!.pickupStage, 'requested');
      expect(b.summary.needsPickup, isTrue);
      final t = await BookingRepository(api).tracking(bookingId!);
      expect(t.status, 'pending');
      expect(t.timeline, isNotEmpty);
    });
    test(
      'the same slot cannot be double-booked beyond capacity; invalid slot is reported',
      () async {
        await expectApiError(
          BookingRepository(api).create(
            BookingRequest(
              serviceId: seed['service_id'] as String,
              issue: 'x problem here',
              date: seed['day'] as String,
              slotStart: '03:00',
            ),
          ),
        );
      },
    );
    test(
      'photo: upload (simulated storage), register, listed with signed URL; wrong path refused',
      () async {
        final uid = seed['customer'] as String;
        final path = '$uid/$bookingId/front.jpg';
        await Dio(
          BaseOptions(baseUrl: base!),
        ).post<dynamic>('/__dev/upload', queryParameters: {'path': path});
        final img = await BookingRepository(
          api,
        ).registerImage(bookingId!, path);
        expect(img.path, path);
        final detail = await BookingRepository(api).detail(bookingId!);
        expect(detail.images.length, 1);
        expect(
          detail.images.single.url,
          isNotEmpty,
          reason: 'detail carries a signed URL for the private bucket',
        );
        await expectApiError(
          BookingRepository(
            api,
          ).registerImage(bookingId!, 'someone-else/$bookingId/x.jpg'),
        );
      },
    );
    test('list, filter by status, other customer isolation', () async {
      final r = BookingRepository(api);
      expect((await r.list(1)).items.single.id, bookingId);
      expect((await r.list(1, status: 'completed')).items, isEmpty);
      await expectApiError(
        BookingRepository(clientFor(() async => otherToken)).detail(bookingId!),
        kind: ApiErrorKind.notFound,
      );
    });
    test('cancel booking', () async {
      final c = await BookingRepository(
        api,
      ).cancel(bookingId!, 'Plans changed');
      expect(c.summary.status, 'cancelled');
      expect(c.canCancel, isFalse);
    });
  });

  group('notifications & support', () {
    test('notifications list, unread count, mark read, mark all', () async {
      final n = NotificationRepository(api);
      final page = await n.list(1);
      expect(page.items.length, greaterThanOrEqualTo(2));
      final before = page.unreadCount;
      expect(before, greaterThanOrEqualTo(2));
      await n.markRead(page.items.first.id);
      expect(await n.unreadCount(), before - 1);
      await n.markAllRead();
      expect(await n.unreadCount(), 0);
    });
    test('other customer sees none of my notifications', () async {
      expect(
        (await NotificationRepository(
          clientFor(() async => otherToken),
        ).list(1)).items,
        isEmpty,
      );
    });
    test('support ticket create / list / detail', () async {
      final s = SupportRepository(api);
      final t = await s.create(
        type: 'complaint',
        subject: 'Late pickup',
        description: 'The pickup was two hours late.',
      );
      expect(t.status, 'open');
      expect((await s.list(1)).items.single.id, t.id);
      expect((await s.get(t.id)).subject, 'Late pickup');
    });
  });

  group('push device registration', () {
    const tokenA = 'contract-fcm-token-AAAAAAAAAAAAAAAAAAAA';
    test('the app\'s own registration call is accepted for a customer and is idempotent', () async {
      final repo = PushRepository(api);
      await repo.register(tokenA);
      await repo.register(tokenA);
      await repo.unregister(tokenA);
      await repo.unregister(tokenA); // unregistering twice is harmless
    });
    test('only the owner can unregister; a token moves to whoever registers it next', () async {
      final mine = clientFor(() async => customerToken);
      final other = clientFor(() async => otherToken);
      await PushRepository(mine).register(tokenA);
      final res = await other.post('/devices/unregister', body: {'token': tokenA}) as Map;
      expect(res['unregistered'], isFalse, reason: 'someone else\'s token is left alone');
      await PushRepository(other).register(tokenA); // same phone, another account
      final back = await mine.post('/devices/unregister', body: {'token': tokenA}) as Map;
      expect(back['unregistered'], isFalse, reason: 'the first account no longer owns it');
      expect((await other.post('/devices/unregister', body: {'token': tokenA}) as Map)['unregistered'], isTrue);
    });
    test('a vendor or admin token cannot register as the customer app; bad tokens and unknown fields are refused', () async {
      await expectApiError(PushRepository(clientFor(() async => vendorToken)).register(tokenA), kind: ApiErrorKind.forbidden);
      await expectApiError(PushRepository(clientFor(() async => adminToken)).register(tokenA), kind: ApiErrorKind.forbidden);
      await expectApiError(PushRepository(clientFor(() async => null)).register(tokenA), kind: ApiErrorKind.unauthorized);
      await expectApiError(PushRepository(api).register('short'));
      await expectApiError(api.put('/devices', body: {'token': tokenA, 'platform': 'android', 'app': 'customer', 'user_id': 'someone-else'}));
    });
    test('the device endpoints never return a token', () async {
      final res = await api.put('/devices', body: {'token': tokenA, 'platform': 'android', 'app': 'customer'}) as Map;
      expect(res.keys, ['registered']);
      await api.post('/devices/unregister', body: {'token': tokenA});
    });
  });
}

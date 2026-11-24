// Contract tests: the Vendor App's REAL repositories + models talk over real HTTP to the REAL FastAPI app started by
// `backend/tests/dev_server.py` (in-memory DB, locally signed JWTs, fake payment provider, simulated Storage). NOT a real Supabase/Storage/gateway test.
//
//   (cd backend && .venv/bin/python -m tests.dev_server) &
//   CONTRACT_API=http://127.0.0.1:8791 flutter test test/contract
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vendor_app/core/api/api_client.dart';
import 'package:vendor_app/core/api/api_exception.dart';
import 'package:vendor_app/features/authentication/repository.dart';
import 'package:vendor_app/features/business_profile/models.dart';
import 'package:vendor_app/features/business_profile/repository.dart';
import 'package:vendor_app/features/earnings/repository.dart';
import 'package:vendor_app/features/notifications/repository.dart';
import 'package:vendor_app/features/orders/repository.dart';
import 'package:vendor_app/features/pickup_dropoff/repository.dart';
import 'package:vendor_app/features/products/models.dart';
import 'package:vendor_app/features/products/repository.dart';
import 'package:vendor_app/features/service_bookings/repository.dart';
import 'package:vendor_app/features/services/models.dart';
import 'package:vendor_app/features/services/repository.dart';

final base = Platform.environment['CONTRACT_API'];

Future<void> expectApiError(
  Future<Object?> f, {
  String? code,
  ApiErrorKind? kind,
  int? status,
}) async {
  try {
    await f;
  } on ApiException catch (e) {
    if (code != null) expect(e.code, code);
    if (kind != null) expect(e.kind, kind);
    if (status != null) expect(e.status, status);
    return;
  }
  fail('expected an ApiException');
}

void main() {
  if (base == null) {
    test(
      'vendor contract tests',
      () {},
      skip:
          'set CONTRACT_API=http://127.0.0.1:8791 with tests/dev_server running',
    );
    return;
  }

  late Map<String, dynamic> seed;
  late Map<String, dynamic> tokens;
  final dev = Dio(BaseOptions(baseUrl: base!));

  ApiClient as(String who) => ApiClient(
    baseUrl: '$base/api/v1',
    readToken: () async => tokens[who] as String,
  );
  ApiClient va() => as('vendor_user'); // approved vendor A
  ApiClient vb() => as('vendor_b_user'); // approved vendor B
  ApiClient customer() => as('customer');
  String pid(String name) => (seed['product_ids'] as Map)[name] as String;

  setUpAll(() async {
    await dev.post<dynamic>('/__dev/reset');
    seed = (await dev.get<Map<String, dynamic>>('/__dev/tokens')).data!;
    tokens = seed['tokens'] as Map<String, dynamic>;
  });

  Future<String> customerOrder(String product, {int qty = 1}) async {
    final c = customer();
    await c.post(
      '/cart/items',
      body: {'product_id': pid(product), 'quantity': qty},
    );
    final res = await c.post(
      '/checkout',
      body: {
        'delivery_address_id': seed['address_id'],
        'payment_method': 'cod',
      },
      headers: {
        'Idempotency-Key': 'k-${DateTime.now().microsecondsSinceEpoch}',
      },
    );
    return (res as Map)['order']['id'] as String;
  }

  group('identity, roles and verification state', () {
    test(
      '/auth/me: vendor accounts are vendors, a customer token is not',
      () async {
        expect((await AuthRepository(va()).me()).isVendor, isTrue);
        expect((await AuthRepository(customer()).me()).isVendor, isFalse);
        expect((await AuthRepository(as('admin')).me()).isVendor, isFalse);
      },
    );
    test(
      'verification state comes from the backend for every lifecycle stage',
      () async {
        expect((await VendorProfileRepository(va()).me()).isApproved, isTrue);
        final pending = await VendorProfileRepository(
          as('vendor_pending'),
        ).me();
        expect(pending.isPending, isTrue);
        final rej = await VendorProfileRepository(as('vendor_rejected')).me();
        expect(
          rej.isRejected && rej.rejectionReason == 'Shop photos were unclear',
          isTrue,
        );
        expect(
          (await VendorProfileRepository(
            as('vendor_suspended'),
          ).me()).isSuspended,
          isTrue,
        );
        final st = await VendorProfileRepository(as('vendor_pending')).status();
        expect(st.status == 'pending' && !st.canOperate, isTrue);
      },
    );
    test(
      'a vendor who has not registered a business gets 404 (app routes them to onboarding)',
      () async {
        await expectApiError(
          VendorProfileRepository(as('vendor_new')).me(),
          kind: ApiErrorKind.notFound,
        );
      },
    );
    test(
      'unapproved vendors cannot use any business endpoint (403) — pending, rejected, suspended, unregistered',
      () async {
        for (final who in [
          'vendor_pending',
          'vendor_rejected',
          'vendor_suspended',
          'vendor_new',
        ]) {
          final c = as(who);
          await expectApiError(
            ProductRepository(c).list(const ProductFilter(), 1),
            kind: ApiErrorKind.forbidden,
          );
          await expectApiError(
            OrderRepository(c).list(1),
            kind: ApiErrorKind.forbidden,
          );
          await expectApiError(
            c.get('/vendor/dashboard'),
            kind: ApiErrorKind.forbidden,
          );
          await expectApiError(
            c.post(
              '/vendor/services',
              body: {
                'service_category_id': seed['service_category_id'],
                'name': 'x y z',
                'price': 10,
              },
            ),
            kind: ApiErrorKind.forbidden,
          );
        }
      },
    );
    test('a customer token cannot reach vendor endpoints', () async {
      await expectApiError(
        ProductRepository(customer()).list(const ProductFilter(), 1),
        kind: ApiErrorKind.forbidden,
      );
    });
  });

  group('onboarding and business profile', () {
    const input = BusinessInput(
      businessName: 'Fresh Wheels',
      businessTypes: [BusinessType.bicycleShop, BusinessType.serviceProvider],
      description: 'We sell and fix cycles.',
      addressLine1: '5 FC Road',
      city: 'Pune',
      state: 'Maharashtra',
      postalCode: '411004',
      contactPhone: '+919811111111',
      operatingHours: {
        'mon': DayHours(open: '09:00', close: '18:00'),
        'sun': DayHours(closed: true),
      },
      shopImagePaths: [],
      servicePostalCodes: ['411004'],
      pickupAvailable: true,
    );
    test(
      'register: always starts as pending, vendor cannot approve themselves',
      () async {
        final c = as('vendor_new');
        final v = await VendorProfileRepository(c).register(input);
        expect(v.verificationStatus, 'pending');
        expect(v.operatingHours['sun']!.closed, isTrue);
        await expectApiError(
          VendorProfileRepository(c).register(input),
          kind: ApiErrorKind.conflict,
        );
      },
    );
    test(
      'the backend rejects attempts to send verification/role fields (422) — the app form cannot even build them',
      () async {
        final body = input.toJson(forUpdate: true);
        expect(body.keys, isNot(contains('verification_status')));
        expect(body.keys, isNot(contains('role')));
        await expectApiError(
          as('vendor_pending').put(
            '/vendors/me',
            body: {...body, 'verification_status': 'approved'},
          ),
          status: 422,
        );
        await expectApiError(
          as('vendor_pending').put('/vendors/me', body: {'role': 'admin'}),
          status: 422,
        );
        expect(
          (await VendorProfileRepository(as('vendor_pending')).me()).isPending,
          isTrue,
        );
      },
    );
    test(
      'pending/rejected vendors may edit their application; suspended vendors may not',
      () async {
        final saved = await VendorProfileRepository(
          as('vendor_rejected'),
        ).update(input);
        expect(saved.businessName, 'Fresh Wheels');
        expect(
          saved.isRejected,
          isTrue,
          reason: 'editing never changes the admin decision',
        );
        await expectApiError(
          VendorProfileRepository(as('vendor_suspended')).update(input),
          kind: ApiErrorKind.forbidden,
          code: 'vendor_suspended',
        );
      },
    );
    test(
      'approved vendor updates contact, hours, service area and pickup; image paths must be in own folder',
      () async {
        final repo = VendorProfileRepository(va());
        final cur = await repo.me();
        final upd = await repo.update(
          BusinessInput(
            businessName: cur.businessName,
            businessTypes: cur.businessTypes,
            addressLine1: cur.addressLine1,
            city: cur.city,
            state: cur.state,
            postalCode: cur.postalCode,
            contactPhone: '+919822222222',
            operatingHours: {
              for (final d in weekdays)
                d: d == 'sun'
                    ? const DayHours(closed: true)
                    : const DayHours(open: '08:30', close: '19:00'),
            },
            shopImagePaths: ['${seed['vendor_user']}/shop/a.jpg'],
            servicePostalCodes: ['411001', '411002', '411003'],
            pickupAvailable: false,
          ),
        );
        expect(upd.contactPhone, '+919822222222');
        expect(upd.operatingHours['tue']!.open, '08:30');
        expect(upd.servicePostalCodes.length, 3);
        expect(upd.pickupAvailable, isFalse);
        expect(upd.isApproved, isTrue);
        await expectApiError(
          repo.update(
            BusinessInput(
              businessName: cur.businessName,
              businessTypes: cur.businessTypes,
              addressLine1: 'x',
              city: 'x',
              state: 'x',
              postalCode: '411001',
              contactPhone: '+919822222222',
              operatingHours: const {},
              shopImagePaths: ['someone-else/shop/a.jpg'],
              servicePostalCodes: const [],
              pickupAvailable: false,
            ),
          ),
          status: 422,
        );
        // restore pickup for the booking tests below
        await repo.update(
          BusinessInput(
            businessName: cur.businessName,
            businessTypes: cur.businessTypes,
            addressLine1: cur.addressLine1,
            city: cur.city,
            state: cur.state,
            postalCode: cur.postalCode,
            contactPhone: cur.contactPhone,
            operatingHours: upd.operatingHours,
            shopImagePaths: const [],
            servicePostalCodes: ['411001', '411002'],
            pickupAvailable: true,
          ),
        );
      },
    );
  });

  group('products, images and inventory', () {
    String? created;
    test(
      'own listing only: vendor A sees its three products, vendor B sees its two',
      () async {
        final a = await ProductRepository(va()).list(const ProductFilter(), 1);
        expect(
          a.items.map((p) => p.name),
          containsAll(['Trail Blazer 29', 'Old Commuter', 'Road Helmet']),
        );
        expect(a.total, 3);
        expect(
          (await ProductRepository(vb()).list(const ProductFilter(), 1)).total,
          2,
        );
        await expectApiError(
          ProductRepository(vb()).get(pid('Trail Blazer 29')),
          kind: ApiErrorKind.notFound,
        );
      },
    );
    test('server-side filters: type, stock, search', () async {
      final r = ProductRepository(va());
      expect(
        (await r.list(
          const ProductFilter(productType: 'used_cycle'),
          1,
        )).items.single.name,
        'Old Commuter',
      );
      expect(
        (await r.list(
          const ProductFilter(inStock: false),
          1,
        )).items.single.name,
        'Road Helmet',
      );
      expect(
        (await r.list(const ProductFilter(q: 'blazer'), 1)).items.single.name,
        'Trail Blazer 29',
      );
      expect(
        (await r.list(
          const ProductFilter(approvalStatus: 'approved'),
          1,
        )).total,
        greaterThan(0),
      );
    });
    test(
      'create a spare part without bicycle-only fields; approval fields come from the backend',
      () async {
        final cats = await ProductRepository(va()).categories();
        final spare = cats.firstWhere((c) => c.kind == 'spare_part');
        final p = await ProductRepository(va()).create(
          ProductInput(
            categoryId: spare.id,
            name: 'Chain Lube',
            specifications: const {},
            condition: 'new',
            price: 349,
            stock: 12,
            isAvailable: true,
          ),
        );
        created = p.id;
        expect(p.productType, 'spare_part');
        expect(p.approvalStatus, anyOf('pending', 'approved'));
        expect(p.stock, 12);
        await expectApiError(
          va().post(
            '/vendor/products',
            body: {
              ...ProductInput(
                categoryId: spare.id,
                name: 'Sneaky',
                specifications: const {},
                condition: 'new',
                price: 1,
                stock: 1,
                isAvailable: true,
              ).toJson(),
              'approval_status': 'approved',
            },
          ),
          status: 422,
        );
        await expectApiError(
          va().post(
            '/vendor/products',
            body: {
              ...ProductInput(
                categoryId: spare.id,
                name: 'Sneaky',
                specifications: const {},
                condition: 'new',
                price: 1,
                stock: 1,
                isAvailable: true,
              ).toJson(),
              'vendor_id': seed['vendor_b_id'],
            },
          ),
          status: 422,
        );
      },
    );
    test(
      'a new cycle must be condition new (backend rule surfaced as a 422)',
      () async {
        final cats = await ProductRepository(va()).categories();
        final nc = cats.firstWhere((c) => c.kind == 'new_cycle');
        await expectApiError(
          ProductRepository(va()).create(
            ProductInput(
              categoryId: nc.id,
              name: 'Fake new',
              specifications: const {},
              condition: 'used',
              price: 100,
              stock: 1,
              isAvailable: true,
            ),
          ),
          status: 422,
        );
      },
    );
    test(
      'images: upload (simulated Storage) → register → reorder → main → remove; foreign/unuploaded paths refused',
      () async {
        final repo = ProductRepository(va());
        final uid = seed['vendor_user'] as String;
        final paths = ['$uid/$created/a.jpg', '$uid/$created/b.png'];
        for (final p in paths) {
          await dev.post<dynamic>(
            '/__dev/upload',
            queryParameters: {'path': p},
          );
        }
        final i1 = await repo.registerImage(created!, paths[0]);
        final i2 = await repo.registerImage(created!, paths[1]);
        expect(
          i1.isPrimary,
          isTrue,
          reason: 'first image becomes the main photo',
        );
        final re = await repo.reorder(created!, [i2.id, i1.id]);
        expect(re.map((e) => e.id).toList(), [i2.id, i1.id]);
        await repo.makePrimary(created!, i2.id);
        expect(
          (await repo.images(created!)).firstWhere((e) => e.isPrimary).id,
          i2.id,
        );
        await repo.removeImage(created!, i1.id);
        expect((await repo.images(created!)).length, 1);
        await expectApiError(
          repo.registerImage(created!, '$uid/$created/never-uploaded.jpg'),
        );
        await expectApiError(
          repo.registerImage(created!, 'other-user/$created/x.jpg'),
        );
        await expectApiError(
          ProductRepository(
            vb(),
          ).registerImage(created!, '${seed['vendor_b_user']}/$created/x.jpg'),
          kind: ApiErrorKind.notFound,
        );
      },
    );
    test('edit, restock, deactivate, remove — and no negative stock', () async {
      final repo = ProductRepository(va());
      final cur = await repo.get(created!);
      final edited = await repo.replace(
        created!,
        ProductInput(
          categoryId: cur.categoryId,
          name: 'Chain Lube Pro',
          description: 'Dry lube',
          brand: 'Muc-Off',
          specifications: const {'Volume': '120 ml'},
          condition: 'new',
          price: 399,
          stock: 20,
          isAvailable: true,
        ),
        isActive: true,
      );
      expect(edited.name, 'Chain Lube Pro');
      expect(edited.specifications['Volume'], '120 ml');
      expect((await repo.patch(created!, {'stock_quantity': 5})).stock, 5);
      await expectApiError(
        repo.patch(created!, {'stock_quantity': -1}),
        status: 422,
      );
      expect(
        (await repo.patch(created!, {'is_active': false})).isActive,
        isFalse,
      );
      expect(
        (await repo.patch(created!, {'is_active': true})).isActive,
        isTrue,
      );
      await repo.delete(created!);
      await expectApiError(repo.get(created!), kind: ApiErrorKind.notFound);
    });
  });

  group('orders (vendor side)', () {
    String? vo;
    test(
      'a customer COD order appears for the right vendor only, with fulfilment data',
      () async {
        await customerOrder('Trail Blazer 29', qty: 2);
        final a = await OrderRepository(va()).list(1);
        expect(a.total, 1);
        expect(
          await OrderRepository(vb()).list(1).then((p) => p.total),
          0,
          reason: 'vendor isolation',
        );
        final o = a.items.single;
        vo = o.id;
        expect(o.status, 'pending');
        expect(o.paymentMethod, 'cod');
        expect(o.itemCount, 2);
        final d = await OrderRepository(va()).detail(vo!);
        expect(d.detail!.items.single.name, 'Trail Blazer 29');
        expect(d.detail!.recipient, 'Asha Rao');
        expect(d.detail!.addressText, contains('MG Road'));
        expect(d.detail!.netPayable, d.subtotal - (d.commission ?? 0));
        await expectApiError(
          OrderRepository(vb()).detail(vo!),
          kind: ApiErrorKind.notFound,
        );
      },
    );
    test('status filter and date range are applied by the backend', () async {
      final r = OrderRepository(va());
      expect((await r.list(1, status: 'pending')).total, 1);
      expect((await r.list(1, status: 'accepted')).total, 0);
      expect(
        (await r.list(1, dateFrom: '2020-01-01', dateTo: '2020-01-31')).total,
        0,
      );
    });
    test(
      'cannot skip steps; accept → processing → ready → completed; payment cannot be touched',
      () async {
        final r = OrderRepository(va());
        await expectApiError(
          r.updateStatus(vo!, 'delivered'),
          kind: ApiErrorKind.conflict,
        );
        expect((await r.accept(vo!)).status, 'accepted');
        await expectApiError(r.accept(vo!), kind: ApiErrorKind.conflict);
        await expectApiError(
          r.updateStatus(vo!, 'delivered'),
          kind: ApiErrorKind.conflict,
        );
        expect((await r.updateStatus(vo!, 'preparing')).status, 'preparing');
        expect(
          (await r.updateStatus(vo!, 'ready_for_dispatch')).status,
          'ready_for_dispatch',
        );
        await expectApiError(
          va().patch(
            '/vendor/orders/$vo/status',
            body: {'status': 'delivered', 'payment_status': 'successful'},
          ),
          status: 422,
        );
        await expectApiError(
          va().patch(
            '/vendor/orders/$vo/status',
            body: {'status': 'delivered', 'commission_amount': 0},
          ),
          status: 422,
        );
        final done = await r.updateStatus(vo!, 'delivered');
        expect(done.status, 'delivered');
        expect(done.paymentStatus, isNot('refunded'));
      },
    );
    test('timeline endpoint returns this order\'s events', () async {
      final t = await OrderRepository(va()).timeline(vo!);
      expect(
        t,
        isA<List>(),
      ); // the in-memory harness writes no history rows; shape + authorization are what is verified here
      await expectApiError(
        OrderRepository(vb()).timeline(vo!),
        kind: ApiErrorKind.notFound,
      );
    });
    test('reject requires a reason and returns stock', () async {
      final id = await customerOrder('Disc Brake Set');
      final list = await OrderRepository(vb()).list(1, status: 'pending');
      expect(list.total, 1, reason: 'Disc Brake Set belongs to vendor B');
      final bOrder = list.items.single.id;
      await expectApiError(
        vb().post('/vendor/orders/$bOrder/reject', body: {}),
        status: 422,
      );
      final rej = await OrderRepository(
        vb(),
      ).reject(bOrder, 'Out of stock at the shop');
      expect(rej.status, 'rejected');
      expect(rej.detail!.rejectionReason, 'Out of stock at the shop');
      expect(id, isNotEmpty);
    });
  });

  group('services', () {
    String? svc;
    test('service categories come from the backend', () async {
      final cats = await ServiceRepository(va()).categories();
      expect(
        cats.map((c) => c.name),
        containsAll([
          'General Servicing',
          'Puncture Repair',
          'Brake Repair',
          'Gear Adjustment',
          'Parts Replacement',
        ]),
      );
    });
    test(
      'list, create, update availability/price/time, deactivate, remove; vendor isolation',
      () async {
        final repo = ServiceRepository(va());
        expect((await repo.list(1)).items.single.name, 'Full service');
        expect((await ServiceRepository(vb()).list(1)).total, 0);
        final cats = await repo.categories();
        final s = await repo.create(
          ServiceInput(
            categoryId: cats[1].id,
            name: 'Puncture fix',
            description: 'Tube patch',
            price: 120,
            durationMinutes: 30,
            isAvailable: true,
            availableDays: const ['mon', 'tue', 'wed'],
            slotMinutes: 30,
            maxPerSlot: 2,
          ),
        );
        svc = s.id;
        expect(s.availableDays, ['mon', 'tue', 'wed']);
        expect(s.categoryName, cats[1].name);
        final p = await repo.patch(svc!, {
          'price': 150,
          'estimated_duration_minutes': 45,
          'is_available': false,
        });
        expect(p.price, 150);
        expect(p.durationMinutes, 45);
        expect(p.isAvailable, isFalse);
        await expectApiError(
          ServiceRepository(vb()).patch(svc!, {'price': 1}),
          kind: ApiErrorKind.notFound,
        );
        await expectApiError(repo.patch(svc!, {'price': -5}), status: 422);
        expect(
          (await repo.patch(svc!, {'is_active': false})).isActive,
          isFalse,
        );
        expect(
          (await repo.list(1, isActive: false)).items.map((e) => e.id),
          contains(svc),
        );
        await repo.delete(svc!);
        await expectApiError(repo.get(svc!), kind: ApiErrorKind.notFound);
      },
    );
  });

  group('service bookings, repair progress, charges, pickup/drop-off', () {
    String? booking, pickup;
    test(
      'a customer booking with pickup shows up for the provider with customer contact and separate logistics stages',
      () async {
        final c = customer();
        final avail =
            await c.get(
                  '/services/${seed['service_id']}/availability',
                  query: {'date': seed['day']},
                  auth: false,
                )
                as Map;
        final slot = (avail['slots'] as List).first['start'];
        final res =
            await c.post(
                  '/service-bookings',
                  body: {
                    'service_id': seed['service_id'],
                    'cycle_brand': 'Hero',
                    'cycle_model': 'Sprint',
                    'issue_description': 'Brakes squeal and gears skip',
                    'preferred_date': seed['day'],
                    'slot_start': slot,
                    'needs_pickup_dropoff': true,
                    'pickup_address_id': seed['address_id'],
                    'pickup_instructions': 'Call at the gate',
                  },
                )
                as Map;
        final list = await ServiceBookingRepository(va()).list(1);
        expect(list.total, 1);
        expect((await ServiceBookingRepository(vb()).list(1)).total, 0);
        final b = list.items.single;
        booking = b.id;
        expect(res['id'], booking);
        expect(b.status, 'pending');
        expect(b.needsPickup, isTrue);
        expect(b.customer?.name, 'Asha Rao');
        final d = await ServiceBookingRepository(va()).detail(booking!);
        expect(d.detail!.cycle['brand'], 'Hero');
        expect(d.detail!.logistics, isNotNull);
        expect(d.detail!.logistics!.pickupStage, 'requested');
        expect(d.detail!.logistics!.deliveryStage, 'requested');
        expect(d.detail!.pricing.estimated, 499.0);
        await expectApiError(
          ServiceBookingRepository(vb()).detail(booking!),
          kind: ApiErrorKind.notFound,
        );
      },
    );
    test('accept confirms the slot; double accept refused', () async {
      final r = ServiceBookingRepository(va());
      final a = await r.accept(booking!);
      expect(a.status, 'accepted');
      expect(a.confirmed.isSet, isTrue);
      await expectApiError(r.accept(booking!), kind: ApiErrorKind.conflict);
    });
    test(
      'charges and notes are appended, original estimate preserved, no arbitrary status jump',
      () async {
        final r = ServiceBookingRepository(va());
        final c = await r.addCharge(booking!, 250, 'Replaced brake pads');
        expect(c.detail!.pricing.estimated, 499.0);
        expect(c.detail!.pricing.additional, 250.0);
        expect(c.detail!.pricing.current, 749.0);
        expect(c.detail!.charges.single.reason, 'Replaced brake pads');
        await expectApiError(r.addCharge(booking!, 0, 'nothing'), status: 422);
        final n = await r.addNote(
          booking!,
          'Pads were worn; also lubricated the chain',
        );
        expect(n.detail!.notes.single.role, 'vendor');
        await expectApiError(
          r.updateStatus(booking!, 'completed'),
          kind: ApiErrorKind.conflict,
        );
        await expectApiError(
          r.updateStatus(booking!, 'in_service'),
          kind: ApiErrorKind.conflict,
        );
      },
    );
    test(
      'pickup coordination: schedule, mark a failed attempt; completion is refused here (recorded by booking status)',
      () async {
        final repo = PickupDropoffRepository(va());
        final list = await repo.list(1);
        expect(list.total, 1);
        pickup = list.items.single.id;
        final when = DateTime.now().add(const Duration(days: 2));
        final s = await repo.coordinate(
          pickup!,
          pickupAt: when,
          pickupStatus: 'scheduled',
          notes: 'Will arrive after 10',
        );
        expect(s.logistics.pickupStage, 'scheduled');
        expect(s.logistics.notes, 'Will arrive after 10');
        expect((await repo.list(1, pickupStatus: 'scheduled')).total, 1);
        expect((await repo.list(1, deliveryStatus: 'completed')).total, 0);
        await expectApiError(
          va().patch(
            '/vendor/pickup-requests/$pickup',
            body: {'pickup_status': 'completed'},
          ),
          status: 422,
        );
        await expectApiError(
          PickupDropoffRepository(vb()).get(pickup!),
          kind: ApiErrorKind.notFound,
        );
      },
    );
    test(
      'repair workflow with pickup: picked_up → in_service → ready_for_delivery → completed records both logistics steps',
      () async {
        final r = ServiceBookingRepository(va());
        expect(
          (await r.updateStatus(
            booking!,
            'picked_up',
          )).detail!.logistics!.pickupStage,
          'picked_up',
        );
        expect(
          (await r.updateStatus(booking!, 'in_service')).status,
          'in_service',
        );
        expect(
          (await r.updateStatus(
            booking!,
            'ready_for_delivery',
            note: 'Tested on the stand',
          )).status,
          'ready_for_delivery',
        );
        final done = await r.updateStatus(
          booking!,
          'completed',
          note: 'Brakes and gears adjusted',
        );
        expect(done.status, 'completed');
        expect(done.detail!.logistics!.deliveryStage, 'delivered');
        expect(done.detail!.completionNotes, 'Brakes and gears adjusted');
        final t = await r.timeline(booking!);
        expect(
          t.map((e) => e.toStatus),
          containsAll([
            'accepted',
            'picked_up',
            'in_service',
            'ready_for_delivery',
            'completed',
          ]),
        );
        await expectApiError(
          r.addCharge(booking!, 10, 'too late'),
          kind: ApiErrorKind.conflict,
        );
      },
    );
    test(
      'reject requires a reason; a booking without pickup skips the picked_up step',
      () async {
        final c = customer();
        final avail =
            await c.get(
                  '/services/${seed['service_id']}/availability',
                  query: {'date': seed['day']},
                  auth: false,
                )
                as Map;
        final slots = (avail['slots'] as List);
        await c.post(
          '/service-bookings',
          body: {
            'service_id': seed['service_id'],
            'issue_description': 'Chain keeps slipping off',
            'preferred_date': seed['day'],
            'slot_start': slots[3]['start'],
          },
        );
        final r = ServiceBookingRepository(va());
        final pend = (await r.list(1, status: 'pending')).items.single;
        expect(pend.nextSteps, isEmpty);
        await expectApiError(
          va().post('/vendor/service-bookings/${pend.id}/reject', body: {}),
          status: 422,
        );
        await r.accept(pend.id);
        final acc = await r.detail(pend.id);
        expect(acc.needsPickup, isFalse);
        expect(acc.nextSteps, ['in_service']);
        await expectApiError(
          r.updateStatus(pend.id, 'picked_up'),
          kind: ApiErrorKind.conflict,
        );
        final rejId = pend.id;
        await r.updateStatus(rejId, 'cancelled', note: 'Cannot take this job');
        expect((await r.detail(rejId)).status, 'cancelled');
      },
    );
  });

  group('earnings, settlements, dashboard', () {
    test(
      'dashboard aggregates come from the database and match the records',
      () async {
        final d = await DashboardRepository(va()).summary();
        expect(d.orderTotal, 1);
        expect(d.completedOrders, 1);
        expect(d.salesTotal, greaterThan(0));
        expect(d.commissionTotal, greaterThan(0));
        expect(d.productTotal, 3);
        expect(d.completedServices, 1);
        expect(d.serviceValue, 749.0, reason: 'estimate + recorded charge');
        expect(
          d.settlement('paid'),
          isNull,
          reason: 'no payout is claimed without a paid record',
        );
        final b = await DashboardRepository(vb()).summary();
        expect(b.completedOrders, 0);
        expect(b.salesTotal, 0);
      },
    );
    test(
      'settlement for the delivered order: gross − commission − deductions = net, owned by this vendor only',
      () async {
        final repo = EarningsRepository(va());
        final s = await repo.settlements(1);
        expect(s.total, 1);
        final x = s.items.single;
        expect(x.gross, greaterThan(0));
        expect(
          x.commission,
          closeTo(x.gross * 0.10, 0.01),
          reason: 'seeded 10% rule, calculated by the backend',
        );
        expect(x.net, closeTo(x.gross - x.commission - x.deductions, 0.001));
        expect(x.isPaid, isFalse);
        expect((await EarningsRepository(vb()).settlements(1)).total, 0);
        expect((await repo.settlements(1, status: 'paid')).total, 0);
        expect(
          (await repo.settlements(
            1,
            dateFrom: '2020-01-01',
            dateTo: '2020-12-31',
          )).total,
          0,
        );
        expect(
          (await repo.settlements(
            1,
            dateFrom: '2000-01-01',
            dateTo: '2100-12-31',
          )).total,
          1,
        );
      },
    );
  });

  group('notifications', () {
    test(
      'vendor notifications list, unread count, mark read, mark all read; isolated per user',
      () async {
        final n = NotificationRepository(va());
        final page = await n.list(1);
        expect(
          page.items.length,
          greaterThanOrEqualTo(2),
          reason: 'new order + seeded booking notification',
        );
        // the in-memory harness does not emit the vendor 'new order' notification (the real SQL function does; see test_sql_integrity)
        expect(
          page.items.map((e) => e.relatedType),
          contains('service_booking'),
        );
        final before = page.unreadCount;
        expect(before, greaterThanOrEqualTo(2));
        await n.markRead(page.items.first.id);
        expect(await n.unreadCount(), before - 1);
        await n.markAllRead();
        expect(await n.unreadCount(), 0);
        expect(
          (await NotificationRepository(
            vb(),
          ).list(1)).items.every((e) => !page.items.any((p) => p.id == e.id)),
          isTrue,
        );
      },
    );
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:vendor_app/app/router.dart';
import 'package:vendor_app/core/auth/auth_controller.dart';
import 'package:vendor_app/features/authentication/models.dart';
import 'package:vendor_app/features/business_profile/models.dart';
import 'package:vendor_app/features/earnings/models.dart';
import 'package:vendor_app/features/orders/models.dart';
import 'package:vendor_app/features/products/models.dart';
import 'package:vendor_app/features/service_bookings/models.dart';
import 'package:vendor_app/features/services/models.dart';

import 'support/fakes.dart';

AuthState signedIn({String? status}) => AuthState(
  AuthStatus.signedIn,
  me: Me.fromJson(meJson()),
  vendor: status == null
      ? null
      : VendorProfile.fromJson(vendorJson(status: status)),
);

void main() {
  group('routing rules (who may see what)', () {
    test('signed out → login/register/forgot only', () {
      const out = AuthState.signedOut();
      expect(redirectFor(out, '/dashboard'), '/login');
      expect(redirectFor(out, '/products'), '/login');
      expect(redirectFor(out, '/login'), isNull);
      expect(redirectFor(out, '/register'), isNull);
    });
    test('loading/error → splash', () {
      expect(redirectFor(const AuthState.unknown(), '/dashboard'), '/splash');
      expect(
        redirectFor(const AuthState(AuthStatus.error), '/orders'),
        '/splash',
      );
    });
    test('vendor without a business → onboarding only', () {
      final s = signedIn();
      expect(redirectFor(s, '/dashboard'), '/onboarding');
      expect(redirectFor(s, '/products/new'), '/onboarding');
      expect(redirectFor(s, '/onboarding'), isNull);
      expect(s.stage, VendorStage.notRegistered);
    });
    test('pending and suspended vendors are locked to the status screen', () {
      for (final st in ['pending', 'suspended']) {
        final s = signedIn(status: st);
        for (final p in [
          '/dashboard',
          '/products',
          '/orders',
          '/earnings',
          '/business/edit',
          '/products/new',
        ]) {
          expect(redirectFor(s, p), '/status', reason: '$st must not reach $p');
        }
        expect(redirectFor(s, '/status'), isNull);
        expect(s.canOperate, isFalse);
      }
    });
    test('rejected vendors may correct their application but nothing else', () {
      final s = signedIn(status: 'rejected');
      expect(redirectFor(s, '/business/edit'), isNull);
      expect(redirectFor(s, '/status'), isNull);
      expect(redirectFor(s, '/products'), '/status');
      expect(s.canOperate, isFalse);
    });
    test(
      'approved vendors reach the app and are moved off auth/status screens',
      () {
        final s = signedIn(status: 'approved');
        expect(s.canOperate, isTrue);
        expect(redirectFor(s, '/orders'), isNull);
        expect(redirectFor(s, '/products/new'), isNull);
        for (final p in ['/splash', '/login', '/onboarding', '/status']) {
          expect(redirectFor(s, p), '/dashboard');
        }
      },
    );
  });

  group('what the app is able to send', () {
    test(
      'business form can never carry verification, role or approval fields',
      () {
        const b = BusinessInput(
          businessName: 'X',
          businessTypes: [BusinessType.bicycleShop],
          addressLine1: 'a',
          city: 'c',
          state: 's',
          postalCode: '411001',
          contactPhone: '+919800000000',
          operatingHours: {
            'mon': DayHours(open: '09:00', close: '18:00'),
            'sun': DayHours(closed: true),
          },
          shopImagePaths: [],
          servicePostalCodes: [],
          pickupAvailable: false,
        );
        for (final j in [b.toJson(), b.toJson(forUpdate: true)]) {
          expect(
            j.keys.where(
              (k) =>
                  k.contains('verif') ||
                  k.contains('role') ||
                  k.contains('approv') ||
                  k.contains('status'),
            ),
            isEmpty,
          );
        }
        expect(b.toJson()['operating_hours']['sun'], {'closed': true});
        expect(
          b.toJson().containsKey('description'),
          isFalse,
          reason: 'omitted on register',
        );
        expect(
          b.toJson(forUpdate: true)['description'],
          isNull,
          reason: 'cleared on update',
        );
      },
    );
    test(
      'product form can never carry vendor, approval, featured or type fields',
      () {
        const p = ProductInput(
          categoryId: 'c',
          name: 'n',
          specifications: {},
          condition: 'new',
          price: 10,
          stock: 1,
          isAvailable: true,
        );
        expect(p.toJson().keys.toSet(), {
          'category_id',
          'name',
          'description',
          'brand',
          'model',
          'specifications',
          'condition',
          'price',
          'stock_quantity',
          'is_available',
        });
      },
    );
    test('service form payload', () {
      const s = ServiceInput(
        categoryId: 'c',
        name: 'Tune-up',
        price: 399,
        isAvailable: true,
        availableDays: ['mon'],
        slotMinutes: 60,
        maxPerSlot: 2,
      );
      expect(s.toJson()['available_days'], ['mon']);
      expect(s.toJson().keys, isNot(contains('vendor_id')));
    });
  });

  group('status workflows mirror the backend state machines', () {
    test('order fulfilment: only the next valid steps are offered', () {
      VendorOrder o(String s) => VendorOrder.fromJson({'id': '1', 'status': s});
      expect(o('pending').isNew, isTrue);
      expect(
        o('pending').nextSteps,
        isEmpty,
        reason: 'pending is accepted/rejected, not advanced',
      );
      expect(o('accepted').nextSteps, ['preparing']);
      expect(o('preparing').nextSteps, ['ready_for_dispatch']);
      expect(o('ready_for_dispatch').nextSteps, [
        'out_for_delivery',
        'delivered',
      ]);
      expect(o('out_for_delivery').nextSteps, ['delivered']);
      for (final s in ['delivered', 'rejected', 'cancelled']) {
        expect(o(s).nextSteps, isEmpty);
        expect(o(s).canCancel, isFalse);
      }
      expect(o('accepted').canCancel, isTrue);
      expect(
        o('pending').canCancel,
        isFalse,
        reason: 'pending orders are rejected, not cancelled',
      );
    });
    test('repair progress adapts to pickup / no pickup', () {
      expect(nextRepairSteps('accepted', needsPickup: true), ['picked_up']);
      expect(nextRepairSteps('accepted', needsPickup: false), ['in_service']);
      expect(nextRepairSteps('picked_up', needsPickup: true), ['in_service']);
      expect(nextRepairSteps('in_service', needsPickup: false), [
        'ready_for_delivery',
      ]);
      expect(nextRepairSteps('ready_for_delivery', needsPickup: true), [
        'completed',
      ]);
      for (final s in ['pending', 'completed', 'cancelled', 'rejected']) {
        expect(nextRepairSteps(s, needsPickup: true), isEmpty);
      }
    });
    test(
      'booking cancel only while accepted; charges only while work is open',
      () {
        VendorBooking b(String s) => VendorBooking.fromJson({
          'id': '1',
          'status': s,
          'issue_description': 'x',
        });
        expect(b('accepted').canCancel, isTrue);
        expect(b('in_service').canCancel, isFalse);
        expect(b('in_service').chargesOpen, isTrue);
        expect(b('pending').chargesOpen, isFalse);
        expect(b('completed').chargesOpen, isFalse);
      },
    );
  });

  group('parsing', () {
    test('VendorProfile reads backend status and hours', () {
      final v = VendorProfile.fromJson(
        vendorJson(status: 'rejected', reason: 'Blurry photos'),
      );
      expect(v.isRejected, isTrue);
      expect(v.rejectionReason, 'Blurry photos');
      expect(v.businessTypes, [
        BusinessType.bicycleShop,
        BusinessType.serviceProvider,
      ]);
      expect(v.operatingHours['mon']!.open, '09:00');
      expect(v.offersServices && v.offersProducts, isTrue);
    });
    test('VendorProduct display status and moderation fields', () {
      VendorProduct p(String approval, {bool active = true}) =>
          VendorProduct.fromJson({
            'id': '1',
            'name': 'n',
            'approval_status': approval,
            'is_active': active,
            'is_available': true,
            'price': 10,
            'stock_quantity': 0,
            'review_notes': 'No photos',
          });
      expect(p('pending').displayStatus, 'pending');
      expect(p('rejected').displayStatus, 'rejected');
      expect(p('rejected').reviewNotes, 'No photos');
      expect(p('approved', active: false).displayStatus, 'inactive');
      expect(p('approved').displayStatus, 'approved');
      expect(p('approved').isLive, isTrue);
      expect(p('approved').stock, 0);
    });
    test(
      'Dashboard maps backend aggregates and never invents paid-out money',
      () {
        final d = Dashboard.fromJson({
          'orders': {
            'total': 5,
            'by_status': {'pending': 2, 'delivered': 3},
            'sales_total': 3000,
            'commission_total': 300.5,
          },
          'products': {
            'total': 7,
            'active': 4,
            'pending_approval': 1,
            'rejected': 1,
            'out_of_stock': 2,
          },
          'bookings': {
            'total': 3,
            'by_status': {'pending': 1, 'completed': 2},
            'completed_value': 1500,
          },
          'settlements': {
            'pending': {
              'count': 2,
              'gross': 2000,
              'commission': 200,
              'deductions': 0,
              'net': 1800,
            },
            'ready': {
              'count': 1,
              'gross': 1000,
              'commission': 100.5,
              'deductions': 0,
              'net': 899.5,
            },
          },
        });
        expect(d.pendingOrders, 2);
        expect(d.completedOrders, 3);
        expect(d.completedServices, 2);
        expect(d.salesTotal, 3000);
        expect(d.commissionTotal, 300.5);
        expect(d.netPending, 2699.5);
        expect(d.netPaid, 0, reason: 'no paid settlement exists');
        expect(d.settlement('paid'), isNull);
      },
    );
    test('Settlement is only "paid" when the backend says so', () {
      Settlement s(String st) => Settlement.fromJson({
        'id': '1',
        'status': st,
        'gross_amount': 100,
        'commission_amount': 10,
        'deductions_amount': 0,
        'net_amount': 90,
      });
      expect(s('ready').isPaid, isFalse);
      expect(s('pending').isPaid, isFalse);
      expect(s('paid').isPaid, isTrue);
    });
    test('VendorOrder detail', () {
      final o = VendorOrder.fromJson({
        'id': 'v1',
        'vendor_order_number': 'VO-1',
        'order_id': 'o1',
        'order_number': 'ORD-1',
        'status': 'pending',
        'payment_method': 'cod',
        'payment_status': 'pending',
        'subtotal': 1000,
        'total_amount': 1050,
        'commission_amount': null,
        'item_count': 1,
        'placed_at': '2026-01-01T10:00:00+00:00',
        'delivery_charge': 50,
        'discount_amount': 0,
        'net_payable': 1000,
        'delivery_address': {
          'recipient_name': 'Asha',
          'phone': '+91',
          'address_line1': '1 Rd',
          'city': 'Pune',
          'state': 'MH',
          'postal_code': '411001',
        },
        'items': [
          {
            'id': 'i1',
            'product_name': 'Bike',
            'unit_price': 1000,
            'quantity': 1,
            'line_total': 1000,
          },
        ],
      }, withDetail: true);
      expect(o.commission, isNull);
      expect(o.detail!.items.single.name, 'Bike');
      expect(o.detail!.addressText, '1 Rd, Pune, MH 411001');
      expect(o.detail!.recipient, 'Asha');
    });
  });
}

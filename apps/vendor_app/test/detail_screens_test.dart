import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vendor_app/app/theme.dart';
import 'package:vendor_app/core/api/api_client.dart';
import 'package:vendor_app/core/providers.dart';
import 'package:vendor_app/features/orders/screens.dart';
import 'package:vendor_app/features/service_bookings/screens.dart';

import 'support/fakes.dart';

Map<String, dynamic> orderJson(String status, {String payment = 'pending'}) => {
  'id': 'v1',
  'vendor_order_number': 'VO-1',
  'order_id': 'o1',
  'order_number': 'ORD-1',
  'status': status,
  'payment_method': 'cod',
  'payment_status': payment,
  'subtotal': 2000,
  'total_amount': 2050,
  'commission_amount': status == 'delivered' ? 200 : null,
  'item_count': 2,
  'placed_at': '2026-01-01T10:00:00+00:00',
  'delivery_charge': 50,
  'discount_amount': 0,
  'net_payable': 2000,
  'delivery_address': {
    'recipient_name': 'Asha Rao',
    'phone': '+919800000001',
    'address_line1': '12 MG Road',
    'city': 'Pune',
    'state': 'MH',
    'postal_code': '411001',
  },
  'customer_note': 'Leave at gate',
  'items': [
    {
      'id': 'i1',
      'product_name': 'Trail Blazer 29',
      'unit_price': 1000,
      'quantity': 2,
      'line_total': 2000,
    },
  ],
};

Map<String, dynamic> bookingJson(String status, {bool pickup = true}) => {
  'id': 'b1',
  'booking_number': 'BK-1',
  'status': status,
  'service_name': 'Full service',
  'vendor_name': 'Spoke',
  'preferred': {
    'date': '2026-06-10',
    'slot_start': '10:00',
    'slot_end': '11:00',
  },
  'confirmed': status == 'pending'
      ? {'date': null, 'slot_start': null, 'slot_end': null}
      : {'date': '2026-06-10', 'slot_start': '10:00', 'slot_end': '11:00'},
  'needs_pickup_dropoff': pickup,
  'current_price': 749,
  'created_at': '2026-06-01T10:00:00+00:00',
  'customer': {'full_name': 'Asha Rao', 'phone': '+919800000001'},
  'issue_description': 'Brakes squeal',
  'cycle': {'brand': 'Hero', 'model': 'Sprint'},
  'estimated_duration_minutes': 120,
  'pricing': {
    'estimated_price': 499,
    'additional_charges_total': 250,
    'current_price': 749,
    'pickup_charge': 0,
    'dropoff_charge': 0,
    'total_estimated': 499,
    'total_current': 749,
  },
  'pickup': pickup
      ? {
          'id': 'p1',
          'pickup_address': {'address_line1': '12 MG Road', 'city': 'Pune'},
          'dropoff_address': {'address_line1': '12 MG Road', 'city': 'Pune'},
          'pickup_status': 'pending',
          'pickup_stage': 'requested',
          'delivery_status': 'pending',
          'delivery_stage': 'requested',
          'pickup_charge': 0,
          'dropoff_charge': 0,
        }
      : null,
  'charges': [
    {
      'id': 'c1',
      'amount': 250,
      'reason': 'Replaced brake pads',
      'recorded_role': 'vendor',
      'created_at': '2026-06-10T12:00:00+00:00',
    },
  ],
  'notes': [],
  'images': [],
  'can_cancel': false,
};

Future<StubAdapter> pump(
  WidgetTester tester,
  Widget screen,
  Responder responder,
) async {
  final http = StubAdapter(responder);
  await tester.binding.setSurfaceSize(const Size(420, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWith(
          (ref) => ApiClient(
            baseUrl: 'http://x/api/v1',
            readToken: () async => 't',
            dio: Dio()..httpClientAdapter = http,
          ),
        ),
      ],
      child: MaterialApp(theme: buildTheme(), home: screen),
    ),
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
  return http;
}

Future<void> reveal(WidgetTester tester, Finder f) => tester.scrollUntilVisible(
  f,
  500,
  scrollable: find.byType(Scrollable).first,
);

void main() {
  group('order detail', () {
    testWidgets(
      'new order: Accept and Reject, no status advance, payment shown read-only',
      (tester) async {
        await pump(
          tester,
          const OrderDetailScreen(id: 'v1'),
          (o) => o.path.endsWith('/timeline')
              ? jsonBody([])
              : jsonBody(orderJson('pending')),
        );
        expect(find.text('Accept order'), findsOneWidget);
        expect(find.text('Reject'), findsOneWidget);
        expect(find.textContaining('Mark as'), findsNothing);
        expect(find.text('Trail Blazer 29'), findsOneWidget);
        expect(find.text('Asha Rao'), findsOneWidget);
        expect(find.textContaining('12 MG Road'), findsOneWidget);
        expect(find.textContaining('cannot change it'), findsOneWidget);
        expect(find.text('Cancel order'), findsNothing);
      },
    );

    testWidgets(
      'accepted order offers exactly the next backend step; cancel needs a reason',
      (tester) async {
        await pump(
          tester,
          const OrderDetailScreen(id: 'v1'),
          (o) => o.path.endsWith('/timeline')
              ? jsonBody([])
              : jsonBody(orderJson('accepted')),
        );
        expect(find.text('Mark as Processing'), findsOneWidget);
        expect(
          find.text('Mark as Completed'),
          findsNothing,
          reason: 'cannot skip steps',
        );
        expect(find.text('Accept order'), findsNothing);
        expect(find.text('Cancel order'), findsOneWidget);
      },
    );

    testWidgets('ready for dispatch offers Shipped or Completed', (
      tester,
    ) async {
      await pump(
        tester,
        const OrderDetailScreen(id: 'v1'),
        (o) => o.path.endsWith('/timeline')
            ? jsonBody([])
            : jsonBody(orderJson('ready_for_dispatch')),
      );
      expect(find.text('Mark as Shipped'), findsOneWidget);
      expect(find.text('Mark as Completed'), findsOneWidget);
    });

    testWidgets(
      'completed order shows the platform-recorded commission and no actions',
      (tester) async {
        await pump(
          tester,
          const OrderDetailScreen(id: 'v1'),
          (o) => o.path.endsWith('/timeline')
              ? jsonBody([])
              : jsonBody(orderJson('delivered', payment: 'successful')),
        );
        expect(find.textContaining('Mark as'), findsNothing);
        expect(find.text('Accept order'), findsNothing);
        expect(find.text('Cancel order'), findsNothing);
        expect(find.textContaining('₹200'), findsWidgets);
      },
    );

    testWidgets(
      'accept: success message only AFTER the backend confirms; a backend refusal is shown instead',
      (tester) async {
        var accepted = false;
        var fail = true;
        await pump(tester, const OrderDetailScreen(id: 'v1'), (o) {
          if (o.path.endsWith('/timeline')) return jsonBody([]);
          if (o.path.endsWith('/accept')) {
            if (fail) {
              return jsonBody({
                'error': {
                  'code': 'invalid_transition',
                  'message':
                      'This order was already cancelled by the customer.',
                },
              }, 409);
            }
            accepted = true;
          }
          return jsonBody(orderJson(accepted ? 'accepted' : 'pending'));
        });
        await tester.tap(find.text('Accept order'));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        await tester.tap(find.widgetWithText(FilledButton, 'Accept').last);
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expect(
          find.text('This order was already cancelled by the customer.'),
          findsOneWidget,
        );
        expect(find.text('Order accepted'), findsNothing);
        fail = false;
        ScaffoldMessenger.of(
          tester.element(find.byType(Scaffold).first),
        ).clearSnackBars();
        await tester.tap(find.text('Accept order'));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        await tester.tap(find.widgetWithText(FilledButton, 'Accept').last);
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expect(find.text('Order accepted'), findsOneWidget);
        expect(
          find.text('Mark as Processing'),
          findsOneWidget,
          reason: 'screen reloaded from the backend',
        );
      },
    );
  });

  group('booking detail', () {
    testWidgets(
      'new booking: accept/reject, customer + cycle + problem, estimate kept apart from charges',
      (tester) async {
        await pump(
          tester,
          const BookingDetailScreen(id: 'b1'),
          (o) => o.path.endsWith('/timeline')
              ? jsonBody([])
              : jsonBody(bookingJson('pending')),
        );
        expect(find.text('Accept'), findsOneWidget);
        expect(find.text('Reject'), findsOneWidget);
        expect(find.text('Asha Rao'), findsOneWidget);
        expect(find.text('Brakes squeal'), findsOneWidget);
        expect(find.text('Original estimate'), findsOneWidget);
        expect(find.textContaining('Replaced brake pads'), findsOneWidget);
        expect(find.text('Current service price'), findsOneWidget);
        expect(
          find.textContaining('NOT confirmed by the customer'),
          findsOneWidget,
        );
        expect(
          find.text('Add charge'),
          findsNothing,
          reason: 'charges only after acceptance',
        );
      },
    );

    testWidgets(
      'accepted pickup booking: repair next step is Picked up; logistics are shown separately',
      (tester) async {
        await pump(
          tester,
          const BookingDetailScreen(id: 'b1'),
          (o) => o.path.endsWith('/timeline')
              ? jsonBody([])
              : jsonBody(bookingJson('accepted')),
        );
        await reveal(tester, find.text('Mark as Picked up'));
        expect(find.text('Mark as Picked up'), findsOneWidget);
        expect(find.text('Mark as In service'), findsNothing);
        expect(
          find.textContaining(
            'Pickup & drop-off (separate from repair status)',
          ),
          findsOneWidget,
        );
        expect(
          find.text('Requested'),
          findsNWidgets(2),
          reason: 'pickup and return delivery have their own stage',
        );
        expect(find.text('Add charge'), findsOneWidget);
        expect(find.text('Cancel booking'), findsOneWidget);
      },
    );

    testWidgets(
      'accepted booking without pickup goes straight to In service and shows no logistics',
      (tester) async {
        await pump(
          tester,
          const BookingDetailScreen(id: 'b1'),
          (o) => o.path.endsWith('/timeline')
              ? jsonBody([])
              : jsonBody(bookingJson('accepted', pickup: false)),
        );
        await reveal(tester, find.text('Mark as In service'));
        expect(find.text('Mark as In service'), findsOneWidget);
        expect(find.text('Mark as Picked up'), findsNothing);
        expect(
          find.textContaining('separate from repair status'),
          findsNothing,
        );
        expect(
          find.text('Picked up'),
          findsNothing,
          reason: 'no pickup step in the progress list',
        );
      },
    );

    testWidgets(
      'in service → Ready for delivery; the cycle can no longer be cancelled',
      (tester) async {
        await pump(
          tester,
          const BookingDetailScreen(id: 'b1'),
          (o) => o.path.endsWith('/timeline')
              ? jsonBody([])
              : jsonBody(bookingJson('in_service')),
        );
        await reveal(tester, find.text('Mark as Ready for delivery'));
        expect(find.text('Mark as Ready for delivery'), findsOneWidget);
        expect(
          find.text('Cancel booking'),
          findsNothing,
          reason: 'cycle is already with the provider',
        );
      },
    );

    testWidgets('completed booking has no actions and no charge button', (
      tester,
    ) async {
      await pump(
        tester,
        const BookingDetailScreen(id: 'b1'),
        (o) => o.path.endsWith('/timeline')
            ? jsonBody([])
            : jsonBody(bookingJson('completed')),
      );
      expect(find.textContaining('Mark as'), findsNothing);
      expect(find.text('Add charge'), findsNothing);
    });
  });
}

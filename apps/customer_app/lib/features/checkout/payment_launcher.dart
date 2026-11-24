import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../orders/models.dart';

enum PaymentLaunchOutcome { notAvailable, completed, cancelled }

/// Opens the payment provider's checkout widget. The client has not chosen a provider yet, so NO provider SDK is bundled and this app never
/// simulates a payment: the only implementation says so honestly. Once a provider is chosen, implement this interface with its SDK; the order
/// only becomes "paid" when the backend receives the provider's verified webhook (the app just polls the payment status afterwards).
abstract class PaymentLauncher {
  Future<PaymentLaunchOutcome> launch(
    BuildContext context, {
    required Payment payment,
    required Map<String, dynamic> clientPayload,
  });
}

class UnavailablePaymentLauncher implements PaymentLauncher {
  const UnavailablePaymentLauncher();
  @override
  Future<PaymentLaunchOutcome> launch(
    BuildContext context, {
    required Payment payment,
    required Map<String, dynamic> clientPayload,
  }) async => PaymentLaunchOutcome.notAvailable;
}

final paymentLauncherProvider = Provider<PaymentLauncher>(
  (ref) => const UnavailablePaymentLauncher(),
);

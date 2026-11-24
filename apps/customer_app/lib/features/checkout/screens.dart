import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api/api_exception.dart';
import '../../core/providers.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/common.dart';
import '../addresses/models.dart';
import '../addresses/providers.dart';
import '../addresses/screens.dart';
import '../cart/models.dart';
import '../cart/providers.dart';
import '../orders/models.dart';
import '../orders/providers.dart';
import 'models.dart';
import 'payment_launcher.dart';
import 'repository.dart';

final checkoutOptionsProvider = FutureProvider.autoDispose<CheckoutOptions>(
  (ref) => ref.read(checkoutRepositoryProvider).options(),
);

String _newKey() {
  final r = Random.secure();
  return 'app-${DateTime.now().microsecondsSinceEpoch}-${List.generate(6, (_) => r.nextInt(36).toRadixString(36)).join()}';
}

class CheckoutScreen extends ConsumerStatefulWidget {
  const CheckoutScreen({super.key});
  @override
  ConsumerState<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends ConsumerState<CheckoutScreen> {
  String? _addressId, _method, _vendorId;
  final _coupon = TextEditingController(), _note = TextEditingController();
  String? _appliedCoupon, _couponError;
  bool _acceptPriceChanges = false;

  CheckoutPreview? _preview;
  ApiException? _previewError;
  bool _previewing = false, _placing = false;
  int _previewSeq = 0;

  // One idempotency key per distinct set of choices: a retry of the SAME request reuses it (so it can never create a second order),
  // changing address / method / coupon / seller / note starts a new one.
  String _key = _newKey();
  String _keyFor = '';

  @override
  void dispose() {
    _coupon.dispose();
    _note.dispose();
    super.dispose();
  }

  String get _signature => [
    _addressId,
    _method,
    _appliedCoupon,
    _vendorId,
    _note.text.trim(),
  ].join('|');

  Map<String, dynamic>? _body() {
    if (_addressId == null || _method == null) return null;
    return CheckoutRepository.body(
      addressId: _addressId!,
      method: _method!,
      coupon: _appliedCoupon,
      note: _note.text.trim(),
      vendorId: _vendorId,
      acceptPriceChanges: _acceptPriceChanges,
    );
  }

  Future<void> _refreshPreview() async {
    final body = _body();
    if (body == null) return;
    final seq = ++_previewSeq;
    setState(() {
      _previewing = true;
      _previewError = null;
    });
    try {
      final p = await ref.read(checkoutRepositoryProvider).preview(body);
      if (!mounted || seq != _previewSeq) return;
      setState(() {
        _preview = p;
        _couponError = null;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _previewSeq) return;
      setState(() {
        _preview = null;
        if (e.code == 'coupon_invalid') {
          _couponError = _couponReason(e);
          _appliedCoupon = null;
        } else {
          _previewError = e;
        }
      });
    } finally {
      if (mounted && seq == _previewSeq) setState(() => _previewing = false);
    }
  }

  String _couponReason(ApiException e) {
    final reason = e.details.isNotEmpty ? e.details.first['reason'] : null;
    return switch (reason) {
      'not_found' => 'That coupon code is not valid.',
      'expired' => 'That coupon has expired.',
      'not_started' => 'That coupon is not active yet.',
      'below_minimum_order' =>
        'Your order is below the minimum for this coupon.',
      'usage_limit_reached' => 'That coupon has been fully used.',
      'already_used' => 'You have already used that coupon.',
      _ => 'That coupon cannot be used for this order.',
    };
  }

  void _applyCoupon() {
    final code = _coupon.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _appliedCoupon = code;
      _couponError = null;
    });
    _refreshPreview();
  }

  void _removeCoupon() {
    _coupon.clear();
    setState(() {
      _appliedCoupon = null;
      _couponError = null;
    });
    _refreshPreview();
  }

  Future<void> _place() async {
    final body = _body();
    if (_placing || body == null) return;
    if (_signature != _keyFor) {
      _key = _newKey();
      _keyFor = _signature;
    }
    setState(() => _placing = true);
    try {
      final result = await ref
          .read(checkoutRepositoryProvider)
          .place(body, _key);
      // Only now, after the backend confirmed the order, do we refresh the cart (the backend already removed the purchased lines).
      await ref.read(cartProvider.notifier).reload();
      ref.read(ordersTickProvider.notifier).bump();
      if (!mounted) return;
      context.pushReplacement('/order-confirmation/${result.order.summary.id}');
    } on ApiException catch (e) {
      if (!mounted) return;
      await _handlePlaceError(e);
    } finally {
      if (mounted) setState(() => _placing = false);
    }
  }

  Future<void> _handlePlaceError(ApiException e) async {
    switch (e.code) {
      case 'price_changed':
        final accept = await confirmDialog(
          context,
          title: 'Prices changed',
          message:
              '${e.message}\n\nDo you want to continue with the new prices?',
          confirmLabel: 'Continue',
        );
        if (accept) {
          setState(() => _acceptPriceChanges = true);
          await _refreshPreview();
          if (mounted && _preview != null) _place();
        }
      case 'insufficient_stock' ||
          'out_of_stock' ||
          'product_unavailable' ||
          'checkout_validation_failed' ||
          'empty_cart':
        final lines = e.details
            .map((d) => d['message'] ?? d['detail'])
            .whereType<String>()
            .join('\n');
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Please review your cart'),
            content: Text('${e.message}${lines.isEmpty ? '' : '\n\n$lines'}'),
            actions: [
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(110, 44)),
                onPressed: () {
                  Navigator.pop(c);
                  context.pop();
                },
                child: const Text('Back to cart'),
              ),
            ],
          ),
        );
        await ref.read(cartProvider.notifier).reload();
      default:
        showSnack(context, e.message, error: true);
        if (e.code == 'cod_not_available' ||
            e.code == 'online_payments_disabled' ||
            e.code == 'payment_provider_not_configured') {
          ref.invalidate(checkoutOptionsProvider);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(cartProvider).value ?? Cart.empty;
    final options = ref.watch(checkoutOptionsProvider);
    final addresses = ref.watch(addressesProvider);

    // default the address once addresses load
    final list = addresses.value ?? const <Address>[];
    final usable = list.where((a) => a.usableForDelivery).toList();
    if (_addressId == null && usable.isNotEmpty) {
      final def = usable.firstWhere(
        (a) => a.isDefault,
        orElse: () => usable.first,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _addressId == null) {
          setState(() => _addressId = def.id);
          _maybeInitialPreview();
        }
      });
    }

    // seller choice when the cart mixes sellers and the platform has not enabled multi-seller checkout
    final sellers = _sellers(cart);
    final multiBlocked =
        cart.multiVendor &&
        options.value != null &&
        !options.value!.multiVendorAllowed;
    if (multiBlocked && _vendorId == null && sellers.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _vendorId == null) {
          setState(() => _vendorId = sellers.first.$1);
          _maybeInitialPreview();
        }
      });
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: options.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          e,
          onRetry: () => ref.invalidate(checkoutOptionsProvider),
        ),
        data: (opt) => _body_(
          context,
          cart,
          opt,
          usable,
          sellers,
          multiBlocked,
          addresses.isLoading,
        ),
      ),
    );
  }

  List<(String, String, int)> _sellers(Cart cart) {
    final m = <String, (String, int)>{};
    for (final i in cart.items) {
      final v = i.product?.vendor;
      if (v == null) continue;
      m[v.id] = (v.businessName, (m[v.id]?.$2 ?? 0) + i.quantity);
    }
    return [for (final e in m.entries) (e.key, e.value.$1, e.value.$2)];
  }

  void _maybeInitialPreview() {
    if (_method != null) _refreshPreview();
  }

  Widget _body_(
    BuildContext context,
    Cart cart,
    CheckoutOptions opt,
    List<Address> addresses,
    List<(String, String, int)> sellers,
    bool multiBlocked,
    bool addressesLoading,
  ) {
    if (cart.isEmpty) {
      return EmptyState(
        icon: Icons.shopping_cart_outlined,
        title: 'Your cart is empty',
        actionLabel: 'Start shopping',
        onAction: () => context.go('/home'),
      );
    }

    // choose a sensible default payment method once we know what is enabled
    if (_method == null && opt.anyPaymentMethod) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _method == null) {
          setState(() => _method = opt.codEnabled ? 'cod' : 'online');
          if (_addressId != null) _refreshPreview();
        }
      });
    }

    Address? selected;
    for (final a in addresses) {
      if (a.id == _addressId) selected = a;
    }
    final canPlace =
        !_placing &&
        !_previewing &&
        _preview != null &&
        _previewError == null &&
        _addressId != null &&
        _method != null &&
        cart.canCheckout;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              if (multiBlocked) ...[
                _Card(
                  title: 'Choose a seller',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Your cart has items from several sellers. Checking out several sellers at once is not enabled yet, so you order from one seller at a time. The other items stay in your cart.',
                        style: TextStyle(color: AppColors.muted, fontSize: 13),
                      ),
                      const SizedBox(height: 6),
                      RadioGroup<String>(
                        groupValue: _vendorId,
                        onChanged: (v) {
                          setState(() => _vendorId = v);
                          _refreshPreview();
                        },
                        child: Column(
                          children: [
                            for (final s in sellers)
                              RadioListTile<String>(
                                contentPadding: EdgeInsets.zero,
                                value: s.$1,
                                title: Text(s.$2),
                                subtitle: Text(
                                  '${s.$3} item${s.$3 == 1 ? '' : 's'}',
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              _Card(
                title: 'Delivery address',
                trailing: TextButton(
                  onPressed: () async {
                    final a = await context.push<Address>(
                      '/addresses?select=1',
                    );
                    if (a != null && a.usableForDelivery) {
                      setState(() => _addressId = a.id);
                      _refreshPreview();
                    }
                  },
                  child: const Text('Change'),
                ),
                child: addressesLoading && addresses.isEmpty
                    ? const LinearProgressIndicator()
                    : selected == null
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Add a delivery address to continue.',
                            style: TextStyle(color: AppColors.muted),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: () => context.push('/address-form'),
                            icon: const Icon(Icons.add),
                            label: const Text('Add address'),
                          ),
                        ],
                      )
                    : AddressCard(
                        address: selected,
                        manage: false,
                        selected: true,
                      ),
              ),
              const SizedBox(height: 12),
              _Card(
                title: 'Order summary',
                child: Column(
                  children: [
                    for (final i in cart.items.where(
                      (i) =>
                          _vendorId == null ||
                          i.product?.vendor?.id == _vendorId,
                    ))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 44,
                              height: 44,
                              child: AppNetworkImage(
                                i.product?.imageUrl,
                                radius: 8,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '${i.product?.name ?? 'Item'}  × ${i.quantity}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (i.lineTotal != null)
                              Text(
                                money(i.lineTotal!),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _Card(
                title: 'Coupon',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_appliedCoupon != null && _preview != null)
                      Row(
                        children: [
                          const Icon(
                            Icons.local_offer,
                            color: AppColors.success,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${_appliedCoupon!.toUpperCase()} applied — you save ${money(_preview!.discount)}',
                              style: const TextStyle(
                                color: AppColors.success,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: _removeCoupon,
                            child: const Text('Remove'),
                          ),
                        ],
                      )
                    else
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _coupon,
                              textCapitalization: TextCapitalization.characters,
                              decoration: InputDecoration(
                                hintText: 'Enter coupon code',
                                errorText: _couponError,
                              ),
                              onSubmitted: (_) => _applyCoupon(),
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 96,
                            child: OutlinedButton(
                              onPressed: _previewing ? null : _applyCoupon,
                              child: const Text('Apply'),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _Card(title: 'Payment method', child: _methods(opt)),
              const SizedBox(height: 12),
              _Card(
                title: 'Note for the seller (optional)',
                child: TextField(
                  controller: _note,
                  maxLength: 500,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    hintText: 'Any delivery instructions?',
                    counterText: '',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(height: 12),
              _Card(title: 'Price details', child: _totals(cart)),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: const BoxDecoration(
              color: AppColors.surface,
              border: Border(top: BorderSide(color: AppColors.line)),
            ),
            child: Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Total',
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                    _previewing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : PriceText(
                            _preview?.total ?? cart.subtotal,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                  ],
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    onPressed: canPlace ? _place : null,
                    child: _placing
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            _method == 'online'
                                ? 'Place order & pay'
                                : 'Place order',
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _methods(CheckoutOptions opt) {
    if (!opt.anyPaymentMethod) {
      return const Text(
        'No payment method is available right now. Please try again later.',
        style: TextStyle(color: AppColors.danger),
      );
    }
    Widget tile(
      String value,
      String title,
      String subtitle,
      bool enabled,
      IconData icon,
    ) => RadioListTile<String>(
      contentPadding: EdgeInsets.zero,
      value: value,
      enabled: enabled,
      secondary: Icon(
        icon,
        color: enabled ? AppColors.primary : AppColors.muted,
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: enabled ? null : AppColors.muted,
        ),
      ),
      subtitle: Text(subtitle),
    );
    return RadioGroup<String>(
      groupValue: _method,
      onChanged: (v) {
        setState(() => _method = v);
        _refreshPreview();
      },
      child: Column(
        children: [
          if (opt.codEnabled)
            tile(
              'cod',
              'Cash on delivery',
              'Pay in cash when your order arrives',
              true,
              Icons.payments_outlined,
            ),
          tile(
            'online',
            'Pay online',
            opt.onlineEnabled
                ? 'UPI, cards and net banking'
                : (opt.onlineProviderConfigured
                      ? 'Currently turned off'
                      : 'Not available yet — online payments are being set up'),
            opt.onlineEnabled,
            Icons.credit_card,
          ),
        ],
      ),
    );
  }

  Widget _totals(Cart cart) {
    if (_previewError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.error_outline, color: AppColors.danger),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _previewError!.message,
                  style: const TextStyle(color: AppColors.danger),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _refreshPreview,
            child: const Text('Retry'),
          ),
        ],
      );
    }
    final p = _preview;
    if (p == null) {
      return Column(
        children: [
          AmountRow('Subtotal', cart.subtotal),
          const SizedBox(height: 4),
          const Text(
            'Select an address and payment method to see delivery charges and the final total.',
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        ],
      );
    }
    return Column(
      children: [
        AmountRow(
          'Subtotal (${p.itemCount} item${p.itemCount == 1 ? '' : 's'})',
          p.subtotal,
        ),
        if (p.discount > 0)
          AmountRow(
            'Discount${p.couponCode != null ? ' (${p.couponCode})' : ''}',
            p.discount,
            negative: true,
          ),
        AmountRow('Delivery', p.deliveryCharge),
        const Divider(height: 18),
        AmountRow('Total payable', p.total, bold: true),
        if (_method == 'cod')
          const Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'You will pay this amount in cash on delivery.',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    ),
  );
}

// ============================================================================================================================ confirmation
class OrderConfirmationScreen extends ConsumerWidget {
  const OrderConfirmationScreen({super.key, required this.orderId});
  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = ref.watch(orderDetailProvider(orderId));
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go('/home');
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Order placed'),
          automaticallyImplyLeading: false,
        ),
        body: AsyncBody(
          value: order,
          onRetry: () => ref.invalidate(orderDetailProvider(orderId)),
          builder: (o) {
            final s = o.summary;
            final online = s.paymentMethod == 'online';
            final unpaid =
                online &&
                (s.paymentStatus == 'pending' ||
                    s.paymentStatus == 'processing' ||
                    s.paymentStatus == 'failed') &&
                s.status == 'pending';
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                const SizedBox(height: 12),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: (unpaid ? AppColors.warning : AppColors.success)
                          .withValues(alpha: .12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      unpaid ? Icons.hourglass_top : Icons.check_circle,
                      color: unpaid ? AppColors.warning : AppColors.success,
                      size: 56,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  unpaid
                      ? 'Order created — payment pending'
                      : 'Thank you! Your order is confirmed',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  'Order ${s.number}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 18),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      children: [
                        for (final v in o.vendorOrders) ...[
                          for (final i in v.items)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text('${i.name}  × ${i.quantity}'),
                                  ),
                                  Text(money(i.lineTotal)),
                                ],
                              ),
                            ),
                        ],
                        const Divider(height: 20),
                        AmountRow('Subtotal', o.subtotal),
                        if (o.discount > 0)
                          AmountRow('Discount', o.discount, negative: true),
                        AmountRow('Delivery', o.deliveryCharge),
                        AmountRow('Total', s.total, bold: true),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Text('Payment: '),
                            Text(
                              online ? 'Online' : 'Cash on delivery',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const Spacer(),
                            StatusChip(s.paymentStatus),
                          ],
                        ),
                        if (!online)
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: EdgeInsets.only(top: 6),
                              child: Text(
                                'Please keep the exact amount ready. Cash is collected on delivery.',
                                style: TextStyle(
                                  color: AppColors.muted,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        if (online && s.paymentStatus == 'successful')
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: EdgeInsets.only(top: 6),
                              child: Text(
                                'Payment received.',
                                style: TextStyle(
                                  color: AppColors.success,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Deliver to: ${o.addressText}',
                  style: const TextStyle(color: AppColors.muted),
                ),
                if (unpaid) ...[
                  const SizedBox(height: 14),
                  PayNowCard(orderId: orderId, dueAt: o.paymentDueAt),
                ],
                const SizedBox(height: 22),
                FilledButton(
                  onPressed: () => context.pushReplacement('/orders/$orderId'),
                  child: const Text('View order'),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () => context.go('/home'),
                  child: const Text('Continue shopping'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Online payment entry point. It asks the backend to (re)start the payment and hands the provider payload to the [PaymentLauncher].
/// With no provider SDK integrated it reports that plainly - it never shows a fake success.
class PayNowCard extends ConsumerStatefulWidget {
  const PayNowCard({super.key, required this.orderId, this.dueAt});
  final String orderId;
  final DateTime? dueAt;
  @override
  ConsumerState<PayNowCard> createState() => _PayNowCardState();
}

class _PayNowCardState extends ConsumerState<PayNowCard> {
  bool _busy = false;
  String? _message;

  Future<void> _pay() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final payload = await ref
          .read(paymentRepositoryProvider)
          .start(widget.orderId);
      final payment = Payment.fromJsonSafe(payload);
      if (!mounted) return;
      final outcome = await ref
          .read(paymentLauncherProvider)
          .launch(context, payment: payment, clientPayload: payload);
      if (!mounted) return;
      switch (outcome) {
        case PaymentLaunchOutcome.notAvailable:
          setState(
            () => _message =
                'The online payment gateway is not connected in this version of the app yet, so this payment cannot be completed here. Your order is held until the payment window ends.',
          );
        case PaymentLaunchOutcome.cancelled:
          setState(
            () => _message = 'Payment was cancelled. You can try again.',
          );
        case PaymentLaunchOutcome.completed:
          ref.invalidate(orderDetailProvider(widget.orderId));
          setState(
            () => _message =
                'Payment submitted. We will confirm it as soon as the payment provider notifies us.',
          );
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(
          () => _message = e.code == 'payment_provider_not_configured'
              ? 'Online payments are not available yet.'
              : e.message,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    color: AppColors.warning.withValues(alpha: .08),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Payment pending',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          Text(
            widget.dueAt != null
                ? 'Pay before ${dateTime(widget.dueAt)} or the order will be cancelled.'
                : 'Complete your payment to confirm this order.',
            style: const TextStyle(color: AppColors.muted),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _message!,
                style: const TextStyle(
                  color: AppColors.danger,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _busy ? null : _pay,
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : const Text('Pay now'),
          ),
        ],
      ),
    ),
  );
}

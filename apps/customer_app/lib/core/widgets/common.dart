import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../api/api_exception.dart';
import '../paged_controller.dart';
import '../utils/format.dart';

void showSnack(BuildContext context, String message, {bool error = false}) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  final dark = Theme.of(context).brightness == Brightness.dark;
  m.showSnackBar(
    SnackBar(
      content: Text(message, style: const TextStyle(color: Colors.white)),
      backgroundColor: error
          ? AppColors.danger
          : (dark ? const Color(0xFF2F403B) : AppColors.ink),
    ),
  );
}

/// Customer-safe text for any thrown error.
String errorText(Object e) {
  if (e is ApiException) return e.message;
  return 'Something went wrong. Please try again.';
}

class AppNetworkImage extends StatelessWidget {
  const AppNetworkImage(
    this.url, {
    super.key,
    this.fit = BoxFit.cover,
    this.radius = 12,
    this.icon = Icons.pedal_bike,
    this.aspectRatio,
  });
  final String? url;
  final BoxFit fit;
  final double radius;
  final IconData icon;
  final double? aspectRatio;

  @override
  Widget build(BuildContext context) {
    Widget placeholder() => Container(
      color: context.palette.line.withValues(alpha: .6),
      alignment: Alignment.center,
      child: Icon(icon, color: context.palette.muted, size: 32),
    );
    final u = url;
    Widget child = (u == null || u.isEmpty)
        ? placeholder()
        : CachedNetworkImage(
            imageUrl: u,
            fit: fit,
            width: double.infinity,
            height: double.infinity,
            placeholder: (_, _) => placeholder(),
            errorWidget: (_, _, _) => placeholder(),
          );
    if (aspectRatio != null) {
      child = AspectRatio(aspectRatio: aspectRatio!, child: child);
    }
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: child);
  }
}

class PriceText extends StatelessWidget {
  const PriceText(this.value, {super.key, this.style, this.strike = false});
  final num value;
  final TextStyle? style;
  final bool strike;
  @override
  Widget build(BuildContext context) => Text(
    money(value),
    style: (style ?? Theme.of(context).textTheme.titleMedium)?.copyWith(
      fontWeight: FontWeight.w800,
      color: strike ? context.palette.muted : context.palette.primary,
      decoration: strike ? TextDecoration.lineThrough : null,
    ),
  );
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.actionLabel, this.onAction});
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.lg,
      AppSpacing.xl,
      AppSpacing.lg,
      AppSpacing.sm,
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        if (onAction != null)
          TextButton(
            onPressed: onAction,
            child: Text(actionLabel ?? 'See all'),
          ),
      ],
    ),
  );
}

/// Colour-coded status pill for order / payment / booking / pickup states.
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.label});
  final String status;
  final String? label;

  static Color colorFor(String s) => switch (s) {
    'completed' ||
    'delivered' ||
    'successful' ||
    'confirmed' ||
    'accepted' ||
    'picked_up' ||
    'ok' ||
    'resolved' => AppColors.success,
    'pending' ||
    'processing' ||
    'scheduled' ||
    'requested' ||
    'preparing' ||
    'in_service' ||
    'ready_for_dispatch' ||
    'ready_for_delivery' ||
    'out_for_delivery' ||
    'open' ||
    'in_progress' => AppColors.warning,
    'cancelled' ||
    'rejected' ||
    'failed' ||
    'out_of_stock' ||
    'not_listed' ||
    'unavailable' ||
    'insufficient_stock' => AppColors.danger,
    'refunded' || 'partially_refunded' => AppColors.info,
    _ => AppColors.muted,
  };

  @override
  Widget build(BuildContext context) {
    final base = colorFor(status);
    // the fixed status colours are tuned for light surfaces; lift them a little on dark ones so the label stays readable
    final c = Theme.of(context).brightness == Brightness.dark
        ? Color.lerp(base, Colors.white, .35)!
        : base;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label ?? humanize(status),
        style: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: 12),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });
  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: context.palette.primary.withValues(alpha: .08),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 40, color: context.palette.primary),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              message!,
              style: TextStyle(color: context.palette.muted),
              textAlign: TextAlign.center,
            ),
          ],
          if (onAction != null) ...[
            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              width: 220,
              child: FilledButton(
                onPressed: onAction,
                child: Text(actionLabel ?? 'Continue'),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class ErrorView extends StatelessWidget {
  const ErrorView(this.error, {super.key, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    final offline = error is ApiException && (error as ApiException).isNetwork;
    return EmptyState(
      icon: offline ? Icons.wifi_off_rounded : Icons.error_outline,
      title: offline ? 'You appear to be offline' : 'Something went wrong',
      message: errorText(error),
      actionLabel: 'Try again',
      onAction: onRetry,
    );
  }
}

class LoadingView extends StatelessWidget {
  const LoadingView({super.key});
  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: CircularProgressIndicator(),
    ),
  );
}

/// loading / error(+retry) / data for a Riverpod AsyncValue.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({
    super.key,
    required this.value,
    required this.builder,
    this.onRetry,
  });
  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => value.when(
    data: builder,
    loading: () => const LoadingView(),
    error: (e, _) => ErrorView(e, onRetry: onRetry),
  );
}

/// Infinite-scroll list over a [PagedController] with pull-to-refresh, loading, empty and error states.
class PagedListView<T> extends StatefulWidget {
  const PagedListView({
    super.key,
    required this.controller,
    required this.itemBuilder,
    required this.empty,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.separator = 12,
  });
  final PagedController<T> controller;
  final Widget Function(BuildContext, T) itemBuilder;
  final Widget empty;
  final EdgeInsets padding;
  final double separator;
  @override
  State<PagedListView<T>> createState() => _PagedListViewState<T>();
}

class _PagedListViewState<T> extends State<PagedListView<T>> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuild);
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) {
        widget.controller.loadMore();
      }
    });
    if (widget.controller.items.isEmpty && !widget.controller.loading) {
      widget.controller.loadMore();
    }
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    if (c.isInitialLoading) return const LoadingView();
    if (c.error != null && c.items.isEmpty) {
      return ErrorView(c.error!, onRetry: c.refresh);
    }
    if (c.isEmpty) return widget.empty;
    return RefreshIndicator(
      onRefresh: c.refresh,
      child: ListView.separated(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: widget.padding,
        itemCount: c.items.length + 1,
        separatorBuilder: (_, _) => SizedBox(height: widget.separator),
        itemBuilder: (context, i) {
          if (i < c.items.length) {
            return widget.itemBuilder(context, c.items[i]);
          }
          if (c.loading) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (c.error != null) {
            return TextButton.icon(
              onPressed: c.loadMore,
              icon: const Icon(Icons.refresh),
              label: Text('${errorText(c.error!)}  Tap to retry'),
            );
          }
          return const SizedBox(height: 24);
        },
      ),
    );
  }
}

class QuantityStepper extends StatelessWidget {
  const QuantityStepper({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 1,
    this.max = 99,
    this.busy = false,
  });
  final int value, min, max;
  final ValueChanged<int> onChanged;
  final bool busy;
  @override
  Widget build(BuildContext context) {
    Widget btn(IconData i, VoidCallback? f, String tip) => IconButton(
      onPressed: busy ? null : f,
      icon: Icon(i, size: 20),
      tooltip: tip,
      visualDensity: VisualDensity.compact,
    );
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: context.palette.line),
        borderRadius: BorderRadius.circular(10),
        color: context.palette.surface,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          btn(
            Icons.remove,
            value > min ? () => onChanged(value - 1) : null,
            'Decrease quantity',
          ),
          SizedBox(
            width: 28,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          btn(
            Icons.add,
            value < max ? () => onChanged(value + 1) : null,
            'Increase quantity',
          ),
        ],
      ),
    );
  }
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Keep'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size(100, 44),
            backgroundColor: destructive ? AppColors.danger : null,
          ),
          onPressed: () => Navigator.pop(c, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Bottom sheet that collects a required reason (cancellations).
Future<String?> askReason(
  BuildContext context, {
  required String title,
  String hint = 'Tell us why',
  String action = 'Submit',
}) {
  final ctrl = TextEditingController();
  final key = GlobalKey<FormState>();
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (c) => Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        MediaQuery.of(c).viewInsets.bottom + 20,
      ),
      child: Form(
        key: key,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(c).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextFormField(
              controller: ctrl,
              autofocus: true,
              maxLines: 3,
              maxLength: 500,
              decoration: InputDecoration(hintText: hint),
              validator: (v) => (v == null || v.trim().length < 3)
                  ? 'Please enter at least 3 characters'
                  : null,
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => key.currentState!.validate()
                  ? Navigator.pop(c, ctrl.text.trim())
                  : null,
              child: Text(action),
            ),
          ],
        ),
      ),
    ),
  );
}

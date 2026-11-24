import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/config.dart';
import '../../app/theme.dart';
import '../../core/paged_controller.dart';
import '../../core/providers.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/common.dart';
import 'models.dart';

final ticketDetailProvider = FutureProvider.family.autoDispose<Ticket, String>(
  (ref, id) => ref.read(supportRepositoryProvider).get(id),
);

class SupportScreen extends ConsumerStatefulWidget {
  const SupportScreen({super.key});
  @override
  ConsumerState<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends ConsumerState<SupportScreen> {
  late final PagedController<Ticket> _paged = PagedController(
    (p) => ref.read(supportRepositoryProvider).list(p),
  );

  @override
  void initState() {
    super.initState();
    _paged.loadMore();
    _paged.addListener(() => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  Future<void> _launch(Uri uri) async {
    if (!await launchUrl(uri) && mounted) {
      showSnack(context, 'Could not open that on this device.', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasContact =
        AppConfig.supportEmail.isNotEmpty || AppConfig.supportPhone.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Help & support')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await context.push('/support/new');
          _paged.refresh();
        },
        icon: const Icon(Icons.add),
        label: const Text('New request'),
      ),
      body: RefreshIndicator(
        onRefresh: _paged.refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            96,
          ),
          children: [
            Text('Contact us', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: hasContact
                  ? Column(
                      children: [
                        if (AppConfig.supportPhone.isNotEmpty)
                          ListTile(
                            leading: const Icon(
                              Icons.phone_outlined,
                              color: AppColors.primary,
                            ),
                            title: Text(AppConfig.supportPhone),
                            onTap: () => _launch(
                              Uri(scheme: 'tel', path: AppConfig.supportPhone),
                            ),
                          ),
                        if (AppConfig.supportEmail.isNotEmpty)
                          ListTile(
                            leading: const Icon(
                              Icons.mail_outline,
                              color: AppColors.primary,
                            ),
                            title: Text(AppConfig.supportEmail),
                            onTap: () => _launch(
                              Uri(
                                scheme: 'mailto',
                                path: AppConfig.supportEmail,
                              ),
                            ),
                          ),
                      ],
                    )
                  : const Padding(
                      padding: EdgeInsets.all(14),
                      child: Text(
                        'Support phone and e-mail have not been configured for this build yet. You can still raise a request below and our team will respond.',
                        style: TextStyle(color: AppColors.muted),
                      ),
                    ),
            ),
            const SizedBox(height: 20),
            Text('Quick help', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Help(
                      'Where is my order?',
                      'Open Profile → My orders and tap the order to see its progress.',
                    ),
                    _Help(
                      'How do I cancel?',
                      'Orders can be cancelled until the seller starts preparing them; service bookings until your cycle is collected or work starts.',
                    ),
                    _Help(
                      'Doorstep pickup',
                      'Choose pickup while booking a service, if the provider offers it. You can follow pickup and return delivery on the booking.',
                    ),
                    _Help(
                      'Refunds',
                      'If you paid online and an order is cancelled, a refund request is raised. It is shown as complete only after it has been processed.',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text('My requests', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_paged.isInitialLoading)
              const LoadingView()
            else if (_paged.error != null && _paged.items.isEmpty)
              ErrorView(_paged.error!, onRetry: _paged.refresh)
            else if (_paged.items.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: Text(
                    'You have not raised any requests.',
                    style: TextStyle(color: AppColors.muted),
                  ),
                ),
              )
            else ...[
              for (final t in _paged.items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(
                    child: ListTile(
                      onTap: () => context.push('/support/${t.id}'),
                      title: Text(
                        t.subject,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${t.number} · ${dateShort(t.createdAt)}'),
                      trailing: StatusChip(t.status),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Help extends StatelessWidget {
  const _Help(this.q, this.a);
  final String q, a;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(q, style: const TextStyle(fontWeight: FontWeight.w700)),
        Text(a, style: const TextStyle(color: AppColors.muted)),
      ],
    ),
  );
}

class NewTicketScreen extends ConsumerStatefulWidget {
  const NewTicketScreen({super.key, this.bookingId, this.orderId});
  final String? bookingId, orderId;
  @override
  ConsumerState<NewTicketScreen> createState() => _NewTicketScreenState();
}

class _NewTicketScreenState extends ConsumerState<NewTicketScreen> {
  final _form = GlobalKey<FormState>();
  final _subject = TextEditingController(), _desc = TextEditingController();
  String _type = 'support_request';
  bool _busy = false;

  @override
  void dispose() {
    _subject.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final t = await ref
          .read(supportRepositoryProvider)
          .create(
            type: _type,
            subject: _subject.text.trim(),
            description: _desc.text.trim(),
            bookingId: widget.bookingId,
            orderId: widget.orderId,
          );
      if (mounted) {
        showSnack(context, 'Request ${t.number} sent');
        context.pushReplacement('/support/${t.id}');
      }
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('New support request')),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          if (widget.bookingId != null || widget.orderId != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: .07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                widget.bookingId != null
                    ? 'About your service booking'
                    : 'About your order',
              ),
            ),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'support_request', label: Text('Question')),
              ButtonSegment(value: 'complaint', label: Text('Complaint')),
              ButtonSegment(value: 'dispute', label: Text('Dispute')),
            ],
            selected: {_type},
            onSelectionChanged: (s) => setState(() => _type = s.first),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _subject,
            maxLength: 150,
            decoration: const InputDecoration(labelText: 'Subject'),
            validator: (v) =>
                (v ?? '').trim().length < 3 ? 'Enter a short subject' : null,
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _desc,
            maxLines: 6,
            maxLength: 3000,
            decoration: const InputDecoration(
              labelText: 'Describe the issue',
              alignLabelWithHint: true,
            ),
            validator: (v) => (v ?? '').trim().length < 10
                ? 'Please give a little more detail (10+ characters)'
                : null,
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _send,
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : const Text('Send request'),
          ),
        ],
      ),
    ),
  );
}

class TicketDetailScreen extends ConsumerWidget {
  const TicketDetailScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Support request')),
    body: AsyncBody<Ticket>(
      value: ref.watch(ticketDetailProvider(id)),
      onRetry: () => ref.invalidate(ticketDetailProvider(id)),
      builder: (t) => ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  t.subject,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              StatusChip(t.status),
            ],
          ),
          Text(
            '${t.number} · ${humanize(t.type)} · ${dateTime(t.createdAt)}',
            style: const TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(t.description),
            ),
          ),
          if ((t.resolution ?? '').isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              color: AppColors.success.withValues(alpha: .08),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Resolution',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: AppColors.success,
                      ),
                    ),
                    Text(t.resolution!),
                  ],
                ),
              ),
            ),
          ] else
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'Our team will review your request and update the status here.',
                style: TextStyle(color: AppColors.muted),
              ),
            ),
        ],
      ),
    ),
  );
}

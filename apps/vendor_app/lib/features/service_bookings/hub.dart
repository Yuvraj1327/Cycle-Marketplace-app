import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../notifications/screens.dart';
import '../services/screens.dart';
import 'screens.dart';

/// "Services" tab: service bookings (incoming work) and the services the business offers.
class ServicesHubScreen extends ConsumerStatefulWidget {
  const ServicesHubScreen({super.key});
  @override
  ConsumerState<ServicesHubScreen> createState() => _ServicesHubScreenState();
}

class _ServicesHubScreenState extends ConsumerState<ServicesHubScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(() => setState(() {}));
  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Services'),
      actions: [
        IconButton(
          tooltip: 'Pickup & drop-off',
          icon: const Icon(Icons.local_shipping_outlined),
          onPressed: () => context.push('/pickups'),
        ),
        const NotificationsButton(),
      ],
      bottom: TabBar(
        controller: _tabs,
        tabs: const [
          Tab(text: 'Bookings'),
          Tab(text: 'My services'),
        ],
      ),
    ),
    floatingActionButton: _tabs.index == 1
        ? FloatingActionButton.extended(
            onPressed: () => context.push('/services/new'),
            icon: const Icon(Icons.add),
            label: const Text('Add service'),
          )
        : null,
    body: TabBarView(
      controller: _tabs,
      children: const [BookingsListScreen(), ServicesListScreen()],
    ),
  );
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/providers.dart';
import 'models.dart';

class AddressesNotifier extends AsyncNotifier<List<Address>> {
  @override
  Future<List<Address>> build() async {
    if (ref.watch(currentUserIdProvider) == null) return const [];
    return ref.read(addressRepositoryProvider).list();
  }

  Future<void> reload() async => state = await AsyncValue.guard(
    () => ref.read(addressRepositoryProvider).list(),
  );

  Future<void> create(AddressInput a) async {
    await ref.read(addressRepositoryProvider).create(a);
    await reload();
  }

  Future<void> edit(String id, AddressInput a) async {
    await ref.read(addressRepositoryProvider).update(id, a);
    if (a.makeDefault) await ref.read(addressRepositoryProvider).setDefault(id);
    await reload();
  }

  Future<void> delete(String id) async {
    await ref.read(addressRepositoryProvider).delete(id);
    await reload();
  }

  Future<void> setDefault(String id) async {
    await ref.read(addressRepositoryProvider).setDefault(id);
    await reload();
  }
}

final addressesProvider =
    AsyncNotifierProvider<AddressesNotifier, List<Address>>(
      AddressesNotifier.new,
    );

/// The address shown in the home header: the default one, else the first saved.
final selectedAddressProvider = Provider<Address?>(
  (ref) => ref
      .watch(addressesProvider)
      .maybeWhen(
        data: (list) => list.isEmpty
            ? null
            : list.firstWhere((a) => a.isDefault, orElse: () => list.first),
        orElse: () => null,
      ),
);

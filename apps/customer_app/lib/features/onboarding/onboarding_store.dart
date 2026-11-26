import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers whether this device has already seen the onboarding. Overridden in `main()` (and with a fake in tests).
abstract class OnboardingStore {
  bool get isCompleted;
  Future<void> markCompleted();
}

class SharedPrefsOnboardingStore implements OnboardingStore {
  SharedPrefsOnboardingStore(this._prefs);
  static const key = 'onboarding_completed';
  final SharedPreferences _prefs;

  static Future<SharedPrefsOnboardingStore> create() async =>
      SharedPrefsOnboardingStore(await SharedPreferences.getInstance());

  @override
  bool get isCompleted => _prefs.getBool(key) ?? false;

  @override
  Future<void> markCompleted() => _prefs.setBool(key, true);
}

final onboardingStoreProvider = Provider<OnboardingStore>(
  (ref) =>
      throw UnimplementedError('onboardingStoreProvider must be overridden'),
);

/// `true` once onboarding has been finished or skipped. The router listens to this to decide the first screen.
class OnboardingController extends Notifier<bool> {
  @override
  bool build() => ref.watch(onboardingStoreProvider).isCompleted;

  Future<void> complete() async {
    state = true; // flip first so the UI/router never waits on disk
    try {
      await ref.read(onboardingStoreProvider).markCompleted();
    } catch (_) {
      // Persisting is best-effort; failing must never trap the user on this screen.
    }
  }
}

final onboardingCompletedProvider =
    NotifierProvider<OnboardingController, bool>(OnboardingController.new);

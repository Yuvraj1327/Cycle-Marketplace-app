import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the chosen theme on this device. Overridden in `main()` with the SharedPreferences store (and with a fake in tests).
abstract class ThemeModeStore {
  ThemeMode load();
  Future<void> save(ThemeMode mode);
}

class SharedPrefsThemeModeStore implements ThemeModeStore {
  SharedPrefsThemeModeStore(this._prefs);
  static const key = 'theme_mode';
  final SharedPreferences _prefs;

  static Future<SharedPrefsThemeModeStore> create() async =>
      SharedPrefsThemeModeStore(await SharedPreferences.getInstance());

  /// Anything missing or unrecognised means "follow the system".
  @override
  ThemeMode load() => switch (_prefs.getString(key)) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  @override
  Future<void> save(ThemeMode mode) => _prefs.setString(key, mode.name);
}

/// Not persisted: the default when nothing is wired (tests); `main()` always overrides it.
class MemoryThemeModeStore implements ThemeModeStore {
  MemoryThemeModeStore([this._mode = ThemeMode.system]);
  ThemeMode _mode;
  @override
  ThemeMode load() => _mode;
  @override
  Future<void> save(ThemeMode mode) async => _mode = mode;
}

final themeModeStoreProvider = Provider<ThemeModeStore>(
  (ref) => MemoryThemeModeStore(),
);

/// The active theme choice. The app root watches it, so changing it restyles the whole app at once.
class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ref.watch(themeModeStoreProvider).load();

  Future<void> set(ThemeMode mode) async {
    state = mode; // apply first so the UI never waits on disk
    try {
      await ref.read(themeModeStoreProvider).save(mode);
    } catch (_) {
      // Persisting is best-effort: the choice still applies for this session.
    }
  }
}

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(
  ThemeModeController.new,
);

import 'package:flutter/material.dart';

/// One design system for the whole app: colours, type, shape and component themes are defined here and nowhere else.
class AppColors {
  const AppColors._();
  static const primary = Color(0xFF0F4C81); // business blue (vendor identity)
  static const accent = Color(
    0xFFF08A24,
  ); // saffron/orange for price + calls to attention
  static const background = Color(0xFFF4F7FA);
  static const surface = Colors.white;
  static const ink = Color(0xFF132033);
  static const muted = Color(0xFF5B6B7F);
  static const line = Color(0xFFE1E7EE);
  static const success = Color(0xFF1F8A4C);
  static const warning = Color(0xFFB7791F);
  static const danger = Color(0xFFC0392B);
  static const info = Color(0xFF2563A8);
}

class AppSpacing {
  const AppSpacing._();
  static const xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 24.0, xxl = 32.0;
}

/// The colours that change between light and dark. Read them with `context.palette` (never `AppColors.*` for surfaces, text or lines),
/// so every screen follows the active theme. [AppColors] keeps the fixed brand and status colours.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.background,
    required this.surface,
    required this.ink,
    required this.muted,
    required this.line,
    required this.primary,
  });
  final Color background, surface, ink, muted, line, primary;

  static const light = AppPalette(
    background: AppColors.background,
    surface: AppColors.surface,
    ink: AppColors.ink,
    muted: AppColors.muted,
    line: AppColors.line,
    primary: AppColors.primary,
  );
  static const dark = AppPalette(
    background: Color(0xFF0D141C),
    surface: Color(0xFF16212D),
    ink: Color(0xFFE6ECF2),
    muted: Color(0xFF9AA9BA),
    line: Color(0xFF2A3846),
    primary: Color(
      0xFF3B82C4,
    ), // lighter blue: readable as text/icons on dark surfaces and still carries white labels
  );

  @override
  AppPalette copyWith({
    Color? background,
    Color? surface,
    Color? ink,
    Color? muted,
    Color? line,
    Color? primary,
  }) => AppPalette(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    ink: ink ?? this.ink,
    muted: muted ?? this.muted,
    line: line ?? this.line,
    primary: primary ?? this.primary,
  );

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      line: Color.lerp(line, other.line, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
    );
  }
}

extension AppPaletteContext on BuildContext {
  /// The palette of the active theme (light when the theme carries none, e.g. a bare `ThemeData` in a test).
  AppPalette get palette =>
      Theme.of(this).extension<AppPalette>() ?? AppPalette.light;
}

ThemeData buildTheme() => _buildTheme(AppPalette.light, Brightness.light);
ThemeData buildDarkTheme() => _buildTheme(AppPalette.dark, Brightness.dark);

ThemeData _buildTheme(AppPalette p, Brightness brightness) {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: p.primary,
        brightness: brightness,
      ).copyWith(
        primary: p.primary,
        onPrimary: Colors.white,
        secondary: AppColors.accent,
        surface: p.surface,
        error: AppColors.danger,
        onSurface: p.ink,
      );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.background,
    extensions: [p],
  );
  final text = base.textTheme
      .apply(bodyColor: p.ink, displayColor: p.ink)
      .copyWith(
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        titleSmall: base.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      );
  final radius = BorderRadius.circular(12);
  return base.copyWith(
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: p.surface,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 1,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: p.line),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: p.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: p.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: p.primary, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: AppColors.danger),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(borderRadius: radius),
        side: BorderSide(color: p.primary),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      side: BorderSide(color: p.line),
      backgroundColor: p.surface,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.surface,
      indicatorColor: p.primary.withValues(alpha: .14),
      labelTextStyle: WidgetStatePropertyAll(text.labelMedium),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: radius),
    ),
    dividerTheme: DividerThemeData(color: p.line, space: 1),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}

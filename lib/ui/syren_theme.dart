import 'package:flutter/material.dart';

/// Colors from the SyrenApp screen designs.
abstract final class SyrenColors {
  static const background = Color(0xFFF3F0EA);
  static const card = Color(0xFFFFFFFF);
  static const softCard = Color(0xFFFAF8F4);
  static const chip = Color(0xFFE9E4DB);
  static const divider = Color(0xFFEEE9E1);
  static const border = Color(0xFFE4DFD6);
  static const dashed = Color(0xFFD6D0C5);
  static const ink = Color(0xFF1C1B19);
  static const muted = Color(0xFF6B675F);
  static const faint = Color(0xFFB9B3A8);
  static const subtle = Color(0xFF4A4740);
  static const accent = Color(0xFFD9623B);
  static const warningBackground = Color(0xFFFBEFD9);
  static const warning = Color(0xFF8A4F07);
  static const goodBackground = Color(0xFFDCEFE3);
  static const good = Color(0xFF1F6B43);
  static const badBackground = Color(0xFFF9E3DE);
  static const badRow = Color(0xFFFBF3F1);
  static const bad = Color(0xFFB83A26);
  static const spotify = Color(0xFF1DB954);

  /// Person colors, handed out in profile order.
  static const people = [
    Color(0xFFD9623B),
    Color(0xFF3E6FD1),
    Color(0xFF2F8A5B),
    Color(0xFF8A4FBF),
    Color(0xFFB7791F),
    Color(0xFF1F8A8A),
    Color(0xFFC2417A),
    Color(0xFF5B6B7F),
  ];
  static const guest = Color(0xFF8A857C);

  /// A pale background in a person's color.
  static Color tint(Color color) => Color.lerp(color, Colors.white, 0.82)!;

  /// A dark text color that reads well on [tint].
  static Color shade(Color color) => Color.lerp(color, Colors.black, 0.4)!;
}

abstract final class SyrenFonts {
  static const sans = 'SchibstedGrotesk';
  static const mono = 'IBMPlexMono';
}

/// Text styles used across the profile screens.
abstract final class SyrenText {
  static const title = TextStyle(
    fontFamily: SyrenFonts.sans,
    fontSize: 28,
    height: 1.1,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.56,
    color: SyrenColors.ink,
  );
  static const hero = TextStyle(
    fontFamily: SyrenFonts.sans,
    fontSize: 30,
    height: 1.1,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.6,
    color: SyrenColors.ink,
  );
  static const heading = TextStyle(
    fontFamily: SyrenFonts.sans,
    fontSize: 24,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.24,
    color: SyrenColors.ink,
  );
  static const cardTitle = TextStyle(
    fontFamily: SyrenFonts.sans,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: SyrenColors.ink,
  );
  static const label = TextStyle(
    fontFamily: SyrenFonts.sans,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: SyrenColors.ink,
  );
  static const body = TextStyle(
    fontFamily: SyrenFonts.sans,
    fontSize: 15,
    height: 1.4,
    color: SyrenColors.ink,
  );
  static const small = TextStyle(
    fontFamily: SyrenFonts.sans,
    fontSize: 13,
    height: 1.35,
    color: SyrenColors.muted,
  );
  static const lead = TextStyle(
    fontFamily: SyrenFonts.sans,
    fontSize: 15,
    height: 1.45,
    color: SyrenColors.muted,
  );
  static const mono = TextStyle(
    fontFamily: SyrenFonts.mono,
    fontSize: 11,
    letterSpacing: 0.44,
    color: SyrenColors.muted,
  );
}

ThemeData syrenTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    fontFamily: SyrenFonts.sans,
    colorScheme: ColorScheme.fromSeed(
      seedColor: SyrenColors.accent,
      brightness: Brightness.light,
      surface: SyrenColors.background,
      primary: SyrenColors.ink,
      onPrimary: Colors.white,
      secondary: SyrenColors.accent,
      error: SyrenColors.bad,
    ),
  );
  return base.copyWith(
    scaffoldBackgroundColor: SyrenColors.background,
    dividerColor: SyrenColors.divider,
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: SyrenColors.ink,
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 6,
      inactiveTrackColor: SyrenColors.divider,
      overlayShape: RoundSliderOverlayShape(overlayRadius: 16),
      thumbShape: RoundSliderThumbShape(
        enabledThumbRadius: 9,
        elevation: 0,
        pressedElevation: 0,
      ),
      trackShape: RoundedRectSliderTrackShape(),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? SyrenColors.ink
            : SyrenColors.faint,
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      side: const BorderSide(color: SyrenColors.faint, width: 1.6),
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? SyrenColors.ink
            : Colors.transparent,
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: InputBorder.none,
      isDense: true,
    ),
    dialogTheme: const DialogThemeData(backgroundColor: SyrenColors.card),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: SyrenColors.card,
      showDragHandle: true,
      dragHandleColor: SyrenColors.dashed,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: SyrenColors.divider,
      indicatorColor: SyrenColors.ink,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? Colors.white
              : SyrenColors.muted,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: SyrenFonts.sans,
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? SyrenColors.ink
              : SyrenColors.muted,
        ),
      ),
    ),
  );
}

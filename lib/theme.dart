import 'package:flutter/material.dart';

/// Colours copied from vibe-flutter's theme (dark and light).
class VC {
  final Color rail, pane, chat, card, text, muted, faint, divider, input;
  final bool dark;
  const VC._(this.dark, this.rail, this.pane, this.chat, this.card, this.text,
      this.muted, this.faint, this.divider, this.input);

  /// Accent colour: blurple by default, changeable in Appearance.
  static Color accent = const Color(0xFF5865F2);
  static Color get blurple => accent;
  static const green = Color(0xFF23A55A);
  static const red = Color(0xFFF23F43);
  static const yellow = Color(0xFFF0B232);

  static const accents = <Color>[
    Color(0xFF5865F2), // blurple
    Color(0xFF23A55A), // green
    Color(0xFFEB459E), // pink
    Color(0xFFF0B232), // yellow
    Color(0xFFF26522), // orange
    Color(0xFF00A8FC), // sky
    Color(0xFF9B59B6), // purple
    Color(0xFFED4245), // red
  ];

  // rail, pane, chat, card, text, muted, faint, divider, input
  static const darkC = VC._(true, Color(0xFF121214), Color(0xFF252429), Color(0xFF1A191E),
      Color(0xFF1E1D22), Color(0xFFF2F3F5), Color(0xFFB5BAC1), Color(0xFF949BA4),
      Color(0xFF3A393F), Color(0xFF29282D));
  static const lightC = VC._(false, Color(0xFFE3E5E8), Color(0xFFF2F3F5), Color(0xFFFFFFFF),
      Color(0xFFF7F7F8), Color(0xFF313338), Color(0xFF5C5E66), Color(0xFF80848E),
      Color(0xFFD8D9DC), Color(0xFFEBEDEF));

  static VC of(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? darkC : lightC;

  /// Names in the timeline, like Vibe: yours muted, others bright (dark-ink in light mode).
  Color nameColor(bool mine) =>
      dark ? (mine ? const Color(0xFFB5BAC1) : const Color(0xFFF2F3F5))
           : (mine ? const Color(0xFF4E5058) : const Color(0xFF060607));

  /// Soft shadow under names in light mode so they stand out on white (from Vibe).
  List<Shadow>? get nameShadows => dark
      ? null
      : const [Shadow(color: Color(0x40000000), blurRadius: 4, offset: Offset(0, 1))];
}

ThemeData vibeTheme(Brightness b) {
  final c = b == Brightness.dark ? VC.darkC : VC.lightC;
  return ThemeData(
    brightness: b,
    useMaterial3: true,
    fontFamily: 'GGSans',
    scaffoldBackgroundColor: c.pane,
    colorScheme: ColorScheme.fromSeed(
        seedColor: VC.blurple, brightness: b, primary: VC.blurple, surface: c.chat),
    dividerColor: c.divider,
    appBarTheme: AppBarTheme(
        backgroundColor: c.chat, foregroundColor: c.text, elevation: 0, scrolledUnderElevation: 0),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: c.chat),
    dialogTheme: DialogThemeData(backgroundColor: c.chat),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? VC.green : c.faint),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
  );
}

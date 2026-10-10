import 'package:flutter/material.dart';

/// Discord palette, same as Vibe.
class VC {
  final Color rail, pane, chat, card, text, muted, faint, divider, input;
  final bool dark;
  const VC._(this.dark, this.rail, this.pane, this.chat, this.card, this.text,
      this.muted, this.faint, this.divider, this.input);

  static const blurple = Color(0xFF5865F2);
  static const green = Color(0xFF23A55A);
  static const red = Color(0xFFF23F43);
  static const yellow = Color(0xFFF0B232);

  static const darkC = VC._(true, Color(0xFF1E1F22), Color(0xFF2B2D31), Color(0xFF313338),
      Color(0xFF232428), Color(0xFFF2F3F5), Color(0xFFB5BAC1), Color(0xFF80848E),
      Color(0xFF3F4147), Color(0xFF1E1F22));
  static const lightC = VC._(false, Color(0xFFE3E5E8), Color(0xFFF2F3F5), Color(0xFFFFFFFF),
      Color(0xFFEBEDEF), Color(0xFF060607), Color(0xFF4E5058), Color(0xFF6D6F78),
      Color(0xFFD7D9DC), Color(0xFFE3E5E8));

  static VC of(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? darkC : lightC;
}

ThemeData vibeTheme(Brightness b) {
  final c = b == Brightness.dark ? VC.darkC : VC.lightC;
  return ThemeData(
    brightness: b,
    useMaterial3: true,
    fontFamily: 'GGSans',
    scaffoldBackgroundColor: c.pane,
    colorScheme: ColorScheme.fromSeed(
        seedColor: VC.blurple, brightness: b, primary: VC.blurple, surface: c.pane),
    appBarTheme: AppBarTheme(
        backgroundColor: c.pane, foregroundColor: c.text, elevation: 0, scrolledUnderElevation: 0),
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

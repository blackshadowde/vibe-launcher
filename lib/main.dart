import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'home.dart';
import 'launcher.dart';
import 'memory.dart';
import 'theme.dart';

final navKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep going after an error instead of showing a grey box, and report it in chat
  FlutterError.onError = (d) {
    // Note it first: printing a very large error can itself fail
    noteError(d.exception, d.stack, during: d.context?.toString());
    if (kDebugMode) {
      try {
        FlutterError.presentError(d);
      } catch (_) {}
    }
  };
  PlatformDispatcher.instance.onError = (e, st) {
    noteError(e, st);
    return true;
  };
  ErrorWidget.builder = (d) => const SizedBox.shrink();
  // Never let a slow start keep the home screen white
  try {
    await prefs.load().timeout(const Duration(seconds: 8));
  } catch (_) {}
  memory.load();
  Native.init();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const VibeLauncher());
}

class VibeLauncher extends StatelessWidget {
  const VibeLauncher({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: prefs,
      builder: (_, __) => MaterialApp(
        navigatorKey: navKey,
        debugShowCheckedModeBanner: false,
        title: 'Vibe Launcher',
        themeMode: prefs.theme,
        theme: vibeTheme(Brightness.light),
        darkTheme: vibeTheme(Brightness.dark),
        home: const HomePage(),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'home.dart';
import 'launcher.dart';
import 'theme.dart';

final navKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await prefs.load();
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

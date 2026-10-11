import 'package:flutter/material.dart';
import 'screens/splash_screen.dart';

/// Minimal app wrapper for the splash screen
/// This runs in a separate frameless window before the main app
class SplashApp extends StatelessWidget {
  const SplashApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SplashScreen(),
    );
  }
}

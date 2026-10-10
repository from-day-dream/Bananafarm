import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'providers/theme_provider.dart' as theme_provider;
import 'providers/common_providers.dart';
import 'screens/job_submission_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/main_layout_screen.dart';
import 'screens/fatal_error_screen.dart';
import 'splash_app.dart';
import 'theme/app_theme.dart';
import 'services/local_storage_service.dart';
import 'services/logger_service.dart';
import 'services/app_initialization_service.dart';
import 'package:window_manager/window_manager.dart';
import 'services/system_tray_service.dart';
import 'services/notification_service.dart';
import 'utils/keys.dart';

late LocalStorageService _localStorageService;
late LoggerService _loggerService;

// Global notifier for splash screen status updates
final ValueNotifier<String> initializationStatus = ValueNotifier<String>(
  'Initializing...',
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
  };

  try {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;

      // Initialize Window Manager for SPLASH SCREEN first
      await windowManager.ensureInitialized();

      // FRAMELESS SPLASH WINDOW (Discord/Riot style)
      WindowOptions splashOptions = const WindowOptions(
        size: Size(600, 400),
        center: true,
        backgroundColor: Colors.transparent,
        skipTaskbar: true,
        titleBarStyle: TitleBarStyle.hidden, // No title bar
        windowButtonVisibility: false, // No window buttons
      );

      await windowManager.waitUntilReadyToShow(splashOptions, () async {
        await windowManager.setAsFrameless(); // Frameless window
        await windowManager.setBackgroundColor(Colors.transparent);
        await windowManager.show();
        await windowManager.focus();
      });
    }

    // Show splash screen app
    runApp(
      const ProviderScope(
        key: ValueKey('SplashProviderScope'),
        child: SplashApp(),
      ),
    );

    // Initialize services in background
    initializationStatus.value = 'Preparing storage...';
    _localStorageService = LocalStorageService();
    await _localStorageService.initialize();

    _loggerService = LoggerService();
    await _loggerService.initialize();

    // ---------------------------------------------------------
    // CRITICAL INITIALIZATION CHECKS
    // ---------------------------------------------------------

    // Check/Create the temp tree shared with the Blender addon
    initializationStatus.value = 'Checking file system...';
    await AppInitializationService.ensureTempRoot();

    // ---------------------------------------------------------

    // Wait minimum splash duration
    initializationStatus.value = 'Starting...';
    await Future.delayed(const Duration(seconds: 2));

    if (Platform.isWindows || Platform.isLinux) {
      // Reconfigure window for MAIN APP
      WindowOptions mainWindowOptions = const WindowOptions(
        size: Size(1280, 720),
        center: true,
        backgroundColor: Colors.transparent,
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.normal,
      );

      await windowManager.waitUntilReadyToShow(mainWindowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      });

      // Initialize Services
      await SystemTrayService().init();
    }

    // Outside the Windows/Linux block on purpose: macOS needs this too, and
    // used to miss it entirely. It now also asks the OS for permission, so
    // deferring it to the first notification would mean the first completed
    // render races the permission prompt and loses.
    await NotificationService().init();

    // Launch main app — no login: straight to the dashboard.
    runApp(
      ProviderScope(
        key: const ValueKey('MainAppProviderScope'),
        overrides: [
          loggerServiceProvider.overrideWithValue(_loggerService),
          localStorageServiceProvider.overrideWithValue(_localStorageService),
        ],
        child: const MyApp(),
      ),
    );
  } on AppInitializationError catch (e) {
    // Handle Expected Fatal Errors
    runApp(FatalErrorScreen(title: e.title, message: e.message));
  } catch (e) {
    // Handle Unexpected Fatal Errors
    try {
      _loggerService.error('Fatal initialization error: $e');
    } catch (_) {
      print('Fatal initialization error (Logger not ready): $e');
    }

    runApp(
      FatalErrorScreen(
        title: 'Unexpected Error',
        message: 'An critical error occurred during startup:\n$e',
      ),
    );
  }
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> {
  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // Defer initialization to next frame to avoid state updates during build
    Future.microtask(() async {
      final themeNotifier = ref.read(theme_provider.themeProvider.notifier);
      // LocalStorageService is a singleton initialized during boot
      await themeNotifier.initialize(LocalStorageService());
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(theme_provider.themeProvider);

    ThemeMode materialThemeMode;
    switch (themeMode) {
      case theme_provider.ThemeMode.light:
        materialThemeMode = ThemeMode.light;
        break;
      case theme_provider.ThemeMode.dark:
        materialThemeMode = ThemeMode.dark;
        break;
      case theme_provider.ThemeMode.system:
        materialThemeMode = ThemeMode.system;
        break;
    }

    return MaterialApp(
      title: 'Blender Render Farm',
      navigatorKey: navigatorKey, // From utils/keys.dart
      scaffoldMessengerKey: scaffoldMessengerKey, // From utils/keys.dart
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: materialThemeMode,
      home: const MainLayoutScreen(),
      routes: {
        '/dashboard': (_) => const MainLayoutScreen(),
        '/job-submission': (_) => const JobSubmissionScreen(),
        '/profile': (_) => const ProfileScreen(),
      },
    );
  }
}

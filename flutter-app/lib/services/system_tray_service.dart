import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';

class SystemTrayService with TrayListener, WindowListener {
  static final SystemTrayService _instance = SystemTrayService._internal();
  factory SystemTrayService() => _instance;
  SystemTrayService._internal();

  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;
    
    await trayManager.setIcon(
       Platform.isWindows ? 'assets/icon/app_icon.ico' : 'assets/icon/icon.png', 
    );
    
    // Create the menu
    Menu menu = Menu(
      items: [
        MenuItem(
          key: 'show_window',
          label: 'Show Banana Farm',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'exit_app',
          label: 'Exit',
        ),
      ],
    );
    
    await trayManager.setContextMenu(menu);
    
    // Add listeners
    trayManager.addListener(this);
    windowManager.addListener(this);
    
    // Prevent default close to handle "Close to Tray"
    await windowManager.setPreventClose(true);
    
    _isInitialized = true;
  }
  
  void dispose() {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
  }

  // --- TrayListener ---
  
  @override
  void onTrayIconMouseDown() {
    // Left click on tray icon -> restore window
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show_window') {
      windowManager.show();
      windowManager.focus();
    } else if (menuItem.key == 'exit_app') {
      // Must allow close before exiting or just force exit
      windowManager.destroy(); // This triggers onWindowClose but we might want to bypass
      exit(0);
    }
  }

  // --- WindowListener ---

  @override
  void onWindowMinimize() async {
    // Check if "Minimize to Tray" is enabled
    final prefs = await SharedPreferences.getInstance();
    final minimizeToTray = prefs.getBool('minimize_to_tray') ?? false;
    
    if (minimizeToTray) {
      // Hide the window instead of just minimizing
      await windowManager.hide();
      // Optional: We could notify here too, but closing is the main confusion point.
    }
    // Else: let it minimize normally (default behavior)
  }
  
  @override
  void onWindowClose() async {
    final prefs = await SharedPreferences.getInstance();
    final minimizeToTray = prefs.getBool('minimize_to_tray') ?? false;
    
    if (minimizeToTray) {
      // Hide to tray instead of closing
      await windowManager.hide();
      
      // Notify the user so they know it's not actually closed.
      // Honours the same Settings toggle as job notifications; read from
      // storage rather than Riverpod because this runs outside the widget
      // tree, on a window callback.
      if (prefs.getBool('show_notifications') ?? true) {
        await NotificationService().show(
          title: 'Banana Farm is running',
          body:
              'The app is running in the background.\nRight-click the tray icon to Exit.',
        );
      }
    } else {
      // Actually close the app
      await windowManager.destroy();
    }
  }
}

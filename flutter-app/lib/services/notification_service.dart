import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Desktop notifications for job completion and background-running notices.
///
/// Replaced `local_notifier`, whose macOS implementation used
/// `NSUserNotification` — deprecated in macOS 11 and silently non-delivering by
/// macOS 14, which is why notifications worked on Windows but not on Mac. This
/// package uses `UNUserNotificationCenter` on macOS and C++/WinRT toasts on
/// Windows.
///
/// The public API is deliberately unchanged from the old service, so the four
/// call sites did not have to move.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  /// Windows resolves a toast's identity from this, matched by the
  /// `AppUserModelID` on the Start Menu shortcut that `installer.iss` creates.
  /// It also matches the macOS bundle id and the URL protocol, so the app has
  /// one identity rather than three. Changing it here without changing the
  /// installer silently stops Windows toasts appearing.
  static const _appUserModelId = 'app.bananafarm.desktop';

  /// The Inno Setup `AppId`, reused so there is a single GUID for the app.
  static const _appGuid = '8a8f27d8-4c8e-4e5f-9d1b-2a3b4c5d6e7f';

  final _plugin = FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;

  /// Callers supply no id, but the plugin requires one. A counter keeps each
  /// notification distinct so a new one never replaces an unread earlier one.
  int _nextId = 0;

  /// Whether the OS will actually deliver. macOS can refuse while the app's own
  /// `showNotifications` setting still reads on — without surfacing that, a
  /// declined permission looks exactly like the bug this class just fixed.
  bool _permissionGranted = true;
  bool get permissionGranted => _permissionGranted;

  Future<void> init() async {
    if (_isInitialized) return;

    await _plugin.initialize(
      settings: const InitializationSettings(
        // Permissions are requested explicitly below rather than here, so the
        // result is observable instead of being discarded.
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        windows: WindowsInitializationSettings(
          appName: 'Banana Farm',
          appUserModelId: _appUserModelId,
          guid: _appGuid,
        ),
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
      ),
    );

    if (Platform.isMacOS) {
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      // A null result means the platform implementation was unavailable, which
      // is not the same as a refusal — don't report a denial we didn't get.
      _permissionGranted = granted ?? true;
    }

    _isInitialized = true;
  }

  Future<void> show({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_isInitialized) await init();

    await _plugin.show(
      id: _nextId++,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        macOS: DarwinNotificationDetails(),
        windows: WindowsNotificationDetails(),
        linux: LinuxNotificationDetails(),
      ),
      payload: payload,
    );
  }
}

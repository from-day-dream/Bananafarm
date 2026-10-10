import 'package:bananafarm/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// These cover the parts of NotificationService that exist without an OS.
///
/// **A green run here does NOT mean notifications are delivered.** Delivery
/// depends on the native plugin, code signing on macOS, and the Start Menu
/// shortcut's AppUserModelID on Windows — none of which a unit test can reach.
/// The bug this service was rewritten to fix (macOS silently delivering
/// nothing) would have passed every test below. Verify delivery by running the
/// app on each platform.
void main() {
  test('is a singleton, so every call site shares one plugin instance', () {
    expect(identical(NotificationService(), NotificationService()), isTrue);
  });

  test('assumes permission until the OS says otherwise', () {
    // Defaulting to false would make the Settings card claim macOS blocked
    // notifications on Windows and Linux, where it was never asked.
    expect(NotificationService().permissionGranted, isTrue);
  });
}

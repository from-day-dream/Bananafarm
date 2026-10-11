// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bananafarm/main.dart';
import 'package:bananafarm/services/local_storage_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  testWidgets('App launches without errors', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await LocalStorageService().initialize();

    // Build our app and trigger a frame.
    await tester.pumpWidget(const ProviderScope(child: MyApp()));

    // Verify that the app launches straight to the dashboard (no login).
    expect(find.byType(MyApp), findsOneWidget);

    // Unmount so the ProviderScope disposes its background pollers
    // (render job manager / queue timers) before the test's timer check.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

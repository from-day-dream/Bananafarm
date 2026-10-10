import 'app_paths.dart';

class AppInitializationError implements Exception {
  final String message;
  final String title;
  final bool isFatal;

  AppInitializationError(
    this.message, {
    this.title = 'Initialization Error',
    this.isFatal = true,
  });

  @override
  String toString() => message;
}

class AppInitializationService {
  /// Ensures the temp tree the app and the Blender addon both write to exists
  /// and is writable. Location: [AppPaths.tempRoot].
  static Future<void> ensureTempRoot() async {
    try {
      await AppPaths.ensureTempRoot();
      print('Temp root ready: ${AppPaths.tempRoot}');
    } catch (e) {
      throw AppInitializationError(
        'Failed to access or create the app data directory.\n'
        'Location: ${AppPaths.tempRoot}\nError: $e\n\n'
        'Please check your file permissions.',
        title: 'Filesystem Error',
      );
    }
  }
}

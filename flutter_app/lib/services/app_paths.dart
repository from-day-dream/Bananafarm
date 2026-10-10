import 'dart:io';
import 'package:path/path.dart' as p;

/// Filesystem layout for everything the app stages on disk.
///
/// The temp root is resolved from environment variables rather than
/// `path_provider` on purpose: the Blender addon has to be able to write into
/// the same tree, and `getApplicationSupportDirectory()` nests under an
/// org/app id that Python has no way to reproduce. The addon still asks the
/// app for the path over the localhost server (`GET /temp-root`) — this class
/// is the single source of truth behind that answer.
///
/// ```
/// <appdata>/day-dream/temp/
///   incoming/<name>_<hex>/   addon writes here, deleted once zipped
///   jobs/<jobId>/<name>.zip  lives until the job is deleted
/// ```
class AppPaths {
  /// Folders under `incoming/` older than this are considered abandoned by a
  /// crashed addon run. Generous enough that a slow pack is never swept.
  static const Duration _incomingMaxAge = Duration(hours: 24);

  /// `<appdata>/day-dream/temp`
  static String get tempRoot => p.join(_appDataRoot, 'day-dream', 'temp');

  /// Where the Blender addon packs a project before the app zips it.
  static String get incomingRoot => p.join(tempRoot, 'incoming');

  /// Parent of the per-job folders.
  static String get jobsRoot => p.join(tempRoot, 'jobs');

  /// The folder holding a single job's project zip. Named after the job id so
  /// deletion can always be verified against it.
  static String jobDir(String jobId) => p.join(jobsRoot, jobId);

  static String get _appDataRoot {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final appData = env['APPDATA'];
      if (appData != null && appData.isNotEmpty) return appData;
      return p.join(env['USERPROFILE'] ?? '', 'AppData', 'Roaming');
    }
    final home = env['HOME'] ?? '';
    if (Platform.isMacOS) {
      return p.join(home, 'Library', 'Application Support');
    }
    final xdg = env['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) return xdg;
    return p.join(home, '.local', 'share');
  }

  /// Create the temp tree and prove we can write to it. Throws on failure —
  /// the caller turns this into a fatal startup error.
  static Future<void> ensureTempRoot() async {
    for (final dir in [Directory(incomingRoot), Directory(jobsRoot)]) {
      if (!await dir.exists()) {
        print('Creating directory: ${dir.path}');
        await dir.create(recursive: true);
      }
    }

    final testFile = File(p.join(tempRoot, '.write_test'));
    await testFile.writeAsString('test');
    await testFile.delete();
  }

  /// Delete temp data that no longer belongs to anything: job folders whose id
  /// is unknown (deleted while the app was closed, or stranded by a crash) and
  /// stale `incoming/` folders from addon runs that never completed.
  ///
  /// Best-effort — a failure here is never worth interrupting startup for.
  static Future<void> sweepOrphans(Set<String> knownIds) async {
    await _sweep(
      Directory(jobsRoot),
      (entity) async => !knownIds.contains(p.basename(entity.path)),
    );
    final cutoff = DateTime.now().subtract(_incomingMaxAge);
    await _sweep(
      Directory(incomingRoot),
      (entity) async => (await entity.stat()).modified.isBefore(cutoff),
    );
  }

  static Future<void> _sweep(
    Directory root,
    Future<bool> Function(FileSystemEntity) shouldDelete,
  ) async {
    try {
      if (!await root.exists()) return;
      await for (final entity in root.list(followLinks: false)) {
        try {
          if (entity is! Directory) continue;
          if (!await shouldDelete(entity)) continue;
          await entity.delete(recursive: true);
          print('🧹 Swept orphaned temp folder: ${entity.path}');
        } catch (e) {
          print('⚠️ Could not sweep ${entity.path}: $e');
        }
      }
    } catch (e) {
      print('⚠️ Temp sweep of ${root.path} failed: $e');
    }
  }
}

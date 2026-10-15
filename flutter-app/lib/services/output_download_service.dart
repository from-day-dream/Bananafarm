import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/job_model.dart';
import '../utils/file_hash.dart';
import '../utils/format_utils.dart';
import 'instance_api_service.dart';

/// Downloads a finished job's outputs from its instance, with retries, and
/// verifies every file before reporting success.
///
/// Verification matters because a successful download is what licenses
/// deleting the instance — the only other copy of the render. A file counts
/// as downloaded only when its size matches the listing and, when the
/// container supplied one, its sha256 does too.
class OutputDownloadService {
  final InstanceApiService _api;

  /// Wait before each retry; its length + 1 is the number of attempts.
  final List<Duration> retryDelays;

  OutputDownloadService(
    this._api, {
    this.retryDelays = const [Duration(seconds: 10), Duration(seconds: 30)],
  });

  /// Download every output of [job] into `<downloadRoot>/<job name>/` and
  /// return that folder. Throws [OutputDownloadException] naming the file and
  /// reason once a file has failed every attempt.
  Future<String> downloadJobOutputs(
    RenderJob job, {
    required String downloadRoot,
    void Function(double fraction)? onProgress,
  }) async {
    final files = job.outputFiles;
    if (files.isEmpty) {
      throw OutputDownloadException('This job has no outputs to download');
    }

    final dir = Directory(p.join(
        downloadRoot, FormatUtils.sanitizeFolderName(job.renderParams.displayName)));
    await dir.create(recursive: true);

    final totalBytes =
        files.fold<int>(0, (sum, f) => sum + f.size).clamp(1, 1 << 62);
    var doneBytes = 0;

    for (final file in files) {
      await _downloadOne(job, file, dir.path, (received) {
        onProgress?.call(((doneBytes + received) / totalBytes).clamp(0, 1));
      });
      doneBytes += file.size;
    }
    onProgress?.call(1);
    return dir.path;
  }

  Future<void> _downloadOne(
    RenderJob job,
    OutputFileInfo file,
    String dir,
    void Function(int received) onReceived,
  ) async {
    // Partial bytes never sit under the real name, so an interrupted run
    // can't leave something that looks like a finished render.
    final part = p.join(dir, '${file.name}.part');

    for (var attempt = 0;; attempt++) {
      try {
        await _api.downloadOutput(
          job,
          file.name,
          part,
          onProgress: (received, _) => onReceived(received),
        );
        await _verify(part, file);
        await File(part).rename(uniqueOutputPath(dir, file.name));
        return;
      } catch (e) {
        await _deleteIfExists(part);
        if (attempt >= retryDelays.length) {
          throw OutputDownloadException(
              '${file.name}: ${e is OutputDownloadException ? e.message : e}');
        }
        print('⚠️ Download of ${file.name} failed (attempt ${attempt + 1}), '
            'retrying in ${retryDelays[attempt].inSeconds}s: $e');
        onReceived(0);
        await Future<void>.delayed(retryDelays[attempt]);
      }
    }
  }

  static Future<void> _verify(String path, OutputFileInfo expected) async {
    final size = await File(path).length();
    if (expected.size > 0 && size != expected.size) {
      throw OutputDownloadException(
          'size mismatch (got $size bytes, expected ${expected.size})');
    }
    final want = expected.sha256;
    if (want != null && want.isNotEmpty) {
      final got = await hashFileInIsolate(path);
      if (got != want) {
        throw OutputDownloadException('checksum mismatch');
      }
    }
  }

  static Future<void> _deleteIfExists(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// The download folder from settings, or the system Downloads folder.
  static Future<String> resolveDownloadRoot(String? configured) async {
    if (configured != null && configured.isNotEmpty) return configured;
    final dir = await getDownloadsDirectory();
    if (dir == null) {
      throw OutputDownloadException('Could not access the Downloads folder');
    }
    return dir.path;
  }
}

/// `dir/name`, or `dir/name_1.ext`, `name_2.ext`, … if that already exists,
/// so a repeat download never overwrites an earlier one.
String uniqueOutputPath(String dir, String fileName) {
  var path = p.join(dir, fileName);
  final ext = p.extension(fileName);
  final stem = p.basenameWithoutExtension(fileName);
  var counter = 1;
  while (File(path).existsSync()) {
    path = p.join(dir, '${stem}_$counter$ext');
    counter++;
  }
  return path;
}

class OutputDownloadException implements Exception {
  final String message;
  OutputDownloadException(this.message);

  @override
  String toString() => message;
}

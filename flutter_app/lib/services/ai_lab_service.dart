import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;
import '../models/ai_model.dart';

/// Provider for the AI Lab Service
final aiLabServiceProvider = Provider((ref) => AiLabService());

/// One step of an install, so the UI can say what is happening during the
/// long tail after the bytes have arrived (a 436MB extract is not instant).
class InstallProgress {
  final double fraction;
  final String message;

  const InstallProgress(this.fraction, this.message);
}

class AiLabService {
  AiLabService();

  /// Tools available for this platform, from the bundled catalog.
  Future<List<AIModel>> fetchAvailableModels() async {
    try {
      final jsonStr = await rootBundle.loadString('assets/data/ai_models.json');
      final List<dynamic> data = jsonDecode(jsonStr) as List<dynamic>;
      return data
          .map((json) => AIModel.fromMap((json as Map).cast<String, dynamic>()))
          .where((m) => m.isActive && m.isAvailableOnThisPlatform)
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
    } catch (e) {
      print('Error loading AI tools catalog: $e');
      return [];
    }
  }

  /// Root for one tool's install: `<appSupport>/tools/<toolId>/`.
  Future<Directory> toolDir(AIModel tool) async {
    final appDir = await getApplicationSupportDirectory();
    return Directory(path.join(appDir.path, 'tools', tool.id));
  }

  /// Absolute path to a tool's main binary, or null if not installed.
  ///
  /// Searches one level down as well, because the two vendors disagree about
  /// layout: the RIFE zip nests everything under a versioned folder while the
  /// Real-ESRGAN zip extracts flat.
  Future<String?> resolveExecutable(AIModel tool) async {
    final dir = await toolDir(tool);
    if (!await dir.exists()) return null;

    final direct = File(path.join(dir.path, tool.executableName));
    if (await direct.exists()) return direct.path;

    await for (final entity in dir.list()) {
      if (entity is Directory) {
        final nested = File(path.join(entity.path, tool.executableName));
        if (await nested.exists()) return nested.path;
      }
    }
    return null;
  }

  /// Path to a companion binary (ffprobe beside ffmpeg).
  Future<String?> resolveCompanion(AIModel tool, String companion) async {
    final exe = await resolveExecutable(tool);
    if (exe == null) return null;
    final candidate =
        File(path.join(path.dirname(exe), tool.companionName(companion)));
    return await candidate.exists() ? candidate.path : null;
  }

  Future<bool> isToolInstalled(AIModel tool) async =>
      await resolveExecutable(tool) != null;

  /// Directory holding a tool's weights, used for the `-m` flag.
  Future<String?> resolveModelsDir(AIModel tool) async {
    final exe = await resolveExecutable(tool);
    if (exe == null) return null;
    final models = Directory(path.join(path.dirname(exe), 'models'));
    // Real-ESRGAN keeps weights in models/; RIFE keeps one dir per variant
    // beside the binary, so the binary's own folder is the right -m root.
    return await models.exists() ? models.path : path.dirname(exe);
  }

  /// Download and install a tool, reporting progress throughout.
  Stream<InstallProgress> installTool(AIModel tool) async* {
    final asset = tool.asset;
    if (asset == null) {
      throw Exception('${tool.name} is not available for this platform');
    }

    final dir = await toolDir(tool);
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);

    if (asset.isArchive) {
      final archivePath = path.join(dir.path, 'download.zip');
      yield* _download(asset.url, archivePath, asset.bytes, 'Downloading',
          // Leave headroom for extraction, which is a real fraction of the
          // wait for a 436MB archive.
          scale: 0.7);

      yield const InstallProgress(0.72, 'Extracting...');
      await _extractArchive(archivePath, dir.path);
      await File(archivePath).delete();

      yield const InstallProgress(0.92, 'Finalising...');
      await _flattenIfNested(dir);
      await _trimModels(tool, dir);
    } else {
      final exePath = path.join(dir.path, tool.executableName);
      yield* _download(asset.url, exePath, asset.bytes, 'Downloading',
          scale: asset.companionUrls.isEmpty ? 0.95 : 0.6);

      var done = 0;
      for (final entry in asset.companionUrls.entries) {
        final name = tool.companionName(entry.key);
        yield* _download(
          entry.value,
          path.join(dir.path, name),
          0,
          'Downloading $name',
          scale: 0.35,
          offset: 0.6 + (done * 0.35),
        );
        done++;
      }
    }

    yield const InstallProgress(0.97, 'Setting permissions...');
    await _makeExecutables(dir);

    if (await resolveExecutable(tool) == null) {
      throw Exception(
          'Install finished but ${tool.executableName} was not found');
    }

    yield const InstallProgress(1.0, 'Installed');
  }

  /// Streams a URL to disk. [scale]/[offset] map it onto a slice of the
  /// overall install progress.
  Stream<InstallProgress> _download(
    String url,
    String destPath,
    int expectedBytes,
    String label, {
    double scale = 1.0,
    double offset = 0.0,
  }) async* {
    final file = File(destPath);
    await file.parent.create(recursive: true);

    IOSink? sink;
    try {
      final response =
          await http.Client().send(http.Request('GET', Uri.parse(url)));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode} fetching $url');
      }

      final total = response.contentLength ?? expectedBytes;
      var received = 0;
      sink = file.openWrite();

      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          final mb = (received / 1048576).toStringAsFixed(0);
          final totalMb = (total / 1048576).toStringAsFixed(0);
          yield InstallProgress(
            offset + (received / total) * scale,
            '$label... ${mb}MB / ${totalMb}MB',
          );
        }
      }
      await sink.flush();
    } catch (e) {
      // Close the handle and drop the partial file, so a retry starts clean.
      try {
        await sink?.close();
      } catch (_) {}
      sink = null;
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
      throw Exception('Download failed: $e');
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
    }
  }

  /// Extracts off the UI isolate — decoding hundreds of MB synchronously
  /// would freeze the app.
  Future<void> _extractArchive(String archivePath, String targetDir) async {
    await Isolate.run(() => _extractSync(archivePath, targetDir));
  }

  static void _extractSync(String archivePath, String targetDir) {
    final bytes = File(archivePath).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final root = Directory(targetDir).absolute.path;

    for (final entry in archive) {
      final outPath = path.normalize(path.join(targetDir, entry.name));

      // Zip-slip guard: an entry named ../../x must not escape the target.
      if (!path.isWithin(root, outPath)) {
        throw Exception('Unsafe archive entry: ${entry.name}');
      }

      if (entry.isFile) {
        final out = File(outPath);
        out.parent.createSync(recursive: true);
        out.writeAsBytesSync(entry.content as List<int>);
      } else {
        Directory(outPath).createSync(recursive: true);
      }
    }
  }

  /// Hoists a lone top-level folder up one level.
  ///
  /// Necessary because the vendors disagree: RIFE nests everything under
  /// `rife-ncnn-vulkan-20221029-macos/`, Real-ESRGAN extracts flat. Only acts
  /// when there is exactly one entry and it is a directory.
  Future<void> _flattenIfNested(Directory dir) async {
    final entries = await dir.list().toList();
    if (entries.length != 1 || entries.first is! Directory) return;

    final inner = entries.first as Directory;
    for (final child in await inner.list().toList()) {
      final dest = path.join(dir.path, path.basename(child.path));
      await child.rename(dest);
    }
    await inner.delete(recursive: true);
  }

  /// Deletes weight directories the app will never select.
  ///
  /// RIFE ships every variant back to v2; keeping only v4/v4.6 takes the
  /// install from ~466MB to ~20MB.
  Future<void> _trimModels(AIModel tool, Directory dir) async {
    if (tool.keepModels.isEmpty) return;

    final exe = await resolveExecutable(tool);
    final root = exe != null ? Directory(path.dirname(exe)) : dir;

    for (final entity in await root.list().toList()) {
      if (entity is! Directory) continue;
      final name = path.basename(entity.path);
      // Only ever delete something that looks like a weights folder for this
      // tool, never an unrelated directory.
      if (!name.startsWith(tool.executable.split('-').first)) continue;
      if (tool.keepModels.contains(name)) continue;
      try {
        await entity.delete(recursive: true);
      } catch (e) {
        print('Could not trim $name: $e');
      }
    }
  }

  /// Marks every extracted binary executable.
  ///
  /// Mandatory and not optional: the Real-ESRGAN zip stores mode 0 (it is
  /// built with FAT attributes), so the archive carries no permission bits to
  /// restore and the binary lands 0644. The RIFE zip does carry 0755. chmod
  /// unconditionally rather than trusting the archive.
  Future<void> _makeExecutables(Directory dir) async {
    if (Platform.isWindows) return;

    await for (final entity in dir.list(recursive: true)) {
      if (entity is! File) continue;
      final name = path.basename(entity.path);
      if (name.contains('.') && !name.endsWith('.sh')) continue; // skip data
      try {
        await Process.run('chmod', ['+x', entity.path]);
      } catch (e) {
        print('chmod failed for $name: $e');
      }
    }
  }

  /// Removes an installed tool.
  Future<void> uninstallTool(AIModel tool) async {
    final dir = await toolDir(tool);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Bytes on disk for an installed tool, for display.
  Future<int> installedSize(AIModel tool) async {
    final dir = await toolDir(tool);
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final e in dir.list(recursive: true)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
    return total;
  }
}

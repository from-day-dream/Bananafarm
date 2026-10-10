// Integration test for the Lab install pipeline and task execution, against
// the REAL Real-ESRGAN release archive.
//
// The archive is served from a local HTTP server so the test doesn't re-fetch
// 52MB from GitHub every run. Point REALESRGAN_ZIP at a local copy:
//
//   curl -L -o /tmp/realesrgan.zip \
//     https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-macos.zip
//   REALESRGAN_ZIP=/tmp/realesrgan.zip flutter test test/ai_lab_integration_test.dart
//
// Skipped automatically when that file isn't present.
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:bananafarm/models/ai_model.dart';
import 'package:bananafarm/models/ai_task.dart';
import 'package:bananafarm/services/ai_lab_service.dart';
import 'package:bananafarm/services/ai_task_service.dart';

/// Redirects getApplicationSupportDirectory() into a throwaway dir.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String root;
  _FakePathProvider(this.root);

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getDownloadsPath() async => root;
}

void main() {
  final zipPath = Platform.environment['REALESRGAN_ZIP'] ?? '/tmp/realesrgan.zip';
  final haveZip = File(zipPath).existsSync();
  final rifeZip = Platform.environment['RIFE_ZIP'] ?? '/tmp/rife.zip';
  final haveRife = File(rifeZip).existsSync();

  late Directory tmp;
  late HttpServer server;
  late AiLabService lab;

  setUpAll(() async {
    if (!haveZip) return;
    TestWidgetsFlutterBinding.ensureInitialized();
    // The test binding installs an HttpOverrides that makes every request
    // return 400. Drop it so the loopback server below is actually reachable.
    HttpOverrides.global = null;

    tmp = await Directory.systemTemp.createTemp('lab_itest_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);

    // Serve the archive locally.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      // Route on the request path so one server can serve both archives.
      final f = req.uri.path.contains('rife') ? File(rifeZip) : File(zipPath);
      req.response.headers.contentType = ContentType.binary;
      req.response.contentLength = await f.length();
      await f.openRead().pipe(req.response);
    });

    lab = AiLabService();
  });

  tearDownAll(() async {
    if (!haveZip) return;
    await server.close(force: true);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  AIModel toolFor(int port) => AIModel(
        id: 'realesrgan',
        name: 'Real-ESRGAN',
        executable: 'realesrgan-ncnn-vulkan',
        models: const ['realesrgan-x4plus'],
        assets: {
          // Key matches whatever this platform resolves to.
          for (final k in AIModel.platformKeys)
            k: ToolAsset(
              url: 'http://127.0.0.1:$port/realesrgan.zip',
              bytes: File(zipPath).lengthSync(),
              format: 'zip',
            ),
        },
      );

  group('install pipeline', skip: haveZip ? null : 'REALESRGAN_ZIP not present', () {
    test('downloads, extracts, and leaves an executable binary', () async {
      final tool = toolFor(server.port);

      final messages = <String>[];
      await for (final p in lab.installTool(tool)) {
        messages.add(p.message);
      }

      expect(messages.first, contains('Downloading'));
      expect(messages.last, 'Installed');

      final exe = await lab.resolveExecutable(tool);
      expect(exe, isNotNull, reason: 'binary should be found after install');

      // The Real-ESRGAN archive stores mode 0, so without an explicit chmod
      // the binary lands 0644 and every later exec dies with EACCES.
      final mode = File(exe!).statSync().mode;
      expect(mode & 0x49, isNonZero, reason: 'exec bit must be set: $mode');

      expect(await lab.isToolInstalled(tool), isTrue);
      expect(await lab.installedSize(tool), greaterThan(1000000));
    });

    test('resolves the bundled models directory', () async {
      final tool = toolFor(server.port);
      final dir = await lab.resolveModelsDir(tool);
      expect(dir, isNotNull);
      expect(Directory(dir!).existsSync(), isTrue);
    });
  });

  group('task execution', skip: haveZip ? null : 'REALESRGAN_ZIP not present', () {
    test('upscales a real image 4x', () async {
      final tool = toolFor(server.port);
      final exe = await lab.resolveExecutable(tool);
      expect(exe, isNotNull, reason: 'install test must run first');

      // The release ships sample images beside the binary.
      final sample = File(p.join(p.dirname(exe!), 'input.jpg'));
      expect(sample.existsSync(), isTrue,
          reason: 'release should include input.jpg');

      final outDir = Directory(p.join(tmp.path, 'out'))..createSync();
      final tasks = AiTaskService(lab);

      AiTaskResult? result;
      final seen = <AiTaskProgress>[];
      await for (final prog in tasks.upscale(
        inputs: [sample.path],
        outputDir: outDir.path,
        params: const UpscaleParams(scale: 4, model: 'realesrgan-x4plus'),
        onDone: (r) => result = r,
      )) {
        seen.add(prog);
      }

      expect(result, isNotNull, reason: 'task should complete');
      expect(seen, isNotEmpty, reason: 'should report progress');

      final produced = outDir.listSync().whereType<File>().toList();
      expect(produced, hasLength(1));
      expect(await produced.first.length(), greaterThan(0));
    });

    test('reports a clear error for a missing tool', () async {
      final tasks = AiTaskService(lab);
      expect(
        () => tasks.upscale(
          inputs: const ['/nonexistent/x.png'],
          outputDir: tmp.path,
          params: const UpscaleParams(),
          onDone: (_) {},
        ).drain(),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('rife: nested archive, trimming, interpolation',
      skip: (haveZip && haveRife) ? null : 'RIFE_ZIP not present', () {
    AIModel rifeTool(int port) => AIModel(
          id: 'rife',
          name: 'RIFE',
          executable: 'rife-ncnn-vulkan',
          models: const ['rife-v4.6', 'rife-v4'],
          keepModels: const ['rife-v4.6', 'rife-v4'],
          assets: {
            for (final k in AIModel.platformKeys)
              k: ToolAsset(
                url: 'http://127.0.0.1:$port/rife.zip',
                bytes: File(rifeZip).lengthSync(),
                format: 'zip',
              ),
          },
        );

    test('flattens the nested folder and trims unused weights', () async {
      final tool = rifeTool(server.port);
      await lab.installTool(tool).drain();

      // Unlike Real-ESRGAN, this archive nests everything under
      // rife-ncnn-vulkan-<date>-<os>/ — the installer must hoist it.
      final exe = await lab.resolveExecutable(tool);
      expect(exe, isNotNull);

      final root = Directory(p.dirname(exe!));
      final kept = root
          .listSync()
          .whereType<Directory>()
          .map((d) => p.basename(d.path))
          .where((n) => n.startsWith('rife'))
          .toSet();

      expect(kept, containsAll(<String>['rife-v4.6', 'rife-v4']));
      expect(kept, isNot(contains('rife-UHD')),
          reason: 'unused weights should be trimmed');
      expect(kept, isNot(contains('rife-anime')));

      // Trimming is the difference between ~466MB and ~20MB installed.
      final size = await lab.installedSize(tool);
      expect(size, lessThan(120 * 1024 * 1024),
          reason: 'trimmed install should be far smaller than 466MB');
    });

    test('interpolates a 2-frame sequence to 4 frames', () async {
      final tool = rifeTool(server.port);
      final exe = await lab.resolveExecutable(tool);
      expect(exe, isNotNull, reason: 'install test must run first');

      // Build a 2-frame sequence from the Real-ESRGAN samples, resized to
      // match (RIFE needs consistent dimensions).
      final esr = await lab.resolveExecutable(AIModel(
          id: 'realesrgan',
          name: 'r',
          executable: 'realesrgan-ncnn-vulkan'));
      final seqIn = Directory(p.join(tmp.path, 'seq_in'))..createSync();
      final srcDir = p.dirname(esr!);
      File(p.join(srcDir, 'input.jpg'))
          .copySync(p.join(seqIn.path, '00000001.jpg'));
      File(p.join(srcDir, 'input.jpg'))
          .copySync(p.join(seqIn.path, '00000002.jpg'));

      final outDir = p.join(tmp.path, 'seq_out');
      final tasks = AiTaskService(lab);

      AiTaskResult? result;
      await for (final _ in tasks.interpolateSequence(
        inputDir: seqIn.path,
        outputDir: outDir,
        params: const InterpolateParams(factor: 4, model: 'rife-v4.6'),
        onDone: (r) => result = r,
      )) {}

      expect(result, isNotNull);
      // (2 - 1) * 4 + 1 == 5
      final frames = Directory(outDir).listSync().whereType<File>();
      expect(frames.length, 5);
    });
  });
}

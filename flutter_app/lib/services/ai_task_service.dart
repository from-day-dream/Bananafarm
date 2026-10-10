import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/ai_model.dart';
import '../models/ai_task.dart';
import 'ai_lab_service.dart';
import 'app_paths.dart';

final aiTaskServiceProvider = Provider((ref) {
  return AiTaskService(ref.read(aiLabServiceProvider));
});

/// Runs the native AI tools and reports progress.
///
/// Progress is derived by **counting output files**, because that is the only
/// signal both tools give: Real-ESRGAN prints per-file percentages to stderr
/// (and resets them for each file in a batch), while RIFE prints nothing at
/// all beyond four GPU-info lines. The stderr percentage is layered on top for
/// single-image upscales, where file counting only ever reads 0 then 1.
class AiTaskService {
  final AiLabService _lab;

  AiTaskService(this._lab);

  Process? _active;
  bool _cancelled = false;

  bool get isRunning => _active != null;

  /// Scratch space for a task.
  ///
  /// Deliberately a sibling of `jobs/`, never inside it: the render manager's
  /// orphan sweeper deletes any directory under `jobsRoot` whose name is not a
  /// known job id, which would eat Lab scratch mid-run.
  static String taskDir(String taskId) =>
      p.join(AppPaths.tempRoot, 'lab', taskId);

  /// Cancel the running task. The child is killed; the caller's stream closes.
  Future<void> cancel() async {
    _cancelled = true;
    final proc = _active;
    if (proc != null) {
      proc.kill(ProcessSignal.sigterm);
      // SIGTERM is usually enough; escalate if the tool ignores it.
      unawaited(Future.delayed(const Duration(seconds: 3), () {
        try {
          proc.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }));
    }
  }

  // ============================================
  // Public entry points
  // ============================================

  /// Upscale images. [inputs] may be a single file or many.
  Stream<AiTaskProgress> upscale({
    required List<String> inputs,
    required String outputDir,
    required UpscaleParams params,
    required void Function(AiTaskResult) onDone,
  }) {
    return _run((emit) async {
      final tool = await _requireTool('realesrgan');
      final exe = await _lab.resolveExecutable(tool);
      final modelsDir = await _lab.resolveModelsDir(tool);

      final taskId = const Uuid().v4();
      final scratch = Directory(taskDir(taskId));
      await scratch.create(recursive: true);

      try {
        final outDir = Directory(outputDir);
        await outDir.create(recursive: true);

        // Real-ESRGAN takes a directory, so stage inputs into one. That also
        // keeps output naming predictable for a mixed selection.
        final stageIn = Directory(p.join(scratch.path, 'in'));
        await stageIn.create(recursive: true);
        for (final f in inputs) {
          await File(f).copy(p.join(stageIn.path, p.basename(f)));
        }

        final stageOut = Directory(p.join(scratch.path, 'out'));
        await stageOut.create(recursive: true);

        emit(AiTaskProgress(
          fraction: 0,
          totalFrames: inputs.length,
          statusMessage: 'Upscaling ${inputs.length} image(s)...',
        ));

        await _exec(
          exe!,
          [
            '-i', stageIn.path,
            '-o', stageOut.path,
            '-s', '${params.scale}',
            '-n', params.model,
            if (modelsDir != null) ...['-m', modelsDir],
          ],
          emit: emit,
          expectedOutputs: inputs.length,
          watchDir: stageOut,
          label: 'Upscaling',
          // Real-ESRGAN's percentage is per-file, so it only stands in for
          // real progress when there is exactly one file.
          useStderrPercent: inputs.length == 1,
        );

        final produced = await _moveAll(stageOut, outDir);
        onDone(AiTaskResult(outputPath: outDir.path, fileCount: produced));
      } finally {
        await _cleanup(scratch, taskId);
      }
    });
  }

  /// Interpolate a numbered image sequence.
  Stream<AiTaskProgress> interpolateSequence({
    required String inputDir,
    required String outputDir,
    required InterpolateParams params,
    required void Function(AiTaskResult) onDone,
  }) {
    return _run((emit) async {
      final tool = await _requireTool('rife');
      final exe = await _lab.resolveExecutable(tool);
      final modelsRoot = await _lab.resolveModelsDir(tool);

      final frames = await _sortedImages(Directory(inputDir));
      if (frames.length < 2) {
        throw AiTaskException('Need at least 2 frames to interpolate');
      }

      final target = (frames.length - 1) * params.factor + 1;
      final outDir = Directory(outputDir);
      await outDir.create(recursive: true);

      emit(AiTaskProgress(
        fraction: 0,
        totalFrames: target,
        statusMessage: 'Interpolating ${frames.length} → $target frames...',
      ));

      await _exec(
        exe!,
        [
          '-i', inputDir,
          '-o', outDir.path,
          '-n', '$target',
          if (modelsRoot != null) ...['-m', p.join(modelsRoot, params.model)],
        ],
        emit: emit,
        expectedOutputs: target,
        watchDir: outDir,
        label: 'Interpolating',
      );

      onDone(AiTaskResult(outputPath: outDir.path, fileCount: target));
    });
  }

  /// Interpolate a video: extract frames, interpolate, re-encode.
  Stream<AiTaskProgress> interpolateVideo({
    required String inputPath,
    required String outputDir,
    required InterpolateParams params,
    required void Function(AiTaskResult) onDone,
  }) {
    return _run((emit) async {
      final rifeTool = await _requireTool('rife');
      final ffTool = await _requireTool('ffmpeg');
      final rife = await _lab.resolveExecutable(rifeTool);
      final ffmpeg = await _lab.resolveExecutable(ffTool);
      final ffprobe = await _lab.resolveCompanion(ffTool, 'ffprobe');
      final modelsRoot = await _lab.resolveModelsDir(rifeTool);

      if (ffprobe == null) {
        throw AiTaskException('ffprobe is missing — reinstall FFmpeg');
      }

      final taskId = const Uuid().v4();
      final scratch = Directory(taskDir(taskId));
      await scratch.create(recursive: true);

      try {
        emit(const AiTaskProgress(statusMessage: 'Inspecting video...'));
        final srcFps = await _probeFps(ffprobe, inputPath);

        final framesIn = Directory(p.join(scratch.path, 'frames'));
        final framesOut = Directory(p.join(scratch.path, 'interp'));
        await framesIn.create(recursive: true);
        await framesOut.create(recursive: true);

        // 1. Extract. -vsync 0 keeps every frame as-is, no dup/drop.
        emit(const AiTaskProgress(statusMessage: 'Extracting frames...'));
        await _exec(
          ffmpeg!,
          ['-i', inputPath, '-vsync', '0',
           p.join(framesIn.path, '%08d.png')],
          emit: emit,
          watchDir: framesIn,
          label: 'Extracting',
        );

        final extracted = await _sortedImages(framesIn);
        if (extracted.length < 2) {
          throw AiTaskException('Video yielded fewer than 2 frames');
        }

        // 2. Interpolate.
        final target = (extracted.length - 1) * params.factor + 1;
        emit(AiTaskProgress(
          fraction: 0,
          totalFrames: target,
          statusMessage: 'Interpolating ${extracted.length} → $target frames...',
        ));
        await _exec(
          rife!,
          [
            '-i', framesIn.path,
            '-o', framesOut.path,
            '-n', '$target',
            if (modelsRoot != null) ...['-m', p.join(modelsRoot, params.model)],
          ],
          emit: emit,
          expectedOutputs: target,
          watchDir: framesOut,
          label: 'Interpolating',
        );

        // 3. Re-encode, carrying the original audio across unchanged.
        final outFps = params.targetFps ?? (srcFps * params.factor);
        final outName =
            '${p.basenameWithoutExtension(inputPath)}_${params.factor}x.mp4';
        final outPath = p.join(outputDir, outName);
        await Directory(outputDir).create(recursive: true);

        emit(AiTaskProgress(
          fraction: null,
          statusMessage: 'Encoding at ${outFps.toStringAsFixed(2)} fps...',
        ));
        await _exec(
          ffmpeg,
          [
            '-y',
            '-framerate', outFps.toStringAsFixed(5),
            '-i', p.join(framesOut.path, '%08d.png'),
            '-i', inputPath,
            '-map', '0:v:0',
            // Audio is optional: '?' makes the mapping non-fatal when the
            // source has no audio track.
            '-map', '1:a:0?',
            '-c:v', 'libx264',
            '-pix_fmt', 'yuv420p',
            '-crf', '17',
            '-c:a', 'copy',
            '-shortest',
            outPath,
          ],
          emit: emit,
          label: 'Encoding',
        );

        onDone(AiTaskResult(outputPath: outPath));
      } finally {
        await _cleanup(scratch, taskId);
      }
    });
  }

  // ============================================
  // Internals
  // ============================================

  /// Wraps a task body in a StreamController.
  ///
  /// A controller rather than `async*` because only a controller can expose
  /// `onCancel`, which is what lets the UI kill the child process.
  Stream<AiTaskProgress> _run(
    Future<void> Function(void Function(AiTaskProgress)) body,
  ) {
    late StreamController<AiTaskProgress> controller;
    controller = StreamController<AiTaskProgress>(
      onCancel: () => cancel(),
    );

    _cancelled = false;

    void emit(AiTaskProgress p) {
      if (!controller.isClosed) controller.add(p);
    }

    Future(() async {
      try {
        await body(emit);
        if (_cancelled) {
          controller.addError(AiTaskException('Cancelled'));
        }
      } catch (e) {
        if (!controller.isClosed) controller.addError(e);
      } finally {
        _active = null;
        if (!controller.isClosed) await controller.close();
      }
    });

    return controller.stream;
  }

  Future<AIModel> _requireTool(String id) async {
    final tools = await _lab.fetchAvailableModels();
    final tool = tools.where((t) => t.id == id).firstOrNull;
    if (tool == null) {
      throw AiTaskException('Unknown tool "$id"');
    }
    if (!await _lab.isToolInstalled(tool)) {
      throw AiTaskException('${tool.name} is not installed');
    }
    return tool;
  }

  /// Runs a binary, streaming stderr and polling the output directory.
  ///
  /// Both tools write everything to stderr and leave stdout empty, so stderr
  /// is where the log and any percentage come from.
  Future<void> _exec(
    String executable,
    List<String> args, {
    required void Function(AiTaskProgress) emit,
    Directory? watchDir,
    int? expectedOutputs,
    String label = 'Processing',
    bool useStderrPercent = false,
  }) async {
    if (_cancelled) throw AiTaskException('Cancelled');

    final proc = await Process.start(executable, args);
    _active = proc;

    final log = <String>[];
    double? stderrPercent;

    final percentRe = RegExp(r'(\d+(?:\.\d+)?)%');

    final stderrDone = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) return;
      log.add(trimmed);
      if (log.length > 200) log.removeAt(0);

      if (useStderrPercent) {
        final m = percentRe.firstMatch(trimmed);
        if (m != null) {
          stderrPercent = double.tryParse(m.group(1)!)?.clamp(0, 100);
        }
      }
    });

    // stdout is always empty for these tools, but drain it so the pipe can
    // never fill and deadlock the child.
    final stdoutDone = proc.stdout.drain<void>();

    Timer? poller;
    if (watchDir != null) {
      poller = Timer.periodic(const Duration(milliseconds: 400), (_) async {
        try {
          final count = await _countFiles(watchDir);
          if (expectedOutputs != null && expectedOutputs > 0) {
            emit(AiTaskProgress(
              fraction: (count / expectedOutputs).clamp(0.0, 1.0),
              currentFrame: count,
              totalFrames: expectedOutputs,
              statusMessage: '$label $count / $expectedOutputs...',
            ));
          } else if (stderrPercent != null) {
            emit(AiTaskProgress(
              fraction: stderrPercent! / 100,
              statusMessage:
                  '$label ${stderrPercent!.toStringAsFixed(0)}%...',
            ));
          } else {
            emit(AiTaskProgress(
              fraction: null,
              currentFrame: count,
              statusMessage:
                  count > 0 ? '$label $count frame(s)...' : '$label...',
            ));
          }
        } catch (_) {
          // Directory may vanish during cleanup; ignore.
        }
      });
    }

    final exitCode = await proc.exitCode;
    poller?.cancel();
    await stderrDone.cancel();
    await stdoutDone;
    _active = null;

    if (_cancelled) {
      throw AiTaskException('Cancelled');
    }
    if (exitCode != 0) {
      throw AiTaskException(
        '${p.basename(executable)} failed (exit $exitCode)',
        log: log.join('\n'),
      );
    }
  }

  Future<int> _countFiles(Directory dir) async {
    if (!await dir.exists()) return 0;
    var n = 0;
    await for (final e in dir.list()) {
      if (e is File && !p.basename(e.path).startsWith('.')) n++;
    }
    return n;
  }

  Future<List<File>> _sortedImages(Directory dir) async {
    final files = <File>[];
    await for (final e in dir.list()) {
      if (e is File && isImageFile(e.path)) files.add(e);
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// Reads the average frame rate via ffprobe.
  Future<double> _probeFps(String ffprobe, String inputPath) async {
    final r = await Process.run(ffprobe, [
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_entries', 'stream=avg_frame_rate',
      '-of', 'default=nw=1:nk=1',
      inputPath,
    ]);
    if (r.exitCode != 0) {
      throw AiTaskException('Could not read video: ${r.stderr}');
    }
    // ffprobe reports a rational like "24000/1001".
    final raw = '${r.stdout}'.trim();
    final parts = raw.split('/');
    if (parts.length == 2) {
      final num = double.tryParse(parts[0]) ?? 0;
      final den = double.tryParse(parts[1]) ?? 0;
      if (den > 0 && num > 0) return num / den;
    }
    final direct = double.tryParse(raw);
    if (direct != null && direct > 0) return direct;
    throw AiTaskException('Could not determine frame rate (got "$raw")');
  }

  /// Moves results into the destination without clobbering existing files.
  Future<int> _moveAll(Directory from, Directory to) async {
    var moved = 0;
    await for (final e in from.list()) {
      if (e is! File) continue;
      final dest = _uniquePath(to.path, p.basename(e.path));
      await e.rename(dest);
      moved++;
    }
    return moved;
  }

  String _uniquePath(String dir, String fileName) {
    var candidate = p.join(dir, fileName);
    var counter = 1;
    final stem = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    while (File(candidate).existsSync()) {
      candidate = p.join(dir, '${stem}_$counter$ext');
      counter++;
    }
    return candidate;
  }

  /// Removes a task's scratch dir, guarded the way the render manager guards
  /// its own: only ever delete a folder named after the task it belongs to.
  Future<void> _cleanup(Directory scratch, String taskId) async {
    try {
      if (p.basename(scratch.path) != taskId) return;
      if (await scratch.exists()) await scratch.delete(recursive: true);
    } catch (e) {
      print('Could not clean Lab scratch dir: $e');
    }
  }
}

// PARKED — this tab is not mounted anywhere.
//
// The Lab (image upscaling and sequence/video interpolation via Real-ESRGAN
// and RIFE) was removed from the app's navigation, but the implementation is
// kept intact for a later release. `MainLayoutScreen` no longer imports this
// file, so nothing reaches it from `main()` and it is tree-shaken out of
// release builds — it costs nothing to keep here.
//
// It is still analysed, which is deliberate: if `AILabService` or
// `AITaskService` changes shape, this file breaks loudly instead of quietly
// rotting. `test/ai_lab_integration_test.dart` still exercises those services.
//
// To bring it back, see the note above the tab row in
// `lib/screens/main_layout_screen.dart`.

import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../models/ai_model.dart';
import '../../models/ai_task.dart';
import '../../providers/settings_provider.dart';
import '../../services/ai_lab_service.dart';
import '../../services/ai_task_service.dart';
import '../../services/notification_service.dart';
import '../../theme/app_theme.dart';

// ###########################################################################
//                               STATE
// ###########################################################################

/// Install state for one tool.
class ToolStatus {
  final AIModel tool;
  final bool installed;
  final int installedBytes;
  final double? installProgress;
  final String? installMessage;

  const ToolStatus({
    required this.tool,
    this.installed = false,
    this.installedBytes = 0,
    this.installProgress,
    this.installMessage,
  });

  bool get isInstalling => installProgress != null;

  ToolStatus copyWith({
    bool? installed,
    int? installedBytes,
    double? installProgress,
    String? installMessage,
    bool clearInstall = false,
  }) {
    return ToolStatus(
      tool: tool,
      installed: installed ?? this.installed,
      installedBytes: installedBytes ?? this.installedBytes,
      installProgress: clearInstall ? null : (installProgress ?? this.installProgress),
      installMessage: clearInstall ? null : (installMessage ?? this.installMessage),
    );
  }
}

class LabTabState {
  final bool loading;
  final List<ToolStatus> tools;

  /// Selected input files (images or a single video).
  final List<String> inputs;

  final AiTaskKind kind;
  final UpscaleParams upscale;
  final InterpolateParams interpolate;

  /// Non-null while a task runs.
  final AiTaskProgress? progress;

  final String? errorMessage;
  final String? lastOutputPath;

  const LabTabState({
    this.loading = true,
    this.tools = const [],
    this.inputs = const [],
    this.kind = AiTaskKind.upscale,
    this.upscale = const UpscaleParams(),
    this.interpolate = const InterpolateParams(),
    this.progress,
    this.errorMessage,
    this.lastOutputPath,
  });

  bool get isRunning => progress != null;

  ToolStatus? toolById(String id) =>
      tools.where((t) => t.tool.id == id).firstOrNull;

  bool get canUpscale => toolById('realesrgan')?.installed ?? false;
  bool get canInterpolate => toolById('rife')?.installed ?? false;
  bool get hasFfmpeg => toolById('ffmpeg')?.installed ?? false;

  /// Every tool needed for the *currently selected* mode.
  bool get toolsReadyForKind {
    switch (kind) {
      case AiTaskKind.upscale:
        return canUpscale;
      case AiTaskKind.interpolateSequence:
        return canInterpolate;
      case AiTaskKind.interpolateVideo:
        return canInterpolate && hasFfmpeg;
    }
  }

  /// Explicit clear flags: without them a copyWith that omits a nullable
  /// field either wipes it or makes it unclearable. The old implementation
  /// did both, in different fields.
  LabTabState copyWith({
    bool? loading,
    List<ToolStatus>? tools,
    List<String>? inputs,
    AiTaskKind? kind,
    UpscaleParams? upscale,
    InterpolateParams? interpolate,
    AiTaskProgress? progress,
    String? errorMessage,
    String? lastOutputPath,
    bool clearProgress = false,
    bool clearError = false,
    bool clearOutput = false,
  }) {
    return LabTabState(
      loading: loading ?? this.loading,
      tools: tools ?? this.tools,
      inputs: inputs ?? this.inputs,
      kind: kind ?? this.kind,
      upscale: upscale ?? this.upscale,
      interpolate: interpolate ?? this.interpolate,
      progress: clearProgress ? null : (progress ?? this.progress),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      lastOutputPath:
          clearOutput ? null : (lastOutputPath ?? this.lastOutputPath),
    );
  }
}

// ###########################################################################
//                             CONTROLLER
// ###########################################################################

class LabTabController extends StateNotifier<LabTabState> {
  final AiLabService _lab;
  final AiTaskService _tasks;
  final Ref _ref;

  StreamSubscription? _installSub;
  StreamSubscription<AiTaskProgress>? _taskSub;

  LabTabController(this._lab, this._tasks, this._ref)
      : super(const LabTabState()) {
    refreshTools();
  }

  @override
  void dispose() {
    _installSub?.cancel();
    _taskSub?.cancel();
    _tasks.cancel();
    super.dispose();
  }

  Future<void> refreshTools() async {
    try {
      final catalog = await _lab.fetchAvailableModels();
      final statuses = await Future.wait(catalog.map((t) async {
        final installed = await _lab.isToolInstalled(t);
        return ToolStatus(
          tool: t,
          installed: installed,
          installedBytes: installed ? await _lab.installedSize(t) : 0,
        );
      }));
      if (!mounted) return;
      state = state.copyWith(tools: statuses, loading: false, clearError: true);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(loading: false, errorMessage: e.toString());
    }
  }

  void _updateTool(String id, ToolStatus Function(ToolStatus) fn) {
    state = state.copyWith(
      tools: state.tools.map((t) => t.tool.id == id ? fn(t) : t).toList(),
    );
  }

  Future<void> installTool(AIModel tool) async {
    await _installSub?.cancel();
    _updateTool(tool.id,
        (t) => t.copyWith(installProgress: 0, installMessage: 'Starting...'));

    final completer = Completer<void>();
    _installSub = _lab.installTool(tool).listen(
      (p) {
        if (!mounted) return;
        _updateTool(
          tool.id,
          (t) => t.copyWith(
            installProgress: p.fraction,
            installMessage: p.message,
          ),
        );
      },
      onError: (e) {
        if (mounted) {
          _updateTool(tool.id, (t) => t.copyWith(clearInstall: true));
          state = state.copyWith(errorMessage: '$e');
        }
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
    );

    await completer.future;
    if (!mounted) return;
    _updateTool(tool.id, (t) => t.copyWith(clearInstall: true));
    await refreshTools();
  }

  Future<void> uninstallTool(AIModel tool) async {
    await _lab.uninstallTool(tool);
    await refreshTools();
  }

  // ---- input selection -------------------------------------------------

  void setKind(AiTaskKind kind) =>
      state = state.copyWith(kind: kind, clearError: true);

  void setUpscale(UpscaleParams v) => state = state.copyWith(upscale: v);
  void setInterpolate(InterpolateParams v) =>
      state = state.copyWith(interpolate: v);

  void clearInputs() => state = state.copyWith(inputs: const []);

  /// Accepts dropped or picked paths, filtering to supported media and
  /// inferring the task kind from what arrived.
  void addInputs(List<String> paths) {
    final accepted = <String>[];
    for (final path in paths) {
      if (FileSystemEntity.isDirectorySync(path)) {
        // A dropped folder is treated as an image sequence.
        final imgs = Directory(path)
            .listSync()
            .whereType<File>()
            .map((f) => f.path)
            .where(isImageFile)
            .toList()
          ..sort();
        accepted.addAll(imgs);
      } else if (isImageFile(path) || isVideoFile(path)) {
        accepted.add(path);
      }
    }

    if (accepted.isEmpty) {
      state = state.copyWith(
          errorMessage: 'No supported image or video files in that selection');
      return;
    }

    final video = accepted.where(isVideoFile).toList();
    AiTaskKind kind = state.kind;
    if (video.isNotEmpty) {
      kind = AiTaskKind.interpolateVideo;
      accepted
        ..clear()
        ..add(video.first); // one video at a time
    } else if (accepted.length > 1 && kind == AiTaskKind.interpolateVideo) {
      kind = AiTaskKind.interpolateSequence;
    }

    state = state.copyWith(inputs: accepted, kind: kind, clearError: true);
  }

  Future<void> pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      dialogTitle: 'Select images or a video',
      type: FileType.custom,
      allowedExtensions: [
        ...kImageExtensions.map((e) => e.substring(1)),
        ...kVideoExtensions.map((e) => e.substring(1)),
      ],
    );
    if (result == null) return;
    addInputs(result.paths.whereType<String>().toList());
  }

  // ---- running ---------------------------------------------------------

  Future<String> _outputDir() async {
    final settings = _ref.read(settingsProvider);
    final base = settings.labOutputPath ?? settings.downloadPath;
    if (base == null || base.isEmpty) {
      throw AiTaskException(
          'Set an output folder in Settings before running a Lab job');
    }
    final dir = Directory(p.join(base, 'lab-output'));
    await dir.create(recursive: true);
    return dir.path;
  }

  Future<void> run() async {
    if (state.inputs.isEmpty || state.isRunning) return;

    state = state.copyWith(
      clearError: true,
      clearOutput: true,
      progress: const AiTaskProgress(statusMessage: 'Starting...'),
    );

    try {
      final outDir = await _outputDir();
      AiTaskResult? result;

      Stream<AiTaskProgress> stream;
      switch (state.kind) {
        case AiTaskKind.upscale:
          stream = _tasks.upscale(
            inputs: state.inputs,
            outputDir: outDir,
            params: state.upscale,
            onDone: (r) => result = r,
          );
          break;
        case AiTaskKind.interpolateSequence:
          stream = _tasks.interpolateSequence(
            inputDir: p.dirname(state.inputs.first),
            outputDir: p.join(outDir, 'interpolated'),
            params: state.interpolate,
            onDone: (r) => result = r,
          );
          break;
        case AiTaskKind.interpolateVideo:
          stream = _tasks.interpolateVideo(
            inputPath: state.inputs.first,
            outputDir: outDir,
            params: state.interpolate,
            onDone: (r) => result = r,
          );
          break;
      }

      final completer = Completer<void>();
      _taskSub = stream.listen(
        (p) {
          if (mounted) state = state.copyWith(progress: p);
        },
        onError: (e) {
          if (mounted) {
            state = state.copyWith(
              clearProgress: true,
              errorMessage: e is AiTaskException ? e.message : '$e',
            );
          }
          if (!completer.isCompleted) completer.complete();
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
      );

      await completer.future;
      if (!mounted) return;

      if (result != null) {
        state = state.copyWith(
          clearProgress: true,
          lastOutputPath: result!.outputPath,
        );
        _notify('${state.kind.label} complete',
            'Saved to ${p.basename(result!.outputPath)}');
      } else {
        state = state.copyWith(clearProgress: true);
      }
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        clearProgress: true,
        errorMessage: e is AiTaskException ? e.message : '$e',
      );
    }
  }

  Future<void> cancel() async {
    await _tasks.cancel();
    await _taskSub?.cancel();
    _taskSub = null;
    if (mounted) {
      state = state.copyWith(clearProgress: true);
    }
  }

  void _notify(String title, String body) {
    try {
      if (_ref.read(settingsProvider).showNotifications) {
        NotificationService().show(title: title, body: body);
      }
    } catch (e) {
      print('⚠️ Notification failed: $e');
    }
  }
}

final labTabProvider =
    StateNotifierProvider<LabTabController, LabTabState>((ref) {
  return LabTabController(
    ref.watch(aiLabServiceProvider),
    ref.watch(aiTaskServiceProvider),
    ref,
  );
});

// ###########################################################################
//                                  UI
// ###########################################################################

String _fmtBytes(int bytes) {
  if (bytes >= 1073741824) {
    return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
  }
  return '${(bytes / 1048576).toStringAsFixed(0)} MB';
}

class LabTab extends ConsumerStatefulWidget {
  const LabTab({super.key});

  @override
  ConsumerState<LabTab> createState() => _LabTabState();
}

class _LabTabState extends ConsumerState<LabTab> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(labTabProvider);

    if (state.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) {
        setState(() => _dragging = false);
        ref
            .read(labTabProvider.notifier)
            .addInputs(detail.files.map((f) => f.path).toList());
      },
      child: Container(
        color: _dragging ? AppTheme.primary.withOpacity(0.06) : null,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Lab',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                'Upscale images and interpolate frames locally on your GPU.',
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
              const SizedBox(height: 20),

              if (state.errorMessage != null) ...[
                _ErrorBanner(message: state.errorMessage!),
                const SizedBox(height: 16),
              ],

              _ToolsSection(state: state),
              const SizedBox(height: 24),

              _ModeSelector(state: state),
              const SizedBox(height: 16),

              _InputSection(state: state, dragging: _dragging),
              const SizedBox(height: 16),

              _ParamsSection(state: state),
              const SizedBox(height: 20),

              _RunSection(state: state),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
      ),
      child: child,
    );
  }
}

class _ToolsSection extends ConsumerWidget {
  final LabTabState state;
  const _ToolsSection({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.extension_outlined, size: 18),
              const SizedBox(width: 8),
              const Text('Components',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Re-check installs',
                onPressed: () =>
                    ref.read(labTabProvider.notifier).refreshTools(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final t in state.tools) _ToolRow(status: t),
        ],
      ),
    );
  }
}

class _ToolRow extends ConsumerWidget {
  final ToolStatus status;
  const _ToolRow({required this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tool = status.tool;
    final notifier = ref.read(labTabProvider.notifier);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            status.installed ? Icons.check_circle : Icons.circle_outlined,
            size: 18,
            color: status.installed ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tool.name,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  status.isInstalling
                      ? (status.installMessage ?? '')
                      : status.installed
                          ? '${tool.description ?? ''}  •  ${_fmtBytes(status.installedBytes)} on disk'
                          : '${tool.description ?? ''}  •  ${_fmtBytes(tool.downloadBytes)} download',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
                if (status.isInstalling) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: status.installProgress),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (!status.isInstalling)
            status.installed
                ? TextButton(
                    onPressed: () => notifier.uninstallTool(tool),
                    child: const Text('Remove'),
                  )
                : ElevatedButton(
                    onPressed: () => notifier.installTool(tool),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Install'),
                  ),
        ],
      ),
    );
  }
}

class _ModeSelector extends ConsumerWidget {
  final LabTabState state;
  const _ModeSelector({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(labTabProvider.notifier);
    return Wrap(
      spacing: 8,
      children: AiTaskKind.values.map((k) {
        final selected = state.kind == k;
        return ChoiceChip(
          label: Text(k.label),
          selected: selected,
          onSelected: state.isRunning ? null : (_) => notifier.setKind(k),
        );
      }).toList(),
    );
  }
}

class _InputSection extends ConsumerWidget {
  final LabTabState state;
  final bool dragging;
  const _InputSection({required this.state, required this.dragging});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(labTabProvider.notifier);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.folder_open, size: 18),
              const SizedBox(width: 8),
              const Text('Input', style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              if (state.inputs.isNotEmpty)
                TextButton(
                  onPressed: state.isRunning ? null : notifier.clearInputs,
                  child: const Text('Clear'),
                ),
              TextButton.icon(
                onPressed: state.isRunning ? null : notifier.pickFiles,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Choose files'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (state.inputs.isEmpty)
            Text(
              dragging
                  ? 'Drop to add'
                  : 'Drag images, a folder of frames, or a video here.',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            )
          else
            Text(
              state.inputs.length == 1
                  ? p.basename(state.inputs.first)
                  : '${state.inputs.length} files selected '
                      '(${p.basename(p.dirname(state.inputs.first))})',
              style: const TextStyle(fontSize: 12),
            ),
        ],
      ),
    );
  }
}

class _ParamsSection extends ConsumerWidget {
  final LabTabState state;
  const _ParamsSection({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(labTabProvider.notifier);
    final enabled = !state.isRunning;

    if (state.kind == AiTaskKind.upscale) {
      final tool = state.toolById('realesrgan')?.tool;
      return _Card(
        child: Row(
          children: [
            const Text('Scale'),
            const SizedBox(width: 12),
            DropdownButton<int>(
              value: state.upscale.scale,
              onChanged: enabled
                  ? (v) => notifier.setUpscale(UpscaleParams(
                      scale: v ?? 4, model: state.upscale.model))
                  : null,
              items: const [2, 3, 4]
                  .map((s) =>
                      DropdownMenuItem(value: s, child: Text('${s}x')))
                  .toList(),
            ),
            const SizedBox(width: 24),
            const Text('Model'),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButton<String>(
                isExpanded: true,
                value: state.upscale.model,
                onChanged: enabled
                    ? (v) => notifier.setUpscale(UpscaleParams(
                        scale: state.upscale.scale,
                        model: v ?? state.upscale.model))
                    : null,
                items: (tool?.models ?? const ['realesrgan-x4plus'])
                    .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                    .toList(),
              ),
            ),
          ],
        ),
      );
    }

    final tool = state.toolById('rife')?.tool;
    return _Card(
      child: Row(
        children: [
          const Text('Factor'),
          const SizedBox(width: 12),
          DropdownButton<int>(
            value: state.interpolate.factor,
            onChanged: enabled
                ? (v) => notifier.setInterpolate(InterpolateParams(
                    factor: v ?? 2, model: state.interpolate.model))
                : null,
            items: const [2, 4]
                .map((f) => DropdownMenuItem(value: f, child: Text('${f}x')))
                .toList(),
          ),
          const SizedBox(width: 24),
          const Text('Model'),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              value: state.interpolate.model,
              onChanged: enabled
                  ? (v) => notifier.setInterpolate(InterpolateParams(
                      factor: state.interpolate.factor,
                      model: v ?? state.interpolate.model))
                  : null,
              items: (tool?.models ?? const ['rife-v4.6'])
                  .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _RunSection extends ConsumerWidget {
  final LabTabState state;
  const _RunSection({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(labTabProvider.notifier);

    if (state.isRunning) {
      final prog = state.progress!;
      return _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: prog.fraction),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: Text(prog.statusMessage)),
                OutlinedButton(
                  onPressed: notifier.cancel,
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final missing = !state.toolsReadyForKind;
    final noInput = state.inputs.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (missing)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              state.kind == AiTaskKind.interpolateVideo
                  ? 'Install RIFE and FFmpeg to interpolate video.'
                  : 'Install the required component above to use this mode.',
              style: TextStyle(color: Colors.orange[700], fontSize: 12),
            ),
          ),
        Row(
          children: [
            ElevatedButton.icon(
              onPressed: (missing || noInput) ? null : notifier.run,
              icon: const Icon(Icons.play_arrow),
              label: Text('Run ${state.kind.label}'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              ),
            ),
            if (state.lastOutputPath != null) ...[
              const SizedBox(width: 16),
              Flexible(
                child: Text(
                  'Saved to ${state.lastOutputPath}',
                  style: TextStyle(fontSize: 12, color: Colors.green[700]),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

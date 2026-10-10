import 'package:flutter_riverpod/flutter_riverpod.dart' as rp;
import 'package:uuid/uuid.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../services/addon_service.dart';
import '../services/app_paths.dart';
import '../services/render_job_manager.dart';
import '../models/draft_job_model.dart';
import '../providers/draft_job_provider.dart';
import '../constants/app_constants.dart';

/// Single instance of addon service
final addonServiceProvider = rp.Provider<AddonService>((ref) {
  return AddonService();
});

/// Connection status of Blender addon
final addonConnectionStatusProvider =
    rp.StateNotifierProvider<AddonConnectionNotifier, AddonConnectionState>((
      ref,
    ) {
      final addonService = ref.watch(addonServiceProvider);
      return AddonConnectionNotifier(addonService, ref);
    });

/// Received jobs from Blender addon
final receivedAddonJobsProvider =
    rp.StateNotifierProvider<ReceivedJobsNotifier, List<Map<String, dynamic>>>((
      ref,
    ) {
      return ReceivedJobsNotifier();
    });

/// Blender version as reported by the addon, falling back when it is absent
/// *or* blank. Both cases mean "the addon told us nothing usable".
String _orDefaultBlenderVersion(String? reported) {
  final v = reported?.trim() ?? '';
  return v.isEmpty ? AppConstants.defaultBlenderVersion : v;
}

class AddonConnectionState {
  final bool isServerRunning;
  final bool isConnected; // Only true when addon actually sends a job
  final int port;
  final String? lastError;
  final DateTime? lastJobReceivedAt;

  AddonConnectionState({
    required this.isServerRunning,
    required this.isConnected,
    required this.port,
    this.lastError,
    this.lastJobReceivedAt,
  });

  AddonConnectionState copyWith({
    bool? isServerRunning,
    bool? isConnected,
    int? port,
    String? lastError,
    DateTime? lastJobReceivedAt,
  }) {
    return AddonConnectionState(
      isServerRunning: isServerRunning ?? this.isServerRunning,
      isConnected: isConnected ?? this.isConnected,
      port: port ?? this.port,
      lastError: lastError ?? this.lastError,
      lastJobReceivedAt: lastJobReceivedAt ?? this.lastJobReceivedAt,
    );
  }
}

class ReceivedJobsNotifier
    extends rp.StateNotifier<List<Map<String, dynamic>>> {
  ReceivedJobsNotifier() : super([]);

  void addJob(Map<String, dynamic> jobData) {
    state = [...state, jobData];
  }

  void removeJob(int index) {
    if (index >= 0 && index < state.length) {
      state = [...state..removeAt(index)];
    }
  }

  void clearJobs() {
    state = [];
  }
}

class AddonConnectionNotifier extends rp.StateNotifier<AddonConnectionState> {
  final AddonService _addonService;
  final rp.Ref _ref;

  AddonConnectionNotifier(this._addonService, this._ref)
    : super(
        AddonConnectionState(
          isServerRunning: false,
          isConnected: false,
          port: 47288,
          lastError: null,
          lastJobReceivedAt: null,
        ),
      ) {
    _initializeServer();
  }

  Future<void> _initializeServer() async {
    try {
      final success = await _addonService.startServer(
        port: state.port,
        onJobReceived: _handleJobReceived,
      );

      state = state.copyWith(
        isServerRunning: success,
        lastError: success ? null : 'Failed to start server',
      );
    } catch (e) {
      state = state.copyWith(isServerRunning: false, lastError: e.toString());
    }
  }

  Future<void> setPort(int newPort) async {
    await _addonService.stopServer();
    _addonService.setPort(newPort);
    state = state.copyWith(port: newPort, isConnected: false);
    await _initializeServer();
  }

  void _handleJobReceived(Map<String, dynamic> jobData) {
    print('Job received from Blender addon: $jobData');

    // Update connection status - addon is now connected
    state = state.copyWith(
      isConnected: true,
      lastJobReceivedAt: DateTime.now(),
      lastError: null,
    );

    // Add to received jobs list
    _ref.read(receivedAddonJobsProvider.notifier).addJob(jobData);

    // Create a local draft job (asynchronously)
    Future.microtask(() => _createJobFromAddonData(jobData));
  }

  /// Create a draft job from addon data
  /// This creates a DraftJob that awaits GPU selection before submission
  Future<void> _createJobFromAddonData(Map<String, dynamic> jobData) async {
    try {
      final renderParams = jobData['render_params'] as Map<String, dynamic>?;
      if (renderParams == null) {
        print('✗ Missing render_params in job data');
        state = state.copyWith(lastError: 'Missing render parameters');
        return;
      }

      // Generate ID first to use for folder name
      final draftJobId = const Uuid().v4();

      // Calculate persistent paths
      final jobDir = Directory(AppPaths.jobDir(draftJobId));
      if (!await jobDir.exists()) {
        await jobDir.create(recursive: true);
      }

      // Extract blend file path (which is now a directory path from addon)
      final blendFilePath = jobData['blend_file_path'] as String?;
      final originalFilename =
          renderParams['original_filename'] as String? ?? 'project';

      if (blendFilePath == null || blendFilePath.isEmpty) {
        print('✗ No blend file path provided');
        state = state.copyWith(lastError: 'Missing blend file path');
        return;
      }

      final sourceDir = Directory(blendFilePath);
      if (!await sourceDir.exists()) {
        print('Source directory not found: $blendFilePath');
        state = state.copyWith(
          lastError: 'Source directory not found: $blendFilePath',
        );
        return;
      }

      // Determin output zip filename
      var destFilename = originalFilename;
      if (!destFilename.toLowerCase().endsWith('.zip')) {
        destFilename = '${p.basenameWithoutExtension(destFilename)}.zip';
      }

      final persistentZipPath = p.join(jobDir.path, destFilename);

      // Create a draft job via the provider using the persistent path AND the generated ID
      // Initial status is zipping
      await _ref
          .read(draftJobsProvider.notifier)
          .createDraftJob(
            id: draftJobId,
            blendFilePath: persistentZipPath,
            originalFilename: originalFilename,
            renderParams: renderParams,
            // `??` alone would let an empty string through, which then
            // disagrees downstream: the container's bash guard rewrites it to
            // a default but its Python does not, so the two would report
            // different versions for the same job.
            blenderVersion: _orDefaultBlenderVersion(
                renderParams['blender_version'] as String?),
            status: DraftJobStatus.zipping,
          );

      print('📦 Zipping folder');
      print('   Source: ${sourceDir.path}');
      print('   Dest: $persistentZipPath');

      try {
        await _createProjectZip(sourceDir.path, persistentZipPath);

        // The zip is store-only, so the addon's folder is now a byte-for-byte
        // duplicate. Drop it rather than carry 2x the project on disk.
        await _deleteAddonSourceDir(sourceDir);

        // Update status to submitted (ready for user action)
        await _ref
            .read(draftJobsProvider.notifier)
            .updateStatus(draftJobId, DraftJobStatus.submitted);
      } catch (e) {
        print('❌ Failed to zip project: $e');
        state = state.copyWith(lastError: 'Failed to zip project: $e');

        // Nothing usable was produced — leave no temp data behind.
        await _deleteAddonSourceDir(sourceDir);
        try {
          if (await jobDir.exists()) await jobDir.delete(recursive: true);
        } catch (cleanupError) {
          print('⚠️ Failed to remove job folder: $cleanupError');
        }

        // Update job with error
        await _ref
            .read(draftJobsProvider.notifier)
            .setErrorMessage(draftJobId, 'Failed to zip project: $e');
        return;
      }

      print('✅ Draft job created: $originalFilename');
      print('   Job ID: $draftJobId');
      print('   Blend file: $persistentZipPath');
      print('   Engine: ${renderParams['engine']}');
      print(
        '   Frames: ${renderParams['frame_start']}-${renderParams['frame_end']}',
      );
      print('   Awaiting GPU selection...');

      state = state.copyWith(lastError: null);
    } catch (e) {
      print('❌ Error creating draft job from addon: $e');
      state = state.copyWith(
        lastError: 'Failed to process job: ${e.toString()}',
      );
    }
  }

  /// Remove the folder the addon packed into.
  ///
  /// Guarded on it actually living under the incoming root, so a malformed
  /// `blend_file_path` from the addon can never delete an arbitrary directory.
  Future<void> _deleteAddonSourceDir(Directory sourceDir) async {
    try {
      if (!p.isWithin(AppPaths.incomingRoot, sourceDir.path)) {
        print('⚠️ Refusing to delete ${sourceDir.path} — outside temp root');
        return;
      }
      if (await sourceDir.exists()) {
        await sourceDir.delete(recursive: true);
        print('🧹 Removed addon source folder: ${sourceDir.path}');
      }
    } catch (e) {
      print('⚠️ Failed to remove addon source folder: $e');
    }
  }

  /// Helper to create the project zip using bundled 7-Zip.
  ///
  /// Deliberately unencrypted: the project is only ever sent over TLS to the
  /// job's own container, which authenticates every request with a 256-bit
  /// bearer token. The old 4-digit ZipCrypto "lock key" protected nothing —
  /// it was handed to the GPU provider in plaintext as a container env var —
  /// while adding a whole class of extraction failures.
  Future<void> _createProjectZip(String sourcePath, String zipPath) async {
    String executable = "";

    // Select executable based on OS
    // Expects binaries to be at assets/bin/{os}/7za(.exe) relative to app execution
    // In Flutter desktop debug, this is often relative to the executable or project root depending on run config.
    // We might need to resolve absolute path if assets are packaged.
    // For now, assuming standard asset location relative to CWD or bundled in build.

    if (Platform.isWindows) {
      // For Windows, look relative to the executable
      final exeDir = File(Platform.resolvedExecutable).parent;
      final List<String> potentialPaths = [
        // 1. Packaged Flutter Windows build (data/flutter_assets/...)
        p.join(
          exeDir.path,
          'data',
          'flutter_assets',
          'assets',
          'bin',
          'win',
          '7za.exe',
        ),
        // 2. Debug/Dev mode (often assets are copied to build dir or relative to CWD)
        p.join(exeDir.path, 'assets', 'bin', 'win', '7za.exe'),
        // 3. Simple relative path fallback (CWD-based)
        "data/flutter_assets/assets/bin/win/7za.exe",
        "assets/bin/win/7za.exe",
      ];

      for (final path in potentialPaths) {
        if (await File(path).exists()) {
          executable = path;
          break;
        }
      }

      if (executable.isEmpty) {
        print(
          '⚠️ Could not locate 7za.exe in potential paths, attempting default fallback',
        );
        executable = "data/flutter_assets/assets/bin/win/7za.exe";
      }
    } else {
      // For macOS and Linux, we need to find the bundled asset relative to the executable
      final exeDir = File(Platform.resolvedExecutable).parent;
      final isMac = Platform.isMacOS;

      final List<String> potentialPaths = [
        // 1. Standard Flutter macOS bundle structure
        // Contents/Frameworks/App.framework/Resources/flutter_assets/assets/bin/mac/7zz
        if (isMac)
          p.join(
            exeDir.path,
            '..',
            'Frameworks',
            'App.framework',
            'Resources',
            'flutter_assets',
            'assets',
            'bin',
            'mac',
            '7zz',
          ),

        // 2. Alternative/Older structure or simple bundle
        // Contents/Resources/flutter_assets/assets/bin/mac/7zz
        p.join(
          exeDir.path,
          '..',
          'Resources',
          'flutter_assets',
          'assets',
          'bin',
          isMac ? 'mac' : 'lin',
          '7zz',
        ),

        // 3. Flat structure (Linux often, or some dev builds)
        p.join(
          exeDir.path,
          'data',
          'flutter_assets',
          'assets',
          'bin',
          isMac ? 'mac' : 'lin',
          '7zz',
        ),

        // 4. Dev/Local fallback (relative to CWD)
        "assets/bin/${isMac ? 'mac' : 'lin'}/7zz",
      ];

      bool found = false;
      for (final path in potentialPaths) {
        // Normalize path to resolve '..'
        final normalizedPath = p.normalize(path);

        // Check if file exists (works for absolute paths and relative to CWD)
        if (await File(normalizedPath).exists()) {
          executable = normalizedPath;
          found = true;
          print('   Found 7-Zip at: $executable');

          // Ensure it is executable
          try {
            await Process.run('chmod', ['+x', executable]);
          } catch (e) {
            print('   Warning: Failed to chmod +x $executable: $e');
          }
          break;
        }
      }

      if (!found) {
        print(
          '⚠️ Could not locate 7zz in bundle, falling back to default relative path',
        );
        executable = "assets/bin/${isMac ? 'mac' : 'lin'}/7zz";
      }
    }

    // Ensure executable exists (or at least try to find it if we are in dev mode)
    // In production builds, assets are bundled differently, but for raw executable spawning
    // they need to be copied to an accessible location or referenced correctly.
    // Using simple relative path as requested by user.

    print('   Using 7-Zip: $executable');

    final result = await Process.run(
      executable,
      [
        'a', // Add to archive
        '-tzip', // Force ZIP format
        '-bso0', // Disable standard output (supresses file listing)
        '-bsp0', // Disable progress output
        '-mx0', // Store only (faster) or default
        zipPath,
        '*', // Add everything in CWD
      ],
      workingDirectory:
          sourcePath, // Run INSIDE the source folder to zip contents, not the folder itself
    );

    if (result.exitCode != 0) {
      throw Exception('7-Zip failed: ${result.stderr}');
    }

    print("   Zip created successfully!");
  }

  /// Submit a draft job for rendering after GPU selection.
  ///
  /// Rents the GPU instance directly on the selected provider; from there
  /// the RenderJobManager drives the rest of the lifecycle in the background
  /// (boot, project upload, render progress, completion).
  Future<void> submitDraftJob(
    String draftJobId, {
    Function(String)? onStatusChange,
  }) async {
    try {
      final draftJob = _ref
          .read(draftJobsProvider.notifier)
          .getDraftJob(draftJobId);
      if (draftJob == null) {
        throw Exception('Draft job not found: $draftJobId');
      }

      if (draftJob.selectedGpu == null) {
        throw Exception('GPU not selected for job: $draftJobId');
      }

      print('🚀 Submitting job with GPU: ${draftJob.selectedGpu!.displayName}');
      onStatusChange?.call('Creating GPU instance...');

      final job = await _ref.read(renderJobManagerProvider).submitJob(draftJob);

      print('✅ Job submitted — instance ${job.instanceId} is starting');

      // Remove the draft but keep the zipped project on disk: the manager
      // uploads it to the instance and cleans it up once rendering starts.
      await _ref
          .read(draftJobsProvider.notifier)
          .deleteDraftJob(draftJobId, deleteFiles: false);

      state = state.copyWith(lastError: null);
    } catch (e) {
      print('❌ Error submitting job: $e');
      state = state.copyWith(
        lastError: 'Failed to submit job: ${e.toString()}',
      );

      // Update draft job with error
      await _ref
          .read(draftJobsProvider.notifier)
          .setErrorMessage(draftJobId, e.toString());
    }
  }

  @override
  void dispose() {
    _addonService.stopServer();
    super.dispose();
  }
}

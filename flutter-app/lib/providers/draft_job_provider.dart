import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/draft_job_model.dart';
import '../services/local_storage_service.dart';
import 'dart:io';

// Provider for local storage service
final localStorageProvider = Provider<LocalStorageService>((ref) {
  return LocalStorageService();
});

// State notifier for managing draft jobs
class DraftJobNotifier extends StateNotifier<List<DraftJob>> {
  final LocalStorageService _localStorage;

  /// Completes once drafts have been read off disk. Anything that acts on the
  /// *absence* of a draft (e.g. sweeping orphaned temp folders) must await
  /// this — the initial state is an empty list, not a loaded one.
  late final Future<void> ready;

  DraftJobNotifier(this._localStorage) : super([]) {
    ready = _init();
  }

  Future<void> _init() async {
    await _localStorage.initialize();
    await _loadDraftJobs();
  }

  /// Load all draft jobs from storage
  Future<void> _loadDraftJobs() async {
    state = _localStorage.getDraftJobs();
  }

  /// Add a new draft job (typically from Blender addon via some mechanism)
  Future<String> createDraftJob({
    String? id,
    required String blendFilePath,
    required String originalFilename,
    required Map<String, dynamic> renderParams,
    required String blenderVersion,
    DraftJobStatus status = DraftJobStatus.submitted,
  }) async {
    const uuid = Uuid();
    final jobId = id ?? uuid.v4();

    final draftJob = DraftJob(
      id: jobId,
      blendFilePath: blendFilePath,
      originalFilename: originalFilename,
      renderParams: renderParams,
      blenderVersion: blenderVersion,
      createdAt: DateTime.now(),
      status: status,
    );

    await _localStorage.saveDraftJob(draftJob);
    state = [...state, draftJob];
    return jobId;
  }

  /// Update a draft job's GPU selection
  Future<void> selectGPUForJob(String jobId, dynamic selectedGpu) async {
    final index = state.indexWhere((j) => j.id == jobId);
    if (index == -1) return;

    final updatedJob = state[index];

    // Guard: Do not allow modification while zipping
    if (updatedJob.status == DraftJobStatus.zipping) {
      print(
        '⚠️ Cannot modify job ${updatedJob.originalFilename} while zipping',
      );
      return;
    }

    updatedJob.selectedGpu = selectedGpu;
    updatedJob.status =
        DraftJobStatus.ready; // Auto-set to ready when configured
    updatedJob.errorMessage = null; // Clear any previous errors

    await _localStorage.saveDraftJob(updatedJob);
    state = [...state];
  }

  /// Update job status
  Future<void> updateStatus(String jobId, DraftJobStatus status) async {
    final index = state.indexWhere((j) => j.id == jobId);
    if (index == -1) return;

    final updatedJob = state[index];
    updatedJob.status = status;

    await _localStorage.saveDraftJob(updatedJob);
    state = [...state];
  }

  /// Pause a job
  Future<void> pauseJob(String jobId) async {
    await updateStatus(jobId, DraftJobStatus.paused);
  }

  /// Resume a job (set to ready if configured)
  Future<void> resumeJob(String jobId) async {
    final job = getDraftJob(jobId);
    if (job != null && job.isConfigured) {
      await updateStatus(jobId, DraftJobStatus.ready);
    }
  }

  /// Delete a draft job and clean up local files.
  ///
  /// Pass [deleteFiles] false to keep the zipped project on disk — used when
  /// the draft turns into a render job that still needs the zip for upload.
  Future<void> deleteDraftJob(
    String jobId, {
    Duration? fileDeletionDelay,
    bool deleteFiles = true,
  }) async {
    // Attempt to clean up physical files first
    final job = getDraftJob(jobId);

    // Remove from UI/storage immediately
    await _localStorage.deleteDraftJob(jobId);
    state = state.where((j) => j.id != jobId).toList();

    if (deleteFiles && job != null && job.blendFilePath.isNotEmpty) {
      // Perform file cleanup asynchronously (fire and forget)
      Future(() async {
        if (fileDeletionDelay != null) {
          print(
            '⏳ Waiting ${fileDeletionDelay.inSeconds}s before deleting files for job $jobId...',
          );
          await Future.delayed(fileDeletionDelay);
        }

        try {
          final file = File(job.blendFilePath);
          final parentDir = file.parent;

          // Safety check: ensure the folder we are about to delete
          // ends with the job ID to prevent deleting wrong directories
          // We use path segments to be safer about separators
          if (parentDir.path.endsWith(jobId) ||
              parentDir.uri.pathSegments.last == jobId) {
            if (await parentDir.exists()) {
              print('🧹 Cleaning up job files: ${parentDir.path}');
              await parentDir.delete(recursive: true);
            }
          }
        } catch (e) {
          print('⚠️ Failed to clean up job files: $e');
        }
      });
    }
  }

  /// Get a single draft job by ID
  DraftJob? getDraftJob(String jobId) {
    try {
      return state.firstWhere((j) => j.id == jobId);
    } catch (e) {
      return null;
    }
  }

  /// Clear all draft jobs
  Future<void> clearAllDraftJobs() async {
    await _localStorage.clearAllDraftJobs();
    state = [];
  }

  /// Set error message for a draft job
  Future<void> setErrorMessage(String jobId, String message) async {
    final index = state.indexWhere((j) => j.id == jobId);
    if (index == -1) return;

    final updatedJob = state[index];
    updatedJob.errorMessage = message;
    updatedJob.status = DraftJobStatus.error; // Set status to error

    await _localStorage.saveDraftJob(updatedJob);
    state = [...state];
  }

  /// Clear error message for a draft job
  Future<void> clearErrorMessage(String jobId) async {
    final index = state.indexWhere((j) => j.id == jobId);
    if (index == -1) return;

    final updatedJob = state[index];
    updatedJob.errorMessage = null;
    // If configured, set back to ready, otherwise submitted
    updatedJob.status = updatedJob.isConfigured
        ? DraftJobStatus.ready
        : DraftJobStatus.submitted;

    await _localStorage.saveDraftJob(updatedJob);
    state = [...state];
  }

  /// Clear all draft jobs
}

// Riverpod StateNotifier provider for draft jobs
final draftJobsProvider =
    StateNotifierProvider<DraftJobNotifier, List<DraftJob>>((ref) {
      final localStorage = ref.watch(localStorageProvider);
      return DraftJobNotifier(localStorage);
    });

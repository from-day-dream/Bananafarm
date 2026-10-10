import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/jobs_provider.dart';
import '../providers/draft_job_provider.dart';
import '../providers/addon_provider.dart';
import '../providers/settings_provider.dart';
import '../models/draft_job_model.dart';

final jobQueueServiceProvider = Provider<JobQueueService>((ref) {
  final service = JobQueueService(ref);
  ref.onDispose(service.dispose);
  return service;
});

class JobQueueService {
  final Ref _ref;
  bool _isSubmitting = false;
  Timer? _timer;

  JobQueueService(this._ref) {
    _startWorker();
  }

  void _startWorker() {
    // Check every 5 seconds
    _timer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _checkAndProcessQueue(),
    );
  }

  Future<void> _checkAndProcessQueue() async {
    if (_isSubmitting) return;

    try {
      // 1. Check for Configured + Queued Jobs FIRST
      final draftJobs = _ref.read(draftJobsProvider);
      final configuredJob = draftJobs.cast<DraftJob?>().firstWhere(
        (job) =>
            job?.status == DraftJobStatus.queued && job?.isConfigured == true,
        orElse: () => null,
      );

      if (configuredJob == null) return;

      // 2. Check concurrency limit against the local job list
      final activeCount = _ref.read(activeJobsProvider).length;
      final maxConcurrent = _ref.read(settingsProvider).maxConcurrentJobs;

      if (activeCount >= maxConcurrent) {
        return; // Limit reached, wait for slot
      }

      // 3. Submit the job
      _isSubmitting = true;
      print(
        '🤖 Worker: Found configured draft job ${configuredJob.originalFilename}, submitting...',
      );

      try {
        await _ref
            .read(addonConnectionStatusProvider.notifier)
            .submitDraftJob(configuredJob.id);
        print('🤖 Worker: Job submitted successfully');
      } catch (e) {
        print('🤖 Worker: Failed to submit job: $e');
        // Error is already handled/set in submitDraftJob
      } finally {
        _isSubmitting = false;
      }
    } catch (e) {
      print('🤖 Worker: Error in queue loop: $e');
      _isSubmitting = false;
    }
  }

  void dispose() {
    _timer?.cancel();
  }
}

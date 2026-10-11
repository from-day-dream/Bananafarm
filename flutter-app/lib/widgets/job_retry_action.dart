import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/gpu_offer.dart';
import '../models/job_model.dart';
import '../services/render_job_manager.dart';
import '../utils/toast_utils.dart';
import 'gpu_selection_modal.dart';

/// What the user chose in the retry dialog.
enum _RetryChoice { sameGpu, changeGpu }

/// Confirm and re-run a failed job, optionally on a different GPU.
///
/// Shared by every surface that lists jobs so the wording and error handling
/// stay identical. Returns true if a new job was actually submitted — callers
/// showing a single job (the detail screen) must pop, because a retry mints a
/// new id and the old record is deleted.
Future<bool> confirmAndRetry(
  BuildContext context,
  WidgetRef ref,
  RenderJob job,
) async {
  final messenger = ScaffoldMessenger.of(context);

  final choice = await showDialog<_RetryChoice>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Retry Job'),
      content: Text(
        job.canRetry
            ? 'Run this render again on ${job.gpuName} with the same settings? '
                'This job will be replaced by the new one'
                '${job.hasLiveInstance ? ', and its old GPU instance deleted' : ''}.'
            : 'The GPU this job used is no longer recorded, so pick one to run '
                'it again. This job will be replaced by the new one'
                '${job.hasLiveInstance ? ', and its old GPU instance deleted' : ''}.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(_RetryChoice.changeGpu),
          child: const Text('Change GPU…'),
        ),
        // Only offered when we still know which GPU the job ran on.
        if (job.canRetry)
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_RetryChoice.sameGpu),
            child: const Text('Retry'),
          ),
      ],
    ),
  );

  if (choice == null) return false;

  GpuOffer? override;
  if (choice == _RetryChoice.changeGpu) {
    if (!context.mounted) return false;
    // Picked before retryJob runs, so the choice stays outside the temp-folder
    // rename that retryJob rolls back on failure.
    override = await showDialog<GpuOffer>(
      context: context,
      builder: (_) => GpuSelectionModal(
        jobId: job.id,
        initialSelection: job.gpuOffer,
      ),
    );
    if (override == null) return false;
  }

  try {
    await ref.read(renderJobManagerProvider).retryJob(
          job.id,
          gpuOverride: override,
        );
    ToastUtils.showSuccess(messenger, 'Job resubmitted');
    return true;
  } catch (e) {
    // retryJob's StateErrors are already written for the user; e.toString()
    // would prefix them with "Bad state: ".
    ToastUtils.showError(
      messenger,
      e is StateError ? e.message : 'Failed to retry job: $e',
    );
    return false;
  }
}

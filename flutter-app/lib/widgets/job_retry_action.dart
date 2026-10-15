import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/job_model.dart';
import '../models/render_provider.dart';
import '../screens/job_submission_screen.dart';
import '../services/render_job_manager.dart';
import '../utils/toast_utils.dart';

/// Retry a failed or cancelled job: turn it back into a draft and open the
/// submission page with its previous GPU preselected, so it is resubmitted
/// exactly like a new job (and the GPU can be changed first).
///
/// Shared by every surface that lists jobs so the wording and error handling
/// stay identical. Returns true if the job was moved back to the submission
/// page. A screen showing that job (the detail screen) passes
/// [replaceCurrent], since the job record no longer exists — it is a draft.
Future<bool> confirmAndRetry(
  BuildContext context,
  WidgetRef ref,
  RenderJob job, {
  bool replaceCurrent = false,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);

  // Only worth a confirm when retrying deletes something that is billing.
  if (job.hasLiveInstance) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Retry Job'),
        content: Text(
          'Delete this job\'s instance on ${job.provider.label} and set it up '
          'again? You can keep or change the GPU before submitting.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete & Retry'),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
  }

  return sendBackToSubmission(
    navigator,
    messenger,
    ref,
    job,
    keepGpu: true,
    replaceCurrent: replaceCurrent,
  );
}

/// Move [job] back to the submission page and open it. Used by Retry and by
/// the slow-start warning. Returns false (after showing why) if it couldn't.
Future<bool> sendBackToSubmission(
  NavigatorState navigator,
  ScaffoldMessengerState messenger,
  WidgetRef ref,
  RenderJob job, {
  required bool keepGpu,
  bool replaceCurrent = false,
}) async {
  try {
    await ref
        .read(renderJobManagerProvider)
        .returnToDraft(job.id, keepGpu: keepGpu);
  } catch (e) {
    // returnToDraft's StateErrors are already written for the user;
    // e.toString() would prefix them with "Bad state: ".
    ToastUtils.showError(
      messenger,
      e is StateError ? e.message : 'Could not set up the job again: $e',
    );
    return false;
  }

  final route = MaterialPageRoute<void>(
    builder: (_) => JobSubmissionScreen(draftJobId: job.id),
  );
  if (replaceCurrent) {
    navigator.pushReplacement(route);
  } else {
    navigator.push(route);
  }
  return true;
}

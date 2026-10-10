import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/job_model.dart';
import 'job_retry_action.dart';

/// Re-runs a failed job, on the same GPU or a different one.
///
/// Deliberately never disappears for a failed job: when the project files have
/// been reclaimed it renders disabled with the reason, because a retry button
/// that silently isn't there reads as "this app has no retry".
class JobRetryButton extends ConsumerStatefulWidget {
  final RenderJob job;

  const JobRetryButton({
    required this.job,
    Key? key,
  }) : super(key: key);

  @override
  ConsumerState<JobRetryButton> createState() => _JobRetryButtonState();
}

class _JobRetryButtonState extends ConsumerState<JobRetryButton> {
  bool _isRetrying = false;

  @override
  Widget build(BuildContext context) {
    final job = widget.job;

    // Only failed jobs are retryable — cancelled is a deliberate user action.
    if (!job.isFailed) {
      return const SizedBox.shrink();
    }

    if (_isRetrying) {
      return _box(
        context,
        const Padding(
          padding: EdgeInsets.all(8),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (!job.canRepickGpu) {
      return Tooltip(
        message: 'Project files were reclaimed — resend the job from Blender',
        child: _box(
          context,
          Icon(Icons.refresh, size: 18, color: Colors.grey[500]),
        ),
      );
    }

    return Tooltip(
      message: 'Retry job',
      child: _box(
        context,
        IconButton(
          icon: const Icon(Icons.refresh, size: 18),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: _retry,
        ),
      ),
    );
  }

  Future<void> _retry() async {
    setState(() => _isRetrying = true);
    try {
      await confirmAndRetry(context, ref, widget.job);
    } finally {
      // The old job is gone on success, so this widget is usually already
      // disposed by the time we get here.
      if (mounted) setState(() => _isRetrying = false);
    }
  }

  Widget _box(BuildContext context, Widget child) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(child: child),
    );
  }
}

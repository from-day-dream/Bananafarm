import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/job_model.dart';
import '../models/render_provider.dart';
import 'instance_logs_dialog.dart';
import 'job_retry_action.dart';

/// Warns when a job's instance has been starting for unusually long, with
/// its logs and a way back to GPU selection.
///
/// Re-checks every 5 s on its own, so it appears when the threshold passes
/// rather than on the next job update. Renders nothing otherwise.
class SlowStartBanner extends ConsumerStatefulWidget {
  final RenderJob job;

  /// One-line form for job cards; the full form is for the detail screen.
  final bool compact;

  /// Set when this banner sits on a screen that shows only this job, which
  /// must be replaced because the job turns into a draft.
  final bool replaceCurrent;

  const SlowStartBanner({
    super.key,
    required this.job,
    this.compact = false,
    this.replaceCurrent = false,
  });

  @override
  ConsumerState<SlowStartBanner> createState() => _SlowStartBannerState();
}

class _SlowStartBannerState extends ConsumerState<SlowStartBanner> {
  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _pickAnotherGpu() async {
    final job = widget.job;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Pick Another GPU?'),
        content: Text(
          'Delete the instance on ${job.provider.label} and choose another '
          'GPU? Nothing has rendered yet, and the job keeps its settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep Waiting'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete & Pick GPU'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    await sendBackToSubmission(
      navigator,
      messenger,
      ref,
      job,
      keepGpu: false,
      replaceCurrent: widget.replaceCurrent,
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final now = DateTime.now();
    if (!job.isSlowToStart(now)) return const SizedBox.shrink();

    final minutes =
        now.difference(job.instanceCreatedAt ?? job.createdAt).inMinutes;
    final amber = Colors.amber[800]!;

    final actions = Wrap(
      spacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: () => showInstanceLogs(context, ref, job),
          icon: const Icon(Icons.article_outlined, size: 16),
          label: const Text('View Logs'),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _pickAnotherGpu,
          icon: const Icon(Icons.swap_horiz, size: 16),
          label: const Text('Delete & pick another GPU'),
          style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
        ),
      ],
    );

    return Container(
      margin: EdgeInsets.only(top: widget.compact ? 12 : 0),
      padding: EdgeInsets.all(widget.compact ? 12 : 16),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(widget.compact ? 8 : 12),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.hourglass_bottom, color: amber, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Instance is taking unusually long to start ($minutes min)',
                  style: TextStyle(fontWeight: FontWeight.bold, color: amber),
                ),
              ),
            ],
          ),
          if (!widget.compact) ...[
            const SizedBox(height: 4),
            Text(
              'It may be stuck pulling the image or downloading Blender. '
              'Check the logs, or delete it and pick another GPU. It is '
              'billing while it starts.',
              style: TextStyle(color: amber, fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          actions,
        ],
      ),
    );
  }
}

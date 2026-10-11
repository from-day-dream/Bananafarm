import 'package:flutter/material.dart';
import '../models/job_model.dart';
import 'job_progress_display.dart';

/// Renders a job's live progress. The RenderJobManager polls the instance
/// and publishes snapshots onto the job model, so this widget just displays
/// `job.progress` — parents watching jobsProvider keep it fresh.
class LiveJobProgressDisplay extends StatelessWidget {
  final RenderJob job;
  final bool compact; // For dashboard list view

  const LiveJobProgressDisplay({
    required this.job,
    this.compact = false,
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final progress = job.progress;
    final isWarmingUp = progress == null &&
        (job.status == LocalJobStatus.creating ||
            job.status == LocalJobStatus.starting);

    final statusMessage = progress?.statusMessage.isNotEmpty == true
        ? progress!.statusMessage
        : job.statusLabel;
    final percentage = progress?.progressPercent ?? 0.0;

    // Dashboard View (Compact)
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min, // Keep height tight
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  statusMessage,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                isWarmingUp ? '--%' : '${percentage.toStringAsFixed(1)}%',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              // Indeterminate while the instance is booting so it looks alive
              value: isWarmingUp ? null : (percentage / 100.0),
              minHeight: 4,
              backgroundColor: Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation<Color>(
                isWarmingUp
                    ? Colors.blue.shade300
                    : _getProgressColor(percentage),
              ),
            ),
          ),
        ],
      );
    }

    // Full Detail View
    return JobProgressDisplay(
      percentage: percentage,
      currentFrame: progress?.currentFrame ?? 0,
      totalFrames: progress?.totalFrames ?? job.renderParams.frameEnd,
      statusMessage: statusMessage,
      loading: isWarmingUp,
      isAnimation: job.renderParams.isAnimationRender,
      tilesDone: progress?.tilesDone ?? 0,
      totalTiles: progress?.totalTiles ?? 0,
    );
  }

  Color _getProgressColor(double percentage) {
    if (percentage < 33) {
      return Colors.blue.shade500;
    } else if (percentage < 66) {
      return Colors.amber.shade500;
    } else {
      return Colors.green.shade500;
    }
  }
}

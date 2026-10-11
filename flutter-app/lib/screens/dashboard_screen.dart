import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/app_theme.dart';
import '../models/job_model.dart';
import 'job_submission_screen.dart';
import 'job_detail_screen.dart';
import '../providers/addon_provider.dart';
import '../providers/draft_job_provider.dart';
import '../providers/jobs_provider.dart';
import '../models/draft_job_model.dart';
import '../widgets/draft_job_status_badge.dart';
import '../widgets/addon_config_modal.dart';
import '../widgets/live_job_progress_display.dart';
import '../utils/job_error_parser.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(jobsProvider);
    final draftJobs = ref.watch(draftJobsProvider);
    final addonStatus = ref.watch(addonConnectionStatusProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final runningJobs = jobs.where((j) => j.isActive).toList();
    final completedCount = jobs.where((j) => j.isCompleted).length;
    final liveInstances =
        jobs.where((j) => !j.isActive && j.hasLiveInstance).length;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // API Status Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).cardTheme.color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isDark
                    ? Colors.white.withOpacity(0.1)
                    : Colors.grey[200]!,
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.grey[800] : Colors.grey[100],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.link, size: 20),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Blender API Status',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'http://localhost:${addonStatus.port}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey,
                          fontSize: 10,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                InkWell(
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) => const AddonConfigModal(),
                    );
                  },
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isDark ? Colors.grey[400]! : Colors.grey[600]!,
                      ),
                    ),
                    child: Text(
                      'Configure Addon',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.grey[400] : Colors.grey[600],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: addonStatus.isServerRunning
                        ? Colors.green.withOpacity(0.1)
                        : Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: addonStatus.isServerRunning
                          ? Colors.green
                          : Colors.red,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: addonStatus.isServerRunning
                              ? Colors.green
                              : Colors.red,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        addonStatus.isServerRunning ? 'Active' : 'Inactive',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: addonStatus.isServerRunning
                              ? Colors.green
                              : Colors.red,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Stats Cards
          Row(
            children: [
              // Currently Rendering Card
              Expanded(
                child: _buildStatsCard(
                  context,
                  title: 'Currently Rendering',
                  value: runningJobs.length.toString(),
                  isAccent: true,
                ),
              ),
              const SizedBox(width: 16),
              // Completed Jobs Count Card
              Expanded(
                child: _buildStatsCard(
                  context,
                  title: 'Completed Jobs',
                  value: completedCount.toString(),
                  isAccent: false,
                ),
              ),
              const SizedBox(width: 16),
              // Live instances awaiting manual deletion
              Expanded(
                child: _buildStatsCard(
                  context,
                  title: 'Instances to Delete',
                  value: liveInstances.toString(),
                  isAccent: false,
                ),
              ),
            ],
          ),

          const SizedBox(height: 32),

          // Running Job Section
          if (runningJobs.isNotEmpty) ...[
            Text(
              'Running Job${runningJobs.length > 1 ? "s" : ""}',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontFamily: 'Urbanist',
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 16),
            ...runningJobs.map(
              (job) => _buildRunningJobCard(context, isDark, job),
            ),
            const SizedBox(height: 32),
          ],

          // Error Banner
          if (draftJobs.any((j) => j.status == DraftJobStatus.error)) ...[
            ...draftJobs
                .where((j) => j.status == DraftJobStatus.error)
                .map(
                  (job) => Container(
                    margin: const EdgeInsets.only(bottom: 24),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                JobSubmissionScreen(draftJobId: job.id),
                          ),
                        ),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Colors.red.withOpacity(0.5),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.error_outline,
                                color: Colors.red,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Job Error: ${job.originalFilename}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.red,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      JobErrorParser.parse(job.errorMessage),
                                      style: TextStyle(
                                        color: Colors.red.shade700,
                                        fontSize: 12,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(
                                Icons.arrow_forward,
                                color: Colors.red,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
          ],

          // Draft Jobs Section
          if (draftJobs.isNotEmpty) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Draft Jobs',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontFamily: 'Urbanist',
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (draftJobs.length > 2)
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const JobSubmissionScreen(),
                      ),
                    ),
                    child: const Text('View All'),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            ...draftJobs
                .take(2)
                .map(
                  (job) => Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardTheme.color,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context).dividerColor.withOpacity(0.1),
                      ),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              job.originalFilename,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 4),
                          Text(
                            'Created: ${_formatDateTime(job.createdAt)}',
                            style: TextStyle(
                              color: isDark
                                  ? Colors.grey[400]
                                  : Colors.grey[600],
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${job.isAnimation ? "Animation" : "Still Frame"} • ${job.framesDisplay} • ${job.engine}',
                            style: TextStyle(
                              color: isDark
                                  ? Colors.grey[500]
                                  : Colors.grey[500],
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 8),
                          DraftJobStatusBadge(
                            status: job.status,
                            errorMessage: job.errorMessage,
                          ),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: 8),
                          IconButton(
                            icon: Icon(
                              Icons.close,
                              size: 20,
                              color: isDark
                                  ? Colors.grey[400]
                                  : Colors.grey[600],
                            ),
                            onPressed: () =>
                                _confirmDeleteDraft(context, ref, job.id),
                            tooltip: 'Delete Draft',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                          const SizedBox(width: 16),
                          Icon(
                            job.status == DraftJobStatus.submitted
                                ? Icons.arrow_forward
                                : Icons.edit,
                            size: 18,
                            color: isDark ? Colors.grey[400] : Colors.grey[600],
                          ),
                        ],
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              JobSubmissionScreen(draftJobId: job.id),
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ] else ...[
            // Empty state for drafts if needed, or just show nothing
            const SizedBox.shrink(),
          ],
        ],
      ),
    );
  }

  Widget _buildStatsCard(
    BuildContext context, {
    required String title,
    required String value,
    required bool isAccent,
    List<Widget>? actions,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isAccent
        ? AppTheme.primary
        : Theme.of(context).cardTheme.color;
    final textColor = isAccent
        ? Colors.black
        : (isDark ? Colors.white : Colors.black);

    return Container(
      height: 140,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: null,
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontFamily: 'Urbanist',
                  fontWeight: FontWeight.normal,
                  fontSize: 12,
                  color: textColor.withOpacity(0.7),
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  fontFamily: 'Urbanist',
                  fontWeight: FontWeight.w600,
                  fontSize: 32,
                  color: textColor,
                ),
              ),
            ],
          ),
          if (actions != null)
            Positioned(top: 0, right: 0, child: Column(children: actions)),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteDraft(
    BuildContext context,
    WidgetRef ref,
    String jobId,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Draft Job'),
        content: const Text(
          'Are you sure you want to delete this draft? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      ref.read(draftJobsProvider.notifier).deleteDraftJob(jobId);
    }
  }

  String _formatDateTime(DateTime date) {
    return '${date.day}/${date.month}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildRunningJobCard(
    BuildContext context,
    bool isDark,
    RenderJob job,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      width: double.infinity,
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? Colors.white.withOpacity(0.1) : Colors.grey[200]!,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => JobDetailScreen(jobId: job.id),
              ),
            );
          },
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      job.id.substring(0, 8),
                      style: const TextStyle(
                        fontFamily: 'Urbanist',
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blue.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        job.statusLabel.toUpperCase(),
                        style: const TextStyle(
                          color: Colors.blue,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '${job.gpuName} • ${job.blenderVersion}',
                  style: TextStyle(
                    color: isDark ? Colors.grey[400] : Colors.grey[600],
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 12),
                LiveJobProgressDisplay(job: job, compact: true),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

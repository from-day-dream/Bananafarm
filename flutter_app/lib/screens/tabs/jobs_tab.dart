import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/draft_job_provider.dart';
import '../../providers/jobs_provider.dart';
import '../../theme/app_theme.dart';
import '../../models/job_model.dart';
import '../../models/draft_job_model.dart';
import '../draft_jobs_screen.dart';
import '../job_submission_screen.dart';
import '../job_detail_screen.dart';
import '../all_jobs_screen.dart';
import '../all_running_jobs_screen.dart';
import '../../widgets/job_download_button.dart';
import '../../widgets/job_retry_button.dart';
import '../../utils/format_utils.dart';
import '../../utils/job_error_parser.dart';
import '../../widgets/draft_job_status_badge.dart';

class JobsTab extends ConsumerWidget {
  const JobsTab({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(jobsProvider);
    final draftJobs = ref.watch(draftJobsProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final activeJobs = jobs.where((j) => j.isActive).toList();
    final completedJobs = jobs.where((j) => !j.isActive).toList();
    final recentCompleted = completedJobs.take(4).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Draft Jobs Section
          _buildSection(
            context,
            title: 'Draft Jobs',
            onViewAll: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const DraftJobsScreen())),
            isEmpty: draftJobs.isEmpty,
            emptyMessage: 'No draft jobs',
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: draftJobs.take(4).length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final job = draftJobs[index];
                return _buildDraftJobCard(context, job, ref);
              },
            ),
          ),
          const SizedBox(height: 24),

          // Running Jobs Section
          _buildSection(
            context,
            title: 'Running Jobs',
            onViewAll: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AllRunningJobsScreen(),
              ),
            ),
            isEmpty: activeJobs.isEmpty,
            emptyMessage: 'No running jobs',
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: activeJobs.take(4).length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final job = activeJobs[index];
                return _buildJobCard(context, job, isCurrent: true);
              },
            ),
          ),
          const SizedBox(height: 24),

          // Past Jobs Section
          _buildSection(
            context,
            title: 'Past Jobs',
            onViewAll: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AllJobsScreen()),
            ),
            isEmpty: recentCompleted.isEmpty,
            emptyMessage: 'No past jobs',
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: recentCompleted.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final job = recentCompleted[index];
                return _buildJobCard(context, job, isCurrent: false);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required VoidCallback onViewAll,
    required bool isEmpty,
    required String emptyMessage,
    required Widget child,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).dividerColor.withOpacity(0.1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontFamily: 'Urbanist',
                  fontWeight: FontWeight.bold,
                ),
              ),
              IconButton(
                onPressed: onViewAll,
                icon: Icon(
                  Icons.arrow_forward,
                  size: 20,
                  color: AppTheme.primary,
                ),
                tooltip: 'View All',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  emptyMessage,
                  style: TextStyle(color: Colors.grey[600]),
                ),
              ),
            )
          else
            child,
        ],
      ),
    );
  }

  Widget _buildDraftJobCard(BuildContext context, dynamic job, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).dividerColor.withOpacity(0.1),
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        title: Row(
          children: [
            Expanded(
              child: Text(
                job.originalFilename,
                style: const TextStyle(fontWeight: FontWeight.bold),
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
                color: isDark ? Colors.grey[400] : Colors.grey[600],
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${job.isAnimation ? "Animation" : "Still Frame"} • ${job.framesDisplay} • ${job.engine}',
              style: TextStyle(
                color: isDark ? Colors.grey[500] : Colors.grey[500],
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
                color: isDark ? Colors.grey[400] : Colors.grey[600],
              ),
              onPressed: () => _confirmDeleteDraft(context, ref, job.id),
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
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => JobSubmissionScreen(draftJobId: job.id),
            ),
          );
        },
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

  Widget _buildJobCard(
    BuildContext context,
    RenderJob job, {
    required bool isCurrent,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCurrent
              ? AppTheme.primary.withOpacity(0.5)
              : Theme.of(context).dividerColor.withOpacity(0.1),
          width: isCurrent ? 1.5 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => JobDetailScreen(jobId: job.id)),
            );
          },
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            job.id.substring(0, 8),
                            style: const TextStyle(
                              fontFamily: 'Urbanist',
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 4),
                          // A failed job reads as red with the parsed reason on
                          // hover, matching the All Jobs list.
                          Text.rich(
                            TextSpan(
                              style: TextStyle(
                                color: isDark
                                    ? Colors.grey[400]
                                    : Colors.grey[600],
                                fontSize: 12,
                              ),
                              children: [
                                TextSpan(text: '${job.gpuName} • '),
                                if (job.isFailed)
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: Tooltip(
                                      message: JobErrorParser.parse(
                                        job.errorMessage,
                                      ),
                                      child: Text(
                                        job.statusLabel,
                                        style: TextStyle(
                                          color: Colors.red[300],
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          decoration:
                                              TextDecoration.underline,
                                          decorationStyle:
                                              TextDecorationStyle.dotted,
                                        ),
                                      ),
                                    ),
                                  )
                                else
                                  TextSpan(text: job.statusLabel),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isCurrent)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),

                if (!isCurrent) ...[
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (job.duration != null)
                            Text(
                              FormatUtils.formatDuration(job.duration!),
                              style: TextStyle(
                                color: isDark
                                    ? Colors.grey[400]
                                    : Colors.grey[600],
                                fontSize: 12,
                              ),
                            ),
                          if (job.hasLiveInstance)
                            Text(
                              'Instance running',
                              style: TextStyle(
                                color: Colors.orange[700],
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          JobRetryButton(job: job),
                          if (job.isFailed) const SizedBox(width: 8),
                          JobDownloadButton(job: job),
                        ],
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

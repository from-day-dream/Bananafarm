import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/jobs_provider.dart';
import '../services/render_job_manager.dart';
import '../models/job_model.dart';
import 'job_detail_screen.dart';
import '../widgets/job_download_button.dart';
import '../widgets/job_retry_action.dart';
import '../widgets/live_cost_text.dart';
import '../utils/format_utils.dart';
import '../utils/job_error_parser.dart';
import '../utils/toast_utils.dart';

class AllJobsScreen extends ConsumerWidget {
  const AllJobsScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pastJobs =
        ref.watch(jobsProvider).where((j) => !j.isActive).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Past Jobs'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: pastJobs.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history, size: 64, color: Colors.grey.shade400),
                  const SizedBox(height: 16),
                  Text(
                    'No past jobs',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(24),
              itemCount: pastJobs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final job = pastJobs[index];
                return _buildJobCard(context, job, ref);
              },
            ),
    );
  }

  Widget _buildJobCard(BuildContext context, RenderJob job, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => JobDetailScreen(jobId: job.id)),
        );
      },
      child: Stack(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).cardTheme.color,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Theme.of(context).dividerColor.withOpacity(0.1),
              ),
            ),
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
                            job.renderParams.displayName,
                            style: const TextStyle(
                              fontFamily: 'Urbanist',
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 4),
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
                                          decoration: TextDecoration.underline,
                                          decorationStyle:
                                              TextDecorationStyle.dotted,
                                        ),
                                      ),
                                    ),
                                  )
                                else
                                  TextSpan(text: job.statusLabel),
                                if (job.isCompleted && job.completedAt != null)
                                  TextSpan(
                                    text:
                                        ' • ${FormatUtils.formatDateTime(job.completedAt!)}',
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
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
                        LiveCostText(
                          job: job,
                          style: TextStyle(
                            color: isDark
                                ? Colors.grey[400]
                                : Colors.grey[600],
                            fontSize: 12,
                          ),
                        ),
                        if (job.hasLiveInstance)
                          Text(
                            'Instance running — delete after download',
                            style: TextStyle(
                              color: Colors.orange[700],
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                    JobDownloadButton(job: job),
                  ],
                ),
              ],
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: Row(
              children: [
                // Offered for every failed job, not just ones whose original
                // GPU is still known — the dialog can re-pick one.
                if (job.canRetry) ...[
                  _buildCardAction(
                    isDark: isDark,
                    icon: Icons.refresh,
                    tooltip: 'Retry job',
                    onTap: () => confirmAndRetry(context, ref, job),
                  ),
                  const SizedBox(width: 6),
                ],
                _buildCardAction(
                  isDark: isDark,
                  icon: Icons.close,
                  tooltip: 'Delete job',
                  onTap: () => _confirmDelete(context, ref, job.id),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCardAction({
    required bool isDark,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isDark ? Colors.grey[800] : Colors.grey[200],
          ),
          child: Icon(
            icon,
            size: 14,
            color: isDark ? Colors.grey[400] : Colors.grey[600],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    String jobId,
  ) async {
    final job = ref.read(jobsProvider).where((j) => j.id == jobId).firstOrNull;
    final hasLiveInstance = job?.hasLiveInstance ?? false;

    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Job'),
        content: Text(
          hasLiveInstance
              ? 'This job\'s GPU instance is still running. Deleting the job '
                  'will also delete the instance (stopping billing) and its '
                  'render outputs. Continue?'
              : 'Are you sure you want to delete this job? This action cannot '
                  'be undone.',
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

    if (confirmed != true) return;

    try {
      await ref.read(renderJobManagerProvider).deleteJob(jobId);
    } catch (e) {
      ToastUtils.showError(messenger, 'Error deleting job: $e');
    }
  }
}

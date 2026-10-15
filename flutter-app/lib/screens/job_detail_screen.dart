import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/job_model.dart';
import '../models/render_provider.dart';
import '../providers/jobs_provider.dart';
import '../services/render_job_manager.dart';
import '../widgets/live_job_progress_display.dart';
import '../widgets/job_download_button.dart';
import '../widgets/job_retry_action.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';
import '../utils/toast_utils.dart';
import '../utils/job_error_parser.dart';
import '../widgets/instance_logs_dialog.dart';
import '../widgets/live_cost_text.dart';
import '../widgets/slow_start_banner.dart';
import 'package:url_launcher/url_launcher.dart';

class JobDetailScreen extends ConsumerStatefulWidget {
  final String jobId;
  const JobDetailScreen({required this.jobId, Key? key}) : super(key: key);

  @override
  ConsumerState<JobDetailScreen> createState() => _JobDetailScreenState();
}

class _JobDetailScreenState extends ConsumerState<JobDetailScreen> {
  bool _actionInProgress = false;

  @override
  Widget build(BuildContext context) {
    final job = ref
        .watch(jobsProvider)
        .where((j) => j.id == widget.jobId)
        .firstOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('Job Details'), elevation: 0),
      body: job == null
          ? Center(
              child: Text(
                'Job not found',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Starting for unusually long: logs / pick another GPU.
                  // Renders nothing until the threshold passes.
                  SlowStartBanner(job: job, replaceCurrent: true),
                  if (job.isSlowToStart(DateTime.now()))
                    const SizedBox(height: 16),

                  // Reminder: instance keeps billing until manually deleted.
                  // Hidden while a download runs — the download card shows it.
                  if (job.isCompleted &&
                      job.hasLiveInstance &&
                      ref.watch(downloadProgressProvider
                              .select((m) => m[job.id])) ==
                          null) ...[
                    _buildLiveInstanceBanner(context, job),
                    const SizedBox(height: 16),
                  ],

                  // Job Info Card
                  _buildInfoCard(context, job),
                  const SizedBox(height: 16),

                  // Progress Card (Active Jobs)
                  if (job.isActive) ...[
                    _buildProgressCard(context, job),
                    const SizedBox(height: 16),
                  ],

                  // Render Parameters Card
                  _buildRenderParamsCard(context, job),
                  const SizedBox(height: 16),

                  // Duration Card
                  if (job.duration != null) ...[
                    _buildDurationCard(context, job),
                    const SizedBox(height: 16),
                  ],

                  // Completed Actions
                  if (job.isCompleted) _buildDownloadCard(context, job),

                  // Not gated on errorMessage: a failed job without one would
                  // otherwise show no explanation at all. JobErrorParser turns
                  // a null message into 'Unknown error occurred'.
                  if (job.isFailed || job.isCancelled) ...[
                    _buildErrorCard(context, job),
                    const SizedBox(height: 16),
                  ],

                  // Job actions (cancel / delete instance / delete job)
                  const SizedBox(height: 8),
                  _buildActionsRow(context, job),
                ],
              ),
            ),
    );
  }

  Widget _buildLiveInstanceBanner(BuildContext context, RenderJob job) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.red[700]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Instance is still running and billing',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.red[800],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Download your files, then delete the instance. Outputs are '
                  'lost when the instance is deleted.',
                  style: TextStyle(color: Colors.red[700], fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionsRow(BuildContext context, RenderJob job) {
    return Row(
      children: [
        // Provider logs exist for as long as the instance does.
        if (job.instanceId != null && !job.instanceDestroyed) ...[
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => showInstanceLogs(context, ref, job),
              icon: const Icon(Icons.article_outlined, size: 18),
              label: const Text('View Logs'),
            ),
          ),
          const SizedBox(width: 12),
        ],
        if (job.isActive)
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _actionInProgress
                  ? null
                  : () => _confirmAction(
                        context,
                        title: 'Cancel Job',
                        message:
                            'Stop this render and delete the GPU instance? '
                            'Progress will be lost.',
                        confirmLabel: 'Cancel Job',
                        action: () => ref
                            .read(renderJobManagerProvider)
                            .cancelJob(job.id),
                        successMessage: 'Job cancelled',
                      ),
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: const Text('Cancel Job'),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
            ),
          ),
        // Failed or cancelled jobs whose project files survive. Retry turns
        // the job back into a draft, so this screen is replaced by the
        // submission page.
        if (job.canRetry) ...[
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _actionInProgress
                  ? null
                  : () async {
                      setState(() => _actionInProgress = true);
                      await confirmAndRetry(context, ref, job,
                          replaceCurrent: true);
                      if (mounted) setState(() => _actionInProgress = false);
                    },
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry Job'),
            ),
          ),
          const SizedBox(width: 12),
        ],
        if (!job.isActive && job.hasLiveInstance) ...[
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _actionInProgress
                  ? null
                  : () => _confirmAction(
                        context,
                        title: 'Delete Instance',
                        message:
                            'Delete the GPU instance on ${job.provider.label}? '
                            'This stops billing and permanently removes the '
                            'render outputs from the instance.',
                        confirmLabel: 'Delete Instance',
                        action: () => ref
                            .read(renderJobManagerProvider)
                            .destroyInstance(job.id),
                        successMessage: 'Instance deleted',
                      ),
              icon: const Icon(Icons.power_settings_new, size: 18),
              label: const Text('Delete Instance'),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
            ),
          ),
          const SizedBox(width: 12),
        ],
        if (!job.isActive)
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _actionInProgress
                  ? null
                  : () => _confirmAction(
                        context,
                        title: 'Delete Job',
                        message: job.hasLiveInstance
                            ? 'Remove this job from history? Its GPU instance '
                                'will also be deleted (stopping billing).'
                            : 'Remove this job from history?',
                        confirmLabel: 'Delete Job',
                        action: () async {
                          await ref
                              .read(renderJobManagerProvider)
                              .deleteJob(job.id);
                          if (mounted) Navigator.of(context).pop();
                        },
                        successMessage: 'Job deleted',
                      ),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete Job'),
            ),
          ),
      ],
    );
  }

  Future<void> _confirmAction(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    required Future<void> Function() action,
    required String successMessage,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Back'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _actionInProgress = true);
    try {
      await action();
      if (mounted) {
        ToastUtils.showSuccess(
            ScaffoldMessenger.of(context), successMessage);
      }
    } catch (e) {
      if (mounted) {
        ToastUtils.showError(ScaffoldMessenger.of(context), 'Failed: $e');
      }
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  Widget _buildInfoCard(BuildContext context, RenderJob job) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.renderParams.displayName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'ID: ${job.id.substring(0, 8)}',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 12,
                        fontFamily: 'Monospace',
                      ),
                    ),
                  ],
                ),
              ),
              _buildStatusBadge(context, job),
            ],
          ),
          const Divider(height: 24),
          Row(
            children: [
              _buildInfoChip(
                context,
                Icons.cloud_queue,
                job.provider.label,
                _getProviderColor(job.provider).withOpacity(0.1),
                _getProviderColor(job.provider),
              ),
              const SizedBox(width: 8),
              _buildInfoChip(
                context,
                Icons.memory,
                job.gpuName,
                AppTheme.primary.withOpacity(0.1),
                AppTheme.primary,
              ),
              if (job.instanceId != null) ...[
                const SizedBox(width: 8),
                _buildInfoChip(
                  context,
                  job.instanceDestroyed ? Icons.power_off : Icons.bolt,
                  job.instanceDestroyed
                      ? 'Instance deleted'
                      : 'Instance ${job.instanceId}',
                  Colors.grey.withOpacity(0.1),
                  job.instanceDestroyed ? Colors.grey : Colors.orange[800]!,
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Created ${FormatUtils.formatDateTime(job.createdAt)}',
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
          ),
          if (job.instanceCreatedAt != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  'Instance cost: ',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
                LiveCostText(
                  job: job,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProgressCard(BuildContext context, RenderJob job) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Live Progress',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 16),
          LiveJobProgressDisplay(job: job),
        ],
      ),
    );
  }

  Widget _buildRenderParamsCard(BuildContext context, RenderJob job) {
    final params = job.renderParams;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Render Configuration',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 16),
          _buildDetailRow(context, 'Engine', params.engine),
          const Divider(height: 16),
          _buildDetailRow(context, 'Resolution', params.resolution),
          const Divider(height: 16),
          _buildDetailRow(context, 'Blender', job.blenderVersion),
          const Divider(height: 16),
          _buildDetailRow(
            context,
            'Frames',
            params.isAnimationRender
                ? '${params.frameStart}-${params.frameEnd}'
                : '${params.currentFrame}',
          ),
          if (params.outputFormat != null) ...[
            const Divider(height: 16),
            _buildDetailRow(context, 'Format', params.outputFormat!),
          ],
        ],
      ),
    );
  }

  Widget _buildDurationCard(BuildContext context, RenderJob job) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
      ),
      child: _buildDetailRow(
        context,
        'Total Duration',
        FormatUtils.formatDuration(job.duration!),
        icon: Icons.timer_outlined,
      ),
    );
  }

  Widget _buildDownloadCard(BuildContext context, RenderJob job) {
    final destroyed = job.instanceDestroyed;
    final progress =
        ref.watch(downloadProgressProvider.select((m) => m[job.id]));
    final failed = progress == null &&
        !destroyed &&
        job.downloadState == DownloadState.failed;
    final downloaded = job.downloadState == DownloadState.downloaded &&
        job.downloadedTo != null;
    final bg = failed
        ? Colors.red[50]
        : (destroyed && !downloaded ? Colors.grey[100] : Colors.green[50]);
    final border =
        failed ? Colors.red : (destroyed && !downloaded ? Colors.grey : Colors.green);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: destroyed ? Colors.grey[300] : Colors.green[100],
              shape: BoxShape.circle,
            ),
            child: Icon(
              destroyed ? Icons.file_download_off : Icons.check,
              color: destroyed ? Colors.grey[700] : Colors.green[800],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  job.status == LocalJobStatus.partiallyCompleted
                      ? 'Partially Complete'
                      : 'Render Complete',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: destroyed ? Colors.grey[800] : Colors.green[900],
                  ),
                ),
                if (progress != null) ...[
                  Text(
                    'Downloading outputs… ${(progress * 100).round()}%',
                    style: TextStyle(color: Colors.green[800], fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: progress > 0 ? progress : null),
                ] else if (failed) ...[
                  Text(
                    'Download failed: ${job.downloadError ?? 'unknown error'}',
                    style: TextStyle(color: Colors.red[800], fontSize: 12),
                  ),
                  Text(
                    'Instance kept — download manually or delete it.',
                    style: TextStyle(color: Colors.red[700], fontSize: 12),
                  ),
                ] else if (downloaded)
                  Text(
                    'Saved to ${job.downloadedTo}'
                    '${destroyed ? ' — instance deleted' : ''}',
                    style: TextStyle(color: Colors.green[800], fontSize: 12),
                  )
                else
                  Text(
                    destroyed
                        ? 'Instance deleted — outputs no longer available'
                        : '${job.outputFiles.length} file(s) ready on the instance',
                    style: TextStyle(
                      color: destroyed ? Colors.grey[600] : Colors.green[800],
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          if (downloaded && progress == null) ...[
            TextButton.icon(
              onPressed: () => launchUrl(Uri.file(job.downloadedTo!)),
              icon: const Icon(Icons.folder_open, size: 16),
              label: const Text('Open folder'),
            ),
            const SizedBox(width: 8),
          ],
          JobDownloadButton(job: job),
        ],
      ),
    );
  }

  Widget _buildErrorCard(BuildContext context, RenderJob job) {
    final parsedError = JobErrorParser.parse(job.errorMessage);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, color: Colors.red[700]),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  parsedError,
                  style: TextStyle(
                    color: Colors.red[900],
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () {
                Clipboard.setData(
                    ClipboardData(text: job.errorMessage ?? parsedError));
                ToastUtils.showSuccess(
                  ScaffoldMessenger.of(context),
                  'Error details copied to clipboard',
                );
              },
              icon: Icon(Icons.copy, size: 18, color: Colors.red[900]),
              label: Text(
                'Copy Error Details',
                style: TextStyle(color: Colors.red[900]),
              ),
              style: TextButton.styleFrom(
                backgroundColor: Colors.white.withOpacity(0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(
    BuildContext context,
    String label,
    String value, {
    IconData? icon,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: Colors.grey[600]),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _buildInfoChip(
    BuildContext context,
    IconData icon,
    String label,
    Color bg,
    Color fg,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(BuildContext context, RenderJob job) {
    Color bg;
    Color fg;

    switch (job.status) {
      case LocalJobStatus.completed:
        bg = Colors.green[50]!;
        fg = Colors.green[700]!;
        break;
      case LocalJobStatus.partiallyCompleted:
        bg = Colors.lime[50]!;
        fg = Colors.lime[800]!;
        break;
      case LocalJobStatus.rendering:
      case LocalJobStatus.uploading:
        bg = Colors.blue[50]!;
        fg = Colors.blue[700]!;
        break;
      case LocalJobStatus.creating:
      case LocalJobStatus.starting:
        bg = Colors.orange[50]!;
        fg = Colors.orange[700]!;
        break;
      case LocalJobStatus.failed:
        bg = Colors.red[50]!;
        fg = Colors.red[700]!;
        break;
      case LocalJobStatus.cancelled:
        bg = Colors.grey[100]!;
        fg = Colors.grey[700]!;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: fg.withOpacity(0.2)),
      ),
      child: Text(
        job.statusLabel.toUpperCase(),
        style: TextStyle(color: fg, fontWeight: FontWeight.bold, fontSize: 11),
      ),
    );
  }

  Color _getProviderColor(RenderProvider provider) {
    switch (provider) {
      case RenderProvider.runpodSecure:
      case RenderProvider.runpodCommunity:
        return Colors.purple;
      case RenderProvider.salad:
        return Colors.green;
      case RenderProvider.vast:
      case RenderProvider.vastSecure:
        return Colors.blue;
    }
  }
}

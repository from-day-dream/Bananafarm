import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';
import '../models/draft_job_model.dart';
import '../models/gpu_offer.dart';
import '../models/render_provider.dart';
import '../providers/addon_provider.dart';
import '../providers/draft_job_provider.dart';
import '../providers/jobs_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../utils/toast_utils.dart';
import '../widgets/gpu_selection_modal.dart';
import '../widgets/draft_job_status_badge.dart';

class JobSubmissionScreen extends ConsumerStatefulWidget {
  final String? draftJobId;

  const JobSubmissionScreen({Key? key, this.draftJobId}) : super(key: key);

  @override
  ConsumerState<JobSubmissionScreen> createState() =>
      _JobSubmissionScreenState();
}

class _JobSubmissionScreenState extends ConsumerState<JobSubmissionScreen> {
  bool _isLoading = false;

  /// Job-name field controllers, one per draft card, keyed by draft id.
  final Map<String, TextEditingController> _nameControllers = {};

  @override
  void dispose() {
    for (final controller in _nameControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _nameController(DraftJob job) =>
      _nameControllers.putIfAbsent(
          job.id, () => TextEditingController(text: job.displayName));

  /// Persist the typed name. An empty field reverts to the saved name.
  Future<void> _saveJobName(DraftJob job) async {
    final controller = _nameControllers[job.id];
    if (controller == null) return;
    if (controller.text.trim().isEmpty) {
      controller.text = job.displayName;
      return;
    }
    await ref
        .read(draftJobsProvider.notifier)
        .renameJob(job.id, controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final allDraftJobs = ref.watch(draftJobsProvider);

    // If a specific draft ID is provided, filter to show only that one
    final draftJobs = widget.draftJobId != null
        ? allDraftJobs.where((job) => job.id == widget.draftJobId).toList()
        : allDraftJobs;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.draftJobId != null
              ? 'Configure Job'
              : 'Configure & Submit Jobs',
        ),
        elevation: 0,
        actions: [
          if (widget.draftJobId != null)
            IconButton(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Delete Draft Job?'),
                    content: const Text('This action cannot be undone.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red,
                        ),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );

                if (confirm == true && mounted) {
                  await ref
                      .read(draftJobsProvider.notifier)
                      .deleteDraftJob(widget.draftJobId!);
                  if (mounted) Navigator.pop(context);
                }
              },
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete Draft',
            ),
        ],
      ),
      body: draftJobs.isEmpty
          ? _buildEmptyState(context)
          : _buildJobsList(context, draftJobs, ref),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_upload_outlined, size: 80, color: Colors.grey[400]),
          const SizedBox(height: 24),
          Text(
            'No Draft Jobs',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Jobs from Blender addon will appear here',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back),
            label: const Text('Back to Dashboard'),
          ),
        ],
      ),
    );
  }

  Widget _buildJobsList(
    BuildContext context,
    List<DraftJob> draftJobs,
    WidgetRef ref,
  ) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Draft Jobs (${draftJobs.length})',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        ...draftJobs.map((job) => _buildDraftJobCard(context, job, ref)),
      ],
    );
  }

  Widget _buildDraftJobCard(BuildContext context, DraftJob job, WidgetRef ref) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Details Card
          _buildDetailsCard(context, job),

          const SizedBox(height: 16),

          // GPU Card
          _buildGpuCard(context, job, ref),

          const SizedBox(height: 24),

          // Submit/Queue Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isLoading || job.selectedGpu == null
                  ? null
                  : () async {
                      // Clicking the button doesn't always take focus from
                      // the name field, so save whatever was typed first.
                      await _saveJobName(job);
                      final activeCount =
                          ref.read(activeJobsProvider).length;
                      final maxConcurrent =
                          ref.read(settingsProvider).maxConcurrentJobs;

                      final shouldQueue = activeCount >= maxConcurrent;

                      if (shouldQueue) {
                        await ref
                            .read(draftJobsProvider.notifier)
                            .updateStatus(job.id, DraftJobStatus.queued);
                        if (context.mounted) {
                          ToastUtils.showInfo(
                            ScaffoldMessenger.of(context),
                            'Job Queued: Will start automatically when a slot opens',
                          );
                          Navigator.pop(context);
                        }
                      } else {
                        _submitJob(job, ref);
                      }
                    },
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.black,
              ),
              child: _isLoading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(Colors.white),
                      ),
                    )
                  : const Text(
                      'Submit Job',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),

          // Error message
          if (job.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red[50],
                  border: Border.all(color: Colors.red[300]!),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error, color: Colors.red[600], size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        job.errorMessage!,
                        style: TextStyle(color: Colors.red[700], fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDetailsCard(BuildContext context, DraftJob job) {
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
          _buildJobNameField(context, job),
          const Divider(height: 24),
          _buildDetailRow(context, 'Engine', job.engine),
          const Divider(height: 16),
          _buildDetailRow(context, 'File', job.originalFilename),
          const Divider(height: 16),
          _buildDetailRow(context, 'Device', job.device),
          const Divider(height: 16),
          _buildDetailRow(context, 'Frames', job.framesDisplay),
          const Divider(height: 16),
          _buildDetailRow(context, 'Format', job.outputFormat),
          const Divider(height: 16),
          _buildDetailRow(context, 'Resolution', job.resolution),
          const Divider(height: 16),
          _buildStatusRow(context, job),
        ],
      ),
    );
  }

  Widget _buildJobNameField(BuildContext context, DraftJob job) {
    return Focus(
      // Save when the field loses focus, not on every keystroke.
      onFocusChange: (hasFocus) {
        if (!hasFocus) _saveJobName(job);
      },
      child: TextField(
        controller: _nameController(job),
        enabled: job.status != DraftJobStatus.zipping,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _saveJobName(job),
        decoration: const InputDecoration(
          labelText: 'Job name',
          helperText: 'Also the name of the download folder',
          isDense: true,
          border: OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _buildStatusRow(BuildContext context, DraftJob job) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'Status',
          style: TextStyle(
            color: Colors.grey[600],
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        DraftJobStatusBadge(status: job.status, errorMessage: job.errorMessage),
      ],
    );
  }

  Widget _buildDetailRow(BuildContext context, String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey[600],
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildGpuCard(BuildContext context, DraftJob job, WidgetRef ref) {
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
              const Text(
                'GPU Configuration',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              if (job.selectedGpu?.pricePerHour != null)
                Text(
                  '\$${job.selectedGpu!.pricePerHour!.toStringAsFixed(2)}/hr',
                  style: TextStyle(
                    color: Colors.green[600],
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (job.selectedGpu != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).cardTheme.color, // Use surface color
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.withOpacity(0.2)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.memory, color: AppTheme.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          job.selectedGpu!.gpuName,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          '${job.selectedGpu!.provider.label}'
                          '${job.selectedGpu!.memoryGb != null ? ' • ${job.selectedGpu!.memoryGb} GB VRAM' : ''}',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: job.status == DraftJobStatus.zipping
                        ? null
                        : () => _showGPUSelectionModal(context, job, ref),
                    icon: const Icon(Icons.edit, size: 20),
                    color: Colors.grey[600],
                  ),
                ],
              ),
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color:
                    Theme.of(context).cardTheme.color?.withOpacity(0.5) ??
                    Colors.grey.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(context).dividerColor.withOpacity(0.2),
                ),
              ),
              child: Column(
                children: [
                  Icon(
                    Icons.memory,
                    size: 48,
                    color:
                        Theme.of(context).iconTheme.color?.withOpacity(0.3) ??
                        Colors.grey[300],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'No GPU Selected',
                    style: TextStyle(
                      color: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.color?.withOpacity(0.6),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: job.status == DraftJobStatus.zipping
                        ? null
                        : () => _showGPUSelectionModal(context, job, ref),
                    icon: const Icon(Icons.add),
                    label: const Text('Select GPU'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.black,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showGPUSelectionModal(
    BuildContext context,
    DraftJob job,
    WidgetRef ref,
  ) async {
    final selectedGpu = await showDialog<GpuOffer>(
      context: context,
      builder: (context) =>
          GpuSelectionModal(jobId: job.id, initialSelection: job.selectedGpu),
    );

    if (selectedGpu != null && mounted) {
      await ref
          .read(draftJobsProvider.notifier)
          .selectGPUForJob(job.id, selectedGpu);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('GPU selected: ${selectedGpu.gpuName}'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _submitJob(DraftJob job, WidgetRef ref) async {
    if (job.selectedGpu == null) {
      ToastUtils.showError(
        ScaffoldMessenger.of(context),
        'Please select a GPU configuration',
      );
      return;
    }

    // Validate file exists locally before starting
    final file = File(job.blendFilePath);
    if (!await file.exists()) {
      ToastUtils.showError(
        ScaffoldMessenger.of(context),
        'Error: Source file not found. Please resend from Blender.',
      );
      return;
    }

    setState(() => _isLoading = true);

    // Rent the GPU instance; upload and render tracking continue in the
    // background via the RenderJobManager once the instance is up.
    await ref
        .read(addonConnectionStatusProvider.notifier)
        .submitDraftJob(job.id);

    if (!mounted) return;
    setState(() => _isLoading = false);

    // On success the draft is removed; on failure it stays with an error.
    final remaining =
        ref.read(draftJobsProvider.notifier).getDraftJob(job.id);
    if (remaining == null) {
      ToastUtils.showSuccess(
        ScaffoldMessenger.of(context),
        'Instance created — uploading and rendering in the background',
      );
      Navigator.of(context).pop();
    } else {
      ToastUtils.showError(
        ScaffoldMessenger.of(context),
        remaining.errorMessage ?? 'Failed to submit job',
      );
    }
  }
}

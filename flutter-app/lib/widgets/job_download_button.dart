import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/job_model.dart';
import '../services/render_job_manager.dart';
import '../utils/toast_utils.dart';

/// Downloads a completed job's outputs straight from the GPU instance
/// (single image/video file, or the auto-zipped image sequence archive).
///
/// Shows the same progress whether the download was started here or by the
/// "Auto download & delete instance" flow, and a red icon with the reason
/// when the last attempt failed. Disabled once the instance has been
/// deleted — the files live only there.
class JobDownloadButton extends ConsumerWidget {
  final RenderJob job;

  const JobDownloadButton({required this.job, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!job.isCompleted) return const SizedBox.shrink();

    if (job.instanceDestroyed) {
      final downloaded = job.downloadState == DownloadState.downloaded;
      return Tooltip(
        message: downloaded
            ? 'Downloaded to ${job.downloadedTo}'
            : 'Instance deleted — outputs are no longer available',
        child: _box(
          context,
          Icon(
            downloaded ? Icons.download_done : Icons.file_download_off,
            size: 18,
            color: Colors.grey[500],
          ),
        ),
      );
    }

    if (job.outputFiles.isEmpty) return const SizedBox.shrink();

    final progress =
        ref.watch(downloadProgressProvider.select((m) => m[job.id]));
    if (progress != null) {
      return Tooltip(
        message: 'Downloading… ${(progress * 100).round()}%',
        child: _box(
          context,
          Padding(
            padding: const EdgeInsets.all(8),
            child: CircularProgressIndicator(
              value: progress > 0 ? progress : null,
              strokeWidth: 2,
            ),
          ),
        ),
      );
    }

    final failed = job.downloadState == DownloadState.failed;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Tooltip(
      message: failed
          ? 'Download failed: ${job.downloadError ?? 'unknown error'}. '
              'Click to try again.'
          : 'Download Output',
      child: _box(
        context,
        IconButton(
          onPressed: () => _download(context, ref),
          icon: Icon(
            failed ? Icons.error_outline : Icons.download,
            size: 18,
            color: failed
                ? Colors.red[400]
                : (isDark ? Colors.grey[300] : Colors.black),
          ),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      ),
    );
  }

  Future<void> _download(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final folder =
          await ref.read(renderJobManagerProvider).downloadOutputs(job.id);
      ToastUtils.showSuccess(messenger, 'Downloaded to: $folder');
    } catch (e) {
      ToastUtils.showError(
        messenger,
        'Download failed: ${e is StateError ? e.message : e}',
      );
    }
  }

  Widget _box(BuildContext context, Widget child) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[900] : Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(child: child),
    );
  }
}

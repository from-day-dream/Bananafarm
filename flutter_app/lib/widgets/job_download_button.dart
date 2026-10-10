import 'package:flutter/material.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/job_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/settings_provider.dart';
import '../services/instance_api_service.dart';
import '../utils/toast_utils.dart';

/// Downloads a completed job's outputs straight from the GPU instance
/// (single image/video file, or the auto-zipped image sequence archive).
/// Disabled once the instance has been deleted — the files live only there.
class JobDownloadButton extends ConsumerStatefulWidget {
  final RenderJob job;
  final VoidCallback? onDownloadStart;
  final VoidCallback? onDownloadComplete;

  const JobDownloadButton({
    required this.job,
    this.onDownloadStart,
    this.onDownloadComplete,
    Key? key,
  }) : super(key: key);

  @override
  ConsumerState<JobDownloadButton> createState() => _JobDownloadButtonState();
}

class _JobDownloadButtonState extends ConsumerState<JobDownloadButton> {
  bool isDownloading = false;
  double downloadProgress = 0.0;

  @override
  Widget build(BuildContext context) {
    // Only show for completed jobs
    if (!widget.job.isCompleted) {
      return const SizedBox.shrink();
    }

    if (widget.job.instanceDestroyed) {
      return Tooltip(
        message: 'Instance deleted — outputs are no longer available',
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: Colors.grey.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(Icons.file_download_off, size: 18, color: Colors.grey[500]),
        ),
      );
    }

    if (widget.job.outputFiles.isEmpty) {
      return const SizedBox.shrink();
    }

    return isDownloading
        ? _buildDownloadingState(context)
        : _buildReadyState(context);
  }

  Widget _buildReadyState(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[900] : Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
      ),
      child: IconButton(
        onPressed: () => _downloadFiles(context),
        icon: Icon(
          Icons.download,
          size: 18,
          color: isDark ? Colors.grey[700] : Colors.black,
        ),
        tooltip: 'Download Output',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      ),
    );
  }

  Widget _buildDownloadingState(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[800] : Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(8),
      child: CircularProgressIndicator(
        value: downloadProgress > 0 ? downloadProgress : null,
        strokeWidth: 2,
        valueColor: AlwaysStoppedAnimation<Color>(
          isDark ? Colors.white : Colors.black,
        ),
      ),
    );
  }

  Future<void> _downloadFiles(BuildContext context) async {
    try {
      widget.onDownloadStart?.call();

      setState(() {
        isDownloading = true;
        downloadProgress = 0.0;
      });

      // Get download directory from settings or default
      final settings = ref.read(settingsProvider);
      String downloadPath = settings.downloadPath ?? '';

      if (downloadPath.isEmpty) {
        final directory = await getDownloadsDirectory();
        if (directory == null) {
          throw Exception('Could not access downloads directory');
        }
        downloadPath = directory.path;
      }

      // Create job subfolder
      final jobDir = Directory('$downloadPath/${widget.job.id}');
      if (!await jobDir.exists()) {
        await jobDir.create(recursive: true);
      }

      final instanceApi = InstanceApiService();
      final files = widget.job.outputFiles;
      final totalBytes =
          files.fold<int>(0, (sum, f) => sum + f.size).clamp(1, 1 << 62);
      var downloadedBytes = 0;

      String lastPath = jobDir.path;
      for (final file in files) {
        final filePath = _uniquePath(jobDir.path, file.name);
        await instanceApi.downloadOutput(
          widget.job,
          file.name,
          filePath,
          onProgress: (received, total) {
            if (mounted) {
              setState(() {
                downloadProgress = (downloadedBytes + received) / totalBytes;
              });
            }
          },
        );
        downloadedBytes += file.size;
        lastPath = filePath;
      }

      if (mounted) {
        setState(() {
          isDownloading = false;
          downloadProgress = 0.0;
        });
      }

      widget.onDownloadComplete?.call();

      if (context.mounted) {
        ToastUtils.showSuccess(
          ScaffoldMessenger.of(context),
          files.length == 1
              ? 'Downloaded to: $lastPath'
              : 'Downloaded ${files.length} files to: ${jobDir.path}',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          isDownloading = false;
          downloadProgress = 0.0;
        });
      }

      if (context.mounted) {
        ToastUtils.showError(
            ScaffoldMessenger.of(context), 'Download failed: $e');
      }
    }
  }

  String _uniquePath(String dir, String fileName) {
    String filePath = '$dir/$fileName';
    int counter = 1;
    while (File(filePath).existsSync()) {
      final dotIndex = fileName.lastIndexOf('.');
      if (dotIndex != -1) {
        final name = fileName.substring(0, dotIndex);
        final ext = fileName.substring(dotIndex);
        filePath = '$dir/${name}_$counter$ext';
      } else {
        filePath = '$dir/${fileName}_$counter';
      }
      counter++;
    }
    return filePath;
  }
}

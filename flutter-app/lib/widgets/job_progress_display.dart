import 'package:flutter/material.dart';

/// Displays real-time rendering progress and statistics
class JobProgressDisplay extends StatelessWidget {
  /// Progress percentage (0.0 to 100.0)
  final double percentage;

  /// Current frame number being rendered
  final int currentFrame;

  /// Total number of frames to render
  final int totalFrames;

  /// Status message (e.g., "Rendering frame 45/250")
  final String statusMessage;

  /// Error message if any
  final String? error;

  /// Whether data is still loading
  final bool loading;

  /// Custom styling class name
  final String? className;

  /// Whether this is an animation render
  final bool isAnimation;

  /// Number of tiles rendered (for still images)
  final int tilesDone;

  /// Total number of tiles (for still images)
  final int totalTiles;

  const JobProgressDisplay({
    required this.percentage,
    required this.currentFrame,
    required this.totalFrames,
    required this.statusMessage,
    this.error,
    this.loading = false,
    this.className,
    this.isAnimation = false,
    this.tilesDone = 0,
    this.totalTiles = 0,
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Column(
        children: [
          const SizedBox(height: 12),
          const SizedBox(
            height: 30,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 12),
          Text(
            'Loading progress...',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.grey.shade500,
            ),
          ),
        ],
      );
    }

    if (error != null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          border: Border.all(color: Colors.red.shade200),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.error, color: Colors.red.shade600, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Progress Error',
                    style: TextStyle(
                      color: Colors.red.shade700,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    error!,
                    style: TextStyle(
                      color: Colors.red.shade600,
                      fontSize: 12,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (percentage == 0 && statusMessage.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                statusMessage,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '${percentage.toStringAsFixed(1)}%',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Progress bar
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: percentage / 100.0,
            minHeight: 10,
            backgroundColor: Colors.grey.shade200,
            valueColor: AlwaysStoppedAnimation<Color>(
              _getProgressColor(percentage),
            ),
          ),
        ),
        const SizedBox(height: 8),

        // Frame info
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Progress',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _getProgressText(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _getProgressText() {
    if (!isAnimation) {
      if (totalTiles > 0) {
        return 'Tile $tilesDone / ${totalTiles - 1} (${percentage.toStringAsFixed(1)}%)';
      }
      return '${percentage.toStringAsFixed(1)}%';
    }
    return totalFrames > 0
        ? 'Frame $currentFrame / $totalFrames'
        : 'Preparing...';
  }

  /// Get progress bar color based on percentage
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
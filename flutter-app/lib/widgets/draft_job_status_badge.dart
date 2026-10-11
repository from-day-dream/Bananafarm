import 'package:flutter/material.dart';
import '../models/draft_job_model.dart';

class DraftJobStatusBadge extends StatelessWidget {
  final DraftJobStatus status;
  final String? errorMessage;

  const DraftJobStatusBadge({Key? key, required this.status, this.errorMessage})
    : super(key: key);

  @override
  Widget build(BuildContext context) {
    Color color;
    String text;
    IconData? icon;

    switch (status) {
      case DraftJobStatus.submitted:
        color = Colors.amber;
        text = 'SUBMITTED';
        break;
      case DraftJobStatus.zipping:
        color = Colors.orange;
        text = 'ZIPPING';
        break;
      case DraftJobStatus.ready:
        color = Colors.blue;
        text = 'READY';
        break;
      case DraftJobStatus.paused:
        color = Colors.grey;
        text = 'PAUSED';
        break;
      case DraftJobStatus.queued:
        color = Colors.purple;
        text = 'QUEUED';
        break;
      case DraftJobStatus.error:
        color = Colors.red;
        text = 'ERROR';
        icon = Icons.info_outline;
        break;
    }

    Widget badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(4),
        color: color.withOpacity(0.1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          if (status == DraftJobStatus.zipping) ...[
            const SizedBox(width: 6),
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
            ),
          ] else if (icon != null) ...[
            const SizedBox(width: 4),
            Icon(icon, size: 12, color: color),
          ],
        ],
      ),
    );

    if (status == DraftJobStatus.error && errorMessage != null) {
      return Tooltip(
        message: errorMessage!,
        padding: const EdgeInsets.all(8),
        margin: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.red.shade700,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(color: Colors.white),
        child: badge,
      );
    }

    return badge;
  }
}

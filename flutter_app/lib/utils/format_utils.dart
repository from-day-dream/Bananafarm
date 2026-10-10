class FormatUtils {
  static String formatCurrency(double value) {
    return '\$$value';
  }

  static String formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  static String formatDateTime(DateTime date) {
    return '${formatDate(date)} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  static String formatJobStatus(String status) {
    switch (status.toLowerCase()) {
      case 'initialising':
      case 'initializing':
        return 'Initializing';
      case 'uploading':
        return 'Uploading';
      case 'queued':
        return 'Queued';
      case 'starting_render':
      case 'startingrender':
        return 'Starting Render';
      case 'rendering':
        return 'Rendering';
      case 'stopping':
        return 'Stopping';
      case 'uploading_output':
      case 'uploadingoutput':
        return 'Uploading Output';
      case 'terminating':
        return 'Terminating';
      case 'completed':
        return 'Completed';
      case 'partially_completed':
      case 'partiallycompleted':
        return 'Partially Completed';
      case 'failed':
        return 'Failed';
      case 'cancelled':
        return 'Cancelled';
      default:
        return status
            .replaceAll('_', ' ')
            .split(' ')
            .map(
              (word) => word[0].toUpperCase() + word.substring(1).toLowerCase(),
            )
            .join(' ');
    }
  }

  static String formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '$hours h $minutes m $seconds s';
    } else if (minutes > 0) {
      return '$minutes m $seconds s';
    } else {
      return '$seconds s';
    }
  }

}

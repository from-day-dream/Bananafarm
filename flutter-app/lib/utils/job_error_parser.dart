class JobErrorParser {
  static String parse(String? error) {
    if (error == null || error.isEmpty) {
      return 'Unknown error occurred';
    }

    final lowerError = error.toLowerCase();

    // Credit related
    if (lowerError.contains('insufficient credit') ||
        lowerError.contains('insufficient balance') ||
        lowerError.contains('payment required')) {
      return 'Insufficient credits to complete the job';
    }

    // Resource/GPU related
    if (lowerError.contains('no gpu available') ||
        lowerError.contains('capacity reached') ||
        lowerError.contains('out of stock')) {
      return 'Selected GPU is currently unavailable';
    }

    // Docker/System related
    if (lowerError.contains('docker') ||
        lowerError.contains('container') ||
        lowerError.contains('image pull failed')) {
      return 'System configuration error';
    }

    if (lowerError.contains('out of memory') || lowerError.contains('oom')) {
      return 'Out of memory (OOM)';
    }

    // Timeouts
    if (lowerError.contains('timeout') || lowerError.contains('timed out')) {
      return 'Operation timed out';
    }

    // File/Storage related
    if (lowerError.contains('file not found') ||
        lowerError.contains('no such file')) {
      return 'Missing source files';
    }

    // Blender specific
    if (lowerError.contains('blender quit') ||
        lowerError.contains('segmentation fault')) {
      return 'Blender crashed unexpectedly';
    }

    // Generic fallback for very long messages
    if (error.length > 50) {
      return 'Job failed during processing';
    }

    return error;
  }
}

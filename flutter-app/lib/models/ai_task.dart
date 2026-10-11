import 'package:path/path.dart' as p;

/// Image formats the Lab will accept as input.
const kImageExtensions = {'.png', '.jpg', '.jpeg', '.webp'};

/// Video containers the Lab will accept as input.
const kVideoExtensions = {'.mp4', '.mov', '.mkv', '.avi', '.webm'};

bool isImageFile(String path) =>
    kImageExtensions.contains(p.extension(path).toLowerCase());

bool isVideoFile(String path) =>
    kVideoExtensions.contains(p.extension(path).toLowerCase());

/// What the Lab is being asked to do.
enum AiTaskKind {
  /// Upscale one or more images with Real-ESRGAN.
  upscale,

  /// Interpolate a numbered image sequence with RIFE.
  interpolateSequence,

  /// Interpolate a video: ffmpeg extract, RIFE, ffmpeg re-encode.
  interpolateVideo,
}

extension AiTaskKindX on AiTaskKind {
  String get label {
    switch (this) {
      case AiTaskKind.upscale:
        return 'Upscale';
      case AiTaskKind.interpolateSequence:
        return 'Interpolate Sequence';
      case AiTaskKind.interpolateVideo:
        return 'Interpolate Video';
    }
  }
}

/// A progress tick from a running task.
///
/// Shaped like `RenderProgressSnapshot` so the Lab UI reads the same way as
/// the render pipeline's.
class AiTaskProgress {
  /// 0..1, or null when the total isn't known yet (indeterminate).
  final double? fraction;
  final int currentFrame;
  final int totalFrames;
  final String statusMessage;

  const AiTaskProgress({
    this.fraction,
    this.currentFrame = 0,
    this.totalFrames = 0,
    required this.statusMessage,
  });

  bool get isIndeterminate => fraction == null;
}

/// Settings for an upscale run.
class UpscaleParams {
  /// Real-ESRGAN accepts 2, 3 or 4.
  final int scale;
  final String model;

  const UpscaleParams({this.scale = 4, this.model = 'realesrgan-x4plus'});
}

/// Settings for an interpolation run.
class InterpolateParams {
  /// Frame multiplier — 2 doubles the frame count.
  final int factor;
  final String model;

  /// Output fps for video. Null means source fps * [factor].
  final double? targetFps;

  const InterpolateParams({
    this.factor = 2,
    this.model = 'rife-v4.6',
    this.targetFps,
  });
}

/// What a finished task produced.
class AiTaskResult {
  final String outputPath;
  final int fileCount;

  const AiTaskResult({required this.outputPath, this.fileCount = 1});
}

/// Raised when a task fails, carrying the tail of the process log so the UI
/// can show something more useful than a non-zero exit code.
class AiTaskException implements Exception {
  final String message;
  final String? log;

  AiTaskException(this.message, {this.log});

  @override
  String toString() => message;
}

import 'gpu_offer.dart';
import 'render_provider.dart';
import '../constants/app_constants.dart';

/// Client-side lifecycle of a render job, fully managed by this app.
enum LocalJobStatus {
  /// Provider create-instance call in flight.
  creating,

  /// Instance exists; waiting for it to boot and the container API to answer.
  starting,

  /// Uploading the project zip to the instance.
  uploading,

  /// Container is extracting/rendering/zipping.
  rendering,

  completed,
  partiallyCompleted,
  failed,
  cancelled,
}

extension LocalJobStatusX on LocalJobStatus {
  String get label {
    switch (this) {
      case LocalJobStatus.creating:
        return 'Creating Instance';
      case LocalJobStatus.starting:
        return 'Starting Instance';
      case LocalJobStatus.uploading:
        return 'Uploading Project';
      case LocalJobStatus.rendering:
        return 'Rendering';
      case LocalJobStatus.completed:
        return 'Completed';
      case LocalJobStatus.partiallyCompleted:
        return 'Partially Completed';
      case LocalJobStatus.failed:
        return 'Failed';
      case LocalJobStatus.cancelled:
        return 'Cancelled';
    }
  }
}

/// Snapshot of the container's /progress response.
class RenderProgressSnapshot {
  final double progressPercent;
  final int currentFrame;
  final int totalFrames;
  final int currentSample;
  final int totalSamples;
  final int tilesDone;
  final int totalTiles;
  final String statusMessage;

  RenderProgressSnapshot({
    this.progressPercent = 0,
    this.currentFrame = 0,
    this.totalFrames = 0,
    this.currentSample = 0,
    this.totalSamples = 0,
    this.tilesDone = 0,
    this.totalTiles = 0,
    this.statusMessage = '',
  });

  factory RenderProgressSnapshot.fromJson(Map<String, dynamic> json) {
    return RenderProgressSnapshot(
      progressPercent: (json['progress_percent'] as num?)?.toDouble() ?? 0,
      currentFrame: (json['current_frame'] as num?)?.toInt() ?? 0,
      totalFrames: (json['total_frames'] as num?)?.toInt() ?? 0,
      currentSample: (json['current_sample'] as num?)?.toInt() ?? 0,
      totalSamples: (json['total_samples'] as num?)?.toInt() ?? 0,
      tilesDone: (json['tiles_done'] as num?)?.toInt() ?? 0,
      totalTiles: (json['total_tiles'] as num?)?.toInt() ?? 0,
      statusMessage: json['status_message'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'progress_percent': progressPercent,
        'current_frame': currentFrame,
        'total_frames': totalFrames,
        'current_sample': currentSample,
        'total_samples': totalSamples,
        'tiles_done': tilesDone,
        'total_tiles': totalTiles,
        'status_message': statusMessage,
      };
}

/// One downloadable render output on the instance.
class OutputFileInfo {
  final String name;
  final int size;
  final bool isArchive;

  OutputFileInfo({required this.name, required this.size, this.isArchive = false});

  factory OutputFileInfo.fromJson(Map<String, dynamic> json) => OutputFileInfo(
        name: json['name'] as String,
        size: (json['size'] as num?)?.toInt() ?? 0,
        isArchive: json['is_archive'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() =>
      {'name': name, 'size': size, 'is_archive': isArchive};
}

/// A render job orchestrated entirely by this app: it owns the provider
/// instance and talks to the render container directly. Persisted locally.
class RenderJob {
  final String id;
  final LocalJobStatus status;
  final RenderProvider provider;
  final String gpuName;

  /// Display-only price snapshot from the offer at submit time — the
  /// provider bills the user directly.
  final double? pricePerHour;

  /// The full offer this job was rented with, kept so a retry can rent the
  /// same GPU without re-querying the provider (`gpuName` alone is a display
  /// string — every provider needs the `gpuId`). Null on jobs saved before
  /// retry existed.
  final GpuOffer? gpuOffer;

  /// vast contract id / runpod pod id / salad container group id.
  final String? instanceId;

  /// Salad container group name (needed for its GET/DELETE calls).
  final String? instanceName;

  /// Base URL of the container's control API once discovered.
  final String? instanceEndpoint;

  /// Per-job bearer token for the container API.
  final String apiToken;

  /// Local project zip, kept until the container starts rendering so an
  /// interrupted upload can resume after an app restart.
  final String? projectZipPath;

  final String blenderVersion;
  final RenderParams renderParams;
  final RenderProgressSnapshot? progress;
  final List<OutputFileInfo> outputFiles;

  /// True once the user has deleted the provider instance; outputs are no
  /// longer downloadable after that.
  final bool instanceDestroyed;

  final String? errorMessage;
  final DateTime createdAt;
  final DateTime? completedAt;

  RenderJob({
    required this.id,
    required this.status,
    required this.provider,
    required this.gpuName,
    this.pricePerHour,
    this.gpuOffer,
    this.instanceId,
    this.instanceName,
    this.instanceEndpoint,
    required this.apiToken,
    this.projectZipPath,
    required this.blenderVersion,
    required this.renderParams,
    this.progress,
    this.outputFiles = const [],
    this.instanceDestroyed = false,
    this.errorMessage,
    required this.createdAt,
    this.completedAt,
  });

  bool get isActive =>
      status == LocalJobStatus.creating ||
      status == LocalJobStatus.starting ||
      status == LocalJobStatus.uploading ||
      status == LocalJobStatus.rendering;

  bool get isCompleted =>
      status == LocalJobStatus.completed ||
      status == LocalJobStatus.partiallyCompleted;

  bool get isFailed => status == LocalJobStatus.failed;

  bool get isCancelled => status == LocalJobStatus.cancelled;

  /// A live instance the user still pays for and must delete manually.
  bool get hasLiveInstance => instanceId != null && !instanceDestroyed;

  bool get canDownload =>
      isCompleted && hasLiveInstance && outputFiles.isNotEmpty;

  /// A failed job can be re-run on the *same* GPU only if we still know which
  /// GPU to rent and still hold the project zip — the finalize path keeps both
  /// on failure.
  bool get canRetry => canRepickGpu && gpuOffer != null;

  /// A failed job can be re-run on a *different* GPU as long as the project zip
  /// survives. Unlike [canRetry] this does not need the original offer, so jobs
  /// persisted before `gpuOffer` existed stay recoverable by picking a new GPU.
  bool get canRepickGpu =>
      isFailed && projectZipPath != null && projectZipPath!.isNotEmpty;

  Duration? get duration =>
      completedAt != null ? completedAt!.difference(createdAt) : null;

  String get statusLabel => status.label;

  RenderJob copyWith({
    LocalJobStatus? status,
    String? instanceId,
    String? instanceName,
    String? instanceEndpoint,
    String? projectZipPath,
    bool clearProjectZipPath = false,
    RenderProgressSnapshot? progress,
    List<OutputFileInfo>? outputFiles,
    bool? instanceDestroyed,
    String? errorMessage,
    DateTime? completedAt,
  }) {
    return RenderJob(
      id: id,
      status: status ?? this.status,
      provider: provider,
      gpuName: gpuName,
      pricePerHour: pricePerHour,
      gpuOffer: gpuOffer,
      instanceId: instanceId ?? this.instanceId,
      instanceName: instanceName ?? this.instanceName,
      instanceEndpoint: instanceEndpoint ?? this.instanceEndpoint,
      apiToken: apiToken,
      projectZipPath:
          clearProjectZipPath ? null : (projectZipPath ?? this.projectZipPath),
      blenderVersion: blenderVersion,
      renderParams: renderParams,
      progress: progress ?? this.progress,
      outputFiles: outputFiles ?? this.outputFiles,
      instanceDestroyed: instanceDestroyed ?? this.instanceDestroyed,
      errorMessage: errorMessage ?? this.errorMessage,
      createdAt: createdAt,
      completedAt: completedAt ?? this.completedAt,
    );
  }

  factory RenderJob.fromJson(Map<String, dynamic> json) {
    return RenderJob(
      id: json['id'] as String,
      status: LocalJobStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => LocalJobStatus.failed,
      ),
      provider: RenderProviderX.fromId(json['provider'] as String),
      gpuName: json['gpu_name'] as String? ?? 'Unknown',
      pricePerHour: (json['price_per_hour'] as num?)?.toDouble(),
      gpuOffer: json['gpu_offer'] != null
          ? GpuOffer.fromJson((json['gpu_offer'] as Map).cast<String, dynamic>())
          : null,
      instanceId: json['instance_id'] as String?,
      instanceName: json['instance_name'] as String?,
      instanceEndpoint: json['instance_endpoint'] as String?,
      apiToken: json['api_token'] as String? ?? '',
      projectZipPath: json['project_zip_path'] as String?,
      blenderVersion: (json['blender_version'] as String?)?.trim().isNotEmpty
              == true
          ? (json['blender_version'] as String).trim()
          : AppConstants.defaultBlenderVersion,
      renderParams: RenderParams.fromJson(
          (json['render_params'] as Map?)?.cast<String, dynamic>() ?? {}),
      progress: json['progress'] != null
          ? RenderProgressSnapshot.fromJson(
              (json['progress'] as Map).cast<String, dynamic>())
          : null,
      outputFiles: (json['output_files'] as List? ?? [])
          .map((f) => OutputFileInfo.fromJson((f as Map).cast<String, dynamic>()))
          .toList(),
      instanceDestroyed: json['instance_destroyed'] as bool? ?? false,
      errorMessage: json['error_message'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      completedAt: json['completed_at'] != null
          ? DateTime.parse(json['completed_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'status': status.name,
        'provider': provider.id,
        'gpu_name': gpuName,
        'price_per_hour': pricePerHour,
        'gpu_offer': gpuOffer?.toJson(),
        'instance_id': instanceId,
        'instance_name': instanceName,
        'instance_endpoint': instanceEndpoint,
        'api_token': apiToken,
        'project_zip_path': projectZipPath,
        'blender_version': blenderVersion,
        'render_params': renderParams.toJson(),
        'progress': progress?.toJson(),
        'output_files': outputFiles.map((f) => f.toJson()).toList(),
        'instance_destroyed': instanceDestroyed,
        'error_message': errorMessage,
        'created_at': createdAt.toIso8601String(),
        'completed_at': completedAt?.toIso8601String(),
      };
}

class RenderParams {
  final int frameStart;
  final int frameEnd;
  final int currentFrame;
  final String resolution;
  final int samples;
  final String engine;
  final String? outputFormat;
  final String? cyclesDevice;
  final bool isAnimationRender;
  final bool isVideoOutput;
  final bool isImageSequence;
  final String? originalFilename;

  RenderParams({
    required this.frameStart,
    required this.frameEnd,
    required this.currentFrame,
    required this.resolution,
    required this.samples,
    required this.engine,
    this.outputFormat,
    this.cyclesDevice,
    this.isAnimationRender = false,
    this.isVideoOutput = false,
    this.isImageSequence = false,
    this.originalFilename,
  });

  factory RenderParams.fromJson(Map<String, dynamic> json) {
    return RenderParams(
      frameStart: json['frame_start'] as int? ?? 1,
      frameEnd: json['frame_end'] as int? ?? 1,
      currentFrame: json['current_frame'] as int? ?? 1,
      resolution: json['resolution'] as String? ?? '1920x1080',
      samples: json['samples'] as int? ?? 128,
      engine: json['engine'] as String? ?? 'CYCLES',
      outputFormat: json['output_format'] as String?,
      cyclesDevice: json['cycles_device'] as String?,
      isAnimationRender: json['is_animation_render'] as bool? ?? false,
      isVideoOutput: json['is_video_output'] as bool? ?? false,
      isImageSequence: json['is_image_sequence'] as bool? ?? false,
      originalFilename: json['original_filename'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'frame_start': frameStart,
        'frame_end': frameEnd,
        'current_frame': currentFrame,
        'resolution': resolution,
        'samples': samples,
        'engine': engine,
        'output_format': outputFormat,
        'cycles_device': cyclesDevice,
        'is_animation_render': isAnimationRender,
        'is_video_output': isVideoOutput,
        'is_image_sequence': isImageSequence,
        'original_filename': originalFilename,
      };

  bool get isAnimation => isAnimationRender;

  int get width {
    final parts = resolution.split('x');
    if (parts.length == 2) {
      return int.tryParse(parts[0]) ?? 1920;
    }
    return 1920;
  }

  int get height {
    final parts = resolution.split('x');
    if (parts.length == 2) {
      return int.tryParse(parts[1]) ?? 1080;
    }
    return 1080;
  }
}

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

  /// Frames fully rendered so far. 0 from render image builds that
  /// predate the progress reporter, which did not report it.
  final int framesDone;
  final int currentSample;
  final int totalSamples;
  final int tilesDone;
  final int totalTiles;
  final String statusMessage;

  RenderProgressSnapshot({
    this.progressPercent = 0,
    this.currentFrame = 0,
    this.totalFrames = 0,
    this.framesDone = 0,
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
      framesDone: (json['frames_done'] as num?)?.toInt() ?? 0,
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
        'frames_done': framesDone,
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

  /// Checksum computed by the container, used to verify a download before
  /// the instance (the only copy) is deleted. Null from older images, which
  /// are verified by size alone.
  final String? sha256;

  OutputFileInfo({
    required this.name,
    required this.size,
    this.isArchive = false,
    this.sha256,
  });

  factory OutputFileInfo.fromJson(Map<String, dynamic> json) => OutputFileInfo(
        name: json['name'] as String,
        size: (json['size'] as num?)?.toInt() ?? 0,
        isArchive: json['is_archive'] as bool? ?? false,
        sha256: json['sha256'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'size': size,
        'is_archive': isArchive,
        'sha256': sha256,
      };
}

/// Where a finished job's outputs are in getting to this machine.
enum DownloadState { none, downloading, downloaded, failed }

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

  /// When the provider instance was rented — billing starts here.
  final DateTime? instanceCreatedAt;

  /// When the instance was deleted — billing stops here. Set automatically
  /// by [copyWith] when [instanceDestroyed] flips to true.
  final DateTime? instanceDestroyedAt;

  /// The instance's actual $/hr as reported by the provider once rented.
  /// [pricePerHour] is the offer shown before renting and can differ.
  final double? ratePerHour;

  /// Progress of getting the outputs onto this machine, automatically or by
  /// the download button.
  final DownloadState downloadState;

  /// Folder the outputs were saved to, once downloaded.
  final String? downloadedTo;

  /// Why the last download failed, shown until the next attempt.
  final String? downloadError;

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
    this.instanceCreatedAt,
    this.instanceDestroyedAt,
    this.ratePerHour,
    this.downloadState = DownloadState.none,
    this.downloadedTo,
    this.downloadError,
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

  /// A failed or cancelled job can be retried while its project zip survives.
  /// Retry reopens the submission page, where the previous GPU is preselected
  /// if known and can be changed, so the original offer is not required.
  bool get canRetry =>
      (isFailed || isCancelled) &&
      projectZipPath != null &&
      projectZipPath!.isNotEmpty;

  /// Still waiting for its instance well past a normal boot — the user is
  /// offered logs and a way back to GPU selection.
  bool isSlowToStart(DateTime now) =>
      status == LocalJobStatus.starting &&
      now.difference(instanceCreatedAt ?? createdAt) >=
          AppConstants.slowStartWarning;

  Duration? get duration =>
      completedAt != null ? completedAt!.difference(createdAt) : null;

  String get statusLabel => status.label;

  /// The best known hourly rate: the provider's reported rate once rented,
  /// otherwise the offer price.
  double? get effectiveRatePerHour => ratePerHour ?? pricePerHour;

  /// Instance cost so far: rate × time from rental to deletion (or [now]).
  /// Null when the rental time or rate is unknown, e.g. for jobs saved
  /// before cost tracking existed.
  double? costSoFar(DateTime now) {
    final start = instanceCreatedAt;
    final rate = effectiveRatePerHour;
    if (start == null || rate == null) return null;
    final end = instanceDestroyedAt ?? now;
    final hours = end.difference(start).inMilliseconds / Duration.millisecondsPerHour;
    return hours <= 0 ? 0 : rate * hours;
  }

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
    DateTime? instanceCreatedAt,
    double? ratePerHour,
    DownloadState? downloadState,
    String? downloadedTo,
    String? downloadError,
    bool clearDownloadError = false,
    String? errorMessage,
    DateTime? completedAt,
  }) {
    final destroyed = instanceDestroyed ?? this.instanceDestroyed;
    final createdInstanceAt = instanceCreatedAt ?? this.instanceCreatedAt;
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
      instanceDestroyed: destroyed,
      instanceCreatedAt: createdInstanceAt,
      // Every destroy path goes through copyWith(instanceDestroyed: true), so
      // stamping here stops the cost clock without touching each of them.
      instanceDestroyedAt: instanceDestroyedAt ??
          (destroyed && createdInstanceAt != null ? DateTime.now() : null),
      ratePerHour: ratePerHour ?? this.ratePerHour,
      downloadState: downloadState ?? this.downloadState,
      downloadedTo: downloadedTo ?? this.downloadedTo,
      downloadError:
          clearDownloadError ? null : (downloadError ?? this.downloadError),
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
      instanceCreatedAt: _parseDate(json['instance_created_at']),
      instanceDestroyedAt: _parseDate(json['instance_destroyed_at']),
      ratePerHour: (json['rate_per_hour'] as num?)?.toDouble(),
      downloadState: DownloadState.values.firstWhere(
        (s) => s.name == json['download_state'],
        orElse: () => DownloadState.none,
      ),
      downloadedTo: json['downloaded_to'] as String?,
      downloadError: json['download_error'] as String?,
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
        'instance_created_at': instanceCreatedAt?.toIso8601String(),
        'instance_destroyed_at': instanceDestroyedAt?.toIso8601String(),
        'rate_per_hour': ratePerHour,
        'download_state': downloadState.name,
        'downloaded_to': downloadedTo,
        'download_error': downloadError,
        'error_message': errorMessage,
        'created_at': createdAt.toIso8601String(),
        'completed_at': completedAt?.toIso8601String(),
      };

  static DateTime? _parseDate(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
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

  /// User-facing job name, set by the app when the draft arrives and editable
  /// until submit. Also names the download folder. Null on jobs saved before
  /// job names existed — use [displayName].
  final String? jobName;

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
    this.jobName,
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
      jobName: json['job_name'] as String?,
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
        'job_name': jobName,
      };

  bool get isAnimation => isAnimationRender;

  /// The job's name, falling back to the .blend name for older jobs.
  String get displayName => jobDisplayName(jobName, originalFilename);

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

/// Job name if set, otherwise the file name without its extension.
String jobDisplayName(String? jobName, String? originalFilename) {
  final name = jobName?.trim();
  if (name != null && name.isNotEmpty) return name;
  final file = originalFilename?.trim() ?? '';
  if (file.isEmpty) return 'project';
  final dot = file.lastIndexOf('.');
  return dot > 0 ? file.substring(0, dot) : file;
}

import 'gpu_offer.dart';
import 'job_model.dart' show jobDisplayName;

/// Draft job model for jobs awaiting GPU selection and submission
///
/// This represents a job that the user submitted from Blender but hasn't
/// selected a GPU configuration and clicked Submit yet.
///
/// States:
/// - Just created: ready to show in UI with gear icon for GPU selection
/// - GPU selected: user has picked a GPU config and can now submit
/// - Submitted: RPC called and job is now in actual "initialising" status
enum DraftJobStatus {
  submitted, // Initial state from Blender
  zipping, // Currently zipping the project
  ready, // GPU selected, ready for queue
  queued, // Queued for auto-submission
  paused, // Paused by user
  error, // Failed to submit
}

class DraftJob {
  /// Unique identifier for this draft job (UUID)
  final String id;

  /// Path to the blend file on the local machine
  final String blendFilePath;

  /// Original filename as provided by Blender addon
  final String originalFilename;

  /// Render parameters from Blender (frame range, resolution, engine, etc)
  final Map<String, dynamic> renderParams;

  /// Blender version to use for rendering
  final String blenderVersion;

  /// When this draft was created
  final DateTime createdAt;

  /// Selected GPU offer (null until user selects one)
  GpuOffer? selectedGpu;

  /// Error message if anything went wrong
  String? errorMessage;

  /// Current status of the draft job
  DraftJobStatus status;

  DraftJob({
    required this.id,
    required this.blendFilePath,
    required this.originalFilename,
    required this.renderParams,
    required this.blenderVersion,
    required this.createdAt,
    this.selectedGpu,
    this.errorMessage,
    this.status = DraftJobStatus.submitted,
  });

  /// The job's name (editable until submit), falling back to the file name.
  String get displayName =>
      jobDisplayName(renderParams['job_name'] as String?, originalFilename);

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'blendFilePath': blendFilePath,
      'originalFilename': originalFilename,
      'renderParams': renderParams,
      'blenderVersion': blenderVersion,
      'createdAt': createdAt.toIso8601String(),
      'selectedGpu': selectedGpu?.toJson(),
      'errorMessage': errorMessage,
      'status': status.name,
    };
  }

  factory DraftJob.fromJson(Map<String, dynamic> json) {
    return DraftJob(
      id: json['id'],
      blendFilePath: json['blendFilePath'],
      originalFilename: json['originalFilename'],
      renderParams: Map<String, dynamic>.from(json['renderParams']),
      blenderVersion: json['blenderVersion'],
      createdAt: DateTime.parse(json['createdAt']),
      selectedGpu: json['selectedGpu'] != null
          ? _tryParseGpu(json['selectedGpu'] as Map<String, dynamic>)
          : null,
      errorMessage: json['errorMessage'],
      status: json['status'] != null
          ? DraftJobStatus.values.firstWhere(
              (e) => e.name == json['status'],
              orElse: () => DraftJobStatus.submitted,
            )
          : DraftJobStatus.submitted,
    );
  }

  /// Stored GPU selections from the old Supabase-era format may not parse —
  /// drop them silently so the user just re-picks a GPU.
  static GpuOffer? _tryParseGpu(Map<String, dynamic> json) {
    try {
      return GpuOffer.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// Check if this job is ready to submit (Status is ready and no errors)
  bool get isReadyToSubmit =>
      status == DraftJobStatus.ready && errorMessage == null;

  /// Check if this job has been configured (GPU selected)
  bool get isConfigured => selectedGpu != null;

  /// Get total frame count
  int get totalFrames {
    final start = renderParams['frame_start'] as int? ?? 1;
    final end = renderParams['frame_end'] as int? ?? 1;
    return (end - start + 1).abs();
  }

  /// Get frame range string
  String get frameRange {
    final start = renderParams['frame_start'] as int? ?? 1;
    final end = renderParams['frame_end'] as int? ?? 1;
    return 'Frames $start-$end';
  }

  /// Get render engine
  String get engine => renderParams['engine'] as String? ?? 'Unknown';

  /// Get output format
  String get outputFormat => renderParams['output_format'] as String? ?? 'PNG';

  /// Check if animation
  bool get isAnimation => renderParams['is_animation_render'] as bool? ?? false;

  /// Get resolution string
  String get resolution {
    return renderParams['resolution'] as String? ?? '1920x1080';
  }

  /// Get device (CUDA/OPTIX/CPU)
  String get device => renderParams['cycles_device'] as String? ?? 'CPU';

  /// Get frames display string
  String get framesDisplay {
    final start = renderParams['frame_start'] as int? ?? 1;
    final end = renderParams['frame_end'] as int? ?? 1;
    if (!isAnimation) {
      return '$start';
    }
    return '$start-$end';
  }

  /// Get status display string
  String get statusDisplay {
    if (errorMessage != null) return 'Error';
    if (isConfigured) return 'Ready to Submit';
    return 'Configuration Needed';
  }
}

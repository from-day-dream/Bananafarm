import 'dart:io';

/// What a tool lets the Lab do. Drives which features unlock once installed.
enum ToolCapability {
  /// Real-ESRGAN — image upscaling.
  upscale,

  /// RIFE — frame interpolation.
  interpolate,

  /// FFmpeg — video decode/encode, required to interpolate video.
  video,
}

ToolCapability? _capabilityFrom(String? raw) {
  switch (raw) {
    case 'upscale':
      return ToolCapability.upscale;
    case 'interpolate':
      return ToolCapability.interpolate;
    case 'video':
      return ToolCapability.video;
  }
  return null;
}

/// One downloadable artifact for a specific platform.
class ToolAsset {
  final String url;
  final int bytes;

  /// 'zip' — extract, then flatten if the archive nests everything under a
  /// single folder. 'raw' — a bare binary; write it out and chmod, no extract.
  final String format;

  /// Extra binaries fetched alongside the main one (ffprobe beside ffmpeg),
  /// keyed by executable name.
  final Map<String, String> companionUrls;

  const ToolAsset({
    required this.url,
    required this.bytes,
    required this.format,
    this.companionUrls = const {},
  });

  bool get isArchive => format == 'zip';

  factory ToolAsset.fromMap(Map<String, dynamic> map) {
    final companions = <String, String>{};
    final raw = map['companion_urls'];
    if (raw is Map) {
      raw.forEach((k, v) => companions['$k'] = '$v');
    }
    return ToolAsset(
      url: map['url'] ?? '',
      bytes: (map['bytes'] as num?)?.toInt() ?? 0,
      format: map['format'] ?? 'zip',
      companionUrls: companions,
    );
  }
}

/// A downloadable native tool the Lab shells out to.
///
/// Immutable — install state is resolved by [AiLabService] rather than being
/// mutated onto the model, which is what the previous `localPath = 'installed'`
/// marker did.
class AIModel {
  final String id;
  final String name;
  final String? description;
  final ToolCapability? capability;

  /// Binary name, without the Windows `.exe` (see [executableName]).
  final String executable;

  /// Extra binaries shipped with this tool (e.g. ffprobe).
  final List<String> companions;

  /// Model/weight names selectable in the UI.
  final List<String> models;

  /// For a tool that ships far more weights than we need, the subdirectories
  /// worth keeping. Everything else is deleted after extraction — this is what
  /// takes RIFE from 466MB installed down to about 20MB.
  final List<String> keepModels;

  final bool isActive;
  final Map<String, ToolAsset> assets;

  const AIModel({
    required this.id,
    required this.name,
    required this.executable,
    this.description,
    this.capability,
    this.companions = const [],
    this.models = const [],
    this.keepModels = const [],
    this.isActive = true,
    this.assets = const {},
  });

  /// Platform key into [assets]. ffmpeg is the one tool with no macOS
  /// universal build, so the Mac key carries an arch suffix; the ncnn tools
  /// ship fat binaries and use a plain 'macos' key.
  static List<String> get platformKeys {
    if (Platform.isWindows) return const ['windows'];
    if (Platform.isMacOS) {
      final arm = _isAppleSilicon();
      return arm
          ? const ['macos', 'macos-arm64']
          : const ['macos', 'macos-x64'];
    }
    return const [];
  }

  /// True on Apple Silicon, including when the app itself is running
  /// translated under Rosetta — we want the binary matching the *hardware*.
  static bool _isAppleSilicon() {
    if (!Platform.isMacOS) return false;
    if (Platform.version.contains('arm64')) return true;
    try {
      final r = Process.runSync('sysctl', ['-in', 'sysctl.proc_translated']);
      return '${r.stdout}'.trim() == '1';
    } catch (_) {
      return false;
    }
  }

  /// The asset for this machine, or null when the tool doesn't ship for it.
  ToolAsset? get asset {
    for (final key in platformKeys) {
      final a = assets[key];
      if (a != null) return a;
    }
    return null;
  }

  bool get isAvailableOnThisPlatform => asset != null;

  /// Binary filename as it exists on disk for this platform.
  String get executableName =>
      Platform.isWindows ? '$executable.exe' : executable;

  String companionName(String name) =>
      Platform.isWindows ? '$name.exe' : name;

  int get downloadBytes => asset?.bytes ?? 0;

  factory AIModel.fromMap(Map<String, dynamic> map) {
    final assets = <String, ToolAsset>{};
    final rawAssets = map['assets'];
    if (rawAssets is Map) {
      rawAssets.forEach((k, v) {
        if (v is Map) {
          assets['$k'] = ToolAsset.fromMap(v.cast<String, dynamic>());
        }
      });
    }

    List<String> stringList(String key) {
      final raw = map[key];
      if (raw is List) return raw.map((e) => '$e').toList();
      return const [];
    }

    return AIModel(
      id: map['id']?.toString() ?? '',
      name: map['name'] ?? 'Unknown Tool',
      description: map['description'],
      capability: _capabilityFrom(map['capability'] as String?),
      executable: map['executable'] ?? '',
      companions: stringList('companions'),
      models: stringList('models'),
      keepModels: stringList('keep_models'),
      isActive: map['is_active'] ?? true,
      assets: assets,
    );
  }
}

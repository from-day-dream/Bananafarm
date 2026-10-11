import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../constants/app_constants.dart';
import '../services/local_storage_service.dart';
import 'common_providers.dart';

/// Provider for app-wide settings
final settingsProvider = StateNotifierProvider<SettingsNotifier, SettingsState>((
  ref,
) {
  // Watch the local storage service to ensure we handle updates if the service itself changes (unlikely)
  // or just read it. Since it's an initialized singleton effectively, read is fine, but watch is safer for Riverpod.
  final storage = ref.watch(localStorageServiceProvider);
  return SettingsNotifier(storage);
});

class SettingsState {
  final String? downloadPath;

  /// Where the Lab writes upscaled / interpolated results. Falls back to
  /// [downloadPath] when unset.
  final String? labOutputPath;

  final bool isLoading;
  final bool minimizeToTray;
  final bool showNotifications;
  final int maxConcurrentJobs;

  SettingsState({
    this.downloadPath,
    this.labOutputPath,
    this.isLoading = true,
    this.minimizeToTray = false, // Default to false
    this.showNotifications = true, // Default to true
    this.maxConcurrentJobs = AppConstants.defaultMaxConcurrentJobs,
  });

  SettingsState copyWith({
    String? downloadPath,
    String? labOutputPath,
    bool? isLoading,
    bool? minimizeToTray,
    bool? showNotifications,
    int? maxConcurrentJobs,
  }) {
    return SettingsState(
      downloadPath: downloadPath ?? this.downloadPath,
      labOutputPath: labOutputPath ?? this.labOutputPath,
      isLoading: isLoading ?? this.isLoading,
      minimizeToTray: minimizeToTray ?? this.minimizeToTray,
      showNotifications: showNotifications ?? this.showNotifications,
      maxConcurrentJobs: maxConcurrentJobs ?? this.maxConcurrentJobs,
    );
  }
}

class SettingsNotifier extends StateNotifier<SettingsState> {
  final LocalStorageService _storage;

  SettingsNotifier(this._storage) : super(SettingsState()) {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    // We assume storage is already initialized from main.dart
    String? path = _storage.getString('download_path');
    final labPath = _storage.getString('lab_output_path');
    final minimizeToTray = _storage.getBool('minimize_to_tray') ?? false;
    final showNotifications = _storage.getBool('show_notifications') ?? true;
    final maxConcurrentJobs = _storage.getInt('max_concurrent_jobs') ??
        AppConstants.defaultMaxConcurrentJobs;

    if (path == null) {
      // Default to system downloads directory
      final downloadsDir = await getDownloadsDirectory();
      path = downloadsDir?.path;
    }

    state = state.copyWith(
      downloadPath: path,
      labOutputPath: labPath,
      isLoading: false,
      minimizeToTray: minimizeToTray,
      showNotifications: showNotifications,
      maxConcurrentJobs: maxConcurrentJobs,
    );
  }

  Future<void> setMaxConcurrentJobs(int value) async {
    await _storage.saveInt('max_concurrent_jobs', value);
    state = state.copyWith(maxConcurrentJobs: value);
  }

  Future<void> setDownloadPath(String path) async {
    await _storage.saveString('download_path', path);
    state = state.copyWith(downloadPath: path);
  }

  Future<void> setLabOutputPath(String path) async {
    await _storage.saveString('lab_output_path', path);
    state = state.copyWith(labOutputPath: path);
  }

  Future<void> setMinimizeToTray(bool value) async {
    await _storage.saveBool('minimize_to_tray', value);
    state = state.copyWith(minimizeToTray: value);
  }

  Future<void> setShowNotifications(bool value) async {
    await _storage.saveBool('show_notifications', value);
    state = state.copyWith(showNotifications: value);
  }
}

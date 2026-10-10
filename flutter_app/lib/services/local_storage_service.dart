import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../models/draft_job_model.dart';

/// Local storage service for app settings and draft jobs
class LocalStorageService {
  static const String _themeKey = 'theme_preference';

  static final LocalStorageService _instance = LocalStorageService._internal();
  late SharedPreferences _prefs;
  bool _isInitialized = false;

  factory LocalStorageService() {
    return _instance;
  }

  LocalStorageService._internal();

  /// Initialize the storage service
  Future<void> initialize() async {
    if (_isInitialized) return;
    _prefs = await SharedPreferences.getInstance();
    _isInitialized = true;
  }

  /// Save theme preference
  Future<void> setThemePreference(String themeMode) async {
    await _prefs.setString(_themeKey, themeMode);
  }

  /// Load theme preference
  String? getThemePreference() {
    return _prefs.getString(_themeKey);
  }

  /// Save arbitrary key-value pair
  Future<void> saveString(String key, String value) async {
    await _prefs.setString(key, value);
  }

  /// Load arbitrary string value
  String? getString(String key) {
    return _prefs.getString(key);
  }

  /// Save arbitrary integer value
  Future<void> saveInt(String key, int value) async {
    await _prefs.setInt(key, value);
  }

  /// Load arbitrary integer value
  int? getInt(String key) {
    return _prefs.getInt(key);
  }

  /// Save arbitrary boolean value
  Future<void> saveBool(String key, bool value) async {
    await _prefs.setBool(key, value);
  }

  /// Load arbitrary boolean value
  bool? getBool(String key) {
    return _prefs.getBool(key);
  }

  // ==================== Draft Jobs Management ====================

  /// Save a draft job to local storage
  Future<void> saveDraftJob(DraftJob job) async {
    try {
      final jobs = getDraftJobs();
      jobs.removeWhere((j) => j.id == job.id);
      jobs.add(job);

      final jsonList = jobs.map((j) => j.toJson()).toList();
      await _prefs.setString('draft_jobs', jsonEncode(jsonList));
    } catch (e) {
      print('Error saving draft job: $e');
    }
  }

  /// Get all draft jobs from local storage
  List<DraftJob> getDraftJobs() {
    try {
      final jsonStr = _prefs.getString('draft_jobs');
      if (jsonStr == null) return [];

      final jsonList = jsonDecode(jsonStr) as List;
      return jsonList
          .map((json) => DraftJob.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('Error loading draft jobs: $e');
      return [];
    }
  }

  /// Delete a draft job by ID
  Future<void> deleteDraftJob(String jobId) async {
    try {
      final jobs = getDraftJobs();
      jobs.removeWhere((j) => j.id == jobId);

      if (jobs.isEmpty) {
        await _prefs.remove('draft_jobs');
      } else {
        final jsonList = jobs.map((j) => j.toJson()).toList();
        await _prefs.setString('draft_jobs', jsonEncode(jsonList));
      }
    } catch (e) {
      print('Error deleting draft job: $e');
    }
  }

  /// Clear all draft jobs
  Future<void> clearAllDraftJobs() async {
    try {
      await _prefs.remove('draft_jobs');
    } catch (e) {
      print('Error clearing draft jobs: $e');
    }
  }
}

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/job_model.dart';

/// Local persistence for render jobs, following the same shared_preferences
/// JSON-list pattern as draft jobs. The job list is the app's source of truth
/// now that no backend exists — progress snapshots are only persisted on
/// meaningful transitions, not every poll tick.
class LocalJobsRepository {
  static const _jobsKey = 'render_jobs';

  final SharedPreferences _prefs;

  LocalJobsRepository(this._prefs);

  static Future<LocalJobsRepository> create() async {
    return LocalJobsRepository(await SharedPreferences.getInstance());
  }

  List<RenderJob> getJobs() {
    try {
      final jsonStr = _prefs.getString(_jobsKey);
      if (jsonStr == null) return [];
      final jsonList = jsonDecode(jsonStr) as List;
      return jsonList
          .map((json) => RenderJob.fromJson((json as Map).cast<String, dynamic>()))
          .toList();
    } catch (e) {
      print('Error loading render jobs: $e');
      return [];
    }
  }

  Future<void> saveJob(RenderJob job) async {
    final jobs = getJobs();
    jobs.removeWhere((j) => j.id == job.id);
    jobs.add(job);
    await _persist(jobs);
  }

  Future<void> deleteJob(String jobId) async {
    final jobs = getJobs()..removeWhere((j) => j.id == jobId);
    await _persist(jobs);
  }

  Future<void> _persist(List<RenderJob> jobs) async {
    try {
      final jsonList = jobs.map((j) => j.toJson()).toList();
      await _prefs.setString(_jobsKey, jsonEncode(jsonList));
    } catch (e) {
      print('Error saving render jobs: $e');
    }
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/job_model.dart';

/// The app's job list — the local source of truth, fed by RenderJobManager.
/// Replaces the old Supabase Realtime userJobsProvider stream.
final jobsProvider = StateNotifierProvider<JobsNotifier, List<RenderJob>>((ref) {
  return JobsNotifier();
});

final activeJobsProvider = Provider<List<RenderJob>>((ref) {
  return ref.watch(jobsProvider).where((j) => j.isActive).toList();
});

final completedJobsProvider = Provider<List<RenderJob>>((ref) {
  return ref.watch(jobsProvider).where((j) => !j.isActive).toList();
});

class JobsNotifier extends StateNotifier<List<RenderJob>> {
  JobsNotifier() : super([]);

  void setAll(List<RenderJob> jobs) {
    state = _sorted(jobs);
  }

  void upsert(RenderJob job) {
    final jobs = [...state]..removeWhere((j) => j.id == job.id);
    jobs.add(job);
    state = _sorted(jobs);
  }

  void remove(String jobId) {
    state = state.where((j) => j.id != jobId).toList();
  }

  RenderJob? byId(String jobId) {
    for (final job in state) {
      if (job.id == jobId) return job;
    }
    return null;
  }

  static List<RenderJob> _sorted(List<RenderJob> jobs) {
    jobs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return jobs;
  }
}

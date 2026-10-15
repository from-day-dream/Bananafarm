import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/draft_job_provider.dart';
import '../theme/app_theme.dart';
import 'job_submission_screen.dart';

class DraftJobsScreen extends ConsumerWidget {
  const DraftJobsScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draftJobs = ref.watch(draftJobsProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Draft Jobs'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: draftJobs.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [const Text('No draft jobs found')],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: draftJobs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final job = draftJobs[index];
                return Card(
                  child: ListTile(
                    title: Text(
                      job.displayName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text('Created: ${_formatDate(job.createdAt)}'),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                    onTap: () {
                      // Navigate to job submission with this draft
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              JobSubmissionScreen(draftJobId: job.id),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute}';
  }
}

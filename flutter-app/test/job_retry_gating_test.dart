// Unit tests for RenderJob's retry gate and slow-start check.
//
// Retry reopens the submission page, so it needs only the project zip — the
// original GPU is preselected when known and picked there otherwise.

import 'package:flutter_test/flutter_test.dart';

import 'package:bananafarm/models/gpu_offer.dart';
import 'package:bananafarm/models/job_model.dart';
import 'package:bananafarm/models/render_provider.dart';

RenderJob _job({
  required LocalJobStatus status,
  GpuOffer? gpuOffer,
  String? projectZipPath,
}) {
  return RenderJob(
    id: 'job-1',
    status: status,
    provider: RenderProvider.vast,
    gpuName: 'RTX 4090',
    gpuOffer: gpuOffer,
    apiToken: 'token',
    projectZipPath: projectZipPath,
    blenderVersion: '5.0.1',
    renderParams: RenderParams.fromJson(const {}),
    createdAt: DateTime(2026, 1, 1),
  );
}

final _offer = GpuOffer(
  provider: RenderProvider.vast,
  gpuName: 'RTX 4090',
  gpuId: 'RTX 4090',
);

void main() {
  group('canRetry', () {
    test('failed and cancelled jobs with their zip can be retried', () {
      for (final status in [LocalJobStatus.failed, LocalJobStatus.cancelled]) {
        final job = _job(status: status, projectZipPath: '/tmp/p.zip');
        expect(job.canRetry, isTrue, reason: '$status');
      }
    });

    test('the original GPU is not required — it is re-picked on submit', () {
      final job = _job(
        status: LocalJobStatus.failed,
        gpuOffer: null,
        projectZipPath: '/tmp/p.zip',
      );
      expect(job.canRetry, isTrue);
    });

    test('a job whose zip was reclaimed cannot be retried', () {
      for (final path in <String?>[null, '']) {
        final job = _job(
          status: LocalJobStatus.failed,
          gpuOffer: _offer,
          projectZipPath: path,
        );
        expect(job.canRetry, isFalse);
      }
    });

    test('active and completed jobs are never retryable', () {
      for (final status in LocalJobStatus.values) {
        if (status == LocalJobStatus.failed ||
            status == LocalJobStatus.cancelled) {
          continue;
        }
        final job = _job(
          status: status,
          gpuOffer: _offer,
          projectZipPath: '/tmp/p.zip',
        );
        expect(job.canRetry, isFalse, reason: '$status');
      }
    });
  });

  group('isSlowToStart', () {
    final rented = DateTime(2026, 10, 15, 12);
    RenderJob starting() => RenderJob(
          id: 'job-1',
          status: LocalJobStatus.starting,
          provider: RenderProvider.vast,
          gpuName: 'RTX 4090',
          apiToken: 'token',
          blenderVersion: '5.0.1',
          renderParams: RenderParams.fromJson(const {}),
          createdAt: rented,
          instanceCreatedAt: rented,
        );

    test('false before 5 minutes, true after', () {
      expect(starting().isSlowToStart(rented.add(const Duration(minutes: 4))),
          isFalse);
      expect(starting().isSlowToStart(rented.add(const Duration(minutes: 5))),
          isTrue);
    });

    test('only applies while starting', () {
      final rendering = starting().copyWith(status: LocalJobStatus.rendering);
      expect(rendering.isSlowToStart(rented.add(const Duration(hours: 1))),
          isFalse);
    });
  });
}

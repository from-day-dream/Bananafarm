// Unit tests for the two retry gates on RenderJob.
//
// canRetry (same GPU) needs the original offer; canRepickGpu (different GPU)
// only needs the project zip, so jobs saved before `gpuOffer` existed stay
// recoverable by choosing a GPU rather than silently losing their retry button.

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
  group('canRetry / canRepickGpu', () {
    test('failed job with offer and zip supports both paths', () {
      final job = _job(
        status: LocalJobStatus.failed,
        gpuOffer: _offer,
        projectZipPath: '/tmp/p.zip',
      );
      expect(job.canRetry, isTrue);
      expect(job.canRepickGpu, isTrue);
    });

    test('legacy failed job without an offer can still re-pick a GPU', () {
      final job = _job(
        status: LocalJobStatus.failed,
        gpuOffer: null,
        projectZipPath: '/tmp/p.zip',
      );
      expect(job.canRetry, isFalse, reason: 'original GPU is unknown');
      expect(job.canRepickGpu, isTrue, reason: 'zip survives, so pick a GPU');
    });

    test('failed job whose zip was reclaimed supports neither', () {
      for (final path in <String?>[null, '']) {
        final job = _job(
          status: LocalJobStatus.failed,
          gpuOffer: _offer,
          projectZipPath: path,
        );
        expect(job.canRetry, isFalse);
        expect(job.canRepickGpu, isFalse);
      }
    });

    test('non-failed statuses are never retryable', () {
      for (final status in LocalJobStatus.values) {
        if (status == LocalJobStatus.failed) continue;
        final job = _job(
          status: status,
          gpuOffer: _offer,
          projectZipPath: '/tmp/p.zip',
        );
        expect(job.canRetry, isFalse, reason: '$status');
        expect(job.canRepickGpu, isFalse, reason: '$status');
      }
    });

    test('cancelled is deliberately excluded', () {
      final job = _job(
        status: LocalJobStatus.cancelled,
        gpuOffer: _offer,
        projectZipPath: '/tmp/p.zip',
      );
      expect(job.canRepickGpu, isFalse);
    });
  });
}

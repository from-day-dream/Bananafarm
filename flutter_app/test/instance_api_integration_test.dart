// Integration test: the real Dart InstanceApiService against the real render
// pod API (docker-image/src) running on localhost:8000.
//
// Start the pod first:
//   cd docker-image/src && JOB_ID=itest-job API_TOKEN=itest-token-123 \
//     PROVIDER=local RENDER_PARAMS='{"frame_start":1,"frame_end":1}' python main.py
//
// The test exercises the full upload contract (multi-chunk, out-of-order
// resume metadata, completion) and the pipeline failure path (no Blender on
// the host, so the job must land in 'failed'). Skipped automatically when no
// pod is listening.
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bananafarm/models/job_model.dart';
import 'package:bananafarm/models/render_provider.dart';
import 'package:bananafarm/services/instance_api_service.dart';

void main() {
  const endpoint = 'http://127.0.0.1:8000';
  const apiToken = 'itest-token-123';

  final job = RenderJob(
    id: 'itest-job',
    status: LocalJobStatus.uploading,
    provider: RenderProvider.vast,
    gpuName: 'Test GPU',
    apiToken: apiToken,
    blenderVersion: '4.5.2',
    renderParams: RenderParams.fromJson({'frame_start': 1, 'frame_end': 1}),
    createdAt: DateTime.now(),
  ).copyWith(instanceEndpoint: endpoint);

  Future<bool> podIsRunning() async {
    try {
      final socket = await Socket.connect('127.0.0.1', 8000,
          timeout: const Duration(seconds: 2));
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  test('full upload + pipeline contract against local pod', () async {
    if (!await podIsRunning()) {
      markTestSkipped('Render pod not running on localhost:8000');
      return;
    }

    final api = InstanceApiService();

    // 1. Health + initial state
    expect(await api.health(job), isTrue);
    var status = await api.getStatus(job);
    expect(status.state, ContainerJobState.waitingForUpload);

    // 2. Build a >100MB project zip (forces 3 chunks at 50MB chunk size)
    final tempDir = await Directory.systemTemp.createTemp('bf_itest_');
    final zipPath = '${tempDir.path}/project.zip';
    final encoder = ZipFileEncoder()..create(zipPath);
    final bigBlend = File('${tempDir.path}/scene.blend');
    final raf = await bigBlend.open(mode: FileMode.write);
    // 110 MB of random bytes — incompressible, so the zip itself exceeds
    // the 50MB chunk size and the upload spans multiple chunks.
    final rand = Random(42);
    for (var i = 0; i < 110; i++) {
      final block =
          List<int>.generate(1024 * 1024, (_) => rand.nextInt(256));
      await raf.writeFrom(block);
    }
    await raf.close();
    await encoder.addFile(bigBlend);
    await encoder.close();
    final zipSize = await File(zipPath).length();
    expect(zipSize, greaterThan(InstanceApiService.chunkSize),
        reason: 'zip must span multiple chunks');

    // 3. Chunked upload with progress callbacks
    final progressValues = <double>[];
    await api.uploadProject(job, zipPath,
        onProgress: progressValues.add);
    expect(progressValues, isNotEmpty);
    expect(progressValues.last, 1.0);

    // 4. Pipeline runs: extracting -> rendering -> failed (no Blender here)
    String finalState = '';
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      status = await api.getStatus(job);
      if (ContainerJobState.terminal.contains(status.state)) {
        finalState = status.state;
        break;
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    expect(finalState, ContainerJobState.failed,
        reason: 'render must fail on a host without Blender');
    expect(status.errorMessage, isNotNull);

    // 5. Progress endpoint mirrors the terminal state
    final progress = await api.getProgress(job);
    expect(progress.state, ContainerJobState.failed);

    // 6. Outputs listing works (empty on failure)
    final outputs = await api.listOutputs(job);
    expect(outputs.files, isEmpty);

    // 7. A second upload attempt is refused in a terminal state
    expect(
      () => api.uploadProject(job, zipPath),
      throwsA(isA<InstanceStateException>()),
    );

    await tempDir.delete(recursive: true);
  });
}

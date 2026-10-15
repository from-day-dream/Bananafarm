import 'dart:convert';
import 'dart:io';

import 'package:bananafarm/models/job_model.dart';
import 'package:bananafarm/models/render_provider.dart';
import 'package:bananafarm/providers/settings_provider.dart';
import 'package:bananafarm/services/instance_api_service.dart';
import 'package:bananafarm/services/output_download_service.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Serves each download from [responses] in order: a String is written as
/// the file's bytes, an Exception is thrown as a network failure.
class _FakeApi extends InstanceApiService {
  final List<Object> responses;
  int calls = 0;

  _FakeApi(this.responses);

  @override
  Future<void> downloadOutput(
    RenderJob job,
    String fileName,
    String destPath, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final next = responses[calls++];
    if (next is Exception) throw next;
    await File(destPath).writeAsString(next as String);
    onProgress?.call(next.length, next.length);
  }
}

const _content = 'rendered frame bytes';
final _sha = sha256.convert(utf8.encode(_content)).toString();

RenderJob _job({String? sha = 'auto', int? size}) => RenderJob(
      id: 'j1',
      status: LocalJobStatus.completed,
      provider: RenderProvider.vast,
      gpuName: 'RTX 3090',
      instanceId: '1',
      apiToken: 't',
      blenderVersion: '5.2.1',
      renderParams: RenderParams.fromJson({'job_name': 'Hero shot'}),
      createdAt: DateTime(2026),
      outputFiles: [
        OutputFileInfo(
          name: 'frame.png',
          size: size ?? _content.length,
          sha256: sha == 'auto' ? _sha : sha,
        ),
      ],
    );

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('bf_dl_'));
  tearDown(() => root.deleteSync(recursive: true));

  OutputDownloadService service(_FakeApi api) =>
      OutputDownloadService(api, retryDelays: const [Duration.zero, Duration.zero]);

  test('downloads into the job-name folder and verifies the checksum', () async {
    final api = _FakeApi([_content]);
    final folder = await service(api)
        .downloadJobOutputs(_job(), downloadRoot: root.path);

    expect(folder, endsWith('Hero shot'));
    expect(File('$folder/frame.png').readAsStringSync(), _content);
    expect(File('$folder/frame.png.part').existsSync(), isFalse);
  });

  test('retries after a network failure', () async {
    final api = _FakeApi([Exception('connection reset'), _content]);
    final folder = await service(api)
        .downloadJobOutputs(_job(), downloadRoot: root.path);

    expect(api.calls, 2);
    expect(File('$folder/frame.png').existsSync(), isTrue);
  });

  test('rejects a corrupted file and retries it', () async {
    final api = _FakeApi(['rendered frame byteZ', _content]); // same size
    await service(api).downloadJobOutputs(_job(), downloadRoot: root.path);
    expect(api.calls, 2, reason: 'checksum mismatch forces a re-download');
  });

  test('without a checksum, a size mismatch is still caught', () async {
    final api = _FakeApi(['short', 'short', 'short']);
    await expectLater(
      service(api).downloadJobOutputs(_job(sha: null), downloadRoot: root.path),
      throwsA(isA<OutputDownloadException>()
          .having((e) => e.message, 'message', contains('size mismatch'))),
    );
    expect(api.calls, 3, reason: '3 attempts in total');
  });

  test('gives up after 3 attempts and leaves no partial file', () async {
    final api = _FakeApi(List.filled(3, Exception('timeout')));
    await expectLater(
      service(api).downloadJobOutputs(_job(), downloadRoot: root.path),
      throwsA(isA<OutputDownloadException>()
          .having((e) => e.message, 'message', contains('frame.png'))),
    );
    final leftovers = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.part'));
    expect(leftovers, isEmpty);
  });

  test('never overwrites an earlier download', () async {
    final first = await service(_FakeApi([_content]))
        .downloadJobOutputs(_job(), downloadRoot: root.path);
    await service(_FakeApi([_content]))
        .downloadJobOutputs(_job(), downloadRoot: root.path);

    expect(File('$first/frame.png').existsSync(), isTrue);
    expect(File('$first/frame_1.png').existsSync(), isTrue);
  });

  test('download fields and checksums survive a JSON round trip', () {
    final job = _job().copyWith(
      downloadState: DownloadState.failed,
      downloadError: 'frame.png: timeout',
    );
    final back = RenderJob.fromJson(job.toJson());
    expect(back.downloadState, DownloadState.failed);
    expect(back.downloadError, 'frame.png: timeout');
    expect(back.outputFiles.single.sha256, _sha);

    final retried = back.copyWith(
      downloadState: DownloadState.downloaded,
      downloadedTo: '/out/Hero shot',
      clearDownloadError: true,
    );
    expect(retried.downloadError, isNull);
    expect(RenderJob.fromJson(retried.toJson()).downloadedTo, '/out/Hero shot');
  });

  test('auto download & delete is on by default', () {
    expect(SettingsState().autoDownloadAndDelete, isTrue);
  });
}

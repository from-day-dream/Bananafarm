// Regression tests for InstanceApiService.uploadProject().
//
// Verifies (against a fake HttpClientAdapter, no real network/container):
// 1. Chunk PUT requests actually overlap in time up to the configured
//    concurrency, not just that the end result is correct.
// 2. Every chunk index is uploaded exactly once.
// 3. Integrity metadata is sent: whole-file sha256 + chunk_size at /begin and
//    a per-chunk X-Chunk-Sha256 that matches the bytes actually transmitted.
// 4. A chunk rejected for corruption is retried on its own, not by discarding
//    the whole upload pass.
// 5. /complete returns 202 and the client waits by polling /status — the pod
//    assembles on a background thread, so no long HTTP request is held open.
//    (Holding it open is what let a timed-out retry start a second, corrupting
//    assembly and produce "Failed to extract project zip".)
// 6. A resume is refused unless the session describes the same file layout.
// 7. The upload never blocks the event loop. Hashing a multi-GB zip on the UI
//    isolate froze the Windows app and overflowed the embedder's task-runner
//    message queue ("Failed to post message to main thread").
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bananafarm/models/job_model.dart';
import 'package:bananafarm/models/render_provider.dart';
import 'package:bananafarm/services/instance_api_service.dart';

/// Fake render-pod control API.
///
/// Models the pod's state machine closely enough to exercise the real client
/// flow: it stays `waiting_for_upload` until /complete, then reports
/// `assembling` for [assemblingPolls] status polls before moving on.
class _FakePodAdapter implements HttpClientAdapter {
  _FakePodAdapter({
    this.chunkHoldMs = 0,
    this.assemblingPolls = 0,
    this.existingSession,
    this.failChunkOnce,
    this.rejectWithChecksumError = false,
    this.hashBodies = true,
  });

  /// How long each chunk PUT is held open (used to observe real overlap).
  final int chunkHoldMs;

  /// Number of /status polls that report `assembling` before `extracting`.
  final int assemblingPolls;

  /// Body returned by GET /upload-project/status before any /begin.
  final Map<String, dynamic>? existingSession;

  /// Chunk index to reject once with a 400, as the pod does on a checksum or
  /// length mismatch.
  final int? failChunkOnce;

  /// Simulate the pod failing the assembled zip's checksum and resetting
  /// itself to accept a fresh upload.
  final bool rejectWithChecksumError;

  /// SHA-256 each received body so a test can compare it against the client's
  /// X-Chunk-Sha256 header. That hashing is synchronous CPU work on the test's
  /// own isolate — a real socket does nothing of the sort — so the
  /// event-loop-responsiveness test turns it off to measure only the client.
  final bool hashBodies;

  int _inFlight = 0;
  int maxInFlight = 0;
  final List<int> receivedOrder = [];
  final List<int> putAttempts = [];
  final Map<int, String> chunkHashHeaders = {};
  final Map<int, String> chunkActualHashes = {};
  Map<String, dynamic>? beginBody;
  int beginCalls = 0;
  int completeCalls = 0;
  int statusPolls = 0;
  bool _uploadCompleted = false;
  bool _chunkFailed = false;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final path = options.uri.path;
    final method = options.method;

    ResponseBody json(Map<String, dynamic> data, [int code = 200]) =>
        ResponseBody.fromBytes(
          Uint8List.fromList(utf8.encode(jsonEncode(data))),
          code,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );

    if (method == 'GET' && path.endsWith('/status')) {
      statusPolls++;
      if (!_uploadCompleted) {
        return json({
          'job_id': 'test',
          'state': 'waiting_for_upload',
          'error_message': null,
          'outputs_ready': false,
        });
      }
      if (rejectWithChecksumError) {
        return json({
          'job_id': 'test',
          'state': 'waiting_for_upload',
          'error_message': 'Uploaded project failed its checksum — the '
              'transfer was corrupted',
          'outputs_ready': false,
        });
      }
      // statusPolls counts the pre-upload gate check too; the assembly poll
      // loop starts after it.
      final assemblyPolls = statusPolls - 1;
      return json({
        'job_id': 'test',
        'state': assemblyPolls <= assemblingPolls ? 'assembling' : 'extracting',
        'error_message': null,
        'outputs_ready': false,
      });
    }

    if (method == 'GET' && path.endsWith('/upload-project/status')) {
      return json(existingSession ??
          {
            'upload_id': null,
            'received_chunks': [],
            'total_chunks': null,
            'total_size': null,
            'chunk_size': null,
          });
    }

    if (method == 'POST' && path.endsWith('/upload-project/begin')) {
      beginCalls++;
      beginBody = (options.data as Map).cast<String, dynamic>();
      return json({'upload_id': 'test-upload'});
    }

    if (method == 'PUT' && path.contains('/upload-project/chunk/')) {
      final index = int.parse(path.split('/').last);
      putAttempts.add(index);

      if (failChunkOnce == index && !_chunkFailed) {
        _chunkFailed = true;
        // Drain the body so the client isn't left writing into a dead stream.
        if (requestStream != null) await requestStream.drain<void>();
        throw DioException(
          requestOptions: options,
          response: Response(
            requestOptions: options,
            statusCode: 400,
            data: {'detail': 'Chunk $index checksum mismatch'},
          ),
          type: DioExceptionType.badResponse,
        );
      }

      _inFlight++;
      maxInFlight = max(maxInFlight, _inFlight);

      final builder = BytesBuilder(copy: false);
      if (requestStream != null) {
        await for (final part in requestStream) {
          builder.add(part);
        }
      }
      final body = builder.takeBytes();
      if (hashBodies) {
        chunkActualHashes[index] = sha256.convert(body).toString();
      }
      chunkHashHeaders[index] =
          options.headers['X-Chunk-Sha256']?.toString() ?? '';

      if (chunkHoldMs > 0) {
        // Hold the request open so concurrently-dispatched chunks overlap
        // within this window instead of completing before the next starts.
        // The window must outlast the per-worker setup cost: reading a 50MB
        // chunk *and* SHA-256'ing it happens before the PUT is dispatched, and
        // the hash is synchronous CPU work that blocks the event loop, so
        // workers reach their PUTs hundreds of ms apart.
        await Future.delayed(Duration(milliseconds: chunkHoldMs));
      }
      _inFlight--;
      receivedOrder.add(index);
      return json({'received': receivedOrder});
    }

    if (method == 'POST' && path.endsWith('/upload-project/complete')) {
      completeCalls++;
      _uploadCompleted = true;
      // The pod validates, spawns a background assembler and returns at once.
      return json({'status': 'assembling'}, 202);
    }

    throw StateError('Unexpected request in fake adapter: $method $path');
  }
}

RenderJob _job() => RenderJob(
      id: 'test-job',
      status: LocalJobStatus.uploading,
      provider: RenderProvider.vast,
      gpuName: 'Test GPU',
      apiToken: 'test-token',
      blenderVersion: '5.0.1',
      renderParams: RenderParams.fromJson({}),
      createdAt: DateTime.now(),
    ).copyWith(instanceEndpoint: 'http://fake-instance');

/// Writes a file of [size] bytes whose content differs per chunk, so each
/// chunk's SHA-256 is distinct (an all-zero buffer would hash identically and
/// hide a chunk/offset mix-up).
Future<String> _writeTestZip(Directory dir, int size) async {
  final bytes = Uint8List(size);
  for (var offset = 0; offset < size; offset += 4096) {
    bytes[offset] = (offset ~/ 4096) % 256;
    bytes[offset + 1] = ((offset ~/ 4096) >> 8) % 256;
  }
  final path = '${dir.path}/project.bin';
  await File(path).writeAsBytes(bytes);
  return path;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('bf_upload_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('dispatches chunks concurrently, each exactly once, with checksums',
      () async {
    // 101MB -> ceil(101MB / 50MB chunkSize) = 3 chunks (50, 50, ~1MB).
    final totalSize = 101 * 1024 * 1024;
    final filePath = await _writeTestZip(tempDir, totalSize);

    final adapter = _FakePodAdapter(chunkHoldMs: 3000);
    final api = InstanceApiService(dio: Dio()..httpClientAdapter = adapter);

    await api.uploadProject(_job(), filePath);

    // 3 chunks, uploadConcurrency=4 -> workerCount = min(4,3) = 3: all
    // three should be in flight together within the fake adapter's delay.
    expect(adapter.maxInFlight, equals(3));
    expect(adapter.receivedOrder.length, equals(3));
    expect(adapter.receivedOrder.toSet(), equals({0, 1, 2}));

    // /begin carries the layout and the whole-file digest the pod verifies.
    expect(adapter.beginBody!['total_size'], equals(totalSize));
    expect(adapter.beginBody!['total_chunks'], equals(3));
    expect(adapter.beginBody!['chunk_size'], equals(InstanceApiService.chunkSize));
    final expectedFileHash =
        (await sha256.bind(File(filePath).openRead()).first).toString();
    expect(adapter.beginBody!['sha256'], equals(expectedFileHash));

    // Every chunk's declared hash matches the bytes actually transmitted, and
    // the three differ from one another.
    for (final index in [0, 1, 2]) {
      expect(adapter.chunkHashHeaders[index], equals(adapter.chunkActualHashes[index]),
          reason: 'chunk $index checksum header must match its body');
    }
    expect(adapter.chunkActualHashes.values.toSet().length, equals(3));
  });

  test('retries only the rejected chunk, not the whole upload', () async {
    final filePath = await _writeTestZip(tempDir, 1024 * 1024);

    final adapter = _FakePodAdapter(failChunkOnce: 0);
    final api = InstanceApiService(dio: Dio()..httpClientAdapter = adapter);

    await api.uploadProject(_job(), filePath);

    // Two attempts at index 0 (one rejected, one accepted); the upload was not
    // restarted, so /begin ran once.
    expect(adapter.putAttempts, equals([0, 0]));
    expect(adapter.receivedOrder, equals([0]));
    expect(adapter.beginCalls, equals(1));
  });

  test('waits out assembly by polling /status instead of one long request',
      () async {
    final filePath = await _writeTestZip(tempDir, 1024 * 1024);

    final adapter = _FakePodAdapter(assemblingPolls: 1);
    final api = InstanceApiService(dio: Dio()..httpClientAdapter = adapter);

    await api.uploadProject(_job(), filePath);

    // /complete was issued exactly once — a second call is what used to start
    // a parallel assembly — and the client kept polling until the pod left
    // the assembling state.
    expect(adapter.completeCalls, equals(1));
    expect(adapter.statusPolls, greaterThanOrEqualTo(3));
  });

  test('surfaces a failed integrity check instead of proceeding to render',
      () async {
    final filePath = await _writeTestZip(tempDir, 1024 * 1024);

    final adapter = _FakePodAdapter(rejectWithChecksumError: true);
    final api = InstanceApiService(dio: Dio()..httpClientAdapter = adapter);

    await expectLater(
      api.uploadProject(_job(), filePath),
      throwsA(predicate((e) => e.toString().contains('checksum'))),
    );
  });

  test('does not block the event loop while hashing and chunking', () async {
    // 101MB -> a whole-file hash plus three chunk hashes. Done on the calling
    // isolate that is seconds of solid synchronous CPU work; the Windows
    // embedder responds by filling its 10,000-entry message queue and logging
    // "Failed to post message to main thread" until the app is unusable.
    final filePath = await _writeTestZip(tempDir, 101 * 1024 * 1024);

    final adapter = _FakePodAdapter(hashBodies: false);
    final api = InstanceApiService(dio: Dio()..httpClientAdapter = adapter);

    var last = DateTime.now();
    var maxGapMs = 0;
    final ticker = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final now = DateTime.now();
      maxGapMs = max(maxGapMs, now.difference(last).inMilliseconds);
      last = now;
    });

    await api.uploadProject(_job(), filePath);
    ticker.cancel();

    expect(maxGapMs, lessThan(250),
        reason: 'event loop stalled for ${maxGapMs}ms — file reading and '
            'hashing must run on a worker isolate');
  });

  test('does not resume a session describing a different file', () async {
    final filePath = await _writeTestZip(tempDir, 1024 * 1024);

    // Same chunk count, different total size — matching on chunk count alone
    // would splice this upload onto a stale session's chunks.
    final adapter = _FakePodAdapter(existingSession: {
      'upload_id': 'stale-upload',
      'received_chunks': [0],
      'total_chunks': 1,
      'total_size': 999999,
      'chunk_size': InstanceApiService.chunkSize,
    });
    final api = InstanceApiService(dio: Dio()..httpClientAdapter = adapter);

    await api.uploadProject(_job(), filePath);

    // A fresh session was started and the chunk re-sent rather than trusted.
    expect(adapter.beginCalls, equals(1));
    expect(adapter.receivedOrder, equals([0]));
  });
}

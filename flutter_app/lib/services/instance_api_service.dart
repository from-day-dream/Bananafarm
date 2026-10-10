import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../models/job_model.dart';

/// Streams a file through SHA-256 on a worker isolate.
///
/// Hashing a multi-GB project zip on the UI isolate froze the Windows app: the
/// synchronous per-block work stops the platform thread from pumping messages
/// while every 64KB read completion keeps posting to the embedder's task
/// runner, whose message queue is capped at 10,000 entries. Past that,
/// PostMessage fails and the embedder logs "Failed to post message to main
/// thread" until the app is unusable.
Future<String> _hashFileInIsolate(String path) {
  return Isolate.run(() async {
    return (await sha256.bind(File(path).openRead()).first).toString();
  });
}

/// Reads one chunk and hashes it on a worker isolate, for the same reason as
/// [_hashFileInIsolate]. The bytes come back via `Isolate.exit`, which hands
/// the buffer over rather than copying it.
Future<(Uint8List, String)> _readAndHashChunkInIsolate(
    String path, int offset, int length) {
  return Isolate.run(() async {
    final raf = await File(path).open();
    try {
      await raf.setPosition(offset);
      final bytes = await raf.read(length);
      return (bytes, sha256.convert(bytes).toString());
    } finally {
      await raf.close();
    }
  });
}

/// Container-side job states reported by the render pod API.
class ContainerJobState {
  static const waitingForUpload = 'waiting_for_upload';
  static const receivingUpload = 'receiving_upload';
  static const assembling = 'assembling';
  static const extracting = 'extracting';
  static const rendering = 'rendering';
  static const zippingOutput = 'zipping_output';
  static const completed = 'completed';
  static const partiallyCompleted = 'partially_completed';
  static const failed = 'failed';

  static const terminal = {completed, partiallyCompleted, failed};

  /// States in which the pod still accepts chunks. `assembling` is
  /// deliberately excluded — re-entering the upload flow while the pod is
  /// assembling is what used to start a second, corrupting assembly.
  static const uploadable = {waitingForUpload, receivingUpload};
}

class ContainerStatus {
  final String state;
  final String? errorMessage;
  final bool outputsReady;

  ContainerStatus({
    required this.state,
    this.errorMessage,
    this.outputsReady = false,
  });
}

class ContainerProgress {
  final String state;
  final RenderProgressSnapshot progress;

  ContainerProgress({required this.state, required this.progress});
}

class OutputListing {
  final String state;
  final List<OutputFileInfo> files;

  OutputListing({required this.state, required this.files});
}

/// Thrown when the container refuses an operation because its job state
/// moved on (e.g. trying to upload while it is already rendering).
class InstanceStateException implements Exception {
  final String message;
  InstanceStateException(this.message);
  @override
  String toString() => message;
}

/// HTTP client for the render container's control API (FastAPI on the GPU
/// instance). Replaces both the Upstash Redis progress polling and the R2
/// upload/download paths of the old architecture.
class InstanceApiService {
  /// Kept under RunPod's Cloudflare proxy body limit (~100 MB).
  static const int chunkSize = 50 * 1024 * 1024;

  /// Chunks in flight simultaneously. Each holds up to [chunkSize] bytes in
  /// memory, so this bounds peak upload memory to roughly chunkSize * this.
  static const int uploadConcurrency = 4;

  /// Attempts per chunk before the whole upload pass is abandoned.
  static const int chunkUploadAttempts = 3;
  static const Duration chunkRetryBackoff = Duration(seconds: 2);

  /// How long to wait for the pod to concatenate and checksum the chunks.
  static const Duration assemblyTimeout = Duration(minutes: 60);
  static const Duration assemblyPollInterval = Duration(seconds: 3);

  /// Project zips are immutable per job, so their hash is worth caching across
  /// upload retries rather than re-reading gigabytes each time.
  static final Map<String, String> _zipHashCache = {};

  /// Job ids whose pod build stamp has already been logged.
  static final Set<String> _loggedBuilds = {};

  final Dio _dio;

  InstanceApiService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 60),
            ));

  Options _auth(RenderJob job, {Duration? sendTimeout}) => Options(
        headers: {'Authorization': 'Bearer ${job.apiToken}'},
        sendTimeout: sendTimeout,
      );

  String _url(RenderJob job, String path) => '${job.instanceEndpoint}$path';

  /// Unauthenticated readiness probe. False on any failure — the instance
  /// may still be booting or pulling the image.
  Future<bool> health(RenderJob job) async {
    if (job.instanceEndpoint == null) return false;
    try {
      final response = await _dio.get(
        _url(job, '/health'),
        options: Options(
          receiveTimeout: const Duration(seconds: 10),
          validateStatus: (s) => true,
        ),
      );
      if (response.statusCode != 200) return false;

      // Log the image build once per job. Providers cache images by tag, so a
      // node can serve an older build than the one just pushed — which
      // otherwise only shows up as errors that don't match the source.
      if (_loggedBuilds.add(job.id)) {
        final build = (response.data is Map)
            ? (response.data as Map)['build'] ?? 'unknown'
            : 'unknown';
        print('🏷️ Pod ${job.id} running image build: $build');
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<ContainerStatus> getStatus(RenderJob job) async {
    final response = await _dio.get(_url(job, '/status'), options: _auth(job));
    final data = response.data as Map;
    return ContainerStatus(
      state: data['state'] as String,
      errorMessage: data['error_message'] as String?,
      outputsReady: data['outputs_ready'] as bool? ?? false,
    );
  }

  Future<ContainerProgress> getProgress(RenderJob job) async {
    final response =
        await _dio.get(_url(job, '/progress'), options: _auth(job));
    final data = response.data as Map;
    return ContainerProgress(
      state: data['state'] as String,
      progress: RenderProgressSnapshot.fromJson(
          (data['progress'] as Map? ?? {}).cast<String, dynamic>()),
    );
  }

  /// Chunked, resumable upload of the project zip. If the container already
  /// holds a matching partial upload (same chunk count), only the missing
  /// chunks are sent.
  Future<void> uploadProject(
    RenderJob job,
    String zipPath, {
    void Function(double fraction)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final file = File(zipPath);
    final totalSize = await file.length();
    final totalChunks = max(1, (totalSize / chunkSize).ceil());
    final fileSha256 = await _zipSha256(file, totalSize);

    // Refuse early if the container is past the upload phase.
    final status = await getStatus(job);
    if (!ContainerJobState.uploadable.contains(status.state)) {
      throw InstanceStateException(
          'Container is in state "${status.state}", not accepting uploads');
    }

    // Resume an interrupted upload only when the session describes the exact
    // same file layout. Matching on chunk count alone would let chunks from a
    // different project splice into an existing session.
    String? uploadId;
    var received = <int>{};
    final sessionResponse =
        await _dio.get(_url(job, '/upload-project/status'), options: _auth(job));
    final session = sessionResponse.data as Map;
    if (session['upload_id'] != null &&
        session['total_chunks'] == totalChunks &&
        session['total_size'] == totalSize &&
        session['chunk_size'] == chunkSize) {
      uploadId = session['upload_id'] as String;
      received = ((session['received_chunks'] as List?) ?? [])
          .map((i) => (i as num).toInt())
          .toSet();
    }

    if (uploadId == null) {
      final beginResponse = await _dio.post(
        _url(job, '/upload-project/begin'),
        data: {
          'filename': file.uri.pathSegments.last,
          'total_size': totalSize,
          'total_chunks': totalChunks,
          'chunk_size': chunkSize,
          'sha256': fileSha256,
        },
        options: _auth(job),
      );
      uploadId = (beginResponse.data as Map)['upload_id'] as String;
      received = {};
    }

    final pendingIndices = [
      for (var index = 0; index < totalChunks; index++)
        if (!received.contains(index)) index,
    ];

    // Bytes the pod already holds. Counting each received chunk as a full
    // chunkSize over-reports whenever the short final chunk is among them.
    var uploadedBytes = received.fold<int>(
      0,
      (sum, index) => sum + max(0, min(chunkSize, totalSize - index * chunkSize)),
    );

    Future<void> uploadChunk(int index) async {
      if (cancelToken?.isCancelled ?? false) {
        throw InstanceStateException('Upload cancelled');
      }

      final offset = index * chunkSize;
      final length = min(chunkSize, totalSize - offset);

      // A fresh ranged read per chunk — safe to call concurrently, unlike
      // sharing one RandomAccessFile's seek position across workers. Read and
      // hashed on a worker isolate so a 50MB chunk never stalls the UI.
      final (bytes, chunkDigest) =
          await _readAndHashChunkInIsolate(file.path, offset, length);

      await _putChunkWithRetry(job, uploadId!, index, bytes, length, chunkDigest);

      // No `await` between the read and write below, so this is safe
      // without a lock despite running from multiple concurrent workers.
      uploadedBytes += length;
      onProgress?.call(min(1.0, uploadedBytes / totalSize));
    }

    await _uploadChunksConcurrently(pendingIndices, uploadChunk);

    await _dio.post(
      _url(job, '/upload-project/complete'),
      data: {'upload_id': uploadId},
      options: _auth(job).copyWith(
        // 202 (assembly started) and 200 (already started) are both success.
        validateStatus: (s) => s != null && s >= 200 && s < 300,
      ),
    );

    // The pod assembles and checksums the zip on a background thread, so the
    // wait happens here rather than in a long-held HTTP request — which no
    // proxy in front of the pod would tolerate anyway.
    await _awaitAssembly(job, cancelToken: cancelToken);
  }

  /// Polls until the pod finishes assembling the uploaded chunks. Throws if the
  /// integrity check failed and the pod reset itself to accept a fresh upload.
  Future<void> _awaitAssembly(RenderJob job, {CancelToken? cancelToken}) async {
    final deadline = DateTime.now().add(assemblyTimeout);

    while (DateTime.now().isBefore(deadline)) {
      if (cancelToken?.isCancelled ?? false) {
        throw InstanceStateException('Upload cancelled');
      }

      final status = await getStatus(job);
      if (status.state == ContainerJobState.waitingForUpload) {
        throw Exception(status.errorMessage ??
            'Pod rejected the uploaded project and is awaiting a new upload');
      }
      if (status.state != ContainerJobState.assembling &&
          status.state != ContainerJobState.receivingUpload) {
        return; // extracting or beyond — assembly succeeded
      }
      await Future<void>.delayed(assemblyPollInterval);
    }

    throw Exception(
        'Pod did not finish assembling the project within '
        '${assemblyTimeout.inMinutes} minutes');
  }

  /// A chunk rejected for length or checksum was corrupted in transit, so
  /// re-sending it is worthwhile. Retrying here keeps one blip on a flaky link
  /// from discarding an entire upload pass.
  Future<void> _putChunkWithRetry(
    RenderJob job,
    String uploadId,
    int index,
    Uint8List bytes,
    int length,
    String chunkDigest,
  ) async {
    for (var attempt = 1;; attempt++) {
      try {
        await _dio.put(
          _url(job, '/upload-project/chunk/$uploadId/$index'),
          data: Stream.fromIterable([bytes]),
          options: _auth(job, sendTimeout: const Duration(minutes: 15)).copyWith(
            headers: {
              'Authorization': 'Bearer ${job.apiToken}',
              'X-Chunk-Sha256': chunkDigest,
              Headers.contentLengthHeader: length,
              Headers.contentTypeHeader: 'application/octet-stream',
            },
          ),
        );
        return;
      } on DioException catch (e) {
        final code = e.response?.statusCode;
        // 400 is a length/checksum rejection — retryable. Anything else in the
        // 4xx range (unknown upload id, bad token, oversized) will not change
        // on a retry, and neither will an explicit cancellation.
        final retryable =
            code == null || code == 400 || code == 408 || code >= 500;
        if (!retryable ||
            attempt >= chunkUploadAttempts ||
            e.type == DioExceptionType.cancel) {
          rethrow;
        }
        await Future<void>.delayed(chunkRetryBackoff * attempt);
      }
    }
  }

  /// SHA-256 of the project zip, streamed so a multi-GB file is never held in
  /// memory. Cached because a retried upload re-reads the same immutable file.
  Future<String> _zipSha256(File file, int totalSize) async {
    final cacheKey = '${file.path}|$totalSize';
    final cached = _zipHashCache[cacheKey];
    if (cached != null) return cached;

    final digest = await _hashFileInIsolate(file.path);
    _zipHashCache[cacheKey] = digest;
    return digest;
  }

  /// Bounded worker pool: [uploadConcurrency] workers pull indices off a
  /// shared cursor until the list is exhausted. Fail-fast — the first error
  /// stops new dispatch, in-flight chunks are allowed to finish, then the
  /// error is rethrown. Safe to retry: the caller resumes from whatever the
  /// server reports as already received.
  Future<void> _uploadChunksConcurrently(
    List<int> indices,
    Future<void> Function(int index) uploadChunk,
  ) async {
    var cursor = 0;
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> worker() async {
      while (true) {
        if (firstError != null) return;
        if (cursor >= indices.length) return;
        final index = indices[cursor++];
        try {
          await uploadChunk(index);
        } catch (e, st) {
          firstError ??= e;
          firstStackTrace ??= st;
          return;
        }
      }
    }

    final workerCount = min(uploadConcurrency, indices.length);
    await Future.wait(List.generate(workerCount, (_) => worker()));

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  Future<OutputListing> listOutputs(RenderJob job) async {
    final response =
        await _dio.get(_url(job, '/outputs'), options: _auth(job));
    final data = response.data as Map;

    final files = <OutputFileInfo>[];
    final archive = data['archive'];
    if (archive is Map) {
      // The archive supersedes the individual frames for download purposes.
      files.add(OutputFileInfo(
        name: archive['name'] as String,
        size: (archive['size'] as num?)?.toInt() ?? 0,
        isArchive: true,
      ));
    } else {
      for (final f in (data['files'] as List? ?? [])) {
        if (f is Map) {
          files.add(OutputFileInfo(
            name: f['name'] as String,
            size: (f['size'] as num?)?.toInt() ?? 0,
          ));
        }
      }
    }
    return OutputListing(state: data['state'] as String, files: files);
  }

  Future<void> downloadOutput(
    RenderJob job,
    String fileName,
    String destPath, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    await _dio.download(
      _url(job, '/outputs/${Uri.encodeComponent(fileName)}'),
      destPath,
      options: Options(
        headers: {'Authorization': 'Bearer ${job.apiToken}'},
        receiveTimeout: const Duration(hours: 2),
      ),
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// Ask the container to stop the render gracefully (salvages partial
  /// animation frames). Best-effort — errors are swallowed.
  Future<void> stopRender(RenderJob job) async {
    if (job.instanceEndpoint == null) return;
    try {
      await _dio.post(_url(job, '/control/stop'), options: _auth(job));
    } catch (e) {
      print('⚠️ stopRender failed (instance may be gone): $e');
    }
  }
}

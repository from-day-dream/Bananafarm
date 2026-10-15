import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bananafarm/models/instance_models.dart';
import 'package:bananafarm/models/render_provider.dart';
import 'package:bananafarm/services/providers/runpod_api_service.dart';
import 'package:bananafarm/services/providers/vast_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Vast: answers request_logs with a result_url, then serves the log file
/// after [notReadyFor] 404s (S3 before the file is written).
class _VastLogsAdapter implements HttpClientAdapter {
  final int notReadyFor;
  final List<Map<String, dynamic>> logRequests = [];
  int s3Hits = 0;

  _VastLogsAdapter({this.notReadyFor = 0});

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.path.contains('/request_logs/')) {
      logRequests.add(Map<String, dynamic>.from(options.data as Map));
      return ResponseBody.fromString(
        jsonEncode({'success': true, 'result_url': 'https://s3.test/log.txt'}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    s3Hits++;
    if (s3Hits <= notReadyFor) {
      return ResponseBody.fromString('<Error>NoSuchKey</Error>', 404);
    }
    return ResponseBody.fromString('line one\nline two\n', 200);
  }
}

/// RunPod: an SSE stream that sends [events] and then stays open, like the
/// real endpoint.
class _SseAdapter implements HttpClientAdapter {
  final List<String> events;
  RequestOptions? request;

  _SseAdapter(this.events);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    request = options;
    final controller = StreamController<Uint8List>();
    for (final e in events) {
      controller.add(Uint8List.fromList(utf8.encode(e)));
    }
    // Never closed: the client must stop on its own once it goes quiet.
    return ResponseBody(controller.stream, 200, headers: {
      Headers.contentTypeHeader: ['text/event-stream'],
    });
  }
}

void main() {
  group('Vast getLogs', () {
    test('container logs omit daemon_logs and follow result_url', () async {
      final adapter = _VastLogsAdapter();
      final service =
          VastApiService(apiKey: 'k', dio: Dio()..httpClientAdapter = adapter);

      final logs =
          await service.getLogs('42', source: InstanceLogSource.container);

      expect(logs, 'line one\nline two\n');
      expect(adapter.logRequests.single, {'tail': '1000'});
    });

    test('system logs ask for daemon logs', () async {
      final adapter = _VastLogsAdapter();
      final service =
          VastApiService(apiKey: 'k', dio: Dio()..httpClientAdapter = adapter);

      await service.getLogs('42', source: InstanceLogSource.system, tail: 200);

      expect(adapter.logRequests.single, {'tail': '200', 'daemon_logs': 'true'});
    });

    test('waits for the log file to appear on S3', () async {
      final adapter = _VastLogsAdapter(notReadyFor: 1);
      final service =
          VastApiService(apiKey: 'k', dio: Dio()..httpClientAdapter = adapter);

      final logs =
          await service.getLogs('42', source: InstanceLogSource.container);

      expect(logs, contains('line one'));
      expect(adapter.s3Hits, 2);
    });
  });

  test('RunPod getLogs reads SSE events and stops once quiet', () async {
    final adapter = _SseAdapter([
      'id: 2026-10-15T12:00:00Z/1\n',
      'data: {"source":"system","line":"Pulling image","ts":"t1"}\n\n',
      ': heartbeat\n',
      'data: {"source":"system","line":"Container started","ts":"t2"}\n\n',
    ]);
    final service = RunpodApiService(
      apiKey: 'k',
      provider: RenderProvider.runpodCommunity,
      dio: Dio()..httpClientAdapter = adapter,
    );

    final watch = Stopwatch()..start();
    final logs = await service.getLogs('pod1', source: InstanceLogSource.system);

    expect(logs, 'Pulling image\nContainer started');
    expect(adapter.request!.uri.toString(),
        contains('/v2/pods/pod1/logs?source=system&tail=1000'));
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)),
        reason: 'stops after the quiet period, not the hard cap');
  });
}

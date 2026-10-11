// Regression test for the "No such container: C.<id>" stuck-job bug.
//
// Vast.ai proxies raw Docker daemon errors through its own API when a rented
// contract's underlying host container never actually started. getInstance()
// must treat that the same as a clean 404 (ProviderInstanceState.missing)
// instead of throwing, so RenderJobManager can fail the job promptly rather
// than silently retrying forever.
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bananafarm/models/instance_models.dart';
import 'package:bananafarm/services/providers/gpu_provider_service.dart';
import 'package:bananafarm/services/providers/vast_api_service.dart';

/// Minimal fake adapter that returns a fixed status/body for every request,
/// avoiding a mocking package dependency for this one test.
class _FixedResponseAdapter implements HttpClientAdapter {
  final int statusCode;
  final Map<String, dynamic> body;

  _FixedResponseAdapter(this.statusCode, this.body);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final bytes = Uint8List.fromList(
        '{"msg":"${body['msg']}","success":false}'.codeUnits);
    return ResponseBody.fromBytes(bytes, statusCode,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        });
  }
}

void main() {
  test('getInstance treats "No such container" as missing, not an error',
      () async {
    final dio = Dio()
      ..httpClientAdapter = _FixedResponseAdapter(500, {
        'msg': 'Error response from daemon: No such container: C.44674917',
      });
    final service = VastApiService(apiKey: 'test-key', dio: dio);

    final status = await service.getInstance('44674917');

    expect(status.state, ProviderInstanceState.missing);
  });

  test('getInstance still throws on unrelated 500 errors', () async {
    final dio = Dio()
      ..httpClientAdapter =
          _FixedResponseAdapter(500, {'msg': 'Internal server error'});
    final service = VastApiService(apiKey: 'test-key', dio: dio);

    expect(
      () => service.getInstance('44674917'),
      throwsA(isA<ProviderApiException>()),
    );
  });

  test('getInstance still treats a plain 404 as missing', () async {
    final dio = Dio()
      ..httpClientAdapter = _FixedResponseAdapter(404, {'msg': 'not found'});
    final service = VastApiService(apiKey: 'test-key', dio: dio);

    final status = await service.getInstance('44674917');

    expect(status.state, ProviderInstanceState.missing);
  });
}

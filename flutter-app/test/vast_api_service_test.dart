// Regression test for the "No such container: C.<id>" stuck-job bug.
//
// Vast.ai proxies raw Docker daemon errors through its own API when a rented
// contract's underlying host container never actually started. getInstance()
// must treat that the same as a clean 404 (ProviderInstanceState.missing)
// instead of throwing, so RenderJobManager can fail the job promptly rather
// than silently retrying forever.
import 'dart:async';
import 'dart:typed_data';

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bananafarm/models/gpu_offer.dart';
import 'package:bananafarm/models/instance_models.dart';
import 'package:bananafarm/models/render_provider.dart';
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

/// Serves an offer search, then answers each `PUT /asks/{id}/` from [asks].
/// Records the offer ids that were attempted, in order.
class _OfferAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> offers;
  final Map<int, (int, Map<String, dynamic>)> asks;
  final List<int> attempted = [];

  /// Request bodies by path, to check what was sent.
  final Map<String, dynamic> bodies = {};

  _OfferAdapter(this.offers, this.asks);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    bodies[options.path] = options.data;
    var status = 200;
    Object body = {'offers': offers};
    final ask = RegExp(r'/asks/(\d+)/').firstMatch(options.path);
    if (ask != null) {
      final id = int.parse(ask.group(1)!);
      attempted.add(id);
      (status, body) = asks[id]!;
    }
    return ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }
}

/// Answers every request with [body].
class _JsonAdapter implements HttpClientAdapter {
  final Map<String, dynamic> body;
  _JsonAdapter(this.body);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      ResponseBody.fromString(jsonEncode(body), 200, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });
}

InstanceRequest _request3090() => InstanceRequest(
      jobId: 'job-1',
      gpu: GpuOffer(
        provider: RenderProvider.vast,
        gpuName: 'RTX 3090',
        gpuId: 'RTX 3090',
      ),
      dockerImage: 'docker.io/example/render:test',
      blenderVersion: '5.2.1',
      renderParams: const {},
      apiToken: 'token',
      diskGb: 32,
    );

const _gone = (
  400,
  {
    'msg': 'error 404/3603: no_such_ask  Instance type by id 1 is not available.',
  }
);

void main() {
  test('createInstance rents the cheapest offer with the configured disk',
      () async {
    final adapter = _OfferAdapter(
      [
        {'id': 1, 'reliability': 0.999, 'dph_total': 0.40},
        {'id': 2, 'reliability': 0.96, 'dph_total': 0.19},
      ],
      {2: (200, {'success': true, 'new_contract': 9})},
    );
    final service =
        VastApiService(apiKey: 'k', dio: Dio()..httpClientAdapter = adapter);

    await service.createInstance(_request3090());

    expect(adapter.attempted, [2]);
    final search = adapter.bodies.entries
        .firstWhere((e) => e.key.endsWith('/bundles/'))
        .value as Map;
    expect(search['allocated_storage'], 32);
    final ask = adapter.bodies.entries
        .firstWhere((e) => e.key.contains('/asks/2/'))
        .value as Map;
    expect(ask['disk'], 32);
  });

  test('getBalance prefers credit and falls back to balance', () async {
    Future<double> balanceFrom(Map<String, dynamic> body) async {
      final dio = Dio()..httpClientAdapter = _JsonAdapter(body);
      return (await VastApiService(apiKey: 'k', dio: dio).getBalance())
          .balance;
    }

    expect(await balanceFrom({'credit': 12.5, 'balance': 0}), 12.5);
    expect(await balanceFrom({'balance': 3.25}), 3.25);
  });

  test('getInstance reports the contract rate', () async {
    final dio = Dio()
      ..httpClientAdapter = _JsonAdapter({
        'instances': {'actual_status': 'loading', 'dph_total': 0.2185},
      });
    final status =
        await VastApiService(apiKey: 'k', dio: dio).getInstance('1');
    expect(status.pricePerHour, 0.2185);
  });

  test('createInstance skips an offer that is already gone', () async {
    final adapter = _OfferAdapter(
      [
        {'id': 1, 'reliability': 0.99, 'dph_total': 0.20},
        {'id': 2, 'reliability': 0.98, 'dph_total': 0.25},
      ],
      {
        1: _gone,
        2: (200, {'success': true, 'new_contract': 777}),
      },
    );
    final service =
        VastApiService(apiKey: 'k', dio: Dio()..httpClientAdapter = adapter);

    final created = await service.createInstance(_request3090());

    expect(created.instanceId, '777');
    expect(adapter.attempted, [1, 2]);
  });

  test('createInstance gives a clear error when every offer is gone', () async {
    final adapter = _OfferAdapter(
      [
        {'id': 1, 'reliability': 0.99, 'dph_total': 0.20},
        {'id': 2, 'reliability': 0.98, 'dph_total': 0.25},
      ],
      {1: _gone, 2: _gone},
    );
    final service =
        VastApiService(apiKey: 'k', dio: Dio()..httpClientAdapter = adapter);

    await expectLater(
      service.createInstance(_request3090()),
      throwsA(isA<ProviderApiException>().having(
          (e) => e.message, 'message', contains('No RTX 3090 offer'))),
    );
    expect(adapter.attempted, [1, 2]);
  });

  test('createInstance does not retry unrelated errors', () async {
    final adapter = _OfferAdapter(
      [
        {'id': 1, 'reliability': 0.99, 'dph_total': 0.20},
        {'id': 2, 'reliability': 0.98, 'dph_total': 0.25},
      ],
      {
        1: (401, {'msg': 'invalid api key'}),
      },
    );
    final service =
        VastApiService(apiKey: 'k', dio: Dio()..httpClientAdapter = adapter);

    await expectLater(service.createInstance(_request3090()),
        throwsA(isA<ProviderApiException>()));
    expect(adapter.attempted, [1]);
  });

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

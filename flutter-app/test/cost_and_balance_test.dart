import 'dart:convert';
import 'dart:typed_data';

import 'package:bananafarm/constants/app_constants.dart';
import 'package:bananafarm/models/job_model.dart';
import 'package:bananafarm/models/render_provider.dart';
import 'package:bananafarm/providers/settings_provider.dart';
import 'package:bananafarm/services/providers/runpod_api_service.dart';
import 'package:bananafarm/widgets/live_cost_text.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

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

RenderJob _job({
  DateTime? instanceCreatedAt,
  double? pricePerHour = 0.20,
  double? ratePerHour,
}) =>
    RenderJob(
      id: 'j1',
      status: LocalJobStatus.rendering,
      provider: RenderProvider.vast,
      gpuName: 'RTX 3090',
      pricePerHour: pricePerHour,
      instanceId: '123',
      apiToken: 't',
      blenderVersion: '5.2.1',
      renderParams: RenderParams.fromJson({}),
      createdAt: DateTime(2026, 10, 15, 12),
      instanceCreatedAt: instanceCreatedAt,
      ratePerHour: ratePerHour,
    );

void main() {
  final start = DateTime(2026, 10, 15, 12);

  group('RenderJob cost', () {
    test('is rate × hours since the instance was rented', () {
      final job = _job(instanceCreatedAt: start, ratePerHour: 0.30);
      expect(job.costSoFar(start.add(const Duration(hours: 2))),
          closeTo(0.60, 1e-9));
    });

    test('falls back to the offer price before the real rate is known', () {
      final job = _job(instanceCreatedAt: start);
      expect(job.costSoFar(start.add(const Duration(minutes: 30))),
          closeTo(0.10, 1e-9));
    });

    test('stops counting once the instance is deleted', () {
      final job = _job(
        instanceCreatedAt: DateTime.now().subtract(const Duration(hours: 1)),
        ratePerHour: 0.30,
      ).copyWith(instanceDestroyed: true);

      expect(job.instanceDestroyedAt, isNotNull);
      final later = DateTime.now().add(const Duration(hours: 5));
      expect(job.costSoFar(later), closeTo(0.30, 0.001));
      expect(LiveCostText.format(job, later), endsWith('total'));
    });

    test('is unknown for jobs saved before cost tracking', () {
      expect(_job().costSoFar(DateTime.now()), isNull);
      expect(LiveCostText.format(_job(), DateTime.now()), isNull);
    });

    test('new fields survive a JSON round trip', () {
      final job = _job(instanceCreatedAt: start, ratePerHour: 0.31)
          .copyWith(instanceDestroyed: true);
      final back = RenderJob.fromJson(job.toJson());
      expect(back.instanceCreatedAt, start);
      expect(back.instanceDestroyedAt, job.instanceDestroyedAt);
      expect(back.ratePerHour, 0.31);
    });
  });

  test('live cost text shows running total and rate', () {
    final job = _job(instanceCreatedAt: start, ratePerHour: 0.21);
    expect(LiveCostText.format(job, start.add(const Duration(hours: 2))),
        '\$0.42 so far · \$0.21/hr');
  });

  test('instance storage is clamped to the allowed range', () {
    expect(AppConstants.defaultInstanceStorageGb, 32);
    expect(clampInstanceStorageGb(4), AppConstants.minInstanceStorageGb);
    expect(clampInstanceStorageGb(5000), AppConstants.maxInstanceStorageGb);
    expect(clampInstanceStorageGb(64), 64);
  });

  group('RunPod', () {
    RunpodApiService service(Map<String, dynamic> body) => RunpodApiService(
          apiKey: 'k',
          provider: RenderProvider.runpodCommunity,
          dio: Dio()..httpClientAdapter = _JsonAdapter(body),
        );

    test('getBalance reads clientBalance and spend rate', () async {
      final b = await service({
        'data': {
          'myself': {'clientBalance': 42.5, 'currentSpendPerHr': 0.44},
        },
      }).getBalance();
      expect(b.balance, 42.5);
      expect(b.spendPerHour, 0.44);
    });

    test('GPU prices include container disk', () async {
      final offers = await service({
        'data': {
          'gpuTypes': [
            {
              'id': 'NVIDIA GeForce RTX 3090',
              'displayName': 'RTX 3090',
              'communityPrice': 0.22,
              'lowestPrice': {'stockStatus': 'High'},
            },
          ],
        },
      }).listGpus(diskGb: 73);
      // 73 GB × $0.10/GB/month ÷ 730 h = $0.01/hr
      expect(offers.single.pricePerHour, closeTo(0.23, 1e-9));
    });

    test('getInstance adds container disk to the pod rate', () async {
      final status = await service({
        'desiredStatus': 'RUNNING',
        'costPerHr': 0.22,
        'containerDiskInGb': 73,
      }).getInstance('pod1');
      expect(status.pricePerHour, closeTo(0.23, 1e-9));
    });
  });
}

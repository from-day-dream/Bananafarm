import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../models/gpu_offer.dart';
import '../../models/instance_models.dart';
import '../../models/render_provider.dart';
import 'gpu_provider_service.dart';

/// Direct RunPod API client. One class serves both marketplaces —
/// construct with [RenderProvider.runpodSecure] or [RenderProvider.runpodCommunity].
///
/// GPU catalog + stock come from the GraphQL API; pod lifecycle uses the
/// REST API (rest.runpod.io/v1). The container is reached through RunPod's
/// HTTP proxy: https://{podId}-8000.proxy.runpod.net.
class RunpodApiService implements GpuProviderService {
  static const _restUrl = 'https://rest.runpod.io/v1';
  static const _graphqlUrl = 'https://api.runpod.io/graphql';
  static const _logsUrl = 'https://api.runpod.io/v2/pods';

  /// The log endpoint is a live SSE stream that never ends by itself. The
  /// backfill arrives in a burst, so stop once the stream goes quiet — or at
  /// the hard cap if a busy container keeps it chattering.
  static const _logQuietPeriod = Duration(milliseconds: 1500);
  static const _logMaxWait = Duration(seconds: 8);

  final String apiKey;
  @override
  final RenderProvider provider;
  final Dio _dio;

  RunpodApiService({
    required this.apiKey,
    required this.provider,
    Dio? dio,
  })  : assert(provider == RenderProvider.runpodSecure ||
            provider == RenderProvider.runpodCommunity),
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 40),
            ));

  bool get _secureCloud => provider == RenderProvider.runpodSecure;

  /// Container disk is billed at $0.10/GB/month while the pod runs; RunPod's
  /// GPU prices leave it out, so it is added to every rate shown.
  static double storagePerHour(int diskGb) => diskGb * 0.10 / 730;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      };

  @override
  Future<List<GpuOffer>> listGpus({required int diskGb}) async {
    // One query covers the whole catalog: prices per marketplace plus a
    // stock signal for this marketplace's cloud.
    final query = '''
      query {
        gpuTypes {
          id
          displayName
          memoryInGb
          securePrice
          communityPrice
          lowestPrice(input: { gpuCount: 1, secureCloud: $_secureCloud }) {
            stockStatus
          }
        }
      }
    ''';

    final response = await _request(
      () => _dio.post(
        _graphqlUrl,
        data: {'query': query},
        options: Options(headers: _headers),
      ),
    );

    final data = response.data;
    if (data is Map && data['errors'] != null) {
      throw ProviderApiException(provider, data['errors'].toString());
    }
    final gpuTypes =
        (data is Map ? (data['data']?['gpuTypes']) : null) as List?;
    if (gpuTypes == null) {
      throw ProviderApiException(
          provider, 'Unexpected GraphQL response: ${response.data}');
    }

    final offers = <GpuOffer>[];
    for (final gpu in gpuTypes) {
      if (gpu is! Map) continue;
      final price =
          (gpu[_secureCloud ? 'securePrice' : 'communityPrice'] as num?)
              ?.toDouble();
      // No price on this marketplace means the GPU isn't offered there.
      if (price == null || price <= 0) continue;

      offers.add(GpuOffer(
        provider: provider,
        gpuName: (gpu['displayName'] as String?) ?? (gpu['id'] as String? ?? ''),
        gpuId: gpu['id'] as String? ?? '',
        pricePerHour: price + storagePerHour(diskGb),
        memoryGb: (gpu['memoryInGb'] as num?)?.round(),
        stockStatus: gpu['lowestPrice']?['stockStatus'] as String?,
      ));
    }

    offers.sort((a, b) => (a.pricePerHour ?? double.infinity)
        .compareTo(b.pricePerHour ?? double.infinity));
    return offers;
  }

  @override
  Future<CreatedInstance> createInstance(InstanceRequest request) async {
    final payload = {
      'name': 'bananafarm-${request.jobId}',
      'imageName': request.dockerImage,
      'computeType': 'GPU',
      'gpuCount': 1,
      'cloudType': _secureCloud ? 'SECURE' : 'COMMUNITY',
      'interruptible': false,
      'gpuTypeIds': [request.gpu.gpuId],
      'gpuTypePriority': 'availability',
      'containerDiskInGb': request.diskGb,
      'volumeInGb': 0,
      'minVCPUPerGPU': 8,
      'minRAMPerGPU': 16,
      'minDownloadMbps': 500,
      'supportPublicIp': true,
      // Exposes container port 8000 via the RunPod HTTP proxy.
      'ports': ['8000/http'],
      'env': GpuProviderService.containerEnv(request),
    };

    final response = await _request(
      () => _dio.post(
        '$_restUrl/pods',
        data: payload,
        options: Options(headers: _headers),
      ),
    );

    final data = response.data;
    final id = data is Map ? data['id'] as String? : null;
    if (id == null) {
      throw ProviderApiException(provider, 'Pod creation failed: ${response.data}');
    }
    return CreatedInstance(instanceId: id);
  }

  @override
  Future<InstanceStatus> getInstance(String instanceId,
      {String? instanceName}) async {
    final Response response;
    try {
      response = await _dio.get(
        '$_restUrl/pods/$instanceId',
        options: Options(headers: _headers),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return InstanceStatus(state: ProviderInstanceState.missing);
      }
      throw _wrap(e);
    }

    final data = response.data;
    final status = (data is Map ? data['desiredStatus'] as String? : null) ?? '';
    final rate = data is Map ? _podRate(data) : null;
    switch (status.toUpperCase()) {
      case 'RUNNING':
        return InstanceStatus(
          state: ProviderInstanceState.running,
          endpoint: 'https://$instanceId-8000.proxy.runpod.net',
          pricePerHour: rate,
        );
      case 'EXITED':
      case 'TERMINATED':
        return InstanceStatus(
            state: ProviderInstanceState.stopped, pricePerHour: rate);
      default:
        return InstanceStatus(
            state: ProviderInstanceState.pending, pricePerHour: rate);
    }
  }

  /// The pod's GPU rate plus its container disk, when the response has it.
  double? _podRate(Map data) {
    // adjustedCostPerHr is what is actually billed after Savings Plans.
    final gpuRate = num.tryParse(
            '${data['adjustedCostPerHr'] ?? data['costPerHr'] ?? ''}')
        ?.toDouble();
    if (gpuRate == null || gpuRate <= 0) return null;
    final diskGb = (data['containerDiskInGb'] as num?)?.toInt() ?? 0;
    return gpuRate + storagePerHour(diskGb);
  }

  @override
  Future<String> getLogs(
    String instanceId, {
    required InstanceLogSource source,
    int tail = 1000,
    String? instanceName,
  }) async {
    final cancel = CancelToken();
    final Response<ResponseBody> response;
    try {
      response = await _dio.get<ResponseBody>(
        '$_logsUrl/$instanceId/logs',
        queryParameters: {
          'source': source == InstanceLogSource.system ? 'system' : 'container',
          'tail': tail.clamp(0, 5000),
        },
        options: Options(
          headers: {..._headers, 'Accept': 'text/event-stream'},
          responseType: ResponseType.stream,
        ),
        cancelToken: cancel,
      );
    } on DioException catch (e) {
      throw _wrap(e);
    }

    final lines = <String>[];
    final done = Completer<void>();
    Timer? quiet;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    void restartQuietTimer() {
      quiet?.cancel();
      quiet = Timer(_logQuietPeriod, finish);
    }

    final subscription = response.data!.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (raw) {
        restartQuietTimer();
        final line = _sseLogLine(raw);
        if (line != null) lines.add(line);
      },
      onError: (_) => finish(),
      onDone: finish,
      cancelOnError: true,
    );
    restartQuietTimer();
    final hardStop = Timer(_logMaxWait, finish);

    await done.future;
    quiet?.cancel();
    hardStop.cancel();
    await subscription.cancel();
    cancel.cancel();
    return lines.join('\n');
  }

  /// The log text of one SSE line, or null for ids, comments, heartbeats and
  /// anything that isn't a log event.
  static String? _sseLogLine(String raw) {
    if (!raw.startsWith('data:')) return null;
    final payload = raw.substring(5).trim();
    if (payload.isEmpty) return null;
    try {
      final event = jsonDecode(payload);
      if (event is Map && event['line'] != null) return '${event['line']}';
    } on FormatException {
      return payload;
    }
    return null;
  }

  @override
  Future<ProviderBalance> getBalance() async {
    final response = await _request(
      () => _dio.post(
        _graphqlUrl,
        data: {'query': 'query { myself { clientBalance currentSpendPerHr } }'},
        options: Options(headers: _headers),
      ),
    );
    final data = response.data;
    if (data is Map && data['errors'] != null) {
      throw ProviderApiException(provider, data['errors'].toString());
    }
    final myself = data is Map ? (data['data']?['myself']) : null;
    final balance = myself is Map ? myself['clientBalance'] : null;
    if (balance is! num) {
      throw ProviderApiException(
          provider, 'Unexpected account response: ${response.data}');
    }
    return ProviderBalance(
      balance: balance.toDouble(),
      spendPerHour: (myself['currentSpendPerHr'] as num?)?.toDouble(),
    );
  }

  @override
  Future<void> destroyInstance(String instanceId, {String? instanceName}) async {
    try {
      await _dio.delete(
        '$_restUrl/pods/$instanceId',
        options: Options(headers: _headers),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return; // already gone
      throw _wrap(e);
    }
  }

  Future<Response> _request(Future<Response> Function() fn) async {
    try {
      return await fn();
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  ProviderApiException _wrap(DioException e) {
    final body = e.response?.data;
    final message = body is Map && body['error'] != null
        ? body['error'].toString()
        : (e.message ?? 'Request failed');
    return ProviderApiException(provider, message,
        statusCode: e.response?.statusCode);
  }
}

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

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      };

  @override
  Future<List<GpuOffer>> listGpus() async {
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
        pricePerHour: price,
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
      'containerDiskInGb': 60,
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
    switch (status.toUpperCase()) {
      case 'RUNNING':
        return InstanceStatus(
          state: ProviderInstanceState.running,
          endpoint: 'https://$instanceId-8000.proxy.runpod.net',
        );
      case 'EXITED':
      case 'TERMINATED':
        return InstanceStatus(state: ProviderInstanceState.stopped);
      default:
        return InstanceStatus(state: ProviderInstanceState.pending);
    }
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

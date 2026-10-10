import 'package:dio/dio.dart';

import '../../models/gpu_offer.dart';
import '../../models/instance_models.dart';
import '../../models/render_provider.dart';
import 'gpu_provider_service.dart';

/// Direct Vast.ai API client (https://console.vast.ai/api/v0).
///
/// Deployment flow: search offers for the GPU name, pick the most reliable
/// offer, then rent it with the render image. The old Supabase deploy relied
/// on a Vast template for disk/ports; those are now inlined in the payload.
class VastApiService implements GpuProviderService {
  static const _baseUrl = 'https://console.vast.ai/api/v0';

  final String apiKey;
  final Dio _dio;

  /// Which Vast marketplace this client queries. One key serves both, so the
  /// tier is carried here rather than being a second credential.
  @override
  final RenderProvider provider;

  VastApiService({
    required this.apiKey,
    this.provider = RenderProvider.vast,
    Dio? dio,
  })  : assert(provider == RenderProvider.vast ||
            provider == RenderProvider.vastSecure),
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 40),
            ));

  bool get _secureCloud => provider == RenderProvider.vastSecure;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      };

  /// Base search filters — same shape the old deploy-job edge function used,
  /// minus the gpu_name filter so every available GPU model is returned.
  ///
  /// Both the catalog and deployment go through here, so the tier the user
  /// browsed is necessarily the tier they rent from.
  Map<String, dynamic> _searchBody({String? gpuName}) => {
        // `verified` is Vast's host-vetting flag and applies to both tiers —
        // it is a quality gate, not the secure/standard selector. The tier is
        // `datacenter`, which narrows to Vast's trusted-datacenter partners;
        // omitting it leaves the wider pool, which is what this app has always
        // searched and what a stored 'vast' job record means.
        'verified': {'eq': true},
        if (_secureCloud) 'datacenter': {'eq': true},
        'rentable': {'eq': true},
        'rented': {'eq': false},
        'type': 'on-demand',
        'reliability': {'gt': 0.95},
        'num_gpus': {'eq': 1},
        'cpu_cores': {'gt': 8},
        // Only machines with open ports can expose the container API.
        'direct_port_count': {'gt': 0},
        if (gpuName != null) 'gpu_name': {'eq': gpuName},
      };

  Future<List<dynamic>> _searchOffers({String? gpuName}) async {
    final response = await _request(
      () => _dio.post(
        '$_baseUrl/bundles/',
        data: _searchBody(gpuName: gpuName),
        options: Options(headers: _headers),
      ),
    );
    final data = response.data;
    if (data is Map && data['offers'] is List) {
      return data['offers'] as List;
    }
    return [];
  }

  @override
  Future<List<GpuOffer>> listGpus() async {
    final offers = await _searchOffers();

    // Aggregate offers by GPU model: cheapest price, offer count, memory.
    final byGpu = <String, List<Map<String, dynamic>>>{};
    for (final offer in offers) {
      if (offer is! Map<String, dynamic>) continue;
      final name = offer['gpu_name'] as String?;
      if (name == null || name.isEmpty) continue;
      byGpu.putIfAbsent(name, () => []).add(offer);
    }

    final result = byGpu.entries.map((entry) {
      final prices = entry.value
          .map((o) => (o['dph_total'] as num?)?.toDouble())
          .whereType<double>()
          .toList()
        ..sort();
      final ramMb = (entry.value.first['gpu_ram'] as num?)?.toDouble();
      return GpuOffer(
        provider: provider,
        gpuName: entry.key,
        gpuId: entry.key,
        pricePerHour: prices.isNotEmpty ? prices.first : null,
        memoryGb: ramMb != null ? (ramMb / 1024).round() : null,
        availability: entry.value.length,
      );
    }).toList()
      ..sort((a, b) =>
          (a.pricePerHour ?? double.infinity).compareTo(b.pricePerHour ?? double.infinity));

    return result;
  }

  @override
  Future<CreatedInstance> createInstance(InstanceRequest request) async {
    final offers = await _searchOffers(gpuName: request.gpu.gpuId);
    if (offers.isEmpty) {
      throw ProviderApiException(
          provider, 'No offers available for ${request.gpu.gpuName}');
    }

    offers.sort((a, b) => ((b['reliability'] as num?) ?? 0)
        .compareTo((a['reliability'] as num?) ?? 0));
    final bestOffer = offers.first as Map<String, dynamic>;
    final offerId = bestOffer['id'];

    final env = <String, String>{
      ...GpuProviderService.containerEnv(request),
      // Vast port-mapping convention: -p entries go into the env map.
      '-p 8000:8000': '1',
    };

    final payload = {
      'client_id': 'me',
      'image': request.dockerImage,
      'label': 'bananafarm-${request.jobId}',
      'disk': 60,
      'runtype': 'args',
      'env': env,
    };

    final response = await _request(
      () => _dio.put(
        '$_baseUrl/asks/$offerId/',
        data: payload,
        options: Options(headers: _headers),
      ),
    );

    final data = response.data;
    if (data is! Map || data['success'] != true || data['new_contract'] == null) {
      throw ProviderApiException(
          provider, 'Instance creation failed: ${response.data}');
    }
    return CreatedInstance(instanceId: data['new_contract'].toString());
  }

  @override
  Future<InstanceStatus> getInstance(String instanceId,
      {String? instanceName}) async {
    final Response response;
    try {
      response = await _dio.get(
        '$_baseUrl/instances/$instanceId/',
        options: Options(headers: _headers),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404 || _isContainerMissing(e)) {
        // Vast proxies raw Docker daemon errors (e.g. "Error response from
        // daemon: No such container: C.<id>") when the host never actually
        // started the container for a rented contract. Treat the same as
        // a clean 404 rather than a fatal error.
        return InstanceStatus(state: ProviderInstanceState.missing);
      }
      throw _wrap(e);
    }

    final data = response.data;
    final instance = data is Map ? data['instances'] : null;
    if (instance == null || (instance is Map && instance.isEmpty)) {
      return InstanceStatus(state: ProviderInstanceState.missing);
    }

    final actualStatus = (instance['actual_status'] as String?) ?? '';
    if (actualStatus == 'exited' || actualStatus == 'stopped') {
      return InstanceStatus(state: ProviderInstanceState.stopped);
    }
    if (actualStatus != 'running') {
      return InstanceStatus(state: ProviderInstanceState.pending);
    }

    // Endpoint = public IP + host port mapped to container port 8000.
    final publicIp = instance['public_ipaddr'] as String?;
    final ports = instance['ports'];
    String? hostPort;
    if (ports is Map && ports['8000/tcp'] is List) {
      final mappings = ports['8000/tcp'] as List;
      if (mappings.isNotEmpty && mappings.first is Map) {
        hostPort = (mappings.first as Map)['HostPort']?.toString();
      }
    }

    if (publicIp == null || hostPort == null) {
      // Running but port mapping not published yet — keep polling.
      return InstanceStatus(state: ProviderInstanceState.pending);
    }
    return InstanceStatus(
      state: ProviderInstanceState.running,
      endpoint: 'http://${publicIp.trim()}:$hostPort',
    );
  }

  @override
  Future<void> destroyInstance(String instanceId, {String? instanceName}) async {
    try {
      await _dio.delete(
        '$_baseUrl/instances/$instanceId/',
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
    final message = body is Map && body['msg'] != null
        ? body['msg'].toString()
        : (e.message ?? 'Request failed');
    return ProviderApiException(provider, message,
        statusCode: e.response?.statusCode);
  }

  bool _isContainerMissing(DioException e) {
    final body = e.response?.data;
    final msg = body is Map && body['msg'] != null ? body['msg'].toString() : '';
    return msg.toLowerCase().contains('no such container');
  }
}

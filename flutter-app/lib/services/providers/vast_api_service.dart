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
  Map<String, dynamic> _searchBody({String? gpuName, required int diskGb}) => {
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
        // Prices each offer's storage at this size, so dph_total is the full
        // hourly rate for the disk we will actually rent. Storage rates vary
        // widely by host, so this changes which offer is cheapest.
        'allocated_storage': diskGb,
      };

  Future<List<dynamic>> _searchOffers(
      {String? gpuName, required int diskGb}) async {
    final response = await _request(
      () => _dio.post(
        '$_baseUrl/bundles/',
        data: _searchBody(gpuName: gpuName, diskGb: diskGb),
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
  Future<List<GpuOffer>> listGpus({required int diskGb}) async {
    final offers = await _searchOffers(diskGb: diskGb);

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
    final offers =
        await _searchOffers(gpuName: request.gpu.gpuId, diskGb: request.diskGb);
    if (offers.isEmpty) {
      throw ProviderApiException(
          provider, 'No offers available for ${request.gpu.gpuName}');
    }

    // Cheapest first, so the GPU is rented at the price the picker showed
    // (listGpus reports each model's cheapest dph_total). Reliability is
    // already gated by the search filter.
    offers.sort((a, b) => ((a['dph_total'] as num?) ?? double.infinity)
        .compareTo((b['dph_total'] as num?) ?? double.infinity));

    final env = <String, String>{
      ...GpuProviderService.containerEnv(request),
      // Vast port-mapping convention: -p entries go into the env map.
      '-p 8000:8000': '1',
    };

    final payload = {
      'client_id': 'me',
      'image': request.dockerImage,
      'label': 'bananafarm-${request.jobId}',
      'disk': request.diskGb,
      'runtype': 'args',
      'env': env,
    };

    // Vast's search index lags behind rentals, so the top offer can already
    // be gone ("no_such_ask"). Always taking offers.first would retry that
    // same dead offer on every submit; fall through to the next one instead.
    ProviderApiException? lastGone;
    for (final offer in offers.take(_maxOfferAttempts)) {
      final offerId = (offer as Map<String, dynamic>)['id'];
      final Response response;
      try {
        response = await _request(
          () => _dio.put(
            '$_baseUrl/asks/$offerId/',
            data: payload,
            options: Options(headers: _headers),
          ),
        );
      } on ProviderApiException catch (e) {
        if (!_isOfferGone(e)) rethrow;
        print('⚠️ Vast offer $offerId no longer available, trying next');
        lastGone = e;
        continue;
      }

      final data = response.data;
      if (data is! Map || data['success'] != true || data['new_contract'] == null) {
        throw ProviderApiException(
            provider, 'Instance creation failed: ${response.data}');
      }
      return CreatedInstance(instanceId: data['new_contract'].toString());
    }

    throw ProviderApiException(
      provider,
      'No ${request.gpu.gpuName} offer could be rented — the listed machines '
      'were taken before the request reached them. Try again or pick another GPU.',
      statusCode: lastGone?.statusCode,
    );
  }

  /// How many offers to try before giving up on a GPU model.
  static const _maxOfferAttempts = 5;

  /// The offer was rented by someone else (or delisted) after the search.
  bool _isOfferGone(ProviderApiException e) {
    final msg = e.message.toLowerCase();
    return msg.contains('no_such_ask') || msg.contains('is not available');
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

    // The contract's full rate, storage included — set at rental time.
    final rate = (instance['dph_total'] as num?)?.toDouble();

    final actualStatus = (instance['actual_status'] as String?) ?? '';
    if (actualStatus == 'exited' || actualStatus == 'stopped') {
      return InstanceStatus(
          state: ProviderInstanceState.stopped, pricePerHour: rate);
    }
    if (actualStatus != 'running') {
      return InstanceStatus(
          state: ProviderInstanceState.pending, pricePerHour: rate);
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
      return InstanceStatus(
          state: ProviderInstanceState.pending, pricePerHour: rate);
    }
    return InstanceStatus(
      state: ProviderInstanceState.running,
      endpoint: 'http://${publicIp.trim()}:$hostPort',
      pricePerHour: rate,
    );
  }

  @override
  Future<String> getLogs(
    String instanceId, {
    required InstanceLogSource source,
    int tail = 1000,
    String? instanceName,
  }) async {
    // Vast writes the requested logs to S3 and returns where to fetch them.
    final response = await _request(
      () => _dio.put(
        '$_baseUrl/instances/request_logs/$instanceId/',
        data: {
          'tail': '$tail',
          if (source == InstanceLogSource.system) 'daemon_logs': 'true',
        },
        options: Options(headers: _headers),
      ),
    );
    final data = response.data;
    final url = data is Map ? data['result_url'] as String? : null;
    if (url == null || url.isEmpty) {
      throw ProviderApiException(provider,
          'Logs unavailable: ${data is Map ? data['msg'] ?? data : data}');
    }

    // The file appears a moment after the request; S3 answers 403/404 until
    // then. The URL is pre-signed, so no auth header (S3 would reject it).
    for (var attempt = 1;; attempt++) {
      try {
        final logs = await _dio.get<String>(
          url,
          options: Options(responseType: ResponseType.plain),
        );
        return logs.data ?? '';
      } on DioException catch (e) {
        final code = e.response?.statusCode;
        final notReady = code == 403 || code == 404;
        if (!notReady || attempt >= _logFetchAttempts) throw _wrap(e);
        await Future<void>.delayed(_logFetchDelay);
      }
    }
  }

  static const _logFetchAttempts = 5;
  static const _logFetchDelay = Duration(seconds: 1);

  @override
  Future<ProviderBalance> getBalance() async {
    final response = await _request(
      () => _dio.get(
        '$_baseUrl/users/current/',
        options: Options(headers: _headers),
      ),
    );
    final data = response.data;
    // Prepaid accounts report remaining funds as `credit`; `balance` is the
    // documented field and the fallback.
    final value = data is Map ? (data['credit'] ?? data['balance']) : null;
    if (value is! num) {
      throw ProviderApiException(
          provider, 'Unexpected account response: ${response.data}');
    }
    return ProviderBalance(balance: value.toDouble());
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

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../models/gpu_offer.dart';
import '../../models/instance_models.dart';
import '../../models/render_provider.dart';
import 'gpu_provider_service.dart';

/// Direct SaladCloud API client. Requires the user's API key plus their
/// organization and project names (Salad scopes container groups under
/// /organizations/{org}/projects/{project}).
///
/// The container is reached through Salad's Container Gateway: the group is
/// created with `networking` enabled on port 8000 and Salad returns a public
/// DNS name for it.
class SaladApiService implements GpuProviderService {
  static const _baseUrl = 'https://api.salad.com/api/public';

  final String apiKey;
  final String organization;
  final String project;
  final Dio _dio;

  SaladApiService({
    required this.apiKey,
    required this.organization,
    required this.project,
    Dio? dio,
  }) : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 40),
            ));

  @override
  RenderProvider get provider => RenderProvider.salad;

  Map<String, String> get _headers => {
        'Salad-Api-Key': apiKey,
        'Content-Type': 'application/json',
      };

  String get _containersUrl =>
      '$_baseUrl/organizations/$organization/projects/$project/containers';

  /// Salad container group names must be lowercase, start with a letter,
  /// and stay short — use a stable prefix + the job UUID's first block.
  static String containerNameForJob(String jobId) {
    final short = jobId.replaceAll('-', '').toLowerCase();
    return 'bf-${short.substring(0, short.length < 12 ? short.length : 12)}';
  }

  @override
  Future<List<GpuOffer>> listGpus({required int diskGb}) async {
    final classes = await _fetchGpuClasses();

    final offers = <GpuOffer>[];
    for (final gpuClass in classes) {
      if (gpuClass is! Map) continue;
      final id = gpuClass['id'] as String?;
      final name = gpuClass['name'] as String?;
      if (id == null || name == null) continue;

      double? highPrice;
      final prices = gpuClass['prices'];
      if (prices is List) {
        for (final price in prices) {
          if (price is Map && price['priority'] == 'high') {
            highPrice = double.tryParse(price['price'].toString());
          }
        }
      }

      // Memory is only encoded in the class name, e.g. "RTX 3090 (24 GB)".
      final memoryMatch = RegExp(r'\((\d+)\s*GB\)').firstMatch(name);

      offers.add(GpuOffer(
        provider: provider,
        gpuName: name,
        gpuId: id,
        pricePerHour: highPrice,
        memoryGb: memoryMatch != null ? int.tryParse(memoryMatch.group(1)!) : null,
      ));
    }

    // Availability per class, best-effort in parallel — failures just leave
    // the count unknown rather than hiding the GPU.
    final withAvailability = await Future.wait(offers.map((offer) async {
      final available = await _checkAvailability(offer.gpuId);
      if (available == null) return offer;
      return GpuOffer(
        provider: offer.provider,
        gpuName: offer.gpuName,
        gpuId: offer.gpuId,
        pricePerHour: offer.pricePerHour,
        memoryGb: offer.memoryGb,
        availability: available,
      );
    }));

    withAvailability.sort((a, b) => (a.pricePerHour ?? double.infinity)
        .compareTo(b.pricePerHour ?? double.infinity));
    return withAvailability;
  }

  Future<List<dynamic>> _fetchGpuClasses() async {
    try {
      final response = await _dio.get(
        '$_baseUrl/organizations/$organization/gpu-classes',
        options: Options(headers: _headers),
      );
      final items = response.data is Map ? response.data['items'] : null;
      if (items is List && items.isNotEmpty) return items;
    } catch (e) {
      print('⚠️ Salad gpu-classes fetch failed, using bundled list: $e');
    }
    // Fallback: bundled snapshot of Salad's GPU classes.
    final bundled = await rootBundle.loadString('assets/data/salad_gpus.json');
    final decoded = jsonDecode(bundled);
    return decoded is Map ? (decoded['items'] as List? ?? []) : [];
  }

  Future<int?> _checkAvailability(String gpuClassId) async {
    try {
      final response = await _dio.post(
        '$_baseUrl/organizations/$organization/availability/sce-gpu-availability',
        data: {
          'gpu_classes': [gpuClassId],
          'cpu': 8,
          'memory': 16384,
          'storage_amount': 53687091200,
          'country_codes': ['us', 'ca'],
        },
        options: Options(headers: _headers),
      );
      final data = response.data;
      if (data is Map && data['available_gpu_high'] != null) {
        return (data['available_gpu_high'] as num).toInt();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<CreatedInstance> createInstance(InstanceRequest request) async {
    final name = containerNameForJob(request.jobId);

    final payload = {
      'name': name,
      'display_name': name,
      'autostart_policy': true,
      'restart_policy': 'never',
      'replicas': 1,
      'container': {
        'image': request.dockerImage,
        'resources': {
          'cpu': 8,
          'memory': 16384,
          'gpu_classes': [request.gpu.gpuId],
          'storage_amount': 53687091200,
          'shm_size': 2048,
        },
        'environment_variables': GpuProviderService.containerEnv(request),
        'priority': 'high',
        'image_caching': true,
      },
      // Container Gateway: gives the group a public HTTPS DNS for port 8000.
      // auth:false is intentional — the container enforces its own bearer token.
      'networking': {
        'protocol': 'http',
        'port': 8000,
        'auth': false,
        'load_balancer': 'least_number_of_connections',
        'client_request_timeout': 100000,
        'server_response_timeout': 100000,
      },
      'country_codes': ['us', 'ca'],
    };

    final response = await _request(
      () => _dio.post(
        _containersUrl,
        data: payload,
        options: Options(headers: _headers),
      ),
    );

    final data = response.data;
    final id = data is Map ? data['id'] as String? : null;
    if (id == null) {
      throw ProviderApiException(
          provider, 'Container creation failed: ${response.data}');
    }
    return CreatedInstance(instanceId: id, instanceName: name);
  }

  @override
  Future<InstanceStatus> getInstance(String instanceId,
      {String? instanceName}) async {
    final name = instanceName ?? instanceId;
    final Response response;
    try {
      response = await _dio.get(
        '$_containersUrl/$name',
        options: Options(headers: _headers),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return InstanceStatus(state: ProviderInstanceState.missing);
      }
      throw _wrap(e);
    }

    final data = response.data;
    final status = data is Map
        ? (data['current_state']?['status'] as String?) ?? 'pending'
        : 'pending';
    final dns =
        data is Map ? (data['networking']?['dns'] as String?) : null;

    switch (status.toLowerCase()) {
      case 'running':
        if (dns == null || dns.isEmpty) {
          return InstanceStatus(state: ProviderInstanceState.pending);
        }
        return InstanceStatus(
          state: ProviderInstanceState.running,
          endpoint: 'https://$dns',
        );
      case 'stopped':
      case 'failed':
        return InstanceStatus(state: ProviderInstanceState.stopped);
      default:
        return InstanceStatus(state: ProviderInstanceState.pending);
    }
  }

  @override
  Future<void> destroyInstance(String instanceId, {String? instanceName}) async {
    final name = instanceName ?? instanceId;
    try {
      await _dio.delete(
        '$_containersUrl/$name',
        options: Options(headers: _headers),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return; // already gone
      throw _wrap(e);
    }
  }

  /// Salad is withdrawn (see ApiKeysState.configuredProviders), so its
  /// balance is never shown.
  @override
  Future<ProviderBalance> getBalance() =>
      throw UnsupportedError('Salad balance is not supported');

  @override
  Future<String> getLogs(
    String instanceId, {
    required InstanceLogSource source,
    int tail = 1000,
    String? instanceName,
  }) =>
      throw UnsupportedError('Salad logs are not supported');

  Future<Response> _request(Future<Response> Function() fn) async {
    try {
      return await fn();
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  ProviderApiException _wrap(DioException e) {
    final body = e.response?.data;
    final message = body is Map && body['message'] != null
        ? body['message'].toString()
        : (e.message ?? 'Request failed');
    return ProviderApiException(provider, message,
        statusCode: e.response?.statusCode);
  }
}

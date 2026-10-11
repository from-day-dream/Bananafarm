import 'dart:convert';

import '../../models/gpu_offer.dart';
import '../../models/instance_models.dart';
import '../../models/render_provider.dart';

/// Error from a GPU provider API, with enough context to show the user.
class ProviderApiException implements Exception {
  final RenderProvider provider;
  final String message;
  final int? statusCode;

  ProviderApiException(this.provider, this.message, {this.statusCode});

  @override
  String toString() =>
      '${provider.label} API error${statusCode != null ? ' ($statusCode)' : ''}: $message';
}

/// Direct client for one GPU cloud provider (Vast.ai / RunPod).
///
/// SaladApiService still implements this and remains in the tree, but
/// Salad is not currently offered — see [ApiKeysState.configuredProviders].
///
/// Implementations translate the app's job model into the provider's REST
/// payloads. All calls use the user's own API key from settings.
abstract class GpuProviderService {
  RenderProvider get provider;

  /// Live list of GPUs the provider currently offers, with prices.
  Future<List<GpuOffer>> listGpus();

  /// Rent an instance running [InstanceRequest.dockerImage] with the render
  /// job's environment variables injected.
  Future<CreatedInstance> createInstance(InstanceRequest request);

  /// Poll instance state and discover the container endpoint once running.
  Future<InstanceStatus> getInstance(String instanceId, {String? instanceName});

  /// Destroy the instance. Idempotent: a missing instance (404) is success.
  Future<void> destroyInstance(String instanceId, {String? instanceName});

  /// Environment variables shared by every provider's container config.
  static Map<String, String> containerEnv(InstanceRequest request) {
    return {
      'JOB_ID': request.jobId,
      'PROVIDER': request.gpu.provider.containerProviderName,
      'BLENDER_VERSION': request.blenderVersion,
      'RENDER_PARAMS': jsonEncode(request.renderParams),
      'API_TOKEN': request.apiToken,
    };
  }
}
